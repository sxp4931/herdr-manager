import React from "react";
import { Sequence } from "remotion";
import { ScenePanel } from "./scenes/ScenePanel";
import { SceneUnblock } from "./scenes/SceneUnblock";
import { SceneEnd } from "./scenes/SceneEnd";
import { SceneHerdr } from "./scenes/SceneHerdr";

export const HeroHerdr: React.FC = () => (
  <Sequence name="HeroHerdr" trimBefore={90} durationInFrames={1} layout="none">
    <SceneHerdr />
  </Sequence>
);

export const HeroWide: React.FC = () => (
  <Sequence name="HeroWide" trimBefore={90} durationInFrames={1} layout="none">
    <ScenePanel />
  </Sequence>
);

export const HeroUnblock: React.FC = () => (
  <Sequence name="HeroUnblock" trimBefore={90} durationInFrames={1} layout="none">
    <SceneUnblock />
  </Sequence>
);

export const HeroEnd: React.FC = () => (
  <Sequence name="HeroEnd" trimBefore={90} durationInFrames={1} layout="none">
    <SceneEnd />
  </Sequence>
);
