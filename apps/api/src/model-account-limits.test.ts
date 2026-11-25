import { modelCredentialDto, serializeModelSecret } from "@rakazo/adapters";
import { OPENAI_COMPATIBLE_PROVIDER_ID } from "@rakazo/contracts";
import { accountModelThinkingLevel, connectionModels } from "@rakazo/core";
import { expect, it } from "vitest";
import { applyModelAccountLimits } from "./model-account-limits.js";

it("isolates authorized models and preserves image and thinking settings when editing limits", () => {
  const secret = {
    kind: "openai_compatible" as const,
    baseUrl: "https://models.example.test",
    enabledModelIds: ["first", "other"],
    visionModelIds: ["first"],
    reasoning: true,
    models: { other: { maxTokens: 128 } },
  };
  expect(applyModelAccountLimits(secret, "missing", {})).toBeNull();
  const changed = applyModelAccountLimits(secret, "first", { maxTokens: 2048 })!;
  expect(changed.models).toEqual({
    first: { maxTokens: 2048, reasoning: true, images: true },
    other: { maxTokens: 128 },
  });
  expect(applyModelAccountLimits(changed, "first", {})?.models).toEqual({
    first: { reasoning: true, images: true },
    other: { maxTokens: 128 },
  });
});

it("saves an older app's thinking switch as the default level and restores a default without changing image settings", () => {
  const secret = {
    kind: "openai_compatible" as const,
    baseUrl: "https://models.example.test",
    enabledModelIds: ["first", "second"],
    models: { second: { reasoning: false } },
  };
  const enabled = applyModelAccountLimits(secret, "first", { reasoning: true })!;
  expect(enabled.models).toEqual({
    first: { reasoning: true, thinkingLevel: "medium" },
    second: { reasoning: false },
  });
  expect(applyModelAccountLimits(enabled, "first", { reasoning: null })?.models).toEqual(
    secret.models,
  );

  const inherited = { ...secret, reasoning: true, visionModelIds: ["first"] };
  const disabled = applyModelAccountLimits(inherited, "first", { reasoning: false })!;
  expect(disabled.models.first).toEqual({ reasoning: false, images: true });
  expect(applyModelAccountLimits(disabled, "first", { reasoning: null })?.models.first).toEqual({
    reasoning: true,
    images: true,
  });
});

it("sets the level an account model thinks at by default, until it follows the connection", () => {
  const secret = {
    kind: "openai_compatible" as const,
    baseUrl: "https://models.example.test",
    enabledModelIds: ["first"],
    models: { first: { reasoning: true, thinkingLevel: "low" as const, maxTokens: 2048 } },
  };
  // An omitted level leaves thinking alone, like any field the form did not change.
  expect(applyModelAccountLimits(secret, "first", { maxTokens: 1024 })?.models.first).toEqual({
    reasoning: true,
    thinkingLevel: "low",
    maxTokens: 1024,
  });
  const high = applyModelAccountLimits(secret, "first", {
    reasoning: false,
    thinkingLevel: "high",
  })!;
  expect(high.models.first).toEqual({ reasoning: true, thinkingLevel: "high" });
  expect(applyModelAccountLimits(high, "first", { thinkingLevel: "off" })?.models.first).toEqual({
    reasoning: false,
  });
  expect(
    applyModelAccountLimits(high, "first", { maxTokens: 2048, thinkingLevel: null })?.models,
  ).toEqual({ first: { maxTokens: 2048 } });
});

it("keeps a model following a connection that thinks by default once Default is saved", () => {
  const secret = {
    kind: "openai_compatible" as const,
    baseUrl: "https://models.example.test",
    enabledModelIds: ["first"],
    // An older connection's switch, which a model follows until it has settings of its own.
    reasoning: true,
  };
  const saved = applyModelAccountLimits(secret, "first", {
    maxTokens: 2048,
    thinkingLevel: null,
  })!;
  // A model's own settings replace the connection's, so its row keeps the switch it follows.
  expect(saved.models.first).toEqual({ maxTokens: 2048, reasoning: true });
  const credential = modelCredentialDto(
    { id: "external-fixture", provider: OPENAI_COMPATIBLE_PROVIDER_ID, label: "Model account" },
    serializeModelSecret(saved),
  );
  const model = connectionModels(credential, [])[0]!;
  expect(accountModelThinkingLevel(model.settings, credential, model.id)).toBeNull();
});
