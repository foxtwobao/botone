import type { NativeExecutionEvent } from "@rakazo/adapter-kit";
import { describe, expect, it } from "vitest";
import { createHostCodexDriver } from "./codex.js";
import { FakeHarnessProcess, startRequest, tick } from "./protocol.test-support.js";

describe("host sandbox policy", () => {
  const sandbox = {
    type: "workspaceWrite",
    writableRoots: ["/workspace"],
    networkAccess: false,
    excludeTmpdirEnvVar: true,
    excludeSlashTmp: true,
  };
  function fixture(overrides: Record<string, unknown> = {}) {
    const process = new FakeHarnessProcess();
    process.reply = (frame) => {
      if (frame.method === "initialize") process.receive({ id: frame.id, result: {} });
      if (frame.method === "thread/start" || frame.method === "thread/resume")
        process.receive({
          id: frame.id,
          result: {
            thread: { id: "thread" },
            cwd: process.workspace,
            approvalPolicy: "on-request",
            approvalsReviewer: "user",
            sandbox,
            ...overrides,
          },
        });
      if (frame.method === "turn/start")
        process.receive({ id: frame.id, result: { turn: { id: "turn" } } });
      if (frame.method === "turn/interrupt") process.receive({ id: frame.id, result: {} });
    };
    return process;
  }

  it.each([false, true])("reapplies restricted permissions when resuming=%s", async (resume) => {
    const process = fixture();
    const driver = createHostCodexDriver(process, "test", () => {});
    await driver.start(
      startRequest(resume ? { session: { id: "thread", engineVersion: "test" } } : {}),
    );
    const thread = process.sent.find((frame) =>
      ["thread/start", "thread/resume"].includes(String(frame.method)),
    );
    expect(thread?.params).toMatchObject({
      approvalPolicy: "on-request",
      approvalsReviewer: "user",
      sandbox: "workspace-write",
    });
    expect(process.sent.find((frame) => frame.method === "turn/start")?.params).toMatchObject({
      approvalPolicy: "on-request",
      approvalsReviewer: "user",
      sandboxPolicy: sandbox,
    });
    await driver.cancel();
  });

  it.each([
    { sandbox: { ...sandbox, type: "externalSandbox" } },
    { sandbox: { ...sandbox, networkAccess: true } },
    { sandbox: { ...sandbox, writableRoots: ["/another-workspace"] } },
    { sandbox: { ...sandbox, excludeSlashTmp: false } },
    { sandbox: { ...sandbox, excludeTmpdirEnvVar: false } },
    { sandbox: null },
    { approvalPolicy: "never" },
    { approvalsReviewer: "auto_review" },
    { cwd: "/another-workspace" },
  ])("does not send a prompt when effective restrictions differ: %j", async (override) => {
    const process = fixture(override);
    const driver = createHostCodexDriver(process, "test", () => {});
    await expect(driver.start(startRequest())).rejects.toThrow("host_sandbox_not_confirmed");
    expect(process.sent.some((frame) => frame.method === "turn/start")).toBe(false);
    await driver.cancel();
  });

  it("requires a decision for an escalation and delivers a refusal to the engine", async () => {
    const process = fixture();
    const events: NativeExecutionEvent[] = [];
    const driver = createHostCodexDriver(process, "test", (event) => events.push(event));
    await driver.start(startRequest());
    process.receive({
      id: "escalation",
      method: "item/commandExecution/requestApproval",
      params: { threadId: "thread", turnId: "turn", command: "write outside workspace" },
    });
    await tick();
    const interaction = events.find((event) => event.type === "interaction");
    if (interaction?.type !== "interaction") throw new Error("Expected permission request");
    expect(process.sent.some((frame) => frame.id === "escalation")).toBe(false);
    await driver.respond(interaction.request.id, "deny");
    expect(process.sent.at(-1)).toMatchObject({
      id: "escalation",
      result: { decision: "decline" },
    });
    await driver.cancel();
  });
});
