import type { SecretStore } from "@rakazo/adapter-kit";
import type { ModelCatalogEntry, ModelRoleChoice, ModelRoleSettings } from "@rakazo/contracts";
import { OPENAI_COMPATIBLE_PROVIDER_ID } from "@rakazo/contracts";
import type { PrismaClient } from "@rakazo/db";
import { modelCredentialDto } from "./model-connect.js";
import { parseModelSecret } from "./pi-oauth.js";

/** Existing external account connections have server-assigned ids; ordinary saves cannot create them. */
export const modelAccountCredentialWhere = { id: { startsWith: "external-" } };

export function modelAccountRole(settings: ModelRoleSettings): ModelRoleSettings {
  const allowed = (choice: ModelRoleChoice) =>
    choice.provider === OPENAI_COMPATIBLE_PROVIDER_ID &&
    choice.credentialId?.startsWith("external-");
  return {
    primary: settings.primary && allowed(settings.primary) ? settings.primary : null,
    backups: settings.backups.filter(allowed),
  };
}

/** Use only the account's discovered model list, never an unrelated provider's bundled catalog. */
export async function modelAccountCatalog(
  prisma: PrismaClient,
  secrets: Pick<SecretStore, "load">,
  userId: string,
): Promise<ModelCatalogEntry[]> {
  const credentials = await prisma.userModelCredential.findMany({
    where: { userId, ...modelAccountCredentialWhere },
  });
  const entries = new Map<string, ModelCatalogEntry>();
  for (const credential of credentials) {
    const row = await prisma.secret.findFirst({
      where: { id: credential.secretId, userId, spaceId: null },
    });
    if (!row) continue;
    const plaintext = await secrets.load(row.ciphertext, row.id);
    const secret = parseModelSecret(plaintext);
    if (secret.kind !== "openai_compatible" || !secret.externalAccount) continue;
    const capabilities = modelCredentialDto(credential, plaintext);
    for (const id of secret.enabledModelIds ?? []) {
      const existing = entries.get(id);
      entries.set(id, {
        provider: OPENAI_COMPATIBLE_PROVIDER_ID,
        providerName: "Model account",
        id,
        label: id,
        billing: "",
        credentialIds: [...(existing?.credentialIds ?? []), credential.id],
        reasoning: secret.reasoning,
        thinkingLevels: capabilities.thinkingLevels,
      });
    }
  }
  return [...entries.values()];
}
