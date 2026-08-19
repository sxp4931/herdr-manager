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
import { AgentCard, DEMO_NEEDS_YOU, PanelChrome, PERMISSION_PEEK } from "../ui/Panel";
import { HerdrWindow } from "../ui/HerdrWindow";


export const SceneUnblock: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  return (
    <AbsoluteFill name="Unblock" style={{ backgroundColor: "#070910" }}>

      <AbsoluteFill
        style={{
          background:
            "radial-gradient(1100px 640px at 50% 50%, rgba(10,16,40,0.22), rgba(7,9,16,0.94))",
        }}
      />

      <Interactive.Div
        name="Kicker"
        style={{
          position: "absolute",
          left: 64,
          top: 40,
          fontFamily: displayFont,
          fontSize: 16,
          fontWeight: 700,
          letterSpacing: 2.2,
          textTransform: "uppercase",
          color: "#FFC94D",
          opacity: interpolate(frame, [0, 0.3 * fps], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.16, 1, 0.3, 1),
          }),
        }}
      >
        Shepherd on herdr
      </Interactive.Div>

      <Interactive.Div
        name="Headline"
        style={{
          position: "absolute",
          left: 64,
          top: 68,
          fontFamily: displayFont,
          fontSize: 52,
          fontWeight: 700,
          letterSpacing: -1.4,
          color: "#F5F5F7",
          opacity: interpolate(frame, [0.08 * fps, 0.45 * fps], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.16, 1, 0.3, 1),
          }),
        }}
      >
        Same stuck pane. Unblock from the bar.
      </Interactive.Div>

      <Interactive.Div
        name="Herdr window"
        style={{
          position: "absolute",
          left: 48,
          top: 160,
          opacity: interpolate(frame, [0.15 * fps, 0.6 * fps], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.16, 1, 0.3, 1),
          }),
        }}
      >
        <HerdrWindow width={880} height={560} highlightBlocked />
      </Interactive.Div>

      <Interactive.Div
        name="Panel"
        style={{
          position: "absolute",
          right: 48,
          top: 150,
          scale: interpolate(frame, [0.2 * fps, 0.85 * fps], [0.9, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.16, 1, 0.3, 1),
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
          height={580}
        >
          <div style={{ paddingTop: 4 }}>
            <AgentCard
              agent={DEMO_NEEDS_YOU[0]}
              selected
              showActions
              highlightApprove
              peek={PERMISSION_PEEK}
            />
          </div>
        </PanelChrome>
      </Interactive.Div>
    </AbsoluteFill>
  );
};
