import React from "react";
import { displayFont, uiFont } from "../fonts";

type Row = {
  name: string;
  kind: string;
  state: "blocked" | "silent" | "working" | "idle" | "done";
  workspace: string;
};

const ROWS: Row[] = [
  { name: "Claude", kind: "claude", state: "blocked", workspace: "herdr-manager" },
  { name: "Codex", kind: "codex", state: "silent", workspace: "api-gateway" },
  { name: "OpenCode", kind: "opencode", state: "working", workspace: "herdr-manager" },
  { name: "Claude", kind: "claude", state: "working", workspace: "website" },
  { name: "Grok", kind: "grok", state: "working", workspace: "herdr-manager" },
  { name: "Codex", kind: "codex", state: "working", workspace: "website" },
  { name: "Claude", kind: "claude", state: "idle", workspace: "docs" },
  { name: "OpenCode", kind: "opencode", state: "done", workspace: "api-gateway" },
];

const STATE_COLOR: Record<Row["state"], string> = {
  blocked: "#FF6B6B",
  silent: "#FFC94D",
  working: "#8BADDC",
  idle: "#8F9AAB",
  done: "#6CA6FF",
};

export const HerdrWindow: React.FC<{
  highlightBlocked?: boolean;
  width?: number;
  height?: number;
}> = ({ highlightBlocked = true, width = 980, height = 620 }) => {
  return (
    <div
      style={{
        width,
        height,
        borderRadius: 12,
        overflow: "hidden",
        background: "#0B1220",
        border: "1px solid rgba(255,255,255,0.10)",
        boxShadow: "0 28px 80px rgba(0,0,0,0.55)",
        fontFamily: uiFont,
        color: "#E8ECF2",
        display: "flex",
        flexDirection: "column",
      }}
    >
      <div
        style={{
          height: 36,
          background: "#11192A",
          borderBottom: "1px solid rgba(255,255,255,0.06)",
          display: "flex",
          alignItems: "center",
          padding: "0 12px",
          gap: 8,
        }}
      >
        <span style={{ width: 10, height: 10, borderRadius: 99, background: "#FF5F57" }} />
        <span style={{ width: 10, height: 10, borderRadius: 99, background: "#FEBC2E" }} />
        <span style={{ width: 10, height: 10, borderRadius: 99, background: "#28C840" }} />
        <div
          style={{
            marginLeft: 10,
            fontFamily: displayFont,
            fontSize: 12,
            fontWeight: 600,
            color: "#A8B2C2",
          }}
        >
          herdr — 27 panes · 2 need you
        </div>
      </div>

      <div style={{ display: "flex", flex: 1, minHeight: 0 }}>
        <div
          style={{
            width: 220,
            background: "#0E1628",
            borderRight: "1px solid rgba(255,255,255,0.06)",
            padding: "10px 8px",
            display: "flex",
            flexDirection: "column",
            gap: 3,
          }}
        >
          <div
            style={{
              fontSize: 10,
              fontWeight: 700,
              letterSpacing: 1.2,
              textTransform: "uppercase",
              color: "#8F9AAB",
              padding: "4px 8px 8px",
            }}
          >
            Agents
          </div>
          {ROWS.map((row, i) => {
            const hot = highlightBlocked && row.state === "blocked";
            return (
              <div
                key={`${row.name}-${i}`}
                style={{
                  display: "flex",
                  alignItems: "center",
                  gap: 8,
                  padding: "7px 8px",
                  borderRadius: 7,
                  background: hot ? "rgba(255,107,107,0.12)" : i === 0 ? "rgba(255,255,255,0.05)" : "transparent",
                  border: hot ? "1px solid rgba(255,107,107,0.35)" : "1px solid transparent",
                }}
              >
                <span
                  style={{
                    width: 7,
                    height: 7,
                    borderRadius: 99,
                    background: STATE_COLOR[row.state],
                    flexShrink: 0,
                  }}
                />
                <div style={{ minWidth: 0, flex: 1 }}>
                  <div style={{ fontSize: 12, fontWeight: 600 }}>{row.name}</div>
                  <div style={{ fontSize: 10, color: "#8F9AAB" }}>{row.workspace}</div>
                </div>
                <div
                  style={{
                    fontSize: 9,
                    fontWeight: 700,
                    letterSpacing: 0.4,
                    textTransform: "uppercase",
                    color: STATE_COLOR[row.state],
                  }}
                >
                  {row.state}
                </div>
              </div>
            );
          })}
        </div>

        <div style={{ flex: 1, display: "flex", flexDirection: "column", minWidth: 0 }}>
          <div
            style={{
              height: 32,
              display: "flex",
              alignItems: "center",
              gap: 6,
              padding: "0 10px",
              borderBottom: "1px solid rgba(255,255,255,0.06)",
              background: "#10182A",
              fontSize: 11,
              fontWeight: 600,
            }}
          >
            {["Claude", "Codex", "OpenCode", "Grok"].map((tab, i) => (
              <div
                key={tab}
                style={{
                  padding: "4px 10px",
                  borderRadius: 6,
                  background: i === 0 ? "rgba(139,173,220,0.18)" : "transparent",
                  color: i === 0 ? "#E8ECF2" : "#8F9AAB",
                }}
              >
                {tab}
              </div>
            ))}
          </div>

          <div
            style={{
              flex: 1,
              padding: 16,
              fontFamily: 'SF Mono, ui-monospace, Menlo, Monaco, monospace',
              fontSize: 13,
              lineHeight: 1.55,
              color: "#C9D2DE",
              background: "#0A101C",
              whiteSpace: "pre-wrap",
            }}
          >
            <div style={{ color: "#8BADDC" }}>Claude Code · herdr-manager · ~src</div>
            <div style={{ marginTop: 14, color: "#E8ECF2" }}>Claude wants to run:</div>
            <div style={{ marginTop: 8, color: "#FFC94D" }}>  git diff --stat HEAD~1</div>
            <div style={{ marginTop: 16 }}>
              <span style={{ color: "#8BADDC" }}>❯ </span>1. Yes
            </div>
            <div>  2. No, and tell Claude what to do differently</div>
            <div style={{ marginTop: 18, color: "#8F9AAB" }}>enter to select · esc to cancel</div>
          </div>
        </div>
      </div>

      <div
        style={{
          height: 26,
          background: "#11192A",
          borderTop: "1px solid rgba(255,255,255,0.06)",
          display: "flex",
          alignItems: "center",
          padding: "0 12px",
          fontSize: 11,
          color: "#8F9AAB",
          justifyContent: "space-between",
        }}
      >
        <span>herdr · protocol 17</span>
        <span>2 blocked · 1 silent · 6 working</span>
      </div>
    </div>
  );
};
