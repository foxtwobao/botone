import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("expo-router", () => ({
  router: { dismissTo: vi.fn(), replace: vi.fn() },
}));

import { router } from "expo-router";
import {
  explicitSignInRoute,
  initialAuthMode,
  replaceWithSignIn,
  signedInRoute,
} from "./auth-routing.js";

beforeEach(() => {
  vi.clearAllMocks();
});

describe("mobile authentication routing", () => {
  it("guides a signed-in account without a model through existing model settings", () => {
    expect(signedInRoute({ needsSignupSurvey: false, needsModel: true })).toBe("/models");
    expect(signedInRoute({ needsSignupSurvey: true, needsModel: true })).toEqual({
      pathname: "/signup-survey",
      params: { next: "models" },
    });
    expect(signedInRoute({ needsSignupSurvey: false, needsModel: false })).toBe("/");
    expect(signedInRoute({ needsSignupSurvey: true, needsModel: false })).toBe("/signup-survey");
    expect(signedInRoute(null)).toBe("/");
  });

  it("defaults ordinary logged-out visitors to sign-up", () => {
    expect(initialAuthMode()).toBe("up");
  });

  it("honors the explicit sign-in route used after logout", () => {
    expect(explicitSignInRoute).toEqual({ pathname: "/sign-in", params: { mode: "in" } });
    expect(initialAuthMode(explicitSignInRoute.params.mode)).toBe("in");
  });

  it("returns to the root stack before replacing it with sign-in", () => {
    replaceWithSignIn();

    expect(router.dismissTo).toHaveBeenCalledWith("/");
    expect(router.replace).toHaveBeenCalledWith(explicitSignInRoute);
    expect(vi.mocked(router.dismissTo).mock.invocationCallOrder[0]).toBeLessThan(
      vi.mocked(router.replace).mock.invocationCallOrder[0] ?? 0,
    );
  });

  it("keeps the plain sign-in route used after deleting the account", () => {
    replaceWithSignIn("/sign-in");

    expect(router.replace).toHaveBeenCalledWith("/sign-in");
  });
});
