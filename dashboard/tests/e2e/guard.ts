import { expect, type Page } from "@playwright/test";

export interface PageGuards {
  errors: string[];
  foreign: string[];
}

export function watchPage(page: Page): PageGuards {
  const errors: string[] = [];
  const foreign: string[] = [];
  page.on("pageerror", (error) => {
    errors.push(String(error));
  });
  page.on("request", (request) => {
    let url: URL;
    try {
      url = new URL(request.url());
    } catch {
      foreign.push(request.url());
      return;
    }
    if (url.protocol !== "http:" && url.protocol !== "https:") return;
    if (url.hostname !== "127.0.0.1" && url.hostname !== "localhost") foreign.push(request.url());
  });
  return { errors, foreign };
}

export function expectQuiet(guards: PageGuards): void {
  expect(guards.errors).toEqual([]);
  expect(guards.foreign).toEqual([]);
}
