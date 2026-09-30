import { useEffect, useState } from "react";
import type { DashboardSnapshot, ProviderId } from "@herdr/contracts";
import { AgentTable } from "./AgentTable.js";
import { AlertList } from "./Alerts.js";
import { isAbortError, loadSnapshot, preferNewer, subscribeSnapshots, type Connection } from "./api.js";
import { formatClock } from "./format.js";
import { GitPanel } from "./GitPanel.js";
import { QuotaCard } from "./QuotaCard.js";
import { SourceStatus } from "./SourceStatus.js";
import { applyTheme, readThemeChoice, resolvedTheme, storeThemeChoice, type ThemeChoice } from "./theme.js";

const PROVIDERS: readonly { id: ProviderId; label: string }[] = [
  { id: "claude", label: "Claude" },
  { id: "codex", label: "Codex" },
  { id: "grok", label: "Grok" },
];

export function App() {
  const [snapshot, setSnapshot] = useState<DashboardSnapshot | null>(null);
  const [failed, setFailed] = useState(false);
  const [connection, setConnection] = useState<Connection>("connecting");
  const [theme, setTheme] = useState<ThemeChoice>(() => readThemeChoice());

  useEffect(() => {
    applyTheme(theme);
    if (theme !== "system") return () => undefined;
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    const onChange = (): void => {
      applyTheme("system");
    };
    media.addEventListener("change", onChange);
    return () => media.removeEventListener("change", onChange);
  }, [theme]);

  useEffect(() => {
    const controller = new AbortController();
    let active = true;
    loadSnapshot(controller.signal)
      .then((fetched) => {
        if (active) setSnapshot((current) => preferNewer(current, fetched));
      })
      .catch((error: unknown) => {
        if (!active || controller.signal.aborted || isAbortError(error)) return;
        setFailed(true);
      });
    const stop = subscribeSnapshots(
      (next) => {
        if (!active) return;
        setSnapshot(next);
        setFailed(false);
      },
      (state) => {
        if (active) setConnection(state);
      },
    );
    return () => {
      active = false;
      controller.abort();
      stop();
    };
  }, []);

  const resolved = resolvedTheme(theme);
  const nextTheme = resolved === "dark" ? "light" : "dark";

  return (
    <main className="shell">
      <header className="topbar">
        <div className="masthead">
          <div className="title-row">
            <h1>herdr dashboard</h1>
            {snapshot?.mode === "fixture" ? <p className="mode-pill" role="status">Demo data</p> : null}
          </div>
          <p className="lede">Read-only localhost view. No agent actions.</p>
        </div>
        <div className="topbar-side">
          <ConnectionBadge connection={connection} snapshot={snapshot} />
          <button
            type="button"
            className="theme-toggle"
            onClick={() => {
              storeThemeChoice(nextTheme);
              setTheme(nextTheme);
              applyTheme(nextTheme);
            }}
          >
            {resolved === "dark" ? "Use light theme" : "Use dark theme"}
          </button>
        </div>
      </header>
      {snapshot ? (
        <Dashboard view={snapshot} connection={connection} />
      ) : failed ? (
        <div className="state-panel" role="alert">
          <h2>Dashboard unavailable</h2>
          <p>The local server did not return a snapshot. The page keeps retrying the event stream and will fill in when the server answers.</p>
        </div>
      ) : (
        <div className="state-panel" role="status">
          <h2>Loading dashboard</h2>
          <p>Waiting for the first snapshot from the local server.</p>
        </div>
      )}
    </main>
  );
}

function ConnectionBadge({ connection, snapshot }: { connection: Connection; snapshot: DashboardSnapshot | null }) {
  const label = connection === "live" ? "Live" : connection === "reconnecting" ? "Reconnecting" : "Connecting";
  return (
    <p className={`connection connection-${connection}`}>
      <span className="connection-dot" aria-hidden="true" />
      <span role="status">{label}</span>
      {snapshot ? (
        <span className="connection-time">
          {" "}
          · updated <time dateTime={snapshot.generatedAt}>{formatClock(snapshot.generatedAt)}</time>
        </span>
      ) : null}
    </p>
  );
}

function Dashboard({ view, connection }: { view: DashboardSnapshot; connection: Connection }) {
  return (
    <>
      {connection === "reconnecting" ? (
        <p className="banner banner-warn" role="alert">
          Lost the live connection. Showing the last snapshot from {formatClock(view.generatedAt)} until the server answers.
        </p>
      ) : null}
      {view.mode === "passive" ? (
        <p className="banner banner-passive" role="status">
          Probes disabled. Quota numbers stay unknown in passive mode.
        </p>
      ) : null}
      {view.providers.length === 0 ? <p className="empty">No provider data</p> : null}
      <div className="cards">
        {PROVIDERS.map((provider) => (
          <QuotaCard
            key={provider.id}
            label={provider.label}
            quota={view.providers.find((item) => item.provider === provider.id) ?? null}
            generatedAt={view.generatedAt}
          />
        ))}
      </div>
      <AgentTable sessions={view.sessions} worktrees={view.worktrees} generatedAt={view.generatedAt} />
      <div className="lower">
        <AlertList alerts={view.alerts} generatedAt={view.generatedAt} />
        <SourceStatus sources={view.sources} alerts={view.alerts} />
      </div>
      <GitPanel sessions={view.sessions} worktrees={view.worktrees} />
    </>
  );
}
