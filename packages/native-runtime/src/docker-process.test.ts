import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { Duplex, PassThrough } from "node:stream";
import { afterEach, expect, it } from "vitest";
import { computerMcpServer } from "./bridge-tools.js";
import type { ComputerExec } from "./docker-process.js";
import { launchDockerProcess } from "./docker-process.js";

const directories: string[] = [];
afterEach(async () => {
  await Promise.all(directories.splice(0).map((dir) => rm(dir, { recursive: true, force: true })));
});

const local: ComputerExec = {
  async exec(options) {
    return {
      async start() {
        const child = spawn(options.Cmd[0]!, options.Cmd.slice(1), {
          cwd: options.WorkingDir,
          env: Object.fromEntries(
            options.Env.map((entry) => {
              const index = entry.indexOf("=");
              return [entry.slice(0, index), entry.slice(index + 1)];
            }),
          ),
          stdio: ["pipe", "pipe", "pipe"],
        });
        const frames = new PassThrough();
        for (const [channel, output] of [
          [1, child.stdout],
          [2, child.stderr],
        ] as const)
          output.on("data", (body: Buffer) => {
            const header = Buffer.alloc(8);
            header[0] = channel;
            header.writeUInt32BE(body.length, 4);
            // Split a Docker header and UTF-8 arbitrarily to exercise the incremental transport.
            frames.write(header.subarray(0, 3));
            frames.write(Buffer.concat([header.subarray(3), body]));
          });
        child.on("close", () => frames.end());
        return Duplex.from({ readable: frames, writable: child.stdin });
      },
    };
  },
};

async function fixture() {
  const dir = await mkdtemp(path.join(tmpdir(), "native-process-"));
  directories.push(dir);
  return dir;
}
const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

it("exchanges multiple protocol frames, Unicode and a confirmed natural exit", async () => {
  const workspace = await fixture();
  const process = await launchDockerProcess(local, {
    workspace,
    user: "1000:1000",
    env: { PATH: "/usr/bin:/bin" },
    command: () => [
      "/usr/bin/python3",
      "-u",
      "-c",
      "import sys,json; print('ready 世界',flush=True); [print(json.dumps(json.loads(sys.stdin.readline())),flush=True) for _ in range(2)]",
    ],
  });
  const lines: string[] = [];
  process.onLine((line) => lines.push(line));
  const exit = new Promise((resolve) => process.onExit(resolve));
  await process.write({ message: "你好" });
  await process.write({ message: "again" });
  expect(await exit).toBe(0);
  await process.stop();
  expect(lines).toHaveLength(3);
  expect(lines[0]).toBe("ready 世界");
  expect(JSON.parse(lines[1]!)).toEqual({ message: "你好" });
});

it("stops detached, double-forked TERM-resistant tools without stopping an unrelated process", async () => {
  const workspace = await fixture();
  const output = path.join(workspace, "ticks");
  const unrelated = spawn("/bin/sleep", ["30"]);
  const process = await launchDockerProcess(local, {
    workspace,
    user: "1000:1000",
    env: { PATH: "/usr/bin:/bin" },
    command: () => [
      "/usr/bin/python3",
      "-u",
      "-c",
      String.raw`
import os,signal,time
if os.fork()==0:
 os.setsid()
 if os.fork()!=0: os._exit(0)
 signal.signal(signal.SIGTERM,signal.SIG_IGN)
 while True:
  with open('ticks','a') as f:f.write('tick\n')
  time.sleep(.02)
print('spawned',flush=True)
time.sleep(60)
`,
    ],
  });
  try {
    for (let attempt = 0; attempt < 100; attempt++) {
      if (await readFile(output, "utf8").catch(() => "")) break;
      await delay(20);
    }
    expect((await readFile(output, "utf8")).length).toBeGreaterThan(0);
    await process.stop();
    const stopped = await readFile(output, "utf8");
    await delay(150);
    expect(await readFile(output, "utf8")).toBe(stopped);
    expect(unrelated.exitCode).toBeNull();
  } finally {
    await process.stop();
    unrelated.kill("SIGKILL");
  }
});

it("relays broker requests over the same process stream", async () => {
  const workspace = await fixture();
  const process = await launchDockerProcess(local, {
    workspace,
    user: "1000:1000",
    env: { PATH: "/usr/bin:/bin" },
    command: (socket) => [
      "/usr/bin/python3",
      "-u",
      "-c",
      String.raw`
import socket,json,sys,time
s=socket.socket(socket.AF_UNIX);s.connect(sys.argv[1]);s.sendall(b'{"id":"one","tool":"approve","input":{},"mode":"permissions"}\n');print(s.recv(4096).decode(),flush=True)
`,
      socket,
    ],
  });
  // A fast child can request approval before its consumer has registered callbacks.
  await delay(50);
  process.onPermission!(async () => ({ behavior: "allow" }));
  const lines: string[] = [];
  process.onLine((line) => lines.push(line));
  await new Promise((resolve) => process.onExit(resolve));
  await process.stop();
  expect(JSON.parse(lines.find((line) => line.startsWith("{"))!)).toEqual({
    id: "one",
    answer: { behavior: "allow" },
  });
});

it("runs the actual stdio MCP proxy and delivers platform tool results", async () => {
  const workspace = await fixture();
  const process = await launchDockerProcess(local, {
    workspace,
    user: "1000:1000",
    env: { PATH: "/usr/local/bin:/usr/bin:/bin" },
    command: (socket) => [globalThis.process.execPath, ...computerMcpServer(socket).args],
  });
  const frames: Array<{ id: number; result: unknown }> = [];
  process.onLine((line) => frames.push(JSON.parse(line)));
  const calls: unknown[] = [];
  process.onTool!(async (request) => {
    calls.push(request);
    return { content: "found" };
  });
  try {
    await process.write({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { protocolVersion: "2024-11-05" },
    });
    await process.write({ jsonrpc: "2.0", id: 2, method: "tools/list" });
    await process.write({
      jsonrpc: "2.0",
      id: 3,
      method: "tools/call",
      params: { name: "recall_memory", arguments: { query: "task" } },
    });
    await expect.poll(() => frames.length).toBe(3);
    expect(calls).toEqual([{ name: "recall_memory", input: { query: "task" } }]);
    expect(frames.find((frame) => frame.id === 3)?.result).toEqual({
      content: [{ type: "text", text: JSON.stringify({ content: "found" }) }],
    });
    expect(JSON.stringify(frames.find((frame) => frame.id === 2))).toContain("publish_file");
  } finally {
    await process.stop();
  }
});

it("fences a replacement run until the previous computer process has finished cleanup", async () => {
  const workspace = await fixture();
  const options = {
    workspace,
    user: "1000:1000",
    env: { PATH: "/usr/bin:/bin" },
    runKey: randomUUID(),
    command: () => ["/bin/sleep", "30"],
  };
  const first = await launchDockerProcess(local, options);
  try {
    await expect(launchDockerProcess(local, options)).rejects.toThrow("computer_process_exited");
  } finally {
    await first.stop();
  }
  const replacement = await launchDockerProcess(local, options);
  await replacement.stop();
});

it("cleans up a process emitting invalid protocol encoding instead of leaving it waiting", async () => {
  const workspace = await fixture();
  const child = await launchDockerProcess(local, {
    workspace,
    user: "1000:1000",
    env: { PATH: "/usr/bin:/bin" },
    command: () => [
      "python3",
      "-u",
      "-c",
      String.raw`import sys,time; sys.stdout.buffer.write(b'\xff\n');sys.stdout.flush();time.sleep(30)`,
    ],
  });
  await new Promise((resolve) => child.onExit(resolve));
  await child.stop();
});
