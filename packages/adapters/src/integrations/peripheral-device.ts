import type {
  AdapterContext,
  ConnectorCall,
  ConnectorEvent,
  ConnectorProvider,
  ConnectorTool,
} from "@rakazo/adapter-kit";
import { deadlineSignal } from "@rakazo/core";
import type { PrismaClient } from "@rakazo/db";
import { z } from "zod";
import { peripheralVoiceDescriptions } from "./peripheral-voice.tool-definition.js";

const definitions = z.array(
  z.object({
    name: z.string().regex(/^[a-zA-Z0-9_-]{1,64}$/),
    description: z.string(),
    inputSchema: z.record(z.string(), z.unknown()),
    readOnly: z.boolean().optional(),
  }),
);

export class PeripheralDeviceConnector implements ConnectorProvider {
  constructor(
    private prisma: PrismaClient,
    private url: URL,
    private secret: string,
  ) {}

  describe() {
    return {
      id: "peripheral-device",
      contractVersion: "1",
      adapterVersion: "1",
      capabilities: { discover: true, oauth: false, secretsBrokered: true },
    };
  }

  private async origin(context: AdapterContext) {
    if (!context.runId || !context.botId) return;
    const run = await this.prisma.run.findFirst({
      where: {
        id: context.runId,
        userId: context.userId,
        spaceId: context.spaceId,
        botId: context.botId,
      },
      select: {
        sourceMessage: { select: { clientNonce: true, authorUserId: true } },
        steeringMessages: {
          where: { claimedAt: { not: null } },
          orderBy: { message: { seq: "desc" } },
          take: 1,
          select: { message: { select: { clientNonce: true, authorUserId: true } } },
        },
      },
    });
    const source = run?.steeringMessages[0]?.message ?? run?.sourceMessage;
    if (source?.authorUserId !== context.userId) return;
    const match = /^(?:pod:|call:[^:]+:)([a-f0-9]{64})\.([a-f0-9]{32})$/.exec(
      source.clientNonce ?? "",
    );
    if (match) return { deviceKey: match[1]!, turnId: match[2]! };
  }

  private async request(action: string, payload: object, signal: AbortSignal) {
    const response = await fetch(new URL(action, this.url), {
      method: "POST",
      redirect: "error",
      headers: { authorization: `Bearer ${this.secret}`, "content-type": "application/json" },
      body: JSON.stringify(payload),
      signal: deadlineSignal(action === "list" ? 3000 : 16000, signal),
    });
    if (!response.ok) throw new Error("当前设备未能确认操作，请检查设备连接。");
    return response.json() as Promise<unknown>;
  }

  async discoverTools(context: AdapterContext): Promise<ConnectorTool[]> {
    const origin = await this.origin(context);
    if (!origin) return [];
    const tools = definitions.parse(
      await this.request("list", { ...origin, runId: context.runId }, context.signal),
    );
    return tools.map(({ name, description, inputSchema, readOnly }) => ({
      name,
      description: peripheralVoiceDescriptions.get(name) ?? description,
      inputSchema,
      readOnly,
      route: { connectorId: this.describe().id, resourceId: origin.deviceKey, toolName: name },
    }));
  }

  async *execute(call: ConnectorCall, context: AdapterContext): AsyncGenerator<ConnectorEvent> {
    const origin = await this.origin(context);
    if (!origin || origin.deviceKey !== call.route?.resourceId) {
      yield { type: "error", message: "发话设备已更改，请在设备上重新发起操作。" };
      return;
    }
    try {
      const reply = z.object({ result: z.unknown() }).parse(
        await this.request(
          "call",
          {
            ...origin,
            runId: context.runId,
            tool: call.tool,
            args: call.args,
            executionId: call.executionId,
          },
          context.signal,
        ),
      );
      yield { type: "result", data: reply.result };
    } catch (error) {
      if (context.signal.aborted) throw error;
      yield { type: "error", message: "当前设备未能确认操作，请检查设备连接。" };
    }
  }
}

export function peripheralDeviceConnector(prisma: PrismaClient, source: NodeJS.ProcessEnv) {
  if (!source.PERIPHERAL_DEVICE_URL) return [];
  const url = new URL(source.PERIPHERAL_DEVICE_URL);
  const secret = source.PERIPHERAL_BRIDGE_SECRET?.trim();
  if (
    !secret ||
    secret.length < 32 ||
    url.username ||
    url.password ||
    (url.protocol !== "https:" &&
      !(url.protocol === "http:" && ["127.0.0.1", "[::1]", "localhost"].includes(url.hostname)))
  ) {
    throw new Error("Peripheral device tools require HTTPS or loopback and a bridge secret");
  }
  url.pathname = url.pathname.replace(/\/?$/, "/");
  return [new PeripheralDeviceConnector(prisma, url, secret)];
}
