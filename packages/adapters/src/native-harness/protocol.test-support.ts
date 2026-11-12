import type { NativeExecutionScope, NativeExecutionStart } from "@rakazo/adapter-kit";
import type { HarnessProcess } from "./driver.js";

export const scope: NativeExecutionScope = {
  spaceId: "space-a",
  userId: "user-a",
  botId: "bot-a",
  threadId: "thread-a",
  computerId: "computer-a",
  profileId: "profile-a",
  revision: 1,
};

export function startRequest(overrides: Partial<NativeExecutionStart> = {}): NativeExecutionStart {
  return {
    runId: "run-a",
    scope,
    fence: 1,
    leaseExpiresAt: new Date(Date.now() + 60_000).toISOString(),
    prompt: "Create a file",
    instructions: "Use the workspace",
    ...overrides,
  };
}

export class FakeHarnessProcess implements HarnessProcess {
  readonly sent: Record<string, unknown>[] = [];
  stopped = false;
  private line: (line: string) => void = () => {};
  private exit: () => void = () => {};
  permission: Parameters<NonNullable<HarnessProcess["onPermission"]>>[0] | undefined;
  tool: Parameters<NonNullable<HarnessProcess["onTool"]>>[0] | undefined;
  onTool(listener: NonNullable<typeof this.tool>) {
    this.tool = listener;
  }
  reply: (frame: Record<string, unknown>) => void = () => {};

  onLine(listener: (line: string) => void) {
    this.line = listener;
  }
  onExit(listener: () => void) {
    this.exit = listener;
  }
  onPermission(listener: NonNullable<typeof this.permission>) {
    this.permission = listener;
  }
  receive(frame: unknown) {
    this.line(JSON.stringify(frame));
  }
  async write(frame: unknown) {
    const value = frame as Record<string, unknown>;
    this.sent.push(value);
    this.reply(value);
  }
  async stop() {
    if (this.stopped) return;
    this.stopped = true;
    this.exit();
  }
}

export const tick = () => new Promise<void>((resolve) => setImmediate(resolve));
