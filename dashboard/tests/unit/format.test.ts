import { describe, expect, it } from "vitest";
import {
  describeUsage,
  eligibilityLine,
  formatAbsolute,
  formatCountdown,
  healthLabel,
  meterKind,
  sourceLine,
} from "../../apps/web/src/format.js";

const NOW = "2026-09-29T16:00:00.000Z";

describe("quota text", () => {
  it("formats fixture countdowns from the snapshot instant", () => {
    expect(formatCountdown("2026-09-29T20:00:00.000Z", NOW)).toBe("4 hours left");
    expect(formatCountdown("2026-10-01T04:00:00.000Z", NOW)).toBe("36 hours left");
    expect(formatCountdown("2026-10-01T05:00:00.000Z", NOW)).toBe("37 hours left");
    expect(formatCountdown("2026-10-01T15:00:00.000Z", NOW)).toBe("47 hours left");
    expect(formatCountdown("2026-09-30T16:00:00.000Z", NOW)).toBe("24 hours left");
    expect(formatCountdown("2026-09-29T17:01:00.000Z", NOW)).toBe("1 hour 1 minute left");
    expect(formatCountdown("2026-09-29T16:59:00.000Z", NOW)).toBe("59 minutes left");
    expect(formatCountdown(NOW, NOW)).toBe("Reset time has passed");
    expect(formatCountdown(null, NOW)).toBe("Unknown reset");
    expect(formatCountdown("not-a-time", NOW)).toBe("Unknown reset");
  });

  it("prints America/New_York absolute time with the original ISO", () => {
    expect(formatAbsolute("2026-09-29T20:00:00.000Z")).toBe("Sep 29, 2026, 4:00 PM EDT (2026-09-29T20:00:00.000Z)");
    expect(formatAbsolute(null)).toBe("Unknown");
    expect(formatAbsolute("not-a-time")).toBe("Unknown");
  });

  it("keeps unknown, not applicable, disabled, and stale last-known distinct", () => {
    const known = { availability: "known" as const, usedPercent: 10, remainingPercent: 90 };
    const missing = { availability: "unknown" as const, usedPercent: null, remainingPercent: null };
    const grok = { availability: "not_applicable" as const, usedPercent: null, remainingPercent: null };
    expect(describeUsage(known, "ok")).toBe("10% used, 90% left");
    expect(describeUsage(known, "stale")).toBe("10% used, 90% left");
    expect(describeUsage(missing, "missing")).toBe("Unknown");
    expect(describeUsage(grok, "ok")).toBe("Not applicable");
    expect(describeUsage(known, "disabled")).toBe("Disabled");
    expect(describeUsage(missing, "disabled")).toBe("Disabled");
    expect(meterKind(known, "ok")).toBe("fresh");
    expect(meterKind(known, "stale")).toBe("stale");
    expect(meterKind(known, "disabled")).toBe("none");
    expect(meterKind(known, "missing")).toBe("none");
    expect(meterKind(missing, "ok")).toBe("none");
    expect(meterKind(grok, "ok")).toBe("none");
    expect(healthLabel("ok")).toBe("Fresh");
    expect(healthLabel("stale")).toBe("Stale");
    expect(healthLabel("not_authenticated")).toBe("Not signed in");
  });

  it("states banked eligibility without inventing a reason", () => {
    expect(eligibilityLine({ eligibility: "eligible", eligibilityReason: null })).toBe("Eligible");
    expect(eligibilityLine({ eligibility: "unknown", eligibilityReason: null })).toBe("Eligibility unknown");
    expect(eligibilityLine({ eligibility: "ineligible", eligibilityReason: "redeemable only after expiry" })).toBe(
      "redeemable only after expiry. Cannot be used before expiry",
    );
    expect(eligibilityLine({ eligibility: "ineligible", eligibilityReason: null })).toBe(
      "Ineligible. Cannot be used before expiry",
    );
    expect(sourceLine({ sourceId: "codex-quota", status: "disabled", reasonCode: "probes_disabled" })).toBe(
      "codex-quota — Disabled — Probes disabled",
    );
  });
});
