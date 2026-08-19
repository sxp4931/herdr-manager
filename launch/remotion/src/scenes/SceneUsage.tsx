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
import { UsageDash } from "../ui/UsageDash";


export const SceneUsage: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  return (
    <AbsoluteFill name="Usage" style={{ backgroundColor: "#070A0B" }}>

      <AbsoluteFill
        style={{
          background:
            "radial-gradient(1100px 640px at 72% 50%, rgba(10,16,40,0.18), rgba(7,9,16,0.9))",
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
        Usage
      </Interactive.Div>

      <Interactive.Div
        name="Headline"
        style={{
          position: "absolute",
          left: 100,
          top: 428,
          width: 700,
          fontFamily: displayFont,
          fontSize: 84,
          fontWeight: 700,
          letterSpacing: -2.2,
          lineHeight: 1.04,
          color: "#F5F5F7",
          opacity: interpolate(frame, [0.1 * fps, 0.55 * fps], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.16, 1, 0.3, 1),
          }),
        }}
      >
        What the herd cost today.
      </Interactive.Div>

      <Interactive.Div
        name="Subhead"
        style={{
          position: "absolute",
          left: 100,
          top: 640,
          width: 620,
          fontFamily: displayFont,
          fontSize: 28,
          fontWeight: 500,
          lineHeight: 1.35,
          color: "#B3B8BD",
          opacity: interpolate(frame, [0.35 * fps, 0.9 * fps], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.16, 1, 0.3, 1),
          }),
        }}
      >
        Model-aware token estimates from local logs. Honest about gaps. Never a bill.
      </Interactive.Div>

      <Interactive.Div
        name="Dashboard"
        style={{
          position: "absolute",
          right: 100,
          top: "50%",
          marginTop: -320,
          opacity: interpolate(frame, [0.15 * fps, 0.7 * fps], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.16, 1, 0.3, 1),
          }),
          translate: interpolate(
            frame,
            [0.15 * fps, 0.8 * fps],
            ["40px 0px", "0px 0px"],
            {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
              easing: Easing.bezier(0.16, 1, 0.3, 1),
            },
          ),
        }}
      >
        <UsageDash />
      </Interactive.Div>
    </AbsoluteFill>
  );
};
