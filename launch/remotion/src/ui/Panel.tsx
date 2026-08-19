import React from "react";
import { theme, panelWidth } from "../theme";
import { FlockMark } from "./FlockMark";

export type AgentState = "blocked" | "silent" | "working" | "done" | "idle";

export type DemoAgent = {
  name: string;
  kind: string;
  location: string;
  state: AgentState;
  dwell: string;
  reason?: string;
  cost: string;
  awaiting?: boolean;
};

export const DEMO_NEEDS_YOU: DemoAgent[] = [
  {
    name: "Claude",
    kind: "claude",
    location: "claude · herdr-manager · ~src",
    state: "blocked",
    dwell: "4m12s",
    reason: "waiting on a permission prompt",
    cost: "~$1.24 today",
    awaiting: true,
  },
  {
    name: "Codex",
    kind: "codex",
    location: "codex · api-gateway · ~services",
    state: "silent",
    dwell: "12m04s",
    reason: "no output for 12m",
    cost: "~$0.86 today",
  },
];

const STATE: Record<
  AgentState,
  { color: string; strong: string; word: string; glyph: string }
> = {
  blocked: { color: theme.blocked, strong: theme.blockedStrong, word: "blocked", glyph: "!" },
  silent: { color: theme.silent, strong: "#FFD873", word: "silent", glyph: "z" },
  working: { color: theme.working, strong: "#70E6A1", word: "working", glyph: "▶" },
  done: { color: theme.done, strong: "#8AB8FF", word: "done", glyph: "✓" },
  idle: { color: theme.idle, strong: "#A8C2BA", word: "idle", glyph: "⏸" },
};

const IconBtn: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <div
    style={{
      width: 30,
      height: 30,
      borderRadius: 15,
      background: "rgba(255,255,255,0.06)",
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
      color: theme.text,
    }}
  >
    {children}
  </div>
);

const StrokeIcon: React.FC<{ d: string }> = ({ d }) => (
  <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
    <path d={d} stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" />
  </svg>
);

export const PanelChrome: React.FC<{
  children: React.ReactNode;
  subtitle: string;
  scope: "needs" | "running" | "all";
  needs: number;
  running: number;
  all: number;
  footer?: React.ReactNode;
  height?: number;
}> = ({ children, subtitle, scope, needs, running, all, footer, height }) => {
  return (
    <div
      style={{
        width: panelWidth,
        height: height ?? 640,
        borderRadius: 12,
        background: "rgba(28,30,32,0.96)",
        border: "1px solid rgba(255,255,255,0.08)",
        boxShadow: "0 24px 80px rgba(0,0,0,0.55), 0 0 0 1px rgba(255,255,255,0.04)",
        overflow: "hidden",
        fontFamily: theme.font,
        color: theme.text,
        display: "flex",
        flexDirection: "column",
      }}
    >
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 10,
          padding: "13px 14px 11px",
        }}
      >
        <FlockMark size={20} />
        <div style={{ display: "flex", flexDirection: "column", gap: 1, flex: 1 }}>
          <div style={{ fontSize: 15, fontWeight: 700, letterSpacing: -0.2 }}>Shepherd</div>
          <div style={{ fontSize: 11, color: theme.secondary }}>{subtitle}</div>
        </div>
        <IconBtn>
          <StrokeIcon d="M2 10.5 L5 7.5 L7.2 9.2 L12 4.5 M8.5 4.5 H12 V8" />
        </IconBtn>
        <IconBtn>
          <StrokeIcon d="M11.2 7 A4.2 4.2 0 1 1 10.4 4.2 M11.2 2.6 V4.6 H9.2" />
        </IconBtn>
        <IconBtn>
          <StrokeIcon d="M7 2.4 V4.2 M7 9.8 V11.6 M4.4 3.3 L5.5 4.6 M8.5 9.4 L9.6 10.7 M3.3 6.2 H5.1 M8.9 6.2 H10.7 M4.4 10.7 L5.5 9.4 M8.5 4.6 L9.6 3.3 M7 5.4 A2.4 2.4 0 1 0 7 10.2 A2.4 2.4 0 1 0 7 5.4 Z" />
        </IconBtn>
        <IconBtn>
          <svg width="14" height="14" viewBox="0 0 14 14" fill="currentColor">
            <circle cx="3.2" cy="7" r="1.05" />
            <circle cx="7" cy="7" r="1.05" />
            <circle cx="10.8" cy="7" r="1.05" />
          </svg>
        </IconBtn>
      </div>

      <div style={{ padding: "0 14px 10px", display: "flex", flexDirection: "column", gap: 9 }}>
        <div
          style={{
            display: "flex",
            alignItems: "center",
            background: "rgba(255,255,255,0.06)",
            borderRadius: 8,
            padding: 3,
            gap: 0,
          }}
        >
          <ScopeTab active={scope === "needs"} label={`Needs you ${needs}`} />
          <ScopeTab active={scope === "running"} label={`Running ${running}`} />
          <div style={{ width: 1, height: 16, background: "rgba(255,255,255,0.18)", margin: "0 4px" }} />
          <ScopeTab active={scope === "all"} label={`All ${all}`} />
        </div>
        <div
          style={{
            height: 28,
            borderRadius: 7,
            background: "rgba(255,255,255,0.05)",
            border: "1px solid rgba(255,255,255,0.08)",
            display: "flex",
            alignItems: "center",
            padding: "0 10px",
            color: theme.secondary,
            fontSize: 12.5,
            gap: 8,
          }}
        >
          <span style={{ opacity: 0.7 }}>⌕</span>
          Filter by name, kind, workspace…
        </div>
      </div>

      <div style={{ flex: 1, overflow: "hidden" }}>{children}</div>

      <div
        style={{
          display: "flex",
          alignItems: "center",
          padding: "8px 14px 10px",
          borderTop: "1px solid rgba(255,255,255,0.06)",
          fontSize: 11,
          color: theme.secondary,
        }}
      >
        {footer ?? (
          <>
            <span style={{ fontSize: 14, marginRight: 6 }}>+</span>
            New agent
            <span style={{ marginLeft: "auto", display: "flex", alignItems: "center", gap: 6 }}>
              <span
                style={{
                  width: 7,
                  height: 7,
                  borderRadius: 99,
                  background: theme.working,
                  display: "inline-block",
                }}
              />
              connected
            </span>
          </>
        )}
      </div>
    </div>
  );
};

const ScopeTab: React.FC<{ active: boolean; label: string }> = ({ active, label }) => (
  <div
    style={{
      flex: 1,
      textAlign: "center",
      padding: "6px 8px",
      borderRadius: 6,
      fontSize: 12,
      fontWeight: 600,
      background: active ? theme.systemBlue : "transparent",
      color: active ? "white" : theme.text,
    }}
  >
    {label}
  </div>
);

export const AgentCard: React.FC<{
  agent: DemoAgent;
  selected?: boolean;
  showActions?: boolean;
  highlightApprove?: boolean;
  peek?: string | null;
}> = ({ agent, selected, showActions, highlightApprove, peek }) => {
  const face = STATE[agent.state];
  return (
    <div
      style={{
        margin: "1px 12px",
        borderRadius: 10,
        background: selected ? "rgba(255,201,77,0.06)" : "rgba(255,255,255,0.025)",
        border: `1.25px solid ${
          selected ? "rgba(255,201,77,0.85)" : `${face.color}24`
        }`,
        display: "flex",
        overflow: "hidden",
      }}
    >
      <div
        style={{
          width: 3.5,
          margin: "8px 0 8px 8px",
          borderRadius: 99,
          background: face.color,
          boxShadow: `0 0 ${agent.state === "blocked" ? 5 : 3}px ${face.color}`,
          flexShrink: 0,
        }}
      />
      <div style={{ flex: 1, padding: "10px 12px 10px 11px" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 7 }}>
          <div
            style={{
              width: 16,
              height: 16,
              borderRadius: 99,
              border: `1.5px solid ${face.color}`,
              color: face.color,
              fontSize: 10,
              fontWeight: 700,
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              flexShrink: 0,
            }}
          >
            {face.glyph}
          </div>
          <div style={{ fontSize: 13.5, fontWeight: 600, flex: 1 }}>{agent.name}</div>
          <div
            style={{
              fontSize: 10.5,
              fontWeight: 600,
              letterSpacing: 0.4,
              textTransform: "uppercase",
              color: face.strong,
              background: `${face.color}24`,
              border: `0.5px solid ${face.color}47`,
              borderRadius: 999,
              padding: "2.5px 7px",
            }}
          >
            {face.word}
          </div>
          <div
            style={{
              fontFamily: theme.mono,
              fontSize: 11.5,
              fontWeight: agent.state === "blocked" ? 700 : 500,
              color: agent.state === "blocked" ? face.color : theme.secondary,
            }}
          >
            {agent.dwell}
          </div>
        </div>
        {agent.reason ? (
          <div
            style={{
              marginTop: 4,
              fontSize: 12.5,
              fontWeight: 500,
              color: agent.state === "blocked" ? theme.blocked : theme.silent,
            }}
          >
            {agent.reason}
          </div>
        ) : null}
        <div style={{ marginTop: 4, fontSize: 10.5, color: theme.secondary }}>{agent.location}</div>
        <div
          style={{
            marginTop: 4,
            fontFamily: theme.mono,
            fontSize: 10.5,
            color: theme.amber,
          }}
        >
          {agent.cost}
        </div>

        {showActions ? (
          <div style={{ display: "flex", gap: 6, marginTop: 8 }}>
            <GhostBtn>Peek</GhostBtn>
            <GhostBtn>Jump</GhostBtn>
            <GhostBtn>Nudge</GhostBtn>
          </div>
        ) : null}

        {agent.awaiting && selected ? (
          <div style={{ display: "flex", gap: 7, marginTop: 8, alignItems: "center" }}>
            <div
              style={{
                background: theme.approve,
                color: "white",
                borderRadius: 7,
                padding: "6px 12px",
                fontSize: 12,
                fontWeight: 600,
                boxShadow: highlightApprove
                  ? `0 0 0 3px ${theme.working}66, 0 0 18px ${theme.working}55`
                  : "none",
              }}
            >
              ✓ Approve
            </div>
            <div
              style={{
                border: `1px solid ${theme.blockedStrong}88`,
                color: theme.blockedStrong,
                borderRadius: 7,
                padding: "6px 12px",
                fontSize: 12,
                fontWeight: 600,
              }}
            >
              ✕ Deny
            </div>
          </div>
        ) : null}

        {peek ? (
          <div
            style={{
              marginTop: 8,
              background: "rgba(0,0,0,0.35)",
              borderRadius: 6,
              padding: 8,
              fontFamily: theme.mono,
              fontSize: 11,
              lineHeight: 1.45,
              color: "#D7D9DB",
              whiteSpace: "pre-wrap",
            }}
          >
            {peek}
          </div>
        ) : null}
      </div>
    </div>
  );
};

const GhostBtn: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <div
    style={{
      flex: 1,
      textAlign: "center",
      padding: "7px 0",
      borderRadius: 7,
      background: "rgba(255,255,255,0.08)",
      border: "1px solid rgba(255,255,255,0.22)",
      fontSize: 12,
      fontWeight: 600,
    }}
  >
    {children}
  </div>
);

export const QuietEmpty: React.FC = () => (
  <div
    style={{
      height: "100%",
      display: "flex",
      flexDirection: "column",
      alignItems: "center",
      justifyContent: "center",
      gap: 10,
      paddingBottom: 24,
    }}
  >
    <FlockMark size={40} />
    <div style={{ fontSize: 16, fontWeight: 700 }}>All quiet</div>
    <div style={{ fontSize: 12.5, color: theme.secondary }}>
      6 agents are working. Nothing needs you.
    </div>
  </div>
);

export const PERMISSION_PEEK = `Claude wants to run:

  git diff --stat HEAD~1

❯ 1. Yes
  2. No, and tell Claude what to do differently

enter to select · esc to cancel`;
