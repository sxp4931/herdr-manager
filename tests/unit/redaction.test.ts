import { describe, expect, it } from "vitest";
import { redactStored, redactText } from "../../apps/server/src/services/redaction.js";

describe("redaction", () => {
  it("removes credential prefixes, bearers, url secrets, and emails", () => {
    const text = redactText(
      "bearer sk-ant-aaaaaaaaaaaa user https://ada:secret@example.com/x?token=sekret ada@example.com AKIAABCDEFGH1234",
    );
    expect(text).not.toContain("sk-ant-");
    expect(text).not.toContain("sekret");
    expect(text).not.toContain("ada@example.com");
    expect(text).not.toContain("ada:secret");
    expect(text).not.toContain("AKIA");
    expect(text).toContain("[redacted");
  });

  it("collapses terminal control text and strips the synthetic sentinel", () => {
    const text = redactText("line one\nSYNTHETIC_SECRET_SENTINEL\nline two");
    expect(text).not.toContain("\n");
    expect(text).not.toContain("SYNTHETIC_SECRET_SENTINEL");
    expect(text).toContain("line one");
    expect(text).toContain("line two");
  });

  it("refuses raw capture fields and keeps ordinary quota text", () => {
    expect(redactText("10% used")).toBe("10% used");
    expect(() => redactStored({ screen: "secret screen", label: "ok" })).toThrow(/raw field/);
    const stored = redactStored({ label: "worker SYNTHETIC_SECRET_SENTINEL" }) as { label: string };
    expect(stored.label).not.toContain("SYNTHETIC_SECRET_SENTINEL");
  });
});
