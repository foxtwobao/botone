import type { AdapterContext, SecretStore } from "@rakazo/adapter-kit";
import type { PrismaClient } from "@rakazo/db";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ApplicationServices } from "../../../configured-apps.js";
import { ConnectorRegistry } from "../../../integrations/connector-registry.js";
import { memoryLeaseQueryRaw } from "./feishu.test-support.js";
import { FeishuOfficeConnector } from "./feishu-connector.js";
import type { FeishuConnectionConfig, FeishuOfficeProvider } from "./feishu-contracts.js";

afterEach(() => vi.unstubAllGlobals());

type Row = Record<string, unknown>;
const clone = <T>(v: T): T => structuredClone(v);
const match = (row: Row, where: Row = {}): boolean =>
  Object.entries(where).every(([k, v]) => {
    const a = row[k];
    if (v && typeof v === "object" && !Array.isArray(v)) {
      const c = v as Row;
      if ("in" in c) return (c.in as unknown[]).includes(a);
      return Boolean(a && typeof a === "object" && match(a as Row, c));
    }
    return a === v;
  });
function table(rows: Row[]) {
  return {
    findMany: async ({ where }: { where?: Row } = {}) => clone(rows.filter((r) => match(r, where))),
    findFirst: async ({ where }: { where: Row }) =>
      clone(rows.find((r) => match(r, where)) ?? null),
    findUnique: async ({ where }: { where: Row }) =>
      clone(rows.find((r) => match(r, where)) ?? null),
    updateMany: async ({ where, data }: { where: Row; data: Row }) => {
      const m = rows.filter((r) => match(r, where));
      for (const r of m) Object.assign(r, clone(data));
      return { count: m.length };
    },
    update: async ({ where, data }: { where: Row; data: Row }) => {
      const r = rows.find((x) => match(x, where));
      if (!r) throw new Error("missing row");
      Object.assign(r, clone(data));
      return clone(r);
    },
    create: async ({ data }: { data: Row }) => {
      const r = { ...clone(data), id: data.id ?? `t-${rows.length}` };
      rows.push(r);
      return clone(r);
    },
    delete: async ({ where }: { where: Row }) => {
      const i = rows.findIndex((r) => match(r, where));
      if (i >= 0) rows.splice(i, 1);
      return clone(rows[i] ?? {});
    },
  };
}

function fixture() {
  const connections: Row[] = [];
  const secretsRows: Row[] = [];
  const tables = {
    $executeRaw: async () => 1,
    connection: table(connections),
    secret: table(secretsRows),
    user: table([{ id: "user-a" }]),
    spaceMember: {
      findUnique: async ({
        where,
      }: {
        where: { spaceId_userId: { spaceId: string; userId: string } };
      }) => (where.spaceId_userId.userId === "user-a" ? { id: "m" } : null),
    },
  };
  const db = {
    ...tables,
    $queryRaw: memoryLeaseQueryRaw(),
    $transaction: async <T>(fn: (tx: typeof tables) => Promise<T>) => fn(tables),
  };
  let n = 0;
  const secrets = {
    put: async (plaintext: string) => ({
      id: `sec-${++n}`,
      ref: `ref-${n}`,
      ciphertext: plaintext,
    }),
    load: async (ref: string) => ref,
    delete: async () => {},
  } as unknown as SecretStore;
  const deps = {
    prisma: db as unknown as PrismaClient,
    secrets,
    providerScopeKey: () => "scope",
  } as unknown as ApplicationServices;
  const config: FeishuConnectionConfig = {
    appId: "cli_synthetic",
    appSecret: "synthetic",
    domain: "feishu" as const,
    identity: "user" as const,
    modules: ["doc", "task", "calendar", "sheet"],
    name: "Feishu",
  };
  const unusedAppProvider = {} as FeishuOfficeProvider;
  const connector = new FeishuOfficeConnector(config, unusedAppProvider, deps, () => "scope");
  const calls: string[] = [];
  const fetcher = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
    const u = String(url);
    const body = init?.body ? (JSON.parse(String(init.body)) as Row) : {};
    const auth = new Headers(init?.headers).get("authorization") ?? "";
    if (u.includes("/authen/v2/oauth/token")) {
      calls.push(`token:${body.grant_type}`);
      const refresh = body.grant_type === "refresh_token";
      return Response.json({
        code: 0,
        access_token: refresh ? "user-tok-2" : "user-tok",
        refresh_token: refresh ? "ref-tok-2" : "ref-tok",
        expires_in: 7200,
      });
    }
    calls.push(`api:${auth.replace("Bearer ", "")}:${u.split("/open-apis")[1]}`);
    if (u.includes("/authen/v1/user_info"))
      return Response.json({ code: 0, data: { open_id: "ou_x", name: "Test" } });
    if (u.includes("/docx/v1/documents") && init?.method === "POST")
      return Response.json({
        code: 0,
        data: { document: { document_id: "doc-u", title: body.title } },
      });
    if (u.includes("/task/v2/tasks"))
      return Response.json({
        code: 0,
        data: { items: [{ guid: "t-u", summary: "s" }], has_more: false },
      });
    return Response.json({ code: 0, data: {} });
  }) as unknown as typeof fetch;
  vi.stubGlobal("fetch", fetcher);
  const ctx = (): AdapterContext => ({
    userId: "user-a",
    spaceId: "space-a",
    runId: "run-a",
    botId: "bot-a",
    operationId: "test",
    traceId: "test",
    signal: new AbortController().signal,
    connectedConnections: connections
      .filter((r) => r.status === "connected")
      .map((r) => ({
        id: String(r.id),
        connectorId: "feishu",
        externalId: "feishu",
        displayName: "Feishu",
        providerRef: String(r.providerRef),
      })),
  });
  return { connector, connections, secretsRows, calls, ctx, config };
}

async function beginUser(
  f: ReturnType<typeof fixture>,
  redirectUrl = "https://app.example.test/cb",
) {
  const begun = await f.connector.begin({ provider: "feishu", redirectUrl }, f.ctx());
  const row = f.connections[0];
  if (!row) throw new Error("begin must create its pending connection");
  row.providerRef = begun.state;
  row.metadata = begun.connectionMetadata ?? {};
  row.status = "pending";
  return begun;
}

async function completeUser(
  f: ReturnType<typeof fixture>,
  begun: Awaited<ReturnType<typeof beginUser>>,
  code = "auth-code",
) {
  return f.connector.complete({ state: begun.state, code }, f.ctx());
}

async function connectUser(f: ReturnType<typeof fixture>) {
  const begun = await beginUser(f);
  expect(begun.authorizationUrl).toContain("/authen/v1/authorize");
  const done = await completeUser(f, begun);
  return done.connectionRef;
}

describe("feishu user identity (OAuth) offline contract", () => {
  it("begin returns the Feishu authorize URL and complete stores an encrypted secret", async () => {
    const f = fixture();
    const state = await connectUser(f);
    expect(f.connections[0]?.status).toBe("connected");
    expect(f.connections[0]?.secretId).toBeTruthy();
    expect(f.secretsRows).toHaveLength(1);
    expect(f.calls).toContain("token:authorization_code");
    expect(await f.connector.listConnectedExternalIds(f.ctx())).toEqual(["feishu"]);
    expect(state).toBeTruthy();
    expect(f.connections[0]?.providerRef).toBe(state);
  });

  it("executes office tools as the authorizing user", async () => {
    const f = fixture();
    await connectUser(f);
    const registry = new ConnectorRegistry([f.connector]);
    const tools = await registry.discoverTools(f.ctx());
    const sel = tools.find((t) => t.route?.toolName === "feishu_create_doc")!;
    const events = [];
    for await (const e of registry.execute(
      { tool: sel.name, route: sel.route, args: { title: "个人文档" }, executionId: "e" },
      f.ctx(),
    ))
      events.push(e);
    expect(events).toEqual([{ type: "result", data: { documentId: "doc-u", title: "个人文档" } }]);
    expect(f.calls.some((c) => c.startsWith("api:user-tok:"))).toBe(true);
  });

  it("refreshes an expiring token before calling the API", async () => {
    const f = fixture();
    await connectUser(f);
    // Age the stored token so the next call must refresh.
    const stored = JSON.parse(String(f.secretsRows[0]?.ciphertext));
    stored.expiresAt = Date.now() - 1000;
    f.secretsRows[0]!.ciphertext = JSON.stringify(stored);
    const registry = new ConnectorRegistry([f.connector]);
    const tools = await registry.discoverTools(f.ctx());
    const sel = tools.find((t) => t.route?.toolName === "feishu_list_tasks")!;
    const events = [];
    for await (const e of registry.execute(
      { tool: sel.name, route: sel.route, args: {}, executionId: "e" },
      f.ctx(),
    ))
      events.push(e);
    expect(events[0]).toMatchObject({ type: "result" });
    expect(f.calls).toContain("token:refresh_token");
    expect(f.calls.some((c) => c.startsWith("api:user-tok-2:"))).toBe(true);
  });

  it("revoke deletes the stored secret", async () => {
    const f = fixture();
    const state = await connectUser(f);
    await f.connector.revoke(state, f.ctx());
    expect(f.secretsRows).toHaveLength(0);
  });

  it("surfaces re-authorization when the refresh token is dead", async () => {
    const f = fixture();
    await connectUser(f);
    const stored = JSON.parse(String(f.secretsRows[0]?.ciphertext));
    stored.expiresAt = Date.now() - 1000;
    stored.refreshToken = "dead-refresh";
    f.secretsRows[0]!.ciphertext = JSON.stringify(stored);
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
        const body = init?.body ? (JSON.parse(String(init.body)) as Row) : {};
        if (String(url).includes("oauth/token") && body.grant_type === "refresh_token")
          return Response.json({ code: 20029, msg: "invalid refresh token" }, { status: 400 });
        return Response.json({ code: 0, data: { open_id: "ou_x", items: [] } });
      }) as unknown as typeof fetch,
    );
    const registry = new ConnectorRegistry([f.connector]);
    const tools = await registry.discoverTools(f.ctx());
    const sel = tools.find((t) => t.route?.toolName === "feishu_list_tasks")!;
    const events = [];
    for await (const e of registry.execute(
      { tool: sel.name, route: sel.route, args: {}, executionId: "e" },
      f.ctx(),
    ))
      events.push(e);
    expect(events).toEqual([{ type: "error", message: "Feishu: authorization_required" }]);
    expect(await f.connector.connectionReady(f.ctx(), "feishu")).toBe(false);
  });

  it("refuses calls after revoke removes the secret", async () => {
    const f = fixture();
    const state = await connectUser(f);
    await f.connector.revoke(state, f.ctx());
    expect(f.connections[0]?.status).toBe("revoked");
    expect(f.secretsRows).toHaveLength(0);
    const registry = new ConnectorRegistry([f.connector]);
    expect(await registry.discoverTools(f.ctx())).toEqual([]);
  });

  it("rejects a replayed OAuth callback once the state is consumed", async () => {
    const f = fixture();
    const begun = await beginUser(f);
    await completeUser(f, begun);
    await expect(
      f.connector.complete({ state: begun.state, code: "auth-code" }, f.ctx()),
    ).rejects.toMatchObject({ code: "forbidden" });
  });

  it("re-authorization on a connected row refreshes the redirect URI and state", async () => {
    const f = fixture();
    await connectUser(f);
    const again = await beginUser(f, "https://app.example.test/cb2");
    expect(again.authorizationUrl).toContain("cb2");
    await completeUser(f, again, "auth-code-2");
    expect(f.connections[0]?.status).toBe("connected");
    expect(f.calls.filter((c) => c === "token:authorization_code")).toHaveLength(2);
  });

  it("does not expose tools to a non-member of the space", async () => {
    const f = fixture();
    await connectUser(f);
    const registry = new ConnectorRegistry([f.connector]);
    expect(await registry.discoverTools({ ...f.ctx(), userId: "user-b" })).toEqual([]);
  });
});
