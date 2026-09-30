import {
  providerQuotaSchema,
  type Clock,
  type ProbeResult,
  type ProviderId,
  type ProviderQuota,
  type QuotaSource,
  type SourceStatus,
} from "@herdr/contracts";
import { runQuotaProbe, type QuotaProbeRequest } from "../adapters/quota-probe.js";
import { redactText } from "../services/redaction.js";
import { QUOTA_PARSER_VERSION, parseQuotaScreens, unknownWindows, type QuotaParseResult } from "./parse.js";

export const FIXTURE_PROFILE_IDS: Record<ProviderId, string> = {
  claude: "claude-fixture-v1",
  codex: "codex-fixture-v1",
  grok: "grok-fixture-v1",
};

interface CapturedPhase {
  phase: string;
  lines: string[];
}

export interface FixtureQuotaRequest {
  provider: ProviderId;
  executable: string;
  cwd: string;
  profile?: string;
  deadlineMs?: number;
  signal?: AbortSignal;
}

export interface FixtureQuotaTarget {
  executable: string;
  cwd: string;
  deadlineMs?: number;
  profile?: string;
}

export async function collectFixtureQuota(request: FixtureQuotaRequest, clock: Clock): Promise<ProviderQuota> {
  const profile = request.profile ?? FIXTURE_PROFILE_IDS[request.provider];
  const now = clock.now();
  const sampledAt = now.toISOString();
  const captured: CapturedPhase[] = [];
  const probeRequest: QuotaProbeRequest = {
    executable: request.executable,
    profile,
    cwd: request.cwd,
    onCapture(phase, lines) {
      captured.push({ phase, lines: lines.map((line) => redactText(line)) });
    },
  };
  if (request.deadlineMs !== undefined) probeRequest.deadlineMs = request.deadlineMs;
  if (request.signal !== undefined) probeRequest.signal = request.signal;
  const probe = await runQuotaProbe(probeRequest);
  const quota = quotaFromProbe({
    provider: request.provider,
    profile,
    probe,
    captured,
    now,
    sampledAt,
  });
  captured.length = 0;
  return quota;
}

export function createFixtureQuotaSource(
  targets: Partial<Record<ProviderId, FixtureQuotaTarget>>,
  clock: Clock,
): QuotaSource {
  return {
    async collect(provider, signal) {
      const target = targets[provider];
      if (!target) return missingQuota(provider, clock.now().toISOString());
      const request: FixtureQuotaRequest = {
        provider,
        executable: target.executable,
        cwd: target.cwd,
        signal,
      };
      if (target.deadlineMs !== undefined) request.deadlineMs = target.deadlineMs;
      if (target.profile !== undefined) request.profile = target.profile;
      return collectFixtureQuota(request, clock);
    },
  };
}

function quotaFromProbe(input: {
  provider: ProviderId;
  profile: string;
  probe: ProbeResult;
  captured: CapturedPhase[];
  now: Date;
  sampledAt: string;
}): ProviderQuota {
  const provenance = input.profile.includes("fixture") ? "fixture" : "live";
  const quotaLines = linesFor(input.captured, input.provider === "codex" ? "status" : "usage");
  const inventoryLines = input.provider === "codex" ? linesFor(input.captured, "usage") : null;
  const sawQuota = quotaLines !== null && quotaLines.length > 0;
  let parsed: QuotaParseResult = parseQuotaScreens({
    provider: input.provider,
    quotaLines: sawQuota ? quotaLines : [],
    inventoryLines,
    now: input.now,
    sampledAt: input.sampledAt,
  });
  const trap = input.probe.reason === "redemption_prompt" || input.probe.reason === "trust_prompt" || input.probe.reason === "model_prompt";
  if (trap) {
    parsed = { ...parsed, bankedResets: null, bankedStatus: "unknown" };
  }
  if (!sawQuota || input.probe.reason === "login_required" || (!input.probe.ok && !trap)) {
    parsed = {
      windows: unknownWindows(input.sampledAt),
      bankedResets: null,
      bankedStatus: "unknown",
    };
  }
  const status = healthStatus(input.probe, parsed);
  const reasonCode = safeReason(status === "ok" ? "ok" : input.probe.reason);
  return seal({
    provider: input.provider,
    windows: parsed.windows,
    bankedResets: parsed.bankedResets,
    bankedStatus: parsed.bankedStatus,
    health: {
      sourceId: `${input.provider}-quota`,
      status,
      checkedAt: input.sampledAt,
      lastSuccessAt: status === "ok" ? input.sampledAt : null,
      reasonCode,
      cliVersion: input.probe.version,
      parserVersion: QUOTA_PARSER_VERSION,
      provenance,
    },
  }, input.provider, input.sampledAt, provenance);
}

function linesFor(captured: CapturedPhase[], phase: string): string[] | null {
  const found = captured.filter((item) => item.phase === phase);
  if (found.length === 0) return null;
  return found.flatMap((item) => item.lines);
}

function informative(parsed: QuotaParseResult): boolean {
  return parsed.windows.some((window) => window.availability === "known" || window.availability === "not_applicable");
}

function healthStatus(probe: ProbeResult, parsed: QuotaParseResult): SourceStatus {
  if (probe.reason === "login_required") return "not_authenticated";
  if (
    probe.reason === "redemption_prompt" ||
    probe.reason === "trust_prompt" ||
    probe.reason === "model_prompt" ||
    probe.reason === "profile_unsafe" ||
    probe.reason === "probe_busy" ||
    probe.reason === "unknown_version"
  ) {
    return "unsupported";
  }
  if (probe.reason === "timeout" || probe.reason === "cancelled") return "timeout";
  if (
    probe.reason === "not_executable" ||
    probe.reason === "python_missing" ||
    probe.reason === "cwd_denied" ||
    probe.reason === "not_absolute"
  ) {
    return "missing";
  }
  if (probe.ok && informative(parsed)) return "ok";
  return "parse_error";
}

function safeReason(reason: string): string {
  return /^[a-z][a-z0-9_]{0,63}$/.test(reason) ? reason : "probe_failed";
}

function seal(quota: ProviderQuota, provider: ProviderId, sampledAt: string, provenance: "fixture" | "live"): ProviderQuota {
  const parsed = providerQuotaSchema.safeParse(quota);
  if (parsed.success) return parsed.data;
  return missingQuota(provider, sampledAt, provenance, "parse_error", "unparsed_quota");
}

function missingQuota(
  provider: ProviderId,
  sampledAt: string,
  provenance: "fixture" | "live" = "fixture",
  status: SourceStatus = "missing",
  reasonCode = "cli_missing",
): ProviderQuota {
  return providerQuotaSchema.parse({
    provider,
    windows: unknownWindows(sampledAt),
    bankedResets: null,
    bankedStatus: "unknown",
    health: {
      sourceId: `${provider}-quota`,
      status,
      checkedAt: sampledAt,
      lastSuccessAt: null,
      reasonCode,
      cliVersion: null,
      parserVersion: QUOTA_PARSER_VERSION,
      provenance,
    },
  });
}
