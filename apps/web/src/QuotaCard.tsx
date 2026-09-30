import type { ProviderQuota, QuotaWindow } from "@herdr/contracts";
import {
  describeUsage,
  eligibilityLine,
  formatAbsolute,
  formatCountdown,
  healthLabel,
  meterKind,
  reasonPhrase,
  windowKindLabel,
} from "./format.js";

export function QuotaCard({
  label,
  quota,
  generatedAt,
}: {
  label: string;
  quota: ProviderQuota | null;
  generatedAt: string;
}) {
  const headingId = `provider-${label.toLowerCase()}`;
  return (
    <section className="card" aria-labelledby={headingId}>
      <header className="card-head">
        <h2 id={headingId}>{label}</h2>
        <p className={quota ? `badge badge-${quota.health.status}` : "badge badge-missing"}>
          {quota ? `Health ${healthLabel(quota.health.status)}` : "Health unknown"}
        </p>
      </header>
      {quota ? <ProviderBody quota={quota} generatedAt={generatedAt} /> : <UnknownWindows />}
    </section>
  );
}

function UnknownWindows() {
  return (
    <>
      <section className="window" aria-label="5 hour">
        <h3>5 hour</h3>
        <p className="percent">Unknown</p>
        <p>Unknown reset</p>
      </section>
      <section className="window" aria-label="Weekly">
        <h3>Weekly</h3>
        <p className="percent">Unknown</p>
        <p>Unknown reset</p>
      </section>
    </>
  );
}

function ProviderBody({ quota, generatedAt }: { quota: ProviderQuota; generatedAt: string }) {
  const reason = reasonPhrase(quota.health.reasonCode);
  const seen = new Set<QuotaWindow["kind"]>();
  return (
    <>
      {reason ? <p className="reason">{reason}</p> : null}
      {quota.windows.map((usage) => {
        seen.add(usage.kind);
        return <WindowBlock key={`${usage.kind}:${usage.scope}`} usage={usage} health={quota.health.status} generatedAt={generatedAt} />;
      })}
      {seen.has("five_hour") ? null : (
        <section className="window" aria-label="5 hour">
          <h3>5 hour</h3>
          <p className="percent">Unknown</p>
        </section>
      )}
      {seen.has("weekly") ? null : (
        <section className="window" aria-label="Weekly">
          <h3>Weekly</h3>
          <p className="percent">Unknown</p>
        </section>
      )}
      <BankedList label={providerLabel(quota.provider)} quota={quota} generatedAt={generatedAt} />
    </>
  );
}

function providerLabel(provider: ProviderQuota["provider"]): string {
  if (provider === "claude") return "Claude";
  if (provider === "codex") return "Codex";
  return "Grok";
}

function WindowBlock({
  usage,
  health,
  generatedAt,
}: {
  usage: QuotaWindow;
  health: ProviderQuota["health"]["status"];
  generatedAt: string;
}) {
  const kind = windowKindLabel(usage.kind);
  const meter = meterKind(usage, health);
  const summary = describeUsage(usage, health);
  return (
    <section className="window" aria-label={kind}>
      <h3>{kind}</h3>
      <p className="scope">Scope {usage.scope}</p>
      <p className="percent">{summary}</p>
      {meter === "none" || usage.usedPercent === null || usage.remainingPercent === null ? null : (
        <progress
          className={meter === "stale" ? "meter meter-stale" : "meter meter-fresh"}
          max={100}
          value={usage.usedPercent}
          aria-label={`${kind} ${summary}`}
        />
      )}
      {health === "stale" ? <p className="sampled">Stale. Sampled {usage.sampledAt}</p> : null}
      {usage.availability === "not_applicable" ? null : usage.resetsAt ? (
        <>
          <p className="reset">
            Resets {formatAbsolute(usage.resetsAt)}
            {usage.sourceTimezone ? ` ${usage.sourceTimezone}` : ""}
          </p>
          <p className="countdown">{formatCountdown(usage.resetsAt, generatedAt)}</p>
        </>
      ) : (
        <p className="reset">Unknown reset</p>
      )}
      {usage.resetRaw ? <p className="reported">Reported {usage.resetRaw}</p> : null}
    </section>
  );
}

function BankedList({
  label,
  quota,
  generatedAt,
}: {
  label: string;
  quota: ProviderQuota;
  generatedAt: string;
}) {
  if (quota.bankedStatus === "not_applicable" || quota.bankedResets === null) {
    return (
      <p className="banked-note">
        {quota.bankedStatus === "not_applicable" ? "Banked resets not applicable" : "Banked resets unknown"}
      </p>
    );
  }
  if (quota.bankedResets.length === 0) return <p className="banked-note">No banked resets</p>;
  return (
    <section className="banked" aria-label={`${label} banked resets`}>
      <h3>{label} banked resets</h3>
      <ul>
        {quota.bankedResets.map((reset) => (
          <li key={reset.id}>
            <h4>{reset.id}</h4>
            <p>Quantity {reset.quantity}</p>
            <p>Expires {reset.expiresAt ? formatAbsolute(reset.expiresAt) : "Unknown"}</p>
            <p>{formatCountdown(reset.expiresAt, generatedAt)}</p>
            {reset.redeemableAt ? <p>Redeemable {formatAbsolute(reset.redeemableAt)}</p> : null}
            <p>{eligibilityLine(reset)}</p>
          </li>
        ))}
      </ul>
    </section>
  );
}
