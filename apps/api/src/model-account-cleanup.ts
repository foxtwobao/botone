import type { SecretStore } from "@rakazo/adapter-kit";
import { modelAccountCatalog } from "@rakazo/adapters";
import { OPENAI_COMPATIBLE_PROVIDER_ID } from "@rakazo/contracts";
import type { PrismaClient } from "@rakazo/db";
import { deleteUnreferencedCredentialSecret, runAsSystem } from "@rakazo/db";

/** Retire ordinary model settings at startup; historical runs and OIDC identities stay intact. */
export async function removeOrdinaryModelConnections(
  prisma: PrismaClient,
  secrets: Pick<SecretStore, "load">,
) {
  return runAsSystem("remove unsupported model connections", () =>
    prisma.$transaction(
      async (tx) => {
        await tx.$queryRaw`SELECT pg_advisory_xact_lock(hashtextextended('model-account-cleanup', 0))::text AS lock`;
        // Existing foreign keys remove the connection's preferences and pinned role choices.
        const rows = await tx.$queryRaw<Array<{ id: string; secretId: string }>>`
          DELETE FROM user_model_credentials WHERE id NOT LIKE 'external-%'
          RETURNING id, "secretId"
        `;
        for (const row of rows)
          await deleteUnreferencedCredentialSecret(tx, {
            credentialKind: "model",
            credentialId: row.id,
            secretId: row.secretId,
          });
        const unsupportedRole = {
          OR: [
            { provider: { not: OPENAI_COMPATIBLE_PROVIDER_ID } },
            { credentialId: null },
            { NOT: { credentialId: { startsWith: "external-" } } },
          ],
        };
        await tx.userModelRoleChoice.deleteMany({ where: unsupportedRole });
        await tx.spaceModelRoleChoice.deleteMany({ where: unsupportedRole });
        await tx.$executeRaw`
          DELETE FROM space_setting_overrides o WHERE o.setting = 'models'
          AND NOT EXISTS (SELECT 1 FROM space_model_role_choices c
            WHERE c."spaceId" = o."spaceId" AND c."userId" = o."userId")
        `;
        await tx.modelOAuthSession.deleteMany({
          where: { NOT: { provider: { startsWith: "external-model" } } },
        });
        const owners = await Promise.all([
          tx.bot.findMany({
            where: { modelProvider: { not: null } },
            select: { userId: true },
            distinct: ["userId"],
          }),
          tx.routine.findMany({
            where: { modelProvider: { not: null } },
            select: { userId: true },
            distinct: ["userId"],
          }),
        ]);
        for (const userId of new Set(owners.flat().map((row) => row.userId))) {
          const catalog = await modelAccountCatalog(tx as unknown as PrismaClient, secrets, userId);
          const where = {
            userId,
            modelProvider: { not: null },
            NOT: {
              modelProvider: OPENAI_COMPATIBLE_PROVIDER_ID,
              modelId: { in: catalog.map((entry) => entry.id) },
            },
          };
          const data = { modelProvider: null, modelId: null, thinkingLevel: null };
          await tx.bot.updateMany({ where, data });
          await tx.routine.updateMany({ where, data });
        }
        await tx.deploymentSettings.updateMany({
          data: { defaultModelProvider: null, defaultModelId: null },
        });
        return { removed: rows.length };
      },
      { timeout: 60_000 },
    ),
  );
}
