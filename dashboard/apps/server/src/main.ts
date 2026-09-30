import path from "node:path";
import type { Server } from "node:http";
import { FIXTURE_NOW, type DashboardSnapshot } from "@herdr/contracts";
import { loadConfigFile, type DashboardConfig } from "./config.js";
import { createDashboardServer } from "./http.js";
import { createRuntimeCollectors, createScheduler, frozenSchedulerClock, wallSchedulerClock, type Scheduler, type SchedulerClock } from "./scheduler.js";
import { isLoopbackHost } from "./security.js";
import type { DashboardStore } from "./storage/repository.js";
import { openStore } from "./storage/repository.js";

export interface CliOptions {
  /** Null when the flag is absent, so the config value applies. */
  host: string | null;
  port: number | null;
  fixtureFlag: boolean;
  configPath: string | null;
  databasePath: string | null;
}

export interface RunningDashboard {
  server: Server;
  scheduler: Scheduler;
  store: DashboardStore;
}

export function parseCli(argv: readonly string[]): CliOptions {
  let host: string | null = null;
  let port: number | null = null;
  let fixtureFlag = false;
  let configPath: string | null = null;
  let databasePath: string | null = null;
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--host") {
      host = argv[i + 1] ?? "";
      i += 1;
    } else if (arg === "--port") {
      port = Number(argv[i + 1]);
      i += 1;
    } else if (arg === "--config") {
      const value = argv[i + 1];
      if (!value) throw new Error("missing --config path");
      configPath = value;
      i += 1;
    } else if (arg === "--database") {
      const value = argv[i + 1];
      if (!value) throw new Error("missing --database path");
      databasePath = value;
      i += 1;
    } else if (arg === "--fixture") {
      fixtureFlag = true;
    } else if (arg === "--help") {
      process.stdout.write(
        "usage: herdr-dashboard [--host 127.0.0.1] [--port 4317] [--config file] [--database file] [--fixture]\n",
      );
      process.exit(0);
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  if (port !== null && (!Number.isInteger(port) || port < 1 || port > 65535)) {
    throw new Error("port must be an integer from 1 to 65535");
  }
  return { host, port, fixtureFlag, configPath, databasePath };
}

/** Flags win over the config file. Either way the host must be loopback. */
export function resolveBind(cli: Pick<CliOptions, "host" | "port">, config: Pick<DashboardConfig, "host" | "port">): { host: string; port: number } {
  const host = cli.host ?? config.host;
  if (!isLoopbackHost(host)) {
    throw new Error("refusing non-loopback host");
  }
  return { host, port: cli.port ?? config.port };
}

export function resolveMode(
  env: NodeJS.ProcessEnv,
  fixtureFlag: boolean,
  configured: "passive" | "live" | "fixture" = "passive",
): "passive" | "live" | "fixture" {
  if ((fixtureFlag || configured === "fixture") && env.HERDR_FIXTURE !== "1") {
    throw new Error("refusing --fixture without HERDR_FIXTURE=1");
  }
  if (env.HERDR_FIXTURE === "1" || fixtureFlag) {
    if (env.HERDR_ALLOW_NETWORK !== "0") {
      throw new Error("refusing fixture mode without HERDR_ALLOW_NETWORK=0");
    }
    return "fixture";
  }
  return configured === "live" ? "live" : "passive";
}

export function repoRootFrom(importMetaUrl: string): string {
  const here = path.dirname(filePathFromUrl(importMetaUrl));
  return path.resolve(here, "../../..");
}

/** `--database` wins. Otherwise an explicit state directory keeps the sqlite file out of the repo. */
export function resolveDatabaseFile(env: NodeJS.ProcessEnv, root: string, cliPath: string | null): string {
  if (cliPath) return cliPath;
  const stateDir = env.HERDR_STATE_DIR;
  if (typeof stateDir === "string" && stateDir.trim() !== "") {
    return path.join(stateDir, "dashboard.sqlite");
  }
  return path.join(root, ".local", "dashboard.sqlite");
}

function filePathFromUrl(value: string): string {
  if (value.startsWith("file:")) {
    return path.normalize(decodeURIComponent(new URL(value).pathname));
  }
  return value;
}

export function launchDashboard(options: {
  host: string;
  port: number;
  webDist: string;
  config: DashboardConfig;
  mode: DashboardSnapshot["mode"];
  databaseFile: string;
  dev?: boolean;
  clock?: SchedulerClock;
}): RunningDashboard {
  const clock = options.clock ?? (options.mode === "fixture" ? frozenSchedulerClock(FIXTURE_NOW) : wallSchedulerClock());
  const store = openStore({ file: options.databaseFile, clock });
  const collectors = createRuntimeCollectors({ config: options.config, mode: options.mode, clock });
  const scheduler = createScheduler({
    clock,
    store,
    mode: options.mode,
    poll: options.config.poll,
    quota: collectors.quota,
    herdr: collectors.herdr,
    tmux: collectors.tmux,
    git: collectors.git,
    roots: collectors.roots,
    probesEnabled: options.mode === "fixture" ? false : options.config.quotaProbesEnabled,
  });
  const server = createDashboardServer({
    host: options.host,
    port: options.port,
    webDist: options.webDist,
    mode: options.mode,
    dev: options.dev === true,
    snapshots: scheduler,
  });
  return { server, scheduler, store };
}

export function startFromCli(argv: readonly string[], env: NodeJS.ProcessEnv = process.env): void {
  const cli = parseCli(argv);
  if (cli.host !== null && !isLoopbackHost(cli.host)) {
    throw new Error("refusing non-loopback host");
  }
  const root = repoRootFrom(import.meta.url);
  const loaded = loadConfigFile(cli.configPath ?? path.join(root, "config/dashboard.example.json"), env);
  const mode = resolveMode(env, cli.fixtureFlag, loaded.mode);
  const bind = resolveBind(cli, loaded);
  const config = { ...loaded, ...bind, mode };
  const running = launchDashboard({
    host: bind.host,
    port: bind.port,
    webDist: path.join(root, "apps/web/dist"),
    config,
    mode,
    databaseFile: resolveDatabaseFile(env, root, cli.databasePath),
    dev: env.HERDR_DEV === "1",
  });
  let shuttingDown = false;
  const shutdown = (): void => {
    if (shuttingDown) return;
    shuttingDown = true;
    const timer = setTimeout(() => process.exit(), 2000);
    timer.unref();
    void running.scheduler.stop().finally(() => {
      try {
        running.store.close();
      } catch {
        // The store may already be closed during a failed startup.
      }
      running.server.close(() => process.exit());
      // Open SSE streams would otherwise hold close() until the 2 second fallback.
      running.server.closeAllConnections();
    });
  };
  const starting = running.scheduler.start();
  starting.catch((error: unknown) => {
    const message = error instanceof Error ? error.message : "scheduler failed";
    process.stderr.write(`${message}\n`);
    process.exitCode = 1;
    shutdown();
  });
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
  running.server.on("error", (error: NodeJS.ErrnoException) => {
    process.stderr.write(`cannot listen on ${bind.host}:${bind.port}: ${error.code ?? error.message}\n`);
    process.exitCode = 1;
    shutdown();
  });
  running.server.listen(bind.port, bind.host, () => {
    process.stdout.write(`listening ${bind.host}:${bind.port}\n`);
  });
}

const invokedDirectly = process.argv[1] && path.resolve(process.argv[1]) === filePathFromUrl(import.meta.url);
if (invokedDirectly) {
  try {
    startFromCli(process.argv.slice(2));
  } catch (error) {
    const message = error instanceof Error ? error.message : "startup failed";
    process.stderr.write(`${message}\n`);
    process.exit(1);
  }
}
