import React from "react";
import { TransitionSeries, linearTiming } from "@remotion/transitions";
import { fade } from "@remotion/transitions/fade";
import { SceneGlance } from "./scenes/SceneGlance";
import { SceneHerdr } from "./scenes/SceneHerdr";
import { ScenePanel } from "./scenes/ScenePanel";
import { SceneUnblock } from "./scenes/SceneUnblock";
import { SceneUsage } from "./scenes/SceneUsage";
import { SceneEnd } from "./scenes/SceneEnd";
import { Soundtrack } from "./ui/SceneVoice";

export const ShepherdLaunch: React.FC = () => {
  return (
    <>
      <Soundtrack />
      <TransitionSeries>
      <TransitionSeries.Sequence durationInFrames={150} name="Glance">
        <SceneGlance />
      </TransitionSeries.Sequence>
      <TransitionSeries.Transition
        presentation={fade()}
        timing={linearTiming({ durationInFrames: 15 })}
      />
      <TransitionSeries.Sequence durationInFrames={150} name="Herdr">
        <SceneHerdr />
      </TransitionSeries.Sequence>
      <TransitionSeries.Transition
        presentation={fade()}
        timing={linearTiming({ durationInFrames: 15 })}
      />
      <TransitionSeries.Sequence durationInFrames={180} name="Panel">
        <ScenePanel />
      </TransitionSeries.Sequence>
      <TransitionSeries.Transition
        presentation={fade()}
        timing={linearTiming({ durationInFrames: 15 })}
      />
      <TransitionSeries.Sequence durationInFrames={180} name="Unblock">
        <SceneUnblock />
      </TransitionSeries.Sequence>
      <TransitionSeries.Transition
        presentation={fade()}
        timing={linearTiming({ durationInFrames: 15 })}
      />
      <TransitionSeries.Sequence durationInFrames={150} name="Usage">
        <SceneUsage />
      </TransitionSeries.Sequence>
      <TransitionSeries.Transition
        presentation={fade()}
        timing={linearTiming({ durationInFrames: 15 })}
      />
      <TransitionSeries.Sequence durationInFrames={225} name="End">
        <SceneEnd />
      </TransitionSeries.Sequence>
    </TransitionSeries>
    </>
  );
};
