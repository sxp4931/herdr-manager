import { describe, expect, it } from "vitest";
import { HealthSchema, parseHealth } from "@herdr/contracts";

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
