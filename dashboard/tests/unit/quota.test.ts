import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { FIXTURE_NOW, fixtureIso, providerQuotaSchema, scenarios, type ProviderId, type QuotaWindow } from "@herdr/contracts";
import { quotaFromScreens } from "../../apps/server/src/quota/parse.js";

const NOW = new Date(FIXTURE_NOW);
const HOUR = 60 * 60 * 1000;

function lines(name: string): string[] {
  return readFileSync(`tests/fixtures/usage/screens/${name}`, "utf8")
    .split(/\r?\n/)
    .filter((line) => line.length > 0);
}

function parse(provider: ProviderId, quotaLines: string[], inventoryLines: string[] | null = null) {
  return quotaFromScreens({
    provider,
    quotaLines,
    inventoryLines,
    now: NOW,
    sampledAt: FIXTURE_NOW,
    cliVersion: "fixture-1",
    provenance: "fixture",
  });
}

function view(window: QuotaWindow | undefined) {
  return {
    kind: window?.kind,
    scope: window?.scope,
    availability: window?.availability,
    usedPercent: window?.usedPercent,
    remainingPercent: window?.remainingPercent,
    resetsAt: window?.resetsAt,
    resetRaw: window?.resetRaw,
    confidence: window?.confidence,
    sourceTimezone: window?.sourceTimezone,
  };
}

describe("provider quota parsers", () => {
  it("matches the daily Claude, Codex, and Grok percentages", () => {
    const claude = parse("claude", lines("claude-usage.txt"));
    const codex = parse("codex", lines("codex-status.txt"), lines("codex-usage.txt"));
    const grok = parse("grok", lines("grok-usage.txt"));
    const expected = scenarios.daily.providers;

    expect(claude.windows.map(view)).toEqual(expected[0]?.windows.map(view));
    expect(codex.windows.map(view)).toEqual(expected[1]?.windows.map(view));
    expect(grok.windows.map(view)).toEqual(expected[2]?.windows.map(view));
    expect(claude.bankedStatus).toBe("not_applicable");
    expect(claude.bankedResets).toBeNull();
    expect(grok.bankedStatus).toBe("not_applicable");
    expect(grok.bankedResets).toBeNull();
    expect(grok.windows.find((window) => window.kind === "five_hour")?.availability).toBe("not_applicable");
    expect(codex.bankedStatus).toBe("known");
    expect(codex.bankedResets).toEqual([
      {
        id: "codex-reset-expiring",
        quantity: 1,
        earnedAt: null,
        expiresAt: fixtureIso(24 * HOUR),
        redeemableAt: fixtureIso(1 * HOUR),
        eligibility: "eligible",
        eligibilityReason: null,
        sampledAt: FIXTURE_NOW,
      },
      {
        id: "codex-reset-unusable",
        quantity: 1,
        earnedAt: null,
        expiresAt: fixtureIso(24 * HOUR),
        redeemableAt: fixtureIso(25 * HOUR),
        eligibility: "ineligible",
        eligibilityReason: "redeemable only after expiry",
        sampledAt: FIXTURE_NOW,
      },
    ]);
    expect(codex.windows.find((window) => window.kind === "five_hour")).toMatchObject({
      usedPercent: 35,
      remainingPercent: 65,
      confidence: "exact",
      resetRaw: "in 4h",
    });
    for (const quota of [claude, codex, grok]) {
      expect(quota.health).toMatchObject({
        status: "ok",
        reasonCode: "ok",
        cliVersion: "fixture-1",
        parserVersion: "quota-1",
        provenance: "fixture",
        sourceId: `${quota.provider}-quota`,
      });
      expect(providerQuotaSchema.parse(quota)).toEqual(quota);
      expect(JSON.stringify(quota)).not.toContain("SYNTHETIC");
      expect(JSON.stringify(quota)).not.toContain("65% left");
    }
  });

  it("keeps a missing Claude 5h unknown and a missing Grok 5h not applicable", () => {
    const claude = parse("claude", ["Weekly limit", "20% used", "Resets in 36h"]);
    const grok = parse("grok", ["Weekly limit", "15% used", "Resets in 47h"]);
    expect(view(claude.windows.find((window) => window.kind === "five_hour"))).toMatchObject({
      availability: "unknown",
      usedPercent: null,
      remainingPercent: null,
    });
    expect(view(grok.windows.find((window) => window.kind === "five_hour"))).toMatchObject({
      availability: "not_applicable",
      usedPercent: null,
      remainingPercent: null,
    });
    expect(claude.windows[0]?.kind).toBe("five_hour");
    expect(claude.windows[1]?.kind).toBe("weekly");
  });

  it("normalizes decimals, rejects bare and inconsistent percents, and keeps model scopes", () => {
    const decimal = parse("claude", ["Weekly limit", "33.3% used", "Resets in 2h"]);
    expect(decimal.windows.find((window) => window.scope === "all" && window.kind === "weekly")).toMatchObject({
      usedPercent: 33.3,
      remainingPercent: 66.7,
      confidence: "rounded",
      resetsAt: fixtureIso(2 * HOUR),
    });

    const bare = parse("claude", lines("bare-percent.txt"));
    expect(bare.health.status).toBe("parse_error");
    expect(bare.windows.every((window) => window.usedPercent === null && window.availability === "unknown")).toBe(true);

    const rejected = parse("claude", ["Weekly limit", "101% used", "Resets in 4h"]);
    expect(rejected.windows.find((window) => window.kind === "weekly")).toMatchObject({
      availability: "unknown",
      usedPercent: null,
      remainingPercent: null,
      resetRaw: "in 4h",
    });

    const inconsistent = parse("claude", ["Weekly limit", "10% used", "50% left"]);
    expect(inconsistent.windows.find((window) => window.kind === "weekly")?.availability).toBe("unknown");

    const scopes = parse("claude", [
      "Sonnet weekly",
      "40% used",
      "Resets in 10h",
      "Opus weekly",
      "12.5% used",
      "Resets in 12h",
      "Weekly limit",
      "20% used",
      "Resets in 36h",
    ]);
    expect(scopes.windows.map((window) => `${window.kind}:${window.scope}:${window.usedPercent}`)).toEqual([
      "five_hour:all:null",
      "weekly:all:20",
      "weekly:opus:12.5",
      "weekly:sonnet:40",
    ]);
    expect(scopes.windows.find((window) => window.scope === "opus")?.confidence).toBe("rounded");
    expect(scopes.windows.find((window) => window.scope === "sonnet")?.confidence).toBe("exact");
  });

  it("leaves ambiguous, impossible, and weekday-only reset times unknown", () => {
    const ambiguous = parse("claude", lines("ambiguous-reset.txt"));
    expect(ambiguous.windows.find((window) => window.kind === "weekly")).toMatchObject({
      availability: "known",
      usedPercent: 20,
      resetsAt: null,
      resetRaw: "Sun Nov 1, 2026 1:30 AM",
    });

    const gap = parse("claude", ["Weekly limit", "10% used", "Resets Sun Mar 8, 2026 2:30 AM"]);
    expect(gap.windows.find((window) => window.kind === "weekly")?.resetsAt).toBeNull();

    const fall = parse("claude", ["Weekly limit", "10% used", "Resets Nov 1, 2026 3:30 AM"]);
    expect(fall.windows.find((window) => window.kind === "weekly")?.resetsAt).toBe("2026-11-01T08:30:00.000Z");

    const springBefore = parse("claude", ["Weekly limit", "10% used", "Resets Mar 8, 2026 1:30 AM"]);
    expect(springBefore.windows.find((window) => window.kind === "weekly")?.resetsAt).toBe("2026-03-08T06:30:00.000Z");

    const springAfter = parse("claude", ["Weekly limit", "10% used", "Resets Mar 8, 2026 3:30 AM"]);
    expect(springAfter.windows.find((window) => window.kind === "weekly")?.resetsAt).toBe("2026-03-08T07:30:00.000Z");

    const explicit = parse("claude", ["Weekly limit", "10% used", "Resets Nov 1, 2026 1:30 AM EST"]);
    expect(explicit.windows.find((window) => window.kind === "weekly")?.resetsAt).toBe("2026-11-01T06:30:00.000Z");
    const edt = parse("claude", ["Weekly limit", "10% used", "Resets 2026-11-01T03:30:00-05:00"]);
    expect(edt.windows.find((window) => window.kind === "weekly")?.resetsAt).toBe("2026-11-01T08:30:00.000Z");

    for (const phrase of ["Mon 1:30 AM", "tomorrow", "Feb 31, 2026 1:00 AM", "Mon Nov 1, 2026 3:30 AM"]) {
      const quota = parse("claude", ["Weekly limit", "10% used", `Resets ${phrase}`]);
      expect(quota.windows.find((window) => window.kind === "weekly")?.resetsAt).toBeNull();
      expect(quota.windows.find((window) => window.kind === "weekly")?.resetRaw).toBe(phrase);
    }
  });

  it("redacts secrets out of reset text", () => {
    const quota = parse("claude", ["Weekly limit", "10% used", "Resets in 4h SYNTHETIC_SECRET_SENTINEL"]);
    const weekly = quota.windows.find((window) => window.kind === "weekly");
    expect(weekly?.resetsAt).toBeNull();
    expect(weekly?.resetRaw).toContain("[redacted-secret]");
    expect(JSON.stringify(quota)).not.toContain("SYNTHETIC_SECRET_SENTINEL");
  });

  it("distinguishes a known empty Codex inventory from an unknown or unsafe one", () => {
    const none = parse("codex", lines("codex-status.txt"), lines("codex-none.txt"));
    expect(none.bankedStatus).toBe("known");
    expect(none.bankedResets).toEqual([]);
    expect(none.windows.find((window) => window.kind === "five_hour")?.usedPercent).toBe(35);

    const zero = parse("codex", ["5h limit", "65% left"], ["Earned resets", "quantity: 0"]);
    expect(zero.bankedStatus).toBe("known");
    expect(zero.bankedResets).toEqual([]);

    const missing = parse("codex", lines("codex-status.txt"), ["Codex fixture-1", "no inventory header"]);
    expect(missing.bankedStatus).toBe("unknown");
    expect(missing.bankedResets).toBeNull();

    const expired = parse("codex", lines("codex-status.txt"), lines("codex-expired.txt"));
    expect(expired.bankedResets).toEqual([
      expect.objectContaining({
        id: "codex-reset-old",
        quantity: 1,
        earnedAt: null,
        expiresAt: "2026-09-01T16:00:00.000Z",
        eligibility: "ineligible",
        eligibilityReason: "expired",
      }),
    ]);

    const unsafe = parse("codex", lines("codex-status.txt"), [
      "Earned resets",
      "id: codex-reset-expiring",
      "quantity: 1",
      "expires in 24h",
      "eligibility: eligible",
      "Redeem reset",
      "Apply",
      "Confirm",
    ]);
    expect(unsafe.bankedStatus).toBe("unknown");
    expect(unsafe.bankedResets).toBeNull();
    expect(unsafe.windows.find((window) => window.kind === "five_hour")?.usedPercent).toBe(35);
    expect(JSON.stringify(unsafe)).not.toContain("codex-reset-expiring");
  });
});
