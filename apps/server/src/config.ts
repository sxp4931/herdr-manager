import { readFileSync, statSync } from "node:fs";
import path from "node:path";
import { z } from "zod";

const providerSchema = z
  .object({
    executable: z.string().min(1).max(200),
    profile: z.string().min(1).max(80).nullable(),
  })
  .strict();

export const dashboardConfigSchema = z
  .object({
    schemaVersion: z.literal(1),
    host: z.string().min(1).max(80),
    port: z.number().int().min(1).max(65535),
    timezone: z.string().min(1).max(80),
    mode: z.enum(["passive", "live", "fixture"]),
    repositoryRoots: z.array(z.string().min(1).max(400)).max(32),
    herdrSocket: z.string().min(1).max(400).nullable(),
    tmuxSocket: z.string().min(1).max(400).nullable(),
    quotaProbesEnabled: z.boolean(),
    providers: z
      .object({
        claude: providerSchema,
        codex: providerSchema,
        grok: providerSchema,
      })
      .strict(),
    poll: z
      .object({
        sessionsSeconds: z.number().int().min(10).max(3600),
        gitSeconds: z.number().int().min(30).max(3600),
        quotaSeconds: z.number().int().min(300).max(86400),
      })
      .strict(),
  })
  .strict();

export type DashboardConfig = z.infer<typeof dashboardConfigSchema>;

export function loadConfig(input: unknown, env: NodeJS.ProcessEnv = process.env): DashboardConfig {
  const parsed = dashboardConfigSchema.parse(input);
  if (parsed.host !== "127.0.0.1" && parsed.host !== "localhost") {
    throw new Error("non-loopback host rejected");
  }
  if (parsed.mode === "fixture" && env.HERDR_FIXTURE !== "1") {
    throw new Error("fixture mode requires HERDR_FIXTURE=1");
  }
  if (parsed.mode === "live" && env.HERDR_FIXTURE !== "1" && !parsed.quotaProbesEnabled) {
    throw new Error("live mode requires quota probes");
  }
  for (const root of parsed.repositoryRoots) {
    if (!path.isAbsolute(root)) {
      throw new Error("repository root must be absolute");
    }
    let info;
    try {
      info = statSync(root);
    } catch {
      throw new Error("repository root is not an existing directory");
    }
    if (!info.isDirectory()) {
      throw new Error("repository root is not an existing directory");
    }
  }
  if (env.HERDR_FIXTURE === "1") {
    return { ...parsed, mode: "fixture" };
  }
  return parsed;
}

export function loadConfigFile(file: string, env: NodeJS.ProcessEnv = process.env): DashboardConfig {
  return loadConfig(JSON.parse(readFileSync(file, "utf8")) as unknown, env);
}

export function defaultConfigPath(): string {
  return path.resolve("config/dashboard.example.json");
}
