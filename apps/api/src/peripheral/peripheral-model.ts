import type { SecretStore } from "@rakazo/adapter-kit";
import {
  findConnectedModelCredential,
  resolveMemberMainModel,
  validateConnectedModelChoice,
} from "@rakazo/adapters";
import type { Actor } from "@rakazo/contracts";
import { OPENAI_COMPATIBLE_PROVIDER_ID } from "@rakazo/contracts";
import { timingSafeStringEqual } from "@rakazo/core/node/secrets-guard";
import type { PrismaClient } from "@rakazo/db";
import { parseModelAccountSecret } from "../model-account-secret.js";

export async function peripheralModel(
  { prisma, secrets }: { prisma: PrismaClient; secrets: Pick<SecretStore, "load"> },
  actor: Actor,
  accountId: string,
  ensuredKey: string,
  baseUrl: string,
  preferredModel?: string,
) {
  const main = preferredModel
    ? undefined
    : await resolveMemberMainModel({ prisma, secretStore: secrets }, actor);
  const modelId = preferredModel || main?.modelId;
  if (!modelId) return null;

  const modelProvider = OPENAI_COMPATIBLE_PROVIDER_ID;
  const credential = await findConnectedModelCredential(
    prisma,
    secrets,
    actor,
    modelProvider,
    modelId,
  );
  if (!credential || credential.id !== `external-${accountId}`) return null;
  const stored = await prisma.secret.findFirst({
    where: { id: credential.secretId, userId: actor.userId, spaceId: null },
    select: { id: true, ciphertext: true },
  });
  if (!stored) return null;
  const { secret, binding } = parseModelAccountSecret(
    await secrets.load(stored.ciphertext, stored.id),
  );
  if (
    binding?.accountId !== accountId ||
    secret.kind !== "openai_compatible" ||
    secret.baseUrl !== baseUrl ||
    !timingSafeStringEqual(secret.apiKey, ensuredKey)
  )
    return null;

  if (
    await validateConnectedModelChoice(prisma, secrets, actor, modelProvider, modelId, {
      credentialId: credential.id,
    })
  )
    return null;
  return { modelProvider, modelId };
}
