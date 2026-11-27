import { findLinkedOidcAccount } from "@rakazo/auth/identity";
import { runAsSystem } from "@rakazo/db";
import type { RouterDeps } from "../router.js";

export function resolvePeripheralActor(
  { prisma, auth }: Pick<RouterDeps, "prisma" | "auth">,
  identity: { issuer: string; subject: string },
) {
  return runAsSystem("resolve a peripheral's linked account and its default Space", async () => {
    const account = await findLinkedOidcAccount(
      prisma,
      identity,
      (await auth.$context).secretConfig,
    );
    if (!account) return null;
    const membership = await prisma.spaceMember.findFirst({
      where: {
        userId: account.user.id,
        role: "owner",
        space: { isDefault: true, createdByUserId: account.user.id, deletingAt: null },
      },
      orderBy: [{ space: { createdAt: "asc" } }, { spaceId: "asc" }],
      select: { spaceId: true },
    });
    if (!membership) return null;
    return {
      actor: {
        userId: account.user.id,
        email: account.user.email,
        spaceId: membership.spaceId,
        isDeploymentOwner: false,
      },
      accountId: account.id,
    };
  });
}
