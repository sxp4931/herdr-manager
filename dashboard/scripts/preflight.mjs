import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import path from "node:path";
import process from "node:process";

const requireCore = process.argv.includes("--require-core");

function which(name) {
  const segments = (process.env.PATH ?? "").split(path.delimiter);
  for (const segment of segments) {
    if (!segment) continue;
    const candidate = path.join(segment, name);
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

function pythonVersion() {
  const python = which("python3");
  if (!python) return null;
  const result = spawnSync(python, ["-c", "import sys; print('%d.%d.%d' % sys.version_info[:3])"], {
    encoding: "utf8",
  });
  if (result.status !== 0) return null;
  return result.stdout.trim();
}

function sqliteWorks() {
  try {
    const db = new DatabaseSync(":memory:");
    db.exec("create table probe (id integer)");
    db.close();
    return true;
  } catch {
    return false;
  }
}

function venvPyteReady() {
  const python = path.resolve(".venv/bin/python");
  if (!existsSync(python)) return false;
  const result = spawnSync(python, ["-c", "import pyte, wcwidth"], { encoding: "utf8" });
  return result.status === 0;
}

async function chromiumReady() {
  try {
    const mod = await import("@playwright/test");
    const executable = mod.chromium.executablePath();
    return existsSync(executable);
  } catch {
    return false;
  }
}

const nodeVersion = process.version;
const nodeOk = /^v22\.\d+\.\d+$/.test(nodeVersion);
const platform = process.platform;
const sqlite = sqliteWorks();
const py = pythonVersion();
const pyOk = py !== null && /^3\.(1[0-3])\./.test(`${py}.`);
const optionalNames = ["claude", "codex", "grok", "tmux", "herdr"];
const optional = {};
for (const name of optionalNames) {
  optional[name] = { available: which(name) !== null };
}

const baseReady = platform === "linux" && nodeOk && sqlite && pyOk;
let coreReady = baseReady;
const missing = [];
if (requireCore) {
  if (!venvPyteReady()) {
    coreReady = false;
    missing.push("venv-pyte");
  }
  if (!(await chromiumReady())) {
    coreReady = false;
    missing.push("chromium");
  }
  if (!baseReady) {
    coreReady = false;
    missing.push("runtime");
  }
}

const report = {
  coreReady: requireCore ? coreReady : baseReady,
  platform,
  node: nodeVersion,
  python: py,
  sqlite,
  optional,
  missing,
};

process.stdout.write(`${JSON.stringify(report)}\n`);
if (requireCore && !report.coreReady) {
  process.exit(1);
}
