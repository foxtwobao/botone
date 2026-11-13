import { mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import type { ContractRouterClient } from "@orpc/contract";
import type { NativeExecutionEvent, NativeExecutionStart } from "@rakazo/adapter-kit";
import type { HostHarnessAdapter } from "@rakazo/adapters/host-harness";
import type { AppContract, HostFrame, HostStart } from "@rakazo/contracts";
import { FakeHarnessProcess, tick } from "@rakazo/native-runtime/testing";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DesktopHarness, hostIpcSchemas } from "./host-harness.js";

const cleanups: (() => Promise<void> | void)[] = [];
afterEach(async () => {
  for (const clean of cleanups.splice(0).reverse()) await clean();
});
const origin = "https://product.example.test";
const input = { spaceId: "space", botId: "bot", text: "Do the task", clientNonce: "message" };

function fixture() {
  const root = mkdtempSync(path.join(tmpdir(), "device-agent-fixture-"));
  cleanups.push(() => rmSync(root, { force: true, recursive: true }));
  const processes: FakeHarnessProcess[] = [];
  const emitters = new Map<string, (event: NativeExecutionEvent) => void>();
  const dispatches: NativeExecutionStart[] = [];
  let account = "user";
  let server: string | null = origin;
  let offline = false;
  const frames: HostFrame[] = [];
  const adapter: HostHarnessAdapter = {
    profile: { id: "fixture-cli", label: "Device agent", status: "ready" },
    version: "fixture-version",
    identity: "fixture-account",
    launch: vi.fn(async (workspace, tools) => {
      const process = new FakeHarnessProcess();
      Object.defineProperty(process, "workspace", { value: workspace });
      // The fake driver uses the same main-process callback as a native dynamic tool.
      process.externalTools = tools ? { ...tools, permissions: "fixture-read-only" } : undefined;
      processes.push(process);
      return process;
    }),
    driver: (_process, _version, emit) => ({
      capabilities: {
        resume: true,
        steer: false,
        permissions: true,
        questions: true,
        images: false,
        tools: false,
      },
      async start(request) {
        dispatches.push(request);
        emitters.set(request.runId, emit);
      },
      async respond(id) {
        emit({ type: "interaction_closed", id, status: "delivered" });
        return true;
      },
      async cancel() {},
      async steer() {
        return false;
      },
    }),
  };
  const starts = new Map<string, HostStart>();
  const start = vi.fn(async (request: HostStart) => {
    starts.set(request.clientNonce, request);
    return {
      runId: `run-${request.clientNonce}`,
      taskId: "task",
      threadId: "thread",
      seq: 1,
      token: request.token,
      userId: account,
      spaceId: "space",
      generation: "server-generation",
      leaseExpiresAt: new Date(Date.now() + 90_000).toISOString(),
      cursor: 2,
      stopped: false,
      instructions: "Server instructions",
      context: [],
    };
  });
  const sync = vi.fn(async (request: { frames: HostFrame[] }) => {
    if (offline) throw new Error("transport unavailable");
    for (const frame of request.frames)
      if (!frames.some((old) => old.sequence === frame.sequence)) frames.push(frame);
    return {
      after: frames.at(-1)?.sequence ?? 0,
      leaseExpiresAt: new Date(Date.now() + 90_000).toISOString(),
      stopped: frames.some((frame) =>
        ["completed", "failed", "cancelled"].includes(frame.event.type),
      ),
      answers: [],
    };
  });
  const rpc = {
    me: vi.fn(async () => ({ userId: account, spaceId: "space" })),
    bots: { get: vi.fn(async () => ({ id: "bot" })) },
    hostExecutions: {
      start,
      sync,
      answer: vi.fn(async () => ({ ok: true })),
      tool: vi.fn(async () => ({ result: '{"written":true}' })),
    },
    threads: {
      subscribe: vi.fn(async (_input: unknown, options: { signal: AbortSignal }) =>
        (async function* () {
          await new Promise<void>((resolve) => {
            if (options.signal.aborted) resolve();
            else options.signal.addEventListener("abort", () => resolve(), { once: true });
          });
        })(),
      ),
    },
  };
  const options = {
    root,
    currentOrigin: () => server,
    fetch,
    chooseDirectory: vi.fn(async () => root),
    confirm: vi.fn(async () => true),
    inspect: vi.fn(async () => adapter),
    client: () => rpc as unknown as ContractRouterClient<AppContract>,
  };
  const controller = new DesktopHarness(options);
  cleanups.push(() => controller.close());
  async function configure(target: "workspace" | "computer" = "workspace") {
    return controller.configure(origin, { ...input, profileId: adapter.profile.id, target });
  }
  return {
    root,
    controller,
    options,
    adapter,
    processes,
    emitters,
    dispatches,
    frames,
    rpc,
    configure,
    setAccount: (value: string) => {
      account = value;
    },
    setOrigin: (value: string | null) => {
      server = value;
    },
    setOffline: (value: boolean) => {
      offline = value;
    },
  };
}

describe("desktop-owned execution", () => {
  it("keeps credentials and run proofs out of the renderer and launches a nonce once", async () => {
    const f = fixture();
    await f.configure();
    const receipts = await Promise.all([
      f.controller.send(origin, input),
      f.controller.send(origin, input),
    ]);
    await tick();
    expect(receipts[0]).toEqual({ runId: "run-message", taskId: "task", seq: 1 });
    expect(receipts[1]).toEqual(receipts[0]);
    expect(f.adapter.launch).toHaveBeenCalledTimes(1);
    expect(f.dispatches).toHaveLength(1);
    expect(f.dispatches[0]).toMatchObject({
      prompt: input.text,
      instructions: "Server instructions",
    });
    expect(f.rpc.hostExecutions.start.mock.calls[0]![0].token).toHaveLength(64);
    const metadata = readdirSync(f.root).filter((name) => name.startsWith("run-"));
    expect(metadata).toHaveLength(1);
    expect(readFileSync(path.join(f.root, metadata[0]!), "utf8")).not.toContain(input.text);
    f.emitters.get("run-message")!({ type: "text", text: "Native output" });
    f.emitters.get("run-message")!({ type: "completed" });
    await vi.waitFor(() =>
      expect(f.frames.some((frame) => frame.event.type === "completed")).toBe(true),
    );
    expect(f.processes[0]!.stopped).toBe(true);
  });

  it("requires native consent and isolates the selected workspace by server and signed-in user", async () => {
    const f = fixture();
    f.options.confirm.mockResolvedValueOnce(false);
    expect(await f.configure()).toBe(null);
    await expect(f.controller.send(origin, input)).rejects.toThrow("Choose a local workspace");
    await f.configure();
    f.setAccount("another-user");
    expect(await f.controller.selection(origin, input)).toBe(null);
    await expect(f.controller.send(origin, input)).rejects.toThrow("Choose a local workspace");
    f.setOrigin("https://another.example.test");
    await expect(f.controller.profiles(origin, input)).rejects.toThrow("Local agent unavailable");
    expect(f.adapter.launch).not.toHaveBeenCalled();
  });

  it("cancels on disconnect and reconciles a journal after restart without replaying the prompt", async () => {
    const f = fixture();
    await f.configure();
    await f.controller.send(origin, input);
    await tick();
    f.setOffline(true);
    f.emitters.get("run-message")!({ type: "text", text: "Durable partial output" });
    await vi.waitFor(() => expect(f.processes[0]!.stopped).toBe(true));
    await f.controller.close();
    f.setOffline(false);
    const restarted = new DesktopHarness(f.options);
    cleanups.push(() => restarted.close());
    await restarted.profiles(origin, { spaceId: "space" });
    expect(f.adapter.launch).toHaveBeenCalledTimes(1);
    expect(f.frames.map((frame) => frame.event.type)).toContain("cancelled");
    expect(f.frames.some((frame) => frame.event.type === "text")).toBe(true);
    expect(readdirSync(f.root).some((name) => name.startsWith("run-"))).toBe(false);
  });

  it("stops before logout and never gives another account an old approval", async () => {
    const f = fixture();
    await f.configure();
    await f.controller.send(origin, input);
    await tick();
    f.setAccount("another-user");
    await expect(
      f.controller.answer(origin, { runId: "run-message", messageId: "ask", answer: "allow" }),
    ).rejects.toThrow("scope changed");
    expect(f.rpc.hostExecutions.answer).not.toHaveBeenCalled();
    f.setAccount("user");
    await f.controller.disconnectedWindow();
    expect(f.processes[0]!.stopped).toBe(true);
    expect(f.controller.hasRuns()).toBe(false);
  });

  it("uses a private read-only scratch area and grants only the selected remote computer's tools", async () => {
    const f = fixture();
    const selection = await f.configure("computer");
    expect(f.options.chooseDirectory).not.toHaveBeenCalled();
    expect(selection?.workspace).toContain(`${path.sep}scratch${path.sep}`);
    await f.controller.send(origin, input);
    await tick();
    const tools = f.processes[0]!.externalTools!;
    expect(tools.permissions).toBe("fixture-read-only");
    expect(
      await tools.invoke("operation", "computer_write_file", {
        path: "result.txt",
        text: "result",
      }),
    ).toBe('{"written":true}');
    expect(f.rpc.hostExecutions.tool).toHaveBeenCalledWith(
      expect.objectContaining({ runId: "run-message", id: "operation" }),
      expect.anything(),
    );
    await f.controller.stop(origin, input);
    await expect(
      tools.invoke("late", "computer_write_file", { path: "late.txt", text: "late" }),
    ).rejects.toThrow("stopped");
  });

  it("rejects renderer-supplied executable paths, scopes and run proofs", () => {
    expect(
      hostIpcSchemas.send.safeParse({ ...input, executable: "/untrusted/program" }).success,
    ).toBe(false);
    expect(
      hostIpcSchemas.answer.safeParse({
        runId: "run",
        messageId: "message",
        answer: "allow",
        token: "renderer-proof",
      }).success,
    ).toBe(false);
    expect(
      hostIpcSchemas.configure.safeParse({ ...input, profileId: "profile", userId: "other" })
        .success,
    ).toBe(false);
  });

  it("shares shutdown and keeps Quit blocked until process cleanup is confirmed", async () => {
    const f = fixture();
    await f.configure();
    await f.controller.send(origin, input);
    await tick();
    const original = f.processes[0]!.stop.bind(f.processes[0]);
    let release!: () => void;
    f.processes[0]!.stop = async () => {
      await new Promise<void>((resolve) => {
        release = resolve;
      });
      await original();
    };
    const closing = f.controller.close();
    expect(f.controller.close()).toBe(closing);
    await tick();
    expect(f.controller.hasRuns()).toBe(true);
    release();
    await closing;
    expect(f.controller.hasRuns()).toBe(false);
  });
});
