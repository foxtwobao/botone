import { describe, expect, it } from "vitest";
import { ConnectorRegistry } from "../../../integrations/connector-registry.js";
import { feishuFixture } from "./feishu.test-support.js";

async function tool(
  f: ReturnType<typeof feishuFixture>,
  name: string,
  args: Record<string, unknown>,
  executionId = "execution-a",
) {
  const context = f.context();
  const registry = new ConnectorRegistry([f.connector]);
  const selected = (await registry.discoverTools(context)).find((t) => t.route?.toolName === name)!;
  expect(selected).toBeDefined();
  const events = [];
  for await (const event of registry.execute(
    { tool: selected.name, route: selected.route, args, executionId },
    context,
  ))
    events.push(event);
  return events;
}

describe("feishu office connector offline contract", () => {
  it("lists the app and auto-connects a member once the credentials are accepted", async () => {
    const f = feishuFixture();
    expect(await f.connector.catalog(f.context())).toMatchObject([
      { slug: "feishu", name: "Feishu", noAuth: true, connected: true },
    ]);
  });

  it("keeps the connection pending when the app credentials are rejected", async () => {
    const f = feishuFixture();
    f.setVerifyOk(false);
    expect(await f.connector.catalog(f.context())).toMatchObject([{ connected: false }]);
    expect(f.connections[0]?.status).toBe("pending");
    expect(await f.connector.listConnectedExternalIds(f.context())).toEqual([]);
  });

  it("discovers the office tools only for a connected account", async () => {
    const f = feishuFixture();
    const registry = new ConnectorRegistry([f.connector]);
    expect(await registry.discoverTools(f.context())).toEqual([]);
    await f.connect();
    const tools = await registry.discoverTools(f.context());
    expect(tools.map((t) => t.route?.toolName).sort()).toEqual([
      "feishu_create_doc",
      "feishu_create_task",
      "feishu_list_tasks",
      "feishu_read_doc",
    ]);
  });

  it("creates and reads a document through the provider", async () => {
    const f = feishuFixture();
    await f.connect();
    expect(await tool(f, "feishu_create_doc", { title: "周报" })).toEqual([
      { type: "result", data: { documentId: "doc-synthetic", title: "周报" } },
    ]);
    expect(await tool(f, "feishu_read_doc", { documentId: "doc-synthetic" })).toEqual([
      { type: "result", data: { content: "content of doc-synthetic" } },
    ]);
    expect(f.calls.map((c) => c.method)).toEqual(["createDoc", "readDoc"]);
  });

  it("creates and lists tasks", async () => {
    const f = feishuFixture();
    await f.connect();
    expect(
      await tool(f, "feishu_create_task", { summary: "跟进客户", dueTimestamp: 1_700_000_000_000 }),
    ).toEqual([{ type: "result", data: { taskId: "task-synthetic", summary: "跟进客户" } }]);
    expect(await tool(f, "feishu_list_tasks", { pageSize: 10 })).toEqual([
      {
        type: "result",
        data: { tasks: [{ taskId: "task-synthetic", summary: "Synthetic task" }] },
      },
    ]);
  });

  it("refuses invalid arguments without calling the provider", async () => {
    const f = feishuFixture();
    await f.connect();
    expect(await tool(f, "feishu_create_doc", {})).toEqual([
      { type: "error", message: "Feishu: invalid_parameters" },
    ]);
    expect(f.calls).toEqual([]);
  });

  it("hides the app outside its configured spaces", async () => {
    const f = feishuFixture();
    expect(await f.connector.catalog({ ...f.context(), spaceId: "space-b" })).toEqual([]);
  });
});
