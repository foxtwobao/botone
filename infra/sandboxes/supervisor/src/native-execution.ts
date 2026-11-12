import path from "node:path";
import type { Hono } from "hono";
import { dataDir } from "./context.js";
import { findBotContainer, managedContainer } from "./identity.js";

/** Existing /computers/* middleware authenticates this route before any lazy runtime is loaded. */
export function registerNativeExecution(app: Hono) {
  let closing = false;
  let runtime: Promise<Awaited<ReturnType<typeof load>>> | undefined;
  const load = async () => {
    const { createComputerExecutionRuntime } = await import("@rakazo/native-runtime");
    return createComputerExecutionRuntime({
      root: path.join(dataDir, "native-execution"),
      async resolve(_computerId, homeKey, spaceId) {
        const container = await findBotContainer(homeKey, spaceId);
        if (!container) throw new Error("computer_unavailable");
        const info = await container.inspect();
        const source = Object.fromEntries(
          (info.Config.Env ?? []).map((entry) => {
            const index = entry.indexOf("=");
            return [entry.slice(0, index), entry.slice(index + 1)];
          }),
        );
        const user = info.Config.User;
        if (
          !/^\d+:\d+$/.test(user) ||
          user.split(":").some((value) => Number(value) === 0) ||
          !source.HOME ||
          info.HostConfig.Privileged ||
          [info.HostConfig.NetworkMode, info.HostConfig.PidMode].includes("host")
        )
          throw new Error("unsafe_execution_computer");
        const allowed = new Set([
          "HOME",
          "LANG",
          "LC_ALL",
          "DISPLAY",
          "LD_PRELOAD",
          "NSS_WRAPPER_PASSWD",
          "NSS_WRAPPER_GROUP",
          "DBUS_SESSION_BUS_ADDRESS",
          "XAUTHORITY",
          "HTTP_PROXY",
          "HTTPS_PROXY",
          "NO_PROXY",
          "http_proxy",
          "https_proxy",
          "no_proxy",
        ]);
        const env = Object.fromEntries(
          Object.entries(source).filter(([key]) => allowed.has(key) || key.startsWith("XDG_")),
        );
        env.PATH = `${source.HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin`;
        const workspace = `${source.HOME}/shared`;
        return {
          container,
          env,
          user,
          workspace,
          running: Boolean(info.State.Running),
          revision: info.Image,
        };
      },
    });
  };
  app.all("/computers/:id/execution/:action", async (c) => {
    c.header("cache-control", "no-store");
    if (closing) return c.body(null, 503);
    if (c.req.header("origin")) return c.body(null, 403);
    const homeKey = c.req.header("x-rakazo-bot-id");
    const spaceId = c.req.header("x-rakazo-space-id");
    if (!homeKey || !spaceId) return c.body(null, 403);
    try {
      // Validate the container before creating persistent execution state.
      await managedContainer(c.req.param("id"), homeKey, spaceId);
      const header = c.req.header("x-execution-scope");
      if (!header || header.length > 4096) return c.body(null, 403);
      const scope = JSON.parse(Buffer.from(header, "base64url").toString("utf8"));
      if (scope.spaceId !== spaceId) return c.body(null, 403);
      const action = c.req.param("action");
      if (
        (action === "describe" && c.req.method !== "GET") ||
        (action !== "describe" && c.req.method !== "POST")
      )
        return c.body(null, 405);
      let body: unknown;
      if (c.req.method === "POST") {
        const chunks: Uint8Array[] = [];
        let size = 0;
        if (!c.req.raw.body) return c.body(null, 400);
        for await (const chunk of c.req.raw.body) {
          size += chunk.length;
          if (size > 2 * 1024 * 1024) return c.body(null, 413);
          chunks.push(chunk);
        }
        body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      }
      runtime ??= load();
      const result = await (await runtime).handle(
        action,
        body,
        scope,
        homeKey,
        c.req.header("x-execution-service-id"),
      );
      return c.json(result);
    } catch {
      return c.json({ error: "Execution request rejected" }, 409);
    }
  });
  return async () => {
    closing = true;
    if (runtime) await (await runtime).close();
  };
}
