import type { NativeExecutionEvent } from "@rakazo/adapter-kit";
import { describe, expect, it } from "vitest";
import { deepseekModelLabel, deepseekWireValue } from "./acp-config.js";
import { createClaudeDriver } from "./claude.js";
import { createCodexDriver } from "./codex.js";
import { createDeepseekDriver } from "./deepseek.js";
import { FakeHarnessProcess, startRequest, tick } from "./protocol.test-support.js";

describe("native protocol conformance", () => {
  it.each([false, true])(
    "defaults to unattended externally sandboxed execution when resuming=%s",
    async (resume) => {
      const process = new FakeHarnessProcess();
      process.reply = (frame) => {
        if (frame.method === "initialize") process.receive({ id: frame.id, result: {} });
        if (frame.method === "thread/start" || frame.method === "thread/resume")
          process.receive({ id: frame.id, result: { thread: { id: "thread" } } });
        if (frame.method === "turn/start")
          process.receive({ id: frame.id, result: { turn: { id: "turn" } } });
      };
      await createCodexDriver(process, "test", () => {}).start(
        startRequest(resume ? { session: { id: "thread", engineVersion: "test" } } : {}),
      );
      expect(
        process.sent.find((frame) => frame.method === (resume ? "thread/resume" : "thread/start"))
          ?.params,
      ).toMatchObject({ approvalPolicy: "never", sandbox: "workspace-write" });
      expect(process.sent.find((frame) => frame.method === "turn/start")?.params).toMatchObject({
        approvalPolicy: "never",
        sandboxPolicy: {
          type: "externalSandbox",
          networkAccess: "enabled",
        },
      });
    },
  );

  it("routes an early completion to the returned turn, observes tools, and never runs them", async () => {
    const process = new FakeHarnessProcess();
    const events: NativeExecutionEvent[] = [];
    process.reply = (frame) => {
      if (frame.method === "initialize") process.receive({ id: frame.id, result: {} });
      if (frame.method === "thread/start")
        process.receive({ id: frame.id, result: { thread: { id: "native-thread" } } });
      if (frame.method === "turn/start") {
        process.receive({ id: frame.id, result: { turn: { id: "native-turn" } } });
        process.receive({
          method: "item/started",
          params: {
            threadId: "native-thread",
            turnId: "native-turn",
            item: { id: "tool-1", type: "commandExecution", command: "touch result.txt" },
          },
        });
        process.receive({
          method: "item/agentMessage/delta",
          params: { threadId: "other-thread", delta: "private" },
        });
        process.receive({
          method: "item/agentMessage/delta",
          params: { threadId: "native-thread", turnId: "native-turn", delta: "Done" },
        });
        process.receive({
          method: "thread/tokenUsage/updated",
          params: {
            threadId: "native-thread",
            turnId: "native-turn",
            tokenUsage: { total: { inputTokens: 120, outputTokens: 14 } },
          },
        });
        process.receive({
          method: "turn/completed",
          params: { threadId: "native-thread", turn: { id: "native-turn", status: "completed" } },
        });
      }
    };
    await createCodexDriver(process, "test", (event) => events.push(event)).start(startRequest());
    expect(events.map((event) => event.type)).toEqual([
      "session",
      "operation",
      "text",
      "usage",
      "completed",
    ]);
    expect(events).toContainEqual({ type: "text", text: "Done" });
    expect(events).toContainEqual({
      type: "usage",
      scope: "session",
      inputTokens: 120,
      outputTokens: 14,
      costUsd: null,
    });
    expect(process.sent.map((frame) => frame.method)).toEqual([
      "initialize",
      "initialized",
      "thread/start",
      "turn/start",
    ]);
  });

  it("requires the original approval and sends a once-only decision exactly once", async () => {
    const process = new FakeHarnessProcess();
    const events: NativeExecutionEvent[] = [];
    process.reply = (frame) => {
      if (frame.method === "initialize") process.receive({ id: frame.id, result: {} });
      if (frame.method === "thread/start")
        process.receive({ id: frame.id, result: { thread: { id: "thread" } } });
      if (frame.method === "turn/start")
        process.receive({ id: frame.id, result: { turn: { id: "turn" } } });
    };
    const driver = createCodexDriver(process, "test", (event) => events.push(event));
    await driver.start(startRequest());
    process.receive({
      id: "approval-7",
      method: "item/commandExecution/requestApproval",
      params: { threadId: "thread", command: "write output" },
    });
    const ask = events.find((event) => event.type === "interaction");
    if (ask?.type !== "interaction") throw new Error("Expected approval");
    expect(await driver.respond("another-request", "allow")).toBe(false);
    expect(await driver.respond(ask.request.id, "allow")).toBe(true);
    expect(await driver.respond(ask.request.id, "allow")).toBe(true);
    expect(await driver.respond(ask.request.id, "deny")).toBe(false);
    expect(process.sent.filter((frame) => frame.id === "approval-7")).toEqual([
      { jsonrpc: "2.0", id: "approval-7", result: { decision: "accept" } },
    ]);
    const elicitation = {
      threadId: "thread",
      turnId: "turn",
      serverName: "platform",
      mode: "form",
      _meta: {
        codex_approval_kind: "mcp_tool_call",
        persist: ["session", "always"],
        tool_name: "publish_file",
        tool_params: { path: "/workspace/result.txt" },
      },
      requestedSchema: { type: "object", properties: {} },
    };
    process.receive({ id: "mcp", method: "mcpServer/elicitation/request", params: elicitation });
    const mcp = events.at(-1);
    if (mcp?.type !== "interaction") throw new Error("Expected native tool approval");
    expect(mcp.request.kind).toBe("permission");
    expect(await driver.respond(mcp.request.id, "always")).toBe(false);
    expect(await driver.respond(mcp.request.id, "allow")).toBe(true);
    expect(process.sent.at(-1)).toEqual({
      jsonrpc: "2.0",
      id: "mcp",
      result: { action: "accept", content: {} },
    });
    process.receive({
      id: "credential-form",
      method: "mcpServer/elicitation/request",
      params: {
        ...elicitation,
        requestedSchema: { type: "object", properties: { token: { type: "string" } } },
      },
    });
    await tick();
    expect(process.sent.at(-1)).toEqual({
      jsonrpc: "2.0",
      id: "credential-form",
      result: { action: "decline" },
    });
    const questions = [{ id: "policy", question: "Which policy?", options: [{ label: "Allow" }] }];
    process.receive({
      id: "question",
      method: "item/tool/requestUserInput",
      params: { threadId: "thread", questions },
    });
    const question = events.at(-1);
    if (question?.type !== "interaction") throw new Error("Expected question");
    expect(question.request.kind).toBe("question");
    expect(await driver.respond(question.request.id, "A custom answer")).toBe(true);
    expect(process.sent.at(-1)?.result).toEqual({
      answers: { policy: { answers: ["A custom answer"] } },
    });
    process.receive({
      id: "multiple-questions",
      method: "item/tool/requestUserInput",
      params: {
        threadId: "thread",
        questions: [...questions, { id: "other", question: "Other?" }],
      },
    });
    await tick();
    expect(process.sent.at(-1)?.error).toMatchObject({ code: -32601 });
    await driver.cancel();
  });

  it("filters resumed ACP history, confirms model selection, and waits for prompt's response", async () => {
    const process = new FakeHarnessProcess();
    const events: NativeExecutionEvent[] = [];
    process.reply = (frame) => {
      const params = frame.params as Record<string, unknown>;
      if (frame.method === "initialize")
        process.receive({ id: frame.id, result: { protocolVersion: 1, authMethods: [] } });
      if (frame.method === "session/resume") {
        process.receive({
          method: "session/update",
          params: {
            sessionId: "session",
            update: {
              sessionUpdate: "agent_message_chunk",
              content: { type: "text", text: "Old history" },
            },
          },
        });
        process.receive({
          id: frame.id,
          result: {
            sessionId: "session",
            configOptions: [
              {
                id: "model",
                type: "select",
                currentValue: "old",
                options: [{ value: '["provider","model"]' }],
              },
            ],
          },
        });
      }
      if (frame.method === "session/set_config_option")
        process.receive({
          id: frame.id,
          result: { configOptions: [{ id: "model", type: "select", currentValue: params.value }] },
        });
    };
    const driver = createDeepseekDriver(process, "test", (event) => events.push(event));
    await driver.start(
      startRequest({ session: { id: "session", engineVersion: "test" }, model: "provider/model" }),
    );
    expect(events.map((event) => event.type)).toEqual(["session"]);
    expect(process.sent.at(-1)?.method).toBe("session/prompt");
    const prompt = process.sent.at(-1)!;
    process.receive({
      method: "session/update",
      params: {
        sessionId: "session",
        update: {
          sessionUpdate: "agent_message_chunk",
          content: { type: "text", text: "New output" },
        },
      },
    });
    expect(events.at(-1)?.type).toBe("text");
    process.receive({ id: prompt.id, result: { stopReason: "end_turn" } });
    await tick();
    expect(events.at(-1)).toEqual({ type: "completed" });
    expect(JSON.stringify(process.sent.at(-1)?.params)).not.toContain("Use the workspace");
  });

  it("never promotes an ACP allow-always option to once-only permission", async () => {
    const process = new FakeHarnessProcess();
    process.reply = (frame) => {
      if (frame.method === "initialize")
        process.receive({ id: frame.id, result: { protocolVersion: 1 } });
      if (frame.method === "session/new")
        process.receive({ id: frame.id, result: { sessionId: "session" } });
    };
    const events: NativeExecutionEvent[] = [];
    const driver = createDeepseekDriver(process, "test", (event) => events.push(event));
    await driver.start(startRequest());
    process.receive({
      id: "permission",
      method: "session/request_permission",
      params: { sessionId: "session", options: [{ kind: "allow_always", optionId: "permanent" }] },
    });
    await tick();
    expect(process.sent.at(-1)).toEqual({
      jsonrpc: "2.0",
      id: "permission",
      result: { outcome: { outcome: "cancelled" } },
    });
    expect(events.some((event) => event.type === "interaction")).toBe(false);
    await driver.cancel();
  });

  it("confirms the resumed Claude session once and rejects a replacement session", async () => {
    const process = new FakeHarnessProcess();
    const events: NativeExecutionEvent[] = [];
    const driver = createClaudeDriver(process, "test", (event) => events.push(event));
    await driver.start(startRequest({ session: { id: "original", engineVersion: "test" } }));
    expect(events).toEqual([]);
    process.receive({ type: "system", subtype: "init", session_id: "original" });
    process.receive({ type: "assistant", session_id: "original", message: { content: [] } });
    await tick();
    expect(events).toEqual([
      { type: "session", session: { id: "original", engineVersion: "test" } },
    ]);
    process.receive({ type: "system", subtype: "init", session_id: "replacement" });
    await tick();
    expect(events.at(-1)).toEqual({ type: "failed", code: "engine_protocol_failed" });
    await driver.cancel();
  });

  it("keeps Claude native permission input intact and declines unsupported elicitation", async () => {
    const process = new FakeHarnessProcess();
    const events: NativeExecutionEvent[] = [];
    const driver = createClaudeDriver(process, "test", (event) => events.push(event));
    await driver.start(startRequest());
    const response = process.permission!({
      id: "permission",
      tool: "Write",
      input: { file_path: "result.txt", content: "hello" },
    });
    expect(await driver.respond("permission", "deny")).toBe(true);
    await expect(response).resolves.toMatchObject({ behavior: "deny" });
    const question = process.permission!({
      id: "question",
      tool: "AskUserQuestion",
      input: { questions: [{ question: "Which policy?" }] },
    });
    expect(await driver.respond("question", "A custom answer")).toBe(true);
    await expect(question).resolves.toMatchObject({
      behavior: "allow",
      updatedInput: { answers: { "Which policy?": "A custom answer" } },
    });
    await expect(
      process.permission!({
        id: "multiple-questions",
        tool: "AskUserQuestion",
        input: { questions: [{ question: "First?" }, { question: "Second?" }] },
      }),
    ).resolves.toMatchObject({ behavior: "deny" });
    process.receive({
      type: "control_request",
      request_id: "form",
      request: {
        subtype: "elicitation",
        requested_schema: { properties: { token: { type: "string" } } },
      },
    });
    await tick();
    expect(process.sent.at(-1)).toEqual({
      type: "control_response",
      response: { subtype: "success", request_id: "form", response: { action: "decline" } },
    });
    process.receive({
      type: "stream_event",
      event: { type: "content_block_delta", delta: { type: "text_delta", text: "Done" } },
    });
    process.receive({ type: "assistant", message: { content: [{ type: "text", text: "Done" }] } });
    process.receive({ type: "result", subtype: "success", total_cost_usd: 0 });
    await tick();
    expect(events.filter((event) => event.type === "text")).toEqual([
      { type: "text", text: "Done" },
    ]);
    expect(events.find((event) => event.type === "usage")).toEqual({
      type: "usage",
      inputTokens: null,
      outputTokens: null,
      costUsd: null,
    });
  });
});

it("keeps ACP connection namespaces on the wire while displaying only the model path", () => {
  const model = "connection/vendor/model";
  expect(deepseekModelLabel(model)).toBe("vendor/model");
  expect(deepseekWireValue(model)).toBe('["connection","vendor/model"]');
  expect(deepseekModelLabel("unqualified-model")).toBe("unqualified-model");
});
