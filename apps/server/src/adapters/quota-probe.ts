import { spawn } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { probeResultSchema, type ProbeResult } from "@herdr/contracts";

const STDOUT_CAP = 64 * 1024;
const STDERR_CAP = 4 * 1024;
const DEFAULT_DEADLINE_MS = 20_000;
const MIN_DEADLINE_MS = 100;

export interface QuotaProbeRequest {
  executable: string;
  profile: string;
  cwd: string;
  deadlineMs?: number;
  lockPath?: string;
  signal?: AbortSignal;
  onCapture?: (phase: string, lines: string[]) => void;
}

export function clampDeadline(requested: number | undefined): number {
  if (requested === undefined || !Number.isFinite(requested)) {
    return DEFAULT_DEADLINE_MS;
  }
  const value = Math.floor(requested);
  if (value < MIN_DEADLINE_MS) {
    return MIN_DEADLINE_MS;
  }
  if (value > DEFAULT_DEADLINE_MS) {
    return DEFAULT_DEADLINE_MS;
  }
  return value;
}

export function interpretProbeOutput(
  stdout: string,
  fallback: { profile: string; deadlineMs: number },
): ProbeResult {
  const failed = failure("invalid_result", fallback.profile, fallback.deadlineMs);
  const trimmed = stdout.trim();
  if (!trimmed) {
    return failed;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed);
  } catch {
    return failed;
  }
  const result = probeResultSchema.safeParse(parsed);
  if (!result.success) {
    return failed;
  }
  return result.data;
}

export async function runQuotaProbe(request: QuotaProbeRequest): Promise<ProbeResult> {
  const deadlineMs = clampDeadline(request.deadlineMs);
  const profile = safeProfile(request.profile);
  if (!path.isAbsolute(request.cwd)) {
    return failure("cwd_denied", profile, deadlineMs);
  }
  let cwdInfo;
  try {
    cwdInfo = statSync(request.cwd);
  } catch {
    return failure("cwd_denied", profile, deadlineMs);
  }
  if (!cwdInfo.isDirectory() || (cwdInfo.mode & 0o002) !== 0) {
    return failure("cwd_denied", profile, deadlineMs);
  }
  if (!path.isAbsolute(request.executable) || request.executable.includes("\0")) {
    return failure("not_absolute", profile, deadlineMs);
  }

  const root = dashboardRoot();
  const python = path.join(root, ".venv", "bin", "python");
  const probe = path.join(root, "probes", "probe.py");
  if (!existsSync(python) || !existsSync(probe)) {
    return failure("python_missing", profile, deadlineMs);
  }

  const lockPath = request.lockPath ?? path.join(request.cwd, ".probe.lock");
  const child = spawn(
    python,
    [probe, "--executable", request.executable, "--profile", request.profile, "--cwd", request.cwd, "--deadline-ms", String(deadlineMs)],
    {
      cwd: request.cwd,
      env: {
        PATH: process.env.PATH ?? "",
        HOME: request.cwd,
        LANG: "C.UTF-8",
        LC_ALL: "C.UTF-8",
        TERM: "xterm-256color",
        HERDR_PROBE_LOCK: lockPath,
      },
      shell: false,
      detached: true,
      stdio: request.onCapture ? ["ignore", "pipe", "pipe", "pipe"] : ["ignore", "pipe", "pipe"],
      windowsHide: true,
    },
  );

  const captureDone = request.onCapture ? watchCapture(child.stdio[3], request.onCapture) : Promise.resolve();

  const stdoutChunks: Uint8Array[] = [];
  let stdoutBytes = 0;
  let stderrBytes = 0;
  let overflow = false;
  let settled = false;

  const take = (chunk: Uint8Array): void => {
    if (overflow || stdoutBytes >= STDOUT_CAP) {
      overflow = true;
      return;
    }
    const room = STDOUT_CAP - stdoutBytes;
    if (chunk.byteLength <= room) {
      stdoutChunks.push(Buffer.from(chunk));
      stdoutBytes += chunk.byteLength;
      return;
    }
    overflow = true;
    stdoutChunks.push(Buffer.from(chunk.subarray(0, room)));
    stdoutBytes = STDOUT_CAP;
  };

  child.stdout?.on("data", (chunk: Uint8Array) => {
    take(chunk);
  });
  child.stderr?.on("data", (chunk: Uint8Array) => {
    stderrBytes += chunk.byteLength;
    if (stderrBytes > STDERR_CAP) {
      child.stderr?.pause();
    }
  });

  const closed = new Promise<void>((resolve, reject) => {
    child.once("error", (error) => {
      reject(error);
    });
    child.once("close", () => {
      resolve();
    });
  });

  const halt = async (): Promise<void> => {
    if (!child.pid) {
      return;
    }
    signalProcess(child.pid, "SIGTERM");
    const until = Date.now() + 800;
    while (Date.now() < until && alive(child.pid)) {
      await delay(20);
    }
    if (child.pid && alive(child.pid)) {
      signalProcess(child.pid, "SIGKILL");
    }
  };

  const onAbort = (): void => {
    if (!settled) {
      void halt();
    }
  };
  if (request.signal) {
    if (request.signal.aborted) {
      await halt();
    } else {
      request.signal.addEventListener("abort", onAbort, { once: true });
    }
  }
  const timer = setTimeout(() => {
    void halt();
  }, deadlineMs + 2_000);

  try {
    await closed;
    await captureDone;
  } catch {
    return failure("python_missing", profile, deadlineMs);
  } finally {
    settled = true;
    clearTimeout(timer);
    request.signal?.removeEventListener("abort", onAbort);
    if (child.pid && alive(child.pid)) {
      await halt();
    }
    reapRecorded(request.cwd, request.executable);
  }

  if (overflow) {
    return failure("invalid_result", profile, deadlineMs);
  }
  const stdout = Buffer.concat(stdoutChunks).toString("utf8");
  if (!stdout.trim()) {
    if (request.signal?.aborted) {
      return failure("cancelled", profile, deadlineMs);
    }
    return failure("invalid_result", profile, deadlineMs);
  }
  return interpretProbeOutput(stdout, { profile, deadlineMs });
}

function failure(reason: string, profile: string, deadlineMs: number): ProbeResult {
  return {
    ok: false,
    provider: "unknown",
    profile: safeProfile(profile),
    state: reason === "cancelled" ? "shutdown" : "started",
    reason,
    version: null,
    isatty: false,
    sent: [],
    childReaped: true,
    recognized: false,
    deadlineMs,
  };
}

function safeProfile(profile: string): string {
  return /^[A-Za-z0-9._-]{1,64}$/.test(profile) ? profile : "unknown";
}

function dashboardRoot(): string {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const candidates = [path.resolve(here, "../../../.."), path.resolve(here, "../../..")];
  for (const candidate of candidates) {
    if (existsSync(path.join(candidate, "probes", "probe.py"))) {
      return candidate;
    }
  }
  throw new Error("dashboard root not found");
}

function processGroup(pid: number): number | null {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
    const after = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
    const group = Number(after[2]);
    return Number.isInteger(group) ? group : null;
  } catch {
    return null;
  }
}

function cmdline(pid: number): string[] {
  try {
    return readFileSync(`/proc/${pid}/cmdline`).toString("utf8").split("\0").filter((part) => part.length > 0);
  } catch {
    return [];
  }
}

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function signalProcess(pid: number, signal: NodeJS.Signals): void {
  if (!Number.isInteger(pid) || pid <= 1 || pid === process.pid) {
    return;
  }
  const group = processGroup(pid);
  try {
    if (group === pid) {
      process.kill(-pid, signal);
      return;
    }
  } catch {
    // The group is already gone; fall through to the process itself.
  }
  try {
    process.kill(pid, signal);
  } catch {
    // The child has already exited.
  }
}

function reapRecorded(cwd: string, executable: string): void {
  const pidFile = path.join(cwd, "pid");
  if (!existsSync(pidFile)) {
    return;
  }
  let pid: number;
  try {
    pid = Number(readFileSync(pidFile, "utf8").trim());
  } catch {
    return;
  }
  if (!Number.isInteger(pid) || pid <= 1 || pid === process.pid || !alive(pid)) {
    return;
  }
  const args = cmdline(pid);
  if (args[0] !== executable && !args.includes(executable)) {
    return;
  }
  signalProcess(pid, "SIGKILL");
}

const CAPTURE_PHASE = /^[a-z][a-z0-9_-]{0,31}$/;

function watchCapture(stream: unknown, onCapture: (phase: string, lines: string[]) => void): Promise<void> {
  if (!stream || typeof stream !== "object" || !("on" in stream)) return Promise.resolve();
  const readable = stream as NodeJS.ReadableStream;
  return new Promise((resolve) => {
    let buffer = "";
    let settled = false;
    const finish = (): void => {
      if (settled) return;
      settled = true;
      resolve();
    };
    if ("setEncoding" in readable && typeof readable.setEncoding === "function") {
      readable.setEncoding("utf8");
    }
    readable.on("data", (chunk: string | Uint8Array) => {
      buffer += typeof chunk === "string" ? chunk : Buffer.from(chunk).toString("utf8");
      if (buffer.length > 256 * 1024) buffer = buffer.slice(-128 * 1024);
      let newline = buffer.indexOf("\n");
      while (newline >= 0) {
        deliverCapture(buffer.slice(0, newline), onCapture);
        buffer = buffer.slice(newline + 1);
        newline = buffer.indexOf("\n");
      }
    });
    readable.on("end", finish);
    readable.on("close", finish);
    readable.on("error", finish);
  });
}

function deliverCapture(line: string, onCapture: (phase: string, lines: string[]) => void): void {
  const trimmed = line.trim();
  if (!trimmed) return;
  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed);
  } catch {
    return;
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return;
  const record = parsed as Record<string, unknown>;
  if ("screen" in record || "rawScreen" in record) return;
  if (typeof record.phase !== "string" || !CAPTURE_PHASE.test(record.phase) || !Array.isArray(record.lines)) return;
  const kept: string[] = [];
  for (const entry of record.lines) {
    if (typeof entry !== "string" || entry.length > 200 || kept.length >= 80) return;
    kept.push(entry);
  }
  onCapture(record.phase, kept);
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}
