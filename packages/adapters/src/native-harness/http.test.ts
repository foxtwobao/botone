import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, expect, it } from "vitest";
import { HttpNativeExecutionProvider } from "./http-client.js";
import { startNativeExecutionServer } from "./http-server.js";
import { FakeHarnessProcess, scope, startRequest, tick } from "./protocol.test-support.js";
import { NativeHarnessExecutionService } from "./service.js";

const cleanup: Array<() => void | Promise<void>> = [];
afterEach(async () => {
  for (const fn of cleanup.splice(0).reverse()) await fn();
});

it("authenticates the service, binds its installation identity, and keeps work after a client detaches", async () => {
  const root = mkdtempSync(path.join(tmpdir(), "native-http-test-"));
  cleanup.push(() => rmSync(root, { recursive: true, force: true }));
  const service = new NativeHarnessExecutionService(root, [
    {
      id: scope.profileId,
      revision: 1,
      spaceId: scope.spaceId,
      userIds: [scope.userId],
      computerId: scope.computerId,
      engineVersion: "test",
      launch: async () => new FakeHarnessProcess(),
      driver: (_process, _version, emit) => ({
        capabilities: {
          images: false,
          resume: false,
          steer: false,
          permissions: false,
          questions: false,
          tools: false,
        },
        async start() {
          emit({ type: "text", text: "hello" });
        },
        async cancel() {},
        async respond() {
          return false;
        },
        async steer() {
          return false;
        },
      }),
    },
  ]);
  cleanup.push(() => service.close());
  const token = "a".repeat(64);
  const server = await startNativeExecutionServer({ root, token, provider: service, profiles: [] });
  cleanup.push(() => server.close());
  const url = `http://127.0.0.1:${server.port}/`;
  const unauthorized = await fetch(`${url}describe`);
  expect(unauthorized.status).toBe(401);
  const browser = await fetch(`${url}describe`, {
    headers: { authorization: `Bearer ${token}`, origin: "https://example.test" },
  });
  expect(browser.status).toBe(401);
  const client = new HttpNativeExecutionProvider({ url, token, allowPrivateEndpoint: true });
  expect((await client.describe()).id).toBe(server.identity);
  await expect(client.start(startRequest())).rejects.toThrow("execution_service_rejected");
  const connected = new HttpNativeExecutionProvider({
    url,
    token,
    identity: server.identity,
    allowPrivateEndpoint: true,
  });
  const started = await connected.start(startRequest());
  await tick();
  const reconnected = new HttpNativeExecutionProvider({
    url,
    token,
    identity: server.identity,
    allowPrivateEndpoint: true,
  });
  const attached = await reconnected.attach({
    runId: "run-a",
    scope,
    generation: started.generation,
    fence: 2,
    after: 0,
    leaseExpiresAt: new Date(Date.now() + 60_000).toISOString(),
  });
  expect(attached.frames).toEqual([{ sequence: 1, event: { type: "text", text: "hello" } }]);
  await expect(
    connected.respond({
      runId: "run-a",
      scope,
      generation: started.generation,
      fence: 1,
      requestId: "old",
      answer: "allow",
    }),
  ).rejects.toThrow("execution_service_rejected");
  service.replaceComputerProfiles(scope.computerId, []);
  await expect(connected.start({ ...startRequest(), runId: "revoked-dispatch" })).rejects.toThrow(
    "execution_service_rejected",
  );
  await connected.stop({ runId: "run-a", scope, fence: 3 });
  const stopped = await reconnected.attach({
    runId: "run-a",
    scope,
    generation: started.generation,
    fence: 3,
    after: 1,
    leaseExpiresAt: new Date(Date.now() + 60_000).toISOString(),
  });
  expect(stopped.frames.at(-1)?.event.type).toBe("cancelled");
});
