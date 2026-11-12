import { randomUUID } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import type {
  ComputerExecutionCapability,
  NativeExecutionEvent,
  NativeExecutionStart,
} from "@rakazo/adapter-kit";
import { createAdapterContext } from "@rakazo/adapter-kit";
import type { createApp } from "@rakazo/api/app";
import { runAsSystem, runAsTenant } from "@rakazo/db";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { FakeHarnessProcess } from "../../native-runtime/src/protocol.test-support.js";
import { NativeHarnessExecutionService } from "../../native-runtime/src/service.js";
import { discardBotIntroFromCreate } from "./discard-bot-intro.js";
import { asSystem } from "./system-db.js";

const integration = process.env.VERIFY_DATABASE === "1" ? describe : describe.skip;
integration("native execution with real authorization, history and leases", () => {
  let app: Awaited<ReturnType<typeof createApp>>;
  let db: Awaited<ReturnType<typeof createApp>>["prisma"];
  let service: NativeHarnessExecutionService;
  let cookie: string;
  let actor: { spaceId: string; userId: string };
  let botId: string;
  let connectionId: string;
  let threadId: string;
  let nativeStarts = 0;
  let nativeAnswers = 0;
  let cancellations = 0;
  let cancelBarrier: Promise<void> | undefined;
  const requests: NativeExecutionStart[] = [];
  const emitters = new Map<string, (event: NativeExecutionEvent) => void>();
  const root = mkdtempSync(path.join(tmpdir(), "native-product-test-"));
  const email = "execution-owner@rakazo.test";

  beforeAll(async () => {
    const { createApp } = await import("@rakazo/api/app");
    app = await createApp({
      databaseUrl: process.env.DATABASE_URL!,
      dataDir: path.join(root, "app"),
      sandboxProvider: "fake",
      agentRuntime: "scripted",
      wakeupDriver: "memory",
      deploymentModelConfigured: false,
      adminEmails: [email],
    });
    db = asSystem(app.prisma);
    const response = await app.app.request("/api/auth/sign-up/email", {
      method: "POST",
      headers: { "content-type": "application/json", origin: "http://127.0.0.1:5173" },
      body: JSON.stringify({ email, password: "test-password-12", name: "Execution owner" }),
    });
    expect(response.status).toBeLessThan(400);
    cookie = `better-auth.session_token=${response.headers.get("set-cookie")!.match(/better-auth\.session_token=([^;]+)/)![1]}`;
    const me = await rpc<{ spaceId: string; userId: string }>("me");
    actor = { spaceId: me.spaceId, userId: me.userId };
    await db.user.update({ where: { id: actor.userId }, data: { emailVerified: true } });
    const bot = await rpc<{ id: string }>("bots/create", {
      name: "Native bot",
      title: "",
      description: "",
      instructions: "Private instructions",
      notifyOnFinish: false,
    });
    botId = bot.id;
    const row = await db.bot.findUniqueOrThrow({ where: { id: botId } });
    threadId = (await db.thread.findUniqueOrThrow({ where: { botId } })).id;
    const profile = {
      id: "native-test",
      revision: 1,
      ...actor,
      userIds: [actor.userId],
      computerId: row.computerId!,
      label: "Test execution",
      engineVersion: "test",
      defaultModel: "model-a",
      models: [
        { id: "model-a", label: "Model A" },
        { id: "model-b", label: "Model B" },
      ],
      status: "ready" as const,
    };
    service = new NativeHarnessExecutionService(path.join(root, "service"), [
      {
        ...profile,
        launch: async () => new FakeHarnessProcess(),
        driver: (_process, _version, emit) => ({
          capabilities: {
            resume: true,
            steer: false,
            images: false,
            permissions: true,
            questions: true,
            tools: false,
          },
          async start(request) {
            nativeStarts++;
            requests.push(request);
            emitters.set(request.runId, emit);
            emit({
              type: "session",
              session: { id: request.session?.id ?? randomUUID(), engineVersion: "test" },
            });
            emit({ type: "text", text: "Native reply" });
            emit({
              type: "interaction",
              request: {
                id: `ask-${request.runId}`,
                kind: "permission",
                title: "Write file?",
                actions: [
                  { id: "allow", label: "Allow once" },
                  { id: "deny", label: "Deny" },
                ],
              },
            });
          },
          async respond(id, answer) {
            nativeAnswers++;
            const runId = id.slice(4);
            emit({ type: "interaction_closed", id, status: "delivered" });
            emit({
              type: "file",
              name: "result.txt",
              content: Buffer.from("Native result").toString("base64"),
            });
            emit({ type: "completed" });
            expect(answer).toBe("deny");
            return emitters.has(runId);
          },
          async cancel() {
            cancellations++;
            await cancelBarrier;
          },
          async steer() {
            return false;
          },
        }),
      },
    ]);
    const computer = await db.computer.findUniqueOrThrow({ where: { id: row.computerId! } });
    const reference = await app.sandbox.provision(
      { botId: computer.homeKey, homePath: path.join(root, "computer") },
      createAdapterContext(actor, botId, "native-fixture"),
    );
    await db.computer.update({
      where: { id: row.computerId! },
      data: {
        kind: "docker",
        providerRef: reference.providerRef,
        state: "running",
        userId: actor.userId,
      },
    });
    app.sandbox.isRunning = async () => true;
    const identity = randomUUID();
    Object.assign(app.sandbox, {
      execution: async () => ({
        describe: async () => ({ id: identity, profiles: [profile] }),
        start: (request) => service.start(request),
        attach: (request) => service.attach(request),
        stop: (request) => service.stop(request),
        cancel: (request) => service.cancel(request),
        respond: (request) => service.respond(request),
        steer: (request) => service.steer(request),
        toolResult: (request) => service.toolResult(request),
      }),
    } satisfies ComputerExecutionCapability);
    const listing = await rpc<Array<{ id: string }>>("executions/list", { botId });
    connectionId = listing[0]!.id;
    await rpc("executions/configure", {
      botId,
      configuration: { connectionId, profileId: profile.id, revision: 1, model: null },
    });
    vi.spyOn(app.runtime, "run").mockImplementation(() => {
      throw new Error("The built-in runtime must not run");
    });
  });
  afterAll(async () => {
    await service?.close();
    await app?.stop();
    rmSync(root, { recursive: true, force: true });
  });

  async function rpc<T = unknown>(procedure: string, input: unknown = {}): Promise<T> {
    const response = await app.app.request(`/rpc/${procedure}`, {
      method: "POST",
      headers: { "content-type": "application/json", origin: "http://127.0.0.1:5173", cookie },
      body: JSON.stringify({ json: input }),
    });
    const body = (await response.json()) as { json: T };
    expect(response.status, JSON.stringify(body)).toBe(200);
    return discardBotIntroFromCreate(app, cookie, procedure, body.json);
  }
  async function run(inThread = threadId) {
    const task = await db.task.create({
      data: { ...actor, botId, threadId: inThread, prompt: "Native task", status: "queued" },
    });
    return db.run.create({
      data: {
        ...actor,
        botId,
        threadId: inThread,
        taskId: task.id,
        status: "queued",
        trigger: "user",
      },
    });
  }
  async function pending(runId: string) {
    await vi.waitFor(
      async () => {
        const interaction = await db.nativeInteraction.findFirst({
          where: { runId, status: "pending" },
        });
        expect(interaction).toBeTruthy();
      },
      { timeout: 15_000 },
    );
    return await db.nativeInteraction.findFirstOrThrow({ where: { runId } });
  }
  const execute = (id: string, worker: string) =>
    runAsSystem("native execution test worker", () => app.executor.continueRun(id, worker));

  it("bypasses the built-in model, persists submission then delivery, and hides another account's configuration", async () => {
    const current = await run();
    const work = execute(current.id, "first-worker");
    const interaction = await pending(current.id);
    expect((await db.run.findUniqueOrThrow({ where: { id: current.id } })).status).toBe("running");
    expect(
      await runAsTenant({ ...actor, userId: "another-user" }, () =>
        app.prisma.executionConnection.findMany(),
      ),
    ).toEqual([]);
    const invalid = await app.app.request("/rpc/threads/answer", {
      method: "POST",
      headers: { "content-type": "application/json", origin: "http://127.0.0.1:5173", cookie },
      body: JSON.stringify({
        json: {
          botId,
          runId: current.id,
          messageId: interaction.messageId,
          answer: "always",
          clientNonce: randomUUID(),
        },
      }),
    });
    expect(invalid.status).toBe(409);
    expect(
      (await db.nativeInteraction.findUniqueOrThrow({ where: { id: interaction.id } })).status,
    ).toBe("pending");
    await rpc("threads/answer", {
      botId,
      runId: current.id,
      messageId: interaction.messageId,
      answer: "deny",
      clientNonce: randomUUID(),
    });
    await work;
    expect((await db.run.findUniqueOrThrow({ where: { id: current.id } })).status).toBe(
      "completed",
    );
    expect(
      (await db.nativeInteraction.findUniqueOrThrow({ where: { id: interaction.id } })).status,
    ).toBe("delivered");
    expect(nativeAnswers).toBe(1);
    expect(app.runtime.run).not.toHaveBeenCalled();
    const messages = await db.message.findMany({ where: { runId: current.id } });
    expect(messages.some((m) => JSON.stringify(m.blocks).includes("Native reply"))).toBe(true);
    const artifact = await db.artifact.findFirstOrThrow({ where: { runId: current.id } });
    expect(artifact.userId).toBe(actor.userId);
    expect(messages.some((m) => JSON.stringify(m.blocks).includes(artifact.id))).toBe(true);
  });

  it("takes over a live approval with a new fence and preserves the original native session", async () => {
    const current = await run();
    const first = execute(current.id, "old-worker");
    const interaction = await pending(current.id);
    const starts = nativeStarts;
    await db.run.update({ where: { id: current.id }, data: { leaseExpiresAt: new Date(0) } });
    const second = execute(current.id, "replacement-worker");
    await vi.waitFor(async () =>
      expect((await db.run.findUniqueOrThrow({ where: { id: current.id } })).leaseFence).toBe(2),
    );
    await rpc("threads/answer", {
      botId,
      runId: current.id,
      messageId: interaction.messageId,
      answer: "deny",
      clientNonce: randomUUID(),
    });
    await Promise.all([first, second]);
    expect(nativeStarts).toBe(starts);
    expect(requests.at(-1)?.session?.id).toBe(
      requests[0] &&
        (await db.nativeExecution.findUniqueOrThrow({ where: { runId: requests[0].runId } }))
          .sessionId,
    );
    expect((await db.run.findUniqueOrThrow({ where: { id: current.id } })).status).toBe(
      "completed",
    );
  });

  it("switches a new bot past its welcome question only after confirmation", async () => {
    await rpc("executions/configure", { botId, configuration: null });
    const welcome = await run();
    await db.run.update({
      where: { id: welcome.id },
      data: { trigger: "created", status: "waiting_input" },
    });
    const configuration = { connectionId, profileId: "native-test", revision: 1, model: "model-b" };
    const request = (configuration: unknown, stopActiveRuns = false) =>
      app.app.request("/rpc/executions/configure", {
        method: "POST",
        headers: { "content-type": "application/json", origin: "http://127.0.0.1:5173", cookie },
        body: JSON.stringify({ json: { botId, configuration, stopActiveRuns } }),
      });
    expect((await request(configuration)).status).toBe(409);
    expect((await request({ ...configuration, profileId: "unavailable" }, true)).status).toBe(403);
    expect((await db.run.findUniqueOrThrow({ where: { id: welcome.id } })).status).toBe(
      "waiting_input",
    );
    expect(await rpc("executions/get", { botId })).toBe(null);
    await rpc("executions/configure", { botId, configuration, stopActiveRuns: true });
    expect((await db.run.findUniqueOrThrow({ where: { id: welcome.id } })).status).toBe(
      "cancelled",
    );
    expect(await rpc("executions/get", { botId })).toEqual(configuration);
    const connections = await rpc<Array<{ profiles: Array<{ models: unknown }> }>>(
      "executions/list",
      { botId },
    );
    expect(connections[0]?.profiles[0]?.models).toEqual([
      { id: "model-a", label: "Model A" },
      { id: "model-b", label: "Model B" },
    ]);
    const selected = await run();
    const work = execute(selected.id, "selected-model-worker");
    const interaction = await pending(selected.id);
    expect(requests.at(-1)?.model).toBe("model-b");
    await rpc("threads/answer", {
      botId,
      runId: selected.id,
      messageId: interaction.messageId,
      answer: "deny",
      clientNonce: randomUUID(),
    });
    await work;
  });

  it("requires confirmation for every active lifecycle state and leaves other bots running", async () => {
    const other = await rpc<{ id: string }>("bots/create", {
      name: "Other bot",
      title: "",
      description: "",
      instructions: "",
      notifyOnFinish: false,
    });
    const group = await rpc<{ id: string }>("groups/create", {
      name: "Shared work",
      botIds: [botId, other.id],
    });
    const sharedThread = await db.thread.findUniqueOrThrow({ where: { groupId: group.id } });
    const current = await run(sharedThread.id);
    const otherTask = await db.task.create({
      data: {
        ...actor,
        botId: other.id,
        threadId: sharedThread.id,
        prompt: "Other work",
        status: "queued",
      },
    });
    const otherRun = await db.run.create({
      data: {
        ...actor,
        botId: other.id,
        threadId: sharedThread.id,
        taskId: otherTask.id,
        status: "waiting_input",
        trigger: "user",
      },
    });
    for (const status of ["queued", "leased", "running", "waiting_input", "waiting_takeover"]) {
      await db.run.update({ where: { id: current.id }, data: { status } });
      const response = await app.app.request("/rpc/executions/configure", {
        method: "POST",
        headers: { "content-type": "application/json", origin: "http://127.0.0.1:5173", cookie },
        body: JSON.stringify({ json: { botId, configuration: null } }),
      });
      expect(response.status).toBe(409);
    }
    await rpc("executions/configure", { botId, configuration: null, stopActiveRuns: true });
    expect((await db.run.findUniqueOrThrow({ where: { id: current.id } })).status).toBe(
      "cancelled",
    );
    expect((await db.run.findUniqueOrThrow({ where: { id: otherRun.id } })).status).toBe(
      "waiting_input",
    );
    await db.run.update({ where: { id: otherRun.id }, data: { status: "cancelled" } });
    await rpc("executions/configure", {
      botId,
      configuration: { connectionId, profileId: "native-test", revision: 1, model: null },
    });
  });

  it.each(["threads/stop", "executions/configure"] as const)(
    "%s waits for execution-side stop before announcing cancellation",
    async (route) => {
      const current = await run();
      const work = execute(current.id, "stop-worker");
      const interaction = await pending(current.id);
      const answers = nativeAnswers;
      let release!: () => void;
      cancelBarrier = new Promise<void>((resolve) => {
        release = resolve;
      });
      const previousCancellations = cancellations;
      const switching = rpc(
        route,
        route === "threads/stop"
          ? { botId }
          : {
              botId,
              configuration: null,
              stopActiveRuns: true,
            },
      );
      try {
        await vi.waitFor(() => expect(cancellations).toBeGreaterThan(previousCancellations));
        expect(await db.botExecution.findUnique({ where: { botId } })).not.toBe(null);
        expect((await db.run.findUniqueOrThrow({ where: { id: current.id } })).status).toBe(
          "running",
        );
      } finally {
        release();
        cancelBarrier = undefined;
      }
      await switching;
      await work;
      if (route === "executions/configure")
        expect(await rpc("executions/get", { botId })).toBe(null);
      else expect(await rpc("executions/get", { botId })).not.toBe(null);
      expect((await db.run.findUniqueOrThrow({ where: { id: current.id } })).status).toBe(
        "cancelled",
      );
      expect(
        (await db.nativeInteraction.findUniqueOrThrow({ where: { id: interaction.id } })).status,
      ).toBe("expired");
      expect(nativeAnswers).toBe(answers);
      await rpc("executions/configure", {
        botId,
        configuration: { connectionId, profileId: "native-test", revision: 1, model: null },
      });
    },
  );

  it.each(["threads/stop", "executions/configure"] as const)(
    "%s retains configuration and work when execution-side stop fails",
    async (route) => {
      const current = await run();
      const work = execute(current.id, "failed-stop-worker");
      const interaction = await pending(current.id);
      vi.spyOn(service, "stop").mockRejectedValueOnce(new Error("test stop unavailable"));
      const response = await app.app.request(`/rpc/${route}`, {
        method: "POST",
        headers: { "content-type": "application/json", origin: "http://127.0.0.1:5173", cookie },
        body: JSON.stringify({
          json:
            route === "threads/stop"
              ? { botId }
              : { botId, configuration: null, stopActiveRuns: true },
        }),
      });
      expect(response.status).toBe(500);
      expect(await db.botExecution.findUnique({ where: { botId } })).not.toBe(null);
      expect((await db.run.findUniqueOrThrow({ where: { id: current.id } })).status).toBe(
        "running",
      );
      expect(
        (await db.nativeInteraction.findUniqueOrThrow({ where: { id: interaction.id } })).status,
      ).toBe("pending");
      await rpc("threads/stop", { botId });
      await work;
    },
  );

  it("confirms process stop after revocation and expires pending interactions", async () => {
    const current = await run();
    const work = execute(current.id, "revocation-worker");
    const interaction = await pending(current.id);
    await rpc("executions/revoke", { id: connectionId });
    await work;
    expect((await db.run.findUniqueOrThrow({ where: { id: current.id } })).status).toBe("failed");
    expect(
      (await db.nativeInteraction.findUniqueOrThrow({ where: { id: interaction.id } })).status,
    ).toBe("expired");
  });
});
