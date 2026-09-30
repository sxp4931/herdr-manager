import path from "node:path";
import { describe, expect, it } from "vitest";
import { resolveDatabaseFile } from "../../apps/server/src/main.js";

describe("resolveDatabaseFile", () => {
  it("keeps an explicit database flag ahead of the state directory", () => {
    expect(resolveDatabaseFile({ HERDR_STATE_DIR: "/var/lib/herdr-state" }, "/repo", "/explicit/db.sqlite")).toBe(
      "/explicit/db.sqlite",
    );
  });

  it("places the sqlite file in HERDR_STATE_DIR when the flag is absent", () => {
    expect(resolveDatabaseFile({ HERDR_STATE_DIR: "/var/lib/herdr-state" }, "/repo", null)).toBe(
      path.join("/var/lib/herdr-state", "dashboard.sqlite"),
    );
  });

  it("falls back to the repo .local directory when no state directory is set", () => {
    expect(resolveDatabaseFile({}, "/repo", null)).toBe(path.join("/repo", ".local", "dashboard.sqlite"));
    expect(resolveDatabaseFile({ HERDR_STATE_DIR: "  " }, "/repo", null)).toBe(
      path.join("/repo", ".local", "dashboard.sqlite"),
    );
  });
});
