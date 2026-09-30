import path from "node:path";

export const PROVIDERS = ["claude", "codex", "grok"] as const;
export type ProviderName = (typeof PROVIDERS)[number];

const NODE_BINARIES = new Set(["node", "nodejs"]);

export interface ProcessFacts {
  argv: string[];
  cwd: string | null;
  startTicks: number;
  ppid: number | null;
}

export interface ProcessLookup {
  inspect(pid: number): ProcessFacts | null;
}

export interface ProviderMatch {
  provider: ProviderName;
  pid: number;
  facts: ProcessFacts;
}

function basename(value: string): string {
  return path.basename(value).toLowerCase();
}

function providerName(value: string): ProviderName | null {
  const name = basename(value).replace(/\.exe$/, "");
  if (name === "claude" || name === "codex" || name === "grok") return name;
  return null;
}

/** Recognize a provider executable, including a Node wrapper whose script basename is the CLI. */
export function providerFromArgv(argv: readonly string[]): ProviderName | null {
  const command = argv[0];
  if (!command) return null;
  const direct = providerName(command);
  if (direct) return direct;
  if (!NODE_BINARIES.has(basename(command))) return null;
  for (const arg of argv.slice(1)) {
    if (arg.startsWith("-")) continue;
    const provider = providerName(arg);
    if (provider) return provider;
  }
  return null;
}

/**
 * Classify the pane process. A shell is not an agent.
 * Walk only continues through Node so a wrapper's parent can be inspected,
 * and stops at the first non-Node command that is not itself a provider.
 */
export function findProvider(pid: number, lookup: ProcessLookup): ProviderMatch | null {
  let current = pid;
  const seen = new Set<number>();
  for (let hop = 0; hop < 6 && current > 1 && !seen.has(current); hop += 1) {
    seen.add(current);
    const facts = lookup.inspect(current);
    if (!facts || facts.argv.length === 0) return null;
    const provider = providerFromArgv(facts.argv);
    if (provider) return { provider, pid: current, facts };
    if (!NODE_BINARIES.has(basename(facts.argv[0] ?? ""))) return null;
    if (facts.ppid === null) return null;
    current = facts.ppid;
  }
  return null;
}
