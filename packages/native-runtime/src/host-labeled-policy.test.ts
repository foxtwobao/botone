import { describe, expect, it } from "vitest";
import { createHostCodexDriver } from "./codex.js";
import { assertLabeledHostConfiguration, assertRemoteHostConfiguration } from "./host-policy.js";
import { safeHostConfiguration } from "./host-policy.test-support.js";
import { FakeHarnessProcess, startRequest, tick } from "./protocol.test-support.js";

const label = {
  id: "fixture",
  allow: "/System/Library/fixture-allow",
  deny: "/System/Library/fixture-deny",
};
function config(readOnly: boolean) {
  const safe = safeHostConfiguration();
  return {
    ...safe,
    features: {
      ...safe.features,
      ...(readOnly
        ? { shell_tool: false, unified_exec: false, view_image: false, code_mode: false }
        : {}),
    },
    permissions: {
      fixture: {
        filesystem: {
          ":root": readOnly ? "deny" : "read",
          ":minimal": "read",
          ":workspace_roots": { ".": readOnly ? "read" : "write" },
          [label.allow]: "read",
          [label.deny]: "deny",
        },
        network: { enabled: false },
      },
    },
  };
}
function fixture(readOnly: boolean, override: Record<string, unknown> = {}) {
  const process = Object.assign(new FakeHarnessProcess(), { hostPermissions: label });
  if (readOnly)
    process.externalTools = { permissions: label.id, specs: [], invoke: async () => "" };
  process.reply = (frame) => {
    if (frame.method === "initialize" || frame.method === "turn/interrupt")
      process.receive({ id: frame.id, result: {} });
    if (frame.method === "config/read")
      process.receive({ id: frame.id, result: { config: config(readOnly) } });
    if (frame.method === "thread/start" || frame.method === "thread/resume")
      process.receive({
        id: frame.id,
        result: {
          thread: { id: "thread" },
          cwd: process.workspace,
          approvalPolicy: "never",
          approvalsReviewer: "user",
          activePermissionProfile: { id: label.id },
          // Native custom policies with deny carveouts have this legacy projection,
          // including a custom policy which allows writes in the workspace.
          sandbox: { type: "readOnly", networkAccess: false },
          ...override,
        },
      });
    if (frame.method === "turn/start")
      process.receive({ id: frame.id, result: { turn: { id: "turn" } } });
  };
  return process;
}

describe.each([false, true])("labeled native permissions readOnly=%s", (readOnly) => {
  it.each([false, true])("retains the precise native profile when resuming=%s", async (resume) => {
    const process = fixture(readOnly);
    const driver = createHostCodexDriver(process, "test", () => {});
    await driver.start(
      startRequest(resume ? { session: { id: "thread", engineVersion: "test" } } : {}),
    );
    for (const frame of process.sent.filter((frame) =>
      ["thread/start", "thread/resume", "turn/start"].includes(String(frame.method)),
    )) {
      expect(frame.params).toMatchObject({
        permissions: label.id,
        environments: [],
        approvalPolicy: "never",
        approvalsReviewer: "user",
      });
      expect(frame.params).not.toHaveProperty("sandboxPolicy");
      expect(frame.params).not.toHaveProperty("sandbox");
    }
    await driver.cancel();
  });

  it("rejects profile changes before sending the prompt", async () => {
    const process = fixture(readOnly, { activePermissionProfile: { id: "different" } });
    const driver = createHostCodexDriver(process, "test", () => {});
    await expect(driver.start(startRequest())).rejects.toThrow("not_confirmed");
    expect(process.sent.some((frame) => frame.method === "turn/start")).toBe(false);
    await driver.cancel();
  });

  it("refuses native approval retries that would discard the descendant label", async () => {
    const process = fixture(readOnly);
    const driver = createHostCodexDriver(process, "test", () => {});
    await driver.start(startRequest());
    for (const method of [
      "item/commandExecution/requestApproval",
      "item/fileChange/requestApproval",
    ]) {
      process.receive({
        id: method,
        method,
        params: { threadId: "thread", turnId: "turn", command: "outside sandbox" },
      });
      await tick();
      expect(process.sent.find((frame) => frame.id === method)?.result).toEqual({
        decision: "decline",
      });
    }
    await driver.cancel();
  });

  it.each(["allow", "deny"])("requires the exact %s probe permission", (probe) => {
    const effective = config(readOnly);
    effective.permissions.fixture.filesystem[label[probe as "allow" | "deny"]] = "write";
    expect(() =>
      readOnly
        ? assertRemoteHostConfiguration(effective, label.id, label)
        : assertLabeledHostConfiguration(effective, label, false),
    ).toThrow("not_confirmed");
  });
});
