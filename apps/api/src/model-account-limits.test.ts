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

it("changes thinking for one model and restores its default without changing image settings", () => {
  const secret = {
    kind: "openai_compatible" as const,
    baseUrl: "https://models.example.test",
    enabledModelIds: ["first", "second"],
    models: { second: { reasoning: false } },
  };
  const enabled = applyModelAccountLimits(secret, "first", { reasoning: true })!;
  expect(enabled.models).toEqual({ first: { reasoning: true }, second: { reasoning: false } });
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
