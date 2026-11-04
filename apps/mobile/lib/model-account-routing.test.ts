import { beforeEach, expect, it, vi } from "vitest";
import { signedInRoute } from "./model-account-routing";

const config = vi.hoisted(() => vi.fn());
vi.mock("./model-account-client", () => ({ modelAccountClient: () => ({ config }) }));
beforeEach(() => {
  config.mockReset().mockResolvedValue({ enabled: false, modelAccountOnly: false });
});

it("guides an account deployment without a model through account settings", async () => {
  config.mockResolvedValue({ enabled: true, modelAccountOnly: true });
  await expect(signedInRoute({ needsSignupSurvey: false, needsModel: true })).resolves.toBe(
    "/models",
  );
  await expect(signedInRoute({ needsSignupSurvey: true, needsModel: true })).resolves.toEqual({
    pathname: "/signup-survey",
    params: { next: "models" },
  });
});

it("preserves upstream sign-in destinations for ordinary connections without a model", async () => {
  await expect(signedInRoute({ needsSignupSurvey: false, needsModel: true })).resolves.toBe("/");
  await expect(signedInRoute({ needsSignupSurvey: true, needsModel: true })).resolves.toBe(
    "/signup-survey",
  );
});

it("uses upstream destinations when the account policy cannot be loaded", async () => {
  config.mockRejectedValue(new Error("offline"));
  await expect(signedInRoute({ needsSignupSurvey: false, needsModel: true })).resolves.toBe("/");
});

it("does not read account policy for existing models or an unavailable session", async () => {
  await expect(signedInRoute({ needsSignupSurvey: false, needsModel: false })).resolves.toBe("/");
  await expect(signedInRoute({ needsSignupSurvey: true, needsModel: false })).resolves.toBe(
    "/signup-survey",
  );
  await expect(signedInRoute(null)).resolves.toBe("/");
  expect(config).not.toHaveBeenCalled();
});
