import { spawn } from "node:child_process";
import { mkdtemp, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import type { NativeExecutionEvent } from "@rakazo/adapter-kit";
import { createHostCodexDriver } from "@rakazo/native-runtime/codex";
import type { HarnessProcess } from "@rakazo/native-runtime/driver";
import { safeHostConfiguration, startRequest } from "@rakazo/native-runtime/testing";
import { afterEach, describe, expect, it } from "vitest";
import { WINDOWS_COMMAND_WRAPPER } from "../desktop-process-tree.js";
import { launchHostProcess } from "./host-process.js";

describe.skipIf(!["linux", "win32"].includes(process.platform))("host protocol process", () => {
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
      const intermediate = `const child = require('node:child_process').spawn(process.execPath, ['-e', ${JSON.stringify(grandchild)}], { detached: true, stdio: 'ignore' }); require('node:fs').writeFileSync('descendant', String(child.pid)); child.unref();`;
      let pid: number | undefined;
      try {
        const { child, root } = await launch(`
        const fs = require('node:fs');
        const child = require('node:child_process').spawn(process.execPath, ['-e', ${JSON.stringify(intermediate)}], { detached: true, stdio: 'ignore' });
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
        expect(() => process.kill(pid!, 0)).toThrow();
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

  it("passes only the explicit environment to the CLI", async () => {
    const { child } = await launch("console.log(JSON.stringify(process.env));", {
      FIXTURE_HOST_VALUE: "explicit",
    });
    const value = JSON.parse(await output(child)());
    expect(value.FIXTURE_HOST_VALUE).toBe("explicit");
    expect(
      Object.keys(value)
        .map((key) => key.toLowerCase())
        .sort(),
    ).toEqual(
      process.env.SystemRoot ? ["fixture_host_value", "systemroot"] : ["fixture_host_value"],
    );
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
