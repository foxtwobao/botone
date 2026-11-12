import { createHash, timingSafeEqual } from "node:crypto";
import type { SandboxProvider, SecretStore } from "@rakazo/adapter-kit";
import { createAdapterContext } from "@rakazo/adapter-kit";
import type { configuredModelAccount, ExternalAccountIdentity } from "@rakazo/adapters";
import {
  computerInitializationGrant,
  configuredExecutionConnection,
  discoverModelAccountModels,
  executionOwnerSchema,
  personalComputerWhere,
  readComputerInitializationGrant,
  toComputerRef,
} from "@rakazo/adapters";
import type { Actor } from "@rakazo/contracts";
import type { PrismaClient } from "@rakazo/db";
import { accountDeactivated, requireMembership } from "@rakazo/db";
import type { Hono } from "hono";
import { HTTPException } from "hono/http-exception";
import { parseModelAccountSecret } from "./model-account-secret.js";

export async function initializeRunningModelComputers(
  prisma: PrismaClient,
  sandbox: SandboxProvider | undefined,
  owner: Actor,
) {
  if (!sandbox) return;
  const computers = await prisma.computer.findMany({
    where: {
      ...personalComputerWhere(owner),
      state: "running",
    },
  });
  // Preparing the existing reference never starts an idle desktop or replays a task.
  await Promise.allSettled(
    computers.map((computer) =>
      sandbox.prepare(
        toComputerRef(computer),
        createAdapterContext(owner, "", "model-initialization"),
      ),
    ),
  );
}

type Identity = ExternalAccountIdentity & { accountId: string; binding: string };

export function mountComputerModelInitialization(
  app: Hono,
  deps: {
    key?: string;
    executionConnection?: string;
    authUrl?: string;
    connection: ReturnType<typeof configuredModelAccount>;
    prisma: PrismaClient;
    secrets: SecretStore;
    identity(userId: string): Promise<Identity>;
    save(owner: Actor, identity: Identity, apiKey: string, expectedSecretId: string): Promise<void>;
    fetch?: typeof fetch;
  },
) {
  const execution = configuredExecutionConnection(deps.executionConnection);
  // Only the trusted execution service can discover computer grants. Never expose this to browsers.
  app.post("/environment", async (c) => {
    if (!execution || !deps.key || !deps.connection || !deps.authUrl)
      return c.json({ error: "disabled" }, 404);
    const expected = Buffer.from(`Bearer ${execution.token}`);
    const supplied = Buffer.from(c.req.header("authorization") ?? "");
    if (
      c.req.header("origin") ||
      expected.length !== supplied.length ||
      !timingSafeEqual(expected, supplied)
    )
      throw new HTTPException(401, { message: "invalid_grant" });
    const scope = executionOwnerSchema.parse(await c.req.json());
    if (await accountDeactivated(deps.prisma, scope.userId))
      throw new HTTPException(403, { message: "authorization_required" });
    await requireMembership(deps.prisma, scope.userId, scope.spaceId);
    const computer = await deps.prisma.computer.findFirst({
      where: { id: scope.computerId, ...personalComputerWhere(scope) },
    });
    if (!computer) throw new HTTPException(403, { message: "computer_unavailable" });
    const identity = await deps.identity(scope.userId);
    const credential = await deps.prisma.userModelCredential.findFirst({
      where: { id: `external-${identity.accountId}`, userId: scope.userId },
    });
    const stored =
      credential &&
      (await deps.prisma.secret.findFirst({
        where: { id: credential.secretId, userId: scope.userId },
      }));
    if (!credential || !stored) throw new HTTPException(401, { message: "authorization_required" });
    const parsed = parseModelAccountSecret(await deps.secrets.load(stored.ciphertext, stored.id));
    if (
      parsed.binding?.accountId !== identity.accountId ||
      parsed.binding.binding !== identity.binding ||
      parsed.secret.kind !== "openai_compatible" ||
      !parsed.secret.apiKey ||
      parsed.secret.baseUrl !== deps.connection.model.baseUrl
    )
      throw new HTTPException(401, { message: "authorization_required" });
    const createdAt = credential.createdAt.toISOString();
    return c.json({
      ...scope,
      homeKey: computer.homeKey,
      state: computer.state,
      credentialId: credential.id,
      credentialCreatedAt: createdAt,
      connectionRevision: createHash("sha256")
        .update(JSON.stringify([deps.connection.model.baseUrl, identity.binding]))
        .digest("hex"),
      models: parsed.secret.enabledModelIds ?? [],
      defaults: deps.connection.defaults,
      initialization: {
        url: new URL("/api/model-account/computer", deps.authUrl).href,
        token: computerInitializationGrant(deps.key, {
          userId: scope.userId,
          spaceId: scope.spaceId,
          homeKey: computer.homeKey,
          credentialId: credential.id,
          credentialCreatedAt: createdAt,
        }),
      },
    });
  });
  app.post("/computer", async (c) => {
    if (!deps.key || !deps.connection) return c.json({ error: "disabled" }, 404);
    const grant = readComputerInitializationGrant(
      deps.key,
      c.req.header("authorization")?.replace(/^Bearer /, "") ?? "",
    );
    if (!grant) throw new HTTPException(401, { message: "invalid_grant" });
    if (await accountDeactivated(deps.prisma, grant.userId))
      throw new HTTPException(403, { message: "authorization_required" });
    const owner = await requireMembership(deps.prisma, grant.userId, grant.spaceId);
    const scope = { userId: grant.userId, spaceId: grant.spaceId, homeKey: grant.homeKey };
    const computer = await deps.prisma.computer.findFirst({
      where: {
        ...personalComputerWhere(scope),
        homeKey: scope.homeKey,
        state: { in: ["running", "booting"] },
      },
    });
    if (!computer) throw new HTTPException(403, { message: "computer_unavailable" });
    const identity = await deps.identity(owner.userId);
    const credential = async () => {
      const row = await deps.prisma.userModelCredential.findFirst({
        where: {
          id: `external-${identity.accountId}`,
          userId: owner.userId,
        },
      });
      if (!row) throw new HTTPException(401, { message: "authorization_required" });
      if (
        row.id !== grant.credentialId ||
        row.createdAt.toISOString() !== grant.credentialCreatedAt
      )
        throw new HTTPException(401, { message: "authorization_required" });
      const stored = await deps.prisma.secret.findFirst({
        where: { id: row.secretId, userId: owner.userId },
      });
      if (!stored) throw new HTTPException(401, { message: "authorization_required" });
      const parsed = parseModelAccountSecret(await deps.secrets.load(stored.ciphertext, stored.id));
      if (
        parsed.binding?.accountId !== identity.accountId ||
        parsed.binding.binding !== identity.binding ||
        parsed.secret.kind !== "openai_compatible" ||
        !parsed.secret.apiKey ||
        parsed.secret.baseUrl !== deps.connection!.model.baseUrl
      )
        throw new HTTPException(401, { message: "authorization_required" });
      return { secret: parsed.secret, secretId: row.secretId };
    };
    const original = await credential();
    let secret = original.secret;
    const probe = async (apiKey: string) => {
      const response = await (deps.fetch ?? fetch)(`${secret.baseUrl.replace(/\/+$/, "")}/models`, {
        headers: { authorization: `Bearer ${apiKey}` },
        redirect: "error",
        signal: AbortSignal.any([c.req.raw.signal, AbortSignal.timeout(5000)]),
      });
      if (!response.ok) {
        await response.body?.cancel();
        return { status: response.status, models: [] as string[] };
      }
      const models = await discoverModelAccountModels(secret.baseUrl, apiKey, async () => response);
      return { status: response.status, models };
    };
    let response = await probe(secret.apiKey!);
    if (response.status === 401) {
      // Ensure may recover a remotely replaced key. It is not a force-rotation API.
      const recovered = await deps.connection.provider.ensure(identity, c.req.raw.signal);
      if (recovered.apiKey === secret.apiKey)
        throw new HTTPException(401, { message: "model_authentication_failed" });
      response = await probe(recovered.apiKey);
      if (response.status !== 200)
        throw new HTTPException(response.status === 401 ? 401 : 503, {
          message: "model_connection_unavailable",
        });
      await deps.save(owner, identity, recovered.apiKey, original.secretId);
      secret = { ...secret, apiKey: recovered.apiKey };
    } else if (response.status !== 200) {
      // Quota, permissions, rate limits and outages never trigger key recovery.
      throw new HTTPException(503, { message: "model_connection_unavailable" });
    }
    const current = await deps.identity(owner.userId);
    if (current.accountId !== identity.accountId || current.binding !== identity.binding)
      throw new HTTPException(401, { message: "authorization_required" });
    await requireMembership(deps.prisma, grant.userId, grant.spaceId);
    if (
      (await accountDeactivated(deps.prisma, grant.userId)) ||
      !(await deps.prisma.computer.findFirst({
        where: {
          ...personalComputerWhere(scope),
          homeKey: scope.homeKey,
          state: { in: ["running", "booting"] },
        },
      }))
    )
      throw new HTTPException(403, { message: "computer_unavailable" });
    // Re-read after network work: a disconnect or concurrent reauthorization wins.
    const latest = (await credential()).secret;
    if (latest.apiKey !== secret.apiKey || latest.baseUrl !== secret.baseUrl)
      throw new HTTPException(409, { message: "model_connection_changed" });
    const request = await c.req.json().catch(() => null);
    return c.json({
      baseUrl: secret.baseUrl,
      ...(request?.checkOnly === true ? {} : { apiKey: secret.apiKey }),
      defaults: deps.connection.defaults,
      modelIds: response.models,
    });
  });
}
