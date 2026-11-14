import { mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import type { ContractRouterClient } from "@orpc/contract";
import type { NativeExecutionEvent, NativeExecutionStart } from "@rakazo/adapter-kit";
import type { AppContract, HostFrame, HostStart } from "@rakazo/contracts";
import { FakeHarnessProcess, tick } from "@rakazo/native-runtime/testing";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { HostHarnessAdapter } from "./host-adapter.js";
import { DesktopHarness, hostIpcSchemas } from "./host-desktop.js";

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
    executions: {
      host: {
        start,
        sync,
        answer: vi.fn(async () => ({ ok: true })),
        tool: vi.fn(async () => ({ result: '{"written":true}' })),
      },
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
  it.each(["failed", "pending"])(
    "stops a local process without waiting for a %s server identity request",
    async (status) => {
      const f = fixture();
      await f.configure();
      await f.controller.send(origin, input);
      await tick();
      expect(f.processes[0]!.stopped).toBe(false);
      f.rpc.me.mockClear();
      if (status === "failed") f.rpc.me.mockRejectedValue(new Error("transport unavailable"));
      else f.rpc.me.mockImplementation(() => new Promise(() => {}));
      await f.controller.stop(origin, input);
      expect(f.processes[0]!.stopped).toBe(true);
      expect(f.rpc.me).not.toHaveBeenCalled();
      expect(f.frames.map((frame) => frame.event)).toContainEqual({ type: "cancelled" });
    },
  );

  it("only stops runs matching the trusted window, space and bot", async () => {
    const f = fixture();
    await f.configure();
    await f.controller.send(origin, input);
    await tick();
    await expect(f.controller.stop("https://other.example.test", input)).rejects.toThrow(
      "Local agent unavailable",
    );
    await f.controller.stop(origin, { ...input, spaceId: "other-space" });
    await f.controller.stop(origin, { ...input, botId: "other-bot" });
    expect(f.processes[0]!.stopped).toBe(false);
    await f.controller.stop(origin, input);
    expect(f.processes[0]!.stopped).toBe(true);
  });

  it.each(["disconnect", "stop", "configure", "close"])(
    "revokes a pending server grant on %s without replaying its prompt",
    async (action) => {
      const f = fixture();
      await f.configure();
      const original = f.rpc.executions.host.start.getMockImplementation()!;
      let release!: () => void;
      const barrier = new Promise<void>((resolve) => {
        release = resolve;
      });
      f.rpc.executions.host.start.mockImplementation(async (request) => {
        const grant = await original(request);
        await barrier;
        return grant;
      });
      const pending = f.controller.send(origin, input).catch((error) => error);
      await vi.waitFor(() => expect(f.rpc.executions.host.start).toHaveBeenCalled());
      expect(f.controller.hasRuns()).toBe(true);
      if (action === "disconnect") await f.controller.disconnectedWindow();
      if (action === "stop") await f.controller.stop(origin, input);
      if (action === "configure")
        await f.controller.configure(origin, { ...input, profileId: null });
      if (action === "close") await f.controller.close();
      release();
      expect(await pending).toBeInstanceOf(Error);
      await tick();
      expect(f.adapter.launch).not.toHaveBeenCalled();
      const restarted = new DesktopHarness(f.options);
      cleanups.push(() => restarted.close());
      await restarted.profiles(origin, input);
      if (action === "configure")
        await expect(restarted.send(origin, input)).rejects.toThrow("Choose a local workspace");
      else await restarted.send(origin, input).catch(() => undefined);
      expect(f.adapter.launch).not.toHaveBeenCalled();
      expect(f.dispatches).toHaveLength(0);
    },
  );

  it.each(["owner", "inspect"])("revokes authority while waiting for %s", async (stage) => {
    const f = fixture();
    await f.configure();
    let release!: () => void;
    const barrier = new Promise<void>((resolve) => {
      release = resolve;
    });
    if (stage === "owner")
      f.rpc.me.mockImplementationOnce(async () => {
        await barrier;
        return { userId: "user", spaceId: "space" };
      });
    else
      f.options.inspect.mockImplementationOnce(async () => {
        await barrier;
        return f.adapter;
      });
    const pending = f.controller.send(origin, input).catch((error) => error);
    await tick();
    expect(f.controller.hasRuns()).toBe(true);
    await f.controller.disconnectedWindow();
    release();
    expect(await pending).toBeInstanceOf(Error);
    expect(f.rpc.executions.host.start).not.toHaveBeenCalled();
    expect(f.adapter.launch).not.toHaveBeenCalled();
  });

  it("reauthenticates a granted launch after the signed-in account changes", async () => {
    const f = fixture();
    await f.configure();
    const original = f.rpc.executions.host.start.getMockImplementation()!;
    f.rpc.executions.host.start.mockImplementation(async (request) => {
      const grant = await original(request);
      f.setAccount("another-user");
      return grant;
    });
    await expect(f.controller.send(origin, input)).rejects.toThrow("scope changed");
    expect(f.adapter.launch).not.toHaveBeenCalled();
  });

  it.each(["disconnect", "stop", "close"])(
    "does not save consent that finishes after %s",
    async (action) => {
      const f = fixture();
      let release!: (value: boolean) => void;
      f.options.confirm.mockImplementationOnce(
        () =>
          new Promise<boolean>((resolve) => {
            release = resolve;
          }),
      );
      const pending = f.configure().catch((error) => error);
      await vi.waitFor(() => expect(f.options.confirm).toHaveBeenCalled());
      if (action === "disconnect") await f.controller.disconnectedWindow();
      if (action === "stop") await f.controller.stop(origin, input);
      if (action === "close") await f.controller.close();
      release(true);
      expect(await pending).toBeInstanceOf(Error);
      expect(
        JSON.parse(readFileSync(path.join(f.root, "settings.json"), "utf8")).selections,
      ).toEqual({});
    },
  );

  it("uploads cancellation and partial output only after orderly shutdown confirms cleanup", async () => {
    const f = fixture();
    await f.configure();
    await f.controller.send(origin, input);
    await tick();
    f.emitters.get("run-message")!({ type: "text", text: "Partial output" });
    const stop = f.processes[0]!.stop.bind(f.processes[0]);
    let release!: () => void;
    f.processes[0]!.stop = async () => {
      await new Promise<void>((resolve) => {
        release = resolve;
      });
      await stop();
    };
    const closing = f.controller.close();
    await tick();
    expect(f.frames.some((frame) => frame.event.type === "cancelled")).toBe(false);
    release();
    await closing;
    expect(f.frames.map((frame) => frame.event)).toContainEqual({
      type: "text",
      text: "Partial output",
    });
    expect(f.frames.map((frame) => frame.event)).toContainEqual({ type: "cancelled" });
    expect(f.frames.some((frame) => frame.event.type === "failed")).toBe(false);
    expect(readdirSync(f.root).some((name) => name.startsWith("run-"))).toBe(false);
  });

  it("keeps failed shutdown journals and allows Stop and Quit to retry cleanup", async () => {
    const f = fixture();
    await f.configure();
    await f.controller.send(origin, input);
    await tick();
    const stop = f.processes[0]!.stop.bind(f.processes[0]);
    f.processes[0]!.stop = vi
      .fn()
      .mockRejectedValueOnce(new Error("host_stop_unconfirmed"))
      .mockImplementation(stop);
    await expect(f.controller.close()).rejects.toThrow("host_stop_unconfirmed");
    expect(f.controller.hasRuns()).toBe(true);
    expect(f.frames.some((frame) => frame.event.type === "cancelled")).toBe(false);
    expect(readdirSync(f.root).some((name) => name.startsWith("run-"))).toBe(true);
    await f.controller.stop(origin, input);
    expect(f.frames.map((frame) => frame.event)).toContainEqual({ type: "cancelled" });
    await f.controller.close();
    expect(f.frames.map((frame) => frame.event)).toContainEqual({ type: "cancelled" });
    expect(f.controller.hasRuns()).toBe(false);
  });

  it("allows an explicit retry after a grant was rejected before any local launch", async () => {
    const f = fixture();
    await f.configure();
    f.rpc.executions.host.start.mockRejectedValueOnce(new Error("CONFLICT"));
    await expect(f.controller.send(origin, input)).rejects.toThrow("CONFLICT");
    await f.controller.send(origin, input);
    await tick();
    expect(f.adapter.launch).toHaveBeenCalledTimes(1);
    expect(f.dispatches).toHaveLength(1);
  });

  it("does not revoke another bot's pending launch when stopping one bot", async () => {
    const f = fixture();
    await f.configure();
    const original = f.rpc.executions.host.start.getMockImplementation()!;
    let release!: () => void;
    const barrier = new Promise<void>((resolve) => {
      release = resolve;
    });
    f.rpc.executions.host.start.mockImplementation(async (request) => {
      const grant = await original(request);
      await barrier;
      return grant;
    });
    const pending = f.controller.send(origin, input);
    await vi.waitFor(() => expect(f.rpc.executions.host.start).toHaveBeenCalled());
    await f.controller.stop(origin, { ...input, botId: "other-bot" });
    release();
    await pending;
    await tick();
    expect(f.adapter.launch).toHaveBeenCalledTimes(1);
  });

  it("keeps unacknowledged shutdown frames when the final sync fails", async () => {
    const f = fixture();
    await f.configure();
    await f.controller.send(origin, input);
    await tick();
    f.setOffline(true);
    await f.controller.close();
    expect(f.processes[0]!.stopped).toBe(true);
    expect(readdirSync(f.root).some((name) => name.startsWith("run-"))).toBe(true);
    f.setOffline(false);
    const restarted = new DesktopHarness(f.options);
    cleanups.push(() => restarted.close());
    await restarted.profiles(origin, input);
    expect(f.frames.map((frame) => frame.event)).toContainEqual({ type: "cancelled" });
    expect(f.adapter.launch).toHaveBeenCalledTimes(1);
  });

  it("bounds final synchronization even when its transport ignores cancellation", async () => {
    const f = fixture();
    await f.configure();
    await f.controller.send(origin, input);
    await tick();
    f.rpc.executions.host.sync.mockImplementationOnce(() => new Promise(() => {}));
    vi.useFakeTimers();
    try {
      const closing = f.controller.close();
      await vi.advanceTimersByTimeAsync(5000);
      await closing;
      expect(f.processes[0]!.stopped).toBe(true);
      expect(readdirSync(f.root).some((name) => name.startsWith("run-"))).toBe(true);
    } finally {
      vi.useRealTimers();
    }
  });
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
    expect(f.rpc.executions.host.start.mock.calls[0]![0].token).toHaveLength(64);
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
    expect(f.rpc.executions.host.answer).not.toHaveBeenCalled();
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
    expect(f.rpc.executions.host.tool).toHaveBeenCalledWith(
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
