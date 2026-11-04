import { expect, it } from "vitest";
import { modelAccountRoutes } from "./model-account.js";

it.each([true, false])(
  "keeps the settings policy available when the connection is disabled (%s)",
  async (modelAccountOnly) => {
    const app = modelAccountRoutes({
      connection: undefined,
      modelAccountOnly,
      prisma: {} as never,
      auth: {} as never,
      secrets: {} as never,
      webOrigin: "https://app.example.test",
      authUrl: "https://api.example.test",
    });
    const response = await app.request("/config");
    expect(response.status).toBe(200);
    const config = await response.json();
    expect(config.enabled).toBe(false);
    expect(Boolean(config.modelAccountOnly)).toBe(modelAccountOnly);
  },
);
