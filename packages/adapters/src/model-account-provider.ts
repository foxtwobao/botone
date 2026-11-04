/** Identity read from an application's verified, persisted external account binding. */
export interface ExternalAccountIdentity {
  issuer: string;
  subject: string;
}

/** Server-only access to a user's externally authorized model account. */
export interface ExternalModelAccountProvider {
  ensure(identity: ExternalAccountIdentity, signal?: AbortSignal): Promise<{ apiKey: string }>;
  authorize(
    input: {
      identity: ExternalAccountIdentity;
      redirectUri: string;
      state: string;
      codeChallenge: string;
    },
    signal?: AbortSignal,
  ): Promise<{ url: string; expiresIn: number }>;
  complete(input: { code: string; codeVerifier: string }, signal?: AbortSignal): Promise<void>;
  revoke(identity: ExternalAccountIdentity, signal?: AbortSignal): Promise<void>;
  balance(
    identity: ExternalAccountIdentity,
    signal?: AbortSignal,
  ): Promise<{ amount: string; unit: string }>;
}

export class ExternalModelAccountError extends Error {
  constructor(
    readonly reason: "authorization_required" | "rejected" | "unavailable",
    readonly retryable = false,
  ) {
    super(
      reason === "authorization_required"
        ? "Authorize the model account in Settings."
        : "Model account is unavailable. Try again later.",
    );
    this.name = "ExternalModelAccountError";
  }
}
