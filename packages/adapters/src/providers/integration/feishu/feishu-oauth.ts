import { z } from "zod";
import { readBoundedText } from "../../../integrations/connector-http.js";
import type { FeishuConnectionConfig } from "./feishu-contracts.js";
import { FeishuServiceError } from "./feishu-provider.js";

const DOMAINS = {
  feishu: "https://open.feishu.cn",
  lark: "https://open.larksuite.com",
} as const;

export const feishuTokenSchema = z.object({
  accessToken: z.string().min(1),
  refreshToken: z.string().min(1).optional(),
  expiresAt: z.number().int(),
});
export type FeishuUserToken = z.infer<typeof feishuTokenSchema>;

/** The scope list is the union of the enabled modules' scopes, plus identity and offline access. */
export function feishuAuthorizeUrl(
  config: FeishuConnectionConfig,
  redirectUri: string,
  state: string,
  scopes: string,
) {
  const base = DOMAINS[config.domain];
  const query = new URLSearchParams({
    app_id: config.appId,
    redirect_uri: redirectUri,
    response_type: "code",
    scope: scopes,
    state,
  });
  return `${base}/open-apis/authen/v1/authorize?${query}`;
}

async function tokenRequest(
  config: FeishuConnectionConfig,
  body: Record<string, unknown>,
  signal: AbortSignal,
  fetcher: typeof fetch,
): Promise<FeishuUserToken> {
  let response: Response;
  try {
    response = await fetcher(`${DOMAINS[config.domain]}/open-apis/authen/v2/oauth/token`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ client_id: config.appId, client_secret: config.appSecret, ...body }),
      redirect: "manual",
      signal,
    });
  } catch (error) {
    if (error instanceof FeishuServiceError) throw error;
    throw new FeishuServiceError("unavailable");
  }
  if (!response.ok || response.type === "opaqueredirect") {
    await response.body?.cancel();
    throw new FeishuServiceError("authorization_required", 403);
  }
  // The response carries two long JWTs plus the scope list; a small cap would truncate the JSON.
  const text = await readBoundedText(response, 262_144).catch(() => ({
    text: "",
    truncated: true,
  }));
  let parsed: unknown;
  try {
    parsed = JSON.parse(text.text);
  } catch {
    throw new FeishuServiceError("invalid_response");
  }
  const envelope = z
    .object({
      code: z.number().default(0),
      access_token: z.string().min(1),
      refresh_token: z.string().min(1).optional(),
      expires_in: z.number().int().positive(),
    })
    .safeParse(parsed);
  if (!envelope.success || envelope.data.code !== 0)
    throw new FeishuServiceError("authorization_required", 403);
  return {
    accessToken: envelope.data.access_token,
    ...(envelope.data.refresh_token ? { refreshToken: envelope.data.refresh_token } : {}),
    expiresAt: Date.now() + envelope.data.expires_in * 1000,
  };
}

export function exchangeFeishuCode(
  config: FeishuConnectionConfig,
  code: string,
  redirectUri: string,
  signal: AbortSignal,
  fetcher: typeof fetch = globalThis.fetch,
) {
  return tokenRequest(
    config,
    { grant_type: "authorization_code", code, redirect_uri: redirectUri },
    signal,
    fetcher,
  );
}

export function refreshFeishuToken(
  config: FeishuConnectionConfig,
  refreshToken: string,
  signal: AbortSignal,
  fetcher: typeof fetch = globalThis.fetch,
) {
  return tokenRequest(
    config,
    { grant_type: "refresh_token", refresh_token: refreshToken },
    signal,
    fetcher,
  );
}
