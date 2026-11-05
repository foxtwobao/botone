import type * as Adapters from "@rakazo/adapters";
import type { ApplicationServices } from "@rakazo/adapters";
import type { Auth } from "@rakazo/auth";
import type { Actor } from "@rakazo/contracts";
import { Hono } from "hono";
import { expect, it, vi } from "vitest";
import { createConnectedApps } from "./connected-apps.js";

const { load } = vi.hoisted(() => ({ load: vi.fn() }));
vi.mock("@rakazo/adapters", async (original) => ({
  ...(await original<typeof Adapters>()),
  loadConfiguredApps: load,
}));

const actor: Actor = {
  userId: "user-a",
  spaceId: "space-a",
  email: "demo@example.test",
  isDeploymentOwner: false,
};

async function fixture() {
  const initialize = vi.fn();
  const handle = vi.fn(async () => new Response(null, { status: 401 }));
  load.mockResolvedValue({ connectors: [], initialize, handle });
  const deps = {} as Pick<ApplicationServices, "prisma" | "artifacts" | "events">;
  const getAuth = vi.fn(() => ({}) as Auth);
  const apps = await createConnectedApps({ ...deps, env: { maxUploadSizeBytes: 1024 } }, getAuth);
  expect(getAuth).not.toHaveBeenCalled();
  return { apps, initialize, handle };
}

it("initializes connections only after authenticated successful account access", async () => {
  const { apps, initialize } = await fixture();
  const me = new Request("https://bot.example.test/rpc/me", { method: "POST" });
  apps.afterRpc(null, me, new Response());
  apps.afterRpc(actor, me, new Response(null, { status: 401 }));
  apps.afterRpc(actor, new Request(me.url), new Response());
  apps.afterRpc(
    actor,
    new Request("https://bot.example.test/rpc/connections/list", { method: "POST" }),
    new Response(),
  );
  expect(initialize).not.toHaveBeenCalled();
  apps.afterRpc(actor, me, new Response());
  expect(initialize).toHaveBeenCalledExactlyOnceWith(actor);
});

it("mounts the same internal boundary without bypassing preceding middleware", async () => {
  const { apps, handle } = await fixture();
  const app = new Hono();
  app.use("*", async (c, next) => {
    await next();
    c.header("x-test-middleware", "applied");
  });
  apps.mount(app);
  const response = await app.request("http://internal.example.test/internal/apps/example", {
    method: "POST",
  });
  expect(response.status).toBe(401);
  expect(response.headers.get("x-test-middleware")).toBe("applied");
  expect(handle).toHaveBeenCalledWith(expect.any(Request), "example");
});
