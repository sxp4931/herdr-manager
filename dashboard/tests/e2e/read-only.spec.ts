import { expect, test, type Page, type Route } from "@playwright/test";
import { scenarios, type DashboardSnapshot } from "../../packages/contracts/src/index.js";
import { expectQuiet, watchPage } from "./guard.js";

const SENTINEL = "SYNTHETIC_SECRET_SENTINEL";
const HOSTILE = "<script>alert(1)</script> ../../etc/passwd https://user:secretpass@example.test/x";
const METHODS = ["POST", "PUT", "PATCH", "DELETE"] as const;
const PATHS = ["/api/health", "/api/snapshot", "/api/providers", "/api/sessions", "/api/worktrees", "/api/alerts", "/api/events", "/"];

function hostileSnapshot(): DashboardSnapshot {
  const snapshot = structuredClone(scenarios.daily);
  const session = snapshot.sessions.find((item) => item.label === "daily-claude-worker");
  const work = snapshot.worktrees[0];
  const commit = work?.recentCommits[0];
  if (!session || !work || !commit) throw new Error("daily fixture is missing the hostile target");
  session.label = HOSTILE;
  commit.subject = "<script>alert(1)</script> https://user:secretpass@example.test/x";
  work.branch = "../../etc/passwd";
  return snapshot;
}

function disabledSnapshot(): DashboardSnapshot {
  const snapshot = structuredClone(scenarios.missing);
  snapshot.mode = "passive";
  for (const provider of snapshot.providers) {
    provider.health.status = "disabled";
    provider.health.reasonCode = "probes_disabled";
  }
  for (const source of snapshot.sources) {
    source.status = "disabled";
    source.reasonCode = "probes_disabled";
  }
  return snapshot;
}

async function fulfillJson(route: Route, body: unknown): Promise<void> {
  await route.fulfill({
    status: 200,
    contentType: "application/json",
    body: JSON.stringify(body),
  });
}

function eventFrame(snapshot: DashboardSnapshot, id: number, retryMs: number): string {
  return `retry: ${retryMs}\nid: ${id}\nevent: snapshot\ndata: ${JSON.stringify(snapshot)}\n\n`;
}

async function fitsViewport(page: Page): Promise<void> {
  const fits = await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);
  expect(fits).toBe(true);
}

test("read-only methods, controls, and both viewports stay on loopback", async ({ page }) => {
  const guards = watchPage(page);
  const traffic: { method: string; url: string }[] = [];
  page.on("request", (request) => {
    traffic.push({ method: request.method(), url: request.url() });
  });

  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "herdr dashboard" })).toBeVisible();
  await expect(page.getByText("<img src=x onerror=alert(1)>")).toBeVisible();
  await expect(page.locator("img")).toHaveCount(0);
  await expect(page.locator("script:not([src])")).toHaveCount(0);
  const labels = (await page.getByRole("button").allTextContents()).map((label) => label.trim());
  expect(labels.some((label) => /start|stop|approve|redeem|refresh/i.test(label))).toBe(false);
  expect(labels.filter((label) => label === "Use dark theme" || label === "Use light theme")).toHaveLength(1);
  await fitsViewport(page);

  await page.setViewportSize({ width: 390, height: 844 });
  await fitsViewport(page);
  const appTraffic = traffic.slice();
  expect(appTraffic.every((item) => item.method === "GET" || item.method === "HEAD")).toBe(true);
  expect(appTraffic.some((item) => /start|stop|approve|redeem/i.test(new URL(item.url).pathname))).toBe(false);

  const probes = await page.evaluate(async ({ methods, paths, sentinel }) => {
    const results: { method: string; path: string; status: number; allow: string | null; body: string }[] = [];
    for (const method of methods) {
      for (const path of paths) {
        const response = await fetch(path, { method });
        results.push({
          method,
          path,
          status: response.status,
          allow: response.headers.get("allow"),
          body: await response.text(),
        });
      }
    }
    const health = await fetch(`/api/health?note=${sentinel}`);
    const snapshot = await fetch("/api/snapshot");
    const escaped = await fetch("/%2e%2e/etc/passwd");
    return {
      results,
      health: await health.text(),
      snapshot: await snapshot.text(),
      escaped: await escaped.text(),
    };
  }, { methods: METHODS, paths: PATHS, sentinel: SENTINEL });

  for (const result of probes.results) {
    expect(result.status, `${result.method} ${result.path}`).toBe(405);
    expect(result.allow).toBe("GET");
    expect(result.body).not.toContain(SENTINEL);
  }
  expect(probes.health).not.toContain(SENTINEL);
  expect(probes.snapshot).not.toContain(SENTINEL);
  expect(probes.snapshot).not.toContain("\"screen\":");
  expect(probes.escaped).not.toContain("root:x:0:0");
  expectQuiet(guards);
});

test("hostile text stays literal when a dropped event stream reconnects", async ({ page }) => {
  const guards = watchPage(page);
  const initial = scenarios.daily;
  const next = hostileSnapshot();
  let events = 0;
  await page.route("**/api/snapshot", async (route) => {
    await fulfillJson(route, initial);
  });
  await page.route("**/api/events", async (route) => {
    events += 1;
    const body = events === 1
      ? eventFrame(initial, 1, 10)
      : `retry: 60000\nevent: snapshot\ndata: {not-json\n\n${eventFrame(next, 2, 60000)}`;
    await route.fulfill({
      status: 200,
      headers: { "content-type": "text/event-stream; charset=utf-8", "cache-control": "no-store" },
      body,
    });
  });
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/");
  const revealed = page.getByRole("button", { name: `Show details for ${HOSTILE}` });
  await expect(revealed).toBeVisible();
  expect(events).toBeGreaterThanOrEqual(2);
  await revealed.focus();
  await page.keyboard.press("Enter");
  const details = page.getByRole("region", { name: `Details for ${HOSTILE}` });
  await expect(details).toContainText("Branch ../../etc/passwd");
  await expect(details).toContainText("<script>alert(1)</script> https://user:secretpass@example.test/x");
  await expect(details).toContainText("Directory /work/demo");
  await expect(page.locator("img")).toHaveCount(0);
  await expect(page.locator("script:not([src])")).toHaveCount(0);
  await expect(page.locator("a")).toHaveCount(0);
  await fitsViewport(page);
  expectQuiet(guards);
});

test("reduced motion, a failed font load, and focus outlines keep the page usable", async ({ page }) => {
  const guards = watchPage(page);
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.addInitScript(() => {
    const fonts = document.fonts;
    fonts.load = () => Promise.reject(new Error("forced font failure"));
  });
  await page.route("**/*", async (route) => {
    if (route.request().resourceType() === "font") {
      await route.abort();
      return;
    }
    await route.continue();
  });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "herdr dashboard" })).toBeVisible();
  const motion = await page.evaluate(() => {
    const style = getComputedStyle(document.body);
    return {
      transition: style.transitionDuration,
      animation: style.animationDuration,
      font: style.fontFamily,
    };
  });
  expect(motion.transition).toBe("0s");
  expect(motion.animation).toBe("0s");
  expect(motion.font.toLowerCase()).toContain("sans-serif");
  await page.keyboard.press("Tab");
  const theme = page.getByRole("button", { name: /Use (dark|light) theme/ });
  await expect(theme).toBeFocused();
  const outline = await theme.evaluate((element) => {
    const style = getComputedStyle(element);
    return { width: style.outlineWidth, style: style.outlineStyle };
  });
  expect(outline.style).not.toBe("none");
  expect(Number.parseFloat(outline.width)).toBeGreaterThanOrEqual(3);
  await fitsViewport(page);
  expectQuiet(guards);
});

test("missing, disabled, and stale sources keep the dashboard usable", async ({ page }) => {
  const guards = watchPage(page);
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.route("**/api/snapshot", async (route) => {
    await fulfillJson(route, scenarios.stale);
  });
  await page.route("**/api/events", async (route) => {
    await route.fulfill({ status: 200, contentType: "text/event-stream", body: "" });
  });
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "herdr dashboard" })).toBeVisible();
  await expect(page.getByRole("region", { name: "Claude", exact: true }).locator('time[datetime="2026-09-29T15:45:00.000Z"]').first()).toBeVisible();
  await expect(page.getByRole("region", { name: "Codex", exact: true })).toContainText("Unknown");
  await expect(page.getByRole("region", { name: "Grok", exact: true })).toContainText("Unknown");
  await fitsViewport(page);

  await page.unroute("**/api/snapshot");
  await page.route("**/api/snapshot", async (route) => {
    await fulfillJson(route, disabledSnapshot());
  });
  await page.reload();
  await expect(page.getByRole("status").filter({ hasText: "Probes disabled" })).toBeVisible();
  await expect(page.getByText("Disabled").first()).toBeVisible();
  await expect(page.locator("progress")).toHaveCount(0);
  await expect(page.getByRole("heading", { name: "Claude", exact: true })).toBeVisible();
  const labels = (await page.getByRole("button").allTextContents()).map((label) => label.trim());
  expect(labels.some((label) => /start|stop|approve|redeem|refresh/i.test(label))).toBe(false);

  const empty = structuredClone(scenarios.missing);
  empty.providers = [];
  empty.sources = [];
  await page.unroute("**/api/snapshot");
  await page.route("**/api/snapshot", async (route) => {
    await fulfillJson(route, empty);
  });
  await page.reload();
  await expect(page.getByText("No provider data")).toBeVisible();
  await expect(page.getByRole("region", { name: "Grok", exact: true })).toContainText("Unknown");
  await expect(page.getByRole("heading", { name: "herdr dashboard" })).toBeVisible();
  await fitsViewport(page);
  expectQuiet(guards);
});
