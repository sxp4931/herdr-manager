import React from "react";
import {
  AbsoluteFill,
  CanvasImage,
  Easing,
  Interactive,
  interpolate,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { displayFont } from "../fonts";


export const SceneEnd: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  return (
    <AbsoluteFill name="End" style={{ backgroundColor: "#070A0B" }}>

      <AbsoluteFill
        style={{
          background:
            "radial-gradient(900px 600px at 50% 42%, rgba(16,28,64,0.45), rgba(7,9,16,0.92))",
        }}
      />

      <AbsoluteFill
        style={{
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          justifyContent: "center",
        }}
      >
        <Interactive.Div
          name="Icon"
          style={{
            width: 176,
            height: 176,
            borderRadius: 40,
            overflow: "hidden",
            backgroundColor: "#141F2F",
            boxShadow: "0 18px 50px rgba(0,0,0,0.45)",
            scale: interpolate(frame, [0, 0.7 * fps], [0.96, 1], {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
              easing: Easing.bezier(0.16, 1, 0.3, 1),
              output: "perceptual-scale",
            }),
          }}
        >
          <CanvasImage
            src={staticFile("icon.png")}
            style={{
              width: 176,
              height: 176,
              display: "block",
            }}
          />
        </Interactive.Div>

        <Interactive.Div
          name="Wordmark"
          style={{
            marginTop: 28,
            fontFamily: displayFont,
            fontSize: 72,
            fontWeight: 700,
            letterSpacing: -2,
            color: "#F5F5F7",
            opacity: interpolate(frame, [0.25 * fps, 0.75 * fps], [0, 1], {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
              easing: Easing.bezier(0.16, 1, 0.3, 1),
            }),
          }}
        >
          Shepherd
        </Interactive.Div>

        <Interactive.Div
          name="Tagline"
          style={{
            marginTop: 10,
            fontFamily: displayFont,
            fontSize: 28,
            fontWeight: 500,
            color: "#B3B8BD",
            opacity: interpolate(frame, [0.45 * fps, 0.95 * fps], [0, 1], {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
              easing: Easing.bezier(0.16, 1, 0.3, 1),
            }),
          }}
        >
          A menu-bar glance for a herd of AI coding agents.
        </Interactive.Div>

        <Interactive.Div
          name="Pills"
          style={{
            marginTop: 22,
            display: "flex",
            gap: 10,
            fontFamily: displayFont,
            fontSize: 16,
            color: "#B3B8BD",
            opacity: interpolate(frame, [0.7 * fps, 1.2 * fps], [0, 1], {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
              easing: Easing.bezier(0.16, 1, 0.3, 1),
            }),
          }}
        >
          <span
            style={{
              padding: "7px 14px",
              borderRadius: 999,
              border: "1px solid rgba(255,255,255,0.12)",
              background: "rgba(255,255,255,0.04)",
            }}
          >
            macOS 14+
          </span>
          <span
            style={{
              padding: "7px 14px",
              borderRadius: 999,
              border: "1px solid rgba(255,255,255,0.12)",
              background: "rgba(255,255,255,0.04)",
            }}
          >
            open source
          </span>
          <span
            style={{
              padding: "7px 14px",
              borderRadius: 999,
              border: "1px solid rgba(255,255,255,0.12)",
              background: "rgba(255,255,255,0.04)",
            }}
          >
            MIT
          </span>
          <span
            style={{
              padding: "7px 14px",
              borderRadius: 999,
              border: "1px solid rgba(255,255,255,0.12)",
              background: "rgba(255,255,255,0.04)",
            }}
          >
            built on herdr
          </span>
        </Interactive.Div>

        <Interactive.Div
          name="Repo"
          style={{
            marginTop: 28,
            fontFamily: displayFont,
            fontSize: 24,
            fontWeight: 700,
            color: "#FFC94D",
            opacity: interpolate(frame, [0.9 * fps, 1.4 * fps], [0, 1], {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
              easing: Easing.bezier(0.16, 1, 0.3, 1),
            }),
          }}
        >
          github.com/sxp4931/herdr-manager
        </Interactive.Div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
