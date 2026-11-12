import type { SecretStore } from "@rakazo/adapter-kit";
import { ACTIVE_RUN_STATUSES } from "@rakazo/core";
import type { PrismaClient, ThreadEvents } from "@rakazo/db";
import { runAsSystem } from "@rakazo/db";
import { updateNativeInteraction } from "./answers.js";
import { executionConnectionClient } from "./connection.js";
import { executionStartSchema } from "./wire.js";

/** The caller has authorized Stop on this thread. No private connection data is returned. */
export async function stopNativeThreadRuns(
  deps: { prisma: PrismaClient; secrets: SecretStore; events: ThreadEvents },
  spaceId: string,
  threadId: string,
  onlyBotId?: string,
) {
  return runAsSystem("stop native processes in an authorized thread", async () => {
    const runs = await deps.prisma.run.findMany({
      where: {
        spaceId,
        threadId,
        status: { in: [...ACTIVE_RUN_STATUSES] },
        ...(onlyBotId ? { botId: onlyBotId } : {}),
      },
      include: { nativeExecution: true, bot: { include: { executionConfiguration: true } } },
    });
    await Promise.all(
      runs.map(async (run) => {
        const saved = run.nativeExecution;
        const configuration = run.bot.executionConfiguration;
        if (!saved && !configuration) return;
        if (!saved && configuration?.userId !== run.userId) return;
        const connection = await deps.prisma.executionConnection.findFirstOrThrow({
          where: {
            id: saved?.connectionId ?? configuration?.connectionId,
            spaceId,
            userId: run.userId,
          },
        });
        // A revoked connection remains usable only to terminate its own processes.
        const client = await executionConnectionClient(deps.secrets, {
          ...connection,
          revokedAt: null,
        });
        const scope = saved
          ? executionStartSchema.parse(
              JSON.parse(await deps.secrets.load(saved.requestRef, run.id)),
            ).scope
          : {
              spaceId,
              userId: run.userId,
              botId: run.botId,
              threadId,
              computerId: connection.computerId,
              profileId: configuration!.profileId,
              revision: configuration!.revision,
            };
        await client.stop({ runId: run.id, scope, fence: run.leaseFence });
        const events = await deps.prisma.$transaction(async (tx) => {
          await tx.$queryRaw`SELECT id FROM runs WHERE id = ${run.id} FOR UPDATE`;
          const pending = await tx.nativeInteraction.findMany({
            where: { runId: run.id, status: { in: ["pending", "submitted"] } },
          });
          return Promise.all(
            pending.map((interaction) => updateNativeInteraction(tx, interaction, "expired")),
          );
        });
        for (const event of events) await deps.events.notify(threadId, event.seq);
      }),
    );
  });
}
