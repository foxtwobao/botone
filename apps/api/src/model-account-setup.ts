import type { BillingProvider } from "@rakazo/adapter-kit";
import { configuredExecutionConnection, configuredModelAccount } from "@rakazo/adapters";
import type { Hono } from "hono";
import type { AppEnv } from "./env.js";
import { modelAccountRoutes } from "./model-account.js";
import type { ModelAccountEnv } from "./model-account-env.js";

type AccountEnv = ModelAccountEnv & { encryptionKey?: string } & Pick<
    AppEnv,
    "oidc" | "stripeSecretKey" | "stripeWebhookSecret" | "agentRuntime" | "webOrigin" | "authUrl"
  >;
type Runtime = Pick<
  Parameters<typeof modelAccountRoutes>[0],
  "prisma" | "auth" | "secrets" | "sandbox"
>;

/** Validate before billing starts, then mount once the app's runtime dependencies exist. */
export function createModelAccountFeature(env: AccountEnv, billingOverride?: BillingProvider) {
  const execution = configuredExecutionConnection(env.executionConnection);
  const connection = configuredModelAccount(env.modelAccountConnection);
  if (execution && (!connection || !env.encryptionKey || !env.authUrl))
    throw new Error(
      "Automatic execution requires a model account connection and computer initialization",
    );
  if (
    connection &&
    (!env.oidc || env.stripeSecretKey || env.stripeWebhookSecret || billingOverride)
  )
    throw new Error("Model account requires OIDC and local billing disabled");
  return {
    mount(app: Hono, runtime: Runtime) {
      app.route(
        "/api/model-account",
        modelAccountRoutes({
          ...runtime,
          connection,
          defaultModel: env.modelAccountDefaultModel,
          modelAccountOnly: Boolean(env.agentRuntime && env.agentRuntime !== "scripted"),
          issuer: env.oidc?.issuer,
          webOrigin: env.webOrigin,
          authUrl: env.authUrl,
          initializationKey: env.encryptionKey,
          executionConnection: env.executionConnection,
        }),
      );
    },
  };
}
