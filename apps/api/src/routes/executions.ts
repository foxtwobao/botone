import { ORPCError } from "@orpc/server";
import { executionConnectionClient } from "@rakazo/adapters";
import { ACTIVE_RUN_STATUSES } from "@rakazo/core";
import { ensureAutomaticExecution } from "../automatic-execution.js";
import { stopBotExecutionRuns } from "../execution-stop.js";
import type { RouterContext } from "./context.js";

const owner = (actor: { spaceId: string; userId: string }) => ({
  spaceId: actor.spaceId,
  userId: actor.userId,
});

export function executionRoutes({ deps, authed }: RouterContext) {
  const ownedBot = async (actor: { spaceId: string; userId: string }, botId: string) => {
    const bot = await deps.prisma.bot.findFirst({ where: { id: botId, ...owner(actor) } });
    if (!bot) throw new ORPCError("NOT_FOUND");
    return bot;
  };
  return {
    executions: {
      list: authed.executions.list.handler(async ({ context: { actor }, input }) => {
        const bot = input.botId ? await ownedBot(actor, input.botId) : null;
        const pending = bot
          ? await ensureAutomaticExecution(deps, actor, bot.computerId)
          : undefined;
        const connections = await deps.prisma.executionConnection.findMany({
          where: {
            ...owner(actor),
            revokedAt: null,
            ...(bot ? { computerId: bot.computerId ?? "" } : {}),
          },
        });
        const views = await Promise.all(
          connections.map(async (connection) => {
            const base = {
              id: connection.id,
              computerId: connection.computerId,
              label: connection.label,
            };
            try {
              const client = await executionConnectionClient(
                deps.secrets,
                connection,
                deps.sandbox,
                deps.prisma,
              );
              const description = await client.describe();
              if (description.id !== connection.identity)
                throw new Error("execution_identity_changed");
              return {
                ...base,
                online: true,
                profiles: description.profiles.filter(
                  (p) =>
                    p.spaceId === actor.spaceId &&
                    p.computerId === connection.computerId &&
                    p.userIds.includes(actor.userId),
                ),
              };
            } catch {
              return { ...base, online: false, profiles: [] };
            }
          }),
        );
        return pending && !views.some((view) => view.id === pending.id)
          ? [...views, pending]
          : views;
      }),
      revoke: authed.executions.revoke.handler(async ({ context: { actor }, input }) => {
        const changed = await deps.prisma.executionConnection.updateMany({
          where: { id: input.id, ...owner(actor) },
          data: { revokedAt: new Date() },
        });
        if (!changed.count) throw new ORPCError("NOT_FOUND");
        return { ok: true as const };
      }),
      get: authed.executions.get.handler(async ({ context: { actor }, input }) => {
        await ownedBot(actor, input.botId);
        return deps.prisma.botExecution.findUnique({ where: { botId: input.botId } });
      }),
      configure: authed.executions.configure.handler(async ({ context: { actor }, input }) => {
        const initialBot = await ownedBot(actor, input.botId);
        const current = await deps.prisma.botExecution.findUnique({
          where: { botId: input.botId },
        });
        if (
          (!current && !input.configuration) ||
          (current &&
            input.configuration &&
            current.connectionId === input.configuration.connectionId &&
            current.profileId === input.configuration.profileId &&
            current.revision === input.configuration.revision &&
            current.model === input.configuration.model)
        )
          return { ok: true as const };
        let validatedIdentity: string | undefined;
        if (input.configuration) {
          const configuration = input.configuration;
          const connection = await deps.prisma.executionConnection.findFirst({
            where: {
              id: configuration.connectionId,
              ...owner(actor),
              computerId: initialBot.computerId ?? "",
              revokedAt: null,
            },
          });
          if (!connection) throw new ORPCError("NOT_FOUND");
          const description = await (
            await executionConnectionClient(deps.secrets, connection, deps.sandbox, deps.prisma)
          ).describe();
          if (
            description.id !== connection.identity ||
            !description.profiles.some(
              (p) =>
                p.status === "ready" &&
                p.id === configuration.profileId &&
                p.revision === configuration.revision &&
                p.spaceId === actor.spaceId &&
                p.computerId === connection.computerId &&
                p.userIds.includes(actor.userId),
            )
          )
            throw new ORPCError("FORBIDDEN");
          validatedIdentity = connection.identity;
        }
        if (input.stopActiveRuns) await stopBotExecutionRuns(deps, actor, input.botId);
        return deps.prisma.$transaction(
          async (tx) => {
            await tx.$queryRaw`SELECT id FROM bots WHERE id = ${input.botId} FOR UPDATE`;
            const bot = await tx.bot.findFirst({ where: { id: input.botId, ...owner(actor) } });
            if (!bot) throw new ORPCError("NOT_FOUND");
            // Existing work retains its immutable configuration until its process has stopped.
            if (
              await tx.run.findFirst({
                where: { botId: bot.id, status: { in: [...ACTIVE_RUN_STATUSES] } },
              })
            )
              throw new ORPCError("CONFLICT", {
                message: "Stop this bot before changing its execution",
              });
            if (!input.configuration) {
              await tx.botExecution.deleteMany({ where: { botId: bot.id, ...owner(actor) } });
              return { ok: true as const };
            }
            const configuration = input.configuration;
            const connection = await tx.executionConnection.findFirst({
              where: {
                id: configuration.connectionId,
                ...owner(actor),
                computerId: bot.computerId ?? "",
                revokedAt: null,
              },
            });
            if (!connection || connection.identity !== validatedIdentity)
              throw new ORPCError("NOT_FOUND");
            const data = { ...owner(actor), ...configuration };
            await tx.botExecution.upsert({
              where: { botId: bot.id },
              create: { botId: bot.id, ...data },
              update: data,
            });
            return { ok: true as const };
          },
          { timeout: 20_000 },
        );
      }),
    },
  };
}
