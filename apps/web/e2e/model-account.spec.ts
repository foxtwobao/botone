import { expect, test } from "@playwright/test";
import type { AppBootstrap, Me, Run, ThreadSnapshot } from "@rakazo/contracts";
import {
  activeBotId,
  captureScreenshot,
  completeOnboarding,
  openUserSettings,
  rpc,
  signup,
} from "./helpers";

for (const outcome of ["authorization", "recovery"] as const) {
  test(`a paused task completes ${outcome} in place without an automatic popup or losing its draft`, async ({
    page,
    context,
  }, testInfo) => {
    let connected = false;
    let serviceAvailable = false;
    let uncertain = false;
    let callback = "";
    let requests = 0;
    let popups = 0;
    page.on("popup", () => popups++);
    await page.route("**/api/model-account/config", (route) =>
      route.fulfill({ json: { enabled: true } }),
    );
    await page.route("**/api/model-account/status", (route) =>
      route.fulfill({
        json: {
          enabled: true,
          connected,
          linked: true,
          ...(!connected
            ? { recovery: uncertain ? "authorization_unknown" : "authorization_required" }
            : {}),
        },
      }),
    );
    await page.route("**/api/model-account/balance", (route) =>
      route.fulfill({ json: { amount: "12.34", unit: "USD" } }),
    );
    await page.route("**/api/model-account/recover", (route) => {
      if (!serviceAvailable) return route.fulfill({ status: 503, json: { error: "unavailable" } });
      connected = true;
      return route.fulfill({ json: { connected: true } });
    });
    await page.route("**/api/model-account/connect", (route) => {
      requests++;
      if (!serviceAvailable) return route.fulfill({ status: 503, json: { error: "unavailable" } });
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
    await signup(page, `task-account-${Date.now()}@rakazo.test`, "password12", "Fixture User");
    await completeOnboarding(page);
    const botId = activeBotId(page);
    const me = await rpc<Me>(page, "me", {});
    await expect
      .poll(
        async () =>
          (await rpc<ThreadSnapshot>(page, "threads/get", { botId })).activeRuns?.some((run) =>
            ["queued", "leased", "running"].includes(run.status),
          ) ?? false,
      )
      .toBe(false);
    await page.route(/\/rpc\/(?:bootstrap|threads\/get)$/, async (route) => {
      const response = await route.fetch();
      const body = (await response.json()) as { json: ThreadSnapshot | AppBootstrap };
      const bootstrap = "thread" in body.json;
      const snap = "thread" in body.json ? body.json.thread : body.json;
      if (!snap) return route.fulfill({ response });
      const run: Run = {
        id: "fixture-paused-model-run",
        userId: me.userId,
        botId,
        threadId: snap.threadId,
        taskId: "fixture-model-task",
        status: connected ? "queued" : "waiting_input",
        modelAuthorizationRequired: !connected,
        trigger: "user",
        routineId: null,
        modelProvider: "openai-compatible",
        modelId: "fixture-model",
        error: null,
        startedAt: null,
        completedAt: null,
        createdAt: new Date().toISOString(),
      };
      const patched: ThreadSnapshot = {
        ...snap,
        run,
        activeRuns: [run],
        messages: [
          ...snap.messages,
          {
            id: "fixture-model-prompt",
            threadId: snap.threadId,
            seq: (snap.messages.at(-1)?.seq ?? 0) + 1,
            role: "bot",
            botId,
            runId: run.id,
            createdAt: new Date().toISOString(),
            blocks: [
              {
                kind: "text",
                text: "Authorize the model account in Settings to continue this task.",
              },
            ],
          },
        ],
      };
      await route.fulfill({
        json: { json: bootstrap ? { ...body.json, thread: patched } : patched },
      });
    });
    await page.reload();
    const authorize = page.getByRole("button", { name: "Authorize and continue", exact: true });
    await expect(authorize).toBeVisible();
    expect(requests).toBe(0);
    expect(popups).toBe(0);
    const composer = page.getByRole("combobox", { name: /Message/ });
    await composer.fill("Keep this unsent task draft");
    const originalURL = page.url();
    await captureScreenshot(page, testInfo, "task-model-authorization");
    await authorize.click();
    await expect(page.getByRole("alert")).toHaveText("Model account unavailable");
    await expect(composer).toHaveValue("Keep this unsent task draft");
    if (outcome === "recovery") {
      uncertain = true;
      await page.evaluate(() => window.dispatchEvent(new Event("focus")));
      const retry = page.getByRole("button", { name: "Retry", exact: true });
      await expect(retry).toBeEnabled();
      serviceAvailable = true;
      await retry.click();
    } else {
      serviceAvailable = true;
      await authorize.click();
    }
    await expect.poll(() => connected).toBe(true);
    await expect.poll(() => context.pages().length).toBe(1);
    await expect(page.locator("[data-model-account]")).toBeHidden();
    await expect(composer).toHaveValue("Keep this unsent task draft");
    expect(page.url()).toBe(originalURL);
    expect(requests).toBe(outcome === "recovery" ? 1 : 2);
    await expect(page.getByTestId("user-settings")).toBeHidden();
  });
}

test("model account settings show balance and platform actions", async ({ page }, testInfo) => {
  let connected = false;
  let apiProtocol = "chat-completions";
  let modelRefreshes = 0;
  let amount = "12.34";
  let revocationUnknown = false;
  let revokeAttempts = 0;
  await page.route("**/api/model-account/config", (route) =>
    route.fulfill({
      json: {
        enabled: true,
        navigation: {
          cookieName: "one_nav",
          defaults: {
            homeUrl: "https://home.example.test/",
            rechargeUrl: "https://wallet.example.test/",
          },
          channels: [],
          productHosts: [],
        },
        modelId: "example-model",
      },
    }),
  );
  await page.route("**/api/model-account/status", (route) =>
    route.fulfill({
      json: {
        enabled: true,
        connected,
        apiProtocol,
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
  await page.route("**/api/model-account/settings", (route) => {
    apiProtocol = route.request().postDataJSON().apiProtocol;
    return route.fulfill({ json: { apiProtocol } });
  });
  await page.route("**/api/model-account/models", (route) => {
    modelRefreshes++;
    return route.fulfill({ json: { connected: true } });
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
  await expect(
    settings.getByRole("status").filter({ hasText: "Connected to TokenONE" }),
  ).toBeVisible();
  await expect(settings.getByRole("button", { name: "Disconnect", exact: true })).toBeHidden();
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
  await settings.getByRole("combobox", { name: "API protocol", exact: true }).click();
  await page.getByRole("option", { name: "Responses", exact: true }).click();
  await expect(settings.getByRole("combobox", { name: "API protocol", exact: true })).toContainText(
    "Responses",
  );
  await settings.getByRole("button", { name: "Refresh models", exact: true }).click();
  await expect(settings.getByRole("button", { name: "Refresh models", exact: true })).toBeEnabled();
  expect(modelRefreshes).toBe(1);
  await captureScreenshot(page, testInfo, "model-account-settings");
  // A pending disconnection created by an older client remains recoverable.
  connected = false;
  revocationUnknown = true;
  await page.evaluate(() => window.dispatchEvent(new Event("focus")));
  await expect(
    settings.getByText("Disconnection pending confirmation.", { exact: true }),
  ).toBeVisible();
  await settings.getByRole("button", { name: "Retry disconnect", exact: true }).click();
  await expect(
    settings.getByRole("button", { name: "Retry disconnect", exact: true }),
  ).toBeEnabled();
  await settings.getByRole("button", { name: "Retry disconnect", exact: true }).click();
  await expect(
    settings.getByRole("button", { name: "Retry disconnect", exact: true }),
  ).toBeHidden();
});

for (const locale of ["en", "zh-CN"]) {
  test(`a failed account connection keeps an error on the original page (${locale})`, async ({
    page,
  }, testInfo) => {
    let connected = false;
    let available = false;
    await page.route("**/api/model-account/config", (route) =>
      route.fulfill({ json: { enabled: true } }),
    );
    await page.route("**/api/model-account/status", (route) =>
      route.fulfill({ json: { enabled: true, connected, linked: true } }),
    );
    await page.route("**/api/model-account/balance", (route) =>
      available
        ? route.fulfill({ json: { amount: "12.34", unit: "USD" } })
        : route.fulfill({ status: 503, json: { error: "unavailable" } }),
    );
    await page.route("**/api/model-account/connect", (route) => {
      if (!available) return route.fulfill({ status: 503, json: { error: "unavailable" } });
      connected = true;
      return route.fulfill({ json: { connected: true } });
    });
    await signup(page, `model-failure-${Date.now()}@rakazo.test`, "password12", "Fixture User");
    await completeOnboarding(page);
    const settings = await openUserSettings(page, "models");
    if (locale === "zh-CN") {
      await page.evaluate(() => localStorage.setItem("rakazo.uiLocale", "zh-CN"));
      await page.reload();
      await expect(settings).toBeVisible();
    }
    const connectLabel = locale === "zh-CN" ? "使用模型账户" : "Use model account";
    const errorLabel = locale === "zh-CN" ? "模型账户暂时不可用" : "Model account unavailable";
    const popupOpened = page.waitForEvent("popup");
    await settings.getByRole("button", { name: connectLabel, exact: true }).click();
    const popup = await popupOpened;
    await expect.poll(() => popup.isClosed()).toBe(true);
    await expect(settings.getByRole("alert")).toHaveText(errorLabel);
    await page.evaluate(() => window.dispatchEvent(new Event("focus")));
    await expect(settings.getByRole("alert")).toHaveText(errorLabel);
    await expect(settings.getByRole("button", { name: connectLabel, exact: true })).toBeEnabled();
    await expect(
      settings.getByText(locale === "zh-CN" ? "已连接到 TokenONE" : "Connected to TokenONE", {
        exact: true,
      }),
    ).toBeHidden();
    await captureScreenshot(page, testInfo, "model-account-connection-error");
    available = true;
    await settings.getByRole("button", { name: connectLabel, exact: true }).click();
    const connectedLabel = locale === "zh-CN" ? "已连接到 TokenONE" : "Connected to TokenONE";
    await expect(settings.getByRole("status").filter({ hasText: connectedLabel })).toBeVisible();
    await expect(settings.getByRole("alert")).toBeHidden();
    await expect(settings.getByRole("button", { name: connectLabel, exact: true })).toBeHidden();
    await expect(
      settings.getByRole("button", { name: locale === "zh-CN" ? "取消" : "Cancel", exact: true }),
    ).toBeHidden();
    await expect(
      settings.getByRole("button", {
        name: locale === "zh-CN" ? "断开" : "Disconnect",
        exact: true,
      }),
    ).toBeHidden();
    await captureScreenshot(page, testInfo, "model-account-connected");
  });
}

for (const scenario of ["first", "renewed", "onboarding"]) {
  const reauthorizing = scenario === "renewed";
  const onboarding = scenario === "onboarding";
  test(`${scenario} authorization preserves the original conversation and unsent draft`, async ({
    page,
    context,
  }, testInfo) => {
    let connected = reauthorizing;
    let renewed = false;
    let callback = "";
    await page.route("**/api/model-account/config", (route) =>
      route.fulfill({
        json: {
          enabled: true,
          navigation: {
            cookieName: "one_nav",
            defaults: {
              homeUrl: "https://home.example.test/",
              rechargeUrl: "https://wallet.example.test/",
            },
            channels: [],
            productHosts: [],
          },
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
          ...(!renewed && reauthorizing ? { recovery: "authorization_required" } : {}),
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
      renewed = true;
      return route.fulfill({
        contentType: "text/html",
        body: `<script>location.replace(${JSON.stringify(callback)})</script>`,
      });
    });
    await signup(page, `model-context-${Date.now()}@rakazo.test`, "password12", "Draft Keeper");
    await completeOnboarding(page);
    const composer = page.getByRole("combobox", { name: /Message/ });
    if (!onboarding) await composer.fill("Keep this unsent draft");
    const conversation = page.url();
    const settings = onboarding
      ? page.getByRole("dialog", { name: "Models", exact: true })
      : await openUserSettings(page, "models");
    if (onboarding) {
      const me = await rpc<Me>(page, "me", {});
      await page.route("**/rpc/me", (route) =>
        route.fulfill({ json: { json: { ...me, modelAccountOnly: true } } }),
      );
      await page.goto("/onboarding/model");
      await page.getByRole("button", { name: "Model account", exact: true }).click();
      await expect(settings).toBeVisible();
    }
    const originalURL = page.url();
    await settings
      .getByRole("button", {
        name: reauthorizing ? "Authorize again" : "Use model account",
        exact: true,
      })
      .click();
    await expect(
      settings.getByRole("status").filter({ hasText: "Connected to TokenONE" }),
    ).toBeVisible();
    await expect(
      settings.getByRole("button", { name: "Use model account", exact: true }),
    ).toBeHidden();
    await expect(
      settings.getByRole("button", { name: "Authorize again", exact: true }),
    ).toBeHidden();
    expect(page.url()).toBe(originalURL);
    if (onboarding) await captureScreenshot(page, testInfo, "model-account-onboarding");
    await settings.getByRole("button", { name: /Close .*settings/ }).click();
    if (!onboarding) {
      await expect(composer).toHaveValue("Keep this unsent draft");
      expect(new URL(page.url()).pathname).toBe(new URL(conversation).pathname);
    }
  });
}

test("missing OIDC identity has no extra binding action and managed connections have no key editor", async ({
  page,
}) => {
  await page.route("**/api/model-account/config", (route) =>
    route.fulfill({
      json: {
        enabled: true,
        navigation: {
          cookieName: "one_nav",
          defaults: {
            homeUrl: "https://home.example.test/",
            rechargeUrl: "https://wallet.example.test/",
          },
          channels: [],
          productHosts: [],
        },
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
  await page.route("**/rpc/models/credentials", (route) =>
    route.fulfill({
      json: {
        json: [
          {
            id: "managed-fixture",
            provider: "openai-compatible",
            label: "Managed fixture connection",
            hasKey: true,
            isDefault: false,
            managed: true,
            baseUrl: "https://models.example.test/v1",
          },
        ],
      },
    }),
  );
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
        navigation: {
          cookieName: "one_nav",
          defaults: {
            homeUrl: "https://home.example.test/",
            rechargeUrl: "https://wallet.example.test/",
          },
          channels: [],
          productHosts: [],
        },
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
  await expect(
    settings.getByRole("status").filter({ hasText: "Connected to TokenONE" }),
  ).toBeVisible();
  await expect(settings.getByRole("button", { name: "Retry", exact: true })).toBeHidden();
  await expect(
    settings.getByRole("button", { name: "Use model account", exact: true }),
  ).toBeHidden();
  expect(authorizations).toBe(0);
});

test("account-only settings retain model choices without ordinary connection controls", async ({
  page,
}, testInfo) => {
  await signup(page, `account-only-${Date.now()}@rakazo.test`, "password12", "Fixture User");
  await completeOnboarding(page);
  const me = await rpc<Me>(page, "me", {});
  await page.route("**/rpc/me", (route) =>
    route.fulfill({ json: { json: { ...me, modelAccountOnly: true } } }),
  );
  let configured = false;
  await page.route("**/api/model-account/config", (route) =>
    route.fulfill({ json: { enabled: configured } }),
  );
  await page.route("**/api/model-account/status", (route) =>
    route.fulfill({ json: { enabled: true, connected: true, linked: true } }),
  );
  await page.route("**/api/model-account/balance", (route) =>
    route.fulfill({ json: { amount: "12.34", unit: "USD" } }),
  );
  const choice = {
    provider: "openai-compatible",
    modelId: "fixture-model",
    credentialId: "external-fixture",
  };
  const entries = [
    {
      provider: choice.provider,
      id: choice.modelId,
      label: "Fixture model",
      providerName: "Model account",
      credentialIds: [choice.credentialId],
    },
    {
      provider: choice.provider,
      id: "fixture-backup",
      label: "Fixture backup",
      credentialIds: [choice.credentialId],
    },
  ];
  await page.route("**/rpc/models/list", (route) => route.fulfill({ json: { json: entries } }));
  await page.route("**/rpc/models/forRole", (route) => route.fulfill({ json: { json: entries } }));
  await page.route("**/rpc/models/role", (route) =>
    route.fulfill({ json: { json: { primary: choice, backups: [], deploymentPrimary: null } } }),
  );
  await page.route("**/rpc/models/credentials", (route) =>
    route.fulfill({
      json: {
        json: [
          {
            id: choice.credentialId,
            label: "Model account",
            provider: choice.provider,
            managed: true,
            modelId: choice.modelId,
            enabledModelIds: [choice.modelId, "fixture-backup"],
          },
        ],
      },
    }),
  );
  const settings = await openUserSettings(page, "models");
  await expect(settings.getByRole("alert")).toHaveText("Model account unavailable");
  await expect(settings.getByRole("button", { name: "Add provider", exact: true })).toBeHidden();
  configured = true;
  await page.evaluate(() => window.dispatchEvent(new Event("focus")));
  await expect(settings.getByText("Connected to TokenONE", { exact: true })).toBeVisible();
  await expect(settings.getByText("Providers", { exact: true })).toBeHidden();
  await expect(settings.getByRole("button", { name: "Add provider", exact: true })).toBeHidden();
  await expect(settings.getByText("Main model", { exact: true })).toBeVisible();
  await expect(settings.getByText("Approval model", { exact: true })).toBeVisible();
  await captureScreenshot(page, testInfo, "model-account-only-settings");
  await settings.getByRole("button", { name: "Add fallback", exact: true }).first().click();
  await expect(page.getByRole("option", { name: /Fixture backup/ })).toBeVisible();
  await expect(page.getByRole("option").filter({ hasText: "Connect" })).toHaveCount(0);
});
