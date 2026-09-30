import { useEffect, useState } from "react";
import type { DashboardSnapshot, ProviderId } from "@herdr/contracts";
import { AgentTable } from "./AgentTable.js";
import { AlertList, sourceProblemAlerts } from "./Alerts.js";
import { isAbortError, loadSnapshot, subscribeSnapshots } from "./api.js";
import { sourceLine } from "./format.js";
import { GitPanel } from "./GitPanel.js";
import { QuotaCard } from "./QuotaCard.js";
import { applyTheme, readThemeChoice, resolvedTheme, storeThemeChoice, type ThemeChoice } from "./theme.js";

const PROVIDERS: readonly { id: ProviderId; label: string }[] = [
  { id: "claude", label: "Claude" },
  { id: "codex", label: "Codex" },
  { id: "grok", label: "Grok" },
];

type View =
  | { status: "loading" }
  | { status: "error" }
  | { status: "ready"; snapshot: DashboardSnapshot };

export function App() {
  const [view, setView] = useState<View>({ status: "loading" });
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
      .then((snapshot) => {
        if (active) setView({ status: "ready", snapshot });
      })
      .catch((error: unknown) => {
        if (!active || controller.signal.aborted || isAbortError(error)) return;
        setView({ status: "error" });
      });
    const stop = subscribeSnapshots((snapshot) => {
      if (active) setView({ status: "ready", snapshot });
    });
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
        <div>
          <h1>herdr dashboard</h1>
          <p className="lede">Read-only localhost view. No agent actions.</p>
        </div>
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
      </header>
      {view.status === "loading" ? <p role="status">Loading dashboard</p> : null}
      {view.status === "error" ? <p role="alert">Dashboard unavailable</p> : null}
      {view.status === "ready" ? <Dashboard view={view.snapshot} /> : null}
    </main>
  );
}

function SourceProblems({ alerts }: { alerts: DashboardSnapshot["alerts"] }) {
  const problems = sourceProblemAlerts(alerts);
  if (problems.length === 0) return <p>No source problems</p>;
  return (
    <div className="source-problems">
      <h3>Source problems</h3>
      <ul>
        {problems.map((alert) => (
          <li key={alert.id}>{alert.message}</li>
        ))}
      </ul>
    </div>
  );
}

function Dashboard({ view }: { view: DashboardSnapshot }) {
  return (
    <>
      {view.mode === "fixture" ? <p className="banner" role="status">Demo data</p> : null}
      {view.mode === "passive" ? <p className="banner banner-passive" role="status">Probes disabled</p> : null}
      {view.providers.length === 0 ? <p>No provider data</p> : null}
      <div className="workspace">
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
      </div>
      <AlertList alerts={view.alerts} />
      <GitPanel sessions={view.sessions} worktrees={view.worktrees} />
      <section className="sources" aria-labelledby="source-status-heading">
        <h2 id="source-status-heading">Source status</h2>
        {view.sources.length === 0 ? <p>No source reports</p> : (
          <ul>
            {view.sources.map((source) => (
              <li key={source.sourceId}>{sourceLine(source)}</li>
            ))}
          </ul>
        )}
        <SourceProblems alerts={view.alerts} />
      </section>
    </>
  );
}
