import { createHash, randomUUID } from "node:crypto";
import { isDeepStrictEqual } from "node:util";
import type { AdapterContext, ArtifactStore } from "@rakazo/adapter-kit";
import type { PrismaClient, ThreadEvents } from "@rakazo/db";
import { vi } from "vitest";
import type { UserAccessCredential } from "./configured-apps.js";
import { CreativeAppConnector } from "./creative-connector.js";
import type { CreativeCapabilities, CreativeInput, CreativeJob } from "./creative-contracts.js";
import type { CreativeConnectionConfig } from "./creative-provider.js";
import { UserCreativeProvider } from "./creative-provider.js";

// Only synthetic identities, in-memory storage and a fetch emulator. No network or billing.
export const capabilities: CreativeCapabilities = {
  models: [
    {
      id: "demo-image",
      name: "Demo Image",
      parameters: {
        type: "object",
        properties: { size: { type: "string" } },
        additionalProperties: false,
      },
      constraints: { pixelSize: true, maxReferences: null },
      kind: "image",
      presets: [{ id: "demo-image-default", parameters: {} }],
      defaultPreset: "demo-image-default",
    },
    {
      id: "demo-video",
      name: "Demo Video",
      description: "Synthetic configurable video model",
      parameters: {
        $schema: "https://json-schema.org/draft/2020-12/schema",
        type: "object",
        properties: {
          mode: { type: "string", enum: ["frames", "reference"] },
          resolution: { type: "string", enum: ["720P", "1080P", "2K"] },
          ratio: { type: "string", enum: ["16:9", "1:1"] },
          watermark: { type: "boolean" },
          seed: { type: "integer", minimum: 0 },
          seconds: { type: "integer", minimum: 4, maximum: 30 },
        },
        allOf: [
          {
            if: { properties: { resolution: { const: "2K" } }, required: ["resolution"] },
            // biome-ignore lint/suspicious/noThenProperty: JSON Schema uses then as a data keyword.
            then: { properties: { seconds: { type: "integer", minimum: 4, maximum: 15 } } },
          },
        ],
        additionalProperties: false,
      },
      constraints: {
        durationConfigurable: true,
        durationByResolution: {
          "720P": { min: 4, max: 30, auto: false },
          "2K": { min: 4, max: 15, auto: false },
        },
        maxImages: 9,
        maxVideos: 3,
        referenceSeconds: null,
      },
      kind: "video",
      presets: [{ id: "demo-video-default", parameters: { resolution: "720P", seconds: 5 } }],
      defaultPreset: "demo-video-default",
    },
    {
      id: "demo-music",
      name: "Demo Music",
      parameters: {
        type: "object",
        properties: { mode: { type: "string", enum: ["song", "instrumental"] } },
        additionalProperties: false,
      },
      constraints: {},
      kind: "music",
      presets: [
        { id: "demo-song", parameters: { mode: "song" } },
        { id: "demo-inst", parameters: { mode: "instrumental" } },
      ],
      defaultPreset: "demo-inst",
    },
  ],
  defaults: { music: "demo-music" },
  submission: { presetOnly: true, referenceMedia: false },
};
export const musicInput: CreativeInput = {
  kind: "music",
  model: "demo-music",
  preset: "demo-inst",
  prompt: "柔和的钢琴片头",
};
export const identityA: UserAccessCredential = {
  accountId: "account-a",
  binding: "binding-a",
  accessToken: async () => "fake-access-a",
};
type Row = Record<string, unknown>;
type Query = { where?: Row; data?: Row; create?: Row };
const clone = <T>(value: T): T => structuredClone(value);
function match(row: Row, where: Row = {}): boolean {
  return Object.entries(where).every(([key, value]) => {
    if (key === "OR") return (value as Row[]).some((item) => match(row, item));
    const actual = row[key];
    if (value instanceof Date)
      return actual instanceof Date && actual.getTime() === value.getTime();
    if (value && typeof value === "object" && !Array.isArray(value)) {
      const condition = value as Row;
      if ("in" in condition) return (condition.in as unknown[]).includes(actual);
      if ("not" in condition) return actual !== condition.not;
      if ("gt" in condition) return actual instanceof Date && actual > (condition.gt as Date);
      if ("lt" in condition) return actual instanceof Date && actual < (condition.lt as Date);
      if ("path" in condition)
        return (
          (condition.path as string[]).reduce<unknown>(
            (current, field) => (current as Row)?.[field],
            actual,
          ) === condition.equals
        );
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
    findUniqueOrThrow: vi.fn(async ({ where }: Query) => {
      const row = rows.find((row) => match(row, where));
      if (!row) throw new Error("Missing test row");
      return clone(row);
    }),
    updateMany: vi.fn(async ({ where, data }: Query) => {
      const matched = rows.filter((row) => match(row, where));
      for (const row of matched)
        Object.assign(row, clone(data), {
          updatedAt: new Date(
            Math.max(Date.now(), (row.updatedAt as Date | undefined)?.getTime() ?? 0) + 1,
          ),
        });
      return { count: matched.length };
    }),
    update: vi.fn(async ({ where, data }: Query) => {
      const row = rows.find((row) => match(row, where));
      if (!row) throw new Error("Missing test row");
      Object.assign(row, clone(data));
      return clone(row);
    }),
    upsert: vi.fn(async ({ where, create }: Query) => {
      let row = rows.find((row) => match(row, where));
      if (!row) {
        row = { ...clone(create), updatedAt: new Date(), run: { userId: "user-a" } };
        rows.push(row);
      }
      return clone(row);
    }),
    create: vi.fn(async ({ data }: Query) => {
      const row = { ...clone(data), id: data?.id ?? `test-${rows.length}` };
      rows.push(row);
      return clone(row);
    }),
  };
}

export function creativeFixture() {
  const config: CreativeConnectionConfig = {
    origin: "https://creative.example.test",
    name: "CreativeOne",
    authorizationUrl: "https://creative.example.test/authorize",
    spaceIds: ["space-a"],
  };
  const effects: Row[] = [],
    connections: Row[] = [],
    messages: Row[] = [],
    artifacts: Row[] = [];
  const runs: Row[] = [
    {
      id: "run-a",
      userId: "user-a",
      spaceId: "space-a",
      threadId: "thread-a",
      botId: "bot-a",
      status: "running",
      trigger: "user",
      sourceMessage: { role: "user" },
    },
  ];
  const threads: Row[] = [{ id: "thread-a", userId: "user-a", spaceId: "space-a", groupId: null }];
  const identities = new Map([
    ["user-a", { ...identityA }],
    [
      "user-b",
      {
        ...identityA,
        accountId: "account-b",
        binding: "binding-b",
        accessToken: async () => "fake-access-b",
      },
    ],
  ]);
  const users: Row[] = [{ id: "user-a" }, { id: "user-b" }];
  const members = new Set(["space-a:user-a", "space-a:user-b"]);
  const tables = {
    $executeRaw: vi.fn(async () => 1),
    externalEffect: table(effects),
    connection: table(connections),
    run: table(runs),
    thread: table(threads),
    message: table(messages),
    artifact: table(artifacts),
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
  const events = { notify: vi.fn(async () => undefined) } as unknown as ThreadEvents;
  const blobs = {
    put: vi.fn(async () => ({ id: "blob", hash: "hash" })),
    remove: vi.fn(async () => undefined),
  } as unknown as ArtifactStore;
  const deps = {
    prisma: db as unknown as PrismaClient,
    events,
    artifacts: blobs,
    maxUploadSizeBytes: 1_024,
    providerScopeKey: vi.fn(() => "synthetic-shared-connection-scope"),
  };
  const references = new Map<
    string,
    { user: string; bytes: Uint8Array; kind: "image" | "video" | "audio" }
  >();
  const referenceIds = new Map<string, string>();
  const referenceUploads: { user: string; bytes: Uint8Array }[] = [];
  let loseUploadResponse = false;
  const remote = new Map<string, { user: string; request: CreativeInput; job: CreativeJob }>();
  const hidden = new Set<string>();
  const history: {
    method: string;
    path: string;
    user: string;
    authorization: string;
    input?: Row;
  }[] = [];
  const tokens = new Map([
    ["fake-access-a", "account-a"],
    ["fake-access-b", "account-b"],
  ]);
  let authenticationAvailable = true,
    billingAuthorized = true,
    losePutResponse = false,
    loseBeforeAccept = false;
  let localEligible = true;
  let catalog = clone(capabilities);
  let connector: CreativeAppConnector;
  const error = (status: number, code: string) => Response.json({ error: { code } }, { status });
  const fetcher = vi.fn(
    async (url: string | URL | Request, init?: RequestInit): Promise<Response> => {
      const target = new URL(String(url));
      if (target.origin !== config.origin || init?.redirect !== "manual")
        throw new Error("Unsafe test request");
      const headers = new Headers(init?.headers);
      const authorization = headers.get("authorization") ?? "";
      if (headers.has("cookie") || headers.has("origin"))
        throw new Error("Unexpected browser credential");
      if (!authenticationAvailable) return error(503, "authentication_unavailable");
      const user = tokens.get(authorization.slice(7));
      if (!authorization.startsWith("Bearer ") || !user)
        return error(401, "authentication_required");
      const method = init?.method ?? "GET";
      const referenceUpload = target.pathname.endsWith("/references") && method === "POST";
      const input =
        init?.body && !referenceUpload ? (JSON.parse(String(init.body)) as Row) : undefined;
      history.push({ method, path: target.pathname, user, authorization, input });
      if (target.pathname.endsWith("/capabilities"))
        return localEligible ? Response.json(catalog) : error(403, "authorization_required");
      if (referenceUpload) {
        const bytes = new Uint8Array(init!.body as Uint8Array);
        referenceUploads.push({ user, bytes });
        if (headers.get("content-type") !== "application/octet-stream")
          throw new Error("Expected original binary image");
        const kind =
          bytes[0] === 137 && bytes[1] === 80
            ? "image"
            : Buffer.from(bytes).subarray(0, 4).toString() === "RIFF"
              ? "audio"
              : Buffer.from(bytes).subarray(4, 8).toString() === "ftyp"
                ? "video"
                : undefined;
        if (!kind) return error(415, "unsupported_media");
        if (
          bytes.byteLength >
          (kind === "image"
            ? (catalog.submission?.maxReferenceImageBytes ?? 0)
            : (catalog.submission?.maxReferenceMediaBytes ?? 0))
        )
          return error(
            413,
            kind === "image" ? "reference_image_too_large" : "reference_media_too_large",
          );
        const digest = `${user}:${createHash("sha256").update(bytes).digest("hex")}`;
        const id = referenceIds.get(digest) ?? randomUUID();
        referenceIds.set(digest, id);
        references.set(id, { user, bytes, kind });
        if (loseUploadResponse) {
          loseUploadResponse = false;
          throw new Error("Synthetic lost upload response");
        }
        return Response.json(
          {
            id,
            kind,
            mimeType: kind === "image" ? "image/png" : kind === "video" ? "video/mp4" : "audio/wav",
            bytes: bytes.byteLength,
            ...(kind !== "audio" ? { width: 1, height: 1 } : {}),
            ...(kind !== "image" ? { durationMs: 1_000 } : {}),
          },
          { status: 201 },
        );
      }
      const [, operationId, outputId] =
        /\/jobs\/([^/]+)(?:\/outputs\/([^/]+))?$/.exec(target.pathname) ?? [];
      if (!operationId) return error(404, "not_found");
      const key = `${user}:${operationId}`;
      const stored = remote.get(key);
      if (stored && hidden.has(operationId)) return error(404, "not_found");
      if (method === "PUT") {
        if (stored)
          return isDeepStrictEqual(
            { ...stored.request, parameters: stored.request.parameters ?? {} },
            { ...input!, parameters: input!.parameters ?? {} },
          )
            ? Response.json(stored.job)
            : error(409, "operation_conflict");
        if (!billingAuthorized) return error(403, "authorization_required");
        const model = catalog.models.find(
          (model) => model.id === input?.model && model.kind === input.kind,
        );
        if (!model?.presets.some((preset) => preset.id === (input?.preset ?? model.defaultPreset)))
          return error(422, "selection_unavailable");
        const selectedReferences = (input?.references ?? []) as string[];
        if (selectedReferences.some((id) => references.get(id)?.user !== user))
          return error(404, "not_found");
        if (
          selectedReferences.some((id) => {
            const kind = references.get(id)!.kind;
            return (
              input?.kind === "music" ||
              (kind === "image"
                ? !model.inputs?.referenceImages
                : kind === "video"
                  ? input?.kind !== "video" || !model.inputs?.referenceVideos
                  : input?.kind !== "video" || !model.inputs?.referenceAudios)
            );
          })
        )
          return error(422, "invalid_parameters");
        const parameters = input?.parameters as Record<string, unknown> | undefined;
        if (
          parameters &&
          Object.keys(parameters).length &&
          catalog.submission?.presetOnly !== false
        )
          return error(422, "invalid_parameters");
        // Synthetic upstream rejection verifies that the client never substitutes default values.
        if (parameters?.seconds === 99) return error(422, "invalid_parameters");
        if (loseBeforeAccept) {
          loseBeforeAccept = false;
          throw new Error("Synthetic pre-accept timeout");
        }
        const job: CreativeJob = { operationId, status: "queued", outputs: [] };
        remote.set(key, {
          user,
          request: input as CreativeInput,
          job,
        });
        if (losePutResponse) {
          losePutResponse = false;
          throw new Error("Synthetic lost response");
        }
        return Response.json(job, { status: 202 });
      }
      if (!stored) return error(404, "not_found");
      if (outputId) {
        const output = stored.job.outputs.find(
          (output) => output.id === decodeURIComponent(outputId),
        );
        return output
          ? new Response(new Uint8Array([1, 2, 3, 4]), {
              headers: { "content-type": output.mimeType },
            })
          : error(404, "not_found");
      }
      return Response.json(stored.job);
    },
  ) as unknown as typeof fetch;
  const provider = new UserCreativeProvider(config, fetcher);
  const identityReader = vi.fn(async (id: string) =>
    identities.has(id) ? { ...identities.get(id)! } : null,
  );
  const rebuild = () =>
    new CreativeAppConnector(
      config,
      provider,
      deps,
      identityReader,
      (context) => `test:${context.spaceId}:${context.userId}`,
    );
  connector = rebuild();
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
        connectorId: "creative",
        externalId: "creative",
        displayName: config.name,
        providerRef: String(row.providerRef),
      })),
  });
  const connect = async (userId = "user-a") => {
    const id = `connection-${userId}`;
    let row = connections.find((row) => row.id === id);
    if (!row) {
      row = {
        id,
        userId,
        spaceId: "space-a",
        connectorId: "creative",
        provider: "creative",
        displayName: config.name,
      };
      connections.push(row);
    }
    Object.assign(row, { status: "pending", providerRef: null });
    const auth = await connector.begin(
      {
        provider: "creative",
        redirectUrl: "https://app.example.test/integrations/callback",
      },
      context(userId),
    );
    Object.assign(row, {
      status: auth.authorizationUrl ? "pending" : "connected",
      providerRef: auth.state,
    });
    await connector.listConnectedExternalIds(context(userId));
    return row;
  };
  return {
    connector,
    rebuild,
    provider,
    fetcher,
    config,
    deps,
    db,
    effects,
    connections,
    messages,
    artifacts,
    runs,
    threads,
    identities,
    members,
    users,
    remote,
    references,
    referenceUploads,
    blobs,
    loseReferenceResponse: () => {
      loseUploadResponse = true;
    },
    history,
    tokens,
    hidden,
    context,
    connect,
    setAuthenticationAvailable: (value: boolean) => {
      authenticationAvailable = value;
    },
    setLocalEligibility: (value: boolean) => {
      localEligible = value;
    },
    setBillingAuthorized: (value: boolean) => {
      billingAuthorized = value;
    },
    setCatalog: (value: CreativeCapabilities) => {
      catalog = clone(value);
    },
    losePut: () => {
      losePutResponse = true;
    },
    loseBeforePut: () => {
      loseBeforeAccept = true;
    },
    putCount: () => history.filter((call) => call.method === "PUT").length,
  };
}
