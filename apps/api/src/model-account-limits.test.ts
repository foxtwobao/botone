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
