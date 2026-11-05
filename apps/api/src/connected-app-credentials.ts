import type { UserAccessCredential } from "@rakazo/adapters";
import { ApplicationCredentialError } from "@rakazo/adapters";
import type { Auth } from "@rakazo/auth";
import { readExternalAccountIdentity } from "@rakazo/auth/identity";
import type { PrismaClient } from "@rakazo/db";

/** Reuse the verified account and Better Auth's encrypted-token refresh path. */
export function userAppCredentialReader(prisma: PrismaClient, auth: Auth, issuer?: string) {
  return async (userId: string): Promise<UserAccessCredential | null> => {
    const authSecret = (await auth.$context).secretConfig;
    const current = () => readExternalAccountIdentity(prisma, userId, issuer, authSecret);
    const identity = await current();
    if (!identity) return null;
    const token = async (refresh: boolean) => {
      const before = await current();
      if (before?.accountId !== identity.accountId || before.binding !== identity.binding)
        throw new ApplicationCredentialError("account_changed", 409);
      const input = { body: { userId, accountId: identity.accountId } };
      const result = await (refresh
        ? auth.api.refreshToken(input)
        : auth.api.getAccessToken(input)
      ).catch((error: unknown) => {
        const code = (error as { body?: { code?: string } })?.body?.code;
        if (
          code &&
          ["ACCOUNT_NOT_FOUND", "REFRESH_TOKEN_NOT_FOUND", "INVALID_TOKEN"].includes(code)
        )
          throw new ApplicationCredentialError("authentication_required", 401);
        throw new ApplicationCredentialError("authentication_unavailable", 503);
      });
      const after = await current();
      if (after?.accountId !== identity.accountId || after.binding !== identity.binding)
        throw new ApplicationCredentialError("account_changed", 409);
      if (
        !result.accessToken ||
        (result.accessTokenExpiresAt &&
          new Date(result.accessTokenExpiresAt).getTime() <= Date.now())
      )
        throw new ApplicationCredentialError("authentication_required", 401);
      return result.accessToken;
    };
    return {
      accountId: identity.accountId,
      binding: identity.binding,
      accessToken: () => token(false),
      refreshAccessToken: () => token(true),
    };
  };
}
