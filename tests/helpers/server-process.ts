import { spawn, type ChildProcess } from "node:child_process";
import { once } from "node:events";
import { mkdtempSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

export function reservePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : 0;
      server.close(() => resolve(port));
    });
  });
}

export function isolatedChildEnv(home: string, extra: NodeJS.ProcessEnv = {}): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {
    ...process.env,
    ...extra,
    HOME: home,
    XDG_CONFIG_HOME: path.join(home, "xdg"),
    TMUX_TMPDIR: home,
  };
  delete env.HERDR_SOCKET_PATH;
  delete env.HERDR_SESSION;
  delete env.TMUX;
  delete env.TMUX_PANE;
  if (!extra.HERDR_FIXTURE) delete env.HERDR_FIXTURE;
  if (!extra.HERDR_ALLOW_NETWORK) delete env.HERDR_ALLOW_NETWORK;
  return env;
}

export function isolatedHome(): string {
  return mkdtempSync(path.join(tmpdir(), "herdr-dashboard-home-"));
}

export interface RunningDashboardProcess {
  port: number;
  pid: number;
  home: string;
  stderr: () => string;
  stop: () => Promise<{ code: number | null; stderr: string }>;
}

export async function startDashboardProcess(options: {
  configPath: string;
  databasePath: string;
  fixture?: boolean;
  env?: NodeJS.ProcessEnv;
  home?: string;
}): Promise<RunningDashboardProcess> {
  const port = await reservePort();
  const home = options.home ?? isolatedHome();
  const args = [
    path.join(repoRoot, "apps/server/dist/main.js"),
    "--host",
    "127.0.0.1",
    "--port",
    String(port),
    "--config",
    options.configPath,
    "--database",
    options.databasePath,
  ];
  if (options.fixture) args.push("--fixture");
  const extra = { ...options.env };
  if (options.fixture && extra.HERDR_ALLOW_NETWORK === undefined) extra.HERDR_ALLOW_NETWORK = "0";
  const child: ChildProcess = spawn(process.execPath, args, {
    cwd: repoRoot,
    env: isolatedChildEnv(home, extra),
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stderr = "";
  child.stderr?.setEncoding("utf8");
  child.stderr?.on("data", (chunk: string) => {
    stderr += chunk;
  });
  child.stdout?.on("data", () => undefined);
  const deadline = Date.now() + 8_000;
  let last = "not started";
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`dashboard exited ${child.exitCode}: ${stderr}`);
    }
    try {
      const response = await fetch(`http://127.0.0.1:${port}/api/health`);
      if (response.status === 200) {
        const pid = child.pid;
        if (!pid) throw new Error("dashboard pid missing");
        return {
          port,
          pid,
          home,
          stderr: () => stderr,
          async stop() {
            if (child.exitCode !== null) return { code: child.exitCode, stderr };
            child.kill("SIGTERM");
            const timer = setTimeout(() => child.kill("SIGKILL"), 5_000);
            const [code] = (await once(child, "exit")) as [number | null];
            clearTimeout(timer);
            return { code, stderr };
          },
        };
      }
      last = `status ${response.status}`;
    } catch (error) {
      last = error instanceof Error ? error.message : "fetch failed";
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  child.kill("SIGTERM");
  throw new Error(`health did not become ready: ${last}; ${stderr}`);
}
