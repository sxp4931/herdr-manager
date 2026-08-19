import React from "react";
import {
  AbsoluteFill,
  Easing,
  Interactive,
  interpolate,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { displayFont } from "../fonts";
import { MenuBarMock } from "../ui/MenuBarMock";
import { AgentCard, DEMO_NEEDS_YOU, PanelChrome } from "../ui/Panel";


export const SceneGlance: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  return (
    <AbsoluteFill name="Glance" style={{ backgroundColor: "#070A0B" }}>

      <AbsoluteFill
        style={{
          background:
            "radial-gradient(1200px 700px at 72% 48%, rgba(10,16,40,0.22), rgba(7,9,16,0.88))",
        }}
      />

      <Interactive.Div
        name="Kicker"
        style={{
          position: "absolute",
          left: 100,
          top: 390,
          fontFamily: displayFont,
          fontSize: 18,
          fontWeight: 700,
          letterSpacing: 2.2,
          textTransform: "uppercase",
          color: "#FFC94D",
          opacity: interpolate(frame, [0, 0.4 * fps], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.16, 1, 0.3, 1),
          }),
        }}
      >
        macOS menu bar
      </Interactive.Div>

      <Interactive.Div
        name="Headline"
        style={{
          position: "absolute",
          left: 100,
          top: 428,
          width: 720,
          fontFamily: displayFont,
          fontSize: 92,
          fontWeight: 700,
          letterSpacing: -2.4,
          lineHeight: 1.02,
          color: "#F5F5F7",
          opacity: interpolate(frame, [0.15 * fps, 0.7 * fps], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.16, 1, 0.3, 1),
          }),
          translate: interpolate(
            frame,
            [0.15 * fps, 0.7 * fps],
            ["0px 28px", "0px 0px"],
            {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
              easing: Easing.bezier(0.16, 1, 0.3, 1),
            },
          ),
        }}
      >
        Does anything need you?
      </Interactive.Div>

      <Interactive.Div
        name="Subhead"
        style={{
          position: "absolute",
          left: 100,
          top: 650,
          width: 640,
          fontFamily: displayFont,
          fontSize: 28,
          fontWeight: 500,
          lineHeight: 1.35,
          color: "#B3B8BD",
          opacity: interpolate(frame, [0.5 * fps, 1.1 * fps], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.16, 1, 0.3, 1),
          }),
        }}
      >
        You should not hunt 27 terminals to find out.
      </Interactive.Div>

      <Interactive.Div
        name="Product"
        style={{
          position: "absolute",
          right: 100,
          top: 180,
          opacity: interpolate(frame, [0.4 * fps, 1.1 * fps], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.16, 1, 0.3, 1),
          }),
          translate: interpolate(
            frame,
            [0.4 * fps, 1.2 * fps],
            ["56px 0px", "0px 0px"],
            {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
              easing: Easing.bezier(0.16, 1, 0.3, 1),
            },
          ),
          scale: interpolate(frame, [0.4 * fps, 1.2 * fps], [0.92, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.spring({ damping: 200 }),
            output: "perceptual-scale",
          }),
        }}
      >
        <MenuBarMock count={2} attention="blocked" />
        <div style={{ height: 16 }} />
        <PanelChrome
          subtitle="2 need you · 0 done · 6 running"
          scope="needs"
          needs={2}
          running={6}
          all={27}
          height={520}
        >
          <div style={{ paddingTop: 4 }}>
            <AgentCard agent={DEMO_NEEDS_YOU[0]} selected />
          </div>
        </PanelChrome>
      </Interactive.Div>
    </AbsoluteFill>
  );
};
