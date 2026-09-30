import type { ProviderQuota, QuotaWindow } from "@herdr/contracts";
import {
  describeUsage,
  eligibilityLine,
  formatCountdown,
  healthLabel,
  meterKind,
  reasonPhrase,
  windowKindLabel,
} from "./format.js";
import { providerLabel } from "./sessions.js";
import { Timestamp } from "./Timestamp.js";

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
  const status = quota?.health.status ?? "missing";
  return (
    <section className="card" aria-labelledby={headingId}>
      <header className="card-head">
        <h2 id={headingId}>{label}</h2>
        <p className={`tag tag-${status}`}>{quota ? `Health ${healthLabel(status)}` : "Health unknown"}</p>
      </header>
      {quota ? <ProviderBody quota={quota} generatedAt={generatedAt} /> : <UnknownWindows />}
    </section>
  );
}

function UnknownWindow({ kind }: { kind: string }) {
  return (
    <section className="window" aria-label={kind}>
      <div className="window-head">
        <h3>{kind}</h3>
        <p className="percent percent-unknown">Unknown</p>
      </div>
      <p className="reset">Unknown reset</p>
    </section>
  );
}

function UnknownWindows() {
  return (
    <>
      <UnknownWindow kind="5 hour" />
      <UnknownWindow kind="Weekly" />
    </>
  );
}

function ProviderBody({ quota, generatedAt }: { quota: ProviderQuota; generatedAt: string }) {
  const reason = reasonPhrase(quota.health.reasonCode);
  const kinds = new Set(quota.windows.map((usage) => usage.kind));
  return (
    <>
      {reason ? <p className="reason">{reason}</p> : null}
      {quota.windows.map((usage) => (
        <WindowBlock key={`${usage.kind}:${usage.scope}`} usage={usage} health={quota.health.status} generatedAt={generatedAt} />
      ))}
      {kinds.has("five_hour") ? null : <UnknownWindow kind="5 hour" />}
      {kinds.has("weekly") ? null : <UnknownWindow kind="Weekly" />}
      <BankedList label={providerLabel(quota.provider)} quota={quota} generatedAt={generatedAt} />
    </>
  );
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
  const known = summary.includes("%");
  return (
    <section className="window" aria-label={kind}>
      <div className="window-head">
        <h3>
          {kind} <span className="scope">Scope {usage.scope}</span>
        </h3>
        <p className={known ? "percent" : "percent percent-unknown"}>{summary}</p>
      </div>
      {meter === "none" || usage.usedPercent === null || usage.remainingPercent === null ? null : (
        <progress
          className={meter === "stale" ? "meter meter-stale" : "meter meter-fresh"}
          max={100}
          value={usage.usedPercent}
          aria-label={`${kind} ${summary}`}
        />
      )}
      {health === "stale" ? (
        <p className="sampled">
          Stale. Sampled <Timestamp iso={usage.sampledAt} />
        </p>
      ) : null}
      {usage.availability === "not_applicable" ? null : usage.resetsAt ? (
        <p className="reset" title={usage.resetRaw ? `Reported ${usage.resetRaw}` : undefined}>
          Resets <Timestamp iso={usage.resetsAt} /> <span className="countdown">· {formatCountdown(usage.resetsAt, generatedAt)}</span>
        </p>
      ) : (
        <p className="reset">Unknown reset</p>
      )}
      {/* The raw CLI text matters most when it could not be parsed into a time. */}
      {usage.resetRaw && !usage.resetsAt ? <p className="reported">Reported {usage.resetRaw}</p> : null}
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
            <div className="banked-head">
              <h4>{reset.id}</h4>
              <span className="banked-qty">Quantity {reset.quantity}</span>
              {reset.eligibility === "ineligible" ? null : <span className="eligibility">{eligibilityLine(reset)}</span>}
            </div>
            {/* An ineligible reset carries a sentence of reason, so it gets its own line. */}
            {reset.eligibility === "ineligible" ? <p className="eligibility eligibility-no">{eligibilityLine(reset)}</p> : null}
            <p>
              Expires <Timestamp iso={reset.expiresAt} /> <span className="countdown">· {formatCountdown(reset.expiresAt, generatedAt)}</span>
            </p>
            {reset.redeemableAt ? (
              <p>
                Redeemable <Timestamp iso={reset.redeemableAt} />
              </p>
            ) : null}
          </li>
        ))}
      </ul>
    </section>
  );
}
