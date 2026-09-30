import { expect, test } from "@playwright/test";

test("built page is titled herdr dashboard", async ({ page }) => {
  const errors: string[] = [];
  page.on("pageerror", (error) => {
    errors.push(String(error));
  });
  await page.goto("/");
  await expect(page).toHaveTitle("herdr dashboard");
  await expect(page.getByRole("heading", { name: "herdr dashboard" })).toBeVisible();
  expect(errors).toEqual([]);
});
