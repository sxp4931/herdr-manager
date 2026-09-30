import { spawn } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import type { CommandRequest, CommandResult, CommandRunner } from "@herdr/contracts";

const SHELLS = new Set(["sh", "bash", "zsh", "dash", "fish", "csh", "tcsh", "ksh", "pwsh", "powershell", "cmd"]);
const GIT_READ = new Set(["rev-parse", "status", "symbolic-ref", "log", "version"]);
const TMUX_DENIED = new Set([
  "send-keys",
  "capture-pane",
  "kill-session",
  "kill-pane",
  "kill-window",
  "kill-server",
  "load-buffer",
  "save-buffer",
  "paste-buffer",
  "set-buffer",
  "pipe-pane",
  "respawn-pane",
  "respawn-window",
  "new-session",
  "split-window",
  "resize-pane",
]);

const SENSITIVE_ENV = /(?:^|_)(?:API_KEY|APIKEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|SESSION)(?:_|$)|^(?:LD_PRELOAD|LD_LIBRARY_PATH|DYLD_INSERT_LIBRARIES|DYLD_LIBRARY_PATH|NODE_OPTIONS|NODE_DEBUG|PYTHONSTARTUP|PYTHONINSPECT|BASH_ENV|ENV|SHELLOPTS|PS4|ANTHROPIC_BASE_URL|ANTHROPIC_API_BASE|OPENAI_BASE_URL|OPENAI_API_BASE|XAI_BASE_URL|XAI_API_BASE)$/i;
const GIT_EXEC_INJECTION = /^GIT_(?:SSH_COMMAND|ASKPASS|EDITOR|PAGER|EXTERNAL_DIFF|SEQUENCE_EDITOR|PROXY_COMMAND)/i;
const GIT_CONFIG_ALLOW = new Set(["core.hooksPath=/dev/null", "core.fsmonitor="]);
const GIT_PATCH_FLAG = /^(?:-p|--patch|-u|--stat|--raw|--numstat|--name-only|--name-status)$|^(?:--unified(?:=|$)|-U)/;
const TMUX_VALUE_FLAGS = new Set(["-S", "-L", "-f", "-F"]);

export class CommandDeniedError extends Error {
  readonly code = "command_denied";

  constructor(message: string) {
    super(message);
    this.name = "CommandDeniedError";
  }
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

function assertExecutable(executable: string): void {
  if (!path.isAbsolute(executable) || executable.includes("\0")) {
    throw new CommandDeniedError("executable must be an absolute path");
  }
  const base = path.basename(executable);
  if (SHELLS.has(base)) {
    throw new CommandDeniedError("shell executable denied");
  }
  if (!existsSync(executable)) {
    throw new CommandDeniedError("executable is missing");
  }
  const info = statSync(executable);
  if (!info.isFile()) {
    throw new CommandDeniedError("executable is not a file");
  }
}

function positionalArgs(args: readonly string[]): string[] {
  const positionals: string[] = [];
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index] ?? "";
    if (arg === "-C" || arg === "--git-dir" || arg === "-c" || arg === "--work-tree") {
      index += 1;
      continue;
    }
    if (arg.startsWith("-")) {
      continue;
    }
    positionals.push(arg);
  }
  return positionals;
}

function blockedGitControl(key: string, value: string): boolean {
  if (GIT_EXEC_INJECTION.test(key)) return true;
  if (!/^GIT_CONFIG/i.test(key)) return false;
  if (key === "GIT_CONFIG_NOSYSTEM" && value === "1") return false;
  if ((key === "GIT_CONFIG_GLOBAL" || key === "GIT_CONFIG_SYSTEM") && value === "/dev/null") return false;
  return true;
}

function assertGit(args: readonly string[]): void {
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index] ?? "";
    if (arg === "--config-env" || arg.startsWith("--config-env=")) {
      throw new CommandDeniedError("git config override denied");
    }
    if (arg === "-c" || (arg.startsWith("-c") && arg.length > 2)) {
      const value = arg === "-c" ? args[index + 1] : arg.slice(2);
      if (arg === "-c") index += 1;
      if (value === undefined || !GIT_CONFIG_ALLOW.has(value)) {
        throw new CommandDeniedError("git config override denied");
      }
      continue;
    }
    if (arg === "--git-dir" || arg.startsWith("--git-dir=") || arg === "--work-tree" || arg.startsWith("--work-tree=")) {
      throw new CommandDeniedError("git directory override denied");
    }
    if (GIT_PATCH_FLAG.test(arg)) {
      throw new CommandDeniedError("git diff output denied");
    }
  }
  const positionals = positionalArgs(args);
  const [command, action] = positionals;
  if (command === undefined) {
    if (args.includes("--version")) {
      return;
    }
    throw new CommandDeniedError("git command denied");
  }
  if (command === "worktree") {
    if (action !== "list") {
      throw new CommandDeniedError("git worktree mutation denied");
    }
    return;
  }
  if (!GIT_READ.has(command)) {
    throw new CommandDeniedError("git command denied");
  }
  if (command === "symbolic-ref" && positionals.length !== 2) {
    throw new CommandDeniedError("git symbolic-ref write denied");
  }
}

function tmuxPositionals(args: readonly string[]): string[] {
  const positionals: string[] = [];
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index] ?? "";
    if (TMUX_VALUE_FLAGS.has(arg)) {
      index += 1;
      continue;
    }
    if (arg.startsWith("-")) {
      continue;
    }
    positionals.push(arg);
  }
  return positionals;
}

function assertTmux(args: readonly string[]): void {
  const positionals = tmuxPositionals(args);
  const command = positionals[0];
  if (command === undefined) {
    if (args.includes("-V") || args.includes("--version")) {
      return;
    }
    throw new CommandDeniedError("tmux command denied");
  }
  if (TMUX_DENIED.has(command)) {
    throw new CommandDeniedError("tmux input command denied");
  }
  if (command !== "list-panes") {
    throw new CommandDeniedError("tmux command denied");
  }
}

function assertRequest(request: CommandRequest): void {
  assertExecutable(request.executable);
  if (!path.isAbsolute(request.cwd)) {
    throw new CommandDeniedError("working directory must be an absolute directory");
  }
  let cwdInfo;
  try {
    cwdInfo = statSync(request.cwd);
  } catch {
    throw new CommandDeniedError("working directory must be an absolute directory");
  }
  if (!cwdInfo.isDirectory()) {
    throw new CommandDeniedError("working directory must be an absolute directory");
  }
  if ((cwdInfo.mode & 0o002) !== 0) {
    throw new CommandDeniedError("working directory must be private");
  }
  if (!Number.isFinite(request.timeoutMs) || request.timeoutMs < 1 || request.timeoutMs > 60_000) {
    throw new CommandDeniedError("timeout is outside the allowed bound");
  }
  if (!Number.isInteger(request.maxBytes) || request.maxBytes < 1 || request.maxBytes > 1_048_576) {
    throw new CommandDeniedError("output cap is outside the allowed bound");
  }
  for (const arg of request.args) {
    if (typeof arg !== "string" || arg.includes("\0")) {
      throw new CommandDeniedError("argument denied");
    }
  }
  const base = path.basename(request.executable);
  if (base === "git") {
    assertGit(request.args);
  }
  if (base === "tmux") {
    assertTmux(request.args);
  }
}

export function filterEnvironment(input: Record<string, string>, executable: string): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(input)) {
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) {
      continue;
    }
    if (key !== "HERDR_SESSION" && (SENSITIVE_ENV.test(key) || blockedGitControl(key, value))) {
      continue;
    }
    env[key] = value;
  }
  if (path.basename(executable) === "git") {
    env.GIT_OPTIONAL_LOCKS = "0";
    env.GIT_TERMINAL_PROMPT = "0";
  }
  return env;
}

function killGroup(pid: number): void {
  const group = processGroup(pid);
  if (group === pid) {
    try {
      process.kill(-pid, "SIGKILL");
      return;
    } catch {
      // Fall through to the direct pid if the group is already gone.
    }
  }
  try {
    process.kill(pid, "SIGKILL");
  } catch {
    // The child has already exited.
  }
}

export async function runCommand(request: CommandRequest, signal: AbortSignal): Promise<CommandResult> {
  assertRequest(request);
  if (signal.aborted) {
    throw new CommandDeniedError("command aborted");
  }
  const env = filterEnvironment(request.allowedEnvironment, request.executable);
  const child = spawn(request.executable, request.args, {
    cwd: request.cwd,
    env,
    shell: false,
    detached: true,
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true,
  });
  const stdoutChunks: Uint8Array[] = [];
  const stderrChunks: Uint8Array[] = [];
  let stdoutBytes = 0;
  let stderrBytes = 0;
  let truncated = false;
  let timedOut = false;
  let settled = false;

  const stop = (fromTimeout: boolean): void => {
    if (settled) {
      return;
    }
    if (fromTimeout) {
      timedOut = true;
    }
    if (child.pid) {
      killGroup(child.pid);
    }
  };

  const timer = setTimeout(() => stop(true), request.timeoutMs);
  const onAbort = (): void => stop(false);
  signal.addEventListener("abort", onAbort, { once: true });

  const take = (chunks: Uint8Array[], used: number, chunk: Uint8Array): number => {
    if (truncated || used >= request.maxBytes) {
      return used;
    }
    const room = request.maxBytes - used;
    if (chunk.byteLength <= room) {
      chunks.push(chunk);
      return used + chunk.byteLength;
    }
    truncated = true;
    stop(false);
    chunks.push(chunk.subarray(0, room));
    return request.maxBytes;
  };

  child.stdout?.on("data", (chunk: Uint8Array) => {
    stdoutBytes = take(stdoutChunks, stdoutBytes, chunk);
  });
  child.stderr?.on("data", (chunk: Uint8Array) => {
    stderrBytes = take(stderrChunks, stderrBytes, chunk);
  });

  const code = await new Promise<number | null>((resolve, reject) => {
    child.once("error", (error) => {
      settled = true;
      clearTimeout(timer);
      signal.removeEventListener("abort", onAbort);
      reject(error);
    });
    child.once("close", (exitCode) => {
      settled = true;
      clearTimeout(timer);
      signal.removeEventListener("abort", onAbort);
      resolve(exitCode);
    });
  });

  return {
    code,
    stdout: Buffer.concat(stdoutChunks).toString("utf8"),
    stderr: Buffer.concat(stderrChunks).toString("utf8"),
    timedOut,
    truncated,
  };
}

export function createCommandRunner(): CommandRunner {
  return { run: runCommand };
}
