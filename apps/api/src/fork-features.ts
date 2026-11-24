import type { ArtifactStore, BillingProvider } from "@rakazo/adapter-kit";
import type { ServerFoundation } from "@rakazo/adapters";
import { configuredModelAccount, createInitializedRunSandbox } from "@rakazo/adapters";
import type { Auth } from "@rakazo/auth";
import type { Hono } from "hono";
import { createConnectedApps } from "./connected-apps.js";
import type { AppEnv } from "./env.js";
import { loadEnv } from "./env.js";
import type { ModelAccountEnv } from "./model-account-env.js";
import { loadModelAccountEnv } from "./model-account-env.js";
import { createModelAccountFeature } from "./model-account-setup.js";

/**
 * The app's configuration before its overrides apply: the environment the API loads, with the
 * account model's beside it. One merged value then reaches the routes and the sandbox alike.
 */
export function loadForkEnv(): AppEnv & ModelAccountEnv {
  return { ...loadEnv(process.env), ...loadModelAccountEnv() };
}

/**
 * The run sandbox, which on a new computer also sets up the account's model, when one is named.
 * Reads the connection from `env`, the app's merged configuration, and asks the same question
 * the routes do, so a computer is set up for the account the routes serve and no other.
 */
export function createAccountModelSandbox(
  env: Pick<AppEnv, "authUrl" | "encryptionKey"> & ModelAccountEnv,
  kind: string,
  options: Omit<Parameters<typeof createInitializedRunSandbox>[1], "initialization">,
) {
  return createInitializedRunSandbox(kind, {
    ...options,
    initialization: configuredModelAccount(env.modelAccountConnection)
      ? { url: env.authUrl, signingKey: env.encryptionKey }
      : undefined,
  });
}

/**
 * What this fork adds to the API process, the account model and the connected applications,
 * in the few calls `app.ts` has room for.
 */
export async function startForkFeatures(
  {
    foundation,
    artifacts,
    env,
    billingOverride,
  }: {
    foundation: Pick<ServerFoundation, "prisma" | "events">;
    artifacts: ArtifactStore;
    env: AppEnv & ModelAccountEnv;
    billingOverride?: BillingProvider | undefined;
  },
  getAuth: () => Auth,
) {
  const { prisma, events } = foundation;
  const modelAccount = createModelAccountFeature(env, billingOverride);
  const connectedApps = await createConnectedApps({ prisma, artifacts, events, env }, getAuth);
  return {
    connectors: connectedApps.connectors,
    afterRpc: connectedApps.afterRpc,
    /** The fork's routes; the applications start once the app can serve them. */
    mount(app: Hono, runtime: Parameters<typeof modelAccount.mount>[1]) {
      modelAccount.mount(app, runtime);
      connectedApps.mount(app);
      connectedApps.start();
    },
    stop: () => connectedApps.stop(),
  };
}
