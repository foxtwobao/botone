import { expect, it } from "vitest";
import { loadModelAccountEnv } from "./model-account-env.js";

it("loads account configuration independently from the generic app environment", () => {
  expect(loadModelAccountEnv({ MODEL_ACCOUNT_CONNECTION: '  {"provider":"fixture"}  ' })).toEqual({
    modelAccountConnection: '{"provider":"fixture"}',
    modelAccountDefaultModel: undefined,
  });
  for (const value of [undefined, "", "  "]) {
    expect(loadModelAccountEnv({ MODEL_ACCOUNT_CONNECTION: value })).toEqual({
      modelAccountConnection: undefined,
      modelAccountDefaultModel: undefined,
    });
  }
});

it("uses the existing configurable default model without inventing an account-specific env variable", () => {
  expect(
    loadModelAccountEnv({ PI_DEFAULT_MODEL: "  gpt-6.1-terra  " }).modelAccountDefaultModel,
  ).toBe("gpt-6.1-terra");
  expect(loadModelAccountEnv({ PI_DEFAULT_MODEL: " " }).modelAccountDefaultModel).toBeUndefined();
});
