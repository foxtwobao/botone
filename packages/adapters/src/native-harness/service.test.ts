import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import type { NativeExecutionControl, NativeExecutionEvent } from "@rakazo/adapter-kit";
import { afterEach, describe, expect, it } from "vitest";
import type { HarnessDriverFactory } from "./driver.js";
import { FakeHarnessProcess, scope, startRequest, tick } from "./protocol.test-support.js";
import { NativeHarnessExecutionService } from "./service.js";

const cleanup: Array<() => void | Promise<void>> = [];
it("records stop before dispatch and never launches the stopped run", async () => {
  const { service, processes } = fixture();
  await service.stop({ runId: "run-a", scope, fence: 1 });
  await expect(service.start(startRequest())).rejects.toThrow("execution_conflict");
  expect(processes).toHaveLength(0);
});

it("requires a fresh approval before a bridged message and correlates the tool result", async () => {
  const { service, processes } = fixture();
  const started = await service.start(startRequest());
  await tick();
  const control = { runId: "run-a", scope, fence: 1, generation: started.generation };
  const result = processes[0]!.tool!({ name: "message_bot", input: { message: "Test message" } });
  const waiting = await service.attach({
    ...control,
    after: 0,
    leaseExpiresAt: startRequest().leaseExpiresAt,
  });
  expect(waiting.frames.some((frame) => frame.event.type === "tool_requested")).toBe(false);
  const permission = waiting.frames.find((frame) => frame.event.type === "interaction")!.event;
  if (permission.type !== "interaction") throw new Error("Missing permission");
  await service.respond({ ...control, requestId: permission.request.id, answer: "allow" });
  const approved = await service.attach({
    ...control,
    after: 0,
    leaseExpiresAt: startRequest().leaseExpiresAt,
  });
  const tool = approved.frames.find((frame) => frame.event.type === "tool_requested")!.event;
  if (tool.type !== "tool_requested") throw new Error("Missing tool");
  await expect(
    service.toolResult({ ...control, requestId: "unrelated", result: "{}" }),
  ).resolves.toBe("expired");
  await expect(
    service.toolResult({ ...control, requestId: tool.id, result: '{"ok":true}' }),
  ).resolves.toBe("delivered");
  await expect(result).resolves.toEqual({ ok: true });
  await expect(
    service.toolResult({ ...control, requestId: tool.id, result: '{"ok":true}' }),
  ).resolves.toBe("delivered");
  await expect(
    service.toolResult({ ...control, requestId: tool.id, result: '{"ok":false}' }),
  ).resolves.toBe("expired");
});
afterEach(async () => {
  for (const fn of cleanup.splice(0).reverse()) await fn();
});

function fixture(options: { limit?: number; launch?: () => Promise<FakeHarnessProcess> } = {}) {
  const root = mkdtempSync(path.join(tmpdir(), "native-runtime-test-"));
  cleanup.push(() => rmSync(root, { recursive: true, force: true }));
  const processes: FakeHarnessProcess[] = [];
  const events = new Map<string, (event: NativeExecutionEvent) => void>();
  let starts = 0;
  let responses = 0;
  const driver: HarnessDriverFactory = (_process, _version, emit) => ({
    capabilities: {
      resume: true,
      steer: true,
      permissions: true,
      questions: true,
      images: false,
      tools: false,
    },
    async start(request) {
      starts++;
      events.set(request.runId, emit);
    },
    async respond() {
      responses++;
      return true;
    },
    async cancel() {},
    async steer() {
      return true;
    },
  });
  const profiles = [
    {
      id: scope.profileId,
      revision: 1,
      spaceId: scope.spaceId,
      userIds: [scope.userId],
      computerId: scope.computerId,
      engineVersion: "test",
      driver,
      launch:
        options.launch ??
        (async () => {
          const process = new FakeHarnessProcess();
          processes.push(process);
          return process;
        }),
    },
  ];
  const service = new NativeHarnessExecutionService(root, profiles, options.limit);
  cleanup.push(() => service.close());
  const control = (generation: string): NativeExecutionControl => ({
    runId: "run-a",
    scope,
    generation,
    fence: 1,
  });
  return {
    service,
    root,
    profiles,
    processes,
    events,
    control,
    get starts() {
      return starts;
    },
    get responses() {
      return responses;
    },
  };
}

describe("native execution lifecycle", () => {
  it("deduplicates dispatch and rejects a changed prompt or cross-user attach", async () => {
    const f = fixture();
    const request = startRequest();
    const result = await f.service.start(request);
    await tick();
    expect((await f.service.start(request)).generation).toBe(result.generation);
    expect(f.starts).toBe(1);
    await expect(f.service.start({ ...request, prompt: "Different task" })).rejects.toThrow(
      "execution_conflict",
    );
    await expect(
      f.service.attach({
        ...f.control(result.generation),
        scope: { ...scope, userId: "user-b" },
        after: 0,
        leaseExpiresAt: request.leaseExpiresAt,
      }),
    ).rejects.toThrow("execution_not_authorized");
  });

  it("takes over the same execution with a new fence and refuses old approvals", async () => {
    const f = fixture();
    const request = startRequest();
    const result = await f.service.start(request);
    await tick();
    f.events.get("run-a")!({ type: "text", text: "part" });
    const attached = await f.service.attach({
      ...f.control(result.generation),
      fence: 2,
      after: 0,
      leaseExpiresAt: request.leaseExpiresAt,
    });
    expect(attached.frames).toEqual([{ sequence: 1, event: { type: "text", text: "part" } }]);
    await expect(
      f.service.respond({
        ...f.control(result.generation),
        requestId: "approval",
        answer: "allow",
      }),
    ).rejects.toThrow("execution_fenced");
    expect(f.responses).toBe(0);
    expect(f.starts).toBe(1);
    await expect(
      f.service.attach({
        ...f.control(result.generation),
        fence: 2,
        after: 2,
        leaseExpiresAt: request.leaseExpiresAt,
      }),
    ).rejects.toThrow("execution_event_gap");
  });

  it("never reruns a dispatched prompt after service restart", async () => {
    const f = fixture();
    const request = startRequest();
    await f.service.start(request);
    await tick();
    const restarted = new NativeHarnessExecutionService(f.root, f.profiles);
    cleanup.push(() => restarted.close());
    const result = await restarted.start(request);
    expect(result.state).toBe("failed");
    expect(result.frames.at(-1)?.event).toEqual({ type: "failed", code: "execution_process_lost" });
    expect(f.starts).toBe(1);
  });

  it("launches unrelated tasks while another launch is waiting", async () => {
    let release: (process: FakeHarnessProcess) => void = () => {};
    let launches = 0;
    const f = fixture({
      launch: async () => {
        launches++;
        if (launches === 1)
          return new Promise((resolve) => {
            release = resolve;
          });
        return new FakeHarnessProcess();
      },
    });
    await f.service.start(startRequest());
    await f.service.start(startRequest({ runId: "run-b", scope: { ...scope, botId: "bot-b" } }));
    await tick();
    expect(f.starts).toBe(1);
    expect(f.events.has("run-b")).toBe(true);
    release(new FakeHarnessProcess());
    await tick();
    expect(f.starts).toBe(2);
  });

  it("confirms process termination before returning cancellation", async () => {
    const f = fixture();
    const result = await f.service.start(startRequest());
    await tick();
    await f.service.cancel(f.control(result.generation));
    expect(f.processes[0]?.stopped).toBe(true);
    await expect(
      f.service.respond({
        ...f.control(result.generation),
        requestId: "approval",
        answer: "allow",
      }),
    ).resolves.toBe("expired");
  });

  it("stops on event overflow instead of returning a complete-looking truncated history", async () => {
    const f = fixture({ limit: 100 });
    const request = startRequest();
    const result = await f.service.start(request);
    await tick();
    f.events.get("run-a")!({ type: "text", text: "x".repeat(200) });
    await tick();
    const snapshot = await f.service.attach({
      ...f.control(result.generation),
      after: 0,
      leaseExpiresAt: request.leaseExpiresAt,
    });
    expect(snapshot.state).toBe("failed");
    expect(snapshot.frames.at(-1)?.event).toEqual({
      type: "failed",
      code: "execution_event_limit",
    });
    expect(f.processes[0]?.stopped).toBe(true);
  });
});
