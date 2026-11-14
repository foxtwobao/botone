import { describe, expect, it } from "vitest";
import { createHostCodexDriver } from "./codex.js";
import { assertHostConfiguration, assertRemoteHostConfiguration } from "./host-policy.js";
import { safeHostConfiguration } from "./host-policy.test-support.js";
import { FakeHarnessProcess, startRequest, tick } from "./protocol.test-support.js";

it.each([
  { features: { ...safeHostConfiguration().features, hooks: true } },
  { mcp_servers: { extra: { command: "unapproved" } } },
  { notify: ["unapproved"] },
  { allow_login_shell: true },
  { web_search: "live" },
])("refuses effective settings that can escape the admitted boundary: %j", (override) => {
  expect(() => assertHostConfiguration({ ...safeHostConfiguration(), ...override })).toThrow(
    "host_configuration_not_confirmed",
  );
});
it("allows disabled project servers and no notification command", () => {
  expect(() =>
    assertHostConfiguration({
      ...safeHostConfiguration(),
      mcp_servers: { project: { enabled: false } },
    }),
  ).not.toThrow();
});

const remoteConfig = () => ({
  ...safeHostConfiguration(),
  features: {
    ...safeHostConfiguration().features,
    shell_tool: false,
    unified_exec: false,
    view_image: false,
    code_mode: false,
  },
  permissions: {
    fixture: {
      filesystem: { ":root": "deny", ":minimal": "read", ":workspace_roots": { ".": "read" } },
      network: { enabled: false },
    },
  },
});
describe("host agent on a remote computer", () => {
  it("accepts the pinned native config's explicit null defaults without permitting extra capabilities", () => {
    const base = remoteConfig();
    const config = {
      ...base,
      permissions: {
        fixture: {
          ...base.permissions.fixture,
          description: null,
          extends: null,
          workspace_roots: null,
          filesystem: { ...base.permissions.fixture.filesystem, glob_scan_max_depth: null },
          network: { enabled: false, proxy_url: null, allow_local_binding: null, domains: null },
        },
      },
    };
    expect(() => assertRemoteHostConfiguration(config, "fixture")).not.toThrow();
    expect(() =>
      assertRemoteHostConfiguration(
        {
          ...config,
          permissions: { fixture: { ...config.permissions.fixture, extends: "extra-root" } },
        },
        "fixture",
      ),
    ).toThrow("host_remote_boundary_not_confirmed");
    expect(() =>
      assertRemoteHostConfiguration(
        {
          ...config,
          permissions: {
            fixture: {
              ...config.permissions.fixture,
              network: { enabled: false, allow_local_binding: true },
            },
          },
        },
        "fixture",
      ),
    ).toThrow("host_remote_boundary_not_confirmed");
  });
  function fixture() {
    const process = new FakeHarnessProcess();
    const calls: unknown[] = [];
    process.externalTools = {
      permissions: "fixture",
      specs: [
        {
          name: "computer_execute",
          label: "Run command",
          description: "Run on the computer",
          inputSchema: { type: "object" },
          requiresApproval: true,
        },
      ],
      invoke: async (...call) => {
        calls.push(call);
        return '{"code":0}';
      },
    };
    process.reply = (frame) => {
      if (frame.method === "initialize" || frame.method === "turn/interrupt")
        process.receive({ id: frame.id, result: {} });
      if (frame.method === "config/read")
        process.receive({ id: frame.id, result: { config: remoteConfig() } });
      if (frame.method === "thread/start" || frame.method === "thread/resume")
        process.receive({
          id: frame.id,
          result: {
            thread: { id: "thread" },
            cwd: process.workspace,
            approvalPolicy: "never",
            approvalsReviewer: "user",
            sandbox: { type: "readOnly", networkAccess: false },
            activePermissionProfile: { id: "fixture", extends: null },
          },
        });
      if (frame.method === "turn/start")
        process.receive({ id: frame.id, result: { turn: { id: "turn" } } });
    };
    return { process, calls };
  }
  it("denies extra local roots, writable scratch space and network", () => {
    const config = remoteConfig();
    expect(() => assertRemoteHostConfiguration(config, "fixture")).not.toThrow();
    config.permissions.fixture.filesystem[":workspace_roots"]["."] = "write";
    expect(() => assertRemoteHostConfiguration(config, "fixture")).toThrow(
      "host_remote_boundary_not_confirmed",
    );
  });
  it.each([false, true])("keeps the local boundary on resume=%s", async (resume) => {
    const { process } = fixture();
    const driver = createHostCodexDriver(process, "test", () => {});
    await driver.start(
      startRequest(resume ? { session: { id: "thread", engineVersion: "test" } } : {}),
    );
    const params = process.sent.find((f) => f.method === "turn/start")!.params as Record<
      string,
      unknown
    >;
    expect(params).toMatchObject({
      permissions: "fixture",
      approvalPolicy: "never",
      environments: [],
    });
    expect(params.sandboxPolicy).toBeUndefined();
    const thread = process.sent.find(
      (f) => f.method === (resume ? "thread/resume" : "thread/start"),
    )!.params;
    expect(thread).toMatchObject({ permissions: "fixture", environments: [] });
    if (!resume)
      expect(thread).toMatchObject({
        dynamicTools: [{ type: "function", name: "computer_execute" }],
      });
    if (!resume) {
      const tools = (thread as { dynamicTools: Record<string, unknown>[] }).dynamicTools;
      expect(tools[0]).not.toHaveProperty("label");
      expect(tools[0]).not.toHaveProperty("requiresApproval");
    }
    await driver.cancel();
  });
  it("requires native approval before a remote command and never permits a host escalation", async () => {
    const { process, calls } = fixture();
    const events: { type: string; request?: { id: string } }[] = [];
    const driver = createHostCodexDriver(process, "test", (event) => events.push(event));
    await driver.start(startRequest());
    process.receive({
      id: "call",
      method: "item/tool/call",
      params: {
        threadId: "thread",
        turnId: "turn",
        callId: "tool-call",
        tool: "computer_execute",
        arguments: { argv: ["pwd"] },
      },
    });
    await tick();
    expect(calls).toEqual([]);
    const request = events.find((event) => event.type === "interaction")!.request!;
    expect(await driver.respond(request.id, "allow")).toBe(true);
    expect(calls).toEqual([["tool-call", "computer_execute", { argv: ["pwd"] }]]);
    expect(await driver.respond(request.id, "allow")).toBe(true);
    expect(calls).toHaveLength(1);
    process.receive({
      id: "local",
      method: "item/commandExecution/requestApproval",
      params: { threadId: "thread", turnId: "turn", command: "local command" },
    });
    await tick();
    expect(process.sent.find((f) => f.id === "local")?.result).toEqual({ decision: "decline" });
    await driver.cancel();
  });
  it("bounds approval previews without changing the command submitted after approval", async () => {
    const { process, calls } = fixture();
    const events: { type: string; request?: { id: string; title: string; detail?: string } }[] = [];
    const driver = createHostCodexDriver(process, "test", (event) => events.push(event));
    await driver.start(startRequest());
    const input = { argv: ["printf", "x".repeat(12_000), "y".repeat(12_000)] };
    process.receive({
      id: "large-call",
      method: "item/tool/call",
      params: {
        threadId: "thread",
        turnId: "turn",
        callId: "large-tool-call",
        tool: "computer_execute",
        arguments: input,
      },
    });
    await tick();
    const request = events.find((event) => event.type === "interaction")!.request!;
    expect(request.title).toBe("Run command?");
    expect(request.detail).toHaveLength(16_000);
    expect(request.detail).toMatch(/…$/);
    expect(calls).toEqual([]);
    await driver.respond(request.id, "allow");
    expect(calls).toEqual([["large-tool-call", "computer_execute", input]]);
    await driver.cancel();
  });
});
