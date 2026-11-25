import type { SandboxProvider } from "@rakazo/adapter-kit";
import { createInitializedRunSandbox } from "@rakazo/adapters";
import type { PrismaClient } from "@rakazo/db";
import { Hono } from "hono";
import { afterEach, expect, it, vi } from "vitest";
import { createAccountModelSandbox, loadForkEnv } from "./fork-features.js";
import { createModelAccountFeature } from "./model-account-setup.js";

vi.mock("@rakazo/adapters", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@rakazo/adapters")>()),
  createInitializedRunSandbox: vi.fn(),
}));
afterEach(() => vi.unstubAllEnvs());

const env = { authUrl: "https://api.example.test", encryptionKey: "fake-signing-key" };
const options = { prisma: {} as PrismaClient, secrets: { load: vi.fn(), onChange: vi.fn() } };
const connection = JSON.stringify({
  provider: "reseller",
  origin: "https://accounts.example.test",
  credential: "fake-app-key",
  baseUrl: "https://models.example.test/v1",
});
const initialization = { url: env.authUrl, signingKey: env.encryptionKey };

it.each([undefined, " ", connection])(
  "sets up the account model on new computers from the connection the app was built with (%s)",
  async (modelAccountConnection) => {
    // The process environment names another account than the app was built with.
    vi.stubEnv(
      "MODEL_ACCOUNT_CONNECTION",
      modelAccountConnection === connection ? undefined : connection,
    );
    vi.mocked(createInitializedRunSandbox).mockResolvedValue({} as SandboxProvider);
    await createAccountModelSandbox({ ...env, modelAccountConnection }, "docker", options);
    expect(vi.mocked(createInitializedRunSandbox)).toHaveBeenCalledExactlyOnceWith("docker", {
      ...options,
      initialization: modelAccountConnection === connection ? initialization : undefined,
    });
  },
);

it("refuses a connection the account routes would refuse", () => {
  // Before any computer provider is built, and before a sandbox can be handed out.
  expect(() =>
    createAccountModelSandbox({ ...env, modelAccountConnection: "{not json" }, "docker", options),
  ).toThrow("Invalid MODEL_ACCOUNT_CONNECTION configuration");
  expect(vi.mocked(createInitializedRunSandbox)).not.toHaveBeenCalled();
});

it("reads the account model's settings from the environment the API starts with", () => {
  vi.stubEnv("DATABASE_URL", "postgres://rakazo:rakazo@127.0.0.1:5433/rakazo");
  vi.stubEnv("MODEL_ACCOUNT_CONNECTION", connection);
  vi.stubEnv("PI_DEFAULT_MODEL", " account-default ");
  const loaded = loadForkEnv();
  expect(loaded.modelAccountConnection).toBe(connection);
  expect(loaded.modelAccountDefaultModel).toBe("account-default");
  vi.stubEnv("MODEL_ACCOUNT_CONNECTION", " ");
  vi.stubEnv("PI_DEFAULT_MODEL", undefined);
  const blank = loadForkEnv();
  expect(blank.modelAccountConnection).toBeUndefined();
  expect(blank.modelAccountDefaultModel).toBeUndefined();
});

it("gives the account routes and new computers the same answer for whether an account is set up", async () => {
  vi.mocked(createInitializedRunSandbox).mockResolvedValue({} as SandboxProvider);
  const accountEnv = {
    ...env,
    webOrigin: "https://app.example.test",
    agentRuntime: "scripted" as const,
    stripeSecretKey: undefined,
    stripeWebhookSecret: undefined,
    oidc: {
      issuer: "https://identity.example.test",
      clientId: "fixture",
      clientSecret: "fake-secret",
      name: "SSO",
      scopes: [],
      allowSignupBypass: false,
    },
  };
  for (const modelAccountConnection of [undefined, " ", connection]) {
    // One merged value, as the app builds it, reaches both.
    const merged = { ...accountEnv, modelAccountConnection };
    await createAccountModelSandbox(merged, "docker", options);
    const enabled = vi.mocked(createInitializedRunSandbox).mock.lastCall?.[1].initialization;
    const app = new Hono();
    createModelAccountFeature(merged).mount(app, {
      prisma: {} as never,
      auth: {} as never,
      secrets: {} as never,
    });
    const response = await app.request("/api/model-account/config");
    expect(await response.json()).toMatchObject({ enabled: Boolean(enabled) });
  }
});
