import { createHash } from "node:crypto";
import { createServer } from "node:http";
import {
  computerInitializationGrant,
  configuredModelAccount,
  EncryptedSecretStore,
  parseModelSecret,
} from "@rakazo/adapters";
import type { Auth } from "@rakazo/auth";
import type { PrismaClient } from "@rakazo/db";
import { asSystem, createDb, runAsTenant } from "@rakazo/db";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { ensureAutomaticExecution } from "./automatic-execution.js";
import { modelAccountRoutes } from "./model-account.js";
import type { RouterDeps } from "./router.js";

const integration = process.env.VERIFY_DATABASE === "1" ? describe : describe.skip;
integration("computer initialization with persisted authorization", () => {
  const userId = "computer-init-user",
    spaceId = "computer-init-space",
    accountId = "computer-init-account";
  const homeKey = "computer-init-home",
    issuer = "https://identity.example.test",
    signingKey = "fake-computer-signing-key";
  const binding = createHash("sha256")
    .update(JSON.stringify([issuer, "fixture-subject"]))
    .digest("hex");
  let db: ReturnType<typeof createDb>,
    prisma: PrismaClient,
    app: ReturnType<typeof modelAccountRoutes>;
  const store = new EncryptedSecretStore("fake-encryption-key");
  const connection = configuredModelAccount(
    JSON.stringify({
      provider: "reseller",
      origin: "https://accounts.example.test",
      credential: "fake-app-key",
      baseUrl: "https://models.example.test/v1",
      defaults: { responses: "fixture-model" },
    }),
  )!;
  const ensure = vi.spyOn(connection.provider, "ensure");
  vi.spyOn(connection.provider, "revoke").mockResolvedValue();
  let rejectOriginal = false;
  const modelFetch = vi.fn<typeof fetch>(async (_url, init) =>
    new Headers(init?.headers).get("authorization") === "Bearer fake-original-key" && rejectOriginal
      ? new Response(null, { status: 401 })
      : Response.json({ data: [{ id: "fixture-model" }] }),
  );
  const request = (route: string, token = "fixture-session") =>
    app.request(`https://app.example.test${route}`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        origin: "https://app.example.test",
        "x-rakazo-space-id": spaceId,
      },
    });
  const grant = async () => {
    const credential = await prisma.userModelCredential.findUniqueOrThrow({
      where: { id: `external-${accountId}` },
    });
    return computerInitializationGrant(signingKey, {
      userId,
      spaceId,
      homeKey,
      credentialId: credential.id,
      credentialCreatedAt: credential.createdAt.toISOString(),
    });
  };
  beforeAll(async () => {
    db = createDb(process.env.DATABASE_URL!);
    prisma = asSystem(db.prisma);
    await prisma.user.create({
      data: {
        id: userId,
        email: "computer-init@fixture.test",
        name: "Fixture",
        emailVerified: true,
      },
    });
    await prisma.organization.create({
      data: {
        id: "computer-init-org",
        name: "Fixture",
        slug: "computer-init-org",
        createdAt: new Date(),
      },
    });
    await prisma.space.create({
      data: { id: spaceId, organizationId: "computer-init-org", name: "Fixture", isDefault: true },
    });
    await prisma.member.create({
      data: {
        id: "computer-init-member",
        organizationId: "computer-init-org",
        userId,
        role: "owner",
        createdAt: new Date(),
      },
    });
    const idToken = `header.${Buffer.from(JSON.stringify({ iss: issuer, sub: "fixture-subject" })).toString("base64url")}.signature`;
    await prisma.account.create({
      data: { id: accountId, userId, providerId: "oidc", accountId: binding, idToken },
    });
    await prisma.session.create({
      data: {
        id: "computer-init-session",
        token: "fixture-session",
        userId,
        expiresAt: new Date(Date.now() + 3600000),
      },
    });
    await prisma.computer.create({
      data: {
        id: "computer-init-computer",
        userId,
        spaceId,
        scope: "dedicated",
        scopeKey: "computer-init-scope",
        homeKey,
        kind: "docker",
        state: "running",
        providerRef: "fake-container",
      },
    });
    const auth = {
      $context: Promise.resolve({ secretConfig: "fake-auth-secret" }),
      api: {
        getSession: async ({ headers }: { headers: Headers }) =>
          headers.get("authorization") === "Bearer fixture-session"
            ? {
                session: await prisma.session.findUniqueOrThrow({
                  where: { id: "computer-init-session" },
                }),
                user: { id: userId },
              }
            : null,
      },
    } as unknown as Auth;
    app = modelAccountRoutes({
      prisma,
      auth,
      secrets: store,
      connection,
      initializationKey: signingKey,
      executionConnection: JSON.stringify({
        url: "https://execution.example.test",
        token: "a".repeat(64),
      }),
      issuer,
      modelFetch,
      webOrigin: "https://app.example.test",
      authUrl: "https://app.example.test",
    });
  });
  beforeEach(async () => {
    rejectOriginal = false;
    ensure.mockReset().mockResolvedValue({ apiKey: "fake-original-key" });
    modelFetch.mockClear();
    await prisma.computer.update({
      where: { id: "computer-init-computer" },
      data: { scope: "dedicated" },
    });
    expect((await request("/connect")).status).toBe(200);
    ensure.mockClear();
  });
  afterAll(async () => {
    if (!db) return;
    await prisma.organization.delete({ where: { id: "computer-init-org" } });
    await prisma.user.delete({ where: { id: userId } });
    await db.prisma.$disconnect();
    await db.pool.end();
  });

  it("replaces an invalid encrypted key without changing its authorization record", async () => {
    const token = await grant();
    const before = await prisma.userModelCredential.findUniqueOrThrow({
      where: { id: `external-${accountId}` },
    });
    rejectOriginal = true;
    ensure.mockResolvedValueOnce({ apiKey: "fake-recovered-key" });
    const response = await request("/computer", token);
    expect(response.status).toBe(200);
    expect((await response.json()).apiKey).toBe("fake-recovered-key");
    expect(ensure).toHaveBeenCalledOnce();
    const after = await prisma.userModelCredential.findUniqueOrThrow({ where: { id: before.id } });
    expect(after.createdAt).toEqual(before.createdAt);
    expect(after.secretId).not.toBe(before.secretId);
    const stored = await prisma.secret.findUniqueOrThrow({ where: { id: after.secretId } });
    expect(stored.ciphertext).not.toContain("fake-recovered-key");
    expect(parseModelSecret(await store.load(stored.ciphertext, stored.id))).toMatchObject({
      apiKey: "fake-recovered-key",
    });
  });

  it("rejects a copied capability after disconnect and after a new authorization", async () => {
    const token = await grant();
    expect((await request("/revoke")).status).toBe(200);
    expect((await request("/computer", token)).status).toBe(401);
    expect((await request("/connect")).status).toBe(200);
    expect((await request("/computer", token)).status).toBe(401);
    expect((await request("/computer", await grant())).status).toBe(200);
  });

  it("initializes a personal team computer and revokes the grant when another member joins", async () => {
    const token = await grant();
    await prisma.computer.update({
      where: { id: "computer-init-computer" },
      data: { scope: "team" },
    });
    expect((await request("/computer", token)).status).toBe(200);
    const other = "computer-init-other";
    await prisma.user.create({ data: { id: other, email: "other@fixture.test", name: "Other" } });
    try {
      await prisma.member.create({
        data: {
          id: other,
          userId: other,
          organizationId: "computer-init-org",
          role: "member",
          createdAt: new Date(),
        },
      });
      modelFetch.mockClear();
      expect((await request("/computer", token)).status).toBe(403);
      expect(modelFetch).not.toHaveBeenCalled();
    } finally {
      await prisma.user.delete({ where: { id: other } });
    }
    expect(ensure).not.toHaveBeenCalled();
  });

  it("discovers only the granted computer and checks readiness without disclosing its model key", async () => {
    const discover = (
      token = "a".repeat(64),
      computerId = "computer-init-computer",
      origin?: string,
    ) =>
      app.request("/environment", {
        method: "POST",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
          ...(origin ? { origin } : {}),
        },
        body: JSON.stringify({ userId, spaceId, computerId }),
      });
    expect((await discover("b".repeat(64))).status).toBe(401);
    expect(
      (await discover("a".repeat(64), "computer-init-computer", "https://app.example.test")).status,
    ).toBe(401);
    expect((await discover("a".repeat(64), "other-computer")).status).toBe(403);
    const response = await discover();
    expect(response.status).toBe(200);
    const environment = await response.json();
    expect(JSON.stringify(environment)).not.toContain("fake-original-key");
    expect(environment).toMatchObject({
      userId,
      spaceId,
      homeKey,
      defaults: { responses: "fixture-model" },
    });
    const checked = await app.request("/computer", {
      method: "POST",
      headers: {
        authorization: `Bearer ${environment.initialization.token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ checkOnly: true }),
    });
    expect(checked.status).toBe(200);
    const body = await checked.json();
    expect(body.modelIds).toEqual(["fixture-model"]);
    expect(body).not.toHaveProperty("apiKey");
    expect(ensure).not.toHaveBeenCalled();
  });

  it("creates one automatic connection concurrently for an ordinary owner of a team computer", async () => {
    await prisma.computer.update({
      where: { id: "computer-init-computer" },
      data: { scope: "team" },
    });
    const server = createServer((_request, response) =>
      response.end(JSON.stringify({ id: "00000000-0000-4000-8000-000000000001", profiles: [] })),
    );
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("test_server");
    try {
      const deps = {
        prisma: db.prisma,
        secrets: store,
        env: {
          executionConnection: JSON.stringify({
            url: `http://127.0.0.1:${address.port}`,
            token: "a".repeat(64),
            allowPrivateEndpoint: true,
          }),
        },
      } as unknown as RouterDeps;
      const actor = {
        userId,
        spaceId,
        email: "computer-init@fixture.test",
        isDeploymentOwner: false,
      };
      await runAsTenant(actor, () =>
        Promise.all([
          ensureAutomaticExecution(deps, actor, "computer-init-computer"),
          ensureAutomaticExecution(deps, actor, "computer-init-computer"),
        ]),
      );
      const rows = await prisma.executionConnection.findMany({ where: { userId, spaceId } });
      expect(rows).toHaveLength(1);
      expect(rows[0]!.secretRef).not.toContain("a".repeat(64));
      await prisma.executionConnection.update({
        where: { id: rows[0]!.id },
        data: { revokedAt: new Date() },
      });
      await runAsTenant(actor, () =>
        ensureAutomaticExecution(deps, actor, "computer-init-computer"),
      );
      expect(
        await prisma.executionConnection.count({ where: { userId, spaceId, revokedAt: null } }),
      ).toBe(0);
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });

  it("does not overwrite a newer authorization while recovering an old key", async () => {
    const token = await grant();
    rejectOriginal = true;
    ensure.mockImplementationOnce(async () => {
      ensure.mockResolvedValueOnce({ apiKey: "fake-newer-authorization-key" });
      expect((await request("/connect")).status).toBe(200);
      return { apiKey: "fake-obsolete-recovered-key" };
    });
    expect((await request("/computer", token)).status).toBe(409);
    const credential = await prisma.userModelCredential.findUniqueOrThrow({
      where: { id: `external-${accountId}` },
    });
    const stored = await prisma.secret.findUniqueOrThrow({ where: { id: credential.secretId } });
    expect(parseModelSecret(await store.load(stored.ciphertext, stored.id))).toMatchObject({
      apiKey: "fake-newer-authorization-key",
    });
  });
});
