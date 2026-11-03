import type {
  ExternalAccountIdentity,
  ExternalModelAccountProvider,
  ExternalModelKeyResolver,
} from "@rakazo/adapter-kit";
import { ExternalModelAccountError } from "@rakazo/adapter-kit";

export function createExternalModelKeyResolver(
  provider: ExternalModelAccountProvider,
  baseUrl: string,
  identityForUser: (
    userId: string,
  ) => Promise<(ExternalAccountIdentity & { accountId: string; binding: string }) | null>,
): ExternalModelKeyResolver {
  return async (userId, reference, requestedBaseUrl, signal) => {
    if (requestedBaseUrl !== baseUrl) throw new ExternalModelAccountError("rejected");
    const identity = await identityForUser(userId);
    if (
      !identity ||
      identity.accountId !== reference.accountId ||
      identity.binding !== reference.binding
    )
      throw new ExternalModelAccountError("authorization_required", false, reference);
    try {
      return (await provider.ensure({ issuer: identity.issuer, subject: identity.subject }, signal))
        .apiKey;
    } catch (error) {
      if (error instanceof ExternalModelAccountError && error.reason === "authorization_required")
        throw new ExternalModelAccountError("authorization_required", false, reference);
      throw error;
    }
  };
}
