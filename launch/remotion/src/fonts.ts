import { loadFont as loadInter } from "@remotion/google-fonts/Inter";

export const { fontFamily: displayFont } = loadInter("normal", {
  weights: ["500", "600", "700"],
  subsets: ["latin"],
});

export const { fontFamily: uiFont } = displayFont;
