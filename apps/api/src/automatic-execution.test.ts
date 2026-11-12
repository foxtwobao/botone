import { EncryptedSecretStore } from "@rakazo/adapters";
import type { Actor } from "@rakazo/contracts";
import type { ExecutionConnection } from "@rakazo/db";
import { afterEach, expect, it, vi } from "vitest";
import { ensureAutomaticExecution } from "./automatic-execution.js";
import type { RouterDeps } from "./router.js";

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0)) await cleanup();
});

it("automatically binds an ordinary user's computer once, keeps revocation and service identity authoritative", async () => {
  const actor: Actor = {
    userId: "fixture-user",
    spaceId: "fixture-space",
    email: "fixture@example.test",
    isDeploymentOwner: false,
  };
  const identity = "00000000-0000-4000-8000-000000000001";
  let installation = identity,
    owned = true,
    available = true;
  const rows = new Map<string, ExecutionConnection>();
  const secrets = new EncryptedSecretStore("fake-encryption-key");
  const put = vi.spyOn(secrets, "put");
  const upsert = vi.fn(async ({ where, create }) => {
    if (!rows.has(where.id)) rows.set(where.id, create);
    return rows.get(where.id);
  });
  const updateMany = vi.fn(async ({ where, data }) => {
    const row = rows.get(where.id);
    if (row && !row.revokedAt && row.secretRef === where.secretRef) Object.assign(row, data);
  });
  const deps = {
    secrets,
    sandbox: {
      execution: async () => ({
        describe: async () => {
          if (!available) throw new Error("offline");
          return { id: installation, profiles: [] };
        },
      }),
    },
    prisma: {
      computer: {
        findFirst: vi.fn(async () =>
          owned
            ? { id: "fixture-computer", providerRef: "container", kind: "docker", homeKey: "home" }
            : null,
        ),
      },
      executionConnection: {
        findUnique: vi.fn(async ({ where }) => rows.get(where.id)),
        upsert,
        updateMany,
      },
    },
  } as unknown as RouterDeps;
  vi.mocked(deps.prisma.computer.findFirst).mockResolvedValueOnce({
    id: "fixture-computer",
    providerRef: null,
  } as never);
  expect(await ensureAutomaticExecution(deps, actor, "fixture-computer")).toMatchObject({
    online: false,
    profiles: [],
  });
  expect(rows.size).toBe(0);
  available = false;
  expect(await ensureAutomaticExecution(deps, actor, "fixture-computer")).toMatchObject({
    online: false,
    profiles: [],
  });
  expect(rows.size).toBe(0);
  available = true;
  await Promise.all([
    ensureAutomaticExecution(deps, actor, "fixture-computer"),
    ensureAutomaticExecution(deps, actor, "fixture-computer"),
  ]);
  expect(rows.size).toBe(1);
  const row = [...rows.values()][0]!;
  expect(row).toMatchObject({
    userId: actor.userId,
    spaceId: actor.spaceId,
    identity,
    computerId: "fixture-computer",
  });
  const stored = JSON.parse(await secrets.load(row.secretRef, row.id));
  expect(stored).toEqual({
    spaceId: actor.spaceId,
    userId: actor.userId,
    computerId: "fixture-computer",
  });
  expect(row.secretRef).not.toContain("a".repeat(64));
  put.mockClear();
  await ensureAutomaticExecution(deps, actor, "fixture-computer");
  expect(put).not.toHaveBeenCalled();
  row.revokedAt = new Date();
  await ensureAutomaticExecution(deps, actor, "fixture-computer");
  expect(row.revokedAt).not.toBeNull();
  expect(put).not.toHaveBeenCalled();
  row.revokedAt = null;
  row.secretRef = (
    await secrets.put(
      "{}",
      { ...actor, operationId: "test", traceId: "test", signal: new AbortController().signal },
      { recordId: row.id },
    )
  ).ref;
  installation = "00000000-0000-4000-8000-000000000002";
  await ensureAutomaticExecution(deps, actor, "fixture-computer");
  expect(row.identity).toBe(identity);
  expect(updateMany).not.toHaveBeenCalled();
  owned = false;
  upsert.mockClear();
  await ensureAutomaticExecution(deps, actor, "fixture-computer");
  expect(upsert).not.toHaveBeenCalled();
});
