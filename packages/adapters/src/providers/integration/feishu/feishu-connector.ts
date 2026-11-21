import { createHash, randomUUID } from "node:crypto";
import type {
  AdapterContext,
  ConnectorCall,
  ConnectorEvent,
  ConnectorTool,
  ManagedConnectorProvider,
} from "@rakazo/adapter-kit";
import { LeaseHeldError, readJsonColumn, recordSecurityEvent, withLease } from "@rakazo/db";
import { bestEffort } from "@rakazo/logging";
import { z } from "zod";
import type { ApplicationServices } from "../../../configured-apps.js";
import { scopeConnectorTools } from "../../../integrations/connector-accounts.js";
import { TOOL_RESULT_TEXT_LIMIT } from "../../../runtime/pi/pi-runtime-limits.js";
import type { FeishuConnectionConfig, FeishuOfficeProvider } from "./feishu-contracts.js";
import {
  feishuCreateDocSchema,
  feishuCreateTaskSchema,
  feishuListTasksSchema,
  feishuReadDocSchema,
} from "./feishu-contracts.js";
import type { FeishuUserToken } from "./feishu-oauth.js";
import {
  exchangeFeishuCode,
  feishuAuthorizeUrl,
  feishuTokenSchema,
  refreshFeishuToken,
} from "./feishu-oauth.js";
import { FeishuServiceError, UserLarkFeishuProvider } from "./feishu-provider.js";

const ID = "feishu";

const connectionMetadataSchema = z.object({
  redirectUri: z.string().optional(),
  oauthState: z.string().optional(),
});

const TOOLS: Array<ConnectorTool & { title: string }> = [
  {
    name: "feishu_create_doc",
    title: "Create document",
    description:
      "Create a Feishu document and return its ID and title. Optionally place it in a folder by its folder token.",
    readOnly: false,
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["title"],
      properties: {
        title: { type: "string", minLength: 1, maxLength: 200 },
        folderToken: { type: "string", minLength: 1, maxLength: 200 },
      },
    },
  },
  {
    name: "feishu_read_doc",
    title: "Read document",
    description:
      "Read the plain-text content of an accessible Feishu document, by its document ID.",
    readOnly: true,
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["documentId"],
      properties: { documentId: { type: "string", minLength: 1, maxLength: 200 } },
    },
  },
  {
    name: "feishu_create_task",
    title: "Create task",
    description:
      "Create a Feishu task with a summary, optional description and optional due time (epoch milliseconds).",
    readOnly: false,
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["summary"],
      properties: {
        summary: { type: "string", minLength: 1, maxLength: 500 },
        description: { type: "string", maxLength: 4000 },
        dueTimestamp: { type: "integer", minimum: 0 },
      },
    },
  },
  {
    name: "feishu_list_tasks",
    title: "List tasks",
    description: "List accessible Feishu tasks. Continue from nextPageToken when present.",
    readOnly: true,
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        pageSize: { type: "integer", minimum: 1, maximum: 100 },
        pageToken: { type: "string", minLength: 1, maxLength: 500 },
      },
    },
  },
];

interface FeishuIdentity {
  appId: string;
  domain: string;
}
type ConnectionRow = {
  id: string;
  status: string;
  providerRef: string | null;
  secretId: string | null;
  displayName: string;
  metadata: unknown;
};

/** One optional Feishu office app, on the same catalog, connection actions and approvals as every client. */
export class FeishuOfficeConnector implements ManagedConnectorProvider {
  constructor(
    private readonly config: FeishuConnectionConfig,
    private readonly provider: FeishuOfficeProvider,
    private readonly deps: ApplicationServices,
    private readonly connectionScope: (context: AdapterContext) => string,
  ) {}
  private get userMode() {
    return this.config.identity === "user";
  }
  describe() {
    return {
      id: ID,
      contractVersion: "1",
      adapterVersion: "0.1.0",
      capabilities: { discover: true, oauth: this.userMode, secretsBrokered: true },
    };
  }
  private async identity(context: AdapterContext): Promise<FeishuIdentity> {
    if (this.config.spaceIds && !this.config.spaceIds.includes(context.spaceId))
      throw new FeishuServiceError("forbidden", 403);
    const [member, user] = await Promise.all([
      this.deps.prisma.spaceMember.findUnique({
        where: { spaceId_userId: { spaceId: context.spaceId, userId: context.userId } },
      }),
      this.deps.prisma.user.findUnique({ where: { id: context.userId }, select: { id: true } }),
    ]);
    if (!member || !user) throw new FeishuServiceError("forbidden", 403);
    return { appId: this.config.appId, domain: this.config.domain };
  }
  private prefix(context: AdapterContext, identity: FeishuIdentity) {
    return createHash("sha256")
      .update(JSON.stringify([identity.appId, identity.domain, context.spaceId, context.userId]))
      .digest("hex");
  }
  private async rows(context: AdapterContext, statuses = ["connected"]) {
    return this.deps.prisma.connection.findMany({
      where: {
        spaceId: context.spaceId,
        userId: context.userId,
        connectorId: ID,
        provider: ID,
        status: { in: statuses },
      },
    });
  }
  private async authorizedRows(context: AdapterContext) {
    const identity = await this.identity(context);
    const prefix = this.prefix(context, identity);
    return (await this.rows(context)).filter((row) => row.providerRef === prefix);
  }
  /** App identity auto-provisions once credentials are accepted; user identity waits for OAuth. */
  async ensureConnection(context: AdapterContext) {
    const identity = await this.identity(context);
    const prefix = this.prefix(context, identity);
    const row = await this.deps.prisma.$transaction(async (tx) => {
      const scope = this.connectionScope(context);
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext('connection-provider'), hashtext(${scope}))`;
      const rows = await tx.connection.findMany({
        where: { spaceId: context.spaceId, userId: context.userId, connectorId: ID, provider: ID },
      });
      const existing = rows.find(
        (row) => ["pending", "connected"].includes(row.status) && row.providerRef === prefix,
      );
      if (existing || rows.length) return existing;
      return tx.connection.create({
        data: {
          id: randomUUID(),
          spaceId: context.spaceId,
          userId: context.userId,
          connectorId: ID,
          provider: ID,
          displayName: this.config.name,
          status: "pending",
          providerRef: prefix,
        },
      });
    });
    if (!row?.providerRef || row.status !== "pending" || this.userMode) return;
    try {
      await this.provider.verify(context.signal);
    } catch (error) {
      if (error instanceof FeishuServiceError && error.code === "authorization_required") return;
      throw error;
    }
    const updated = await this.deps.prisma.connection.updateMany({
      where: { id: row.id, status: "pending", providerRef: row.providerRef },
      data: { status: "connected" },
    });
    if (updated.count) await this.recordCreated(context, row.id);
  }
  private async recordCreated(context: AdapterContext, connectionId: string) {
    await recordSecurityEvent({
      type: "credential.created",
      userId: context.userId,
      spaceId: context.spaceId,
      metadata: { procedure: context.operationId, kind: "connection", connectionId },
    });
  }
  private async storeTokens(context: AdapterContext, row: ConnectionRow, tokens: FeishuUserToken) {
    const secrets = this.deps.secrets;
    if (!secrets) throw new FeishuServiceError("unavailable");
    const record = await secrets.put(JSON.stringify(tokens), context);
    await this.deps.prisma.secret.create({
      data: {
        id: record.id,
        userId: context.userId,
        spaceId: context.spaceId,
        kind: ID,
        ciphertext: record.ciphertext,
      },
    });
    const superseded = row.secretId;
    await this.deps.prisma.connection.update({
      where: { id: row.id },
      data: { secretId: record.id },
    });
    row.secretId = record.id;
    if (superseded)
      await bestEffort(
        "delete superseded Feishu secret",
        this.deps.prisma.secret.delete({ where: { id: superseded } }),
      );
  }
  private async loadTokens(context: AdapterContext, row: ConnectionRow): Promise<FeishuUserToken> {
    const secrets = this.deps.secrets;
    if (!secrets || !row.secretId) throw new FeishuServiceError("authorization_required", 403);
    const secret = await this.deps.prisma.secret.findUnique({ where: { id: row.secretId } });
    if (!secret) throw new FeishuServiceError("authorization_required", 403);
    const plaintext = await secrets.load(secret.ciphertext, secret.id);
    let parsed;
    try {
      parsed = feishuTokenSchema.safeParse(JSON.parse(plaintext));
    } catch {
      throw new FeishuServiceError("authorization_required", 403);
    }
    if (!parsed.success) throw new FeishuServiceError("authorization_required", 403);
    return parsed.data;
  }
  /** Load the person's token, refreshing through Feishu shortly before it expires. */
  private async userToken(context: AdapterContext, row: ConnectionRow): Promise<FeishuUserToken> {
    const expiring = (t: FeishuUserToken) => !!t.refreshToken && t.expiresAt < Date.now() + 60_000;
    const tokens = await this.loadTokens(context, row);
    if (!expiring(tokens)) return tokens;
    try {
      // One refresh at a time per connection across processes; Feishu rotates refresh tokens.
      return await withLease(
        this.deps.prisma,
        `feishu-refresh:${row.id}`,
        { ttlMs: 30_000, signal: context.signal },
        async () => {
          const fresh = await this.deps.prisma.connection.findUnique({ where: { id: row.id } });
          if (!fresh) throw new FeishuServiceError("authorization_required", 403);
          row.secretId = fresh.secretId;
          const current = await this.loadTokens(context, row);
          if (!current.refreshToken || current.expiresAt >= Date.now() + 60_000) return current;
          const refreshed = await refreshFeishuToken(
            this.config,
            current.refreshToken,
            context.signal,
          );
          await this.storeTokens(context, row, refreshed);
          await recordSecurityEvent({
            type: "credential.changed",
            userId: context.userId,
            spaceId: context.spaceId,
            metadata: { kind: "connection", connectionId: row.id },
          });
          return refreshed;
        },
      );
    } catch (error) {
      if (error instanceof LeaseHeldError) {
        // Another run holds the refresh; use the current token, still valid until expiry.
        const fresh = await this.deps.prisma.connection.findUnique({ where: { id: row.id } });
        if (fresh) row.secretId = fresh.secretId;
        return this.loadTokens(context, row);
      }
      throw error;
    }
  }
  private async providerFor(
    context: AdapterContext,
    row: ConnectionRow,
  ): Promise<FeishuOfficeProvider> {
    if (!this.userMode) return this.provider;
    const tokens = await this.userToken(context, row);
    return new UserLarkFeishuProvider(this.config, tokens.accessToken);
  }
  private async authorize(context: AdapterContext, id: string, ref: string) {
    const identity = await this.identity(context);
    const row = await this.deps.prisma.connection.findFirst({
      where: {
        id,
        spaceId: context.spaceId,
        userId: context.userId,
        connectorId: ID,
        provider: ID,
        status: "connected",
        providerRef: ref,
      },
    });
    if (!row || ref !== this.prefix(context, identity))
      throw new FeishuServiceError("forbidden", 403);
    return row;
  }
  async catalog(context: AdapterContext, query = "") {
    if (
      (this.config.spaceIds && !this.config.spaceIds.includes(context.spaceId)) ||
      (query &&
        !this.config.name.toLowerCase().includes(query.toLowerCase()) &&
        !ID.includes(query.toLowerCase()))
    )
      return [];
    const connected =
      (await bestEffort("list connected Feishu apps", this.listConnectedExternalIds(context))) ??
      [];
    return [
      {
        connectorId: ID,
        slug: ID,
        name: this.config.name,
        logo: this.config.icon ?? null,
        connected: connected.length > 0,
        noAuth: !this.userMode,
      },
    ];
  }
  async listConnectedExternalIds(context: AdapterContext) {
    await this.ensureConnection(context);
    const identity = await this.identity(context);
    const prefix = this.prefix(context, identity);
    const rows = (await this.rows(context, ["pending", "connected"])).filter(
      (row) => row.providerRef === prefix,
    );
    return rows.some((row) => row.status === "connected") ? [ID] : [];
  }
  async listReconnectRefs(context: AdapterContext) {
    const rows = await this.rows(context, ["pending", "connected"]);
    try {
      const identity = await this.identity(context);
      const prefix = this.prefix(context, identity);
      return rows
        .filter((row) => row.providerRef !== prefix)
        .flatMap((row) => (row.providerRef ? [row.providerRef] : []));
    } catch (error) {
      if (error instanceof FeishuServiceError && error.code === "forbidden")
        return rows.flatMap((row) => (row.providerRef ? [row.providerRef] : []));
      throw error;
    }
  }
  async begin(request: { provider: string; redirectUrl: string }, context: AdapterContext) {
    if (request.provider !== ID) throw new FeishuServiceError("not_found", 404);
    const identity = await this.identity(context);
    const prefix = this.prefix(context, identity);
    if (!this.userMode) return { state: prefix, authorizationUrl: null };
    // Random per-request state, persisted server-side, so a callback cannot be forged or replayed.
    const state = randomUUID();
    await this.ensureConnection(context);
    await this.deps.prisma.connection.updateMany({
      where: {
        spaceId: context.spaceId,
        userId: context.userId,
        connectorId: ID,
        provider: ID,
        providerRef: prefix,
        status: { in: ["pending", "connected"] },
      },
      data: { metadata: { redirectUri: request.redirectUrl, oauthState: state } },
    });
    return { state, authorizationUrl: feishuAuthorizeUrl(this.config, request.redirectUrl, state) };
  }
  async connectionReady(context: AdapterContext, externalId: string) {
    if (externalId !== ID) return false;
    const identity = await this.identity(context);
    const prefix = this.prefix(context, identity);
    const eligible = (await this.rows(context, ["pending", "connected"])).find(
      (row) => row.providerRef === prefix,
    );
    if (!eligible?.providerRef) return false;
    try {
      if (this.userMode) {
        if (eligible.status !== "connected") return false;
        await (await this.providerFor(context, eligible)).verify(context.signal);
      } else {
        await this.provider.verify(context.signal);
      }
      return true;
    } catch (error) {
      if (error instanceof FeishuServiceError && error.code === "authorization_required")
        return false;
      throw error;
    }
  }
  async complete(request: { state: string; code?: string }, context: AdapterContext) {
    const identity = await this.identity(context);
    if (this.userMode) {
      if (!this.deps.secrets || !request.code)
        throw new FeishuServiceError("authorization_required", 403);
      const meta = (row: ConnectionRow) =>
        readJsonColumn(
          connectionMetadataSchema,
          row.metadata,
          { table: "connections", column: "metadata", id: row.id },
          { fallback: {} },
        );
      const row = (await this.rows(context, ["pending", "connected"])).find(
        (row) => meta(row).oauthState === request.state,
      );
      if (!row) throw new FeishuServiceError("forbidden", 403);
      const redirectUri = meta(row).redirectUri;
      if (!redirectUri) throw new FeishuServiceError("authorization_required", 403);
      const tokens = await exchangeFeishuCode(
        this.config,
        request.code,
        redirectUri,
        context.signal,
      );
      await this.storeTokens(context, row, tokens);
      // Consume the one-time state so the callback cannot be replayed.
      await this.deps.prisma.connection.updateMany({
        where: { id: row.id },
        data: { status: "connected", metadata: {} },
      });
      await this.recordCreated(context, row.id);
      return { connectionRef: row.providerRef! };
    }
    if (request.state !== this.prefix(context, identity))
      throw new FeishuServiceError("forbidden", 403);
    if (!(await this.connectionReady(context, ID)))
      throw new FeishuServiceError("authorization_required", 403);
    return { connectionRef: request.state };
  }
  async revoke(connectionRef: string, context: AdapterContext) {
    const row = await this.deps.prisma.connection.findFirst({
      where: {
        spaceId: context.spaceId,
        userId: context.userId,
        connectorId: ID,
        provider: ID,
        providerRef: connectionRef,
      },
    });
    if (!row) return;
    if (row.secretId)
      await bestEffort(
        "delete revoked Feishu secret",
        this.deps.prisma.secret.delete({ where: { id: row.secretId } }),
      );
    await this.deps.prisma.connection.updateMany({
      where: { id: row.id },
      data: { status: "revoked" },
    });
    await recordSecurityEvent({
      type: "credential.deleted",
      userId: context.userId,
      spaceId: context.spaceId,
      metadata: { kind: "connection", connectionId: row.id },
    });
  }
  async discoverTools(context: AdapterContext) {
    const allowed =
      (await bestEffort("list authorized Feishu connections", this.authorizedRows(context))) ?? [];
    const selected = context.connectedConnections;
    const displayOnly = !context.runId && context.operationId === "connections.tools";
    return allowed
      .filter((row) =>
        selected?.some(
          (item) =>
            item.id === row.id && item.connectorId === ID && item.providerRef === row.providerRef,
        ),
      )
      .flatMap((row) =>
        scopeConnectorTools(TOOLS, {
          id: row.id,
          connectorId: ID,
          externalId: ID,
          displayName: row.displayName,
          providerRef: row.providerRef!,
        }).map((tool, index) => (displayOnly ? { ...tool, name: TOOLS[index]!.title } : tool)),
      );
  }
  async *execute(call: ConnectorCall, context: AdapterContext): AsyncIterable<ConnectorEvent> {
    try {
      const tool = (await this.discoverTools(context)).find(
        (item) =>
          (item.name === call.tool || item.route?.toolName === call.tool) &&
          item.route?.connectionId === call.route?.connectionId,
      );
      if (!tool?.route?.connectionId || typeof tool.route.resourceRevision !== "string")
        throw new FeishuServiceError("forbidden", 403);
      const row = await this.authorize(
        context,
        tool.route.connectionId,
        tool.route.resourceRevision,
      );
      const provider = await this.providerFor(context, row);
      let data: unknown;
      switch (tool.route.toolName) {
        case "feishu_create_doc": {
          const parsed = feishuCreateDocSchema.safeParse(call.args);
          if (!parsed.success) throw new FeishuServiceError("invalid_parameters", 422);
          data = await provider.createDoc(parsed.data, context.signal);
          break;
        }
        case "feishu_read_doc": {
          const parsed = feishuReadDocSchema.safeParse(call.args);
          if (!parsed.success) throw new FeishuServiceError("invalid_parameters", 422);
          const content = await provider.readDoc(parsed.data.documentId, context.signal);
          data = { content: content.slice(0, TOOL_RESULT_TEXT_LIMIT) };
          break;
        }
        case "feishu_create_task": {
          const parsed = feishuCreateTaskSchema.safeParse(call.args);
          if (!parsed.success) throw new FeishuServiceError("invalid_parameters", 422);
          data = await provider.createTask(parsed.data, context.signal);
          break;
        }
        case "feishu_list_tasks": {
          const parsed = feishuListTasksSchema.safeParse(call.args);
          if (!parsed.success) throw new FeishuServiceError("invalid_parameters", 422);
          data = await provider.listTasks(parsed.data, context.signal);
          break;
        }
        default:
          throw new FeishuServiceError("forbidden", 403);
      }
      yield { type: "result", data };
    } catch (error) {
      const denial = error instanceof FeishuServiceError ? error : undefined;
      yield {
        type: "error",
        message: denial?.permissionUrl
          ? `${denial.message}. Grant the missing permission on Feishu: ${denial.permissionUrl}`
          : (denial?.message ?? "Feishu: unavailable"),
      };
    }
  }
}
