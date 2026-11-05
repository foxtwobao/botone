import type {
  ApplicationServices,
  ConnectedApplication,
  UserAccessCredential,
} from "./configured-apps.js";
import { ApplicationCredentialError } from "./configured-apps.js";
import { CreativeAppConnector } from "./creative-connector.js";
import {
  CreativeServiceError,
  creativeConnectionSchema,
  UserCreativeProvider,
} from "./creative-provider.js";

async function credentialCall<T>(call: () => Promise<T>): Promise<T> {
  try {
    return await call();
  } catch (error) {
    if (error instanceof ApplicationCredentialError)
      throw new CreativeServiceError(error.code, error.status);
    throw error;
  }
}

export function createApplication(
  options: unknown,
  services: ApplicationServices,
): ConnectedApplication {
  const config = creativeConnectionSchema.parse(options);
  if (!services.credentials || !services.providerScopeKey)
    throw new Error("Application host services unavailable");
  const providerScopeKey = services.providerScopeKey;
  const credentials = services.credentials;
  const connector = new CreativeAppConnector(
    config,
    new UserCreativeProvider(config),
    services,
    async (userId): Promise<UserAccessCredential | null> => {
      const identity = await credentialCall(() => credentials(userId));
      if (!identity) return null;
      return {
        accountId: identity.accountId,
        binding: identity.binding,
        accessToken: () => credentialCall(() => identity.accessToken()),
        refreshAccessToken: identity.refreshAccessToken
          ? () => credentialCall(() => identity.refreshAccessToken!())
          : undefined,
      };
    },
    (context) => providerScopeKey(context, "creative", "creative"),
  );
  return {
    connector,
    start: () => connector.creativeJobs.start(),
    initialize: (actor) =>
      connector.ensureConnection({
        userId: actor.userId,
        spaceId: actor.spaceId,
        operationId: "connections.auto",
        traceId: "connections.auto",
        signal: AbortSignal.timeout(20_000),
      }),
    stop: () => connector.creativeJobs.stop(),
  };
}
