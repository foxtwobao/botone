import type { ExternalAccountIdentity, ExternalModelAccountProvider } from "@rakazo/adapter-kit";
import { ExternalModelAccountError } from "@rakazo/adapter-kit";
import { readBoundedJsonResponse } from "@rakazo/core";
import { z } from "zod";

const identitySchema = z.object({ issuer: z.url(), subject: z.string().min(1) });
const keySchema = z.object({
  status: z.literal("ready"),
  api_key: z.object({
    key: z
      .string()
      .min(1)
      .regex(/^[!-~]+$/),
  }),
});
const authorizationSchema = z.object({
  authorization_url: z.string(),
  expires_in: z.number().int().positive().max(300),
});
const balanceSchema = z.object({
  data: z.object({
    balance: z.object({
      amount: z.string().regex(/^-?\d+\.\d{2}$/),
      unit: z.enum(["USD", "CNY", "QUOTA"]),
    }),
  }),
});

export interface ResellerModelAccountConfig {
  origin: string;
  credential: string;
  /** Exact trusted origins to which the browser may be sent for model authorization. */
  authorizationOrigins?: string[];
}

export class ResellerModelAccountProvider implements ExternalModelAccountProvider {
  private readonly origin: string;
  private readonly authorizationOrigins: Set<string> | undefined;

  constructor(
    private readonly config: ResellerModelAccountConfig,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {
    this.origin = httpsOrigin(config.origin);
    this.authorizationOrigins = config.authorizationOrigins
      ? new Set(config.authorizationOrigins.map(httpsOrigin))
      : undefined;
    if (!/^[!-~]+$/.test(config.credential)) throw new Error("Invalid model account credential");
    if (this.authorizationOrigins && !this.authorizationOrigins.size)
      throw new Error("Missing authorization origins");
  }

  async ensure(identity: ExternalAccountIdentity, signal?: AbortSignal) {
    const body = await this.request("keys/ensure", { identity: checkedIdentity(identity) }, signal);
    const result = keySchema.safeParse(body);
    if (!result.success) throw new ExternalModelAccountError("unavailable");
    return { apiKey: result.data.api_key.key };
  }

  async authorize(
    input: {
      identity: ExternalAccountIdentity;
      redirectUri: string;
      state: string;
      codeChallenge: string;
    },
    signal?: AbortSignal,
  ) {
    const redirect = new URL(input.redirectUri);
    if (
      redirect.protocol !== "https:" ||
      redirect.username ||
      redirect.password ||
      redirect.search ||
      redirect.hash
    )
      throw new Error("Invalid authorization callback");
    if (
      !/^[A-Za-z0-9_-]{32,256}$/.test(input.state) ||
      !/^[A-Za-z0-9_-]{43}$/.test(input.codeChallenge)
    )
      throw new Error("Invalid authorization transaction");
    const body = await this.request(
      "authorizations",
      {
        identity: checkedIdentity(input.identity),
        redirect_uri: input.redirectUri,
        state: input.state,
        code_challenge: input.codeChallenge,
      },
      signal,
    );
    const result = authorizationSchema.safeParse(body);
    if (!result.success) throw new ExternalModelAccountError("unavailable");
    let url: URL;
    try {
      url = new URL(result.data.authorization_url);
    } catch {
      throw new ExternalModelAccountError("unavailable");
    }
    if (
      url.protocol !== "https:" ||
      url.username ||
      url.password ||
      (this.authorizationOrigins && !this.authorizationOrigins.has(url.origin)) ||
      url.hash
    )
      throw new ExternalModelAccountError("unavailable");
    return { url: url.href, expiresIn: result.data.expires_in };
  }

  async complete(input: { code: string; codeVerifier: string }, signal?: AbortSignal) {
    if (!input.code || !/^[A-Za-z0-9._~-]{43,128}$/.test(input.codeVerifier))
      throw new Error("Invalid authorization result");
    const body = await this.request(
      "authorizations/complete",
      {
        code: input.code,
        code_verifier: input.codeVerifier,
      },
      signal,
    );
    if (!z.object({ status: z.literal("authorized") }).safeParse(body).success)
      throw new ExternalModelAccountError("unavailable");
  }

  async revoke(identity: ExternalAccountIdentity, signal?: AbortSignal) {
    const body = await this.request(
      "authorizations/revoke",
      { identity: checkedIdentity(identity) },
      signal,
    );
    if (!z.object({ status: z.literal("revoked") }).safeParse(body).success)
      throw new ExternalModelAccountError("unavailable");
  }

  async balance(identity: ExternalAccountIdentity, signal?: AbortSignal) {
    const body = await this.request(
      "balance/query",
      { identity: checkedIdentity(identity) },
      signal,
      7_000,
    );
    const result = balanceSchema.safeParse(body);
    if (!result.success) throw new ExternalModelAccountError("unavailable");
    return result.data.data.balance;
  }

  private async request(
    path: string,
    body: unknown,
    signal?: AbortSignal,
    timeoutMs = 35_000,
  ): Promise<unknown> {
    const timeout = AbortSignal.timeout(timeoutMs);
    try {
      const response = await this.fetchImpl(`${this.origin}/api/apps/${path}`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${this.config.credential}`,
          "content-type": "application/json",
        },
        body: JSON.stringify(body),
        redirect: "error",
        cache: "no-store",
        signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
      });
      const data = await readBoundedJsonResponse<unknown>(
        response,
        64 * 1024,
        signal ? AbortSignal.any([signal, timeout]) : timeout,
      );
      if (response.status !== 200) {
        const error = z.object({ error: z.string(), retryable: z.boolean() }).safeParse(data);
        if (
          path === "keys/ensure" &&
          response.status === 403 &&
          error.success &&
          error.data.error === "APP_USER_AUTHORIZATION_REQUIRED"
        )
          throw new ExternalModelAccountError("authorization_required");
        const retryable =
          response.status === 503 &&
          error.success &&
          error.data.retryable &&
          ["APP_SERVICE_UNAVAILABLE", "APP_DATABASE_UNAVAILABLE"].includes(error.data.error);
        throw new ExternalModelAccountError(
          response.status >= 500 ? "unavailable" : "rejected",
          retryable,
        );
      }
      return data;
    } catch (error) {
      if (error instanceof ExternalModelAccountError) throw error;
      throw new ExternalModelAccountError("unavailable");
    }
  }
}

function httpsOrigin(value: string) {
  const url = new URL(value);
  if (
    url.protocol !== "https:" ||
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    url.pathname !== "/"
  )
    throw new Error("Invalid model account origin");
  return url.origin;
}

function checkedIdentity(identity: ExternalAccountIdentity) {
  const parsed = identitySchema.parse(identity);
  if (Buffer.byteLength(parsed.subject) > 500 || !parsed.subject.trim())
    throw new Error("Invalid external account identity");
  return parsed;
}
