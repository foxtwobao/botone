import type { AdapterContext } from "@rakazo/adapter-kit";
import type { PrismaClient } from "@rakazo/db";
import { vi } from "vitest";
import type { ApplicationServices } from "../../../configured-apps.js";
import { FeishuOfficeConnector } from "./feishu-connector.js";
import type { FeishuConnectionConfig, FeishuOfficeProvider } from "./feishu-contracts.js";

// Synthetic app, in-memory storage and a fake provider. No network or real credentials.
type Row = Record<string, unknown>;
type Query = { where?: Row; data?: Row };
const clone = <T>(value: T): T => structuredClone(value);
function match(row: Row, where: Row = {}): boolean {
  return Object.entries(where).every(([key, value]) => {
    const actual = row[key];
    if (value && typeof value === "object" && !Array.isArray(value)) {
      const condition = value as Row;
      if ("in" in condition) return (condition.in as unknown[]).includes(actual);
      return Boolean(actual && typeof actual === "object" && match(actual as Row, condition));
    }
    return actual === value;
  });
}
function table(rows: Row[]) {
  return {
    findMany: vi.fn(async ({ where }: Query = {}) =>
      clone(rows.filter((row) => match(row, where))),
    ),
    findFirst: vi.fn(async ({ where }: Query) =>
      clone(rows.find((row) => match(row, where)) ?? null),
    ),
    findUnique: vi.fn(async ({ where }: Query) =>
      clone(rows.find((row) => match(row, where)) ?? null),
    ),
    updateMany: vi.fn(async ({ where, data }: Query) => {
      const matched = rows.filter((row) => match(row, where));
      for (const row of matched) Object.assign(row, clone(data));
      return { count: matched.length };
    }),
    create: vi.fn(async ({ data }: Query) => {
      const row = { ...clone(data), id: data?.id ?? `test-${rows.length}` };
      rows.push(row);
      return clone(row);
    }),
  };
}

/** In-memory emulation of the leases-table queries withLease issues, for offline tests. */
export function memoryLeaseQueryRaw() {
  const leases = new Map<string, { fence: number; expiresAt: number }>();
  let seq = 0;
  return async (strings: TemplateStringsArray, ...values: unknown[]) => {
    const sql = strings[0]?.trim() ?? "";
    if (sql.startsWith('INSERT INTO "leases"')) {
      const key = String(values[0]);
      const ttl = Number(values[1]);
      const cur = leases.get(key);
      if (cur && cur.expiresAt > Date.now()) return [];
      const fence = ++seq;
      leases.set(key, { fence, expiresAt: Date.now() + ttl });
      return [{ fence: BigInt(fence) }];
    }
    if (sql.startsWith('UPDATE "leases"')) {
      const ttl = Number(values[0]);
      const key = String(values[1]);
      const fence = Number(values[2]);
      const cur = leases.get(key);
      if (cur && cur.fence === fence && cur.expiresAt > Date.now()) {
        cur.expiresAt = Date.now() + ttl;
        return [1];
      }
      return [];
    }
    if (sql.startsWith('DELETE FROM "leases"')) {
      const key = String(values[0]);
      const fence = Number(values[1]);
      const cur = leases.get(key);
      if (cur && cur.fence === fence) {
        leases.delete(key);
        return [1];
      }
      return [];
    }
    return [];
  };
}

export function feishuFixture(
  modules: FeishuConnectionConfig["modules"] = ["doc", "task", "calendar", "sheet"],
) {
  const config: FeishuConnectionConfig = {
    appId: "cli_synthetic",
    appSecret: "synthetic-secret",
    domain: "feishu",
    identity: "app",
    modules,
    name: "Feishu",
    spaceIds: ["space-a"],
  };
  const connections: Row[] = [];
  const users: Row[] = [{ id: "user-a" }, { id: "user-b" }];
  const members = new Set(["space-a:user-a", "space-a:user-b"]);
  const calls: Array<{ method: string; input: unknown }> = [];
  let verifyOk = true;
  const provider: FeishuOfficeProvider = {
    verify: vi.fn(async () => {
      if (!verifyOk) {
        const { FeishuServiceError } = await import("./feishu-provider.js");
        throw new FeishuServiceError("authorization_required", 403);
      }
    }),
    createDoc: vi.fn(async (input) => {
      calls.push({ method: "createDoc", input });
      return { documentId: "doc-synthetic", title: input.title };
    }),
    readDoc: vi.fn(async (documentId) => {
      calls.push({ method: "readDoc", input: documentId });
      return `content of ${documentId}`;
    }),
    createTask: vi.fn(async (input) => {
      calls.push({ method: "createTask", input });
      return { taskId: "task-synthetic", summary: input.summary };
    }),
    listTasks: vi.fn(async (input) => {
      calls.push({ method: "listTasks", input });
      return { tasks: [{ taskId: "task-synthetic", summary: "Synthetic task" }] };
    }),
    listEvents: vi.fn(async (input) => {
      calls.push({ method: "listEvents", input });
      return [{ eventId: "event-synthetic", summary: "Synthetic event" }];
    }),
    createEvent: vi.fn(async (input) => {
      calls.push({ method: "createEvent", input });
      return { eventId: "event-synthetic", summary: input.summary };
    }),
    createSheet: vi.fn(async (input) => {
      calls.push({ method: "createSheet", input });
      return { spreadsheetToken: "sheet-synthetic", title: input.title };
    }),
    readSheet: vi.fn(async (input) => {
      calls.push({ method: "readSheet", input });
      return { range: input.range, values: [["a", 1]] };
    }),
    appendRows: vi.fn(async (input) => {
      calls.push({ method: "appendRows", input });
      return { range: input.range, updatedRows: input.values.length };
    }),
  };
  const tables = {
    $executeRaw: vi.fn(async () => 1),
    connection: table(connections),
    user: table(users),
    spaceMember: {
      findUnique: vi.fn(
        async ({ where }: { where: { spaceId_userId: { spaceId: string; userId: string } } }) =>
          members.has(`${where.spaceId_userId.spaceId}:${where.spaceId_userId.userId}`)
            ? { id: "member" }
            : null,
      ),
    },
  };
  const db = {
    ...tables,
    $transaction: async <T>(fn: (tx: typeof tables) => Promise<T>): Promise<T> => fn(tables),
  };
  const deps = {
    prisma: db as unknown as PrismaClient,
    providerScopeKey: vi.fn(() => "synthetic-connection-scope"),
  } as unknown as ApplicationServices;
  const connector = new FeishuOfficeConnector(
    config,
    provider,
    deps,
    (context) => `test:${context.spaceId}:${context.userId}`,
  );
  const context = (userId = "user-a"): AdapterContext => ({
    userId,
    spaceId: "space-a",
    runId: "run-a",
    botId: "bot-a",
    operationId: "test",
    traceId: "test",
    signal: new AbortController().signal,
    connectedConnections: connections
      .filter((row) => row.userId === userId && row.status === "connected")
      .map((row) => ({
        id: String(row.id),
        connectorId: "feishu",
        externalId: "feishu",
        displayName: config.name,
        providerRef: String(row.providerRef),
      })),
  });
  // The real auto-provision path: ensureConnection verifies the app, then marks the row connected.
  const connect = async (userId = "user-a") => {
    await connector.listConnectedExternalIds(context(userId));
    return connections.find((row) => row.userId === userId);
  };
  return {
    connector,
    provider,
    config,
    connections,
    calls,
    context,
    connect,
    setVerifyOk: (value: boolean) => {
      verifyOk = value;
    },
  };
}
