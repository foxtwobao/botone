import { bestEffort } from "@rakazo/logging/best-effort";
import { modelAccountClient } from "./model-account-client";

/** Only account deployments add model setup to the upstream sign-in route. */
export async function signedInRoute(
  me: { needsSignupSurvey?: boolean; needsModel?: boolean } | null,
) {
  const upstreamRoute = me?.needsSignupSurvey ? ("/signup-survey" as const) : ("/" as const);
  if (!me?.needsModel) return upstreamRoute;
  const config = await bestEffort("read the model account config", modelAccountClient().config());
  if (!config?.modelAccountOnly) return upstreamRoute;
  return me.needsSignupSurvey
    ? { pathname: "/signup-survey" as const, params: { next: "models" } }
    : ("/models" as const);
}
