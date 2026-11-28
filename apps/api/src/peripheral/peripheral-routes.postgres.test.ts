import { createHash } from "node:crypto";
import {
  configuredModelAccount,
  EncryptedSecretStore,
  ExternalModelAccountError,
  FakeSandboxProvider,
  InMemoryJobQueue,
  InMemoryRealtimeFanout,
} from "@rakazo/adapters";
import type { Auth } from "@rakazo/auth";
import { OPENAI_COMPATIBLE_PROVIDER_ID } from "@rakazo/contracts";
import { callRequestClientNonce } from "@rakazo/core";
import {
  asSystem,
  bootstrapUserSpace,
  createDb,
  createGroupRepos,
  createRepos,
  createThreadEvents,
  createThreadMessageInTransaction,
  runAsTenant,
} from "@rakazo/db";
import { Hono } from "hono";
import type { MockInstance } from "vitest";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { serializeModelAccountSecret } from "../model-account-secret.js";
import { mountPeripheralRoutes } from "./peripheral-routes.js";
import { ensureVoiceBot } from "./voice-bot.js";

const databaseUrl = process.env.VERIFY_DATABASE === "1" ? process.env.DATABASE_URL : undefined;
const userId = "peripheral-fixture-user";
const issuer = "https://identity.example.test";
const subject = "peripheral-fixture-subject";
const accountId = "peripheral-fixture-account";
const bridgeSecret = "fixture-peripheral-bridge-credential";
const apiKey = "fixture-model-key";
const modelId = "fixture-model";
const nextModelId = "fixture-model-next";
const mainModelId = "fixture-model-main";

describe.skipIf(!databaseUrl)("peripheral chat", () => {
  const app = new Hono();
  const secrets = new EncryptedSecretStore("fixture-encryption-key");
  const jobs = new InMemoryJobQueue();
  const connection = configuredModelAccount(
    JSON.stringify({
      provider: "reseller",
      origin: "https://accounts.example.test",
      credential: "fixture-app-key",
      baseUrl: "https://models.example.test/v1",
    }),
  )!;
  let ensure: MockInstance<typeof connection.provider.ensure>;
  let db: ReturnType<typeof createDb>;
  let events: ReturnType<typeof createThreadEvents>;
  let actor: { userId: string; spaceId: string; email: string; isDeploymentOwner: boolean };
  const deviceKey = "a".repeat(64);

  function request(route: string, body: object = {}, auth = bridgeSecret, identity = subject) {
    return app.request(`/api/peripheral/v1/${route}`, {
      method: "POST",
      headers: { authorization: `Bearer ${auth}`, "content-type": "application/json" },
      body: JSON.stringify({ issuer, subject: identity, deviceId: "fixture-device", ...body }),
    });
  }

  function chat(turnId: string, auth = bridgeSecret, identity = subject, chatModel = modelId) {
    return request("chat", { turnId, text: "你好波波", chatModel }, auth, identity);
  }

  async function nextEvent(reader: ReadableStreamDefaultReader<Uint8Array>, event: string) {
    for (;;) {
      const frame = await reader.read();
      if (frame.done) throw new Error(`Stream ended before ${event}`);
      const text = new TextDecoder().decode(frame.value);
      if (text.startsWith(`event: ${event}\n`)) return JSON.parse(text.split("data: ")[1]!);
    }
  }

  beforeEach(() => {
    vi.spyOn(jobs, "enqueue").mockResolvedValue(undefined);
    ensure = vi.spyOn(connection.provider, "ensure").mockResolvedValue({ apiKey });
  });

  beforeAll(async () => {
    db = createDb(databaseUrl!);
    const system = asSystem(db.prisma);
    events = createThreadEvents(db.prisma, new InMemoryRealtimeFanout());
    await system.user.create({
      data: { id: userId, email: "peripheral@fixture.test", name: "Fixture" },
    });
    actor = {
      userId,
      ...(await bootstrapUserSpace(system, { id: userId })),
      email: "peripheral@fixture.test",
      isDeploymentOwner: false,
    };
    const binding = createHash("sha256")
      .update(JSON.stringify([issuer, subject]))
      .digest("hex");
    const idToken = `header.${Buffer.from(JSON.stringify({ iss: issuer, sub: subject })).toString("base64url")}.signature`;
    await system.account.create({
      data: { id: accountId, userId, accountId: binding, providerId: "oidc", idToken },
    });
    const secret = await secrets.put(
      serializeModelAccountSecret(
        { ...connection.model, apiKey, enabledModelIds: [modelId, nextModelId, mainModelId] },
        { accountId, binding },
      ),
      {
        ...actor,
        operationId: "fixture",
        traceId: "fixture",
        signal: new AbortController().signal,
      },
    );
    await system.secret.create({
      data: { id: secret.id, ciphertext: secret.ciphertext, userId, kind: "model" },
    });
    await system.userModelCredential.create({
      data: {
        id: `external-${accountId}`,
        userId,
        provider: OPENAI_COMPATIBLE_PROVIDER_ID,
        label: "Fixture",
        secretId: secret.id,
      },
    });
    await system.userModelRoleChoice.create({
      data: {
        userId,
        role: "main",
        position: 0,
        provider: OPENAI_COMPATIBLE_PROVIDER_ID,
        modelId: mainModelId,
        credentialId: `external-${accountId}`,
      },
    });
    mountPeripheralRoutes(
      app,
      {
        auth: { $context: Promise.resolve({ secretConfig: bridgeSecret }) } as Auth,
        events,
        jobs,
        prisma: db.prisma,
        sandbox: new FakeSandboxProvider(),
        secrets,
        answerTakeover: vi.fn().mockResolvedValue(null),
      },
      {
        bridgeSecret,
        issuer,
        connection,
      },
    );
  });

  afterAll(async () => {
    await jobs.close();
    await db?.pool.end();
  });

  it("checks bridge credentials and linked identity before obtaining a key", async () => {
    expect((await chat("bad-credential", "untrusted")).status).toBe(401);
    expect((await chat("unknown-account", bridgeSecret, "unknown")).status).toBe(403);
    expect(ensure).not.toHaveBeenCalled();
  });

  it("returns quota errors before creating or sending to a bot", async () => {
    ensure.mockRejectedValueOnce(new ExternalModelAccountError("quota_exhausted"));
    const response = await chat("quota-exhausted");
    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({ error: "quota_exhausted" });
    expect(
      await runAsTenant(actor, () => db.prisma.bot.count({ where: { spaceId: actor.spaceId } })),
    ).toBe(0);
  });

  it("requires the device's voice model for the default target", async () => {
    const response = await request("chat", { turnId: "missing-model", text: "你好波波" });
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "invalid_request" });
  });

  it("reuses one voice bot and one send when the same turn is submitted concurrently", async () => {
    const responses = await Promise.all([chat("turn-1"), chat("turn-1")]);
    const readers = responses.map((response) => response.body!.getReader());
    try {
      for (const response of responses) {
        expect(response.status).toBe(200);
        expect(response.headers.get("cache-control")).toBe("no-store");
      }
      const [{ bot, thread, runs, messages }, metadata] = await Promise.all([
        runAsTenant(actor, async () => {
          const bot = await db.prisma.bot.findFirstOrThrow({
            where: { spawnKey: "peripheral:podone" },
          });
          const thread = await db.prisma.thread.findUniqueOrThrow({ where: { botId: bot.id } });
          const runs = await db.prisma.run.findMany({ where: { threadId: thread.id } });
          const messages = await db.prisma.message.findMany({ where: { threadId: thread.id } });
          return { bot, thread, runs, messages };
        }),
        Promise.all(
          readers.map(async (reader) => new TextDecoder().decode((await reader.read()).value)),
        ),
      ]);
      expect(bot).toMatchObject({
        name: "波波",
        modelProvider: OPENAI_COMPATIBLE_PROVIDER_ID,
        modelId,
        thinkingLevel: "off",
        fleetManagement: true,
      });
      expect(runs).toHaveLength(1);
      expect(runs[0]).toMatchObject({ modelPinned: false });
      expect(messages).toHaveLength(1);
      expect(messages[0]?.clientNonce).toBe("pod:turn-1");
      for (const frame of metadata) {
        expect(frame).toContain("event: session_meta");
        expect(frame).toContain(
          JSON.stringify({
            type: "session_meta",
            turnId: "turn-1",
            botId: bot.id,
            threadId: thread.id,
            runId: runs[0]?.id,
            cursor: 0,
            tts: { baseUrl: connection.model.baseUrl, apiKey },
          }),
        );
      }
      const scope = {
        spaceId: actor.spaceId,
        threadId: thread.id,
        botId: bot.id,
        runId: runs[0]!.id,
      };
      await runAsTenant(actor, async () => {
        await events.append({
          ...scope,
          type: "thread.progress",
          payload: { text: "🙂你好", streaming: true },
        });
        await events.append({
          ...scope,
          type: "thread.message.created",
          payload: { role: "bot", blocks: [{ kind: "text", text: "🙂你好！" }] },
        });
        await db.prisma.run.update({ where: { id: scope.runId }, data: { status: "completed" } });
        await events.append({ ...scope, type: "run.completed", payload: {} });
      });
      for (const reader of readers) {
        let rest = "";
        const decoder = new TextDecoder();
        for (;;) {
          const chunk = await reader.read();
          if (chunk.done) break;
          rest += decoder.decode(chunk.value, { stream: true });
        }
        expect(rest).toContain('event: text_delta\ndata: {"text":"🙂你好"}');
        expect(rest).toContain('event: text_delta\ndata: {"text":"！"}');
        expect(rest).toContain("event: done");
        expect(rest).not.toContain(apiKey);
      }
    } finally {
      await Promise.all(readers.map((reader) => reader.cancel()));
    }
  });

  it("respects the voice bot's saved model and backfills when unset", async () => {
    const bot = await runAsTenant(actor, async () => {
      const botId = await ensureVoiceBot(db.prisma, actor);
      return db.prisma.bot.update({
        where: { id: botId },
        data: { modelId: mainModelId, modelProvider: OPENAI_COMPATIBLE_PROVIDER_ID },
      });
    });
    const response = await chat("voice-model-saved", bridgeSecret, subject, nextModelId);
    expect(response.status).toBe(200);
    const reader = response.body!.getReader();
    try {
      const meta = await nextEvent(reader, "session_meta");
      await runAsTenant(actor, async () => {
        const currentBot = await db.prisma.bot.findUniqueOrThrow({ where: { id: bot.id } });
        expect(currentBot).toMatchObject({
          modelProvider: OPENAI_COMPATIBLE_PROVIDER_ID,
          modelId: mainModelId,
        });
        await db.prisma.run.update({ where: { id: meta.runId }, data: { status: "completed" } });
      });
    } finally {
      await reader.cancel();
    }

    await runAsTenant(actor, () =>
      db.prisma.bot.update({
        where: { id: bot.id },
        data: { modelId: null, modelProvider: null },
      }),
    );
    const backfill = await chat("voice-model-backfill", bridgeSecret, subject, nextModelId);
    expect(backfill.status).toBe(200);
    const backfillReader = backfill.body!.getReader();
    try {
      const meta = await nextEvent(backfillReader, "session_meta");
      await runAsTenant(actor, async () => {
        const currentBot = await db.prisma.bot.findUniqueOrThrow({ where: { id: bot.id } });
        expect(currentBot).toMatchObject({
          modelProvider: OPENAI_COMPATIBLE_PROVIDER_ID,
          modelId: nextModelId,
        });
        await db.prisma.run.update({ where: { id: meta.runId }, data: { status: "completed" } });
      });
    } finally {
      await backfillReader.cancel();
    }
  });

  async function botFixture(name: string) {
    return runAsTenant(actor, () =>
      createRepos(db.prisma).createBot(actor, {
        name,
        description: "",
        instructions: "",
        notifyOnFinish: true,
        modelProvider: OPENAI_COMPATIBLE_PROVIDER_ID,
        modelId,
      }),
    );
  }

  it.each([false, true])(
    "answers only the selected pending approval (web fetch: %s)",
    async (web) => {
      const bot = await botFixture("Research");
      const threadId = bot.threadId!;
      const { run, message } = await runAsTenant(actor, () =>
        db.prisma.$transaction(async (tx) => {
          const scope = { spaceId: actor.spaceId, threadId, botId: bot.id, userId };
          const task = await tx.task.create({
            data: { ...scope, prompt: "Review", status: "waiting_input" },
          });
          const run = await tx.run.create({
            data: { ...scope, taskId: task.id, trigger: "user", status: "waiting_input" },
          });
          const effect = await tx.externalEffect.create({
            data: {
              spaceId: actor.spaceId,
              runId: run.id,
              kind: web ? "web_fetch" : "write_file",
              idempotencyKey: `peripheral-test-approval-${web}`,
              status: "intended",
              request: web ? { url: "https://news.example.com/?q=fixture" } : {},
            },
          });
          const message = await createThreadMessageInTransaction(tx, {
            threadId,
            runId: run.id,
            botId: bot.id,
            role: "bot",
            blocks: [
              {
                kind: "ask",
                text: web ? "Allow Web fetch → example.com?" : "Save the draft?",
                status: "pending",
                approvalEffectId: effect.id,
                ...(web
                  ? { site: "example.com", detail: "https://news.example.com/?q=fixture" }
                  : {}),
                actions: [
                  { id: "allow", label: "Allow once" },
                  ...(web ? [{ id: "always", label: "Always allow example.com" }] : []),
                  { id: "deny", label: "Deny" },
                ],
              },
            ],
          });
          return { run, message };
        }),
      );
      const roster = await (await request("fleet")).json();
      expect(roster.cards).toContainEqual(
        expect.objectContaining({
          kind: "approval",
          threadId,
          runId: run.id,
          messageId: message.id,
          text: web ? "想访问 example.com 上的网页" : "想写入文件",
          ...(web ? { offersSiteApproval: true } : {}),
        }),
      );
      const ref = { threadId, runId: run.id, messageId: message.id };
      const input = { ...ref, action: web ? "always_allow_site" : "approve" };
      expect((await request("decisions", { ...input, messageId: "wrong-card" })).status).toBe(409);
      if (!web) {
        expect((await request("decisions", { ...ref, action: "always_allow_site" })).status).toBe(
          409,
        );
      }
      expect(await (await request("decisions", input)).json()).toEqual({ ok: true });
      expect((await request("decisions", input)).status).toBe(409);
      expect(
        await runAsTenant(actor, () => db.prisma.run.findUnique({ where: { id: run.id } })),
      ).toMatchObject({ status: "queued" });
      if (web) {
        expect(
          await runAsTenant(actor, () =>
            db.prisma.userActionApprovalRule.findFirst({
              where: {
                userId,
                effect: "always_allow",
                matchKind: "site",
                matchValue: "example.com",
              },
            }),
          ),
        ).not.toBeNull();
      }
    },
  );

  it("dispatches one group turn and sends its delayed result to its source device", async () => {
    const [first, second] = await Promise.all([botFixture("A"), botFixture("B")]);
    const group = await runAsTenant(actor, () =>
      createGroupRepos(db.prisma).createGroup(actor, {
        name: "Operations",
        botIds: [first.id, second.id],
      }),
    );
    const response = await request("chat", {
      targetGroupId: group.id,
      deviceKey,
      turnId: "group-1",
      text: "Summarize.",
    });
    expect(response.status).toBe(200);
    const replay = await request("chat", {
      targetGroupId: group.id,
      deviceKey,
      turnId: "group-1",
      text: "Summarize.",
    });
    expect(replay.status).toBe(200);
    expect(await replay.text()).toContain('"status":"queued"');

    const chatReader = response.body!.getReader();
    const meta = await nextEvent(chatReader, "session_meta");
    expect(await nextEvent(chatReader, "done")).toEqual({ status: "queued" });
    await chatReader.cancel();
    const stream = await request("events", {
      deviceKey,
      targetGroupIds: [group.id],
      cursors: { [meta.threadId]: meta.cursor },
    });
    const reader = stream.body!.getReader();
    try {
      expect(await nextEvent(reader, "ready")).toMatchObject({
        cursors: { [meta.threadId]: meta.cursor },
      });
      await runAsTenant(actor, async () => {
        const runs = await db.prisma.run.findMany({ where: { threadId: meta.threadId } });
        expect(runs).toHaveLength(2);
        const run = runs.find(({ id }) => id === meta.runId)!;
        await db.prisma.$transaction(async (tx) => {
          await createThreadMessageInTransaction(tx, {
            threadId: run.threadId,
            runId: run.id,
            botId: run.botId,
            role: "bot",
            blocks: [{ kind: "text", text: "Group complete" }],
          });
          await tx.run.update({ where: { id: run.id }, data: { status: "completed" } });
        });
        await events.append({
          spaceId: actor.spaceId,
          threadId: run.threadId,
          runId: run.id,
          botId: run.botId,
          type: "run.completed",
          payload: {},
        });
      });
      expect(await nextEvent(reader, "result")).toMatchObject({
        id: meta.runId,
        text: expect.stringContaining("Group complete"),
      });
    } finally {
      await reader.cancel();
    }
  });

  it("delivers a ringing call and settles it only once", async () => {
    const bot = await botFixture("Caller");
    const incoming = {
      kind: "call_request" as const,
      callId: "fixture-call",
      reason: "A result is ready",
      opening: "I have the result.",
      status: "ringing" as const,
      expiresAt: new Date(Date.now() + 60_000).toISOString(),
    };
    await runAsTenant(actor, () =>
      db.prisma.$transaction((tx) =>
        createThreadMessageInTransaction(tx, {
          threadId: bot.threadId!,
          botId: bot.id,
          role: "bot",
          clientNonce: callRequestClientNonce(incoming.callId),
          blocks: [incoming],
        }),
      ),
    );
    const response = await request("events", { deviceKey });
    const reader = response.body!.getReader();
    try {
      expect(await nextEvent(reader, "calls")).toMatchObject({
        calls: [{ botId: bot.id, callId: incoming.callId, reason: incoming.reason }],
      });
      const input = { action: "accept_call", callId: incoming.callId, botId: bot.id };
      expect(await (await request("decisions", input)).json()).toEqual({
        ok: true,
        opening: "I have the result.",
      });
      expect((await request("decisions", input)).status).toBe(409);
    } finally {
      await reader.cancel();
    }
  });

  it("routes delegated Bot results back to the device that sent the request", async () => {
    const sent = await request("chat", {
      deviceKey,
      turnId: "delegate",
      text: "Delegate a task.",
      chatModel: modelId,
    });
    const chat = sent.body!.getReader();
    const meta = await nextEvent(chat, "session_meta");
    await chat.cancel();

    const streams = await Promise.all(
      [deviceKey, "b".repeat(64)].map((key) =>
        request("events", { deviceKey: key, cursors: { [meta.threadId]: meta.cursor } }),
      ),
    );
    const [matching, other] = streams.map((response) => response.body!.getReader());
    try {
      await Promise.all([nextEvent(matching!, "ready"), nextEvent(other!, "ready")]);
      const inbound = await runAsTenant(actor, async () => {
        const outbound = await db.prisma.$transaction((tx) =>
          createThreadMessageInTransaction(tx, {
            threadId: meta.threadId,
            botId: meta.botId,
            runId: meta.runId,
            role: "bot",
            blocks: [
              {
                kind: "bot_message_sent",
                toBotId: meta.botId,
                toBotName: "Fixture",
                text: "Delegate a task.",
                intent: "request",
              },
            ],
          }),
        );
        const reply = await db.prisma.$transaction(async (tx) => {
          const ref = {
            threadId: meta.threadId,
            botId: meta.botId,
            spaceId: actor.spaceId,
            userId,
          };
          const task = await tx.task.create({
            data: { ...ref, status: "queued", prompt: "Result" },
          });
          const run = await tx.run.create({
            data: { ...ref, taskId: task.id, status: "queued", trigger: "bot_message" },
          });
          const message = await createThreadMessageInTransaction(tx, {
            threadId: meta.threadId,
            runId: run.id,
            role: "user",
            replyToMessageId: outbound.id,
            blocks: [
              {
                kind: "bot_message_received",
                fromBotId: meta.botId,
                fromBotName: "Research",
                text: "Result for the original Pod",
                intent: "result",
              },
            ],
          });
          return { message, run };
        });
        const event = await events.append({
          threadId: meta.threadId,
          spaceId: actor.spaceId,
          botId: meta.botId,
          runId: reply.run.id,
          type: "thread.message.created",
          payload: { role: "user", messageId: reply.message.id },
        });
        return { id: reply.message.id, seq: event.seq };
      });
      expect(await nextEvent(matching!, "result")).toMatchObject({
        id: inbound.id,
        text: expect.stringContaining("Result for the original Pod"),
      });
      expect(await nextEvent(other!, "cursor")).toMatchObject({ cursor: inbound.seq });
    } finally {
      await Promise.all([matching!.cancel(), other!.cancel()]);
    }
  });

  it("streams only the owner's routine completion as a notification", async () => {
    const bot = await botFixture("Digest");
    const scope = { spaceId: actor.spaceId, userId, threadId: bot.threadId!, botId: bot.id };
    const run = await runAsTenant(actor, () =>
      db.prisma.$transaction(async (tx) => {
        const task = await tx.task.create({
          data: { ...scope, prompt: "Daily", status: "completed" },
        });
        return tx.run.create({
          data: { ...scope, taskId: task.id, trigger: "routine", status: "completed" },
        });
      }),
    );
    const stream = await request("events", { deviceKey });
    const reader = stream.body!.getReader();
    try {
      await nextEvent(reader, "calls");
      await events.publishChatAlert?.(userId, {
        ...scope,
        kind: "completion",
        runId: run.id,
        title: "Digest finished",
        body: "Summary ready",
      });
      expect(await nextEvent(reader, "notification")).toMatchObject({
        id: run.id,
        text: expect.stringContaining("Summary ready"),
      });
    } finally {
      await reader.cancel();
    }
  });
});
