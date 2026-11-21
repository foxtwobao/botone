import { describe, expect, it } from "vitest";
import { loadConfiguredApps } from "../../../configured-apps.js";

const config = {
  appId: "cli_synthetic",
  appSecret: "synthetic",
  domain: "feishu",
  name: "Feishu",
};
const env = { APP_CONNECTIONS: JSON.stringify({ feishu: config }) };

describe("feishu configured-app registration", () => {
  it("loads the feishu connector on the API host", async () => {
    const apps = await loadConfiguredApps({
      env,
      prisma: {} as never,
      artifacts: {} as never,
      events: {} as never,
      credentials: async () => null,
      providerScopeKey: () => "scope",
    });
    expect(apps.connectors.map((c) => c.describe().id)).toEqual(["feishu"]);
    await apps.stop();
  });

  it("uses the proxy connector on a worker without credentials", async () => {
    const apps = await loadConfiguredApps({ env: { ...env, RAKAZO_ALLOW_DEV_SECRETS: "1" } });
    expect(apps.connectors.map((c) => c.describe().id)).toEqual(["feishu"]);
    await apps.stop();
  });

  it("rejects app ids that are not trusted adapters", async () => {
    await expect(
      loadConfiguredApps({ env: { APP_CONNECTIONS: JSON.stringify({ nope: {} }) } }),
    ).rejects.toThrow("Invalid APP_CONNECTIONS configuration");
  });

  it("rejects user identity when the host has no secret store", async () => {
    await expect(
      loadConfiguredApps({
        env: { APP_CONNECTIONS: JSON.stringify({ feishu: { ...config, identity: "user" } }) },
        prisma: {} as never,
        artifacts: {} as never,
        events: {} as never,
        credentials: async () => null,
        providerScopeKey: () => "scope",
      }),
    ).rejects.toThrow("Invalid APP_CONNECTIONS configuration");
  });
});
