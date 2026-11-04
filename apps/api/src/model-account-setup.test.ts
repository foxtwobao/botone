import type { BillingProvider } from "@rakazo/adapter-kit";
import { Hono } from "hono";
import { expect, it } from "vitest";
import { createModelAccountFeature } from "./model-account-setup.js";

const env: Parameters<typeof createModelAccountFeature>[0] = {
  webOrigin: "https://app.example.test",
  authUrl: "https://api.example.test",
  agentRuntime: "pi",
  stripeSecretKey: undefined,
  stripeWebhookSecret: undefined,
};
const connection = JSON.stringify({
  provider: "reseller",
  origin: "https://accounts.example.test",
  credential: "fake-app-credential",
  baseUrl: "https://models.example.test/v1",
});
const oidc = {
  issuer: "https://identity.example.test",
  clientId: "fixture",
  clientSecret: "fake-secret",
  name: "SSO",
  scopes: [],
  allowSignupBypass: false,
};

it("keeps account configuration validation ahead of runtime setup", () => {
  for (const patch of [
    { oidc: undefined },
    { stripeSecretKey: "fake-billing-key" },
    { stripeWebhookSecret: "fake-webhook-secret" },
  ]) {
    expect(() =>
      createModelAccountFeature({
        ...env,
        modelAccountConnection: connection,
        oidc,
        ...patch,
      }),
    ).toThrow("Model account requires OIDC and local billing disabled");
  }
  expect(() =>
    createModelAccountFeature(
      { ...env, modelAccountConnection: connection, oidc },
      {} as BillingProvider,
    ),
  ).toThrow("Model account requires OIDC and local billing disabled");
  expect(() =>
    createModelAccountFeature({ ...env, modelAccountConnection: connection, oidc }),
  ).not.toThrow();
});

it.each(["pi", "scripted"])(
  "mounts the account policy for %s without account configuration",
  async (agentRuntime) => {
    const app = new Hono();
    createModelAccountFeature({ ...env, agentRuntime }, {} as BillingProvider).mount(app, {
      prisma: {} as never,
      auth: {} as never,
      secrets: {} as never,
    });
    const response = await app.request("/api/model-account/config");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      enabled: false,
      ...(agentRuntime === "pi" ? { modelAccountOnly: true } : {}),
    });
  },
);
