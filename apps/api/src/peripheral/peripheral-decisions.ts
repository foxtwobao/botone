import { ORPCError } from "@orpc/server";
import { settleCallRequest, stopNativeThreadRuns, wakeRun } from "@rakazo/adapters";
import type { Actor, MessageBlock } from "@rakazo/contracts";
import {
  ACTIVE_RUN_STATUSES,
  isApprovalAskBlock,
  isSecretAskBlock,
  truncatedPlainText,
} from "@rakazo/core";
import type { PrismaClient } from "@rakazo/db";
import { answerToolQuestion, storedMessageBlocks } from "@rakazo/db";
import * as z from "zod";
import { answerExecutionInput } from "../execution-answer.js";
import type { RouterDeps } from "../router.js";
import { stopThreadRuns } from "../threads/thread-stop.js";
import { resolveThreadTarget } from "../threads/thread-target.js";

export type PeripheralDecisionDeps = Pick<
  RouterDeps,
  "prisma" | "events" | "jobs" | "sandbox" | "secrets" | "notifications"
> & {
  answerTakeover(
    actor: Actor,
    botId: string,
    reason: "done" | "skipped",
    runId: string,
  ): Promise<string | null>;
};
const id = z.string().min(1).max(128);
const runRef = { threadId: id, runId: id };
export const decisionInput = z.discriminatedUnion("action", [
  z.object({ action: z.literal("stop"), threadId: id }),
  z.object({ action: z.enum(["accept_call", "decline_call"]), botId: id, callId: id }),
  z.object({
    action: z.literal("end_call"),
    botId: id,
    callId: id,
    durationSeconds: z.number().int().min(0).max(86_400),
  }),
  z.object({ action: z.enum(["resume", "skip"]), ...runRef }),
  z.object({
    action: z.enum(["approve", "always_allow_site", "deny", "decline_question"]),
    ...runRef,
    messageId: id,
  }),
  z.object({
    action: z.literal("answer"),
    ...runRef,
    messageId: id,
    answer: z.string().trim().min(1).max(2_000).optional(),
    values: z
      .record(z.string(), z.union([z.string().max(2_000), z.boolean(), z.number()]))
      .optional(),
  }),
]);

function question(blocks: MessageBlock[]) {
  return blocks.find(
    (block) =>
      (block.kind === "ask" && block.status !== "answered" && !isSecretAskBlock(block)) ||
      (block.kind === "tool_question" &&
        block.status === "pending" &&
        Date.parse(block.expiresAt) > Date.now()),
  );
}

const approvalActions = new Map([
  ["web_fetch", "查看网页"],
  ["write_file", "写入文件"],
  ["save_page", "保存页面"],
  ["create_space", "创建工作区"],
  ["update_bot", "修改机器人的设置"],
  ["set_child_instructions", "修改机器人的指令"],
  ["archive_bot", "归档机器人"],
  ["schedule_create", "创建例行任务"],
  ["schedule_update", "修改例行任务"],
  ["shell", "运行命令"],
  ["user_computer_shell", "在你的电脑上运行命令"],
  ["browser_act", "操作浏览器"],
]);

function approvalSpeech(block: Extract<MessageBlock, { kind: "ask" }>, tool?: string) {
  if (block.site) return `想访问 ${truncatedPlainText(block.site, 100)} 上的网页`;
  if (block.receipt) {
    return block.receipt.amount
      ? `想支付 ${truncatedPlainText(block.receipt.amount, 60)}`
      : "想完成一笔付款";
  }
  if (block.outgoingDraft) {
    const { kind, to } = block.outgoingDraft.values;
    return `想给 ${truncatedPlainText(to, 80)} 发送${kind === "email" ? "邮件" : "消息"}`;
  }
  const action = tool && approvalActions.get(tool);
  return action ? `想${action}` : "有一项操作等你确认，请在 Botone 查看详情";
}

function offersSiteApproval(block: Extract<MessageBlock, { kind: "ask" }>) {
  return Boolean(block.site && block.actions?.some(({ id }) => id === "always"));
}

export async function peripheralFleet(prisma: PrismaClient, actor: Actor) {
  const scope = { spaceId: actor.spaceId, archivedAt: null };
  const [bots, groups, runs] = await Promise.all([
    prisma.bot.findMany({
      where: scope,
      orderBy: { position: "asc" },
      select: { id: true, name: true, thread: { select: { id: true } } },
    }),
    prisma.chatGroup.findMany({
      where: scope,
      orderBy: { name: "asc" },
      select: { id: true, name: true, thread: { select: { id: true } } },
    }),
    prisma.run.findMany({
      where: {
        spaceId: actor.spaceId,
        userId: actor.userId,
        status: { in: [...ACTIVE_RUN_STATUSES] },
      },
      orderBy: { createdAt: "desc" },
      take: 50,
      select: {
        id: true,
        threadId: true,
        botId: true,
        status: true,
        bot: { select: { name: true } },
      },
    }),
  ]);
  const messages = (
    await prisma.message.findMany({
      where: {
        runId: { in: runs.map((run) => run.id) },
        role: "bot",
        thread: { spaceId: actor.spaceId },
      },
      orderBy: [{ createdAt: "desc" }, { seq: "desc" }],
      select: { id: true, threadId: true, runId: true, blocks: true },
      take: 200,
    })
  ).map((item) => ({ ...item, block: question(storedMessageBlocks(item)) }));
  const effectIds = messages.flatMap(({ block }) =>
    block?.kind === "ask" && block.approvalEffectId && !block.site ? [block.approvalEffectId] : [],
  );
  const effects = new Map(
    effectIds.length
      ? (
          await prisma.externalEffect.findMany({
            where: {
              id: { in: effectIds },
              spaceId: actor.spaceId,
              runId: { in: runs.map(({ id }) => id) },
            },
            select: { id: true, kind: true, runId: true },
          })
        ).map((effect) => [effect.id, effect] as const)
      : [],
  );
  const cards = runs.flatMap((run) => {
    const ref = { runId: run.id, threadId: run.threadId, botId: run.botId, botName: run.bot.name };
    if (run.status === "waiting_takeover") {
      return [{ ...ref, kind: "takeover", text: "电脑操作完成后，请说继续。" }];
    }
    for (const item of messages) {
      if (item.runId !== run.id || item.threadId !== run.threadId) continue;
      const { block } = item;
      if (block?.kind === "ask" && run.status === "waiting_input") {
        const approval = isApprovalAskBlock(block);
        const effect = block.approvalEffectId && effects.get(block.approvalEffectId);
        return [
          {
            ...ref,
            messageId: item.id,
            kind: approval ? "approval" : "question",
            text: approval
              ? approvalSpeech(block, effect && effect.runId === run.id ? effect.kind : undefined)
              : truncatedPlainText(
                  [block.text, block.detailFormat === "code" ? "" : block.detail]
                    .filter(Boolean)
                    .join(" "),
                  240,
                ),
            ...(approval && offersSiteApproval(block) ? { offersSiteApproval: true } : {}),
            actions: block.actions?.map(({ id, label }) => ({ id, label })),
          },
        ];
      }
      if (block?.kind === "tool_question" && run.status === "running") {
        return [
          {
            ...ref,
            messageId: item.id,
            kind: "tool_question",
            text: block.question.message,
            fields: block.question.fields.map((field) => ({
              id: field.name,
              label: field.label,
              type: field.type,
              ...(field.type === "choice" ? { options: field.options } : {}),
            })),
          },
        ];
      }
    }
    return [];
  });
  return {
    bots: bots.map(({ id, name, thread }) => ({ id, name, threadId: thread?.id })),
    groups: groups.map(({ id, name, thread }) => ({ id, name, threadId: thread?.id })),
    runs: runs.map(({ bot, ...run }) => ({ ...run, botName: bot.name })),
    cards,
  };
}

export async function peripheralDecision(
  deps: PeripheralDecisionDeps,
  actor: Actor,
  input: z.infer<typeof decisionInput>,
) {
  if (input.action === "accept_call" || input.action === "decline_call") {
    const target = await resolveThreadTarget(deps.prisma, actor, { botId: input.botId });
    if (target.kind !== "bot" || target.bot.userId !== actor.userId) return null;
    const status = input.action === "accept_call" ? "answered" : "declined";
    const reply = await settleCallRequest(deps, {
      threadId: target.threadId,
      callId: input.callId,
      from: ["ringing"],
      status,
    });
    return reply?.status === status ? { ok: true, opening: reply.opening } : null;
  }
  if (input.action === "end_call") {
    const target = await resolveThreadTarget(deps.prisma, actor, { botId: input.botId });
    if (target.kind !== "bot" || target.bot.userId !== actor.userId) return null;
    await settleCallRequest(deps, {
      threadId: target.threadId,
      callId: input.callId,
      from: ["answered"],
      durationSeconds: input.durationSeconds,
    });
    return { ok: true };
  }
  if (!("threadId" in input)) return null;

  if (input.action === "stop") {
    const thread = await deps.prisma.thread.findFirst({
      where: {
        id: input.threadId,
        spaceId: actor.spaceId,
        userId: actor.userId,
        externalConversationId: null,
      },
      select: { botId: true, groupId: true },
    });
    if (!thread) return null;
    const target = await resolveThreadTarget(deps.prisma, actor, {
      botId: thread.botId ?? undefined,
      groupId: thread.groupId ?? undefined,
    });
    // The admitted thread belongs to the device owner, as in the signed-in Stop path.
    await stopNativeThreadRuns(deps, actor.spaceId, target.threadId);
    await stopThreadRuns(deps, actor, target);
    return { ok: true };
  }

  const run = await deps.prisma.run.findFirst({
    where: {
      id: input.runId,
      threadId: input.threadId,
      spaceId: actor.spaceId,
      userId: actor.userId,
    },
    select: { botId: true, status: true },
  });
  if (!run) return null;
  if (input.action === "resume" || input.action === "skip") {
    if (run.status !== "waiting_takeover") return null;
    const resumed = await deps.answerTakeover(
      actor,
      run.botId,
      input.action === "resume" ? "done" : "skipped",
      input.runId,
    );
    return resumed ? { ok: true } : null;
  }
  if (!("messageId" in input)) return null;
  const message = await deps.prisma.message.findFirst({
    where: { id: input.messageId, runId: input.runId, threadId: input.threadId, role: "bot" },
  });
  if (!message) return null;
  const block = question(storedMessageBlocks(message));
  if (block?.kind === "tool_question" && run.status === "running") {
    if (input.action !== "answer" && input.action !== "decline_question") return null;
    const result = await answerToolQuestion(deps.prisma, {
      ...input,
      spaceId: actor.spaceId,
      userId: actor.userId,
      action: input.action === "answer" ? "accept" : "decline",
      values: input.action === "answer" ? input.values : undefined,
    });
    if (!result) return null;
    await deps.events.notify(result.threadId, result.seq);
    return { ok: true };
  }
  if (block?.kind !== "ask" || run.status !== "waiting_input") return null;
  const approval = isApprovalAskBlock(block);
  const answer =
    input.action === "always_allow_site" && approval && offersSiteApproval(block)
      ? "always"
      : input.action === "approve" && approval
        ? "allow"
        : input.action === "deny" && approval
          ? "deny"
          : input.action === "answer" && !approval
            ? input.answer
            : undefined;
  if (!answer) return null;
  const native = await answerExecutionInput(deps, actor, input.threadId, {
    ...input,
    answer,
  }).catch((error: unknown) => {
    if (error instanceof ORPCError && error.code === "CONFLICT") return false;
    throw error;
  });
  if (native !== null) return native || null;
  const accepted = await deps.events.answerRunInput({
    ...input,
    spaceId: actor.spaceId,
    answeredByUserId: actor.userId,
    answer,
  });
  if (!accepted) return null;
  await wakeRun(deps.jobs, input.runId);
  return { ok: true };
}
