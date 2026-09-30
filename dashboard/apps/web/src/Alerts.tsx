import type { Alert } from "@herdr/contracts";
import { evidenceRow } from "./format.js";

export function capacityAlerts(alerts: readonly Alert[]): Alert[] {
  return alerts.filter((alert) => alert.kind !== "source_problem");
}

export function sourceProblemAlerts(alerts: readonly Alert[]): Alert[] {
  return alerts.filter((alert) => alert.kind === "source_problem");
}

const KIND_LABELS: Record<Alert["kind"], string> = {
  window_open_idle: "Idle window",
  weekly_reset_underused: "Weekly reset soon",
  banked_reset_unusable_before_expiry: "Banked reset unusable",
  banked_reset_expiring: "Banked reset expiring",
  source_problem: "Source problem",
};

export function AlertList({ alerts, generatedAt }: { alerts: readonly Alert[]; generatedAt: string }) {
  const capacity = capacityAlerts(alerts);
  return (
    <section className="panel alerts" aria-labelledby="alerts-heading">
      <h2 id="alerts-heading">
        Alerts {capacity.length > 0 ? <span className="count">{capacity.length}</span> : null}
      </h2>
      {capacity.length === 0 ? <p className="empty">No capacity alerts</p> : (
        <ul className="alert-list">
          {capacity.map((alert) => (
            <li key={alert.id} className={`alert alert-${alert.severity}`}>
              <p className="alert-meta">
                <span className={`tag tag-${alert.severity}`}>{alert.severity === "warning" ? "Warning" : "Info"}</span>
                <span>{KIND_LABELS[alert.kind]}</span>
              </p>
              <p className="alert-message">{alert.message}</p>
              <details className="evidence">
                <summary>Evidence</summary>
                <dl>
                  {Object.entries(alert.evidence).map(([key, value]) => {
                    const row = evidenceRow(key, value, generatedAt);
                    return (
                      <div key={key}>
                        <dt>{row.label}</dt>
                        <dd>{row.value}</dd>
                      </div>
                    );
                  })}
                </dl>
              </details>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
