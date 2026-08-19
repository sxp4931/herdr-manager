import React from "react";
import { Html5Audio, staticFile } from "remotion";

/** One premixed bed+VO file. Html5Audio is stable in Studio playback. */
export const Soundtrack: React.FC = () => (
  <Html5Audio src={staticFile("voice/soundtrack.wav")} />
);
