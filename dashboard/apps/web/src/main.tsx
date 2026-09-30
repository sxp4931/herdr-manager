import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App.js";
import { applyTheme, readThemeChoice } from "./theme.js";
import "./styles.css";

applyTheme(readThemeChoice());

const root = document.getElementById("root");
if (!root) {
  throw new Error("missing root");
}
createRoot(root).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
