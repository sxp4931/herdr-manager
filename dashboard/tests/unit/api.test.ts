import { describe, expect, it } from "vitest";
import { scenarios } from "@herdr/contracts";
import { preferNewer } from "../../apps/web/src/api.js";

describe("preferNewer", () => {
  const at = (sequence: number) => ({ ...scenarios.daily, sequence });

  it("takes the fetched snapshot when nothing is on screen", () => {
    const fetched = at(3);
    expect(preferNewer(null, fetched)).toBe(fetched);
  });

  it("keeps a newer stream snapshot when the fetch resolves late", () => {
    const streamed = at(7);
    expect(preferNewer(streamed, at(5))).toBe(streamed);
    expect(preferNewer(streamed, at(7))).toBe(streamed);
  });

  it("takes a fetched snapshot that is newer than the one on screen", () => {
    const fetched = at(9);
    expect(preferNewer(at(4), fetched)).toBe(fetched);
  });
});
