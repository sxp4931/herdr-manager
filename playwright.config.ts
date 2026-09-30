import { mkdirSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { defineConfig } from "@playwright/test";

const stateDir = path.join(os.tmpdir(), "herdr-dashboard-playwright");
mkdirSync(stateDir, { recursive: true });

export default defineConfig({
  testDir: "tests/e2e",
  fullyParallel: false,
  workers: 1,
  retries: process.env.CI ? 1 : 0,
  forbidOnly: Boolean(process.env.CI),
  reporter: "list",
  use: {
    baseURL: "http://127.0.0.1:14318",
    headless: true,
    trace: "off",
    screenshot: "off",
    video: "off",
  },
  webServer: {
    command: "node apps/server/dist/main.js --fixture --host 127.0.0.1 --port 14318",
    url: "http://127.0.0.1:14318/api/health",
    reuseExistingServer: false,
    timeout: 30_000,
    env: {
      ...process.env,
      HERDR_FIXTURE: "1",
      HERDR_ALLOW_NETWORK: "0",
      HERDR_FIXTURE_NOW: "2026-09-29T16:00:00.000Z",
      HERDR_STATE_DIR: stateDir,
    },
  },
});
