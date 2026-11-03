import { expect, it, vi } from "vitest";
import { readHomeNavigation } from "./homeone-navigation.js";
import { discoverModelAccountModels } from "./model-account-models.js";

const defaults = {
  homeUrl: "https://home.example.test/",
  rechargeUrl: "https://wallet.example.test/wallet",
};
it("reads public navigation policy without sending application credentials or cookies", async () => {
  const transport = vi.fn<typeof fetch>(async () =>
    Response.json({
      navigationPolicy: { defaults: { v: 1, channel: "", ...defaults }, productHosts: [] },
    }),
  );
  expect(await readHomeNavigation("https://home.example.test", transport)).toMatchObject({
    cookieName: "one_nav",
    defaults,
    channels: [],
  });
  expect(String(transport.mock.calls[0]?.[0])).toBe("https://home.example.test/auth.json");
  expect(transport.mock.calls[0]?.[1]).toMatchObject({ redirect: "error" });
  expect(transport.mock.calls[0]?.[1]?.headers).toBeUndefined();
});
it("rejects unsafe or missing navigation without inventing destinations", async () => {
  for (const body of [
    {},
    {
      navigationPolicy: {
        defaults: { v: 1, channel: "", ...defaults, rechargeUrl: "javascript:alert(1)" },
        productHosts: [],
      },
    },
  ])
    await expect(
      readHomeNavigation("https://home.example.test", async () => Response.json(body)),
    ).rejects.toThrow();
});
it("discovers models with a transient user key and validates catalog shape", async () => {
  const transport = vi.fn<typeof fetch>(async () =>
    Response.json({ data: [{ id: "model-a" }, { id: "model-a" }, { id: "model-b" }] }),
  );
  expect(
    await discoverModelAccountModels("https://models.example.test/v1/", "fixture-key", transport),
  ).toEqual(["model-a", "model-b"]);
  expect(transport.mock.calls[0]).toMatchObject([
    "https://models.example.test/v1/models",
    { headers: { authorization: "Bearer fixture-key" }, redirect: "error" },
  ]);
  await expect(
    discoverModelAccountModels("https://models.example.test/v1", "fixture-key", async () =>
      Response.json({ data: [{ id: 1 }] }),
    ),
  ).rejects.toThrow();
});
