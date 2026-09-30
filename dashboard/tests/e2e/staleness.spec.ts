import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { expect, test, type Page } from "@playwright/test";
import { expectQuiet, watchPage } from "./guard.js";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

function readSnapshot(name: string): Record<string, unknown> {
  const parsed: unknown = JSON.parse(readFileSync(path.join(root, "tests/fixtures/usage", name), "utf8"));
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error(`fixture ${name} is not an object`);
  }
  return structuredClone(parsed) as Record<string, unknown>;
}

async function fulfillSnapshot(page: Page, snapshot: unknown): Promise<void> {
  const body = JSON.stringify(snapshot);
  await page.route("**/api/snapshot", async (route) => {
    await route.fulfill({ status: 200, contentType: "application/json", body });
  });
  await page.route("**/api/events", async (route) => {
    await route.fulfill({
      status: 200,
      contentType: "text/event-stream",
      body: "",
    });
  });
}

test("stale last-known quota keeps its original sample time", async ({ page }) => {
  const guards = watchPage(page);
  await fulfillSnapshot(page, readSnapshot("stale.json"));
  await page.goto("/");
  const claude = page.getByRole("region", { name: "Claude", exact: true });
  await expect(claude).toContainText("Stale");
  await expect(claude).toContainText("2026-09-29T15:45:00.000Z");
  await expect(claude).toContainText("10% used, 90% left");
  await expect(claude.locator("progress.meter-stale")).toHaveCount(2);
  await expect(claude.locator("progress.meter-fresh")).toHaveCount(0);
  await expect(claude).not.toContainText("Health Fresh");
  await expect(page.locator("progress.meter-fresh")).toHaveCount(0);
  await expect(page.getByRole("region", { name: "Codex", exact: true })).toContainText("Unknown");
  await expect(page.getByRole("region", { name: "Grok", exact: true })).toContainText("Unknown");
  await expect(page.getByRole("status").filter({ hasText: "Demo data" })).toBeVisible();
  expectQuiet(guards);
});

test("missing quota says unknown and does not draw a zero meter", async ({ page }) => {
  const guards = watchPage(page);
  await fulfillSnapshot(page, readSnapshot("missing.json"));
  await page.goto("/");
  await expect(page.getByRole("region", { name: "Claude", exact: true })).toContainText("Unknown");
  await expect(page.getByRole("region", { name: "Codex", exact: true })).toContainText("Unknown");
  await expect(page.getByRole("region", { name: "Grok", exact: true })).toContainText("Unknown");
  await expect(page.getByText("Health Missing").first()).toBeVisible();
  await expect(page.locator("progress")).toHaveCount(0);
  const text = await page.locator("main").innerText();
  expect(text).not.toMatch(/(^|[^0-9.])0%/);
  expect(text).not.toContain("Not applicable");
  expectQuiet(guards);
});

test("disabled probes stay distinct from missing numbers", async ({ page }) => {
  const guards = watchPage(page);
  const snapshot = readSnapshot("missing.json");
  snapshot.mode = "passive";
  for (const key of ["providers", "sources"] as const) {
    const rows = snapshot[key];
    if (!Array.isArray(rows)) throw new Error(`missing ${key}`);
    for (const row of rows) {
      if (typeof row !== "object" || row === null) continue;
      const record = row as Record<string, unknown>;
      const health = key === "providers" ? record.health : record;
      if (typeof health !== "object" || health === null) continue;
      const status = health as Record<string, unknown>;
      status.status = "disabled";
      status.reasonCode = "probes_disabled";
    }
  }
  await fulfillSnapshot(page, snapshot);
  await page.goto("/");
  await expect(page.getByText("Disabled").first()).toBeVisible();
  await expect(page.getByRole("status").filter({ hasText: "Probes disabled" })).toBeVisible();
  await expect(page.locator("progress")).toHaveCount(0);
  await expect(page.getByText("Demo data")).toHaveCount(0);
  const text = await page.locator("main").innerText();
  expect(text).not.toMatch(/(^|[^0-9.])0%/);
  expectQuiet(guards);
});

test("shows loading, empty, and unavailable states", async ({ page }) => {
  const guards = watchPage(page);
  let release = (): void => undefined;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  const body = JSON.stringify(readSnapshot("stale.json"));
  await page.route("**/api/snapshot", async (route) => {
    await gate;
    await route.fulfill({ status: 200, contentType: "application/json", body });
  });
  await page.route("**/api/events", async (route) => {
    await gate;
    await route.fulfill({ status: 200, contentType: "text/event-stream", body: "" });
  });
  try {
    await page.goto("/");
    await expect(page.getByRole("status").filter({ hasText: "Loading dashboard" })).toBeVisible();
  } finally {
    release();
  }
  await expect(page.getByRole("heading", { name: "Claude", exact: true })).toBeVisible();

  const empty = readSnapshot("missing.json");
  empty.providers = [];
  empty.sessions = [];
  empty.worktrees = [];
  empty.alerts = [];
  empty.sources = [];
  await page.unroute("**/api/snapshot");
  await page.unroute("**/api/events");
  await fulfillSnapshot(page, empty);
  await page.reload();
  await expect(page.getByText("No provider data")).toBeVisible();
  await expect(page.getByRole("heading", { name: "Grok", exact: true })).toBeVisible();
  await expect(page.getByRole("region", { name: "Grok", exact: true })).toContainText("Unknown");

  await page.unroute("**/api/snapshot");
  await page.unroute("**/api/events");
  await page.route("**/api/snapshot", async (route) => {
    await route.fulfill({ status: 500, contentType: "application/json", body: "{}" });
  });
  await page.route("**/api/events", async (route) => {
    await route.fulfill({ status: 500, contentType: "text/event-stream", body: "" });
  });
  await page.reload();
  await expect(page.getByRole("alert")).toContainText("Dashboard unavailable");
  expectQuiet(guards);
});
