import type { PrismaClient } from "@rakazo/db";
import { expect, it, vi } from "vitest";
import type { ExecutorDeps } from "./executor-deps.js";
import { modelAccountCatalog, modelAccountRole } from "./model-account-policy.js";
import { findConnectedModelCredential, validateBotModelChange } from "./model-selection.js";
import { serializeModelSecret } from "./pi-oauth.js";
import { resolveModelKey } from "./run-model.js";

const scope = { userId: "fixture-user", spaceId: "fixture-space" };
const credential = {
  id: "external-fixture",
  provider: "openai-compatible",
  secretId: "fixture-secret",
};
const stored = serializeModelSecret({
  kind: "openai_compatible",
  baseUrl: "https://models.example.test/v1",
  enabledModelIds: ["account-model"],
  externalAccount: { accountId: "fixture-account", binding: "fixture-binding" },
});
const fixture = (plaintext = stored) => {
  const prisma = {
    userModelCredential: { findMany: vi.fn(async () => [credential]) },
    secret: {
      findFirst: vi.fn(async () => ({ id: credential.secretId, ciphertext: "fixture-ciphertext" })),
    },
  } as unknown as PrismaClient;
  const secrets = { load: vi.fn(async () => plaintext) };
  return { prisma, secrets };
};

it("does not keep ordinary role selections or backups", () => {
  const primary = {
    provider: "openai-compatible",
    modelId: "account-model",
    credentialId: credential.id,
  };
  expect(
    modelAccountRole({
      primary: { ...primary, credentialId: "ordinary" },
      backups: [primary, { provider: "other", modelId: "other" }],
    }),
  ).toEqual({ primary: null, backups: [primary] });
});

it("requires the managed reference and an explicitly listed model", async () => {
  const { prisma, secrets } = fixture();
  const select = (model: string, credentialId?: string) =>
    findConnectedModelCredential(prisma, secrets, scope, "openai-compatible", model, {
      modelAccountOnly: true,
      credentialId,
    });
  expect(await select("account-model")).toMatchObject({ id: credential.id });
  expect(await select("account-model", "ordinary")).toBeNull();
  expect(await select("unlisted-model")).toBeNull();
  secrets.load.mockResolvedValue(
    serializeModelSecret({
      kind: "openai_compatible",
      baseUrl: "https://models.example.test/v1",
      apiKey: "fake-key",
      enabledModelIds: ["account-model"],
    }),
  );
  expect(await select("account-model")).toBeNull();
  expect(await modelAccountCatalog(prisma, secrets, scope.userId)).toEqual([]);
});

it.each([
  null,
  "fake-api-key",
  serializeModelSecret({
    kind: "openai_compatible",
    baseUrl: "https://models.example.test/v1",
    apiKey: "fake-key",
  }),
])("blocks ordinary runtime credentials and deployment fallback: %s", async (plaintext) => {
  const { prisma, secrets } = fixture(plaintext ?? stored);
  const externalModelKey = vi.fn();
  const deps = {
    prisma,
    secretStore: secrets,
    externalModelKey,
    billingEnabled: false,
    deploymentModelKey: "fake-deployment-key",
  } as unknown as ExecutorDeps;
  await expect(
    resolveModelKey(
      deps,
      scope.userId,
      scope.spaceId,
      plaintext ? credential : null,
      "openai-compatible",
      "account-model",
    ),
  ).rejects.toThrow();
  expect(externalModelKey).not.toHaveBeenCalled();
});

it("revalidates an unchanged bot model when ordinary connections are disabled", async () => {
  const { prisma, secrets } = fixture();
  const result = await validateBotModelChange(
    {
      prisma,
      secretStore: secrets,
      modelAccountOnly: true,
      refreshExpiredCredential: vi.fn(),
      defaultModel: async () => ({ provider: null, model: null }),
    },
    {
      ...scope,
      provider: "openrouter",
      model: "old-model",
      current: { provider: "openrouter", model: "old-model" },
    },
  );
  expect(result.ok).toBe(false);
});
