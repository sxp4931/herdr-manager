import React from "react";
import { Composition, Folder, Still } from "remotion";
import "./fonts";
import { ShepherdLaunch } from "./ShepherdLaunch";
import { SceneGlance } from "./scenes/SceneGlance";
import { SceneHerdr } from "./scenes/SceneHerdr";
import { ScenePanel } from "./scenes/ScenePanel";
import { SceneUnblock } from "./scenes/SceneUnblock";
import { SceneUsage } from "./scenes/SceneUsage";
import { SceneEnd } from "./scenes/SceneEnd";
import { HeroEnd, HeroHerdr, HeroUnblock, HeroWide } from "./stills";

export const RemotionRoot: React.FC = () => {
  return (
    <>
      <Composition
        id="ShepherdLaunch"
        component={ShepherdLaunch}
        durationInFrames={960}
        fps={30}
        width={1920}
        height={1080}
      />
      <Folder name="Scenes">
        <Composition
          id="SceneGlance"
          component={SceneGlance}
          durationInFrames={150}
          fps={30}
          width={1920}
          height={1080}
        />
        <Composition
          id="SceneHerdr"
          component={SceneHerdr}
          durationInFrames={150}
          fps={30}
          width={1920}
          height={1080}
        />
        <Composition
          id="ScenePanel"
          component={ScenePanel}
          durationInFrames={180}
          fps={30}
          width={1920}
          height={1080}
        />
        <Composition
          id="SceneUnblock"
          component={SceneUnblock}
          durationInFrames={180}
          fps={30}
          width={1920}
          height={1080}
        />
        <Composition
          id="SceneUsage"
          component={SceneUsage}
          durationInFrames={150}
          fps={30}
          width={1920}
          height={1080}
        />
        <Composition
          id="SceneEnd"
          component={SceneEnd}
          durationInFrames={225}
          fps={30}
          width={1920}
          height={1080}
        />
      </Folder>
      <Folder name="Stills">
        <Still id="HeroHerdr" component={HeroHerdr} width={1920} height={1080} />
        <Still id="HeroWide" component={HeroWide} width={1920} height={1080} />
        <Still id="HeroUnblock" component={HeroUnblock} width={1920} height={1080} />
        <Still id="HeroEnd" component={HeroEnd} width={1920} height={1080} />
      </Folder>
    </>
  );
};
