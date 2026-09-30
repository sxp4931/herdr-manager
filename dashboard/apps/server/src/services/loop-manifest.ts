import { lstatSync, readFileSync, realpathSync, statSync } from "node:fs";
import path from "node:path";
import { loopManifestSchema, type LoopManifest } from "@herdr/contracts";
import { redactText } from "./redaction.js";

const MAX_BYTES = 16 * 1024;
const FRESH_MS = 30_000;

export type ManifestRead =
  | { ok: true; manifest: LoopManifest }
  | { ok: false; reason: "missing" | "escape" | "oversize" | "invalid" | "stale" };

function insideRoot(root: string, candidate: string): boolean {
  return candidate === root || candidate.startsWith(`${root}${path.sep}`);
}

function resolveContained(root: string): string | null {
  let current = root;
  for (const part of [".herdr-dashboard", "run.json"]) {
    const next = path.join(current, part);
    let info;
    try {
      info = lstatSync(next);
    } catch {
      return null;
    }
    if (info.isSymbolicLink()) {
      let target: string;
      try {
        target = realpathSync(next);
      } catch {
        return null;
      }
      if (!insideRoot(root, target)) return null;
      current = target;
      continue;
    }
    current = next;
  }
  try {
    const finalPath = realpathSync(current);
    if (!insideRoot(root, finalPath)) return null;
    return finalPath;
  } catch {
    return null;
  }
}

export function readLoopManifest(worktree: string, now: Date): ManifestRead {
  let root: string;
  try {
    root = realpathSync(worktree);
  } catch {
    return { ok: false, reason: "missing" };
  }
  const file = resolveContained(root);
  if (!file) {
    const direct = path.join(root, ".herdr-dashboard", "run.json");
    try {
      const linkParent = path.join(root, ".herdr-dashboard");
      if (lstatSync(linkParent).isSymbolicLink() || lstatSync(direct).isSymbolicLink()) {
        return { ok: false, reason: "escape" };
      }
    } catch {
      return { ok: false, reason: "missing" };
    }
    return { ok: false, reason: "missing" };
  }
  let info;
  try {
    info = statSync(file);
  } catch {
    return { ok: false, reason: "missing" };
  }
  if (!info.isFile() || info.size > MAX_BYTES) return { ok: false, reason: "oversize" };
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(file, "utf8")) as unknown;
  } catch {
    return { ok: false, reason: "invalid" };
  }
  const result = loopManifestSchema.safeParse(parsed);
  if (!result.success) return { ok: false, reason: "invalid" };
  const age = now.getTime() - Date.parse(result.data.updatedAt);
  if (Number.isNaN(age) || age > FRESH_MS) return { ok: false, reason: "stale" };
  const objective = result.data.objective === null ? null : redactText(result.data.objective).slice(0, 160);
  const sessionIdentity = redactText(result.data.sessionIdentity).slice(0, 120).trim();
  if (sessionIdentity.length === 0) return { ok: false, reason: "invalid" };
  return {
    ok: true,
    manifest: {
      ...result.data,
      sessionIdentity,
      objective: objective === "" ? null : objective,
    },
  };
}
