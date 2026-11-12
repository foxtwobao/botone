import type { MessageBlock } from "@rakazo/contracts";
import type { Prisma, PrismaClient, ThreadEvents } from "@rakazo/db";
import { appendEventInTransaction } from "@rakazo/db";

export async function updateNativeInteraction(
  tx: Prisma.TransactionClient,
  interaction: { id: string; messageId: string; runId: string; spaceId: string },
  status: "submitted" | "delivered" | "expired",
  answer?: string,
) {
  const message = await tx.message.findUniqueOrThrow({ where: { id: interaction.messageId } });
  const blocks = (message.blocks as MessageBlock[]).map((block) =>
    block.kind === "ask" && block.nativeRequestId
      ? {
          ...block,
          nativeDelivery: status,
          ...(answer === undefined ? {} : { answer }),
          status: status === "submitted" ? ("pending" as const) : ("answered" as const),
        }
      : block,
  );
  await tx.nativeInteraction.update({ where: { id: interaction.id }, data: { status } });
  await tx.message.update({ where: { id: message.id }, data: { blocks } });
  return appendEventInTransaction(tx, {
    spaceId: interaction.spaceId,
    threadId: message.threadId,
    botId: message.botId!,
    runId: interaction.runId,
    type: "thread.message.updated",
    payload: { messageId: message.id, blocks },
  });
}

/** Submission is durable first. Only the live original process can report delivery. */
export async function answerNativeInteraction(
  deps: { prisma: PrismaClient; events: ThreadEvents },
  input: {
    spaceId: string;
    userId: string;
    threadId: string;
    runId: string;
    messageId: string;
    answer: string;
  },
): Promise<boolean | null> {
  const interaction = await deps.prisma.nativeInteraction.findFirst({
    where: { runId: input.runId, messageId: input.messageId, spaceId: input.spaceId },
  });
  if (!interaction) return null;
  if (interaction.userId !== input.userId || !input.answer || input.answer.length > 16_384)
    return false;
  const result = await deps.prisma.$transaction(async (tx) => {
    await tx.$queryRaw`SELECT id FROM runs WHERE id = ${input.runId} FOR UPDATE`;
    const run = await tx.run.findFirst({
      where: { id: input.runId, threadId: input.threadId, userId: input.userId, status: "running" },
    });
    const current = await tx.nativeInteraction.findUniqueOrThrow({ where: { id: interaction.id } });
    const execution = await tx.nativeExecution.findUnique({ where: { runId: input.runId } });
    if (!run || current.generation !== execution?.generation) return false;
    const message = await tx.message.findUniqueOrThrow({ where: { id: input.messageId } });
    const block = (message.blocks as MessageBlock[]).find(
      (block) => block.kind === "ask" && block.nativeRequestId === current.requestId,
    );
    if (
      block?.kind !== "ask" ||
      (block.nativeKind === "permission" && !block.actions?.some((a) => a.id === input.answer))
    )
      return false;
    if (current.status !== "pending") {
      return (
        (current.status === "submitted" || current.status === "delivered") &&
        block.answer === input.answer
      );
    }
    return updateNativeInteraction(tx, current, "submitted", input.answer);
  });
  if (typeof result === "boolean") return result;
  await deps.events.notify(input.threadId, result.seq);
  return true;
}
