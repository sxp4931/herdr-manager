import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import http from "node:http";
import path from "node:path";
import process from "node:process";

const FIXTURE_NOW = "2026-09-29T16:00:00.000Z";
const ALERT_IDS = [
  "weekly_reset_underused:claude:weekly:all",
  "weekly_reset_underused:codex:weekly:all",
  "weekly_reset_underused:grok:weekly:all",
  "banked_reset_unusable_before_expiry:codex:codex-reset-unusable",
  "banked_reset_expiring:codex:codex-reset-expiring",
];

function arg(name) {
  const index = process.argv.indexOf(name);
  const value = index === -1 ? undefined : process.argv[index + 1];
  if (!value || value.startsWith("--")) {
    process.stderr.write(`missing ${name}\n`);
    process.exit(2);
  }
  return value;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function sanitize(text) {
  let cleaned = "";
  for (const char of text.replaceAll("SYNTHETIC_SECRET_SENTINEL", "[redacted-secret]")) {
    const code = char.charCodeAt(0);
    cleaned += code <= 31 || code === 127 ? " " : char;
  }
  return cleaned.slice(0, 240);
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function childAlive() {
  const raw = process.env.HERDR_SMOKE_PID;
  if (!raw) return;
  const pid = Number(raw);
  if (!Number.isInteger(pid) || pid <= 0) return;
  try {
    process.kill(pid, 0);
  } catch {
    let log = "";
    const stateDir = process.env.HERDR_STATE_DIR;
    if (stateDir) {
      try {
        log = readFileSync(path.join(stateDir, "server.log"), "utf8");
      } catch {
        log = "";
      }
    }
    if (log.includes("EADDRINUSE")) {
      throw new Error("port is already in use; the existing listener was left running");
    }
    throw new Error("fixture server exited before smoke finished");
  }
}

function request(url, options = {}) {
  const target = new URL(url);
  const method = options.method ?? "GET";
  const headers = options.headers ?? {};
  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        hostname: target.hostname,
        port: target.port,
        path: `${target.pathname}${target.search}`,
        method,
        headers,
      },
      (res) => {
        const chunks = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("end", () => {
          resolve({
            status: res.statusCode ?? 0,
            headers: res.headers,
            body: Buffer.concat(chunks).toString("utf8"),
          });
        });
      },
    );
    req.setTimeout(options.timeoutMs ?? 5_000, () => {
      req.destroy(new Error("request timed out"));
    });
    req.on("error", reject);
    req.end();
  });
}

function header(headers, name) {
  const value = headers[name.toLowerCase()];
  return Array.isArray(value) ? value.join(",") : (value ?? "");
}

function forbidCapture(body) {
  assert(!body.includes("SYNTHETIC_SECRET_SENTINEL"), "response included a secret sentinel");
  assert(!body.includes("rawScreen"), "response included a raw capture field");
  assert(!body.includes("\"screen\":"), "response included a raw capture field");
}

function windowOf(provider, kind) {
  return provider.windows.find((item) => item.kind === kind && item.scope === "all");
}

const baseUrl = arg("--base-url");
const waitMs = Number(arg("--wait-ms"));
const evidencePath = arg("--evidence");
assert(Number.isInteger(waitMs) && waitMs > 0, "wait-ms must be a positive integer");

const checks = [];
const startedAt = Date.now();
const deadline = startedAt + waitMs;

async function check(name, fn) {
  const started = Date.now();
  try {
    childAlive();
    await fn();
    checks.push({ name, status: "passed", durationMs: Date.now() - started });
  } catch (error) {
    const detail = sanitize(error instanceof Error ? error.message : "check failed");
    checks.push({ name, status: "failed", durationMs: Date.now() - started, detail });
  }
}

let health = null;
let snapshot = null;

await check("health", async () => {
  while (Date.now() < deadline) {
    childAlive();
    try {
      const response = await request(`${baseUrl}/api/health`);
      if (response.status === 200) {
        let body;
        try {
          body = JSON.parse(response.body);
        } catch {
          throw new Error("malformed health response");
        }
        assert(body.status === "ok", "health status");
        assert(body.readOnly === true, "health readOnly");
        assert(body.mode === "fixture", "health mode");
        assert(body.schemaVersion === 1, "health schema");
        health = body;
        return;
      }
    } catch (error) {
      if (error instanceof Error && error.message === "malformed health response") throw error;
    }
    await sleep(100);
  }
  throw new Error("health deadline exceeded");
});

await check("providers", async () => {
  while (Date.now() < deadline) {
    childAlive();
    try {
      const response = await request(`${baseUrl}/api/snapshot`);
      if (response.status === 200) {
        forbidCapture(response.body);
        const body = JSON.parse(response.body);
        const claude = body.providers?.find((item) => item.provider === "claude");
        const ready = Array.isArray(body.providers)
          && body.providers.length === 3
          && claude
          && windowOf(claude, "five_hour")?.usedPercent === 10
          && Array.isArray(body.sessions)
          && body.sessions.length === 6
          && Array.isArray(body.worktrees)
          && body.worktrees.length === 1
          && Array.isArray(body.alerts)
          && body.alerts.length === ALERT_IDS.length;
        if (ready) {
          snapshot = body;
          break;
        }
      }
    } catch (error) {
      if (error instanceof Error && /capture field|secret sentinel/.test(error.message)) throw error;
    }
    await sleep(100);
  }
  assert(snapshot, "fixture catalog was not ready");
  assert(snapshot.mode === "fixture", "snapshot mode");
  assert(snapshot.generatedAt === FIXTURE_NOW, "frozen fixture clock");
  assert(snapshot.providers.map((item) => item.provider).join(",") === "claude,codex,grok", "provider order");
  const expected = {
    claude: { five: [10, 90, "2026-09-29T20:00:00.000Z"], weekly: [20, 80, "2026-10-01T04:00:00.000Z"] },
    codex: { five: [35, 65, "2026-09-29T20:00:00.000Z"], weekly: [25, 75, "2026-10-01T05:00:00.000Z"] },
    grok: { five: [null, null, null], weekly: [15, 85, "2026-10-01T15:00:00.000Z"] },
  };
  for (const provider of snapshot.providers) {
    const five = windowOf(provider, "five_hour");
    const weekly = windowOf(provider, "weekly");
    const want = expected[provider.provider];
    assert(five && weekly && want, "windows present");
    if (provider.provider === "grok") {
      assert(five.availability === "not_applicable", "grok 5h applicability");
      assert(five.usedPercent === null && five.remainingPercent === null && five.resetsAt === null, "grok 5h nulls");
    } else {
      assert(five.availability === "known", `${provider.provider} 5h applicability`);
    }
    assert(weekly.availability === "known", `${provider.provider} weekly applicability`);
    assert(five.usedPercent === want.five[0] && five.remainingPercent === want.five[1] && five.resetsAt === want.five[2], `${provider.provider} 5h values`);
    assert(weekly.usedPercent === want.weekly[0] && weekly.remainingPercent === want.weekly[1] && weekly.resetsAt === want.weekly[2], `${provider.provider} weekly values`);
  }
});

await check("banked-inventory", async () => {
  assert(snapshot, "snapshot missing");
  const claude = snapshot.providers.find((item) => item.provider === "claude");
  const grok = snapshot.providers.find((item) => item.provider === "grok");
  const codex = snapshot.providers.find((item) => item.provider === "codex");
  assert(claude.bankedStatus === "not_applicable" && claude.bankedResets === null, "claude banked");
  assert(grok.bankedStatus === "not_applicable" && grok.bankedResets === null, "grok banked");
  assert(codex.bankedStatus === "known" && Array.isArray(codex.bankedResets) && codex.bankedResets.length === 2, "codex inventory");
  const expiring = codex.bankedResets.find((item) => item.id === "codex-reset-expiring");
  const unusable = codex.bankedResets.find((item) => item.id === "codex-reset-unusable");
  assert(expiring && unusable, "codex reset ids");
  for (const reset of [expiring, unusable]) {
    assert(reset.quantity === 1, "reset quantity");
    assert(reset.earnedAt === "2026-09-27T16:00:00.000Z", "reset earnedAt");
    assert(reset.expiresAt === "2026-09-30T16:00:00.000Z", "reset expiresAt");
    assert(typeof reset.redeemableAt === "string" && typeof reset.eligibility === "string", "reset fields");
  }
  assert(expiring.eligibility === "eligible" && expiring.redeemableAt === "2026-09-29T17:00:00.000Z", "expiring reset");
  assert(unusable.eligibility === "ineligible" && unusable.eligibilityReason === "redeemable only after expiry", "unusable reset");
  assert(unusable.redeemableAt === "2026-09-30T17:00:00.000Z", "unusable redeemableAt");
});

await check("provenance", async () => {
  assert(snapshot, "snapshot missing");
  for (const provider of snapshot.providers) {
    assert(provider.health.provenance === "fixture", `${provider.provider} provenance`);
    assert(provider.health.status === "ok", `${provider.provider} health`);
  }
  for (const sourceId of ["herdr", "tmux", "git", "claude-quota", "codex-quota", "grok-quota"]) {
    const source = snapshot.sources.find((item) => item.sourceId === sourceId);
    assert(source && source.provenance === "fixture" && source.status === "ok", `${sourceId} provenance`);
  }
});

await check("sessions", async () => {
  assert(snapshot, "snapshot missing");
  const goal = snapshot.sessions.find((item) => item.label === "goal-runner");
  const processOnly = snapshot.sessions.find((item) => item.label === "codex-process-only");
  assert(goal?.loop?.kind === "goal" && goal.loop.state === "running" && goal.loop.source === "manifest" && goal.loop.iteration === 2, "goal loop");
  assert(processOnly?.status === "unknown" && processOnly.loop?.kind === "unknown" && processOnly.loop.source === "process", "process-only loop");
  assert(snapshot.sessions.some((item) => item.label === "daily-claude-worker" && item.status === "working"), "claude session");
});

await check("worktrees", async () => {
  assert(snapshot, "snapshot missing");
  const work = snapshot.worktrees[0];
  assert(work.path === "/work/demo" && work.branch === "feature/demo", "worktree identity");
  assert(work.staged === 1 && work.modified === 1 && work.untracked === 1 && work.conflicted === 0, "worktree counts");
  assert(work.recentCommits?.length === 2, "two commits");
  assert(work.recentCommits[0].sha === "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "head sha");
  assert(work.recentCommits[1].sha === "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "parent sha");
  assert(work.health.provenance === "fixture", "worktree provenance");
});

await check("alerts", async () => {
  assert(snapshot, "snapshot missing");
  const ids = snapshot.alerts.map((item) => item.id).sort();
  assert(JSON.stringify(ids) === JSON.stringify([...ALERT_IDS].sort()), "daily alerts");
  assert(!snapshot.alerts.some((item) => item.kind === "window_open_idle"), "no idle alert");
});

await check("unknown-api", async () => {
  const response = await request(`${baseUrl}/api/not-a-route`);
  assert(response.status === 404, "unknown api status");
  forbidCapture(response.body);
});

await check("mutations", async () => {
  for (const method of ["POST", "PUT", "PATCH", "DELETE"]) {
    const response = await request(`${baseUrl}/api/snapshot`, { method });
    assert(response.status === 405, `${method} status`);
    assert(header(response.headers, "allow") === "GET", `${method} allow`);
    forbidCapture(response.body);
  }
});

await check("hostile-host", async () => {
  const response = await request(`${baseUrl}/api/health`, { headers: { Host: "example.com" } });
  assert(response.status === 403, "hostile host status");
  const body = JSON.parse(response.body);
  assert(body.error?.code === "forbidden_host", "hostile host code");
  forbidCapture(response.body);
});

await check("headers", async () => {
  const response = await request(`${baseUrl}/api/snapshot`);
  assert(header(response.headers, "content-type").startsWith("application/json"), "json content type");
  assert(header(response.headers, "cache-control") === "no-store", "cache control");
  assert(header(response.headers, "content-security-policy").includes("script-src 'self'"), "csp");
});

await check("page", async () => {
  const response = await request(`${baseUrl}/`);
  assert(response.status === 200, "page status");
  assert(header(response.headers, "content-type").startsWith("text/html"), "html content type");
  assert(response.body.includes("herdr dashboard"), "page title");
  assert(header(response.headers, "content-security-policy").includes("script-src 'self'"), "page csp");
  forbidCapture(response.body);
});

await check("sse", async () => {
  const target = new URL(`${baseUrl}/api/events`);
  const text = await new Promise((resolve, reject) => {
    const req = http.request(
      {
        hostname: target.hostname,
        port: target.port,
        path: target.pathname,
        method: "GET",
        headers: { Accept: "text/event-stream" },
      },
      (res) => {
        if (res.statusCode !== 200) {
          reject(new Error("sse status"));
          res.resume();
          return;
        }
        if (!String(res.headers["content-type"] ?? "").includes("text/event-stream")) {
          reject(new Error("sse content type"));
          res.resume();
          return;
        }
        let received = "";
        let pulseTimer = null;
        const finish = (error, value) => {
          clearTimeout(timer);
          clearTimeout(pulseTimer);
          req.destroy();
          if (error) reject(error);
          else resolve(value);
        };
        const timer = setTimeout(() => {
          finish(new Error("sse heartbeat deadline"));
        }, Math.max(waitMs + 5_000, 20_000));
        const pulse = () => {
          try {
            childAlive();
          } catch (error) {
            finish(error);
            return;
          }
          pulseTimer = setTimeout(pulse, 100);
        };
        pulseTimer = setTimeout(pulse, 100);
        res.on("data", (chunk) => {
          received += chunk.toString("utf8");
          if (received.includes("event: snapshot") && received.includes(": heartbeat")) finish(null, received);
        });
        res.on("error", (error) => finish(error));
      },
    );
    req.on("error", (error) => {
      if (error && (error.code === "ECONNRESET" || error.message === "socket hang up")) return;
      reject(error);
    });
    req.end();
  });
  forbidCapture(text);
  assert(text.includes("event: snapshot"), "sse snapshot event");
  assert(text.includes(": heartbeat"), "sse heartbeat");
  const data = text.split("\n").find((line) => line.startsWith("data: "));
  assert(data, "sse data");
  const event = JSON.parse(data.slice("data: ".length));
  assert(event.mode === "fixture" && event.providers?.length === 3, "sse payload");
});

const evidence = {
  ok: checks.length > 0 && checks.every((item) => item.status === "passed"),
  skippedTests: 0,
  checks,
  statuses: Object.fromEntries(checks.map((item) => [item.name, item.status])),
  durationsMs: Object.fromEntries(checks.map((item) => [item.name, item.durationMs])),
  health,
};
mkdirSync(path.dirname(evidencePath), { recursive: true });
const payload = JSON.stringify(evidence);
forbidCapture(payload);
writeFileSync(evidencePath, `${payload}\n`);
if (!evidence.ok) {
  for (const item of checks) {
    if (item.status === "failed") process.stderr.write(`${item.name}: ${item.detail ?? "failed"}\n`);
  }
  process.exit(1);
}
process.stdout.write("smoke ok\n");
