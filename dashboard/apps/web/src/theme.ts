export const THEME_KEY = "herdr-dashboard-theme";

export type ThemeChoice = "light" | "dark" | "system";

export function readThemeChoice(): ThemeChoice {
  try {
    const stored = localStorage.getItem(THEME_KEY);
    if (stored === "light" || stored === "dark" || stored === "system") return stored;
  } catch {
    // Storage can throw in locked-down browsers. The system preference still applies.
  }
  return "system";
}

export function storeThemeChoice(choice: ThemeChoice): void {
  try {
    localStorage.setItem(THEME_KEY, choice);
  } catch {
    // The current document still updates even when persistence is unavailable.
  }
}

export function resolvedTheme(choice: ThemeChoice): "light" | "dark" {
  if (choice === "light" || choice === "dark") return choice;
  if (typeof window.matchMedia !== "function") return "light";
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

export function applyTheme(choice: ThemeChoice): "light" | "dark" {
  const resolved = resolvedTheme(choice);
  document.documentElement.dataset.theme = resolved;
  return resolved;
}
