import { ExternalModelAccountError } from "@rakazo/adapter-kit";
import { describe, expect, it, vi } from "vitest";
import { ResellerModelAccountProvider } from "./reseller-model-account.js";

const identity = { issuer: "https://identity.example.test", subject: "subject-1" };
const config = {
  origin: "https://accounts.example.test",
  credential: "fake-application-credential",
  authorizationOrigins: ["https://gateway.example.test"],
};
function fixture(body: unknown, status = 200) {
  const fetch = vi.fn<typeof globalThis.fetch>(async () => Response.json(body, { status }));
  return { fetch, provider: new ResellerModelAccountProvider(config, fetch) };
}

describe("external model account protocol", () => {
  it("only obtains the user key and sends the exact identity contract", async () => {
    const { fetch, provider } = fixture({
      status: "ready",
      api_key: { key: "fake-user-key", id: "42" },
    });
    expect(await provider.ensure(identity)).toEqual({ apiKey: "fake-user-key" });
    expect(fetch).toHaveBeenCalledTimes(1);
    const [url, init] = fetch.mock.calls[0]!;
    expect(url).toBe("https://accounts.example.test/api/apps/keys/ensure");
    expect(JSON.parse(init!.body as string)).toEqual({ identity });
    expect(init).toMatchObject({
      method: "POST",
      redirect: "error",
      cache: "no-store",
      headers: { authorization: "Bearer fake-application-credential" },
    });
    expect(init!.signal).toBeInstanceOf(AbortSignal);
  });

  it("keeps large, negative and zero balances as exact decimal strings", async () => {
    for (const amount of ["999999999999999999.99", "-12.34", "0.00"]) {
      const { provider } = fixture({ data: { balance: { amount, unit: "QUOTA" } } });
      expect(await provider.balance(identity)).toEqual({ amount, unit: "QUOTA" });
    }
  });

  it("validates successful responses instead of inventing a key or zero balance", async () => {
    for (const body of [
      {},
      { data: { balance: { amount: 0, unit: "USD" } } },
      { data: { balance: { amount: "0.00", unit: "UNKNOWN" } } },
    ]) {
      await expect(fixture(body).provider.balance(identity)).rejects.toMatchObject({
        reason: "unavailable",
      });
    }
    await expect(
      fixture({ status: "ready", api_key: { key: "key\r\ninjected" } }).provider.ensure(identity),
    ).rejects.toMatchObject({ reason: "unavailable" });
  });

  it("only requests authorization for the exact ensure denial", async () => {
    const { provider } = fixture(
      { error: "APP_USER_AUTHORIZATION_REQUIRED", retryable: false },
      403,
    );
    await expect(provider.ensure(identity)).rejects.toMatchObject({
      reason: "authorization_required",
    });
    await expect(provider.balance(identity)).rejects.toMatchObject({ reason: "rejected" });
    await expect(
      fixture({ error: "OTHER_ERROR", retryable: false }, 403).provider.ensure(identity),
    ).rejects.toMatchObject({ reason: "rejected" });
  });

  it("does not automatically retry writes or expose upstream error details", async () => {
    const { fetch, provider } = fixture(
      { error: "APP_DATABASE_UNAVAILABLE", retryable: true, detail: "private upstream detail" },
      503,
    );
    const error = await provider
      .complete({ code: "fake-code", codeVerifier: "v".repeat(43) })
      .catch((error) => error);
    expect(error).toBeInstanceOf(ExternalModelAccountError);
    expect(error).toMatchObject({ reason: "unavailable", retryable: true });
    expect(String(error)).not.toContain("private");
    expect(fetch).toHaveBeenCalledTimes(1);
    await expect(
      fixture({ error: "OTHER_ERROR", retryable: true }, 503).provider.ensure(identity),
    ).rejects.toMatchObject({ retryable: false });
  });

  it("does not interpret an application credential failure as expired local login", async () => {
    await expect(
      fixture({ error: "INVALID_CREDENTIAL", retryable: false }, 401).provider.balance(identity),
    ).rejects.toMatchObject({ reason: "rejected", retryable: false });
  });

  it("starts authorization with PKCE and validates the returned browser destination", async () => {
    const input = {
      identity,
      redirectUri: "https://app.example.test/auth/model/callback",
      state: "s".repeat(43),
      codeChallenge: "c".repeat(43),
    };
    const { fetch, provider } = fixture({
      authorization_url: "https://gateway.example.test/start?flow=fake",
      expires_in: 300,
    });
    expect(await provider.authorize(input)).toEqual({
      url: "https://gateway.example.test/start?flow=fake",
      expiresIn: 300,
    });
    expect(JSON.parse(fetch.mock.calls[0]![1]!.body as string)).toEqual({
      identity,
      redirect_uri: input.redirectUri,
      state: input.state,
      code_challenge: input.codeChallenge,
    });
    for (const url of [
      "https://evil.example.test/start",
      "http://gateway.example.test/start",
      "https://user:pass@gateway.example.test/start",
      "malformed",
    ]) {
      await expect(
        fixture({ authorization_url: url, expires_in: 300 }).provider.authorize(input),
      ).rejects.toMatchObject({ reason: "unavailable" });
    }
  });

  it("completes and revokes without returning provider payloads", async () => {
    const completed = fixture({ status: "authorized", app_id: "example" });
    await expect(
      completed.provider.complete({ code: "code", codeVerifier: "v".repeat(43) }),
    ).resolves.toBeUndefined();
    expect(JSON.parse(completed.fetch.mock.calls[0]![1]!.body as string)).toEqual({
      code: "code",
      code_verifier: "v".repeat(43),
    });
    await expect(fixture({ status: "revoked" }).provider.revoke(identity)).resolves.toBeUndefined();
    await expect(fixture({}).provider.revoke(identity)).rejects.toMatchObject({
      reason: "unavailable",
    });
  });

  it("rejects invalid local input before sending credentials", async () => {
    const { fetch, provider } = fixture({});
    await expect(provider.ensure({ ...identity, subject: " " })).rejects.toThrow();
    await expect(provider.ensure({ ...identity, subject: "x".repeat(501) })).rejects.toThrow();
    await expect(provider.complete({ code: "code", codeVerifier: "short" })).rejects.toThrow();
    expect(fetch).not.toHaveBeenCalled();
    expect(
      () =>
        new ResellerModelAccountProvider({
          ...config,
          origin: "https://accounts.example.test/other",
        }),
    ).toThrow();
  });

  it("contains network errors and propagates caller cancellation to the transport", async () => {
    const controller = new AbortController();
    controller.abort();
    const fetch = vi.fn<typeof globalThis.fetch>(async (_url, init) => {
      expect(init!.signal!.aborted).toBe(true);
      throw new Error("network details including secrets");
    });
    await expect(
      new ResellerModelAccountProvider(config, fetch).ensure(identity, controller.signal),
    ).rejects.toThrow("Model account is unavailable. Try again later.");
    expect(fetch).toHaveBeenCalledTimes(1);
  });
});

it("uses validated HTTPS authorization URLs without requiring a deployment allowlist", async () => {
  const transport = vi.fn<typeof fetch>(async () =>
    Response.json({
      authorization_url: "https://channel.example.test/authorize?state=opaque",
      expires_in: 300,
    }),
  );
  const provider = new ResellerModelAccountProvider(
    { origin: config.origin, credential: config.credential },
    transport,
  );
  const input = {
    identity,
    redirectUri: "https://app.example.test/callback",
    state: "s".repeat(43),
    codeChallenge: "c".repeat(43),
  };
  expect((await provider.authorize(input)).url).toContain("https://channel.example.test/");
  for (const url of [
    "http://channel.example.test/",
    "javascript:alert(1)",
    "https://user:password@channel.example.test/",
    "https://channel.example.test/#token",
  ]) {
    transport.mockResolvedValueOnce(Response.json({ authorization_url: url, expires_in: 300 }));
    await expect(provider.authorize(input)).rejects.toThrow();
  }
});
