import { expect, test, type Locator, type Page } from "@playwright/test";
import { expectQuiet, watchPage } from "./guard.js";

test("built page is titled herdr dashboard", async ({ page }) => {
  const guards = watchPage(page);
  await page.goto("/");
  await expect(page).toHaveTitle("herdr dashboard");
  await expect(page.getByRole("heading", { name: "herdr dashboard" })).toBeVisible();
  expectQuiet(guards);
});

test("shows fixture quotas, banked resets, and demo data", async ({ page }) => {
  const guards = watchPage(page);
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/");

  await expect(page.getByRole("status").filter({ hasText: "Demo data" })).toBeVisible();
  await expect(page.getByText("Read-only localhost view. No agent actions.")).toBeVisible();

  const claude = page.getByRole("region", { name: "Claude", exact: true });
  const codex = page.getByRole("region", { name: "Codex", exact: true });
  const grok = page.getByRole("region", { name: "Grok", exact: true });

  await expect(claude.getByRole("region", { name: "5 hour", exact: true })).toContainText("10% used, 90% left");
  await expect(claude.getByRole("region", { name: "5 hour", exact: true })).toContainText("2026-09-29T20:00:00.000Z");
  await expect(claude.getByRole("region", { name: "5 hour", exact: true })).toContainText("4 hours left");
  await expect(claude.getByRole("region", { name: "Weekly", exact: true })).toContainText("20% used, 80% left");
  await expect(claude.getByRole("region", { name: "Weekly", exact: true })).toContainText("2026-10-01T04:00:00.000Z");
  await expect(claude.getByRole("region", { name: "Weekly", exact: true })).toContainText("36 hours left");
  await expect(claude.locator("progress.meter-fresh")).toHaveCount(2);
  await expect(claude.locator("progress.meter-stale")).toHaveCount(0);
  await expect(claude).toContainText("Health Fresh");
  await expect(claude).toContainText("Scope all");

  await expect(codex.getByRole("region", { name: "5 hour", exact: true })).toContainText("35% used, 65% left");
  await expect(codex.getByRole("region", { name: "5 hour", exact: true })).toContainText("4 hours left");
  await expect(codex.getByRole("region", { name: "Weekly", exact: true })).toContainText("25% used, 75% left");
  await expect(codex.getByRole("region", { name: "Weekly", exact: true })).toContainText("2026-10-01T05:00:00.000Z");
  await expect(codex.getByRole("region", { name: "Weekly", exact: true })).toContainText("37 hours left");

  const banked = codex.getByRole("region", { name: "Codex banked resets", exact: true });
  await expect(banked).toContainText("codex-reset-expiring");
  await expect(banked).toContainText("codex-reset-unusable");
  await expect(banked).toContainText("2026-09-30T16:00:00.000Z");
  await expect(banked.getByText("24 hours left")).toHaveCount(2);
  await expect(banked).toContainText("Eligible");
  await expect(banked).toContainText("redeemable only after expiry");
  await expect(banked).toContainText("Cannot be used before expiry");
  await expect(banked).toContainText("Quantity 1");

  const grokFive = grok.getByRole("region", { name: "5 hour", exact: true });
  await expect(grokFive).toContainText("Not applicable");
  await expect(grokFive.locator("progress")).toHaveCount(0);
  await expect(grok.getByRole("region", { name: "Weekly", exact: true })).toContainText("15% used, 85% left");
  await expect(grok.getByRole("region", { name: "Weekly", exact: true })).toContainText("2026-10-01T15:00:00.000Z");
  await expect(grok.getByRole("region", { name: "Weekly", exact: true })).toContainText("47 hours left");
  await expect(grok.locator("progress.meter-fresh")).toHaveCount(1);

  await expect(page.locator("progress.meter-stale")).toHaveCount(0);
  await expect(page.locator("img")).toHaveCount(0);

  const labels = (await page.getByRole("button").allTextContents()).map((label) => label.trim());
  expect(labels.some((label) => /start|stop|approve|redeem|refresh/i.test(label))).toBe(false);
  expect(labels.filter((label) => label === "Use dark theme" || label === "Use light theme")).toHaveLength(1);
  expect(labels.some((label) => label.startsWith("Show details for"))).toBe(true);

  for (const name of ["Claude", "Codex", "Grok"]) {
    await expectCardInView(page, name);
  }
  const firstAgent = await boxOf(page.getByRole("button", { name: "Show details for daily-claude-worker" }));
  expect(firstAgent.y).toBeGreaterThanOrEqual(0);
  expect(firstAgent.y + firstAgent.height).toBeLessThanOrEqual(900);
  const fits = await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);
  expect(fits).toBe(true);
  expectQuiet(guards);
});

test("phone width keeps provider cards in a vertical stack", async ({ page }) => {
  const guards = watchPage(page);
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/");
  const claude = await boxOf(page.getByRole("region", { name: "Claude", exact: true }));
  const codex = await boxOf(page.getByRole("region", { name: "Codex", exact: true }));
  const grok = await boxOf(page.getByRole("region", { name: "Grok", exact: true }));
  expect(codex.y).toBeGreaterThan(claude.y + claude.height - 1);
  expect(grok.y).toBeGreaterThan(codex.y + codex.height - 1);
  for (const box of [claude, codex, grok]) {
    expect(box.x).toBeGreaterThanOrEqual(0);
    expect(box.x + box.width).toBeLessThanOrEqual(390);
  }
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  expect(overflow).toBeLessThanOrEqual(1);
  const fits = await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);
  expect(fits).toBe(true);
  expectQuiet(guards);
});

test("theme choice survives reload and follows an unset system preference", async ({ page }) => {
  const guards = watchPage(page);
  await page.emulateMedia({ colorScheme: "light" });
  await page.addInitScript(() => {
    const mark = "herdr-theme-test-init";
    if (sessionStorage.getItem(mark) === "1") return;
    localStorage.removeItem("herdr-dashboard-theme");
    sessionStorage.setItem(mark, "1");
  });
  await page.goto("/");
  await expect(page.locator("html")).toHaveAttribute("data-theme", "light");
  await expect(page.locator("body")).toHaveCSS("background-color", "rgb(247, 247, 244)");
  await expect(page.locator("body")).toHaveCSS("color", "rgb(18, 23, 20)");
  await expect(page.getByRole("button", { name: "Use dark theme" })).toBeVisible();
  await page.getByRole("button", { name: "Use dark theme" }).click();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  await expect(page.locator("body")).toHaveCSS("background-color", "rgb(20, 24, 22)");
  await expect(page.locator("body")).toHaveCSS("color", "rgb(233, 235, 229)");
  await page.reload();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  await expect(page.getByRole("button", { name: "Use light theme" })).toBeVisible();
  await expect(page.locator("body")).toHaveCSS("background-color", "rgb(20, 24, 22)");

  await page.evaluate(() => localStorage.removeItem("herdr-dashboard-theme"));
  await page.emulateMedia({ colorScheme: "dark" });
  await page.reload();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  await expect(page.getByRole("button", { name: "Use light theme" })).toBeVisible();
  expectQuiet(guards);
});

async function expectCardInView(page: Page, name: string): Promise<void> {
  const card = page.getByRole("region", { name, exact: true });
  const box = await boxOf(card);
  expect(box.y).toBeGreaterThanOrEqual(0);
  expect(box.y).toBeLessThan(700);
  expect(box.x).toBeGreaterThanOrEqual(0);
  expect(box.x + box.width).toBeLessThanOrEqual(1440);
  for (const kind of ["5 hour", "Weekly"]) {
    const windowBox = await boxOf(card.getByRole("region", { name: kind, exact: true }));
    expect(windowBox.y).toBeGreaterThanOrEqual(0);
    expect(windowBox.y + windowBox.height).toBeLessThanOrEqual(900);
  }
}

async function boxOf(locator: Locator): Promise<{ x: number; y: number; width: number; height: number }> {
  const box = await locator.boundingBox();
  if (!box) throw new Error("missing card bounds");
  return box;
}
