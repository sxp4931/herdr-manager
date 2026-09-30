import { existsSync } from "node:fs";
import path from "node:path";

// `--version` and `--help` are the only diagnostic arguments. Live profiles stay
// unlaunched until startup hooks and MCP are proven inert, so this process
// never spawns claude, codex, or grok.
const DIAGNOSTIC_ARGV = ["--version", "--help"];
const PROVIDERS = ["claude", "codex", "grok"];
const REFUSAL = "startup hooks and MCP are not proven inert";

function which(name) {
  for (const segment of (process.env.PATH ?? "").split(path.delimiter)) {
    if (!segment) continue;
    const candidate = path.join(segment, name);
    if (existsSync(candidate)) return true;
  }
  return false;
}

const known = new Set(["--json", "--live"]);
for (const arg of process.argv.slice(2)) {
  if (!known.has(arg)) {
    process.stderr.write("unknown doctor argument\n");
    process.exit(2);
  }
}

const live = process.argv.includes("--live");
const providers = PROVIDERS.map((provider) => {
  const available = which(provider);
  if (!available) {
    return {
      provider,
      available: false,
      status: "missing",
      liveProbe: false,
      diagnostic: live ? "missing" : "not_requested",
    };
  }
  if (!live) {
    return {
      provider,
      available: true,
      status: "present",
      liveProbe: false,
      diagnostic: "not_requested",
    };
  }
  return {
    provider,
    available: true,
    status: "profile_unsafe",
    liveProbe: false,
    diagnostic: "refused",
    reason: REFUSAL,
  };
});

const report = {
  quotaProbesEnabled: false,
  diagnosticAllowlist: DIAGNOSTIC_ARGV,
  executed: [],
  executedCount: 0,
  providers,
};

process.stdout.write(`${JSON.stringify(report)}\n`);
