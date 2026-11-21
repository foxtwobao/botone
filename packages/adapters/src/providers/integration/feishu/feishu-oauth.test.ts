import { afterEach, describe, expect, it, vi } from "vitest";
import { exchangeFeishuCode } from "./feishu-oauth.js";

afterEach(() => vi.unstubAllGlobals());

const config = {
  appId: "cli_synthetic",
  appSecret: "synthetic",
  domain: "feishu" as const,
  identity: "user" as const,
  name: "Feishu",
};

describe("feishu oauth token exchange", () => {
  it("parses a large token response (two JWTs plus scope) without truncating", async () => {
    const jwt = "x".repeat(6_000);
    const scope = "some:scope ".repeat(400);
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        Response.json({
          code: 0,
          token_type: "Bearer",
          access_token: jwt,
          refresh_token: jwt,
          refresh_token_expires_in: 604_800,
          expires_in: 7_200,
          scope,
        }),
      ),
    );
    const token = await exchangeFeishuCode(
      config,
      "auth-code",
      "http://localhost:3000/callback",
      new AbortController().signal,
    );
    expect(token.accessToken).toBe(jwt);
    expect(token.refreshToken).toBe(jwt);
    expect(token.expiresAt).toBeGreaterThan(Date.now());
  });
});
