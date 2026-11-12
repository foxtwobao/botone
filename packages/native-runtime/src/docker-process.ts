import { randomUUID } from "node:crypto";
import type { Duplex } from "node:stream";
import { StringDecoder } from "node:string_decoder";
import { computerMcpServer } from "./bridge-tools.js";
import type { HarnessProcess } from "./driver.js";
import { computerProcessProgram } from "./process-program.js";

/** Minimal Docker boundary; also exercised using real local pipes in offline tests. */
export interface ComputerExec {
  exec(options: {
    Cmd: string[];
    User: string;
    WorkingDir: string;
    Env: string[];
    AttachStdin: boolean;
    AttachStdout: boolean;
    AttachStderr: boolean;
  }): Promise<{
    start(options: { hijack: boolean; stdin: boolean }): Promise<Duplex>;
  }>;
}

export async function launchDockerProcess(
  container: ComputerExec,
  options: {
    command(socket: string): string[];
    workspace: string;
    env: Record<string, string>;
    user: string;
    /** Kernel-owned per-bot fence also survives a supervisor restart until cleanup finishes. */
    runKey?: string;
  },
): Promise<HarnessProcess> {
  const socket = `/tmp/native-${randomUUID()}.sock`;
  const exec = await container.exec({
    Cmd: ["/usr/bin/python3", "-u", "-c", computerProcessProgram],
    User: options.user,
    WorkingDir: options.workspace,
    Env: Object.entries(options.env).map(([key, value]) => `${key}=${value}`),
    AttachStdin: true,
    AttachStdout: true,
    AttachStderr: true,
  });
  const stream = await exec.start({ hijack: true, stdin: true });
  let permission: Parameters<NonNullable<HarnessProcess["onPermission"]>>[0] | undefined;
  let tool: Parameters<NonNullable<HarnessProcess["onTool"]>>[0] | undefined;
  let listener: ((line: string) => void) | undefined;
  let exitListener: ((code?: number | null) => void) | undefined;
  const pending: string[] = [];
  const requests: Array<{
    id: string;
    mode: string;
    tool: string;
    input: Record<string, unknown>;
  }> = [];
  let buffered = 0;
  let finished = false;
  let clean = false;
  let exitCode: number | null = null;
  let resolveExit: () => void = () => {};
  const exited = new Promise<void>((resolve) => {
    resolveExit = resolve;
  });
  let resolveReady: () => void = () => {};
  let rejectReady: (error: Error) => void = () => {};
  const ready = new Promise<void>((resolve, reject) => {
    resolveReady = resolve;
    rejectReady = reject;
  });
  const write = (value: unknown) =>
    new Promise<void>((resolve, reject) => {
      if (stream.destroyed) {
        reject(new Error("computer_process_disconnected"));
        return;
      }
      stream.write(`${JSON.stringify(value)}\n`, (error) => (error ? reject(error) : resolve()));
    });
  function finish(code: number | null, acknowledged: boolean) {
    if (finished) return;
    finished = true;
    clean = acknowledged;
    exitCode = code;
    clearInterval(heartbeat);
    clearTimeout(startup);
    rejectReady(new Error("computer_process_exited"));
    exitListener?.(code);
    resolveExit();
  }
  const heartbeat = setInterval(() => {
    void write({ type: "heartbeat" }).catch(() => stream.destroy());
  }, 5000);
  heartbeat.unref();
  const startup = setTimeout(() => {
    rejectReady(new Error("computer_process_start_timeout"));
    stream.destroy();
  }, 10000);
  startup.unref();
  function deliverRequests() {
    for (let index = requests.length - 1; index >= 0; index--) {
      const request = requests[index]!;
      if (request.mode === "tools" ? !tool : !permission) continue;
      requests.splice(index, 1);
      void Promise.resolve()
        .then(() =>
          request.mode === "tools"
            ? tool!({ name: request.tool, input: request.input })
            : permission!(request),
        )
        .then(
          (answer) => write({ type: "answer", id: request.id, answer }),
          () => write({ type: "answer", id: request.id, answer: { behavior: "deny" } }),
        )
        .catch(() => stream.destroy());
    }
  }
  const decoder = new StringDecoder("utf8");
  let bytes = Buffer.alloc(0);
  let text = "";
  stream.on("data", (chunk: Buffer) => {
    bytes = Buffer.concat([bytes, chunk]);
    // Docker's non-TTY attach stream uses an eight-byte stdout/stderr header.
    while (bytes.length >= 8) {
      const size = bytes.readUInt32BE(4);
      if (size > 2 * 1024 * 1024) {
        stream.destroy();
        return;
      }
      if (bytes.length < 8 + size) break;
      const channel = bytes[0];
      const body = bytes.subarray(8, 8 + size);
      bytes = bytes.subarray(8 + size);
      if (channel !== 1) continue;
      text += decoder.write(body);
      if (Buffer.byteLength(text) > 2 * 1024 * 1024) {
        stream.destroy();
        return;
      }
      while (text.includes("\n")) {
        const newline = text.indexOf("\n");
        const line = text.slice(0, newline);
        text = text.slice(newline + 1);
        try {
          const message = JSON.parse(line);
          if (message.type === "ready") {
            clearTimeout(startup);
            resolveReady();
          } else if (message.type === "exit") {
            finish(message.code, message.clean === true);
            stream.end();
          } else if (message.type === "line") {
            if (typeof message.line !== "string") throw new Error("invalid_line");
            if (listener) listener(message.line);
            else {
              buffered += Buffer.byteLength(message.line);
              if (buffered > 2 * 1024 * 1024) throw new Error("output_limit");
              pending.push(message.line);
            }
          } else if (message.type === "request") {
            if (requests.length >= 64) throw new Error("request_limit");
            requests.push(message.request);
            deliverRequests();
          }
        } catch {
          stream.destroy();
          return;
        }
      }
    }
  });
  stream.on("error", () => finish(null, false));
  stream.on("close", () => finish(null, false));
  try {
    await write({
      command: options.command(socket),
      socket,
      workspace: options.workspace,
      env: options.env,
      runKey: options.runKey,
    });
    await ready;
  } catch (error) {
    stream.destroy();
    // Observe a startup rejection even if the initial write failed first.
    void ready.catch(() => {});
    throw error;
  }
  return {
    workspace: options.workspace,
    mcpServer: computerMcpServer(socket),
    onLine(callback) {
      listener = callback;
      for (const line of pending) callback(line);
      pending.length = 0;
      buffered = 0;
    },
    onExit(callback) {
      exitListener = callback;
      if (finished) callback(exitCode);
    },
    onPermission(callback) {
      permission = callback;
      deliverRequests();
    },
    onTool(callback) {
      tool = callback;
      deliverRequests();
    },
    write: (frame) => write({ type: "input", frame }),
    async stop() {
      if (!finished) {
        await write({ type: "stop" });
        let timeout: NodeJS.Timeout | undefined;
        try {
          await Promise.race([
            exited,
            new Promise<never>((_, reject) => {
              timeout = setTimeout(() => reject(new Error("computer_stop_unconfirmed")), 12000);
            }),
          ]);
        } finally {
          clearTimeout(timeout);
          stream.destroy();
        }
      }
      if (!clean) throw new Error("computer_stop_unconfirmed");
    },
  };
}
