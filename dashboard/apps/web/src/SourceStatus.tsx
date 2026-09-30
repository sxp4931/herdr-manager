import type { Alert, SourceHealth } from "@herdr/contracts";
import { sourceProblemAlerts } from "./Alerts.js";
import { healthLabel, reasonPhrase } from "./format.js";

export function SourceStatus({ sources, alerts }: { sources: readonly SourceHealth[]; alerts: readonly Alert[] }) {
  const problems = sourceProblemAlerts(alerts);
  return (
    <section className="panel sources" aria-labelledby="source-status-heading">
      <h2 id="source-status-heading">Source status</h2>
      {sources.length === 0 ? <p className="empty">No source reports</p> : (
        <ul className="source-list">
          {sources.map((source) => {
            const reason = reasonPhrase(source.reasonCode);
            return (
              <li key={source.sourceId} className={source.status === "ok" ? "source" : "source source-problem"}>
                <span className="source-id">{source.sourceId}</span>
                <span className={`tag tag-${source.status}`}>{healthLabel(source.status)}</span>
                {reason ? <span className="source-reason">{reason}</span> : null}
              </li>
            );
          })}
        </ul>
      )}
      {problems.length === 0 ? <p className="empty">No source problems</p> : (
        <div className="source-problems">
          <h3>Source problems</h3>
          <ul>
            {problems.map((alert) => (
              <li key={alert.id}>{alert.message}</li>
            ))}
          </ul>
        </div>
      )}
    </section>
  );
}
