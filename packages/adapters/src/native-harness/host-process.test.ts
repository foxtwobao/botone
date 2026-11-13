import { execFile, spawn } from "node:child_process";
import {
  access,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rename,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import type { NativeExecutionEvent } from "@rakazo/adapter-kit";
import { createHostCodexDriver } from "@rakazo/native-runtime/codex";
import type { HarnessProcess } from "@rakazo/native-runtime/driver";
import { safeHostConfiguration, startRequest } from "@rakazo/native-runtime/testing";
import { afterEach, describe, expect, it } from "vitest";
import { WINDOWS_COMMAND_WRAPPER } from "../desktop-process-tree.js";
import { launchHostProcess } from "./host-process.js";
import {
  createHostProcessMarker,
  discardHostProcessMarker,
  MACOS_HOST_OWNER,
  macosHostOwnershipAvailable,
  probeMacosHostOwnership,
} from "./host-process-macos.js";

const supported = ["linux", "win32", "darwin"].includes(process.platform);
describe.skipIf(!supported)("host protocol process", () => {
  const roots: string[] = [];
  const processes: HarnessProcess[] = [];
  afterEach(async () => {
    await Promise.all(processes.splice(0).map((child) => child.stop()));
    await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
  });
  async function launch(program: string, env: NodeJS.ProcessEnv = {}) {
    const root = await mkdtemp(path.join(tmpdir(), "host protocol "));
    roots.push(root);
    const script = path.join(root, "fixture.cjs");
    await writeFile(script, program);
    const child = await launchHostProcess({
      executable: process.execPath,
      args: [script],
      workspace: root,
      env: {
        // Needed by Node on Windows, without inheriting credentials from the test runner.
        SystemRoot: process.env.SystemRoot,
        ...env,
      },
    });
    processes.push(child);
    return { child, root };
  }
  function output(child: HarnessProcess) {
    const lines: string[] = [];
    let received: ((line: string) => void) | undefined;
    child.onLine((line) => {
      if (received) {
        const listener = received;
        received = undefined;
        listener(line);
      } else lines.push(line);
    });
    return () =>
      lines.length
        ? Promise.resolve(lines.shift()!)
        : new Promise<string>((resolve) => {
            received = resolve;
          });
  }
  function expectNotRunning(pid: number) {
    if (process.platform === "darwin") {
      const koffi = createRequire(import.meta.url)("koffi");
      const info = koffi
        .load("/usr/lib/libproc.dylib")
        .func("int proc_pidinfo(int, int, uint64_t, void *, int)");
      const identity = Buffer.alloc(56);
      const state = Buffer.alloc(64);
      const live = info(pid, 17, 0, identity, identity.length);
      const includingZombie = info(pid, 13, 1, state, state.length);
      // launchd may not have reaped an orphan yet. Confirm kernel SZOMB, rather
      // than treating kill(pid, 0), which also succeeds for zombies, as liveness.
      if (includingZombie === state.length && state.readUInt32LE(12) === 5) {
        expect(live).toBe(0);
        return;
      }
      expect(live).toBe(0);
    }
    expect(() => process.kill(pid, 0)).toThrow();
  }

  it("keeps stdin open for multiple UTF-8 frames, with a real private bootstrap on Windows", async () => {
    const { child, root } = await launch(`
      const readline = require('node:readline');
      console.error('private native account diagnostics');
      readline.createInterface({ input: process.stdin }).on('line', line => {
        const bytes = Buffer.from(JSON.stringify({ value: JSON.parse(line), cwd: process.cwd() }) + '\\r\\n');
        for (const byte of bytes) process.stdout.write(Buffer.from([byte]));
      });
    `);
    const next = output(child);
    for (const value of [
      "你好",
      'literal $(touch unwanted) `echo unwanted` "quote"',
      "next turn",
    ]) {
      await child.write(value);
      expect(JSON.parse(await next())).toEqual({ value, cwd: await realpath(root) });
    }
    expect(child.workspace).toBe(await realpath(root));
    expect(child.mcpServer).toBeUndefined();
    await child.stop();
    await expect(child.write({ after: "stop" })).rejects.toThrow("host_process_stopped");
  });

  it("consumes the Windows bootstrap without forwarding its credentials to protocol stdin", async () => {
    // Exercise the exact wrapper on every OS, in addition to the native Windows Job tests.
    const { child } = await launch(`process.argv[1] = 'stream'; ${WINDOWS_COMMAND_WRAPPER}`);
    const next = output(child);
    await child.write({
      argv: [
        process.execPath,
        "-e",
        "require('node:readline').createInterface({input:process.stdin}).on('line',line=>console.log(line));",
      ],
      env: { SystemRoot: process.env.SystemRoot, PRIVATE_FIXTURE: "bootstrap-only" },
    });
    await child.write({ message: "你好" });
    expect(JSON.parse(await next())).toEqual({ message: "你好" });
    await child.write({ message: "second frame" });
    expect(JSON.parse(await next())).toEqual({ message: "second frame" });
  });

  it("delivers output and exit that occur before listeners attach", async () => {
    const { child } = await launch("console.log('early');");
    const code = await new Promise((resolve) => child.onExit(resolve));
    expect(code).toBe(0);
    expect(await output(child)()).toBe("early");
    expect(await new Promise((resolve) => child.onExit(resolve))).toBe(0);
  });

  it("runs the host driver over real stdio, refuses an escalation, and interrupts the turn", async () => {
    const { child } = await launch(`
      const readline = require('node:readline');
      const send = value => console.log(JSON.stringify(value));
      readline.createInterface({ input: process.stdin }).on('line', line => {
        const frame = JSON.parse(line);
        const result = value => send({ id: frame.id, result: value });
        if (frame.method === 'initialize') result({});
        if (frame.method === 'config/read') result({ config: ${JSON.stringify(safeHostConfiguration())} });
        if (frame.method === 'thread/start') result({
          thread: { id: 'thread' }, cwd: process.cwd(),
          approvalPolicy: 'on-request', approvalsReviewer: 'user',
          sandbox: { type: 'workspaceWrite', writableRoots: [process.cwd()],
            networkAccess: false, excludeTmpdirEnvVar: true, excludeSlashTmp: true }
        });
        if (frame.method === 'turn/start') {
          result({ turn: { id: 'turn' } });
          send({ id: 'approval', method: 'item/commandExecution/requestApproval',
            params: { threadId: 'thread', turnId: 'turn', command: 'outside workspace' } });
        }
        if (frame.id === 'approval' && frame.result?.decision === 'decline')
          send({ method: 'item/agentMessage/delta',
            params: { threadId: 'thread', turnId: 'turn', delta: 'Operation refused' } });
        if (frame.method === 'turn/interrupt') result({});
      });
    `);
    const events: NativeExecutionEvent[] = [];
    let receivePermission: (event: Extract<NativeExecutionEvent, { type: "interaction" }>) => void =
      () => {};
    const permission = new Promise<Extract<NativeExecutionEvent, { type: "interaction" }>>(
      (resolve) => {
        receivePermission = resolve;
      },
    );
    let received: () => void = () => {};
    const response = new Promise<void>((resolve) => {
      received = resolve;
    });
    const driver = createHostCodexDriver(child, "fixture", (event) => {
      events.push(event);
      if (event.type === "interaction") receivePermission(event);
      if (event.type === "text") received();
    });
    await driver.start(startRequest());
    const interaction = await permission;
    expect(interaction.request.kind).toBe("permission");
    expect(await driver.respond(interaction.request.id, "deny")).toBe(true);
    await response;
    expect(events).toContainEqual({ type: "text", text: "Operation refused" });
    await driver.cancel();
    expect(events.at(-1)).toEqual({ type: "cancelled" });
  });

  it("stops only the requested process", async () => {
    const echo =
      "require('node:readline').createInterface({input:process.stdin}).on('line',console.log);";
    const first = await launch(echo);
    const second = await launch(echo);
    const next = output(second.child);
    await first.child.stop();
    await second.child.write({ still: "running" });
    expect(JSON.parse(await next())).toEqual({ still: "running" });
  });

  it.each(["stop", "exit", "crash"])(
    "reaps detached double-forked descendants on %s and leaves unrelated processes running",
    async (action) => {
      const unrelated = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"]);
      const grandchild = `process.on('SIGTERM', () => {}); setInterval(() => require('node:fs').appendFileSync('ticks', 'tick\\n'), 10);`;
      const intermediate = `const child = require('node:child_process').spawn(process.execPath, ['-e', ${JSON.stringify(grandchild)}], { detached: true, stdio: 'ignore', env: {} }); require('node:fs').writeFileSync('descendant', String(child.pid)); child.unref();`;
      let pid: number | undefined;
      try {
        const { child, root } = await launch(`
        const fs = require('node:fs');
        const child = require('node:child_process').spawn(process.execPath, ['-e', ${JSON.stringify(intermediate)}], { detached: true, stdio: 'ignore', env: {} });
        child.unref();
        const timer = setInterval(() => {
          if (!fs.existsSync('ticks')) return;
          console.log(fs.readFileSync('descendant', 'utf8'));
          clearInterval(timer);
          ${action === "stop" ? "setInterval(() => {}, 1000);" : `process.exit(${action === "exit" ? 0 : 1});`}
        }, 10);
      `);
        pid = Number(await output(child)());
        if (action !== "stop")
          expect(await new Promise((resolve) => child.onExit(resolve))).toBe(
            action === "exit" ? 0 : 1,
          );
        await child.stop();
        expectNotRunning(pid!);
        const stopped = await readFile(path.join(root, "ticks"), "utf8");
        await new Promise((resolve) => setTimeout(resolve, 50));
        expect(await readFile(path.join(root, "ticks"), "utf8")).toBe(stopped);
        expect(unrelated.exitCode).toBeNull();
      } finally {
        if (pid) {
          try {
            process.kill(pid, "SIGKILL");
          } catch {}
        }
        unrelated.kill("SIGKILL");
      }
    },
  );

  it.skipIf(process.platform !== "darwin")(
    "probes the actual sandbox label and audit-token signal operations before admission",
    async () => {
      const probe = await probeMacosHostOwnership();
      expect(probe.success, probe.diagnostic).toBe(true);
      expect(await macosHostOwnershipAvailable()).toBe(true);
    },
  );

  it.skipIf(process.platform !== "darwin")(
    "confirms an owner pipe closed before bootstrap without launching a process",
    async () => {
      const owner = spawn(
        process.execPath,
        ["-e", MACOS_HOST_OWNER, createRequire(import.meta.url).resolve("koffi")],
        {
          env: { ELECTRON_RUN_AS_NODE: "1" },
          stdio: ["ignore", "ignore", "ignore", "pipe", "pipe"],
        },
      );
      const acknowledgement: Buffer[] = [];
      owner.stdio[4]!.on("data", (data: Buffer) => acknowledgement.push(data));
      const closed = new Promise((resolve) => owner.once("close", resolve));
      try {
        (owner.stdio[3] as NodeJS.WritableStream).end();
        expect(await closed).toBe(0);
        expect(Buffer.concat(acknowledgement).toString()).toBe("clean\n");
      } finally {
        owner.kill("SIGKILL");
      }
    },
  );

  it.skipIf(process.platform !== "darwin")(
    "does not mistake another sandbox denying both probe paths for this run's label",
    async () => {
      const foreign = spawn(
        "/usr/bin/sandbox-exec",
        [
          "-p",
          '(version 1)(allow default)(deny file-read* (subpath "/private/tmp"))',
          "/bin/sleep",
          "30",
        ],
        { stdio: "ignore", env: {} },
      );
      try {
        const { child } = await launch("console.log('ready'); setInterval(() => {}, 1000);");
        expect(await output(child)()).toBe("ready");
        await child.stop();
        expect(foreign.exitCode).toBeNull();
        expect(foreign.signalCode).toBeNull();
      } finally {
        foreign.kill("SIGKILL");
      }
    },
  );

  it.skipIf(process.platform !== "darwin").each(["stop", "exit", "crash"])(
    "cleans a native CLI's helpers and sandboxed detached tools on %s with empty environments",
    async (action) => {
      const root = await mkdtemp(path.join(tmpdir(), "host sandbox label "));
      roots.push(root);
      const marker = await createHostProcessMarker();
      const policy = `(version 1)(allow default)(deny file-read* (literal ${JSON.stringify(marker.deny)}))`;
      const grandchild = `process.on('SIGTERM', () => {}); setInterval(() => require('node:fs').appendFileSync('tool-ticks', 'tick\\n'), 10);`;
      const intermediate = `const p = require('node:child_process').spawn(process.execPath, ['-e', ${JSON.stringify(grandchild)}], { detached: true, stdio: 'ignore', env: {} }); require('node:fs').writeFileSync('tool-pid', String(p.pid)); p.unref();`;
      const script = path.join(root, "native-cli.cjs");
      await writeFile(
        script,
        `const { spawn } = require('node:child_process');
        const fs = require('node:fs');
        const helper = spawn(process.execPath, ['-e', "setInterval(() => {}, 1000)"], { detached: true, stdio: 'ignore', env: {} });
        helper.unref();
        const tool = spawn('/usr/bin/sandbox-exec', ['-p', ${JSON.stringify(policy)}, process.execPath, '-e', ${JSON.stringify(intermediate)}], { detached: true, stdio: 'ignore', env: {} });
        tool.unref();
        const timer = setInterval(() => {
          if (!fs.existsSync('tool-ticks')) return;
          console.log(JSON.stringify([Number(fs.readFileSync('tool-pid', 'utf8')), helper.pid]));
          clearInterval(timer);
          ${action === "stop" ? "setInterval(() => {}, 1000);" : `process.exit(${action === "exit" ? 0 : 1});`}
        }, 10);`,
      );
      const child = await launchHostProcess({
        executable: process.execPath,
        args: [script],
        workspace: root,
        env: {},
        marker,
      });
      processes.push(child);
      const pids = JSON.parse(await output(child)()) as number[];
      try {
        if (action !== "stop")
          expect(await new Promise((resolve) => child.onExit(resolve))).toBe(
            action === "exit" ? 0 : 1,
          );
        await child.stop();
        for (const pid of pids) expectNotRunning(pid);
      } finally {
        for (const pid of pids) {
          try {
            process.kill(pid, "SIGKILL");
          } catch {}
        }
      }
    },
  );

  it.skipIf(process.platform !== "darwin")(
    "keeps marker and private owner descriptors out of the native CLI",
    async () => {
      const root = await mkdtemp(path.join(tmpdir(), "host private handles "));
      roots.push(root);
      const marker = await createHostProcessMarker();
      const objects = await Promise.all(
        [marker.directory, marker.allow, marker.deny].map((file) => stat(file)),
      );
      const script = path.join(root, "handles.cjs");
      await writeFile(
        script,
        `const fs = require('node:fs');
        const objects = ${JSON.stringify(objects.map(({ dev, ino }) => [dev, ino]))};
        const leaked = [];
        for (let fd = 3; fd < 64; fd++) {
          try { const info = fs.fstatSync(fd); if (objects.some(([dev, ino]) => info.dev === dev && info.ino === ino)) leaked.push(fd); } catch {}
        }
        console.log(JSON.stringify(leaked));`,
      );
      const child = await launchHostProcess({
        executable: process.execPath,
        args: [script],
        workspace: root,
        env: {},
        marker,
      });
      processes.push(child);
      expect(JSON.parse(await output(child)())).toEqual([]);
      await child.stop();
      await expect(access(marker.allow)).rejects.toThrow();
      await expect(access(marker.deny)).rejects.toThrow();
    },
  );

  it.skipIf(process.platform !== "darwin").each(["missing", "replaced"])(
    "refuses cleanup and leaves an unrelated process alive when the negative marker is %s",
    async (action) => {
      const root = await mkdtemp(path.join(tmpdir(), "host marker integrity "));
      roots.push(root);
      const marker = await createHostProcessMarker();
      const script = path.join(root, "fixture.cjs");
      await writeFile(script, "console.log('ready'); setInterval(() => {}, 1000);");
      const child = await launchHostProcess({
        executable: process.execPath,
        args: [script],
        workspace: root,
        env: {},
        marker,
      });
      processes.push(child);
      expect(await output(child)()).toBe("ready");
      const foreign = spawn("/bin/sleep", ["30"], { env: {}, stdio: "ignore" });
      const saved = `${marker.deny}-saved`;
      let stopped = false;
      try {
        await rename(marker.deny, saved);
        if (action === "replaced")
          await writeFile(marker.deny, "replacement", { mode: 0o600, flag: "wx" });
        const stopping = child.stop().then(() => {
          stopped = true;
        });
        await new Promise((resolve) => setTimeout(resolve, 250));
        expect(stopped).toBe(false);
        expect(foreign.exitCode).toBeNull();
        expect(foreign.signalCode).toBeNull();
        await rm(marker.deny, { force: true });
        await rename(saved, marker.deny);
        await stopping;
        expect(foreign.exitCode).toBeNull();
        expect(foreign.signalCode).toBeNull();
      } finally {
        await rm(marker.deny, { force: true }).catch(() => {});
        await rename(saved, marker.deny).catch(() => {});
        foreign.kill("SIGKILL");
      }
    },
  );

  it.skipIf(process.platform !== "darwin")(
    "rejects workspaces in the reserved marker directory",
    async () => {
      const marker = await createHostProcessMarker();
      const nested = path.join(marker.directory, "workspace-fixture");
      try {
        await mkdir(nested);
        for (const workspace of [marker.directory, nested]) {
          await expect(
            launchHostProcess({
              executable: process.execPath,
              args: ["-e", ""],
              workspace,
              env: {},
            }),
          ).rejects.toThrow("host_workspace_reserved");
        }
      } finally {
        await rm(nested, { recursive: true, force: true });
        discardHostProcessMarker(marker);
      }
    },
  );

  it("passes only the explicit environment to the CLI", async () => {
    const previous = process.env.RAKAZO_HOST_FIXTURE_SECRET;
    process.env.RAKAZO_HOST_FIXTURE_SECRET = "fake-parent-only-secret";
    try {
      const program = "console.log(JSON.stringify(process.env));";
      const env = { FIXTURE_HOST_VALUE: "explicit" };
      const { child } = await launch(program, env);
      const value = JSON.parse(await output(child)());
      // libuv adds required Windows OS variables even with an explicit env. Compare
      // against a direct native spawn, including their values, rather than allow extras.
      const { stdout } = await promisify(execFile)(process.execPath, ["-e", program], {
        env: { SystemRoot: process.env.SystemRoot, ...env },
      });
      expect(value).toEqual(JSON.parse(stdout));
      expect(value.FIXTURE_HOST_VALUE).toBe("explicit");
      expect(value).not.toHaveProperty("RAKAZO_HOST_FIXTURE_SECRET");
    } finally {
      if (previous === undefined) delete process.env.RAKAZO_HOST_FIXTURE_SECRET;
      else process.env.RAKAZO_HOST_FIXTURE_SECRET = previous;
    }
  });

  it.each([
    "process.stdout.write('x'.repeat(3 * 1024 * 1024));",
    "console.log('x\\n'.repeat(2048));",
  ])("terminates output overflow rather than buffering without a bound: %s", async (program) => {
    const { child } = await launch(`${program} setInterval(() => {}, 1000);`);
    expect(await new Promise((resolve) => child.onExit(resolve))).toBe(1);
    await child.stop();
  });

  it("bounds writes and cleans up the process when input is too large", async () => {
    const { child } = await launch("setInterval(() => {}, 1000);");
    await expect(child.write("x".repeat(3 * 1024 * 1024))).rejects.toThrow("host_input_limit");
    await child.stop();
  });

  it("reports spawn failure without exposing executable paths or diagnostics", async () => {
    const root = await mkdtemp(path.join(tmpdir(), "host-missing-"));
    roots.push(root);
    await expect(
      launchHostProcess({
        executable: path.join(root, "missing.exe"),
        args: [],
        workspace: root,
        env: {},
      }),
    ).rejects.toThrow("host_process_start_failed");
  });

  it("requires absolute paths rather than resolving commands through a shell", async () => {
    await expect(
      launchHostProcess({ executable: "command", args: [], workspace: "relative", env: {} }),
    ).rejects.toThrow("host_absolute_path_required");
  });
});
