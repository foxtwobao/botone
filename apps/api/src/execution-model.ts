import type { Actor } from "@rakazo/contracts";
import type { RouterDeps } from "./router.js";
import { botsRunOwnModels } from "./routes/shared.js";

/** Native executions resolve their models remotely; built-in bots use the existing credential check. */
export async function botsCanRunWithoutDefaultModel(
  deps: RouterDeps,
  actor: Actor,
  botIds: string[],
) {
  const native = await deps.prisma.bot.findMany({
    where: {
      id: { in: botIds },
      spaceId: actor.spaceId,
      executionConfiguration: {
        spaceId: actor.spaceId,
        userId: actor.userId,
        connection: { revokedAt: null },
      },
    },
    select: { id: true },
  });
  const nativeIds = new Set(native.map((bot) => bot.id));
  return botsRunOwnModels(
    deps,
    actor,
    botIds.filter((id) => !nativeIds.has(id)),
  );
}
