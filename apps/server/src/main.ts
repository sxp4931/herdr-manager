import path from "node:path";
import { createDashboardServer } from "./http.js";
import { isLoopbackHost } from "./security.js";

export interface CliOptions {
  host: string;
  port: number;
  fixtureFlag: boolean;
}

export function parseCli(argv: readonly string[]): CliOptions {
  let host = "127.0.0.1";
  let port = 4317;
  let fixtureFlag = false;
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--host") {
      host = argv[i + 1] ?? "";
      i += 1;
    } else if (arg === "--port") {
      port = Number(argv[i + 1]);
      i += 1;
    } else if (arg === "--fixture") {
      fixtureFlag = true;
    } else if (arg === "--help") {
      process.stdout.write("usage: herdr-dashboard [--host 127.0.0.1] [--port 4317] [--fixture]\n");
      process.exit(0);
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error("port must be an integer from 1 to 65535");
  }
  return { host, port, fixtureFlag };
}

export function resolveMode(env: NodeJS.ProcessEnv, fixtureFlag: boolean): "passive" | "live" | "fixture" {
  if (fixtureFlag && env.HERDR_FIXTURE !== "1") {
    throw new Error("refusing --fixture without HERDR_FIXTURE=1");
  }
  if (env.HERDR_FIXTURE === "1") {
    return "fixture";
  }
  return "passive";
}

export function repoRootFrom(importMetaUrl: string): string {
  const here = path.dirname(filePathFromUrl(importMetaUrl));
  return path.resolve(here, "../../..");
}

function filePathFromUrl(value: string): string {
  if (value.startsWith("file:")) {
    return path.normalize(decodeURIComponent(new URL(value).pathname));
  }
  return value;
}

export function startFromCli(argv: readonly string[], env: NodeJS.ProcessEnv = process.env): void {
  const cli = parseCli(argv);
  if (!isLoopbackHost(cli.host)) {
    throw new Error("refusing non-loopback host");
  }
  const mode = resolveMode(env, cli.fixtureFlag);
  const root = repoRootFrom(import.meta.url);
  const server = createDashboardServer({
    host: cli.host,
    port: cli.port,
    webDist: path.join(root, "apps/web/dist"),
    mode,
  });
  let shuttingDown = false;
  const shutdown = (): void => {
    if (shuttingDown) {
      return;
    }
    shuttingDown = true;
    const timer = setTimeout(() => process.exit(0), 2000);
    timer.unref();
    server.close(() => process.exit(0));
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
  server.listen(cli.port, cli.host, () => {
    process.stdout.write(`listening ${cli.host}:${cli.port}\n`);
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
