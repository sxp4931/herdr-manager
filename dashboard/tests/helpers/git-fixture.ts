import { spawnSync } from "node:child_process";
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

export interface ActivityFixture {
  directory: string;
  repo: string;
  feature: string;
  outside: string;
  mainHead: string;
  featureHead: string;
  mainCommittedAt: string;
  featureCommittedAt: string;
  cleanup: () => void;
}

export interface ConflictFixture {
  directory: string;
  repo: string;
  cleanup: () => void;
}

export interface StateFixture {
  directory: string;
  detached: string;
  detachedHead: string;
  unborn: string;
  lockedRepo: string;
  locked: string;
  missing: string;
  empty: string;
  cleanup: () => void;
}

export function gitExecutable(): string {
  for (const segment of (process.env.PATH ?? "").split(path.delimiter)) {
    if (!segment) continue;
    const candidate = path.join(segment, "git");
    if (existsSync(candidate)) return candidate;
  }
  throw new Error("git is not on PATH");
}

function run(git: string, args: string[]): string {
  const result = spawnSync(git, args, { encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(`git ${args.join(" ")} failed (${String(result.status)}): ${result.stderr}`);
  }
  return result.stdout.trim();
}

function initRepo(git: string, directory: string): void {
  run(git, ["init", "-b", "main", directory]);
  run(git, ["-C", directory, "config", "user.name", "Dashboard Fixture"]);
  run(git, ["-C", directory, "config", "user.email", "fixture@example.invalid"]);
}

function commitFile(git: string, directory: string, file: string, contents: string, message: string): void {
  writeFileSync(path.join(directory, file), contents);
  run(git, ["-C", directory, "add", file]);
  run(git, ["-C", directory, "commit", "-m", message]);
}

function isoCommit(git: string, directory: string): string {
  return new Date(run(git, ["-C", directory, "log", "-1", "--format=%cI"])).toISOString();
}

export function createActivityFixture(): ActivityFixture {
  const git = gitExecutable();
  const directory = mkdtempSync(path.join(tmpdir(), "herdr-gitfix-"));
  const repo = path.join(directory, "repo");
  const feature = path.join(directory, "feature");
  const outside = path.join(directory, "outside");
  initRepo(git, repo);
  commitFile(git, repo, "README", "one\n", "first commit");
  appendFileSync(path.join(repo, "README"), "two\n");
  run(git, ["-C", repo, "commit", "-am", "second SYNTHETIC_SECRET_SENTINEL"]);
  mkdirSync(path.join(repo, "sub"));
  writeFileSync(path.join(repo, "sub", "has space.txt"), "staged\n");
  run(git, ["-C", repo, "add", path.join("sub", "has space.txt")]);
  appendFileSync(path.join(repo, "README"), "dirty\n");
  writeFileSync(path.join(repo, "weird\nname.txt"), "untracked\n");
  run(git, ["-C", repo, "worktree", "add", "-b", "feature", feature, "HEAD"]);
  commitFile(git, feature, "FEATURE", "note\n", "feature commit");
  run(git, ["-C", feature, "mv", "README", "README-renamed"]);
  writeFileSync(path.join(feature, "overlap.txt"), "base\n");
  run(git, ["-C", feature, "add", "overlap.txt"]);
  appendFileSync(path.join(feature, "overlap.txt"), "more\n");
  run(git, ["-C", repo, "worktree", "add", "-b", "elsewhere", outside, "HEAD"]);
  return {
    directory,
    repo,
    feature,
    outside,
    mainHead: run(git, ["-C", repo, "rev-parse", "HEAD"]),
    featureHead: run(git, ["-C", feature, "rev-parse", "HEAD"]),
    mainCommittedAt: isoCommit(git, repo),
    featureCommittedAt: isoCommit(git, feature),
    cleanup: () => rmSync(directory, { recursive: true, force: true }),
  };
}

export function createConflictFixture(): ConflictFixture {
  const git = gitExecutable();
  const directory = mkdtempSync(path.join(tmpdir(), "herdr-gitconflict-"));
  const repo = path.join(directory, "repo");
  initRepo(git, repo);
  commitFile(git, repo, "f", "a\n", "base");
  run(git, ["-C", repo, "checkout", "-b", "other"]);
  writeFileSync(path.join(repo, "f"), "b\n");
  run(git, ["-C", repo, "commit", "-am", "other"]);
  run(git, ["-C", repo, "checkout", "main"]);
  writeFileSync(path.join(repo, "f"), "c\n");
  run(git, ["-C", repo, "commit", "-am", "main side"]);
  const merge = spawnSync(git, ["-C", repo, "merge", "other"], { encoding: "utf8" });
  if (merge.status === 0) throw new Error("expected a conflict fixture to stop before commit");
  return {
    directory,
    repo,
    cleanup: () => rmSync(directory, { recursive: true, force: true }),
  };
}

export function createStateFixture(): StateFixture {
  const git = gitExecutable();
  const directory = mkdtempSync(path.join(tmpdir(), "herdr-gitstate-"));
  const detached = path.join(directory, "detached");
  const unborn = path.join(directory, "unborn");
  const lockedRepo = path.join(directory, "locked-repo");
  const locked = path.join(directory, "locked");
  const missing = path.join(directory, "missing");
  const empty = path.join(directory, "empty");
  initRepo(git, detached);
  commitFile(git, detached, "README", "base\n", "detached base");
  run(git, ["-C", detached, "checkout", "--detach"]);
  initRepo(git, unborn);
  writeFileSync(path.join(unborn, "note.txt"), "pending\n");
  initRepo(git, lockedRepo);
  commitFile(git, lockedRepo, "README", "base\n", "locked base");
  run(git, ["-C", lockedRepo, "worktree", "add", "-b", "locked-branch", locked, "HEAD"]);
  run(git, ["-C", lockedRepo, "worktree", "lock", locked]);
  run(git, ["-C", lockedRepo, "worktree", "add", "-b", "gone", missing, "HEAD"]);
  rmSync(missing, { recursive: true, force: true });
  mkdirSync(empty);
  return {
    directory,
    detached,
    detachedHead: run(git, ["-C", detached, "rev-parse", "HEAD"]),
    unborn,
    lockedRepo,
    locked,
    missing,
    empty,
    cleanup: () => rmSync(directory, { recursive: true, force: true }),
  };
}
