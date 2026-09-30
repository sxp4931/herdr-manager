import { existsSync } from "node:fs";
import path from "node:path";

const providers = ["claude", "codex", "grok"];

function which(name) {
  for (const segment of (process.env.PATH ?? "").split(path.delimiter)) {
    if (!segment) continue;
    const candidate = path.join(segment, name);
    if (existsSync(candidate)) return true;
  }
  return false;
}

if (process.argv.includes("--live")) {
  process.stderr.write("live probes are disabled in the capability doctor\n");
  process.exit(2);
}

const report = {
  quotaProbesEnabled: false,
  providers: providers.map((provider) => {
    const available = which(provider);
    return {
      provider,
      available,
      status: available ? "present" : "missing",
      liveProbe: false,
    };
  }),
};

process.stdout.write(`${JSON.stringify(report)}\n`);
