import { describe, expect, it } from "vitest";
import { verificationBinding } from "./verification.js";

describe("execution verification binding", () => {
  const profile = {
    id: "personal",
    revision: 1,
    modelConnection: { url: "https://model.example.test/v1", apiKey: "fake-key", model: "model-a" },
  };
  it("keeps discovery metadata separate from the verified execution boundary", () => {
    expect(verificationBinding({ ...profile, models: [{ id: "model-a", label: "Model A" }] })).toBe(
      verificationBinding(profile),
    );
    expect(
      verificationBinding({
        ...profile,
        modelConnection: { ...profile.modelConnection, apiKey: "different-fake-key" },
      }),
    ).not.toBe(verificationBinding(profile));
    expect(verificationBinding({ ...profile, revision: 2 })).not.toBe(verificationBinding(profile));
  });
});
