import type { BankedReset, QuotaWindow, SourceStatus } from "@herdr/contracts";

const ZONE = "America/New_York";

export function healthLabel(status: SourceStatus): string {
  switch (status) {
    case "ok":
      return "Fresh";
    case "stale":
      return "Stale";
    case "disabled":
      return "Disabled";
    case "missing":
      return "Missing";
    case "not_authenticated":
      return "Not signed in";
    case "timeout":
      return "Timed out";
    case "unsupported":
      return "Unsupported";
    case "parse_error":
      return "Unreadable";
  }
}

export function reasonPhrase(code: string): string | null {
  if (code === "ok") return null;
  if (code === "probes_disabled") return "Probes disabled";
  if (code === "cli_missing") return "CLI missing";
  if (code === "quota_ttl_exceeded") return "Quota sample expired";
  if (code === "socket_missing") return "Socket missing";
  if (code === "tmux_missing") return "Tmux missing";
  if (code === "profile_unsafe") return "Probe profile unsafe";
  if (code === "collector_error") return "Collector failed";
  return code;
}

export function windowKindLabel(kind: QuotaWindow["kind"]): string {
  return kind === "five_hour" ? "5 hour" : "Weekly";
}

export function describeUsage(
  usage: Pick<QuotaWindow, "availability" | "usedPercent" | "remainingPercent">,
  health: SourceStatus,
): string {
  if (health === "disabled") return "Disabled";
  if (usage.availability === "not_applicable") return "Not applicable";
  if (usage.availability !== "known" || usage.usedPercent === null || usage.remainingPercent === null) {
    return "Unknown";
  }
  return `${String(usage.usedPercent)}% used, ${String(usage.remainingPercent)}% left`;
}

export function meterKind(
  usage: Pick<QuotaWindow, "availability" | "usedPercent">,
  health: SourceStatus,
): "fresh" | "stale" | "none" {
  if (usage.availability !== "known" || usage.usedPercent === null) return "none";
  if (health === "ok") return "fresh";
  if (health === "stale") return "stale";
  return "none";
}

/** Reset and expiry times read in America/New_York. The exact ISO instant lives on the <time> element. */
export function formatAbsolute(iso: string | null): string {
  if (iso === null) return "Unknown";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "Unknown";
  return new Intl.DateTimeFormat("en-US", {
    timeZone: ZONE,
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
    timeZoneName: "short",
  }).format(date);
}

/** Clock time for the "updated" line, in the same zone as reset times. */
export function formatClock(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "unknown time";
  return new Intl.DateTimeFormat("en-US", {
    timeZone: ZONE,
    hour: "numeric",
    minute: "2-digit",
    second: "2-digit",
    timeZoneName: "short",
  }).format(date);
}

const EVIDENCE_LABELS: Record<string, string> = {
  remainingPercent: "Remaining",
  usedPercent: "Used",
  weeklyRemainingPercent: "Weekly remaining",
  resetsAt: "Resets",
  expiresAt: "Expires",
  redeemableAt: "Redeemable",
  lastSuccessAt: "Last success",
  eligibility: "Eligibility",
  eligibilityReason: "Reason",
  reasonCode: "Reason",
  sourceId: "Source",
  status: "Status",
  scope: "Scope",
  dwellMs: "Idle for",
};

/** Alert evidence as short human rows. Unknown keys keep their name so nothing is hidden. */
export function evidenceRow(key: string, value: string | number | boolean | null, nowIso: string): { label: string; value: string } {
  const label = EVIDENCE_LABELS[key] ?? key;
  if (value === null) return { label, value: "none" };
  if (typeof value === "number" && key.endsWith("Percent")) return { label, value: `${String(value)}%` };
  if (typeof value === "number" && key === "dwellMs") {
    return { label, value: formatElapsed(new Date(Date.parse(nowIso) - value).toISOString(), nowIso) };
  }
  if (typeof value === "string" && key.endsWith("At") && !Number.isNaN(Date.parse(value))) {
    return { label, value: formatAbsolute(value) };
  }
  return { label, value: String(value) };
}

export function formatElapsed(startIso: string, nowIso: string): string {
  const delta = Date.parse(nowIso) - Date.parse(startIso);
  if (!Number.isFinite(delta) || delta < 0) return "Unknown dwell";
  const minutes = Math.floor(delta / 60_000);
  if (minutes <= 0) return "under 1 minute";
  const hours = Math.floor(minutes / 60);
  const remainder = minutes % 60;
  if (hours >= 1 && remainder === 0) return countPhrase(hours, "hour", "hours");
  if (hours >= 1) return `${countPhrase(hours, "hour", "hours")} ${countPhrase(remainder, "minute", "minutes")}`;
  return countPhrase(minutes, "minute", "minutes");
}

export function formatCountdown(target: string | null, nowIso: string): string {
  if (target === null) return "Unknown reset";
  const delta = Date.parse(target) - Date.parse(nowIso);
  if (!Number.isFinite(delta)) return "Unknown reset";
  if (delta <= 0) return "Reset time has passed";
  const minutes = Math.floor(delta / 60_000);
  const hours = Math.floor(minutes / 60);
  const remainder = minutes % 60;
  if (hours >= 1 && remainder === 0) return `${countPhrase(hours, "hour", "hours")} left`;
  if (hours >= 1) {
    return `${countPhrase(hours, "hour", "hours")} ${countPhrase(remainder, "minute", "minutes")} left`;
  }
  return `${countPhrase(minutes, "minute", "minutes")} left`;
}

export function eligibilityLine(reset: Pick<BankedReset, "eligibility" | "eligibilityReason">): string {
  if (reset.eligibility === "eligible") return "Eligible";
  if (reset.eligibility === "unknown") return "Eligibility unknown";
  const reason = reset.eligibilityReason?.trim();
  return `${reason && reason.length > 0 ? reason : "Ineligible"}. Cannot be used before expiry`;
}

function countPhrase(count: number, singular: string, plural: string): string {
  return `${count} ${count === 1 ? singular : plural}`;
}
