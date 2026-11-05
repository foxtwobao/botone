import type { Actor } from "@rakazo/contracts";
import { currentDbContext } from "@rakazo/db";
import { beforeEach, expect, it, vi } from "vitest";
import type { ApplicationServices } from "./configured-apps.js";
import { loadConfiguredApps } from "./configured-apps.js";

const { factory } = vi.hoisted(() => ({ factory: vi.fn() }));
vi.mock("./creative-application.js", () => ({ createApplication: factory }));
const actor: Actor = {
  userId: "user-a",
  spaceId: "space-a",
  email: "demo@example.test",
  isDeploymentOwner: false,
};
const services = (value?: string) =>
  ({
    env: { APP_CONNECTIONS: value },
    credentials: async () => null,
  }) as unknown as ApplicationServices;
beforeEach(() => vi.clearAllMocks());

it("does not load adapters, credentials or background work without configuration", async () => {
  const apps = await loadConfiguredApps(services());
  apps.start();
  apps.initialize(actor);
  await apps.stop();
  expect(apps.connectors).toEqual([]);
  expect(factory).not.toHaveBeenCalled();
  const worker = await loadConfiguredApps({ ...services(), credentials: undefined });
  expect(worker.connectors).toEqual([]);
  await worker.stop();
});

it("rejects malformed settings and executable module names before loading anything", async () => {
  for (const value of ["[", "[]", "null", '{"../arbitrary-module":{}}', '{"__proto__":{}}'])
    await expect(loadConfiguredApps(services(value))).rejects.toThrow("Invalid APP_CONNECTIONS");
  expect(factory).not.toHaveBeenCalled();
});

it("loads adapters on the application host and only a generic proxy on workers", async () => {
  const connector = { describe: () => ({ id: "creative" }) };
  factory.mockReturnValue({ connector, start: vi.fn(), stop: vi.fn() });
  const host = services('{"creative":{"name":"Example"}}');
  const apps = await loadConfiguredApps(host);
  expect(apps.connectors).toEqual([connector]);
  expect(factory).toHaveBeenCalledExactlyOnceWith({ name: "Example" }, host);
  await apps.stop();
  factory.mockClear();
  const worker = await loadConfiguredApps({
    env: { ...host.env, ENCRYPTION_KEY: "fake-existing-encryption-key" },
  });
  expect(worker.connectors[0]!.describe().id).toBe("creative");
  expect(factory).not.toHaveBeenCalled();
  expect(
    (await worker.handle(new Request("http://internal.example.test"), "creative")).status,
  ).toBe(404);
  await worker.stop();
});

it("initializes in the actor's scope without blocking and drains before stopping the adapter", async () => {
  let complete = () => {};
  const check = new Promise<void>((resolve) => {
    complete = resolve;
  });
  const initialize = vi.fn(() => {
    expect(currentDbContext()).toMatchObject({
      kind: "tenant",
      userId: "user-a",
      spaceId: "space-a",
    });
    return check;
  });
  const stop = vi.fn(async () => {});
  factory.mockReturnValue({ connector: {}, start: vi.fn(), initialize, stop });
  const apps = await loadConfiguredApps(services('{"creative":{}}'));
  expect(apps.initialize(actor)).toBeUndefined();
  const draining = apps.stop();
  expect(stop).not.toHaveBeenCalled();
  complete();
  await draining;
  expect(initialize).toHaveBeenCalledOnce();
  expect(stop).toHaveBeenCalledOnce();
  apps.initialize(actor);
  expect(initialize).toHaveBeenCalledOnce();
});

it("does not fail account access when application initialization is unavailable", async () => {
  factory.mockReturnValue({
    connector: {},
    start: vi.fn(),
    stop: vi.fn(),
    initialize: vi.fn(async () => {
      throw new Error("Synthetic unavailable");
    }),
  });
  const apps = await loadConfiguredApps(services('{"creative":{}}'));
  apps.initialize(actor);
  await expect(apps.stop()).resolves.toBeUndefined();
});
