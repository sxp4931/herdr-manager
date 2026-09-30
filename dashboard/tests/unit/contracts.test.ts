import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  HealthSchema,
  FIXTURE_NOW,
  dashboardSnapshotSchema,
  parseHealth,
  providerQuotaSchema,
  quotaWindowSchema,
  scenarioNames,
  scenarios,
  sourceHealthSchema,
} from "@herdr/contracts";

const scenarioFiles = [
  "daily",
  "missing",
  "stale",
  "partial",
  "dst",
  "banked-expiring",
  "unknown-loop",
] as const;

describe("health contract", () => {
  it("accepts a read-only loopback health payload", () => {
    const parsed = parseHealth({
      status: "ok",
      schemaVersion: 1,
      mode: "passive",
      readOnly: true,
    });
    expect(parsed.mode).toBe("passive");
    expect(parsed.readOnly).toBe(true);
  });

  it("rejects a writable health payload", () => {
    expect(() =>
      HealthSchema.parse({
        status: "ok",
        schemaVersion: 1,
        mode: "passive",
        readOnly: false,
      }),
    ).toThrow();
  });
});

describe("synthetic fixture catalog", () => {
  it("validates every labeled scenario from disk", () => {
    expect(scenarioNames).toEqual([...scenarioFiles]);
    for (const name of scenarioFiles) {
      const disk = JSON.parse(readFileSync(`tests/fixtures/usage/${name}.json`, "utf8")) as unknown;
      expect(disk).toEqual(scenarios[name]);
      expect(dashboardSnapshotSchema.parse(disk).mode).toBe("fixture");
    }
  });

  it("fixes the daily catalog at the documented instant", () => {
    expect(scenarios.daily.generatedAt).toBe(FIXTURE_NOW);
    expect(scenarios.daily.generatedAt).toBe("2026-09-29T16:00:00.000Z");
    expect(scenarios.daily.providers.map((provider) => provider.provider)).toEqual(["claude", "codex", "grok"]);
    const claudeWeekly = scenarios.daily.providers[0]?.windows.find((window) => window.kind === "weekly");
    const codexFive = scenarios.daily.providers[1]?.windows.find((window) => window.kind === "five_hour");
    const grokFive = scenarios.daily.providers[2]?.windows.find((window) => window.kind === "five_hour");
    expect(scenarios.daily.providers[0]?.windows.find((window) => window.kind === "five_hour")?.usedPercent).toBe(10);
    expect(claudeWeekly?.usedPercent).toBe(20);
    expect(codexFive?.usedPercent).toBe(35);
    expect(codexFive?.remainingPercent).toBe(65);
    expect(scenarios.daily.providers[1]?.windows.find((window) => window.kind === "weekly")?.remainingPercent).toBe(75);
    expect(scenarios.daily.providers[2]?.windows.find((window) => window.kind === "weekly")?.usedPercent).toBe(15);
    expect(grokFive?.availability).toBe("not_applicable");
    expect(grokFive?.usedPercent).toBeNull();
    expect(grokFive?.remainingPercent).toBeNull();
    expect(scenarios.daily.providers[1]?.bankedResets).toHaveLength(2);
    expect(scenarios.partial.providers.find((provider) => provider.provider === "codex")?.bankedResets).toEqual([]);
    expect(scenarios.partial.providers.find((provider) => provider.provider === "claude")?.bankedStatus).toBe("unknown");
    expect(scenarios.partial.providers.find((provider) => provider.provider === "claude")?.bankedResets).toBeNull();
    const screen = readFileSync("tests/fixtures/usage/screens/codex-status.txt", "utf8");
    expect(screen).toContain("65% left");
    expect(screen.startsWith("SYNTHETIC")).toBe(true);
  });
});

describe("quota validation", () => {
  const known = scenarios.daily.providers[0]?.windows[0];
  if (!known) {
    throw new Error("daily fixture is missing a window");
  }

  it("rejects invalid numbers", () => {
    expect(() => quotaWindowSchema.parse({ ...known, usedPercent: 101, remainingPercent: -1 })).toThrow();
    expect(() => quotaWindowSchema.parse({ ...known, usedPercent: Number.NaN, remainingPercent: 90 })).toThrow();
    expect(() => quotaWindowSchema.parse({ ...known, usedPercent: Number.POSITIVE_INFINITY, remainingPercent: 0 })).toThrow();
    expect(() => quotaWindowSchema.parse({ ...known, usedPercent: -5, remainingPercent: 105 })).toThrow();
  });

  it("rejects invalid dates", () => {
    expect(() => quotaWindowSchema.parse({ ...known, sampledAt: "yesterday" })).toThrow();
    expect(() => quotaWindowSchema.parse({ ...known, resetsAt: "2026-09-29" })).toThrow();
    expect(() => quotaWindowSchema.parse({ ...known, sampledAt: "2026-09-29T16:00:00Z" })).toThrow();
  });

  it("rejects a missing provenance", () => {
    const health = scenarios.daily.providers[0]?.health;
    if (!health) {
      throw new Error("daily fixture is missing health");
    }
    const withoutProvenance = {
      sourceId: health.sourceId,
      status: health.status,
      checkedAt: health.checkedAt,
      lastSuccessAt: health.lastSuccessAt,
      reasonCode: health.reasonCode,
      cliVersion: health.cliVersion,
      parserVersion: health.parserVersion,
    };
    expect(() => sourceHealthSchema.parse(withoutProvenance)).toThrow();
  });

  it("rejects zero substituted for unknown", () => {
    expect(() =>
      quotaWindowSchema.parse({
        ...known,
        availability: "unknown",
        usedPercent: 0,
        remainingPercent: null,
        confidence: "unknown",
      }),
    ).toThrow();
    expect(() =>
      quotaWindowSchema.parse({
        ...known,
        availability: "not_applicable",
        usedPercent: 0,
        remainingPercent: 100,
        confidence: "unknown",
      }),
    ).toThrow();
  });

  it("rejects an empty list standing in for an unknown banked inventory", () => {
    const codex = scenarios.daily.providers[1];
    expect(codex).toBeDefined();
    expect(() => providerQuotaSchema.parse({ ...codex, bankedStatus: "unknown", bankedResets: [] })).toThrow();
    expect(() => providerQuotaSchema.parse({ ...codex, bankedStatus: "known", bankedResets: null })).toThrow();
  });
});
