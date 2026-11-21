import type { ApplicationServices, ConnectedApplication } from "../../../configured-apps.js";
import { FeishuOfficeConnector } from "./feishu-connector.js";
import { feishuConnectionSchema } from "./feishu-contracts.js";
import { LarkFeishuProvider } from "./feishu-provider.js";

const ID = "feishu";

export function createApplication(
  options: unknown,
  services: ApplicationServices,
): ConnectedApplication {
  const config = feishuConnectionSchema.parse(options);
  if (!services.providerScopeKey) throw new Error("Application host services unavailable");
  if (config.identity === "user" && !services.secrets)
    throw new Error("Feishu user identity requires a secret store on the application host");
  const providerScopeKey = services.providerScopeKey;
  const connector = new FeishuOfficeConnector(
    config,
    new LarkFeishuProvider(config),
    services,
    (context) => providerScopeKey(context, ID, ID),
  );
  return {
    connector,
    start() {},
    initialize: (actor) =>
      connector.ensureConnection({
        userId: actor.userId,
        spaceId: actor.spaceId,
        operationId: "connections.auto",
        traceId: "connections.auto",
        signal: AbortSignal.timeout(20_000),
      }),
    async stop() {},
  };
}
