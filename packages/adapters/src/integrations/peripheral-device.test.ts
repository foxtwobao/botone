import type { AdapterContext } from "@rakazo/adapter-kit";
import type { PrismaClient } from "@rakazo/db";
import { afterEach, expect, it, vi } from "vitest";
import { peripheralDeviceConnector } from "./peripheral-device.js";

const key = "a".repeat(64);
const turn = "b".repeat(32);
const context: AdapterContext = {
  operationId: "op",
  traceId: "trace",
  userId: "owner",
  botId: "bot",
  spaceId: "space",
  runId: "run",
  signal: new AbortController().signal,
};
const source = (clientNonce: string, authorUserId = context.userId) => ({
  clientNonce,
  authorUserId,
});

afterEach(() => vi.unstubAllGlobals());

it("routes the actual hardware result and rejects a device change during execution", async () => {
  const run = {
    sourceMessage: source(`pod:${key}.${turn}`),
    steeringMessages: [] as { message: ReturnType<typeof source> }[],
  };
  const findFirst = vi.fn(async () => run);
  const [connector] = peripheralDeviceConnector({ run: { findFirst } } as unknown as PrismaClient, {
    PERIPHERAL_DEVICE_URL: "http://127.0.0.1/internal/device-tools",
    PERIPHERAL_BRIDGE_SECRET: "test".repeat(8),
  });
  const tool = {
    name: "self_get_device_status",
    description: "State",
    inputSchema: { type: "object" },
  };
  const http = vi.fn(async (url: URL, options: RequestInit) => {
    const payload = JSON.parse(String(options.body));
    expect(payload).toMatchObject({ deviceKey: key, turnId: turn, runId: "run" });
    return Response.json(
      url.pathname.endsWith("/list")
        ? [tool, { ...tool, name: "pod_play_music" }, { ...tool, name: "pod_end_conversation" }]
        : { result: { volume: 30 } },
    );
  });
  vi.stubGlobal("fetch", http);
  const [discovered, music, standby] = await connector!.discoverTools(context);
  expect(discovered?.name).toBe("self_get_device_status");
  expect(music?.description).toContain("唱歌");
  expect(standby?.description).toContain("待机");
  const call = { tool: tool.name, executionId: "one", args: {}, route: discovered!.route };
  expect((await connector!.execute(call, context).next()).value).toEqual({
    type: "result",
    data: { volume: 30 },
  });
  run.steeringMessages.push({ message: source(`call:voice:${"c".repeat(64)}.${turn}`) });
  expect((await connector!.execute(call, context).next()).value).toMatchObject({ type: "error" });
  run.steeringMessages[0] = { message: source("ordinary-web-message") };
  expect(await connector!.discoverTools(context)).toEqual([]);
  run.steeringMessages[0] = { message: source(`pod:${key}.${turn}`, "another-owner") };
  expect(await connector!.discoverTools(context)).toEqual([]);
  expect(http).toHaveBeenCalledTimes(2);
});
