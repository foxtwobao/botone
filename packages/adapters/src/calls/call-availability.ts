import type { PrismaClient } from "@rakazo/db";

/** A deployment can deliver calls through its peripheral bridge or a user's voice connection. */
export async function canReceiveBotCall(
  prisma: Pick<PrismaClient, "userVoiceCredential">,
  userId: string,
): Promise<boolean> {
  const source = process.env;
  const enabled = source.PERIPHERAL_CALLS_ENABLED;
  // A separate worker can opt in without carrying the bridge's API credential.
  if (enabled === "true" || (enabled === undefined && source.PERIPHERAL_BRIDGE_SECRET?.trim()))
    return true;
  return Boolean(
    await prisma.userVoiceCredential.findFirst({
      where: { userId },
      select: { id: true },
    }),
  );
}
