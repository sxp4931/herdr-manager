import { describe, expect, it } from "vitest";
import { parseCli, resolveBind } from "../../apps/server/src/main.js";

describe("parseCli and resolveBind", () => {
  it("uses the config host and port when no flag is given", () => {
    const cli = parseCli(["--config", "x.json"]);
    expect(resolveBind(cli, { host: "localhost", port: 4400 })).toEqual({ host: "localhost", port: 4400 });
  });

  it("lets explicit flags override the config", () => {
    const cli = parseCli(["--host", "127.0.0.1", "--port", "4999"]);
    expect(resolveBind(cli, { host: "localhost", port: 4400 })).toEqual({ host: "127.0.0.1", port: 4999 });
  });

  it("still rejects a bad port flag", () => {
    expect(() => parseCli(["--port", "0"])).toThrow(/port/);
    expect(() => parseCli(["--port"])).toThrow(/port/);
  });

  it("refuses a non-loopback host from either source", () => {
    expect(() => resolveBind(parseCli(["--host", "0.0.0.0"]), { host: "127.0.0.1", port: 4317 })).toThrow(/non-loopback/);
    expect(() => resolveBind(parseCli([]), { host: "0.0.0.0", port: 4317 })).toThrow(/non-loopback/);
  });
});
