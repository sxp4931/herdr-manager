import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { expect, test, type Page } from "@playwright/test";
import { idleSeed, scenarios, sourceHealthSchema, type DashboardSnapshot } from "../../packages/contracts/src/index.js";
import { createAlertEngine, sessionCoverage } from "../../apps/server/src/services/alerts.js";
import { createManualClock, createScheduler } from "../../apps/server/src/scheduler.js";
import { openStore } from "../../apps/server/src/storage/repository.js";
import { expectQuiet, watchPage } from "./guard.js";

const TEN_MINUTES = 10 * 60 * 1000;

test("filters, expands work, and closes details from the keyboard", async ({ page }) => {
  const guards = watchPage(page);
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/");
  await expect(page.getByRole("button", { name: "Show details for daily-claude-worker" })).toBeVisible();

  const buttons = (await page.getByRole("button").allTextContents()).map((label) => label.trim());
  const agents = buttons.filter((label) => label.startsWith("Show details for"));
  expect(agents.slice(0, 4)).toEqual([
    "Show details for daily-claude-worker",
    "Show details for daily-codex-worker",
    "Show details for daily-grok-worker",
    "Show details for goal-runner",
  ]);
  expect(agents[4]).toContain("Show details for <img");
  expect(agents[5]).toBe("Show details for codex-process-only");
  expect(buttons.some((label) => /start|stop|approve|redeem|refresh/i.test(label))).toBe(false);
  await expect(page.getByRole("row", { name: /daily-claude-worker/ })).toContainText("20 minutes");
  await expect(page.getByText("<img src=x onerror=alert(1)>")).toBeVisible();
  await expect(page.locator("img")).toHaveCount(0);

  const search = page.getByRole("searchbox", { name: "Search agents" });
  await search.focus();
  await page.keyboard.type("goal-runner");
  await expect(page.getByRole("button", { name: "Show details for goal-runner" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Show details for daily-claude-worker" })).toHaveCount(0);

  await search.fill("");
  await page.getByRole("combobox", { name: "Provider", exact: true }).selectOption("claude");
  await expect(page.getByRole("button", { name: "Show details for daily-claude-worker" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Show details for goal-runner" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Show details for daily-codex-worker" })).toHaveCount(0);

  const goal = page.getByRole("button", { name: "Show details for goal-runner" });
  await goal.focus();
  await expect(goal).toBeFocused();
  await page.keyboard.press("Enter");
  const goalDetails = page.getByRole("region", { name: "Details for goal-runner" });
  await expect(goalDetails).toContainText("Loop goal / running. Source manifest.");
  await expect(goalDetails).toContainText("Iteration 2");
  await expect(goalDetails).toContainText("feature/demo");
  await page.keyboard.press("Escape");
  await expect(goalDetails).toHaveCount(0);

  const worker = page.getByRole("button", { name: "Show details for daily-claude-worker" });
  await worker.focus();
  await page.keyboard.press("Enter");
  const details = page.getByRole("region", { name: "Details for daily-claude-worker" });
  await expect(details).toContainText("Branch feature/demo");
  await expect(details).toContainText("staged 1, modified 1, untracked 1, conflicted 0");
  await expect(details).toContainText("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
  await expect(details).toContainText("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
  await expect(details).toContainText("Worktree health Fresh");
  await page.keyboard.press("Escape");
  await expect(details).toHaveCount(0);

  await page.getByRole("combobox", { name: "Provider", exact: true }).selectOption("all");
  await page.getByRole("combobox", { name: "Status", exact: true }).selectOption("unknown");
  const processRow = page.getByRole("row", { name: /codex-process-only/ });
  await expect(processRow).toContainText("Unknown");
  await expect(processRow).not.toContainText("Idle");
  const processButton = page.getByRole("button", { name: "Show details for codex-process-only" });
  await processButton.focus();
  await page.keyboard.press("Enter");
  const processDetails = page.getByRole("region", { name: "Details for codex-process-only" });
  await expect(processDetails).toContainText("Loop unknown / unknown. Source process.");
  await expect(processDetails).toContainText("No mapped worktree");
  await expect(page.getByRole("region", { name: "Unmapped worktrees" })).toContainText("No unmapped worktrees");

  const payload: unknown = await page.evaluate(async () => {
    const response = await fetch("/api/snapshot");
    return response.json();
  });
  if (typeof payload !== "object" || payload === null || !("alerts" in payload) || !Array.isArray(payload.alerts)) {
    throw new Error("snapshot alerts missing");
  }
  const snapshotAlerts = payload.alerts.filter((alert): alert is { kind: string; message: string } => {
    if (typeof alert !== "object" || alert === null || !("kind" in alert) || !("message" in alert)) return false;
    return typeof alert.kind === "string" && typeof alert.message === "string";
  });
  const weekly = snapshotAlerts.find((alert) => alert.kind === "weekly_reset_underused");
  const unusable = snapshotAlerts.find((alert) => alert.kind === "banked_reset_unusable_before_expiry");
  if (!weekly || !unusable) throw new Error("fixture snapshot is missing capacity alerts");
  const alerts = page.getByRole("region", { name: "Alerts" });
  await expect(alerts).toContainText(weekly.message);
  await expect(alerts).toContainText(unusable.message);
  expect(snapshotAlerts.some((alert) => alert.kind === "window_open_idle")).toBe(false);
  await expect(page.getByText("no working session has been seen for 10 minutes")).toHaveCount(0);
  await expect(page.getByRole("region", { name: "Source status" })).toContainText("No source problems");
  expectQuiet(guards);
});

test("idle alert appears and disappears as the harness clock advances", async ({ page }) => {
  test.setTimeout(60_000);
  const guards = watchPage(page);
  const frames = await idleClockFrames();
  const claudeIdle = frames.appeared.alerts.find((alert) => alert.id === "window_open_idle:claude:five_hour:all");
  const codexIdle = frames.cleared.alerts.find((alert) => alert.id === "window_open_idle:codex:five_hour:all");
  if (!claudeIdle || !codexIdle) throw new Error("harness clock did not open and then clear the idle alerts");
  expect(frames.before.alerts.some((alert) => alert.kind === "window_open_idle")).toBe(false);
  expect(frames.cleared.alerts.some((alert) => alert.id === claudeIdle.id)).toBe(false);

  await showSnapshot(page, frames.before);
  await expect(page.getByText(claudeIdle.message)).toHaveCount(0);
  await showSnapshot(page, frames.appeared);
  await expect(page.getByRole("region", { name: "Alerts" })).toContainText(claudeIdle.message);
  await showSnapshot(page, frames.cleared);
  await expect(page.getByRole("region", { name: "Alerts" })).not.toContainText(claudeIdle.message);
  await expect(page.getByRole("region", { name: "Alerts" })).toContainText(codexIdle.message);
  expectQuiet(guards);
});

test("source problems stay in source status", async ({ page }) => {
  const guards = watchPage(page);
  const stale = scenarios.stale;
  const alerts = createAlertEngine().evaluate(stale, new Date(stale.generatedAt), sessionCoverage(stale));
  const problem = alerts.find((alert) => alert.kind === "source_problem");
  if (!problem) throw new Error("stale fixture produced no source problem");
  await showSnapshot(page, { ...stale, alerts });
  await expect(page.getByRole("region", { name: "Alerts" })).not.toContainText(problem.message);
  await expect(page.getByRole("region", { name: "Source status" })).toContainText(problem.message);
  await expect(page.getByRole("heading", { name: "Source problems" })).toBeVisible();
  expectQuiet(guards);
});

async function showSnapshot(page: Page, snapshot: DashboardSnapshot): Promise<void> {
  await page.unrouteAll({ behavior: "ignoreErrors" });
  const body = JSON.stringify(snapshot);
  await page.route("**/api/snapshot", async (route) => {
    await route.fulfill({ status: 200, contentType: "application/json", body });
  });
  await page.route("**/api/events", async (route) => {
    await route.fulfill({ status: 200, contentType: "text/event-stream", body: "" });
  });
  await page.goto("/");
}

async function idleClockFrames(): Promise<{
  before: DashboardSnapshot;
  appeared: DashboardSnapshot;
  cleared: DashboardSnapshot;
}> {
  const clock = createManualClock(idleSeed.generatedAt);
  const dir = mkdtempSync(path.join(os.tmpdir(), "herdr-dashboard-clock-"));
  const store = openStore({ file: path.join(dir, "dashboard.sqlite"), clock });
  let claudeStatus: "idle" | "working" = "idle";
  const iso = (): string => clock.now().toISOString();
  const healthAt = (sourceId: string) => {
    const source = idleSeed.sources.find((item) => item.sourceId === sourceId);
    if (!source) throw new Error(`missing ${sourceId}`);
    return sourceHealthSchema.parse({ ...source, checkedAt: iso(), lastSuccessAt: iso() });
  };
  const scheduler = createScheduler({
    clock,
    store,
    mode: "fixture",
    poll: { sessionsSeconds: 10, gitSeconds: 3600, quotaSeconds: 10 },
    probesEnabled: false,
    quota: {
      async collect(provider) {
        const source = idleSeed.providers.find((item) => item.provider === provider);
        if (!source) throw new Error(`missing ${provider}`);
        return {
          ...source,
          windows: source.windows.map((window) => ({ ...window, sampledAt: iso() })),
          bankedResets:
            source.bankedResets === null
              ? null
              : source.bankedResets.map((reset) => ({ ...reset, sampledAt: iso() })),
          health: { ...source.health, checkedAt: iso(), lastSuccessAt: iso() },
        };
      },
    },
    herdr: {
      async collect() {
        return {
          sessions: idleSeed.sessions.map((session) => ({
            ...session,
            observedAt: iso(),
            status: session.provider === "claude" ? claudeStatus : session.status,
          })),
          health: healthAt("herdr"),
        };
      },
    },
    tmux: {
      async collect() {
        return { sessions: [], health: healthAt("tmux") };
      },
    },
    git: {
      async collect() {
        const worktree = idleSeed.worktrees[0];
        if (!worktree) throw new Error("missing worktree");
        return {
          worktrees: [
            {
              ...worktree,
              observedAt: iso(),
              health: { ...worktree.health, checkedAt: iso(), lastSuccessAt: iso() },
            },
          ],
          health: healthAt("git"),
        };
      },
    },
  });
  try {
    await scheduler.start();
    const before = structuredClone(scheduler.current());
    await clock.advance(TEN_MINUTES - 1);
    await clock.advance(1);
    const appeared = structuredClone(scheduler.current());
    claudeStatus = "working";
    await clock.advance(10_000);
    const cleared = structuredClone(scheduler.current());
    return { before, appeared, cleared };
  } finally {
    await scheduler.stop();
    store.close();
    rmSync(dir, { recursive: true, force: true });
  }
}
