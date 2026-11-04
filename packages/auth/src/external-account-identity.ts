import type { PrismaClient } from "@rakazo/db";
import { isCurrentOidcAccount } from "./oidc.js";
import type { TokenKey } from "./token-storage.js";
import { openIdToken } from "./token-storage.js";

/** Reads a previously verified stored binding, not fresh authentication proof. */
export async function readOidcAccountIdentity(
  account: { providerId: string; accountId: string; idToken?: string | null },
  issuer: string | undefined,
  key: TokenKey,
) {
  if (!issuer || account.providerId !== "oidc") return null;
  const idToken = await openIdToken(key, account.idToken);
  if (!idToken || !(await isCurrentOidcAccount({ ...account, idToken }, issuer, key))) return null;
  try {
    const claims = JSON.parse(Buffer.from(idToken.split(".")[1] ?? "", "base64url").toString());
    return typeof claims.sub === "string" && claims.sub.trim().length > 0
      ? { issuer, subject: claims.sub }
      : null;
  } catch {
    return null;
  }
}

export async function readExternalAccountIdentity(
  prisma: Pick<PrismaClient, "account">,
  userId: string,
  issuer: string | undefined,
  key: TokenKey,
) {
  if (!issuer) return null;
  const accounts = await prisma.account.findMany({
    where: { userId, providerId: "oidc" },
    select: { id: true, providerId: true, accountId: true, idToken: true },
  });
  const identities = await Promise.all(
    accounts.map(async (account) => {
      const identity = await readOidcAccountIdentity(account, issuer, key);
      return identity ? { accountId: account.id, binding: account.accountId, ...identity } : null;
    }),
  );
  const current = identities.filter((identity) => identity !== null);
  return current.length === 1 ? current[0]! : null;
}
