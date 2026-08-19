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
import { HerdrWindow } from "../ui/HerdrWindow";


export const SceneHerdr: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  return (
    <AbsoluteFill name="Herdr" style={{ backgroundColor: "#070910" }}>

      <AbsoluteFill
        style={{
          background:
            "radial-gradient(1200px 700px at 70% 48%, rgba(10,16,40,0.35), rgba(7,9,16,0.92))",
        }}
      />

      <Interactive.Div
        name="Kicker"
        style={{
          position: "absolute",
          left: 80,
          top: 330,
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
        herdr
      </Interactive.Div>

      <Interactive.Div
        name="Headline"
        style={{
          position: "absolute",
          left: 80,
          top: 368,
          width: 620,
          fontFamily: displayFont,
          fontSize: 76,
          fontWeight: 700,
          letterSpacing: -2,
          lineHeight: 1.04,
          color: "#F5F5F7",
          opacity: interpolate(frame, [0.1 * fps, 0.55 * fps], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.16, 1, 0.3, 1),
          }),
        }}
      >
        herdr runs the herd.
      </Interactive.Div>

      <Interactive.Div
        name="Subhead"
        style={{
          position: "absolute",
          left: 80,
          top: 560,
          width: 560,
          fontFamily: displayFont,
          fontSize: 26,
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
        27 live panes. Two of them are stuck. You still have to hunt.
      </Interactive.Div>

      <Interactive.Div
        name="Herdr window"
        style={{
          position: "absolute",
          right: 56,
          top: 90,
          opacity: interpolate(frame, [0.15 * fps, 0.7 * fps], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.16, 1, 0.3, 1),
          }),
          scale: interpolate(frame, [0.15 * fps, 0.8 * fps], [0.92, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.16, 1, 0.3, 1),
            output: "perceptual-scale",
          }),
        }}
      >
        <HerdrWindow highlightBlocked />
      </Interactive.Div>
    </AbsoluteFill>
  );
};
