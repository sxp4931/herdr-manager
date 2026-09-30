import { createServer, type Server, type Socket } from "node:net";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

export interface FakeHerdrRequest {
  id: string;
  method: string;
  params: unknown;
}

export type FakeHerdrReply =
  | { type: "result"; result: unknown; id?: string | number; preface?: unknown[]; error?: null }
  | { type: "error"; error: unknown }
  | { type: "split"; result: unknown }
  | { type: "hang" }
  | { type: "oversize" }
  | { type: "nonewline"; partial: string }
  | { type: "drop" };

export interface FakeHerdr {
  socketPath: string;
  methods: string[];
  connections: number;
  close(): Promise<void>;
}

function writeJson(socket: Socket, value: unknown): void {
  socket.write(`${JSON.stringify(value)}\n`);
}

/** In-process Unix socket that speaks one NDJSON request per connection. */
export async function startFakeHerdr(
  respond: (request: FakeHerdrRequest, connection: number) => FakeHerdrReply,
): Promise<FakeHerdr> {
  const directory = mkdtempSync(path.join(tmpdir(), "herdr-fake-"));
  const socketPath = path.join(directory, "herdr.sock");
  const methods: string[] = [];
  const sockets = new Set<Socket>();
  let connections = 0;
  const server: Server = createServer((socket) => {
    connections += 1;
    const connection = connections;
    sockets.add(socket);
    socket.on("error", () => {
      // The client destroys the socket on timeout, oversize, and shutdown.
    });
    socket.on("close", () => sockets.delete(socket));
    let buffer = Buffer.alloc(0);
    let replied = false;
    const fail = (): void => {
      socket.destroy();
    };
    socket.on("data", (chunk: Buffer) => {
      if (replied) return;
      buffer = Buffer.concat([buffer, chunk]);
      const newline = buffer.indexOf(0x0a);
      if (newline < 0) return;
      replied = true;
      const line = buffer.subarray(0, newline).toString("utf8");
      let parsed: { id?: unknown; method?: unknown; params?: unknown };
      try {
        parsed = JSON.parse(line) as { id?: unknown; method?: unknown; params?: unknown };
      } catch {
        fail();
        return;
      }
      const method = typeof parsed.method === "string" ? parsed.method : "";
      const id = typeof parsed.id === "string" || typeof parsed.id === "number" ? String(parsed.id) : "";
      methods.push(method);
      const reply = respond({ id, method, params: parsed.params ?? {} }, connection);
      if (reply.type === "drop") {
        fail();
        return;
      }
      if (reply.type === "hang") return;
      if (reply.type === "oversize") {
        socket.write(Buffer.alloc(4 * 1024 * 1024 + 1, 0x61));
        return;
      }
      if (reply.type === "nonewline") {
        socket.write(reply.partial);
        return;
      }
      if (reply.type === "error") {
        writeJson(socket, { id, error: reply.error });
        return;
      }
      if (reply.type === "split") {
        const payload = `${JSON.stringify({ id, result: reply.result, error: null })}\n`;
        const middle = Math.max(1, Math.floor(payload.length / 2));
        socket.write(payload.slice(0, middle));
        setTimeout(() => {
          if (!socket.destroyed) socket.write(payload.slice(middle));
        }, 20);
        return;
      }
      for (const preface of reply.preface ?? []) writeJson(socket, preface);
      writeJson(socket, { id: reply.id ?? id, result: reply.result, error: reply.error ?? null });
    });
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, () => resolve());
  });
  return {
    socketPath,
    methods,
    get connections() {
      return connections;
    },
    async close() {
      for (const socket of sockets) socket.destroy();
      await new Promise<void>((resolve) => server.close(() => resolve()));
      rmSync(directory, { recursive: true, force: true });
    },
  };
}
