import { readFileSync, readlinkSync } from "node:fs";
import type { ProcessFacts } from "./identity.js";

function readStat(pid: number): { ppid: number; startTicks: number } | null {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
    const after = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
    const ppid = Number(after[1]);
    const startTicks = Number(after[19]);
    if (!Number.isInteger(ppid) || !Number.isInteger(startTicks)) return null;
    return { ppid, startTicks };
  } catch {
    return null;
  }
}

export function inspectProcess(pid: number): ProcessFacts | null {
  if (!Number.isInteger(pid) || pid <= 0) return null;
  try {
    const raw = readFileSync(`/proc/${pid}/cmdline`).subarray(0, 65_536);
    const argv = raw.toString("utf8").split("\0").filter((part) => part.length > 0);
    const stat = readStat(pid);
    if (argv.length === 0 || !stat) return null;
    let cwd: string | null = null;
    try {
      cwd = readlinkSync(`/proc/${pid}/cwd`);
    } catch {
      cwd = null;
    }
    return { argv, cwd, startTicks: stat.startTicks, ppid: stat.ppid > 0 ? stat.ppid : null };
  } catch {
    return null;
  }
}
