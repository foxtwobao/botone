import { realpath, stat } from "node:fs/promises";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import type { HarnessProcess } from "@rakazo/native-runtime/driver";
import type { HostProcessMarker } from "./host-process-macos.js";
import { spawnOwnedHostCommand } from "./host-process-owner.js";

const MAX_BYTES = 2 * 1024 * 1024;
const MAX_PENDING_LINES = 1024;

/**
 * A duplex protocol process, not a shell or a sandbox. The desktop composition root must
 * authorize the executable/workspace and configure the driver's host sandbox before launch.
 * Environment is explicit: never inherit a product server's environment into a user CLI.
 */
export async function launchHostProcess(options: {
  executable: string;
  args: string[];
  workspace: string;
  env: NodeJS.ProcessEnv;
  marker?: HostProcessMarker;
}): Promise<HarnessProcess> {
  if (!path.isAbsolute(options.executable) || !path.isAbsolute(options.workspace))
    throw new Error("host_absolute_path_required");
  // Shell shims require their own verified installer adapter, never implicit shell execution.
  if (process.platform === "win32" && !/\.exe$/i.test(options.executable))
    throw new Error("host_executable_unsupported");
  let workspace: string;
  try {
    workspace = await realpath(options.workspace);
    if (!(await stat(workspace)).isDirectory()) throw new Error();
  } catch {
    throw new Error("host_workspace_unavailable");
  }
  try {
    if (!(await stat(options.executable)).isFile()) throw new Error();
  } catch {
    throw new Error("host_process_start_failed");
  }
  const { child, tree } = await spawnOwnedHostCommand(
    [options.executable, ...options.args],
    workspace,
    options.env,
    options.marker,
  );
  let lineListener: ((line: string) => void) | undefined;
  let exitListener: ((code?: number | null) => void) | undefined;
  let code: number | null = null;
  let closed = false;
  let finished = false;
  let failed = false;
  let stopping: Promise<void> | undefined;
  let fragment = "";
  const pending: string[] = [];
  let pendingBytes = 0;
  function fail() {
    failed = true;
    void stop().catch(() => {});
  }
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk: string) => {
    if (stopping) return;
    fragment += chunk;
    if (Buffer.byteLength(fragment) > MAX_BYTES) return fail();
    while (fragment.includes("\n")) {
      const newline = fragment.indexOf("\n");
      const line = fragment.slice(0, newline).replace(/\r$/, "");
      fragment = fragment.slice(newline + 1);
      if (lineListener) lineListener(line);
      else {
        pendingBytes += Buffer.byteLength(line);
        if (pending.length >= MAX_PENDING_LINES || pendingBytes > MAX_BYTES) return fail();
        pending.push(line);
      }
      if (stopping) return;
    }
  });
  // Stderr may contain credentials or native account paths. Drain it without logging or
  // mixing it into the structured protocol; callers receive sanitized lifecycle failures.
  child.stderr.resume();
  child.stdout.on("error", fail);
  child.stderr.on("error", fail);
  child.on("error", fail);
  // Descendants can keep stdout/stderr open after their parent exits. Kill them on exit,
  // rather than waiting for close, which itself waits for those inherited pipes to close.
  child.on("exit", () => tree.kill());
  child.on("close", (exitCode) => {
    code = failed ? 1 : exitCode;
    closed = true;
    // A natural parent exit must also terminate descendants that still belong to its tree.
    void stop().then(
      () => {
        finished = true;
        exitListener?.(code);
      },
      () => {
        finished = true;
        code = 1;
        exitListener?.(code);
      },
    );
  });
  function stop() {
    stopping ??= (async () => {
      try {
        tree.kill();
        const deadline = Date.now() + (process.platform === "win32" ? 3000 : 12_000);
        while ((!closed || tree.alive()) && Date.now() < deadline) await delay(10);
        if (!closed || tree.alive()) throw new Error("host_stop_unconfirmed");
      } finally {
        tree.close();
      }
    })().catch((error) => {
      stopping = undefined;
      throw error;
    });
    return stopping;
  }
  try {
    await new Promise<void>((resolve, reject) => {
      child.once("spawn", resolve);
      child.once("error", () => reject(new Error("host_process_start_failed")));
    });
  } catch (error) {
    await stop();
    throw error;
  }
  return {
    workspace,
    onLine(listener) {
      lineListener = listener;
      for (const line of pending.splice(0)) listener(line);
      pendingBytes = 0;
    },
    onExit(listener) {
      exitListener = listener;
      if (finished) listener(code);
    },
    write(frame) {
      if (closed || stopping) return Promise.reject(new Error("host_process_stopped"));
      const input = `${JSON.stringify(frame)}\n`;
      if (Buffer.byteLength(input) + child.stdin.writableLength > MAX_BYTES) {
        fail();
        return Promise.reject(new Error("host_input_limit"));
      }
      return new Promise<void>((resolve, reject) => {
        child.stdin.write(input, (error) => {
          if (error) {
            fail();
            reject(new Error("host_process_write_failed"));
          } else resolve();
        });
      });
    },
    stop,
  };
}
