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
import { AgentCard, DEMO_NEEDS_YOU, PanelChrome } from "../ui/Panel";


export const ScenePanel: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  return (
    <AbsoluteFill name="Panel" style={{ backgroundColor: "#070A0B" }}>

      <AbsoluteFill
        style={{
          background:
            "radial-gradient(1100px 640px at 72% 50%, rgba(10,16,40,0.22), rgba(7,9,16,0.9))",
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
          opacity: interpolate(frame, [0, 0.35 * fps], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.16, 1, 0.3, 1),
          }),
        }}
      >
        Attention, not a census
      </Interactive.Div>

      <Interactive.Div
        name="Headline"
        style={{
          position: "absolute",
          left: 100,
          top: 428,
          width: 700,
          fontFamily: displayFont,
          fontSize: 92,
          fontWeight: 700,
          letterSpacing: -2.4,
          lineHeight: 1.02,
          color: "#F5F5F7",
          opacity: interpolate(frame, [0.1 * fps, 0.55 * fps], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.16, 1, 0.3, 1),
          }),
          translate: interpolate(
            frame,
            [0.1 * fps, 0.55 * fps],
            ["0px 24px", "0px 0px"],
            {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
              easing: Easing.bezier(0.16, 1, 0.3, 1),
            },
          ),
        }}
      >
        Shepherd shows you.
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
          opacity: interpolate(frame, [0.4 * fps, 0.95 * fps], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.16, 1, 0.3, 1),
          }),
        }}
      >
        herdr holds the panes. Shepherd tells you which ones need you.
      </Interactive.Div>

      <Interactive.Div
        name="Panel"
        style={{
          position: "absolute",
          right: 100,
          top: "50%",
          marginTop: -320,
          opacity: interpolate(frame, [0.2 * fps, 0.8 * fps], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.16, 1, 0.3, 1),
          }),
          scale: interpolate(frame, [0.2 * fps, 0.9 * fps], [0.9, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.spring({ damping: 200 }),
            output: "perceptual-scale",
          }),
        }}
      >
        <PanelChrome
          subtitle="2 need you · 0 done · 6 running"
          scope="needs"
          needs={2}
          running={6}
          all={27}
        >
          <div style={{ paddingTop: 4, display: "flex", flexDirection: "column", gap: 4 }}>
            <AgentCard agent={DEMO_NEEDS_YOU[0]} selected showActions />
            <AgentCard agent={DEMO_NEEDS_YOU[1]} showActions />
          </div>
        </PanelChrome>
      </Interactive.Div>
    </AbsoluteFill>
  );
};
