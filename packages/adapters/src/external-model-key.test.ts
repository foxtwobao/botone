import type { ExternalModelAccountProvider } from "@rakazo/adapter-kit";
import { expect, it, vi } from "vitest";
import { createExternalModelKeyResolver } from "./external-model-key.js";
import { configuredModelAccount } from "./model-account-config.js";
import { parseModelSecret, resolveModelAuth, serializeModelSecret } from "./pi-oauth.js";

const base = "https://models.example.test/v1";
const reference = { accountId: "account", binding: "binding" };
const identity = { ...reference, issuer: "https://identity.example.test", subject: "subject" };

it("pins identity and destination before obtaining a key, without persisting it", async () => {
  const ensure = vi.fn(async () => ({ apiKey: "fake-user-key" }));
  const read = vi.fn(async () => identity);
  const resolver = createExternalModelKeyResolver(
    { ensure } as unknown as ExternalModelAccountProvider,
    base,
    read,
  );
  const serialized = serializeModelSecret({
    kind: "openai_compatible",
    baseUrl: base,
    externalAccount: reference,
  });
  expect(parseModelSecret(serialized)).toMatchObject({ externalAccount: reference });
  const result = await resolveModelAuth(serialized, "openai-compatible", {
    externalKey: (ref, url) => resolver("user", ref, url),
  });
  expect(result.apiKey).toBe("fake-user-key");
  expect(result.secret).not.toHaveProperty("apiKey");
  expect(read).toHaveBeenCalledWith("user");
  expect(ensure).toHaveBeenCalledWith(
    { issuer: identity.issuer, subject: identity.subject },
    undefined,
  );
  ensure.mockClear();
  await expect(resolver("user", reference, "https://evil.example.test/v1")).rejects.toThrow();
  await expect(resolver("user", { ...reference, binding: "different" }, base)).rejects.toThrow();
  expect(ensure).not.toHaveBeenCalled();
});

it("fails closed when no resolver is configured instead of using an embedded or default key", async () => {
  const secret = serializeModelSecret({
    kind: "openai_compatible",
    baseUrl: base,
    externalAccount: reference,
    apiKey: "must-not-use",
  });
  await expect(resolveModelAuth(secret, "openai-compatible")).rejects.toThrow("Model account");
});

it("does not affect ordinary saved credentials", async () => {
  expect((await resolveModelAuth("ordinary-key", "openai")).apiKey).toBe("ordinary-key");
});

it("accepts HTTP for the server account origin while keeping other destinations on HTTPS", () => {
  const config = {
    provider: "reseller",
    origin: "http://accounts.internal:55100",
    credential: "fake-credential",
    baseUrl: base,
  };
  expect(configuredModelAccount(JSON.stringify(config))?.provider).toBeDefined();
  for (const override of [
    { origin: "ftp://accounts.internal" },
    { origin: "http://user:password@accounts.internal" },
    { origin: "http://accounts.internal/path" },
    { origin: "http://accounts.internal/?query=1" },
    { origin: "http://accounts.internal/#fragment" },
    { authorizationOrigins: ["http://gateway.example.test"] },
    { navigationOrigin: "http://home.example.test" },
    { baseUrl: "http://models.example.test/v1" },
  ]) {
    expect(() => configuredModelAccount(JSON.stringify({ ...config, ...override }))).toThrow(
      "Invalid MODEL_ACCOUNT_CONNECTION configuration",
    );
  }
});

it("configures optional accounts using compatible settings and sanitizes configuration errors", () => {
  const config = {
    provider: "reseller",
    origin: "https://accounts.example.test",
    credential: "fake-credential",
    authorizationOrigins: ["https://gateway.example.test"],
    homeUrl: "https://home.example.test/",
    rechargeUrl: "https://wallet.example.test/",
    modelId: "example-model",
    model: { kind: "openai_compatible", baseUrl: base, apiProtocol: "chat-completions" },
  };
  expect(configuredModelAccount(undefined)).toBeUndefined();
  expect(
    configuredModelAccount(
      JSON.stringify({
        provider: "reseller",
        origin: config.origin,
        credential: config.credential,
        baseUrl: base,
      }),
    )?.model,
  ).toMatchObject({ kind: "openai_compatible", baseUrl: base });
  expect(configuredModelAccount(JSON.stringify(config))?.model.enabledModelIds).toBeUndefined();
  for (const model of [
    { ...config.model, apiKey: "private-key" },
    { ...config.model, baseUrl: "http://models.example.test" },
    { ...config.model, headers: { Authorization: "private-key" } },
  ]) {
    expect(() => configuredModelAccount(JSON.stringify({ ...config, model }))).toThrow(
      "Invalid MODEL_ACCOUNT_CONNECTION configuration",
    );
  }
});
