import { randomUUID } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import { DockerSandboxProvider } from "@rakazo/adapters";
import type { createApp } from "@rakazo/api/app";
import { afterAll, describe, expect, it } from "vitest";
import { asSystem } from "./system-db.js";

const integration = process.env.VERIFY_DATABASE === "1" ? describe : describe.skip;
integration("automatic execution application composition", () => {
  let app: Awaited<ReturnType<typeof createApp>> | undefined;
  let root: string | undefined;
  const scopes: unknown[] = [];
  const server = createServer((request, response) => {
    expect(request.url).toBe("/computers/fixture-container/execution/describe");
    expect(request.headers.authorization).toBe(`Bearer ${"a".repeat(64)}`);
    scopes.push(
      JSON.parse(Buffer.from(String(request.headers["x-execution-scope"]), "base64url").toString()),
    );
    response.end(JSON.stringify({ id: "00000000-0000-4000-8000-000000000001", profiles: [] }));
  });
  afterAll(async () => {
    await app?.stop();
    if (server.listening) await new Promise<void>((resolve) => server.close(() => resolve()));
    if (root) await rm(root, { recursive: true, force: true });
  });

  it("uses the computer provider connection for ordinary-user discovery without execution configuration", async () => {
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("test_server");
    root = await mkdtemp(path.join(tmpdir(), "automatic-execution-"));
    const { createApp } = await import("@rakazo/api/app");
    app = await createApp({
      databaseUrl: process.env.DATABASE_URL!,
      dataDir: root,
      sandboxProvider: "fake",
      agentRuntime: "scripted",
      wakeupDriver: "memory",
      deploymentModelConfigured: false,
      adminEmails: [],
      encryptionKey: "fake-encryption-key",
      stripeSecretKey: undefined,
      stripeWebhookSecret: undefined,
      oidc: {
        issuer: "https://identity.example.test",
        clientId: "fixture",
        clientSecret: "fake-secret",
        name: "SSO",
        scopes: [],
        allowSignupBypass: false,
      },
      modelAccountConnection: JSON.stringify({
        provider: "reseller",
        origin: "https://accounts.example.test",
        credential: "fake-app-key",
        baseUrl: "https://models.example.test/v1",
      }),
    });
    const provider = new DockerSandboxProvider(`http://127.0.0.1:${address.port}`, "a".repeat(64));
    Object.assign(app.sandbox, { execution: provider.execution.bind(provider) });
    const signup = await app.app.request("/api/auth/sign-up/email", {
      method: "POST",
      headers: { "content-type": "application/json", origin: "http://127.0.0.1:5173" },
      body: JSON.stringify({
        email: "automatic-owner@fixture.test",
        password: "test-password-12",
        name: "Fixture",
      }),
    });
    expect(signup.status).toBeLessThan(400);
    const session = signup.headers
      .get("set-cookie")
      ?.match(/better-auth\.session_token=([^;]+)/)?.[1];
    expect(session).toBeTruthy();
    const headers = {
      "content-type": "application/json",
      origin: "http://127.0.0.1:5173",
      cookie: `better-auth.session_token=${session}`,
    };
    const meResponse = await app.app.request("/rpc/me", {
      method: "POST",
      headers,
      body: JSON.stringify({ json: {} }),
    });
    expect(meResponse.status).toBe(200);
    const { json: actor } = await meResponse.json();
    expect(actor.isAdmin).toBe(false);
    const db = asSystem(app.prisma);
    const computer = await db.computer.create({
      data: {
        userId: actor.userId,
        spaceId: actor.spaceId,
        scopeKey: randomUUID(),
        homeKey: randomUUID(),
        kind: "docker",
        scope: "dedicated",
        state: "stopped",
        providerRef: "fixture-container",
      },
    });
    const bot = await db.bot.create({
      data: {
        userId: actor.userId,
        spaceId: actor.spaceId,
        name: "Fixture",
        color: "gray",
        computerId: computer.id,
      },
    });
    const response = await app.app.request("/rpc/executions/list", {
      method: "POST",
      headers,
      body: JSON.stringify({ json: { botId: bot.id } }),
    });
    expect(response.status).toBe(200);
    const { json: connections } = await response.json();
    expect(connections).toHaveLength(1);
    expect(connections[0]).toMatchObject({ computerId: computer.id, online: true });
    expect(scopes).toContainEqual({
      userId: actor.userId,
      spaceId: actor.spaceId,
      computerId: computer.id,
    });
    expect((await db.computer.findUniqueOrThrow({ where: { id: computer.id } })).state).toBe(
      "stopped",
    );
    expect(await db.executionConnection.count({ where: { userId: actor.userId } })).toBe(1);
  });
});
