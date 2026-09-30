import { spawnSync } from "node:child_process";
import { cpSync, mkdirSync } from "node:fs";
import path from "node:path";
import { build } from "esbuild";

await build({
  entryPoints: ["apps/server/src/main.ts"],
  outfile: "apps/server/dist/main.js",
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node22",
  legalComments: "none",
  sourcemap: false,
});

mkdirSync("apps/server/dist/migrations", { recursive: true });
cpSync("apps/server/src/storage/migrations/001.sql", "apps/server/dist/migrations/001.sql");

const viteBin = path.resolve("node_modules/vite/bin/vite.js");
const vite = spawnSync(process.execPath, [viteBin, "build"], {
  cwd: path.resolve("apps/web"),
  stdio: "inherit",
});
if (vite.status !== 0) {
  process.exit(vite.status ?? 1);
}
