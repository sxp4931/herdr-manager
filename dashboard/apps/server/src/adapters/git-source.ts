import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, realpathSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  gitWorktreeSchema,
  sourceHealthSchema,
  type Clock,
  type CommandResult,
  type CommandRunner,
  type GitCommit,
  type GitSource,
  type GitWorktree,
  type SourceHealth,
} from "@herdr/contracts";
import { CommandDeniedError } from "./command-runner.js";
import { redactText } from "../services/redaction.js";

const PARSER_VERSION = "git-1";
const SHA = /^[0-9a-f]{40}$/;
const ZERO_SHA = /^0{40}$/;
const UNMERGED = new Set(["DD", "AU", "UD", "UA", "DU", "AA", "UU"]);
const GUARD = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor="];

interface PorcelainWorktree {
  path: string;
  head: string | null;
  branch: string | null;
  detached: boolean;
  locked: boolean;
  prunable: boolean;
  bare: boolean;
  repositoryKey: string;
}

interface GitRun extends CommandResult {
  denied: boolean;
}

interface FailedRoot {
  path: string;
  status: SourceHealth["status"];
  reason: string;
}

export interface GitSourceOptions {
  runner: CommandRunner;
  clock: Clock;
  gitExecutable?: string;
}

export function createGitSource(options: GitSourceOptions): GitSource {
  return {
    collect(roots, signal) {
      return collectGit(options, roots, signal);
    },
  };
}

function findGit(explicit: string | undefined): string | null {
  if (explicit && path.isAbsolute(explicit) && existsSync(explicit)) return explicit;
  for (const segment of (process.env.PATH ?? "").split(path.delimiter)) {
    if (!segment) continue;
    const candidate = path.join(segment, "git");
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

function makeHealth(
  sourceId: string,
  status: SourceHealth["status"],
  reasonCode: string,
  now: string,
  cliVersion: string | null,
): SourceHealth {
  return sourceHealthSchema.parse({
    sourceId,
    status,
    checkedAt: now,
    lastSuccessAt: status === "ok" ? now : null,
    reasonCode,
    cliVersion,
    parserVersion: PARSER_VERSION,
    provenance: "live",
  });
}

function identityPath(input: string): string {
  const resolved = path.resolve(input);
  try {
    return realpathSync(resolved);
  } catch {
    return resolved;
  }
}

function digest(value: string): string {
  return createHash("sha256").update(value).digest("hex").slice(0, 32);
}

function cleanBranch(value: string | null): string | null {
  if (value === null) return null;
  const cleaned = redactText(value).replace(/\s+/g, " ").trim();
  if (cleaned.length === 0 || cleaned.length > 200) return null;
  return cleaned;
}

function sanitizeSubject(value: string): string {
  const cleaned = redactText(value).replace(/\s+/g, " ").trim();
  const clipped = Array.from(cleaned).slice(0, 120).join("");
  return clipped.length > 0 ? clipped : "(no subject)";
}

function normalizeSha(value: string): string | null {
  const sha = value.trim().toLowerCase();
  if (!SHA.test(sha) || ZERO_SHA.test(sha)) return null;
  return sha;
}

function blankWorktree(): PorcelainWorktree {
  return { path: "", head: null, branch: null, detached: false, locked: false, prunable: false, bare: false, repositoryKey: "" };
}

function parseWorktreeList(stdout: string): PorcelainWorktree[] {
  const records: PorcelainWorktree[] = [];
  let current: PorcelainWorktree | null = null;
  const flush = (): void => {
    if (current?.path) records.push(current);
    current = null;
  };
  for (const raw of stdout.split("\0")) {
    if (raw === "") {
      flush();
      continue;
    }
    current ??= blankWorktree();
    if (raw.startsWith("worktree ")) current.path = raw.slice("worktree ".length);
    else if (raw.startsWith("HEAD ")) current.head = normalizeSha(raw.slice("HEAD ".length));
    else if (raw.startsWith("branch ")) {
      const ref = raw.slice("branch ".length).trim();
      current.branch = ref.startsWith("refs/heads/") ? ref.slice("refs/heads/".length) : ref;
    } else if (raw === "detached") current.detached = true;
    else if (raw === "bare") current.bare = true;
    else if (raw === "locked" || raw.startsWith("locked ")) current.locked = true;
    else if (raw === "prunable" || raw.startsWith("prunable ")) current.prunable = true;
  }
  flush();
  return records.filter((record) => record.path.length > 0 && !record.bare);
}

function parseStatus(stdout: string): { staged: number; modified: number; untracked: number; conflicted: number } {
  const parts = stdout.split("\0");
  if (parts.length > 0 && parts[parts.length - 1] === "") parts.pop();
  const counts = { staged: 0, modified: 0, untracked: 0, conflicted: 0 };
  for (let index = 0; index < parts.length; index += 1) {
    const entry = parts[index] ?? "";
    if (entry.length < 3 || entry[2] !== " ") continue;
    const x = entry[0] ?? " ";
    const y = entry[1] ?? " ";
    // Rename and copy records carry the other pathname in the next NUL field.
    if (x === "R" || x === "C" || y === "R" || y === "C") index += 1;
    const pair = `${x}${y}`;
    if (UNMERGED.has(pair)) {
      counts.conflicted += 1;
      continue;
    }
    if (pair === "??") {
      counts.untracked += 1;
      continue;
    }
    if (pair === "!!") continue;
    if (x !== " " && x !== "?") counts.staged += 1;
    if (y !== " " && y !== "?") counts.modified += 1;
  }
  return counts;
}

function parseLog(stdout: string): GitCommit[] {
  const fields = stdout.split("\0").map((field) => field.replace(/^\n/, ""));
  while (fields.length > 0 && fields[fields.length - 1] === "") fields.pop();
  const commits: GitCommit[] = [];
  for (let index = 0; index + 2 < fields.length; index += 3) {
    const sha = normalizeSha(fields[index] ?? "");
    const when = (fields[index + 1] ?? "").trim();
    const subject = fields[index + 2] ?? "";
    if (!sha) continue;
    const parsed = Date.parse(when);
    if (Number.isNaN(parsed)) continue;
    commits.push({
      sha,
      subject: sanitizeSubject(subject),
      committedAt: new Date(parsed).toISOString(),
    });
    if (commits.length === 5) break;
  }
  return commits;
}

function isDirectory(candidate: string): boolean {
  try {
    return statSync(candidate).isDirectory();
  } catch {
    return false;
  }
}

function matchesAllowed(wtPath: string, requested: readonly string[], tops: ReadonlySet<string>): boolean {
  const resolved = path.resolve(wtPath);
  let real: string | null = null;
  try {
    real = realpathSync(resolved);
  } catch {
    real = null;
  }
  if (real && tops.has(real)) return true;
  for (const root of requested) {
    const rootResolved = path.resolve(root);
    if (resolved === rootResolved || resolved.startsWith(`${rootResolved}${path.sep}`)) return true;
    if (real && (real === rootResolved || real.startsWith(`${rootResolved}${path.sep}`))) return true;
    if (!isDirectory(rootResolved)) continue;
    const rootReal = identityPath(rootResolved);
    if (real && (real === rootReal || real.startsWith(`${rootReal}${path.sep}`))) return true;
  }
  return false;
}

function failureKind(result: GitRun): FailedRoot["status"] | null {
  if (result.denied) return "unsupported";
  if (result.timedOut) return "timeout";
  if (result.truncated) return "parse_error";
  if (result.code !== 0) return "missing";
  return null;
}

function failureReason(result: GitRun): string {
  if (result.denied) return "command_denied";
  if (result.timedOut) return "timeout";
  if (result.truncated) return "truncated";
  return "not_a_repository";
}

async function collectGit(options: GitSourceOptions, roots: string[], signal: AbortSignal): Promise<{ worktrees: GitWorktree[]; health: SourceHealth }> {
  const now = options.clock.now().toISOString();
  const executable = findGit(options.gitExecutable);
  if (!executable) {
    return { worktrees: [], health: makeHealth("git", "missing", "git_missing", now, null) };
  }
  const privateDir = mkdtempSync(path.join(tmpdir(), "herdr-git-"));
  const runGit = async (args: string[]): Promise<GitRun> => {
    try {
      const result = await options.runner.run(
        {
          executable,
          args: [...GUARD, ...args],
          cwd: privateDir,
          timeoutMs: 8_000,
          maxBytes: 1_048_576,
          allowedEnvironment: {
            PATH: process.env.PATH ?? "",
            HOME: privateDir,
            LANG: "C",
            LC_ALL: "C",
            GIT_CONFIG_NOSYSTEM: "1",
            GIT_CONFIG_GLOBAL: "/dev/null",
            GIT_CONFIG_SYSTEM: "/dev/null",
          },
        },
        signal,
      );
      return { ...result, denied: false };
    } catch (error) {
      if (error instanceof CommandDeniedError) {
        return { code: null, stdout: "", stderr: "", timedOut: false, truncated: false, denied: true };
      }
      throw error;
    }
  };

  try {
    const version = await runGit(["--version"]);
    const cliVersion = version.code === 0 ? (version.stdout.trim().split("\n")[0] ?? "").slice(0, 80) || null : null;
    if (roots.length === 0) {
      return { worktrees: [], health: makeHealth("git", "missing", "no_roots", now, cliVersion) };
    }

    const requested = roots.map((root) => path.resolve(root));
    const tops = new Set<string>();
    const seenCommon = new Set<string>();
    const listed: PorcelainWorktree[] = [];
    const failed: FailedRoot[] = [];

    for (const root of requested) {
      if (!isDirectory(root)) {
        failed.push({ path: root, status: "missing", reason: "not_a_repository" });
        continue;
      }
      const top = await runGit(["-C", root, "rev-parse", "--show-toplevel"]);
      const topKind = failureKind(top);
      if (topKind) {
        failed.push({ path: root, status: topKind === "missing" ? "missing" : topKind, reason: topKind === "missing" ? "not_a_repository" : failureReason(top) });
        continue;
      }
      const toplevel = identityPath(top.stdout.trim());
      tops.add(toplevel);
      const commonResult = await runGit(["-C", toplevel, "rev-parse", "--git-common-dir"]);
      const common = commonResult.code === 0 && !commonResult.truncated && !commonResult.timedOut
        ? identityPath(path.resolve(toplevel, commonResult.stdout.trim()))
        : toplevel;
      if (seenCommon.has(common)) continue;
      seenCommon.add(common);
      const list = await runGit(["-C", toplevel, "worktree", "list", "--porcelain", "-z"]);
      const listKind = failureKind(list);
      if (listKind) {
        failed.push({ path: toplevel, status: listKind === "missing" ? "parse_error" : listKind, reason: listKind === "missing" ? "git_failed" : failureReason(list) });
        continue;
      }
      listed.push(...parseWorktreeList(list.stdout).map((record) => ({ ...record, repositoryKey: common })));
    }

    const seenPaths = new Set<string>();
    const worktrees: GitWorktree[] = [];
    for (const record of listed) {
      const key = identityPath(record.path);
      if (seenPaths.has(key)) continue;
      seenPaths.add(key);
      if (record.path.length > 400) continue;
      const allowed = matchesAllowed(record.path, requested, tops);
      if (!allowed || !existsSync(record.path)) {
        worktrees.push(metadataOnly(record, key, allowed ? "missing" : "disabled", allowed ? "worktree_missing" : "outside_root", now, cliVersion));
        continue;
      }
      worktrees.push(await inspectWorktree(runGit, record, key, now, cliVersion));
    }

    for (const failure of failed) {
      const key = identityPath(failure.path);
      if (seenPaths.has(key) || failure.path.length > 400) continue;
      seenPaths.add(key);
      worktrees.push(metadataOnly(
        { path: failure.path, head: null, branch: null, detached: false, locked: false, prunable: false, bare: false, repositoryKey: failure.path },
        key,
        failure.status,
        failure.reason,
        now,
        cliVersion,
      ));
    }

    worktrees.sort((left, right) => left.path.localeCompare(right.path));
    return { worktrees, health: summarize(worktrees, now, cliVersion) };
  } finally {
    rmSync(privateDir, { recursive: true, force: true });
  }
}

function metadataOnly(
  record: PorcelainWorktree,
  key: string,
  status: SourceHealth["status"],
  reason: string,
  now: string,
  cliVersion: string | null,
): GitWorktree {
  const id = `wt:${digest(key)}`;
  return gitWorktreeSchema.parse({
    id,
    repositoryId: `repo:${digest(record.repositoryKey || key)}`,
    path: record.path,
    branch: cleanBranch(record.detached ? null : record.branch),
    head: record.head,
    detached: record.detached,
    locked: record.locked,
    prunable: record.prunable,
    staged: 0,
    modified: 0,
    untracked: 0,
    conflicted: 0,
    recentCommits: [],
    observedAt: now,
    health: makeHealth(`git:${id}`, status, reason, now, cliVersion),
  });
}

async function inspectWorktree(runGit: (args: string[]) => Promise<GitRun>, record: PorcelainWorktree, key: string, now: string, cliVersion: string | null): Promise<GitWorktree> {
  const id = `wt:${digest(key)}`;
  const repositoryId = `repo:${digest(record.repositoryKey || key)}`;
  const base = {
    id,
    repositoryId,
    path: record.path,
    locked: record.locked,
    prunable: record.prunable,
    observedAt: now,
  };
  const status = await runGit(["-C", record.path, "status", "--porcelain=v1", "-z", "--untracked-files=normal"]);
  const statusKind = failureKind(status);
  if (statusKind) {
    return gitWorktreeSchema.parse({
      ...base,
      branch: cleanBranch(record.detached ? null : record.branch),
      head: record.head,
      detached: record.detached,
      staged: 0,
      modified: 0,
      untracked: 0,
      conflicted: 0,
      recentCommits: [],
      health: makeHealth(`git:${id}`, statusKind === "missing" ? "parse_error" : statusKind, statusKind === "missing" ? "git_failed" : failureReason(status), now, cliVersion),
    });
  }
  const symbolic = await runGit(["-C", record.path, "symbolic-ref", "--quiet", "--short", "HEAD"]);
  const revision = await runGit(["-C", record.path, "rev-parse", "HEAD"]);
  const log = await runGit(["-C", record.path, "log", "-5", "--format=%H%x00%cI%x00%s%x00"]);
  const branch = symbolic.code === 0 ? cleanBranch(symbolic.stdout.trim()) : null;
  const head = revision.code === 0 ? normalizeSha(revision.stdout) : null;
  const detached = branch === null && head !== null;
  const unborn = branch !== null && head === null;
  let healthStatus: SourceHealth["status"] = "ok";
  let reason = unborn ? "unborn" : "observed";
  if (symbolic.timedOut || revision.timedOut || log.timedOut) {
    healthStatus = "timeout";
    reason = "timeout";
  } else if (symbolic.truncated || revision.truncated || log.truncated) {
    healthStatus = "parse_error";
    reason = "truncated";
  } else if (branch === null && head === null) {
    healthStatus = "parse_error";
    reason = "head_unreadable";
  }
  const counts = parseStatus(status.stdout);
  const recentCommits = log.code === 0 && !log.truncated && !log.timedOut ? parseLog(log.stdout) : [];
  return gitWorktreeSchema.parse({
    ...base,
    branch,
    head,
    detached,
    ...counts,
    recentCommits,
    health: makeHealth(`git:${id}`, healthStatus, reason, now, cliVersion),
  });
}

function summarize(worktrees: readonly GitWorktree[], now: string, cliVersion: string | null): SourceHealth {
  if (worktrees.length === 0) return makeHealth("git", "missing", "no_repository", now, cliVersion);
  const relevant = worktrees.filter((entry) => entry.health.reasonCode !== "outside_root");
  if (relevant.some((entry) => entry.health.status === "ok")) return makeHealth("git", "ok", "observed", now, cliVersion);
  const sample = relevant[0] ?? worktrees[0];
  if (!sample) return makeHealth("git", "missing", "no_repository", now, cliVersion);
  return makeHealth("git", sample.health.status, sample.health.reasonCode, now, cliVersion);
}
