import type { Prisma } from "@rakazo/db";

/** Shared homes must never receive one member's personal model credentials. */
export function personalComputerWhere(owner: {
  userId: string;
  spaceId: string;
}): Prisma.ComputerWhereInput {
  return {
    userId: owner.userId,
    spaceId: owner.spaceId,
    kind: "docker",
    scope: { in: ["team", "dedicated"] },
    space: {
      deletingAt: null,
      memberships: {
        some: { userId: owner.userId },
        none: { userId: { not: owner.userId } },
      },
    },
  };
}
