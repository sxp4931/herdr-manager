import type { Alert } from "@herdr/contracts";

export function capacityAlerts(alerts: readonly Alert[]): Alert[] {
  return alerts.filter((alert) => alert.kind !== "source_problem");
}

export function sourceProblemAlerts(alerts: readonly Alert[]): Alert[] {
  return alerts.filter((alert) => alert.kind === "source_problem");
}

export function AlertList({ alerts }: { alerts: readonly Alert[] }) {
  const capacity = capacityAlerts(alerts);
  return (
    <section className="panel" aria-labelledby="alerts-heading">
      <h2 id="alerts-heading">Alerts</h2>
      {capacity.length === 0 ? <p>No capacity alerts</p> : (
        <ul className="alert-list">
          {capacity.map((alert) => (
            <li key={alert.id}>
              <p>{alert.message}</p>
              <p className="alert-meta">{alert.severity} · {alert.kind}</p>
              <ul>
                {Object.entries(alert.evidence).map(([key, value]) => (
                  <li key={key}>
                    {key}: {value === null ? "none" : String(value)}
                  </li>
                ))}
              </ul>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
