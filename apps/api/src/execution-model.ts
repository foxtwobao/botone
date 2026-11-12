import type { Actor } from "@rakazo/contracts";
import type { RouterDeps } from "./router.js";
import { botsRunOwnModels } from "./routes/shared.js";

/** Native executions resolve their models remotely; built-in bots use the existing credential check. */
export async function botsCanRunWithoutDefaultModel(
  deps: RouterDeps,
  actor: Actor,
  botIds: string[],
) {
  const native = await deps.prisma.botExecution.findMany({
    where: {
      botId: { in: botIds },
      spaceId: actor.spaceId,
      userId: actor.userId,
      connection: { revokedAt: null },
    },
    select: { botId: true },
  });
  const nativeIds = new Set(native.map((configuration) => configuration.botId));
  return botsRunOwnModels(
    deps,
    actor,
    botIds.filter((id) => !nativeIds.has(id)),
  );
}
