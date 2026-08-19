import React from "react";
import { theme, panelWidth } from "../theme";

export const UsageDash: React.FC = () => {
  const models = [
    { name: "claude-opus-4.1", cost: "$2.14", tokens: "412k", bar: 0.78 },
    { name: "gpt-4.1", cost: "$1.41", tokens: "288k", bar: 0.52 },
    { name: "grok-4.6", cost: "$0.73", tokens: "191k", bar: 0.27 },
  ];
  return (
    <div
      style={{
        width: panelWidth,
        height: 640,
        borderRadius: 12,
        background: "rgba(28,30,32,0.96)",
        border: "1px solid rgba(255,255,255,0.08)",
        boxShadow: "0 24px 80px rgba(0,0,0,0.55)",
        overflow: "hidden",
        fontFamily: theme.font,
        color: theme.text,
        display: "flex",
        flexDirection: "column",
      }}
    >
      <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "13px 14px 11px" }}>
        <div
          style={{
            width: 30,
            height: 30,
            borderRadius: 15,
            background: "rgba(255,255,255,0.06)",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            fontSize: 14,
          }}
        >
          ‹
        </div>
        <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
          <path
            d="M2 11.5 L5.2 8.2 L7.6 10.1 L14 4"
            stroke={theme.amber}
            strokeWidth="1.6"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
        <div>
          <div style={{ fontSize: 15, fontWeight: 700 }}>Usage & cost</div>
          <div style={{ fontSize: 11, color: theme.secondary }}>
            API-equivalent list-price estimate
          </div>
        </div>
      </div>

      <div style={{ padding: "0 14px 10px" }}>
        <div
          style={{
            display: "flex",
            background: "rgba(255,255,255,0.06)",
            borderRadius: 8,
            padding: 3,
          }}
        >
          {["Today", "7 days", "30 days"].map((label, i) => (
            <div
              key={label}
              style={{
                flex: 1,
                textAlign: "center",
                padding: "6px 8px",
                borderRadius: 6,
                fontSize: 12,
                fontWeight: 600,
                background: i === 0 ? theme.systemBlue : "transparent",
                color: "white",
              }}
            >
              {label}
            </div>
          ))}
        </div>
      </div>

      <div
        style={{
          margin: "0 14px 12px",
          padding: 14,
          borderRadius: 10,
          background: "rgba(255,201,77,0.09)",
        }}
      >
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start" }}>
          <div>
            <div style={{ fontSize: 12, fontWeight: 600 }}>All local activity</div>
            <div style={{ fontSize: 11, color: theme.secondary, marginTop: 2 }}>Today</div>
          </div>
          <div style={{ textAlign: "right" }}>
            <div
              style={{
                fontSize: 26,
                fontWeight: 700,
                fontFamily: theme.font,
                color: theme.amber,
                letterSpacing: -0.4,
              }}
            >
              ~$4.28
            </div>
            <div style={{ fontSize: 10, fontWeight: 500, color: theme.secondary }}>
              Estimate — not a bill
            </div>
          </div>
        </div>
        <div style={{ display: "flex", gap: 12, marginTop: 10, fontSize: 11, color: theme.secondary }}>
          <span>891k tokens</span>
          <span>14 sessions</span>
        </div>
      </div>

      <div style={{ padding: "0 14px", display: "flex", flexDirection: "column", gap: 8 }}>
        {models.map((m) => (
          <div
            key={m.name}
            style={{
              padding: "10px 12px",
              borderRadius: 10,
              background: "rgba(255,255,255,0.03)",
              border: "1px solid rgba(255,255,255,0.06)",
            }}
          >
            <div style={{ display: "flex", justifyContent: "space-between", fontSize: 12.5 }}>
              <span style={{ fontWeight: 600 }}>{m.name}</span>
              <span style={{ color: theme.amber, fontFamily: theme.mono }}>{m.cost}</span>
            </div>
            <div
              style={{
                marginTop: 8,
                height: 4,
                borderRadius: 99,
                background: "rgba(255,255,255,0.08)",
                overflow: "hidden",
              }}
            >
              <div
                style={{
                  width: `${m.bar * 100}%`,
                  height: "100%",
                  background: theme.amberDeep,
                }}
              />
            </div>
            <div style={{ marginTop: 6, fontSize: 10.5, color: theme.secondary, fontFamily: theme.mono }}>
              {m.tokens}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
};
