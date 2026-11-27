import { loadUserIncomingCalls } from "@rakazo/adapters";
import type { Actor } from "@rakazo/contracts";
import { callIdFromClientNonce, callRequestClientNonce, truncatedPlainText } from "@rakazo/core";
import { storedMessageBlocks } from "@rakazo/db";
import type { RouterDeps } from "../router.js";
import { mergeStreams } from "../routes/shared.js";

type Deps = Pick<RouterDeps, "prisma" | "events">;
type Frame = { event: string; data: Record<string, unknown> };

export function peripheralNonce(deviceKey: string | undefined, turnId: string, callId?: string) {
  const suffix = deviceKey ? `${deviceKey}.${turnId}` : turnId;
  return callId ? `call:${callId}:${suffix}` : `pod:${suffix}`;
}

function sourceDevice(nonce: string | null | undefined) {
  if (!nonce?.startsWith("pod:") && !callIdFromClientNonce(nonce)) return undefined;
  const suffix = nonce?.slice(nonce.lastIndexOf(":") + 1);
  return /^([a-f0-9]{64})\./.exec(suffix ?? "")?.[1];
}

async function originDevice(
  deps: Deps,
  actor: Actor,
  threadId: string,
  runId: string,
  before: Date,
) {
  const run = await deps.prisma.run.findFirst({
    where: { id: runId, threadId, userId: actor.userId },
    select: { sourceMessage: { select: { clientNonce: true } } },
  });
  if (!run) return undefined;
  const claim = await deps.prisma.event.findFirst({
    where: { type: "run.steering.claimed", threadId, runId, createdAt: { lte: before } },
    orderBy: { seq: "desc" },
    select: { payload: true },
  });
  const payload = claim?.payload;
  const watermark =
    payload && typeof payload === "object" && !Array.isArray(payload)
      ? payload.nextMessageSeq
      : undefined;
  if (typeof watermark === "number") {
    const message = await deps.prisma.message.findFirst({
      where: { threadId, runId, seq: { lt: watermark }, role: "user", authorUserId: actor.userId },
      orderBy: { seq: "desc" },
      select: { clientNonce: true },
    });
    if (message) return sourceDevice(message.clientNonce);
  }
  return sourceDevice(run.sourceMessage?.clientNonce);
}

async function* calls(deps: Deps, actor: Actor, signal: AbortSignal): AsyncGenerator<Frame> {
  if (!deps.events.followIncomingCalls) return;
  for await (const _ of deps.events.followIncomingCalls(actor.userId, signal)) {
    const ringing = (await loadUserIncomingCalls(deps.prisma, actor.userId)).filter(
      (item) => item.spaceId === actor.spaceId,
    );
    const list = await Promise.all(
      ringing.map(async ({ id, name, incomingCall }) => {
        const message = await deps.prisma.message.findFirst({
          where: {
            botId: id,
            clientNonce: callRequestClientNonce(incomingCall.callId),
            thread: { spaceId: actor.spaceId, userId: actor.userId },
          },
          select: { runId: true, createdAt: true, threadId: true },
        });
        const origin = message?.runId
          ? await originDevice(deps, actor, message.threadId, message.runId, message.createdAt)
          : undefined;
        return {
          botId: id,
          botName: name,
          ...incomingCall,
          ...(origin ? { deviceKey: origin } : {}),
        };
      }),
    );
    yield { event: "calls", data: { calls: list } };
  }
}

async function* notices(deps: Deps, actor: Actor, signal: AbortSignal): AsyncGenerator<Frame> {
  if (!deps.events.followChatAlerts) return;
  for await (const alert of deps.events.followChatAlerts(actor.userId, actor.spaceId, signal)) {
    if (alert.kind === "help" || alert.kind === "takeover") {
      yield { event: "pending_cards", data: {} };
    }
    if (alert.kind !== "completion" || !alert.runId) continue;
    const run = await deps.prisma.run.findFirst({
      where: {
        id: alert.runId,
        threadId: alert.threadId,
        userId: actor.userId,
        spaceId: actor.spaceId,
        trigger: "routine",
        status: "completed",
      },
      select: {
        id: true,
        bot: { select: { name: true } },
        routine: { select: { notify: true, name: true } },
      },
    });
    if (run && run.routine?.notify !== false) {
      yield {
        event: "notification",
        data: {
          id: run.id,
          text: `${run.routine?.name ?? run.bot.name}完成了。${alert.body}`,
        },
      };
    }
  }
}

async function* results(
  deps: Deps,
  actor: Actor,
  threadId: string,
  cursor: number,
  deviceKey: string,
  signal: AbortSignal,
): AsyncGenerator<Frame> {
  for await (const event of deps.events.follow(threadId, cursor, signal)) {
    if (
      event.type === "thread.message.created" &&
      event.payload.role === "user" &&
      typeof event.payload.messageId === "string" &&
      event.runId
    ) {
      const incoming = await deps.prisma.message.findFirst({
        where: { id: event.payload.messageId, threadId, runId: event.runId },
        select: { id: true, blocks: true, replyTo: { select: { runId: true, createdAt: true } } },
      });
      const block =
        incoming &&
        storedMessageBlocks(incoming).find(
          (item) => item.kind === "bot_message_received" && item.intent === "result",
        );
      if (incoming?.replyTo?.runId && block?.kind === "bot_message_received") {
        const origin = await originDevice(
          deps,
          actor,
          threadId,
          incoming.replyTo.runId,
          incoming.replyTo.createdAt,
        );
        if (origin === deviceKey) {
          yield {
            event: "result",
            data: {
              id: incoming.id,
              threadId,
              cursor: event.seq,
              text: `${block.fromBotName}完成了。${truncatedPlainText(block.text, 240)}`,
            },
          };
          continue;
        }
      }
    }
    if (event.type === "run.completed" && event.runId) {
      const groupRun = await deps.prisma.run.findFirst({
        where: {
          id: event.runId,
          threadId,
          userId: actor.userId,
          thread: { groupId: { not: null } },
        },
        select: {
          id: true,
          bot: { select: { name: true } },
          sourceMessage: { select: { clientNonce: true } },
        },
      });
      if (groupRun && sourceDevice(groupRun.sourceMessage?.clientNonce) === deviceKey) {
        const reply = await deps.prisma.message.findFirst({
          where: { threadId, runId: groupRun.id, role: "bot" },
          orderBy: { seq: "desc" },
          select: { id: true, blocks: true },
        });
        const text = reply
          ? storedMessageBlocks(reply)
              .flatMap((block) => (block.kind === "text" ? [block.text] : []))
              .join(" ")
          : "";
        yield {
          event: "result",
          data: {
            id: groupRun.id,
            threadId,
            cursor: event.seq,
            text: `${groupRun.bot.name}完成了。${truncatedPlainText(text, 240)}`,
          },
        };
        continue;
      }
    }
    yield { event: "cursor", data: { threadId, cursor: event.seq } };
  }
}

export async function* peripheralEvents(
  deps: Deps,
  actor: Actor,
  input: {
    deviceKey: string;
    targetBotIds: string[];
    targetGroupIds: string[];
    cursors: Record<string, number>;
  },
  signal: AbortSignal,
) {
  const threads = await deps.prisma.thread.findMany({
    where: {
      spaceId: actor.spaceId,
      userId: actor.userId,
      OR: [
        {
          bot: {
            archivedAt: null,
            OR: [{ spawnKey: "peripheral:podone" }, { id: { in: input.targetBotIds } }],
          },
        },
        { group: { id: { in: input.targetGroupIds }, archivedAt: null } },
      ],
    },
    select: { id: true, nextEventSeq: true },
  });
  yield {
    event: "ready",
    data: {
      cursors: Object.fromEntries(
        threads.map((thread) => [thread.id, input.cursors[thread.id] ?? thread.nextEventSeq - 1]),
      ),
    },
  };
  yield* mergeStreams(
    calls(deps, actor, signal),
    notices(deps, actor, signal),
    ...threads.map(({ id, nextEventSeq }) =>
      results(deps, actor, id, input.cursors[id] ?? nextEventSeq - 1, input.deviceKey, signal),
    ),
  );
}
