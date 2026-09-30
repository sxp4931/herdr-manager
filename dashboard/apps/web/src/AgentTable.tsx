import { useEffect, useState } from "react";
import type { AgentSession, GitWorktree } from "@herdr/contracts";
import { formatAbsolute, formatElapsed } from "./format.js";
import { filterSessions, providerLabel, statusLabel, worktreeForCwd } from "./sessions.js";
import { WorktreeFacts } from "./WorktreeFacts.js";

const PROVIDER_OPTIONS = ["all", "claude", "codex", "grok"] as const;
const STATUS_OPTIONS = ["all", "blocked", "working", "idle", "done", "unknown"] as const;

export function AgentTable({
  sessions,
  worktrees,
  generatedAt,
}: {
  sessions: readonly AgentSession[];
  worktrees: readonly GitWorktree[];
  generatedAt: string;
}) {
  const [provider, setProvider] = useState("all");
  const [status, setStatus] = useState("all");
  const [search, setSearch] = useState("");
  const [openId, setOpenId] = useState<string | null>(null);
  const visible = filterSessions(sessions, { provider, status, search });

  useEffect(() => {
    if (openId === null) return () => undefined;
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === "Escape") setOpenId(null);
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [openId]);

  return (
    <section className="panel" aria-labelledby="agents-heading">
      <h2 id="agents-heading">Agents</h2>
      <div className="filters">
        <label>
          Provider
          <select aria-label="Provider" value={provider} onChange={(event) => setProvider(event.target.value)}>
            {PROVIDER_OPTIONS.map((option) => (
              <option key={option} value={option}>
                {option === "all" ? "All providers" : providerLabel(option)}
              </option>
            ))}
          </select>
        </label>
        <label>
          Status
          <select aria-label="Status" value={status} onChange={(event) => setStatus(event.target.value)}>
            {STATUS_OPTIONS.map((option) => (
              <option key={option} value={option}>
                {option === "all" ? "All statuses" : statusLabel(option)}
              </option>
            ))}
          </select>
        </label>
        <label>
          Search agents
          <input
            type="search"
            aria-label="Search agents"
            value={search}
            onChange={(event) => setSearch(event.target.value)}
            autoComplete="off"
          />
        </label>
      </div>
      <div className="table-wrap">
        <table>
          <caption>Agents</caption>
          <thead>
            <tr>
              <th scope="col">Agent</th>
              <th scope="col">Provider</th>
              <th scope="col">Status</th>
              <th scope="col">Dwell</th>
              <th scope="col">Provenance</th>
            </tr>
          </thead>
          <tbody>
            {visible.length === 0 ? (
              <tr>
                <td colSpan={5}>{sessions.length === 0 ? "No agents" : "No matching agents"}</td>
              </tr>
            ) : null}
            {visible.map((session) => {
              const open = openId === session.id;
              const detailId = `agent-detail-${session.id.replace(/[^a-zA-Z0-9_-]/g, "-")}`;
              const worktree = worktreeForCwd(session.cwd, worktrees);
              return (
                <AgentRows
                  key={session.id}
                  session={session}
                  open={open}
                  detailId={detailId}
                  generatedAt={generatedAt}
                  worktree={worktree}
                  onToggle={() => setOpenId(open ? null : session.id)}
                />
              );
            })}
          </tbody>
        </table>
      </div>
    </section>
  );
}

function AgentRows({
  session,
  open,
  detailId,
  generatedAt,
  worktree,
  onToggle,
}: {
  session: AgentSession;
  open: boolean;
  detailId: string;
  generatedAt: string;
  worktree: GitWorktree | null;
  onToggle: () => void;
}) {
  const action = open ? "Hide details for" : "Show details for";
  return (
    <>
      <tr>
        <th scope="row">
          <button type="button" className="detail" aria-expanded={open} aria-controls={detailId} onClick={onToggle}>
            {action} {session.label}
          </button>
        </th>
        <td>{providerLabel(session.provider)}</td>
        <td>{statusLabel(session.status)}</td>
        <td>{formatElapsed(session.enteredAt, generatedAt)}</td>
        <td>
          {session.evidenceSource} · {session.confidence}
        </td>
      </tr>
      {open ? (
        <tr>
          <td id={detailId} colSpan={5}>
            <div className="detail-body" role="region" aria-label={`Details for ${session.label}`}>
              <p>Entered {formatAbsolute(session.enteredAt)}</p>
              <p>Dwell {formatElapsed(session.enteredAt, generatedAt)}</p>
              <p>
                Provenance {session.evidenceSource}, {session.confidence}
              </p>
              <p>Directory {session.cwd ?? "unknown"}</p>
              {session.loop ? (
                <p>
                  Loop {session.loop.kind} / {session.loop.state}. Source {session.loop.source}.
                </p>
              ) : (
                <p>Loop not reported</p>
              )}
              {session.loop?.iteration != null ? <p>Iteration {session.loop.iteration}</p> : null}
              {session.loop?.objective ? <p>Objective {session.loop.objective}</p> : null}
              {worktree ? <WorktreeFacts tree={worktree} /> : <p>No mapped worktree</p>}
            </div>
          </td>
        </tr>
      ) : null}
    </>
  );
}
