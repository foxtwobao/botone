import { createHash, randomUUID } from "node:crypto";
import {
  closeSync,
  existsSync,
  fsyncSync,
  mkdirSync,
  openSync,
  readdirSync,
  readFileSync,
  truncateSync,
  writeSync,
} from "node:fs";
import path from "node:path";
import type {
  NativeEngineCapabilities,
  NativeExecutionControl,
  NativeExecutionEvent,
  NativeExecutionFrame,
  NativeExecutionProvider,
  NativeExecutionScope,
  NativeExecutionSnapshot,
  NativeExecutionStart,
} from "@rakazo/adapter-kit";
import { bridgeInputSchemas } from "./bridge-tools.js";
import type { HarnessDriver, HarnessDriverFactory, HarnessProcess } from "./driver.js";
import { HarnessInteractions, permissionActions } from "./interactions.js";

export interface ExecutionProfileAdmission {
  id: string;
  revision: number;
  spaceId: string;
  userIds: string[];
  computerId: string;
  engineVersion: string;
  driver: HarnessDriverFactory;
  launch(request: NativeExecutionStart): Promise<HarnessProcess>;
  readWorkspaceFile?(file: string): Promise<{ name: string; content: string }>;
}

interface Entry {
  runId: string;
  scope: NativeExecutionScope;
  fingerprint: string;
  fence: number;
  generation: string;
  expiresAt: number;
  state: NativeExecutionSnapshot["state"];
  capabilities: NativeEngineCapabilities;
  frames: NativeExecutionFrame[];
  size: number;
  driver?: HarnessDriver;
  process?: HarnessProcess;
  launching?: Promise<HarnessProcess>;
  bridge?: HarnessInteractions;
  tools?: Map<string, { resolve: (result: unknown) => void; result?: string }>;
  timer?: NodeJS.Timeout;
  sessionKey?: string;
  stopping?: Promise<void>;
  steering: Map<string, { text: string; result: Promise<"accepted" | "unsupported"> }>;
}

const sameScope = (a: NativeExecutionScope, b: NativeExecutionScope) =>
  a.spaceId === b.spaceId &&
  a.userId === b.userId &&
  a.botId === b.botId &&
  a.threadId === b.threadId &&
  a.computerId === b.computerId &&
  a.profileId === b.profileId &&
  a.revision === b.revision;

/** Process cache backed by a private journal. A restart makes unfinished work unknown, never runnable. */
export class NativeHarnessExecutionService implements NativeExecutionProvider {
  private readonly entries = new Map<string, Entry>();
  private readonly sessions = new Map<string, string>();
  private readonly sessionScopes = new Map<string, NativeExecutionScope>();

  constructor(
    private readonly root: string,
    private readonly profiles: ExecutionProfileAdmission[],
    private readonly maxEventBytes = 4 * 1024 * 1024,
    private readonly onFrame?: (runId: string, frame: NativeExecutionFrame) => void,
  ) {
    mkdirSync(root, { recursive: true, mode: 0o700 });
    for (const file of readdirSync(root)) {
      if (!/^[a-f0-9]{64}\.jsonl$/.test(file)) continue;
      const contents = readFileSync(path.join(root, file), "utf8");
      const lines = contents.split("\n");
      const header = lines.shift()!;
      const saved = JSON.parse(header) as Omit<Entry, "steering">;
      if (path.basename(this.file(saved.runId)) !== file)
        throw new Error("execution_journal_corrupt");
      let validBytes = Buffer.byteLength(`${header}\n`);
      const frames: NativeExecutionFrame[] = [];
      // A crash during the last append may leave a partial line; earlier frames remain authoritative.
      for (const [index, line] of lines.entries()) {
        if (index === lines.length - 1) break;
        try {
          if (!line && index === lines.length - 1) break;
          const frame = JSON.parse(line) as NativeExecutionFrame;
          if (frame.sequence !== frames.length + 1) throw new Error("invalid_sequence");
          frames.push(frame);
          validBytes += Buffer.byteLength(`${line}\n`);
          if (frame.event.type === "session")
            this.sessionScopes.set(
              this.sessionKey(saved.scope, frame.event.session.id),
              saved.scope,
            );
        } catch {
          if (index !== lines.length - 1) throw new Error("execution_journal_corrupt");
        }
      }
      if (validBytes !== Buffer.byteLength(contents))
        truncateSync(path.join(root, file), validBytes);
      const last = frames.at(-1)?.event.type;
      const entry: Entry = {
        ...saved,
        frames,
        size: frames.reduce(
          (total, frame) => total + Buffer.byteLength(`${JSON.stringify(frame)}\n`),
          0,
        ),
        steering: new Map(),
        state: last === "completed" ? "completed" : last === "cancelled" ? "cancelled" : "failed",
      };
      this.entries.set(entry.runId, entry);
      if (last !== "completed" && last !== "cancelled" && last !== "failed") {
        // Never attach an old approval to a replacement process.
        this.append(entry, { type: "failed", code: "execution_process_lost" });
      }
    }
  }

  private file(runId: string) {
    return path.join(this.root, `${createHash("sha256").update(runId).digest("hex")}.jsonl`);
  }

  private sessionKey(scope: NativeExecutionScope, sessionId: string) {
    return JSON.stringify([scope.profileId, scope.revision, sessionId]);
  }

  private write(file: string, value: string, exclusive = false) {
    const descriptor = openSync(file, exclusive ? "wx" : "a", 0o600);
    try {
      writeSync(descriptor, value);
      fsyncSync(descriptor);
    } finally {
      closeSync(descriptor);
    }
    if (exclusive && process.platform !== "win32") {
      const directory = openSync(this.root, "r");
      try {
        fsyncSync(directory);
      } finally {
        closeSync(directory);
      }
    }
  }

  private profile(scope: NativeExecutionScope) {
    const profile = this.profiles.find((p) => p.id === scope.profileId);
    if (
      !profile ||
      profile.revision !== scope.revision ||
      profile.spaceId !== scope.spaceId ||
      profile.computerId !== scope.computerId ||
      !profile.userIds.includes(scope.userId)
    )
      throw new Error("execution_not_authorized");
    return profile;
  }

  private leaseDate(value: string) {
    const time = Date.parse(value);
    if (!Number.isFinite(time) || time <= Date.now() || time > Date.now() + 5 * 60_000)
      throw new Error("invalid_execution_lease");
    return time;
  }

  private control(request: NativeExecutionControl) {
    const entry = this.entries.get(request.runId);
    if (!entry || !sameScope(entry.scope, request.scope) || entry.generation !== request.generation)
      throw new Error("execution_not_found");
    if (request.fence < entry.fence) throw new Error("execution_fenced");
    if (entry.state === "running" && entry.expiresAt <= Date.now()) {
      void this.stopEntry(entry, "execution_lease_expired");
      throw new Error("execution_lease_expired");
    }
    entry.fence = request.fence;
    return entry;
  }

  /** New dispatches use current admissions; existing entries retain their process and scope. */
  replaceComputerProfiles(computerId: string, profiles: ExecutionProfileAdmission[]) {
    for (let index = this.profiles.length - 1; index >= 0; index--)
      if (this.profiles[index]!.computerId === computerId) this.profiles.splice(index, 1);
    this.profiles.push(...profiles);
  }

  private arm(entry: Entry) {
    clearTimeout(entry.timer);
    entry.timer = setTimeout(
      () => {
        void this.stopEntry(entry, "execution_lease_expired");
      },
      Math.max(1, entry.expiresAt - Date.now()),
    );
    entry.timer.unref();
  }

  private append(entry: Entry, event: NativeExecutionEvent) {
    const frame = { sequence: entry.frames.length + 1, event };
    const line = `${JSON.stringify(frame)}\n`;
    if (entry.size + Buffer.byteLength(line) > this.maxEventBytes && event.type !== "failed") {
      void this.stopEntry(entry, "execution_event_limit");
      return;
    }
    this.write(this.file(entry.runId), line);
    entry.size += Buffer.byteLength(line);
    entry.frames.push(frame);
    this.onFrame?.(entry.runId, frame);
    if (event.type === "completed" || event.type === "failed" || event.type === "cancelled") {
      entry.state = event.type;
      clearTimeout(entry.timer);
      if (entry.sessionKey) this.sessions.delete(entry.sessionKey);
    }
  }

  private stopEntry(entry: Entry, code?: string): Promise<void> {
    if (entry.stopping) return entry.stopping;
    if (
      entry.state !== "running" &&
      ["completed", "failed", "cancelled"].includes(entry.frames.at(-1)?.event.type ?? "")
    )
      return Promise.resolve();
    // Fence controlled operations before awaiting process-tree termination.
    entry.state = "failed";
    entry.bridge?.close();
    for (const tool of entry.tools?.values() ?? []) tool.resolve({ error: "Execution stopped" });
    clearTimeout(entry.timer);
    entry.stopping = (async () => {
      await entry.launching?.then(
        (process) => {
          entry.process = process;
        },
        () => undefined,
      );
      await entry.driver?.cancel().catch(() => undefined);
      await entry.process?.stop();
      this.append(entry, code ? { type: "failed", code } : { type: "cancelled" });
    })().catch((error) => {
      entry.stopping = undefined;
      throw error;
    });
    // Observe background cleanup failures without claiming the process stopped.
    void entry.stopping.catch(() => {});
    return entry.stopping;
  }

  private snapshot(entry: Entry, after = 0): NativeExecutionSnapshot {
    if (!Number.isSafeInteger(after) || after < 0 || after > entry.frames.length)
      throw new Error("execution_event_gap");
    const frames = entry.frames.slice(after, after + 128);
    return {
      generation: entry.generation,
      state: entry.state,
      capabilities: entry.capabilities,
      frames,
      nextSequence: frames.at(-1)?.sequence ?? after,
    };
  }

  /** Read a journal after restart without authorizing a replacement process or prompt. */
  recover(runId: string, scope: NativeExecutionScope): NativeExecutionSnapshot | null {
    const entry = this.entries.get(runId);
    return entry && sameScope(entry.scope, scope) ? this.snapshot(entry) : null;
  }

  async start(request: NativeExecutionStart) {
    const profile = this.profile(request.scope);
    const expiresAt = this.leaseDate(request.leaseExpiresAt);
    const fingerprint = createHash("sha256")
      .update(JSON.stringify({ ...request, fence: 0, leaseExpiresAt: "" }))
      .digest("hex");
    const existing = this.entries.get(request.runId);
    if (existing) {
      if (!sameScope(existing.scope, request.scope) || existing.fingerprint !== fingerprint)
        throw new Error("execution_conflict");
      if (request.fence < existing.fence) throw new Error("execution_fenced");
      return this.snapshot(existing);
    }
    const sessionKey = request.session
      ? this.sessionKey(request.scope, request.session.id)
      : undefined;
    if (
      sessionKey &&
      !sameScope(this.sessionScopes.get(sessionKey) ?? ({} as NativeExecutionScope), request.scope)
    )
      throw new Error("execution_session_not_authorized");
    if (sessionKey && this.sessions.has(sessionKey)) throw new Error("execution_session_busy");
    if (request.session && request.session.engineVersion !== profile.engineVersion)
      throw new Error("execution_session_incompatible");
    const entry: Entry = {
      runId: request.runId,
      scope: request.scope,
      fingerprint,
      fence: request.fence,
      generation: randomUUID(),
      expiresAt,
      state: "running",
      frames: [],
      size: 0,
      capabilities: {
        images: false,
        resume: false,
        steer: false,
        permissions: false,
        questions: false,
        tools: false,
      },
      steering: new Map(),
      sessionKey,
    };
    // Exclusive durable intent precedes every fallible launch. No result permits prompt replay.
    if (existsSync(this.file(request.runId))) throw new Error("execution_result_unknown");
    this.write(
      this.file(request.runId),
      `${JSON.stringify({ ...entry, steering: undefined })}\n`,
      true,
    );
    this.entries.set(request.runId, entry);
    if (sessionKey) this.sessions.set(sessionKey, request.runId);
    this.arm(entry);
    entry.launching = Promise.resolve().then(() => {
      if (entry.state !== "running") throw new Error("execution_stopped");
      return profile.launch(request);
    });
    // Different runs launch immediately; there is no global process slot or work queue.
    void (async () => {
      try {
        entry.process = await entry.launching!;
        if (entry.state !== "running") {
          await entry.process.stop();
          return;
        }
        entry.tools = new Map();
        entry.bridge = new HarnessInteractions((event) => {
          if (entry.state === "running") this.append(entry, event);
        });
        entry.process.onTool?.(
          (call) =>
            new Promise((resolve) => {
              if (entry.state !== "running") return resolve({ error: "Execution stopped" });
              const id = randomUUID();
              const invoke = () => {
                entry.tools!.set(id, { resolve });
                this.append(entry, { type: "tool_requested", id, ...call });
              };
              if (call.name === "recall_memory") invoke();
              else if (
                call.name === "message_bot" ||
                (call.name === "publish_file" && profile.readWorkspaceFile)
              )
                entry.bridge!.open(
                  {
                    kind: "permission",
                    title: call.name === "publish_file" ? "Attach file?" : "Send message?",
                    detail: JSON.stringify(call.input),
                    actions: permissionActions,
                  },
                  async (answer) => {
                    if (answer === "allow" && call.name === "publish_file") {
                      const input = bridgeInputSchemas.publish_file.safeParse(call.input);
                      if (!input.success) return resolve({ error: "Invalid file path" });
                      try {
                        const file = await profile.readWorkspaceFile!(input.data.path);
                        if (entry.state !== "running")
                          return resolve({ error: "Execution stopped" });
                        this.append(entry, { type: "file", ...file });
                        resolve({ submitted: file.name });
                      } catch {
                        resolve({ error: "File unavailable or exceeds the attachment limit" });
                      }
                    } else if (answer === "allow") invoke();
                    else resolve({ error: "Permission denied" });
                  },
                );
              else resolve({ error: "Tool unavailable" });
            }),
        );
        entry.driver = profile.driver(entry.process, profile.engineVersion, (event) => {
          if (entry.state !== "running") return;
          if (event.type === "session") {
            const key = this.sessionKey(entry.scope, event.session.id);
            const bound = this.sessionScopes.get(key);
            if (bound && !sameScope(bound, entry.scope)) {
              void this.stopEntry(entry, "execution_session_not_authorized");
              return;
            }
            this.sessionScopes.set(key, entry.scope);
            entry.sessionKey = key;
            this.sessions.set(key, entry.runId);
          }
          if (event.type === "completed" || event.type === "failed" || event.type === "cancelled") {
            entry.state = "failed";
            entry.stopping = (async () => {
              await entry.process?.stop();
              this.append(entry, event);
            })().catch((error) => {
              entry.stopping = undefined;
              throw error;
            });
            void entry.stopping.catch(() => {});
          } else this.append(entry, event);
        });
        entry.capabilities = entry.driver.capabilities;
        entry.capabilities.tools = Boolean(entry.process.onTool || entry.process.externalTools);
        await entry.driver.start(request);
      } catch {
        if (entry.state === "running") await this.stopEntry(entry, "execution_start_failed");
      } finally {
        // A live native session stays reserved through completion, not only through startup.
        if (sessionKey && entry.state !== "running") this.sessions.delete(sessionKey);
      }
    })().catch(() => {
      // Cleanup remains unconfirmed; explicit stop/close callers retain its rejection.
    });
    return this.snapshot(entry);
  }

  async attach(request: NativeExecutionControl & { after: number; leaseExpiresAt: string }) {
    const entry = this.control(request);
    if (entry.state === "running") {
      entry.expiresAt = this.leaseDate(request.leaseExpiresAt);
      this.arm(entry);
    }
    return this.snapshot(entry, request.after);
  }

  async respond(request: NativeExecutionControl & { requestId: string; answer: string }) {
    const entry = this.control(request);
    if (entry.state !== "running") return "expired";
    return (await entry.bridge?.respond(request.requestId, request.answer)) ||
      (await entry.driver?.respond(request.requestId, request.answer))
      ? "delivered"
      : "expired";
  }

  async toolResult(request: NativeExecutionControl & { requestId: string; result: string }) {
    const entry = this.control(request);
    const tool = entry.tools?.get(request.requestId);
    if (!tool || (tool.result !== undefined && tool.result !== request.result))
      return "expired" as const;
    if (tool.result === undefined) {
      if (entry.state !== "running") return "expired" as const;
      tool.result = request.result;
      tool.resolve(JSON.parse(request.result));
    }
    return "delivered" as const;
  }

  async cancel(request: NativeExecutionControl) {
    await this.stopEntry(this.control(request));
  }

  /** A durable cancellation intent also fences a start whose HTTP response was lost. */
  async stop(request: { runId: string; scope: NativeExecutionScope; fence: number }) {
    const existing = this.entries.get(request.runId);
    if (existing) {
      await this.stopEntry(this.control({ ...request, generation: existing.generation }));
      return;
    }
    // The transport authorizes owner scope. Cancelling undispatched work needs no ready engine.
    const entry: Entry = {
      ...request,
      fingerprint: "cancelled-before-start",
      generation: randomUUID(),
      expiresAt: 0,
      state: "cancelled",
      capabilities: {
        images: false,
        resume: false,
        steer: false,
        permissions: false,
        questions: false,
        tools: false,
      },
      frames: [],
      size: 0,
      steering: new Map(),
    };
    this.write(
      this.file(request.runId),
      `${JSON.stringify({ ...entry, steering: undefined })}\n`,
      true,
    );
    this.entries.set(entry.runId, entry);
    this.append(entry, { type: "cancelled" });
  }

  async steer(request: NativeExecutionControl & { id: string; text: string }) {
    const entry = this.control(request);
    if (entry.state !== "running") return "unsupported";
    const previous = entry.steering.get(request.id);
    if (previous) {
      if (previous.text !== request.text) throw new Error("execution_conflict");
      return previous.result;
    }
    // Retain rejected/unknown results too. A timeout never authorizes a second steer.
    const result: Promise<"accepted" | "unsupported"> = Promise.resolve().then(async () =>
      (await entry.driver?.steer(request.text)) ? "accepted" : "unsupported",
    );
    entry.steering.set(request.id, { text: request.text, result });
    return result;
  }

  async close(options: { cancelled?: boolean } = {}) {
    await Promise.all(
      [...this.entries.values()].map((entry) =>
        this.stopEntry(entry, options.cancelled ? undefined : "execution_service_stopped"),
      ),
    );
  }
}
