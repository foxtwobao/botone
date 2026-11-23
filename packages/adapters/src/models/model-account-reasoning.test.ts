import { credentialModelSettings, modelThinkingLevels } from "@rakazo/core";
import { expect, it } from "vitest";
import { reasoningModelIds } from "./model-account-reasoning.js";
import { modelCredentialDto } from "./model-connect.js";
import { parseModelSecret, serializeModelSecret } from "./model-secret.js";
import { connectionModelSettings } from "./model-settings.js";

it("requires an exact ID whose catalog entries agree on thinking support", () => {
  expect(
    reasoningModelIds([
      { id: "known", reasoning: true },
      { id: "mixed", reasoning: false },
      { id: "mixed", reasoning: true },
      { id: "plain", reasoning: false },
    ]),
  ).toEqual(new Set(["known"]));
});

it("uses catalog defaults on managed accounts in both the picker and runtime, preserving overrides", () => {
  const known = "deepseek-v4.1-flash";
  const other = "gpt-6.2-sol";
  const alias = `${known}-fixture`;
  const row = {
    id: "fixture",
    provider: "openai-compatible",
    label: "Fixture",
    defaultModel: known,
  };
  const raw = {
    kind: "openai_compatible",
    baseUrl: "https://example.test/v1",
    enabledModelIds: [known, other, alias],
    models: {
      [known]: { maxTokens: 2000 },
      [other]: { reasoning: false },
      [alias]: { reasoning: true },
    },
  };
  for (const managed of [true, false]) {
    const plaintext = JSON.stringify(
      managed ? { ...raw, externalAccount: { accountId: "fixture", binding: "fixture" } } : raw,
    );
    const secret = parseModelSecret(plaintext);
    const dto = modelCredentialDto(row, plaintext);
    for (const [id, supported] of [
      [known, managed],
      [other, false],
      [alias, true],
    ] as const) {
      expect(connectionModelSettings(secret, row.provider, id).reasoning ?? false).toBe(supported);
      expect(credentialModelSettings(dto, id).reasoning ?? false).toBe(supported);
      expect(modelThinkingLevels(dto, undefined, id).includes("high")).toBe(supported);
    }
    expect(dto.defaultReasoningModelIds).toEqual(managed ? [known, other] : undefined);
    expect(JSON.parse(serializeModelSecret(secret)).models).toEqual(raw.models);
  }
});
