import { spawn } from "node:child_process";
import { constants } from "node:fs";
import { chown, mkdtemp, open, readFile, realpath, rm } from "node:fs/promises";
import type { Socket } from "node:net";
import { createServer } from "node:net";
import path from "node:path";
import type { Writable } from "node:stream";
import { fileURLToPath } from "node:url";
import type { NativeExecutionStart } from "@rakazo/adapter-kit";
import { resolveComputerTarget } from "./computer-target.js";
import type { HarnessProcess } from "./driver.js";
import { record, text } from "./driver.js";
import { computerInitializationProgram } from "./initialization-program.js";
import type { ComputerExecutionProfile } from "./launch-arguments.js";
import { nativeLaunchArguments } from "./launch-arguments.js";

export async function launchComputerHarness(
  profile: ComputerExecutionProfile,
  request: NativeExecutionStart,
  controlRoot: string,
  inspection?: "version" | "authentication" | "isolation",
): Promise<HarnessProcess> {
  if (process.platform !== "linux") throw new Error("unsupported_execution_platform");
  const account = await resolveComputerTarget(profile.computer, request.scope);
  const control = await realpath(controlRoot);
  if (control === account.source || control.startsWith(`${account.source}${path.sep}`))
    throw new Error("computer_contains_execution_control");
  const brokerRoot = await mkdtemp(path.join(account.source, ".native-harness-"));
  const brokerDirectory = await open(
    brokerRoot,
    constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW,
  );
  const socketPath = `/proc/self/fd/${brokerDirectory.fd}/permissions.sock`;
  let permission: Parameters<NonNullable<HarnessProcess["onPermission"]>>[0] | undefined;
  let tool: Parameters<NonNullable<HarnessProcess["onTool"]>>[0] | undefined;
  const sockets = new Set<Socket>();
  const broker = createServer((socket) => {
    sockets.add(socket);
    socket.once("close", () => sockets.delete(socket));
    socket.on("error", () => {});
    socket.setEncoding("utf8");
    let buffer = "";
    let received = false;
    socket.on("data", (chunk: string) => {
      buffer += chunk;
      if (Buffer.byteLength(buffer) > 1024 * 1024 || received) return socket.destroy();
      const newline = buffer.indexOf("\n");
      if (newline === -1) return;
      received = true;
      try {
        const message = record(JSON.parse(buffer.slice(0, newline)));
        if (!text(message.id) || !text(message.tool)) return socket.destroy();
        const result =
          message.mode === "tools"
            ? tool?.({ name: text(message.tool), input: record(message.input) })
            : permission?.({
                id: text(message.id),
                tool: text(message.tool),
                input: record(message.input),
              });
        if (!result) return socket.destroy();
        void result.then(
          (answer) => socket.end(`${JSON.stringify({ id: message.id, answer })}\n`),
          () => socket.destroy(),
        );
      } catch {
        socket.destroy();
      }
    });
  });
  await new Promise<void>((resolve, reject) => {
    broker.once("error", reject);
    broker.listen(socketPath, () => {
      broker.removeListener("error", reject);
      resolve();
    });
  });
  await chown(socketPath, account.uid, account.gid);
  await brokerDirectory.chown(account.uid, account.gid);
  const runner = await open(fileURLToPath(new URL("./computer-runner.mjs", import.meta.url)), "r");
  const node = "/usr/bin/node";
  let command =
    inspection === "version"
      ? [profile.engine === "deepseek" ? "dsh" : profile.engine, "--version"]
      : inspection === "authentication"
        ? profile.engine === "codex"
          ? ["codex", "login", "status"]
          : profile.engine === "claude"
            ? ["claude", "auth", "status", "--json"]
            : ["dsh", "--help"]
        : inspection === "isolation"
          ? [
              node,
              "-e",
              `const fs=require('node:fs');console.log(JSON.stringify({privatePaths:${JSON.stringify([controlRoot, account.source])}.map(p=>fs.existsSync(p)),deploymentEnvironment:['DATABASE_URL','ENCRYPTION_KEY','EXECUTION_TOKEN'].some(k=>k in process.env),uid:process.getuid(),groups:process.getgroups(),cgroup:fs.readFileSync('/proc/self/cgroup','utf8').trim(),pid:process.pid,pidNamespace:fs.statSync('/proc/self/ns/pid').ino}));`,
            ]
          : nativeLaunchArguments(profile, request);
  if (profile.initialization) {
    if (inspection === "version")
      command[0] = `/usr/local/bin/${profile.engine === "deepseek" ? "dsh" : profile.engine}`;
    else if (!inspection)
      command = [
        "/usr/local/bin/node",
        "--input-type=module",
        "--eval",
        computerInitializationProgram,
        profile.engine === "deepseek" ? "dsh" : profile.engine,
        ...command.slice(1),
      ];
  }
  // The selected computer supplies its filesystem, installed software, home, and network.
  // A private PID namespace makes stopping one run terminate all its descendants.
  const child = spawn(
    "/usr/bin/nsenter",
    [
      `--target=${account.pid}`,
      "--join-cgroup",
      "--cgroup",
      `--mount=/proc/${account.pid}/ns/mnt`,
      `--net=/proc/${account.pid}/ns/net`,
      `--ipc=/proc/${account.pid}/ns/ipc`,
      `--uts=/proc/${account.pid}/ns/uts`,
      `--root=/proc/${account.pid}/root`,
      `--wd=/proc/${account.pid}/root${account.home}`,
      "--",
      "/usr/bin/unshare",
      "--mount",
      "--pid",
      "--fork",
      "--kill-child",
      "--mount-proc",
      node,
      "--input-type=module",
      "--eval",
      "import {readFileSync,closeSync} from 'node:fs';const code=readFileSync(4);closeSync(4);await import('data:text/javascript;base64,'+code.toString('base64'));",
    ],
    {
      detached: true,
      stdio: ["ignore", "pipe", "ignore", "pipe", runner.fd, "pipe"],
      env: { PATH: "/usr/bin:/bin" },
    },
  );
  await runner.close();
  const configuration = child.stdio[3] as Writable;
  configuration.on("error", () => {});
  configuration.end(
    JSON.stringify({
      uid: account.uid,
      gid: account.gid,
      env: {
        ...account.env,
        ...(profile.initialization && !inspection
          ? {
              COMPUTER_MODEL_INITIALIZATION: JSON.stringify(profile.initialization),
              COMPUTER_MODEL_PROGRAM: computerInitializationProgram,
              COMPUTER_MODEL_LAUNCH: "1",
            }
          : {}),
        ...(profile.modelConnection
          ? profile.engine === "claude"
            ? {
                ANTHROPIC_BASE_URL: profile.modelConnection.url.replace(/\/v1\/?$/, ""),
                ANTHROPIC_AUTH_TOKEN: profile.modelConnection.apiKey,
                ANTHROPIC_DEFAULT_HAIKU_MODEL: profile.modelConnection.model,
                ANTHROPIC_DEFAULT_SONNET_MODEL: profile.modelConnection.model,
                ANTHROPIC_DEFAULT_OPUS_MODEL: profile.modelConnection.model,
              }
            : { OPENAI_API_KEY: profile.modelConnection.apiKey }
          : {}),
      },
      workspace: profile.computer.workspace,
      broker: path.join(account.home, path.basename(brokerRoot)),
      command,
      proxy: await readFile(
        fileURLToPath(new URL("./permission-proxy.mjs", import.meta.url)),
        "utf8",
      ),
    }),
  );
  const input = child.stdio.at(5) as Writable;
  const output = child.stdout!;
  const lineListeners = new Set<(line: string) => void>();
  const exitListeners = new Set<(code?: number | null) => void>();
  let exitCode: number | null | undefined;
  const queued: string[] = [];
  let ended = false;
  let stopPromise: Promise<void> | undefined;
  let resolveExit: () => void = () => {};
  const exited = new Promise<void>((resolve) => {
    resolveExit = resolve;
  });
  let buffer = "";
  output.setEncoding("utf8");
  output.on("data", (chunk: string) => {
    buffer += chunk;
    if (Buffer.byteLength(buffer) > 1024 * 1024) {
      void stop();
      return;
    }
    let newline = buffer.indexOf("\n");
    while (newline !== -1) {
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      newline = buffer.indexOf("\n");
      if (!line.trim()) continue;
      if (queued.length >= 1024) {
        void stop();
        return;
      }
      if (!lineListeners.size) queued.push(line);
      else for (const listener of lineListeners) listener(line);
    }
  });
  const onExit = (code?: number | null) => {
    if (ended) return;
    ended = true;
    exitCode = code;
    resolveExit();
    for (const listener of exitListeners) listener(code);
  };
  child.once("close", onExit);
  child.once("error", () => onExit());
  input.on("error", () => {
    void stop();
  });
  function stop() {
    stopPromise ??= (async () => {
      if (!ended && child.pid) {
        try {
          process.kill(-child.pid, "SIGTERM");
        } catch {}
        const kill = setTimeout(() => {
          try {
            process.kill(-child.pid!, "SIGKILL");
          } catch {}
        }, 2_000);
        try {
          await exited;
        } finally {
          clearTimeout(kill);
        }
      }
      for (const socket of sockets) socket.destroy();
      await new Promise<void>((resolve) => broker.close(() => resolve()));
      await brokerDirectory.close();
      await rm(brokerRoot, { recursive: true, force: true });
    })();
    return stopPromise;
  }
  return {
    onTool(listener) {
      tool = listener;
    },
    onLine(listener) {
      lineListeners.add(listener);
      for (const line of queued.splice(0)) listener(line);
    },
    onExit(listener) {
      exitListeners.add(listener);
      if (ended) listener(exitCode);
    },
    onPermission(listener) {
      permission = listener;
    },
    write(frame) {
      if (ended) return Promise.reject(new Error("execution_process_lost"));
      const line = `${JSON.stringify(frame)}\n`;
      if (Buffer.byteLength(line) > 1024 * 1024)
        return Promise.reject(new Error("execution_frame_limit"));
      return new Promise((resolve, reject) =>
        input.write(line, (error) =>
          error ? reject(new Error("execution_write_failed")) : resolve(),
        ),
      );
    },
    stop,
  };
}
