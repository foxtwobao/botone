import { createHash } from "node:crypto";
import type { JobPublisher } from "@rakazo/adapter-kit";
import {
  ExternalModelAccountError,
  modelAccountAuthorizationCheckpoint,
} from "@rakazo/adapter-kit";
import {
  configuredModelAccount,
  createExternalModelKeyResolver,
  EncryptedSecretStore,
  parseModelSecret,
  pauseModelAccountRun,
} from "@rakazo/adapters";
import type { Auth } from "@rakazo/auth";
import { readExternalAccountIdentity } from "@rakazo/auth";
import type { PrismaClient } from "@rakazo/db";
import { asSystem, createDb, createThreadEvents } from "@rakazo/db";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { resolveModelKey } from "../../../packages/adapters/src/run-model.js";
import { modelAccountRoutes } from "./model-account.js";

const databaseUrl = process.env.DATABASE_URL;
const postgres = process.env.VERIFY_DATABASE && databaseUrl ? describe.sequential : describe.skip;
const origin = "https://app.example.test";
const issuer = "https://identity.example.test";
const key = "offline-test-secret-at-least-32-characters";
const userId = "model-account-fixture-user";
const accountId = "model-account-fixture-account";
const spaceId = "model-account-fixture-space";
const sessionId = "model-account-fixture-session";
const binding = createHash("sha256")
  .update(JSON.stringify([issuer, "subject"]))
  .digest("hex");
const idToken = `header.${Buffer.from(JSON.stringify({ iss: issuer, sub: "subject" })).toString("base64url")}.signature`;
const config = {
  provider: "reseller",
  origin: "https://accounts.example.test",
  credential: "fake-credential",
  authorizationOrigins: ["https://gateway.example.test"],
  homeUrl: "https://home.example.test/",
  rechargeUrl: "https://wallet.example.test/",
  modelId: "example-model",
  model: { kind: "openai_compatible", baseUrl: "https://models.example.test/v1" },
};

postgres("external model account isolated PostgreSQL", () => {
  let db: ReturnType<typeof createDb>;
  let prisma: PrismaClient;
  let app: ReturnType<typeof modelAccountRoutes>;
  const enqueue = vi.fn<JobPublisher["enqueue"]>(async () => undefined);
  const jobs: JobPublisher = { enqueue, cancel: vi.fn(), close: async () => undefined };
  const secrets = new EncryptedSecretStore("fixture-encryption-key");
  const connection = configuredModelAccount(JSON.stringify(config))!;
  let authorized = false;
  let authorizedState = "";
  const ensure = vi.spyOn(connection.provider, "ensure").mockImplementation(async () => {
    if (!authorized) throw new ExternalModelAccountError("authorization_required");
    return { apiKey: "fake-model-key" };
  });
  const complete = vi.spyOn(connection.provider, "complete").mockImplementation(async () => {
    authorized = true;
  });
  vi.spyOn(connection.provider, "authorize").mockImplementation(async (input) => {
    authorizedState = input.state;
    return { url: "https://gateway.example.test/authorize", expiresIn: 300 };
  });
  vi.spyOn(connection.provider, "revoke").mockImplementation(async () => {
    authorized = false;
  });
  vi.spyOn(connection.provider, "balance").mockResolvedValue({ amount: "-12.34", unit: "CNY" });
  const request = (path: string, options: RequestInit = {}) =>
    app.request(`https://api.example.test${path}`, {
      ...options,
      headers: {
        origin,
        authorization: "Bearer fixture-session",
        "x-rakazo-space-id": spaceId,
        "content-type": "application/json",
        ...Object.fromEntries(new Headers(options.headers)),
      },
    });
  const begin = async () => {
    const response = await request("/connect", { method: "POST", body: "{}" });
    expect(response.status).toBe(200);
    const body = await response.json();
    const launch = await request(`/launch${new URL(body.url).search}`);
    expect(launch.status).toBe(302);
    const cookie = launch.headers.getSetCookie()[0]!.split(";")[0]!;
    return {
      cookie,
      callback: `/callback?state=${authorizedState}&code=fixture-code`,
      url: body.url,
    };
  };
  beforeAll(async () => {
    db = createDb(databaseUrl!);
    prisma = asSystem(db.prisma);
    const createdAt = new Date();
    await prisma.user.create({
      data: {
        id: userId,
        name: "Fixture",
        email: "model-account@fixture.test",
        emailVerified: true,
      },
    });
    await prisma.organization.create({
      data: {
        id: "model-account-fixture-org",
        name: "Fixture",
        slug: "model-account-fixture-org",
        createdAt,
      },
    });
    await prisma.space.create({
      data: {
        id: spaceId,
        organizationId: "model-account-fixture-org",
        name: "Fixture",
        isDefault: true,
      },
    });
    await prisma.member.create({
      data: {
        id: "model-account-fixture-member",
        userId,
        organizationId: "model-account-fixture-org",
        role: "owner",
        createdAt,
      },
    });
    await prisma.account.create({
      data: { id: accountId, userId, accountId: binding, providerId: "oidc", idToken },
    });
    await prisma.session.create({
      data: {
        id: sessionId,
        token: "fixture-session",
        userId,
        expiresAt: new Date(Date.now() + 3600_000),
      },
    });
    await prisma.bot.create({
      data: { id: "model-account-bot", userId, spaceId, name: "Fixture", color: "test" },
    });
    await prisma.thread.create({
      data: { id: "model-account-thread", userId, spaceId, botId: "model-account-bot" },
    });
    const auth = {
      externalAccountIdentity: (id: string) => readExternalAccountIdentity(prisma, id, issuer, key),
      api: {
        getSession: async ({ headers }: { headers: Headers }) => {
          if (headers.get("authorization") !== "Bearer fixture-session") return null;
          const session = await prisma.session.findUnique({ where: { id: sessionId } });
          return session && { session, user: { id: userId } };
        },
      },
    } as unknown as Auth;
    app = modelAccountRoutes({
      jobs,
      connection,
      prisma,
      auth,
      secrets,
      webOrigin: origin,
      authUrl: "https://api.example.test",
    });
  });
  beforeEach(async () => {
    authorized = false;
    enqueue.mockClear();
    await prisma.task.deleteMany({ where: { userId } });
    complete.mockClear();
    ensure.mockClear();
    vi.mocked(connection.provider.authorize).mockClear();
    await prisma.userModelCredential.deleteMany({ where: { userId } });
    await prisma.modelOAuthSession.deleteMany({ where: { userId } });
    await prisma.session.update({
      where: { id: sessionId },
      data: { expiresAt: new Date(Date.now() + 3600_000) },
    });
    await prisma.account.update({ where: { id: accountId }, data: { accountId: binding } });
  });
  afterAll(async () => {
    if (!db) return;
    await prisma.organization.delete({ where: { id: "model-account-fixture-org" } });
    await prisma.user.delete({ where: { id: userId } });
    await db.prisma.$disconnect();
    await db.pool.end();
  });

  it("authorizes, saves only an account reference, and resolves runtime keys without local billing", async () => {
    const flow = await begin();
    const callback = await request(flow.callback, { headers: { cookie: flow.cookie } });
    expect(callback.status).toBe(302);
    expect(callback.headers.get("location")).toBe(`${origin}/app`);
    const credential = await prisma.userModelCredential.findUniqueOrThrow({
      where: { id: `external-${accountId}` },
    });
    const stored = await prisma.secret.findUniqueOrThrow({ where: { id: credential.secretId } });
    const plaintext = await secrets.load(stored.ciphertext, stored.id);
    expect(plaintext).not.toContain("fake-model-key");
    expect(plaintext).not.toContain("subject");
    expect(parseModelSecret(plaintext)).toMatchObject({ externalAccount: { accountId, binding } });
    const externalModelKey = createExternalModelKeyResolver(
      connection.provider,
      connection.model.baseUrl,
      (id) => readExternalAccountIdentity(prisma, id, issuer, key),
    );
    const resolved = await resolveModelKey(
      { prisma, secretStore: secrets, externalModelKey, billingEnabled: false } as never,
      userId,
      spaceId,
      credential,
      credential.provider,
      config.modelId,
    );
    expect(resolved.apiKey).toBe("fake-model-key");
    expect(resolved.callObserver).toBeUndefined();
    expect(await prisma.billingAuditEvent.count()).toBe(0);
    expect((await request(flow.callback, { headers: { cookie: flow.cookie } })).status).toBe(400);
    expect(complete).toHaveBeenCalledTimes(1);
    await request("/connect", { method: "POST", body: "{}" });
    expect(await prisma.userModelCredential.count({ where: { userId } })).toBe(1);
    expect(await (await request("/revoke", { method: "POST" })).json()).toEqual({
      connected: false,
    });
    expect(await prisma.userModelCredential.count({ where: { userId } })).toBe(0);
    await expect(
      resolveModelKey(
        { prisma, secretStore: secrets, externalModelKey, billingEnabled: false } as never,
        userId,
        spaceId,
        credential,
        credential.provider,
        config.modelId,
      ),
    ).rejects.toThrow();
  });

  it("rejects a missing browser proof, expired original session and changed account", async () => {
    const flow = await begin();
    expect((await request(flow.callback)).status).toBe(400);
    await prisma.session.update({ where: { id: sessionId }, data: { expiresAt: new Date(0) } });
    expect((await request(flow.callback, { headers: { cookie: flow.cookie } })).status).toBe(400);
    expect(complete).not.toHaveBeenCalled();
  });

  it("rejects a changed identity without exchanging the code", async () => {
    const flow = await begin();
    await prisma.account.update({
      where: { id: accountId },
      data: { accountId: "changed-binding" },
    });
    expect((await request(flow.callback, { headers: { cookie: flow.cookie } })).status).toBe(403);
    expect(complete).not.toHaveBeenCalled();
  });

  it("binds native browser authorization without placing the app session in a URL", async () => {
    const started = await request("/connect", {
      method: "POST",
      body: "{}",
      headers: { origin: "rakazo://" },
    });
    const { url } = await started.json();
    expect(url).not.toContain("fixture-session");
    const launch = await request(`/launch${new URL(url).search}`);
    const cookie = launch.headers.getSetCookie()[0]!.split(";")[0]!;
    const callback = await request(`/callback?state=${authorizedState}&code=native-code`, {
      headers: { cookie, authorization: "" },
    });
    expect(callback.status).toBe(302);
    expect(callback.headers.get("location")).toBe("rakazo://model-authorization");
  });

  it("refuses cross-site writes, launch replay and duplicate callback parameters", async () => {
    expect(
      (
        await request("/connect", {
          method: "POST",
          headers: { origin: "https://evil.example.test" },
        })
      ).status,
    ).toBe(403);
    expect(
      (await request("/connect", { method: "POST", headers: { authorization: "" } })).status,
    ).toBe(401);
    const flow = await begin();
    expect((await request(`/launch${new URL(flow.url).search}`)).status).toBe(400);
    expect(
      (await request(`${flow.callback}&code=other`, { headers: { cookie: flow.cookie } })).status,
    ).toBe(400);
  });

  it("uses the existing desktop SSO completion URL and rejects external returns", async () => {
    const callbackURL = new URL("/sso/callback", origin);
    callbackURL.searchParams.set("nonce", "12345678-1234-1234-1234-123456789012");
    callbackURL.searchParams.set("returnTo", `${origin}/app`);
    const started = await request("/connect", {
      method: "POST",
      body: JSON.stringify({ callbackURL: callbackURL.href }),
    });
    const body = await started.json();
    const launch = await request(`/launch${new URL(body.url).search}`);
    const cookie = launch.headers.getSetCookie()[0]!.split(";")[0]!;
    const response = await request(`/callback?state=${authorizedState}&code=desktop-code`, {
      headers: { cookie },
    });
    expect(response.headers.get("location")).toBe(callbackURL.href);
    authorized = false;
    expect(
      (
        await request("/connect", {
          method: "POST",
          body: JSON.stringify({ callbackURL: "https://evil.example.test/app" }),
        })
      ).status,
    ).toBe(400);
  });

  it("keeps concurrent reconnects to one connection and removes superseded secrets", async () => {
    authorized = true;
    const replies = await Promise.all([
      request("/connect", { method: "POST", body: "{}" }),
      request("/connect", { method: "POST", body: "{}" }),
    ]);
    expect(replies.map((reply) => reply.status)).toEqual([200, 200]);
    expect(await prisma.userModelCredential.count({ where: { userId } })).toBe(1);
  });

  it("allows only one concurrent callback to exchange a code", async () => {
    const flow = await begin();
    const replies = await Promise.all([
      request(flow.callback, { headers: { cookie: flow.cookie } }),
      request(flow.callback, { headers: { cookie: flow.cookie } }),
    ]);
    expect(replies.map((reply) => reply.status).sort()).toEqual([302, 400]);
    expect(complete).toHaveBeenCalledTimes(1);
  });

  it("does not recreate a connection revoked during exchange", async () => {
    const flow = await begin();
    complete.mockImplementationOnce(async () => {
      expect((await request("/revoke", { method: "POST" })).status).toBe(200);
      authorized = true;
    });
    const response = await request(flow.callback, { headers: { cookie: flow.cookie } });
    expect(response.status).toBe(302);
    expect(new URL(response.headers.get("location")!).searchParams.get("error")).toBe(
      "result_unknown",
    );
    expect(await prisma.userModelCredential.count({ where: { userId } })).toBe(0);
  });

  it("recovers a lost exchange response by checking authorization", async () => {
    const flow = await begin();
    complete.mockImplementationOnce(async () => {
      authorized = true;
      throw new Error("lost response");
    });
    expect((await request(flow.callback, { headers: { cookie: flow.cookie } })).status).toBe(302);
    expect(complete).toHaveBeenCalledTimes(1);
  });

  it("rejects a transaction started with a replaced application credential", async () => {
    const flow = await begin();
    const version = connection.credentialVersion;
    connection.credentialVersion = "rotated";
    try {
      expect((await request(flow.callback, { headers: { cookie: flow.cookie } })).status).toBe(400);
      expect(complete).not.toHaveBeenCalled();
    } finally {
      connection.credentialVersion = version;
    }
  });

  it("restores only authorization-paused runs with their original ids", async () => {
    authorized = true;
    await request("/connect", { method: "POST", body: "{}" });
    authorized = false;
    const threadId = "model-account-thread";
    const botId = "model-account-bot";
    const task = await prisma.task.create({
      data: { userId, spaceId, threadId, botId, prompt: "Original work", status: "running" },
    });
    const run = await prisma.run.create({
      data: {
        userId,
        spaceId,
        threadId,
        botId,
        taskId: task.id,
        status: "running",
        trigger: "user",
        leaseOwner: "fixture-worker",
        leaseFence: 1,
        leaseExpiresAt: new Date(Date.now() + 60_000),
      },
    });
    const attempt = await prisma.attempt.create({
      data: { runId: run.id, status: "running", fence: 1 },
    });
    const checkpoint = modelAccountAuthorizationCheckpoint({ accountId, binding });
    const events = createThreadEvents(prisma);
    await pauseModelAccountRun(
      { prisma, events, jobs, secretStore: secrets },
      run,
      { attemptId: attempt.id, workerId: "fixture-worker", fence: 1 },
      { accountId, binding },
      null,
    );
    expect((await prisma.run.findUniqueOrThrow({ where: { id: run.id } })).status).toBe(
      "waiting_input",
    );
    expect(await (await request("/status")).json()).toMatchObject({
      connected: true,
      recovery: "authorization_required",
    });
    const other = await prisma.run.create({
      data: {
        userId,
        spaceId,
        threadId,
        botId,
        taskId: task.id,
        status: "waiting_input",
        trigger: "user",
        checkpoint: "approval-checkpoint",
      },
    });
    const completed = await prisma.run.create({
      data: {
        userId,
        spaceId,
        threadId,
        botId,
        taskId: task.id,
        status: "completed",
        trigger: "user",
        checkpoint,
      },
    });
    authorized = true;
    expect((await request("/connect", { method: "POST", body: "{}" })).status).toBe(200);
    expect((await prisma.run.findUniqueOrThrow({ where: { id: run.id } })).status).toBe("queued");
    expect((await prisma.run.findUniqueOrThrow({ where: { id: other.id } })).status).toBe(
      "waiting_input",
    );
    expect((await prisma.run.findUniqueOrThrow({ where: { id: completed.id } })).status).toBe(
      "completed",
    );
    expect(await prisma.run.count({ where: { taskId: task.id } })).toBe(3);
    expect(enqueue).toHaveBeenCalledTimes(1);
    await request("/connect", { method: "POST", body: "{}" });
    expect(enqueue).toHaveBeenCalledTimes(1);
  });

  it("recovers authorization that completed immediately before the run paused", async () => {
    authorized = true;
    await request("/connect", { method: "POST", body: "{}" });
    enqueue.mockClear();
    const credential = await prisma.userModelCredential.findUniqueOrThrow({
      where: { id: `external-${accountId}` },
    });
    const task = await prisma.task.create({
      data: {
        userId,
        spaceId,
        threadId: "model-account-thread",
        botId: "model-account-bot",
        prompt: "Original work",
        status: "running",
      },
    });
    const run = await prisma.run.create({
      data: {
        userId,
        spaceId,
        threadId: task.threadId,
        botId: task.botId,
        taskId: task.id,
        status: "running",
        trigger: "user",
        leaseOwner: "fixture-worker",
        leaseFence: 1,
      },
    });
    const attempt = await prisma.attempt.create({
      data: { runId: run.id, status: "running", fence: 1 },
    });
    await pauseModelAccountRun(
      {
        prisma,
        events: createThreadEvents(prisma),
        jobs,
        secretStore: secrets,
        externalModelKey: createExternalModelKeyResolver(
          connection.provider,
          connection.model.baseUrl,
          (id) => readExternalAccountIdentity(prisma, id, issuer, key),
        ),
      },
      run,
      { attemptId: attempt.id, workerId: "fixture-worker", fence: 1 },
      { accountId, binding },
      credential,
    );
    expect((await prisma.run.findUniqueOrThrow({ where: { id: run.id } })).status).toBe("queued");
    expect(enqueue).toHaveBeenCalledTimes(1);
    expect(await prisma.run.count({ where: { taskId: task.id } })).toBe(1);
  });

  it("keeps a failed revocation visible and retries it idempotently", async () => {
    authorized = true;
    await request("/connect", { method: "POST", body: "{}" });
    vi.mocked(connection.provider.revoke).mockRejectedValueOnce(new Error("lost reply"));
    const unknown = await request("/revoke", { method: "POST" });
    expect(unknown.status).toBe(503);
    expect(await unknown.json()).toEqual({ error: "result_unknown" });
    expect(await (await request("/status")).json()).toMatchObject({
      connected: false,
      recovery: "revocation_unknown",
    });
    expect((await request("/revoke", { method: "POST" })).status).toBe(200);
    expect(await (await request("/status")).json()).not.toHaveProperty("recovery");
  });

  it("recovers an unknown authorization without exchanging its code again", async () => {
    const flow = await begin();
    complete.mockImplementationOnce(async () => {
      authorized = true;
      throw new Error("lost reply");
    });
    ensure.mockRejectedValueOnce(new ExternalModelAccountError("unavailable"));
    const reply = await request(flow.callback, { headers: { cookie: flow.cookie } });
    expect(new URL(reply.headers.get("location")!).searchParams.get("error")).toBe(
      "result_unknown",
    );
    expect(await (await request("/status")).json()).toMatchObject({
      recovery: "authorization_unknown",
    });
    expect((await request("/recover", { method: "POST" })).status).toBe(200);
    expect(await (await request("/status")).json()).not.toHaveProperty("recovery");
    expect(complete).toHaveBeenCalledTimes(1);
  });

  it("never starts authorization when recovery has no exchange or authorization is missing", async () => {
    expect((await request("/recover", { method: "POST" })).status).toBe(200);
    expect(ensure).not.toHaveBeenCalled();
    expect(connection.provider.authorize).not.toHaveBeenCalled();
    const flow = await begin();
    complete.mockRejectedValueOnce(new Error("lost reply"));
    await request(flow.callback, { headers: { cookie: flow.cookie } });
    const attempts = vi.mocked(connection.provider.authorize).mock.calls.length;
    const response = await request("/recover", { method: "POST" });
    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: "authorization_required" });
    expect(connection.provider.authorize).toHaveBeenCalledTimes(attempts);
    expect(complete).toHaveBeenCalledTimes(1);
    expect(await prisma.userModelCredential.count({ where: { userId } })).toBe(0);
  });

  it("requires the original identity and same-origin request for recovery", async () => {
    const flow = await begin();
    complete.mockRejectedValueOnce(new Error("lost reply"));
    await request(flow.callback, { headers: { cookie: flow.cookie } });
    expect(
      (
        await request("/recover", {
          method: "POST",
          headers: { origin: "https://other.example.test" },
        })
      ).status,
    ).toBe(403);
    await prisma.account.update({ where: { id: accountId }, data: { accountId: "changed" } });
    expect((await request("/recover", { method: "POST" })).status).toBe(403);
    expect(await prisma.userModelCredential.count({ where: { userId } })).toBe(0);
  });

  it("does not restore a connection revoked during automatic confirmation", async () => {
    const flow = await begin();
    complete.mockRejectedValueOnce(new Error("lost reply"));
    await request(flow.callback, { headers: { cookie: flow.cookie } });
    ensure.mockImplementationOnce(async () => {
      expect((await request("/revoke", { method: "POST" })).status).toBe(200);
      return { apiKey: "fake-model-key" };
    });
    expect((await request("/recover", { method: "POST" })).status).toBe(503);
    expect(await prisma.userModelCredential.count({ where: { userId } })).toBe(0);
    expect(enqueue).not.toHaveBeenCalled();
  });

  it("returns exact balances and no private platform configuration", async () => {
    expect(await (await request("/balance")).json()).toEqual({ amount: "-12.34", unit: "CNY" });
    const publicConfig = await (await request("/config")).text();
    expect(publicConfig).not.toContain("fake-credential");
    expect(publicConfig).not.toContain("subject");
  });
});
