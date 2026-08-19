import React from "react";
import { theme } from "../theme";
import { FlockMark } from "./FlockMark";

export const MenuBarMock: React.FC<{
  count?: number;
  attention?: "blocked" | "silent" | "calm";
}> = ({ count = 2, attention = "blocked" }) => {
  const color =
    attention === "blocked" ? "#FF3B30" : attention === "silent" ? "#FFD60A" : theme.working;
  return (
    <div
      style={{
        width: 720,
        height: 38,
        borderRadius: 10,
        background: "rgba(22,24,26,0.92)",
        border: "1px solid rgba(255,255,255,0.08)",
        display: "flex",
        alignItems: "center",
        padding: "0 14px",
        fontFamily: theme.font,
        color: theme.text,
        boxShadow: "0 16px 40px rgba(0,0,0,0.4)",
      }}
    >
      <div style={{ fontSize: 13, fontWeight: 600, marginRight: 16 }}>Finder</div>
      <div style={{ fontSize: 13, color: theme.secondary }}>File</div>
      <div style={{ marginLeft: "auto", display: "flex", alignItems: "center", gap: 12 }}>
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: 5,
            background: "rgba(255,255,255,0.06)",
            borderRadius: 7,
            padding: "3px 7px 3px 5px",
          }}
        >
          <FlockMark size={15} />
          {attention !== "calm" ? (
            <>
              <div
                style={{
                  width: 8,
                  height: 8,
                  background: color,
                  clipPath:
                    attention === "blocked"
                      ? "polygon(50% 8%, 100% 92%, 0 92%)"
                      : "polygon(50% 0, 100% 50%, 50% 100%, 0 50%)",
                }}
              />
              <div style={{ fontSize: 12.5, fontWeight: 700, color }}>{count}</div>
            </>
          ) : null}
        </div>
        <div style={{ fontSize: 13, opacity: 0.7 }}>Tue 7:12</div>
      </div>
    </div>
  );
};
