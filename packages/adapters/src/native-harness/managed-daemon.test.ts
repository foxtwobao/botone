import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, it, vi } from "vitest";
import { launchComputerHarness } from "./computer-process.js";
import { startExecutionDaemon } from "./daemon.js";
import { HttpNativeExecutionProvider } from "./http-client.js";
import { inspectComputerHarness, verifyComputerIsolation } from "./inspection.js";
import { FakeHarnessProcess, tick } from "./protocol.test-support.js";
import { verificationChecks } from "./verification.js";

vi.mock("./inspection.js", () => ({
  inspectComputerHarness: vi.fn(),
  verifyComputerIsolation: vi.fn(),
}));
vi.mock("./computer-process.js", () => ({ launchComputerHarness: vi.fn() }));
vi.mock("./catalog.js", () => ({
  nativeHarnessDriver:
    async () => (_process: unknown, _version: string, emit: (event: object) => void) => ({
      capabilities: {
        images: false,
        resume: false,
        steer: false,
        permissions: false,
        questions: false,
        tools: false,
      },
      async start() {
        emit({ type: "text", text: "Native reply" });
      },
      async cancel() {},
      async respond() {
        return false;
      },
      async steer() {
        return false;
      },
    }),
}));

it("refreshes managed admissions without restarting or losing control of an existing process", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "managed-daemon-"));
  const owner = {
    spaceId: "fixture-space",
    userId: "fixture-user",
    computerId: "fixture-computer",
  };
  let generation = "2026-01-01T00:00:00.000Z",
    status = 200;
  const api = createServer(async (request, response) => {
    if (status !== 200) {
      response.writeHead(status).end();
      return;
    }
    if (request.url === "/api/model-account/environment")
      response.end(
        JSON.stringify({
          ...owner,
          homeKey: "fixture-home",
          state: "running",
          credentialId: "fixture-credential",
          credentialCreatedAt: generation,
          connectionRevision: "c".repeat(64),
          defaults: { responses: "fixture-model" },
          models: ["fixture-model"],
          initialization: { url: `${apiUrl}/computer`, token: "fake-computer-grant" },
        }),
      );
    else response.end(JSON.stringify({ modelIds: ["fixture-model"] }));
  });
  await new Promise<void>((resolve) => api.listen(0, "127.0.0.1", resolve));
  const address = api.address();
  if (!address || typeof address === "string") throw new Error("test_server");
  const apiUrl = `http://127.0.0.1:${address.port}`;
  const reservation = createServer();
  await new Promise<void>((resolve) => reservation.listen(0, "127.0.0.1", resolve));
  const reserved = reservation.address();
  if (!reserved || typeof reserved === "string") throw new Error("test_server");
  await new Promise<void>((resolve) => reservation.close(() => resolve()));
  const file = path.join(root, "configuration.json");
  await writeFile(
    file,
    JSON.stringify({
      root,
      port: reserved.port,
      token: "a".repeat(64),
      managed: { apiUrl, runtimeRevision: "b".repeat(40) },
    }),
    { mode: 0o600 },
  );
  vi.mocked(inspectComputerHarness).mockResolvedValue({ code: 0, output: "0.167.0" });
  vi.mocked(verifyComputerIsolation).mockResolvedValue();
  const process = new FakeHarnessProcess();
  vi.mocked(launchComputerHarness).mockResolvedValue(process);
  const daemon = await startExecutionDaemon(file);
  const client = new HttpNativeExecutionProvider({
    url: `http://127.0.0.1:${daemon.port}`,
    token: "a".repeat(64),
    identity: daemon.identity,
    allowPrivateEndpoint: true,
    scope: owner,
  });
  try {
    const initial = await client.describe();
    expect(initial.profiles.map((profile) => profile.label)).toEqual([
      "Codex",
      "Claude Code",
      "DSH",
    ]);
    expect(initial.profiles.map((profile) => profile.status)).toEqual([
      "unverified",
      "unavailable",
      "unavailable",
    ]);
    expect(launchComputerHarness).not.toHaveBeenCalled();
    await writeFile(
      path.join(root, "runtime-codex.json"),
      JSON.stringify({
        managed: true,
        runtimeRevision: "b".repeat(40),
        version: "0.167.0",
        checks: verificationChecks,
      }),
      { mode: 0o600 },
    );
    const ready = (await client.describe()).profiles[0]!;
    expect(ready.status).toBe("ready");
    expect(verifyComputerIsolation).toHaveBeenCalledOnce();
    const request = {
      runId: "fixture-run",
      scope: {
        ...owner,
        botId: "fixture-bot",
        threadId: "fixture-thread",
        profileId: ready.id,
        revision: ready.revision,
      },
      fence: 1,
      prompt: "fixture prompt",
      instructions: "",
      leaseExpiresAt: new Date(Date.now() + 60000).toISOString(),
    };
    const started = await client.start(request);
    await tick();
    expect(launchComputerHarness).toHaveBeenCalledOnce();
    generation = "2026-01-02T00:00:00.000Z";
    expect((await client.describe()).profiles[0]!.id).not.toBe(ready.id);
    await expect(client.start({ ...request, runId: "obsolete-session" })).rejects.toThrow(
      "execution_service_rejected",
    );
    const attached = await client.attach({
      runId: request.runId,
      scope: request.scope,
      fence: request.fence,
      leaseExpiresAt: request.leaseExpiresAt,
      generation: started.generation,
      after: 0,
    });
    expect(attached.frames.some((frame) => frame.event.type === "text")).toBe(true);
    await client.stop({ runId: request.runId, scope: request.scope, fence: 2 });
    expect(process.stopped).toBe(true);
    vi.mocked(verifyComputerIsolation).mockRejectedValue(new Error("isolation_failed"));
    expect((await client.describe()).profiles[0]!.status).toBe("unverified");
    vi.mocked(inspectComputerHarness).mockResolvedValue({ code: 0, output: "different-version" });
    expect((await client.describe()).profiles[0]!.status).toBe("unsupported");
    status = 401;
    expect(
      (await client.describe()).profiles.every((profile) => profile.status === "unauthenticated"),
    ).toBe(true);
    status = 503;
    await expect(client.describe()).rejects.toThrow("execution_service_rejected");
    expect(launchComputerHarness).toHaveBeenCalledOnce();
  } finally {
    await daemon.close();
    await new Promise<void>((resolve) => api.close(() => resolve()));
    await rm(root, { recursive: true, force: true });
  }
});
