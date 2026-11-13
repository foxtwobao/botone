import { randomUUID } from "node:crypto";
import { access, mkdir, mkdtemp, readFile, realpath, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import type { HarnessProcess } from "@rakazo/native-runtime/driver";
import { record } from "@rakazo/native-runtime/driver";
import {
  assertLabeledHostConfiguration,
  assertRemoteHostConfiguration,
} from "@rakazo/native-runtime/host-policy";
import { HarnessProtocolError, HarnessRpc } from "@rakazo/native-runtime/rpc";
import koffi from "koffi";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import {
  HOST_ENGINE_VERSION,
  hostFilesystemOverride,
  hostLaunchArguments,
  resolveHostExecutable,
} from "./host-adapter.js";
import { launchHostProcess } from "./host-process.js";
import { createHostProcessMarker, macosHostOwnershipAvailable } from "./host-process-macos.js";

// CI installs this exact official CLI. A developer without it skips these offline checks.
// No native account is read and no turn/model request is sent. Any accidental model call
// is directed to a loopback address without a service, with authentication disabled.
describe.skipIf(process.platform !== "darwin")("pinned native CLI macOS policies", () => {
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
    if (executable && (await macosHostOwnershipAvailable())) {
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
        if (code !== 0 || lines.join("") !== `codex-cli ${HOST_ENGINE_VERSION}`)
          executable = undefined;
      } finally {
        await probe.stop();
      }
    } else executable = undefined;
    if (process.env.CI && !executable) throw new Error("pinned_native_cli_or_owner_unavailable");
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
    const marker = await createHostProcessMarker();
    const permissions = `fixture_${randomUUID().replaceAll("-", "")}`;
    const label = { id: permissions, ...marker };
    const args = hostLaunchArguments();
    args.splice(
      args.length - 1,
      0,
      ...(readOnly ? ["shell_tool", "unified_exec", "view_image", "code_mode"] : []).flatMap(
        (feature) => ["--disable", feature],
      ),
      "-c",
      hostFilesystemOverride(permissions, readOnly, marker),
      "-c",
      `permissions.${permissions}.network.enabled=false`,
      "-c",
      `default_permissions=${JSON.stringify(permissions)}`,
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
    if (readOnly) assertRemoteHostConfiguration(effective.config, permissions, label);
    else assertLabeledHostConfiguration(effective.config, label, false);
    const thread = record(
      await rpc.request(
        "thread/start",
        {
          cwd: workspace,
          ephemeral: true,
          permissions,
          environments: [],
          approvalPolicy: "never",
          approvalsReviewer: "user",
        },
        10_000,
      ),
    );
    expect(record(thread.activePermissionProfile).id).toBe(permissions);
    expect(record(thread.sandbox)).toMatchObject({ type: "readOnly", networkAccess: false });
    const command = async (script: string, timeoutMs = 3_000) =>
      record(
        await rpc.request(
          "command/exec",
          {
            command: ["/bin/sh", "-c", script],
            cwd: workspace,
            permissionProfile: permissions,
            timeoutMs,
          },
          timeoutMs + 5_000,
        ),
      );
    return { child, workspace, marker, command };
  }

  it("keeps workspace writes, protects metadata, labels the actual tool sandbox and cleans it on stop", async ({
    skip,
  }) => {
    if (!executable) return skip();
    const { child, workspace, marker, command } = await launch(false);
    expect((await command("printf fixture > ordinary-file")).exitCode).toBe(0);
    expect(await readFile(path.join(workspace, "ordinary-file"), "utf8")).toBe("fixture");
    for (const directory of [".git", ".codex"]) {
      expect((await command(`printf fixture > ${directory}/forbidden-file`)).exitCode).not.toBe(0);
      await expect(access(path.join(workspace, directory, "forbidden-file"))).rejects.toThrow();
    }
    const running = command('printf "%s" "$$" > tool-pid; exec /bin/sleep 10', 12_000);
    // Attach immediately: stopping the owner may reject the pending command RPC.
    const settled = running.catch((error: unknown) => {
      expect(error).toBeInstanceOf(HarnessProtocolError);
    });
    let pid = 0;
    const deadline = Date.now() + 5_000;
    while (!pid && Date.now() < deadline) {
      try {
        pid = Number(await readFile(path.join(workspace, "tool-pid"), "utf8"));
      } catch {}
      if (!pid) await delay(20);
    }
    expect(Number.isSafeInteger(pid) && pid > 0).toBe(true);
    const sandbox = koffi.load("/usr/lib/libsandbox.dylib");
    const check = sandbox.func("int sandbox_check(int, const char *, int, ...)");
    const flags = 1 | koffi.decode(sandbox.symbol("SANDBOX_CHECK_NO_REPORT"), "int");
    expect(check(pid, "file-read-data", flags, "str", marker.allow)).toBe(0);
    expect(check(pid, "file-read-data", flags, "str", marker.deny)).toBeGreaterThan(0);
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

  it("remote profile rejects local command execution and leaves device paths untouched", async ({
    skip,
  }) => {
    if (!executable) return skip();
    const { workspace, command } = await launch(true);
    const systemScratch = await Promise.all(
      ["/private/tmp", "/private/var/tmp"].map(async (directory) => {
        const target = await mkdtemp(path.join(directory, "native-policy-"));
        roots.push(target);
        return target;
      }),
    );
    const targets = [workspace, env.TMPDIR!, ...systemScratch].map((directory) =>
      path.join(directory, "forbidden-file"),
    );
    for (const target of targets) {
      // The unsandboxed host can write each path.
      await writeFile(target, "outside-control", { flag: "wx" });
      await rm(target);
      const quoted = `'${target.replaceAll("'", "'\\''")}'`;
      const result = await command(`printf fixture > ${quoted}`);
      expect(result).toMatchObject({
        exitCode: expect.any(Number),
        stdout: "",
        stderr: expect.stringMatching(/\b(?:Operation not permitted|Permission denied)\b/),
      });
      expect(result.exitCode).not.toBe(0);
      await expect(access(target)).rejects.toThrow();
    }
  }, 60_000);

  it("protects both runs' markers and their shared directory inside a writable workspace", async ({
    skip,
  }) => {
    if (!executable) return skip();
    // This workspace deliberately contains the reserved directory. More specific
    // deny/read entries must win over the workspace's broad write permission.
    const first = await launch(false, "/private/tmp");
    const second = await launch(false, "/private/tmp");
    const quote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`;
    const objects = [
      first.marker.directory,
      first.marker.allow,
      first.marker.deny,
      second.marker.allow,
      second.marker.deny,
    ];
    const original = await Promise.all(objects.map((file) => stat(file)));
    expect((await first.command(`cat ${quote(first.marker.allow)} > /dev/null`)).exitCode).toBe(0);
    for (const file of [first.marker.deny, second.marker.allow, second.marker.deny])
      expect((await first.command(`cat ${quote(file)} > /dev/null`)).exitCode).not.toBe(0);
    for (const file of objects) {
      for (const script of [
        `chmod 0777 ${quote(file)}`,
        `mv ${quote(file)} ${quote(`${file}-moved`)}`,
        ...(file === first.marker.directory
          ? []
          : [`rm ${quote(file)}`, `printf fixture > ${quote(file)}`]),
      ])
        expect((await first.command(script)).exitCode).not.toBe(0);
    }
    for (const [index, file] of objects.entries()) {
      const current = await stat(file);
      expect([current.dev, current.ino, current.mode]).toEqual([
        original[index]!.dev,
        original[index]!.ino,
        original[index]!.mode,
      ]);
    }
    await first.child.stop();
    children.delete(first.child);
    // The first owner's cleanup must remove only its own two markers.
    await expect(access(first.marker.allow)).rejects.toThrow();
    await expect(access(first.marker.deny)).rejects.toThrow();
    expect((await second.command(`cat ${quote(second.marker.allow)} > /dev/null`)).exitCode).toBe(
      0,
    );
    await access(second.marker.deny);
  }, 60_000);
});
