import { useEffect, useState } from "react";
import type { AgentSession, GitWorktree } from "@herdr/contracts";
import { formatElapsed } from "./format.js";
import { filterSessions, providerLabel, statusLabel, worktreeForCwd } from "./sessions.js";
import { Timestamp } from "./Timestamp.js";
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
  const filtered = provider !== "all" || status !== "all" || search.trim() !== "";

  useEffect(() => {
    if (openId === null) return () => undefined;
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === "Escape") setOpenId(null);
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [openId]);

  return (
    <section className="panel agents" aria-labelledby="agents-heading">
      <div className="panel-head">
        <h2 id="agents-heading">
          Agents <span className="count">{filtered ? `${visible.length} of ${sessions.length}` : sessions.length}</span>
        </h2>
        <div className="filters">
          <label>
            <span className="visually-hidden">Provider</span>
            <select aria-label="Provider" value={provider} onChange={(event) => setProvider(event.target.value)}>
              {PROVIDER_OPTIONS.map((option) => (
                <option key={option} value={option}>
                  {option === "all" ? "All providers" : providerLabel(option)}
                </option>
              ))}
            </select>
          </label>
          <label>
            <span className="visually-hidden">Status</span>
            <select aria-label="Status" value={status} onChange={(event) => setStatus(event.target.value)}>
              {STATUS_OPTIONS.map((option) => (
                <option key={option} value={option}>
                  {option === "all" ? "All statuses" : statusLabel(option)}
                </option>
              ))}
            </select>
          </label>
          <label>
            <span className="visually-hidden">Search agents</span>
            <input
              type="search"
              aria-label="Search agents"
              placeholder="Label, directory, or id"
              value={search}
              onChange={(event) => setSearch(event.target.value)}
              autoComplete="off"
            />
          </label>
        </div>
      </div>
      <div className="table-wrap" role="region" aria-label="Agent table" tabIndex={0}>
        <table>
          <caption className="visually-hidden">Agents, attention first: blocked, working, idle, done, unknown</caption>
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
                <td colSpan={5} className="empty-row">
                  {sessions.length === 0 ? "No agents" : "No matching agents"}
                </td>
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
      <tr className={open ? "agent-row agent-row-open" : "agent-row"}>
        <th scope="row">
          <button
            type="button"
            className="detail"
            aria-expanded={open}
            aria-controls={open ? detailId : undefined}
            onClick={onToggle}
          >
            <span className="chevron" aria-hidden="true" />
            <span className="visually-hidden">{action} </span>
            <span className="agent-label">{session.label}</span>
          </button>
          {session.cwd ? <span className="agent-cwd">{session.cwd}</span> : null}
        </th>
        <td>{providerLabel(session.provider)}</td>
        <td>
          <span className={`status status-${session.status}`}>{statusLabel(session.status)}</span>
        </td>
        <td className="num">{formatElapsed(session.enteredAt, generatedAt)}</td>
        <td className="provenance">
          {session.evidenceSource} · {session.confidence}
        </td>
      </tr>
      {open ? (
        <tr className="detail-row">
          <td id={detailId} colSpan={5}>
            <div className="detail-body" role="region" aria-label={`Details for ${session.label}`}>
              <div className="facts">
                <p>
                  <span className="k">Entered</span> <Timestamp iso={session.enteredAt} />
                </p>
                <p>
                  <span className="k">Dwell</span> {formatElapsed(session.enteredAt, generatedAt)}
                </p>
                <p>
                  <span className="k">Provenance</span> {session.evidenceSource}, {session.confidence}
                </p>
                <p>
                  <span className="k">Directory</span> {session.cwd ?? "unknown"}
                </p>
                {session.loop ? (
                  <p>
                    <span className="k">Loop</span> {session.loop.kind} / {session.loop.state}. Source {session.loop.source}.
                  </p>
                ) : (
                  <p>
                    <span className="k">Loop</span> not reported
                  </p>
                )}
                {session.loop?.iteration != null ? (
                  <p>
                    <span className="k">Iteration</span> {session.loop.iteration}
                  </p>
                ) : null}
                {session.loop?.objective ? (
                  <p>
                    <span className="k">Objective</span> {session.loop.objective}
                  </p>
                ) : null}
              </div>
              {worktree ? <WorktreeFacts tree={worktree} /> : <p className="empty">No mapped worktree</p>}
            </div>
          </td>
        </tr>
      ) : null}
    </>
  );
}
