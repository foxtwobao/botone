import type { configuredModelAccount } from "@rakazo/adapters";
import { ExternalModelAccountError } from "@rakazo/adapters";
import { THREAD_MESSAGE_TEXT_MAX_LENGTH } from "@rakazo/contracts";
import { ClientError, deadlineSignal } from "@rakazo/core";
import { hasValidBearerToken } from "@rakazo/core/node/secrets-guard";
import { IsolationError, runAsTenant } from "@rakazo/db";
import { getLogger } from "@rakazo/logging";
import type { Context } from "hono";
import { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import { streamSSE } from "hono/streaming";
import * as z from "zod";
import { assertTeachingSendAllowed } from "../bots/taught-skills.js";
import type { SpeechSummarizer } from "../calls/speech-summary.js";
import type { RouterDeps } from "../router.js";
import { HEARTBEAT, withHeartbeats } from "../routes/shared.js";
import {
  resolveThreadTarget,
  sendTargetBotIds,
  sendThreadMessage,
} from "../threads/thread-target.js";
import { resolvePeripheralActor } from "./peripheral-auth.js";
import type { PeripheralDecisionDeps } from "./peripheral-decisions.js";
import { decisionInput, peripheralDecision, peripheralFleet } from "./peripheral-decisions.js";
import { peripheralEvents, peripheralNonce } from "./peripheral-events.js";
import { peripheralModel } from "./peripheral-model.js";
import { peripheralStream } from "./peripheral-stream.js";
import { ensurePodToolApprovals, ensureVoiceBot, existingVoiceBot } from "./voice-bot.js";

const id = z.string().min(1).max(128);
const noncePart = z.string().regex(/^[A-Za-z0-9_-]{1,96}$/);
const deviceKey = z.string().regex(/^[a-f0-9]{64}$/);
const statusInput = z.object({
  issuer: z.string().min(1).max(1024),
  subject: z.string().min(1).max(512),
  chatModel: z.string().trim().min(1).max(512).optional(),
});
const device = z.object({
  issuer: z.string().min(1).max(1024),
  subject: z.string().min(1).max(512),
  deviceId: id,
  deviceKey: deviceKey.optional(),
});
const chatInput = device
  .extend({
    turnId: noncePart,
    text: z.string().trim().min(1).max(THREAD_MESSAGE_TEXT_MAX_LENGTH),
    chatModel: z.string().trim().min(1).max(512).optional(),
    targetBotId: id.optional(),
    targetGroupId: id.optional(),
    callId: noncePart.optional(),
  })
  .refine(({ chatModel, targetGroupId, targetBotId, callId }) => {
    if (targetGroupId) return !chatModel && !targetBotId && !callId;
    if (targetBotId) return !chatModel && Boolean(callId);
    return Boolean(chatModel) && !callId;
  });
const eventInput = device.extend({
  deviceKey,
  targetBotIds: z.array(id).max(32).default([]),
  targetGroupIds: z.array(id).max(32).default([]),
  cursors: z.record(id, z.number().int().min(-1)).default({}),
});

const TTS_MODEL_PATTERN = /(^|[-_/])(tts|speech|cosyvoice|fish|vox|audio|voice)([-_.]|$)/i;
const MODEL_CATALOG_TTL_MS = 30_000;
const modelCatalogCache = new Map<
  string,
  { expiresAt: number; value: { chatModels: string[]; ttsModels: string[] } }
>();

async function fetchAvailableModels(
  baseUrl: string,
  apiKey: string,
  cacheKey: string,
  signal: AbortSignal,
): Promise<{ chatModels: string[]; ttsModels: string[] } | undefined> {
  const now = Date.now();
  const cached = modelCatalogCache.get(cacheKey);
  if (cached && cached.expiresAt > now) return cached.value;
  try {
    const response = await fetch(`${baseUrl.replace(/\/+$/, "")}/models`, {
      method: "GET",
      headers: { authorization: `Bearer ${apiKey}` },
      signal: deadlineSignal(2500, signal),
    });
    if (!response.ok) return undefined;
    const payload = (await response.json()) as { data?: Array<{ id?: unknown }> };
    const chatModels: string[] = [];
    const ttsModels: string[] = [];
    const seen = new Set<string>();
    for (const item of payload.data ?? []) {
      const id = typeof item?.id === "string" ? item.id.trim() : "";
      if (!id || seen.has(id)) continue;
      seen.add(id);
      if (TTS_MODEL_PATTERN.test(id)) ttsModels.push(id);
      else chatModels.push(id);
    }
    const value = { chatModels, ttsModels };
    if (modelCatalogCache.size >= 256) modelCatalogCache.clear();
    modelCatalogCache.set(cacheKey, { expiresAt: now + MODEL_CATALOG_TTL_MS, value });
    return value;
  } catch {
    return undefined;
  }
}

type PeripheralOptions = {
  bridgeSecret: string;
  issuer?: string;
  connection: ReturnType<typeof configuredModelAccount>;
  speechSummary?: { summarize: SpeechSummarizer; minChars: number };
};

type Variables = {
  body: unknown;
  linked: NonNullable<Awaited<ReturnType<typeof resolvePeripheralActor>>>;
  identity: { issuer: string; subject: string };
};

function sendStream(
  c: Context,
  follow: (signal: AbortSignal) => AsyncGenerator<{ event: string; data: unknown }>,
  stillAuthorized?: () => Promise<boolean>,
) {
  const controller = new AbortController();
  const signal = AbortSignal.any([controller.signal, c.req.raw.signal]);
  const response = streamSSE(c, async (stream) => {
    stream.onAbort(() => controller.abort());
    try {
      for await (const frame of withHeartbeats({ signal, stillAuthorized }, follow)) {
        if (frame === HEARTBEAT) await stream.writeSSE({ event: "heartbeat", data: "{}" });
        else await stream.writeSSE({ event: frame.event, data: JSON.stringify(frame.data) });
      }
    } catch (error) {
      if (signal.aborted) return;
      getLogger().error("peripheral event stream failed", error);
      await stream.writeSSE({ event: "error", data: '{"error":"unavailable"}' });
    } finally {
      controller.abort();
    }
  });
  response.headers.set("cache-control", "no-store");
  return response;
}

export function mountPeripheralRoutes(
  app: Hono,
  deps: PeripheralDecisionDeps & Pick<RouterDeps, "auth">,
  { bridgeSecret, issuer, connection, speechSummary }: PeripheralOptions,
) {
  if (!connection || !issuer)
    throw new Error("Peripheral bridge requires OIDC and a model account");

  const routes = new Hono<{ Variables: Variables }>();
  routes.use("*", async (c, next) => {
    c.header("cache-control", "no-store");
    if (!hasValidBearerToken(c.req.header("authorization"), bridgeSecret))
      return c.json({ error: "unauthorized" }, 401);
    return next();
  });
  routes.use("*", bodyLimit({ maxSize: 512 * 1024 }));
  routes.post("/status", async (c) => {
    let body: unknown;
    try {
      body = await c.req.json();
    } catch (error) {
      if (!(error instanceof SyntaxError)) throw error;
      return c.json({ error: "invalid_request" }, 400);
    }
    const parsed = statusInput.safeParse(body);
    if (!parsed.success) return c.json({ error: "invalid_request" }, 400);
    if (parsed.data.issuer !== issuer) {
      return c.json({
        accountReady: false,
        boboReady: false,
        boboBotId: null,
        authStatus: "account_required",
        modelReady: false,
      });
    }
    const identity = { issuer, subject: parsed.data.subject };
    const linked = await resolvePeripheralActor(deps, identity);
    if (!linked) {
      return c.json({
        accountReady: false,
        boboReady: false,
        boboBotId: null,
        authStatus: "account_required",
        modelReady: false,
      });
    }
    const result = await runAsTenant(linked.actor, async () => {
      const bobo = await existingVoiceBot(deps.prisma, linked.actor);
      const entitlement = await connection!.provider
        .ensure(identity, c.req.raw.signal)
        .catch((error) => {
          if (!(error instanceof ExternalModelAccountError)) throw error;
          return error;
        });
      if (entitlement instanceof ExternalModelAccountError) {
        const authStatus =
          entitlement.reason === "authorization_required"
            ? "authorization_required"
            : entitlement.reason === "quota_exhausted"
              ? "quota_exhausted"
              : "unavailable";
        return {
          accountReady: true,
          boboReady: Boolean(bobo),
          boboBotId: bobo?.id ?? null,
          authStatus,
          modelReady: false,
        };
      }
      let modelReady = true;
      let authStatus: "ready" | "model_connection_required" = "ready";
      if (parsed.data.chatModel) {
        const model = await peripheralModel(
          deps,
          linked.actor,
          linked.accountId,
          entitlement.apiKey,
          connection.model.baseUrl,
          parsed.data.chatModel,
        );
        if (!model) {
          modelReady = false;
          authStatus = "model_connection_required";
        }
      }
      const availableModels = await fetchAvailableModels(
        connection.model.baseUrl,
        entitlement.apiKey,
        `${connection.model.baseUrl}\0${linked.actor.userId}`,
        c.req.raw.signal,
      );
      return {
        accountReady: true,
        boboReady: Boolean(bobo),
        boboBotId: bobo?.id ?? null,
        authStatus,
        modelReady,
        ...(availableModels ? { availableModels } : {}),
      };
    });
    return c.json(result);
  });
  routes.use("*", async (c, next) => {
    let body: unknown;
    try {
      body = await c.req.json();
    } catch (error) {
      if (!(error instanceof SyntaxError)) throw error;
      return c.json({ error: "invalid_request" }, 400);
    }
    const parsed = device.safeParse(body);
    if (!parsed.success) return c.json({ error: "invalid_request" }, 400);
    if (parsed.data.issuer !== issuer) return c.json({ error: "account_required" }, 403);
    const identity = { issuer, subject: parsed.data.subject };
    const linked = await resolvePeripheralActor(deps, identity);
    if (!linked) return c.json({ error: "account_required" }, 403);
    c.set("body", body);
    c.set("linked", linked);
    c.set("identity", identity);
    await runAsTenant(linked.actor, next);
  });

  async function ensure(c: Context<{ Variables: Variables }>) {
    const value = await connection!.provider
      .ensure(c.get("identity"), c.req.raw.signal)
      .catch((error) => {
        if (!(error instanceof ExternalModelAccountError)) throw error;
        return error;
      });
    if (!(value instanceof ExternalModelAccountError)) return value;
    if (value.reason === "authorization_required")
      return c.json({ error: "authorization_required" }, 403);
    if (value.reason === "quota_exhausted") return c.json({ error: "quota_exhausted" }, 409);
    return c.json({ error: "model_account_unavailable" }, 503);
  }

  routes.post("/fleet", async (c) =>
    c.json(await peripheralFleet(deps.prisma, c.get("linked").actor)),
  );

  routes.post("/decisions", async (c) => {
    const parsed = decisionInput.safeParse(c.get("body"));
    if (!parsed.success) return c.json({ error: "invalid_request" }, 400);
    const result = await peripheralDecision(deps, c.get("linked").actor, parsed.data).catch(
      (error: unknown) => {
        if (
          error instanceof IsolationError ||
          (error instanceof ClientError && error.kind === "CONFLICT")
        )
          return null;
        if (error instanceof ClientError && error.kind === "BAD_REQUEST") return false;
        throw error;
      },
    );
    if (result === false) return c.json({ error: "invalid_answer" }, 400);
    return result ? c.json(result) : c.json({ error: "decision_conflict" }, 409);
  });

  routes.post("/events", (c) => {
    const parsed = eventInput.safeParse(c.get("body"));
    if (!parsed.success) return c.json({ error: "invalid_request" }, 400);
    const { actor } = c.get("linked");
    return sendStream(
      c,
      (signal) => peripheralEvents(deps, actor, parsed.data, signal),
      async () => {
        const refreshed = await resolvePeripheralActor(deps, c.get("identity"));
        return (
          refreshed?.actor.userId === actor.userId && refreshed.actor.spaceId === actor.spaceId
        );
      },
    );
  });

  routes.post("/speech", async (c) => {
    const entitlement = await ensure(c);
    return entitlement instanceof Response
      ? entitlement
      : c.json({ tts: { baseUrl: connection.model.baseUrl, ...entitlement } });
  });

  routes.post("/chat", async (c) => {
    const parsed = chatInput.safeParse(c.get("body"));
    if (!parsed.success) return c.json({ error: "invalid_request" }, 400);
    const {
      turnId,
      text,
      chatModel,
      targetBotId,
      targetGroupId,
      callId,
      deviceKey: key,
    } = parsed.data;
    const { actor, accountId } = c.get("linked");
    const existing =
      targetBotId || targetGroupId ? null : await existingVoiceBot(deps.prisma, actor);
    const requested = targetBotId ?? existing?.id;
    const current =
      requested || targetGroupId
        ? await resolveThreadTarget(deps.prisma, actor, {
            botId: requested,
            groupId: targetGroupId,
          }).catch((error: unknown) => {
            if (error instanceof IsolationError) return null;
            throw error;
          })
        : null;
    if (
      ((requested || targetGroupId) && !current) ||
      (current?.kind === "bot" && current.bot.userId !== actor.userId)
    )
      return c.json({ error: "target_unavailable" }, 404);
    const entitlement = await ensure(c);
    if (entitlement instanceof Response) return entitlement;
    const { apiKey } = entitlement;
    const personalModel = (modelId?: string) =>
      peripheralModel(deps, actor, accountId, apiKey, connection.model.baseUrl, modelId);

    const nonce = peripheralNonce(key, turnId, callId);
    const model =
      current?.kind === "group"
        ? null
        : await personalModel(
            chatModel ?? (current?.kind === "bot" ? (current.bot.modelId ?? undefined) : undefined),
          );
    const target =
      current ??
      (model &&
        (await resolveThreadTarget(deps.prisma, actor, {
          botId: await ensureVoiceBot(deps.prisma, actor),
        })));
    if (!target) return c.json({ error: "model_connection_required" }, 403);

    let receipt: Awaited<ReturnType<typeof sendThreadMessage>>;
    if (target.kind === "bot") {
      if (
        !model ||
        (!chatModel && target.bot.modelProvider && target.bot.modelProvider !== model.modelProvider)
      )
        return c.json({ error: "model_connection_required" }, 403);
      await assertTeachingSendAllowed(deps.prisma, actor.spaceId, target.botId);
      await ensurePodToolApprovals(deps.prisma, actor);
      receipt = await sendThreadMessage(deps, actor, target, {
        text,
        clientNonce: nonce,
        modelPin: { ...model, thinkingLevel: chatModel ? "off" : target.bot.thinkingLevel },
      });
    } else {
      const targets = sendTargetBotIds(target, { text });
      if (!targets.length) return c.json({ error: "target_unavailable" }, 404);
      const bots = await deps.prisma.bot.findMany({
        where: { id: { in: targets }, spaceId: actor.spaceId, archivedAt: null },
        select: { id: true, modelId: true, modelProvider: true, thinkingLevel: true },
      });
      const models = new Map<string, Awaited<ReturnType<typeof personalModel>>>();
      const pins = new Map<
        string,
        NonNullable<Parameters<typeof sendThreadMessage>[3]["modelPin"]>
      >();
      for (const bot of bots) {
        const choice = bot.modelId ?? "";
        if (!models.has(choice)) models.set(choice, await personalModel(bot.modelId ?? undefined));
        const selected = models.get(choice);
        if (!selected || (bot.modelProvider && bot.modelProvider !== selected.modelProvider))
          return c.json({ error: "model_connection_required" }, 403);
        pins.set(bot.id, { ...selected, thinkingLevel: bot.thinkingLevel });
      }
      receipt = await sendThreadMessage(deps, actor, target, {
        text,
        clientNonce: nonce,
        mentions: [...pins.keys()],
        modelPins: pins,
      });
    }

    const run = await deps.prisma.run.findFirst({
      where: { id: receipt.runId, threadId: target.threadId, userId: actor.userId },
      select: { id: true },
    });
    if (!run) return c.json({ error: "thread_busy" }, 409);
    const message = await deps.prisma.message.findUnique({
      where: { threadId_clientNonce: { threadId: target.threadId, clientNonce: nonce } },
      select: { id: true, seq: true, steeringMessages: { select: { id: true }, take: 1 } },
    });
    if (!message) return c.json({ error: "turn_unavailable" }, 409);
    const event = await deps.prisma.event.findFirst({
      where: {
        threadId: target.threadId,
        type: "thread.message.created",
        payload: { path: ["messageId"], equals: message.id },
      },
      select: { seq: true },
    });
    if (!event) return c.json({ error: "turn_unavailable" }, 409);

    return sendStream(c, async function* (signal) {
      yield {
        event: "session_meta",
        data: {
          type: "session_meta",
          turnId,
          botId: target.kind === "bot" ? target.botId : undefined,
          threadId: target.threadId,
          runId: run.id,
          cursor: event.seq,
          tts: { baseUrl: connection.model.baseUrl, apiKey },
        },
      };
      if (target.kind === "group") {
        yield { event: "done", data: { status: "queued" } };
        return;
      }
      const events = deps.events.follow(target.threadId, event.seq, signal);
      const summarize =
        callId && speechSummary
          ? {
              minChars: speechSummary.minChars,
              run: (reply: string) => speechSummary.summarize(actor, target.botId, reply, signal),
            }
          : undefined;
      yield* peripheralStream(
        events,
        run.id,
        summarize,
        message.steeringMessages.length ? message.seq : undefined,
      );
    });
  });

  app.route("/api/peripheral/v1", routes);
}
