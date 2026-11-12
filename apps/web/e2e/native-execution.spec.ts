import { expect, test } from "@playwright/test";
import { captureScreenshot } from "./helpers";

test("native permission submission waits for delivery and expiry never shows approval", async ({
  page,
}, testInfo) => {
  await page.goto("/e2e/fixtures/native-execution.html");
  await expect(page.getByRole("button", { name: "Allow once", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "Always allow this tool" })).toHaveCount(0);
  await captureScreenshot(page, testInfo, "native-permission-pending");
  await page.getByRole("button", { name: "Allow once", exact: true }).click();
  await expect(page.getByText("Sending…", { exact: true })).toBeVisible();
  await expect(page.getByText("Allowed once", { exact: true })).toHaveCount(0);
  await page.goto("/e2e/fixtures/native-execution.html?state=expired");
  await expect(page.getByText("No longer active", { exact: true })).toBeVisible();
  await expect(page.getByText("Allowed once", { exact: true })).toHaveCount(0);
  await captureScreenshot(page, testInfo, "native-permission-expired");
});

test("execution connections disclose readiness and private network settings", async ({
  page,
}, testInfo) => {
  await page.goto("/e2e/fixtures/native-execution.html?screen=settings");
  await expect(page.getByRole("combobox", { name: "Agent", exact: true })).toBeVisible();
  await expect(page.getByRole("option", { name: "Personal account" })).toHaveCount(1);
  await expect(page.getByRole("option", { name: "Additional account" })).toHaveCount(0);
  await page.getByRole("button", { name: "Connection", exact: true }).click();
  await expect(page.getByRole("dialog")).toBeVisible();
  await expect(
    page.getByText("Additional account · Sign in required", { exact: true }),
  ).toBeVisible();
  await expect(page.getByRole("checkbox", { name: "Private network" })).toBeVisible();
  await captureScreenshot(page, testInfo, "native-execution-connections");
});

test("execution switches stop only after confirmation and offer available models", async ({
  page,
}, testInfo) => {
  await page.goto("/e2e/fixtures/native-execution.html?screen=settings&state=running");
  const execution = page.getByRole("combobox", {
    name: "Agent",
    exact: true,
    includeHidden: true,
  });
  const selected = JSON.stringify(["connection", "account", 1]);
  await execution.selectOption(selected);
  await expect(page.getByRole("alertdialog")).toBeVisible();
  await expect(execution).toHaveValue("");
  await captureScreenshot(page, testInfo, "native-execution-switch-confirmation");
  await page.getByRole("button", { name: "Cancel", exact: true }).click();
  await expect(page.getByRole("alertdialog")).toHaveCount(0);
  await expect(execution).toHaveValue("");
  await execution.selectOption(selected);
  await page.getByRole("button", { name: "Stop and switch", exact: true }).click();
  await expect(page.getByRole("alertdialog")).toHaveCount(0);
  await expect(execution).toHaveValue(selected);
  const model = page.getByRole("combobox", { name: "Model", exact: true });
  await expect(model).toHaveValue("");
  await expect(model.getByRole("option", { name: "Default (Model A)", exact: true })).toHaveCount(
    1,
  );
  await model.selectOption("provider/model-b");
  await expect(model).toHaveValue("provider/model-b");
  await captureScreenshot(page, testInfo, "native-execution-model-selection");
  await execution.selectOption("");
  await expect(model).toHaveValue("");
  await expect(model.getByRole("option", { name: "Space default", exact: true })).toHaveCount(1);
  await captureScreenshot(page, testInfo, "native-built-in-model-selection");
});

test("failed stop keeps the original execution and allows retry", async ({ page }) => {
  await page.goto("/e2e/fixtures/native-execution.html?screen=settings&state=stop-failed");
  const execution = page.getByRole("combobox", {
    name: "Agent",
    exact: true,
    includeHidden: true,
  });
  await execution.selectOption(JSON.stringify(["connection", "account", 1]));
  await page.getByRole("button", { name: "Stop and switch", exact: true }).click();
  await expect(page.getByRole("alertdialog")).toBeVisible();
  await expect(page.getByRole("alert")).toBeVisible();
  await expect(page.getByRole("button", { name: "Stop and switch", exact: true })).toBeEnabled();
  await expect(execution).toHaveValue("");
});
