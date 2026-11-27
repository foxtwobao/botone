import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { access, mkdir, mkdtemp, readFile, realpath, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import type { HarnessProcess } from "@rakazo/native-runtime/driver";
import { record } from "@rakazo/native-runtime/driver";
import { assertRemoteHostConfiguration } from "@rakazo/native-runtime/host-policy";
import { HarnessProtocolError, HarnessRpc } from "@rakazo/native-runtime/rpc";
import koffi from "koffi";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import {
  hostFilesystemOverride,
  hostLaunchArguments,
  resolveHostExecutable,
} from "./host-adapter.js";
import { launchHostProcess } from "./host-process.js";
import { createHostProcessMarker, macosHostOwnershipAvailable } from "./host-process-macos.js";

// CI installs an official CLI. A developer without it skips these offline checks.
// No native account is read and no turn/model request is sent. Any accidental model call
// is directed to a loopback address without a service, with authentication disabled.
describe.skipIf(process.platform !== "darwin")("native CLI macOS policies", () => {
  const roots: string[] = [];
  const children = new Set<HarnessProcess>();
  let root: string;
  let executable: string | undefined;
  let env: NodeJS.ProcessEnv;

  beforeAll(async () => {
    root = await realpath(await mkdtemp(path.join(tmpdir(), "native-policy-")));
    roots.push(root);
    const home = path.join(root, "home");
    const codeHome = path.join(home, ".codex");
    const scratch = path.join(root, "scratch");
    await Promise.all([mkdir(codeHome, { recursive: true }), mkdir(scratch)]);
    env = {
      HOME: home,
      CODEX_HOME: codeHome,
      TMPDIR: scratch,
      PATH: process.env.PATH ?? "/usr/bin:/bin:/usr/sbin:/sbin",
    };
    executable = await resolveHostExecutable({ env, home });
    if (process.env.CI) expect(executable, "installed CLI discovery").toBeDefined();
    const owned = executable ? await macosHostOwnershipAvailable() : false;
    if (process.env.CI) expect(owned, "native process ownership").toBe(true);
    if (executable && owned) {
      const probe = await launchHostProcess({
        executable,
        args: ["--version"],
        workspace: root,
        env,
      });
      try {
        const lines: string[] = [];
        probe.onLine((line) => lines.push(line));
        const code = await new Promise((resolve, reject) => {
          const timer = setTimeout(() => reject(new Error("native_cli_version_timeout")), 5_000);
          probe.onExit((status) => {
            clearTimeout(timer);
            resolve(status);
          });
        });
        if (process.env.CI) {
          expect(code, "CLI version command exit status").toBe(0);
          expect(lines.join(""), "CLI version output").toMatch(/^codex-cli \d+\.\d+\.\d+$/);
        }
        if (code !== 0 || !/^codex-cli \d+\.\d+\.\d+$/.test(lines.join(""))) executable = undefined;
      } finally {
        await probe.stop();
      }
    } else executable = undefined;
    if (process.env.CI && !executable) throw new Error("native_cli_or_owner_unavailable");
  });

  afterEach(async () => {
    for (const child of children) {
      await child.stop();
      children.delete(child);
    }
  });
  afterAll(async () => {
    await Promise.all(roots.map((directory) => rm(directory, { recursive: true, force: true })));
  });

  async function launch(readOnly: boolean, workspaceOverride?: string) {
    const workspace = workspaceOverride ?? (await mkdtemp(path.join(root, "workspace-")));
    if (!workspaceOverride)
      await Promise.all([
        mkdir(path.join(workspace, ".git")),
        mkdir(path.join(workspace, ".codex")),
      ]);
    const marker = readOnly ? await createHostProcessMarker() : undefined;
    const permissions = `fixture_${randomUUID().replaceAll("-", "")}`;
    const args = readOnly ? hostLaunchArguments() : ["app-server"];
    if (marker)
      args.splice(
        args.length - 1,
        0,
        ...["shell_tool", "unified_exec", "view_image", "code_mode"].flatMap((feature) => [
          "--disable",
          feature,
        ]),
        "-c",
        hostFilesystemOverride(permissions, marker),
        "-c",
        `permissions.${permissions}.network.enabled=false`,
        "-c",
        `default_permissions=${JSON.stringify(permissions)}`,
      );
    args.splice(
      args.length - 1,
      0,
      "-c",
      'model_provider="offline_fixture"',
      "-c",
      'cli_auth_credentials_store="file"',
      "-c",
      'model="offline-fixture"',
      "-c",
      'model_providers.offline_fixture={name="Offline fixture",base_url="http://127.0.0.1:9/v1",wire_api="responses",requires_openai_auth=false}',
      "-c",
      "analytics.enabled=false",
      "-c",
      "feedback.enabled=false",
      "-c",
      "check_for_update_on_startup=false",
    );
    const child = await launchHostProcess({
      executable: executable!,
      args,
      workspace,
      env,
      marker,
    });
    children.add(child);
    const rpc = new HarnessRpc(
      child,
      async (message) => {
        if (message.id !== undefined) await rpc.reject(message.id as string | number);
      },
      () => {},
    );
    await rpc.request(
      "initialize",
      {
        clientInfo: { name: "offline-policy-fixture", version: "1" },
        capabilities: { experimentalApi: true },
      },
      5_000,
    );
    await rpc.notify("initialized", {});
    const effective = record(
      await rpc.request("config/read", { cwd: workspace, includeLayers: false }, 5_000),
    );
    if (marker)
      assertRemoteHostConfiguration(effective.config, permissions, { id: permissions, ...marker });
    const thread = record(
      await rpc.request(
        "thread/start",
        {
          cwd: workspace,
          ephemeral: true,
          ...(readOnly ? { permissions, environments: [] } : { sandbox: "danger-full-access" }),
          approvalPolicy: "never",
          approvalsReviewer: "user",
          ...(readOnly
            ? {
                dynamicTools: [
                  {
                    type: "function",
                    name: "computer_execute",
                    description: "Offline remote tool fixture",
                    inputSchema: {
                      type: "object",
                      properties: {},
                      additionalProperties: false,
                    },
                  },
                ],
              }
            : {}),
        },
        10_000,
      ),
    );
    if (readOnly) expect(record(thread.activePermissionProfile).id).toBe(permissions);
    expect(record(thread.sandbox)).toMatchObject(
      readOnly ? { type: "readOnly", networkAccess: false } : { type: "dangerFullAccess" },
    );
    const command = async (script: string, timeoutMs = 3_000) =>
      record(
        await rpc.request(
          "command/exec",
          {
            command: ["/bin/sh", "-c", script],
            cwd: workspace,
            ...(readOnly
              ? { permissionProfile: permissions }
              : { sandboxPolicy: { type: "dangerFullAccess" } }),
            timeoutMs,
          },
          timeoutMs + 5_000,
        ),
      );
    return { child, workspace, marker, command, config: effective.config, thread };
  }

  it("connects to a local app socket outside the workspace", async ({ skip }) => {
    if (!executable) return skip();
    const { command } = await launch(false);
    const socket = path.join(root, "app.sock");
    const server = createServer((connection) => connection.end("connected"));
    try {
      await new Promise<void>((resolve, reject) =>
        server.once("error", reject).listen(socket, resolve),
      );
      const result = await command(`/usr/bin/nc -U "${socket}" < /dev/null`);
      expect(result).toMatchObject({ exitCode: 0, stdout: "connected" });
    } finally {
      server.close();
    }
  }, 60_000);

  it("stops a local command running with full account access", async ({ skip }) => {
    if (!executable) return skip();
    const { child, workspace, command } = await launch(false);
    const running = command('printf "%s" "$$" > tool-pid; exec /bin/sleep 10', 12_000);
    // Attach immediately: stopping the owner may reject the pending command RPC.
    const settled = running.catch((error: unknown) => {
      expect(error).toBeInstanceOf(HarnessProtocolError);
    });
    const pid = await vi.waitUntil(
      async () => {
        const file = path.join(workspace, "tool-pid");
        if (!existsSync(file)) return;
        return Number(await readFile(file, "utf8")) || undefined;
      },
      { timeout: 5_000 },
    );
    const info = koffi
      .load("/usr/lib/libproc.dylib")
      .func("int proc_pidinfo(int, int, uint64_t, void *, int)");
    const identity = Buffer.alloc(56);
    expect(info(pid, 17, 0, identity, identity.length)).toBe(identity.length);
    const unique = identity.readBigUInt64LE(16);
    await child.stop();
    children.delete(child);
    await settled;
    // PROC_PIDUNIQIDENTIFIERINFO with arg=0 excludes zombies as well as exited tasks.
    const alive = info(pid, 17, 0, identity, identity.length) === identity.length;
    expect(alive && identity.readBigUInt64LE(16) === unique).toBe(false);
  }, 60_000);

  it("accepts a remote dynamic-tool session with native tools disabled", async ({ skip }) => {
    if (!executable) return skip();
    const { workspace, config, thread } = await launch(true);
    expect(record(config).features).toMatchObject({
      shell_tool: false,
      unified_exec: false,
      view_image: false,
      code_mode: false,
    });
    expect(record(thread.thread).id).toEqual(expect.any(String));
    expect(thread).toMatchObject({
      cwd: workspace,
      approvalPolicy: "never",
      approvalsReviewer: "user",
    });
  }, 60_000);

  it("protects the process owner's markers even when the starting folder contains them", async ({
    skip,
  }) => {
    if (!executable) return skip();
    const local = await launch(false, "/private/tmp");
    const remote = await launch(true);
    const marker = remote.marker!;
    for (const file of [marker.allow, marker.deny]) {
      expect((await local.command(`cat "${file}"`)).exitCode).not.toBe(0);
      expect((await local.command(`printf fixture > "${file}"`)).exitCode).not.toBe(0);
    }
    await local.child.stop();
    children.delete(local.child);
    await access(marker.allow);
    await remote.child.stop();
    children.delete(remote.child);
    await expect(access(marker.allow)).rejects.toThrow();
  }, 60_000);
});
