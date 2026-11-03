import { expect, test } from "@playwright/test";
import { captureScreenshot, completeOnboarding, openUserSettings, signup } from "./helpers";

test("model account settings show balance and platform actions", async ({ page }, testInfo) => {
  let connected = false;
  let amount = "12.34";
  let revocationUnknown = false;
  let revokeAttempts = 0;
  await page.route("**/api/model-account/config", (route) =>
    route.fulfill({
      json: {
        enabled: true,
        homeUrl: "https://home.example.test/",
        rechargeUrl: "https://wallet.example.test/",
        modelId: "example-model",
      },
    }),
  );
  await page.route("**/api/model-account/status", (route) =>
    route.fulfill({
      json: {
        enabled: true,
        connected,
        linked: true,
        ...(revocationUnknown ? { recovery: "revocation_unknown" } : {}),
      },
    }),
  );
  await page.route("**/api/model-account/balance", (route) =>
    route.fulfill({ json: { amount, unit: "USD" } }),
  );
  await page.route("**/api/model-account/connect", (route) => {
    connected = true;
    return route.fulfill({ json: { connected } });
  });
  await page.route("**/api/model-account/revoke", (route) => {
    connected = false;
    revokeAttempts++;
    if (revokeAttempts === 1) {
      revocationUnknown = true;
      return route.fulfill({ status: 503, json: { error: "result_unknown" } });
    }
    revocationUnknown = false;
    return route.fulfill({ json: { connected } });
  });
  await signup(page, `model-account-${Date.now()}@rakazo.test`, "password12", "Fixture User");
  await completeOnboarding(page);
  const settings = await openUserSettings(page, "models");
  await expect(settings.getByRole("heading", { name: "Model account", exact: true })).toBeVisible();
  await expect(settings.getByText("12.34 USD", { exact: true })).toBeVisible();
  await settings.getByRole("button", { name: "Use model account", exact: true }).click();
  await expect(settings.getByRole("button", { name: "Disconnect", exact: true })).toBeVisible();
  await expect(settings.getByRole("link", { name: "Recharge", exact: true })).toHaveAttribute(
    "href",
    "https://wallet.example.test/",
  );
  await expect(
    settings.getByRole("button", { name: "Use model account", exact: true }),
  ).toBeHidden();
  amount = "22.34";
  await settings.getByRole("button", { name: "Refresh balance", exact: true }).click();
  await expect(settings.getByText("22.34 USD", { exact: true })).toBeVisible();
  amount = "32.34";
  await page.evaluate(() => window.dispatchEvent(new Event("focus")));
  await expect(settings.getByText("32.34 USD", { exact: true })).toBeVisible();
  await captureScreenshot(page, testInfo, "model-account-settings");
  await settings.getByRole("button", { name: "Disconnect", exact: true }).click();
  await expect(
    settings.getByText("Disconnection pending confirmation.", { exact: true }),
  ).toBeVisible();
  await settings.getByRole("button", { name: "Retry disconnect", exact: true }).click();
  await expect(
    settings.getByRole("button", { name: "Retry disconnect", exact: true }),
  ).toBeHidden();
});

for (const reauthorizing of [false, true]) {
  test(`${reauthorizing ? "renewed" : "first"} authorization preserves the original conversation and unsent draft`, async ({
    page,
    context,
  }) => {
    let connected = false;
    let callback = "";
    await page.route("**/api/model-account/config", (route) =>
      route.fulfill({
        json: {
          enabled: true,
          homeUrl: "https://home.example.test/",
          rechargeUrl: "https://wallet.example.test/",
          modelId: "fixture-model",
        },
      }),
    );
    await page.route("**/api/model-account/status", (route) =>
      route.fulfill({
        json: {
          enabled: true,
          connected,
          linked: true,
          ...(!connected && reauthorizing ? { recovery: "authorization_pending" } : {}),
        },
      }),
    );
    await page.route("**/api/model-account/balance", (route) =>
      route.fulfill({ json: { amount: "10.00", unit: "USD" } }),
    );
    await page.route("**/api/model-account/connect", (route) => {
      callback = route.request().postDataJSON().callbackURL;
      return route.fulfill({
        json: { connected: false, url: "https://gateway.example.test/authorize" },
      });
    });
    await context.route("https://gateway.example.test/authorize", (route) => {
      connected = true;
      return route.fulfill({
        contentType: "text/html",
        body: `<script>location.replace(${JSON.stringify(callback)})</script>`,
      });
    });
    await signup(page, `model-context-${Date.now()}@rakazo.test`, "password12", "Draft Keeper");
    await completeOnboarding(page);
    const composer = page.getByRole("combobox", { name: /Message/ });
    await composer.fill("Keep this unsent draft");
    const conversation = page.url();
    const settings = await openUserSettings(page, "models");
    const originalURL = page.url();
    await settings
      .getByRole("button", {
        name: reauthorizing ? "Authorize again" : "Use model account",
        exact: true,
      })
      .click();
    await expect(settings.getByRole("button", { name: "Disconnect", exact: true })).toBeVisible();
    await expect(
      settings.getByRole("button", { name: "Use model account", exact: true }),
    ).toBeHidden();
    expect(page.url()).toBe(originalURL);
    await settings.getByRole("button", { name: /Close .*settings/ }).click();
    await expect(composer).toHaveValue("Keep this unsent draft");
    expect(new URL(page.url()).pathname).toBe(new URL(conversation).pathname);
  });
}

test("missing OIDC identity has no extra binding action and managed connections have no key editor", async ({
  page,
}) => {
  await page.route("**/api/model-account/config", (route) =>
    route.fulfill({
      json: {
        enabled: true,
        homeUrl: "https://home.example.test/",
        rechargeUrl: "https://wallet.example.test/",
        modelId: "fixture-model",
      },
    }),
  );
  await page.route("**/api/model-account/status", (route) =>
    route.fulfill({ json: { enabled: true, connected: false, linked: false } }),
  );
  await page.route("**/api/model-account/balance", (route) =>
    route.fulfill({ status: 403, json: { error: "link_required" } }),
  );
  await page.route("**/rpc/models/credentials", async (route) => {
    const response = await route.fetch();
    const body = await response.json();
    body.json.push({
      id: "managed-fixture",
      provider: "openai-compatible",
      label: "Managed fixture connection",
      hasKey: false,
      isDefault: false,
      managed: true,
      baseUrl: "https://models.example.test/v1",
    });
    await route.fulfill({ response, json: body });
  });
  await signup(page, `model-link-${Date.now()}@rakazo.test`, "password12", "Fixture User");
  await completeOnboarding(page);
  const settings = await openUserSettings(page, "models");
  await expect(settings.getByRole("button", { name: "Link SSO", exact: true })).toBeHidden();
  await expect(
    settings.getByRole("button", { name: "Use model account", exact: true }),
  ).toBeHidden();
  await expect(settings.getByTestId("model-provider-managed-fixture")).toHaveCount(0);
});

test("unknown authorization is checked automatically and retry appears only after failure", async ({
  page,
}) => {
  let connected = false;
  let available = false;
  let checks = 0;
  let authorizations = 0;
  await page.route("**/api/model-account/config", (route) =>
    route.fulfill({
      json: {
        enabled: true,
        homeUrl: "https://home.example.test/",
        rechargeUrl: "https://wallet.example.test/",
        modelId: "fixture-model",
      },
    }),
  );
  await page.route("**/api/model-account/status", (route) =>
    route.fulfill({
      json: {
        enabled: true,
        linked: true,
        connected,
        ...(!connected ? { recovery: "authorization_unknown" } : {}),
      },
    }),
  );
  await page.route("**/api/model-account/balance", (route) =>
    route.fulfill({ json: { amount: "10.00", unit: "USD" } }),
  );
  await page.route("**/api/model-account/connect", (route) => {
    authorizations++;
    return route.fulfill({ status: 500, json: { error: "unavailable" } });
  });
  await page.route("**/api/model-account/recover", (route) => {
    checks++;
    if (!available) return route.fulfill({ status: 503, json: { error: "unavailable" } });
    connected = true;
    return route.fulfill({ json: { connected: true } });
  });
  await signup(page, `model-recovery-${Date.now()}@rakazo.test`, "password12", "Fixture User");
  await completeOnboarding(page);
  const settings = await openUserSettings(page, "models");
  await expect(settings.getByRole("button", { name: "Retry", exact: true })).toBeVisible();
  expect(checks).toBeGreaterThan(0);
  await expect(settings.getByRole("button", { name: "Authorize again", exact: true })).toBeHidden();
  available = true;
  await settings.getByRole("button", { name: "Retry", exact: true }).click();
  await expect(settings.getByRole("button", { name: "Disconnect", exact: true })).toBeVisible();
  await expect(settings.getByRole("button", { name: "Retry", exact: true })).toBeHidden();
  await expect(
    settings.getByRole("button", { name: "Use model account", exact: true }),
  ).toBeHidden();
  expect(authorizations).toBe(0);
});
