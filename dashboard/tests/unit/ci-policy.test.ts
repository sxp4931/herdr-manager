import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

describe("ci policy", () => {
  it("parses the workflow file and does not claim hosted Actions ran", () => {
    const result = spawnSync(process.execPath, ["scripts/check-ci.mjs"], { encoding: "utf8" });
    expect(result.status).toBe(0);
    const report = JSON.parse(result.stdout) as {
      hostedActionsExecuted: boolean;
      runsOn: string;
      node: string;
      python: string;
      permissions: { contents: string };
      stages: string[];
      ok: boolean;
    };
    const workflow = readFileSync(".github/workflows/ci.yml", "utf8");
    const scripts = JSON.parse(readFileSync("package.json", "utf8")).scripts as Record<string, string>;
    expect(report.hostedActionsExecuted).toBe(false);
    expect(report.ok).toBe(true);
    expect(report.runsOn).toBe("ubuntu-22.04");
    expect(report.node).toBe("22.23.2");
    expect(report.python).toBe("3.13.7");
    expect(report.permissions).toEqual({ contents: "read" });
    expect(workflow).toContain(`"${report.node}"`);
    expect(workflow).toContain(`"${report.python}"`);
    expect(workflow).toContain(report.runsOn);
    expect(workflow).toContain("contents: read");
    expect(report.stages).toEqual([
      "npm ci --no-audit --no-fund",
      "python3 -m venv .venv && .venv/bin/python -m pip install -r probes/requirements.txt",
      "npm exec playwright install chromium",
      "npm run check:policy",
      "npm run check",
      "npm run test:e2e",
    ]);
    for (const stage of report.stages) {
      expect(workflow).toContain(stage);
      for (const match of stage.matchAll(/npm run ([A-Za-z0-9:_-]+)/g)) {
        expect(scripts[match[1]]).toEqual(expect.any(String));
      }
    }
  });
});
