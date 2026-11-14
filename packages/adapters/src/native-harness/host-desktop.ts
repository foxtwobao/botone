import { createHash, createHmac, randomBytes, randomUUID } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { realpath } from "node:fs/promises";
import path from "node:path";
import { createORPCClient } from "@orpc/client";
import { RPCLink } from "@orpc/client/fetch";
import type { ContractRouterClient } from "@orpc/contract";
import type { NativeExecutionControl, NativeExecutionScope } from "@rakazo/adapter-kit";
import type {
  AppContract,
  DesktopHostBridge,
  DesktopHostSelection,
  HostFrame,
} from "@rakazo/contracts";
import { HostComputerCallSchema, hostComputerTools } from "@rakazo/contracts";
import { NativeHarnessExecutionService } from "@rakazo/native-runtime/service";
import { z } from "zod";
import type { HostHarnessAdapter } from "./host-adapter.js";
import { inspectHostHarness } from "./host-adapter.js";

type Client = ContractRouterClient<AppContract>;
const key = (value: unknown) => createHash("sha256").update(JSON.stringify(value)).digest("hex");
const selectionSchema = z.object({
  profileId: z.string(),
  workspace: z.string(),
  target: z.enum(["workspace", "computer"]),
  model: z.string().optional(),
});
const stateSchema = z.object({
  installationId: z.string(),
  seed: z.string(),
  selections: z.record(z.string(), selectionSchema),
});
const metaSchema = z.object({
  origin: z.string().url(),
  userId: z.string(),
  spaceId: z.string(),
  botId: z.string(),
  runId: z.string(),
  taskId: z.string(),
  threadId: z.string(),
  clientNonce: z.string(),
  version: z.string(),
  identity: z.string(),
  selection: selectionSchema,
  cursor: z.number().int(),
  after: z.number().int(),
  leaseExpiresAt: z.string(),
});
type Metadata = z.infer<typeof metaSchema>;
interface Intent {
  origin: string;
  spaceId: string;
  botId: string;
  abort: AbortController;
}
interface Active {
  meta: Metadata;
  rpc: Client;
  service: NativeHarnessExecutionService;
  control: NativeExecutionControl;
  token: string;
  abort: AbortController;
  heartbeat?: NodeJS.Timeout;
  retry?: NodeJS.Timeout;
  pumping?: Promise<void>;
  dirty: boolean;
  finished: boolean;
}
export interface DesktopHarnessOptions {
  root: string;
  currentOrigin(): string | null;
  fetch: typeof fetch;
  chooseDirectory(): Promise<string | null>;
  confirm(input: {
    origin: string;
    workspace: string;
    target: "workspace" | "computer";
  }): Promise<boolean>;
  inspect?: () => Promise<HostHarnessAdapter>;
  client?: (origin: string, spaceId: string) => Client;
}

/** Private main-process state. The renderer never receives a run grant, CLI path or account. */
export class DesktopHarness {
  private readonly state: z.infer<typeof stateSchema>;
  private readonly services = new Map<string, NativeHarnessExecutionService>();
  private readonly runs = new Map<string, Active>();
  private readonly restoring = new Set<string>();
  private readonly pending = new Set<Intent>();
  private readonly launching = new Map<string, Intent>();
  private readonly dispatches = new Map<string, ReturnType<DesktopHarness["dispatch"]>>();
  private closing = false;
  private closed = false;
  private shutdown?: Promise<void>;
  constructor(private readonly options: DesktopHarnessOptions) {
    mkdirSync(options.root, { recursive: true, mode: 0o700 });
    const file = path.join(options.root, "settings.json");
    this.state = existsSync(file)
      ? stateSchema.parse(JSON.parse(readFileSync(file, "utf8")))
      : { installationId: randomUUID(), seed: randomBytes(32).toString("hex"), selections: {} };
    this.saveState();
  }
  private write(file: string, data: unknown) {
    writeFileSync(`${file}.tmp`, JSON.stringify(data), { mode: 0o600 });
    chmodSync(`${file}.tmp`, 0o600);
    renameSync(`${file}.tmp`, file);
  }
  private saveState() {
    this.write(path.join(this.options.root, "settings.json"), this.state);
  }
  private metaFile(runId: string) {
    return path.join(this.options.root, `run-${key(runId)}.json`);
  }
  private saveRun(run: Active) {
    this.write(this.metaFile(run.meta.runId), run.meta);
  }
  private client(origin: string, spaceId: string): Client {
    if (this.options.client) return this.options.client(origin, spaceId);
    return createORPCClient(
      new RPCLink({
        url: `${origin}/rpc`,
        fetch: async (input, init) => {
          if (this.options.currentOrigin() !== origin || this.closed)
            throw new Error("Local execution disconnected");
          const request = new Request(input, init);
          const headers = new Headers(request.headers);
          headers.set("x-rakazo-space-id", spaceId);
          headers.set("origin", origin);
          // Re-authenticate through the window's server session on every call and stream.
          return this.options.fetch(new Request(request, { headers, credentials: "include" }));
        },
      }),
    );
  }
  private async owner(origin: string, spaceId: string, cleanup = false) {
    if (origin !== this.options.currentOrigin() || (this.closing && !cleanup) || this.closed)
      throw new Error("Local agent unavailable");
    const rpc = this.client(origin, spaceId);
    const me = await rpc.me();
    if (me.spaceId !== spaceId) throw new Error("Space unavailable");
    return { rpc, userId: me.userId, spaceId };
  }
  private intent(origin: string, input: { spaceId: string; botId: string }) {
    const intent = {
      origin,
      spaceId: input.spaceId,
      botId: input.botId,
      abort: new AbortController(),
    };
    this.assertIntent(intent);
    this.pending.add(intent);
    return intent;
  }
  private assertIntent(intent: Intent) {
    if (
      intent.abort.signal.aborted ||
      this.closing ||
      this.options.currentOrigin() !== intent.origin
    )
      throw new Error("Local execution disconnected");
  }
  private revoke(origin?: string, input?: { spaceId: string; botId: string }) {
    for (const intent of this.pending)
      if (
        !input ||
        (intent.origin === origin &&
          intent.spaceId === input.spaceId &&
          intent.botId === input.botId)
      )
        intent.abort.abort();
  }
  private selectionKey(origin: string, userId: string, spaceId: string, botId: string) {
    return key([origin, userId, spaceId, botId]);
  }
  private profileId(selection: DesktopHostSelection, identity: string) {
    return key([
      selection.profileId,
      selection.workspace,
      selection.target,
      selection.model ?? null,
      identity,
    ]);
  }
  private scope(meta: Metadata): NativeExecutionScope {
    return {
      spaceId: meta.spaceId,
      userId: meta.userId,
      botId: meta.botId,
      threadId: meta.threadId,
      computerId: this.state.installationId,
      profileId: this.profileId(meta.selection, meta.identity),
      revision: 1,
    };
  }
  private proof(meta: Pick<Metadata, "origin" | "userId" | "spaceId" | "botId" | "clientNonce">) {
    return createHmac("sha256", this.state.seed)
      .update(
        JSON.stringify([meta.origin, meta.userId, meta.spaceId, meta.botId, meta.clientNonce]),
      )
      .digest("hex");
  }
  private service(meta: Metadata, adapter: HostHarnessAdapter) {
    const id = key([
      meta.origin,
      meta.userId,
      meta.spaceId,
      this.profileId(meta.selection, meta.identity),
      meta.version,
    ]);
    let service = this.services.get(id);
    if (!service) {
      service = new NativeHarnessExecutionService(
        path.join(this.options.root, "journals", id),
        [
          {
            id: this.profileId(meta.selection, meta.identity),
            revision: 1,
            spaceId: meta.spaceId,
            userIds: [meta.userId],
            computerId: this.state.installationId,
            engineVersion: meta.version,
            driver: adapter.driver,
            launch: (request) => {
              const intent = this.launching.get(request.runId);
              if (!intent) throw new Error("Local execution disconnected");
              this.assertIntent(intent);
              return adapter.launch(
                meta.selection.workspace,
                meta.selection.target === "computer"
                  ? {
                      specs: hostComputerTools,
                      invoke: async (id, name, input) => {
                        const run = this.runs.get(request.runId);
                        if (!run || run.finished || run.abort.signal.aborted)
                          throw new Error("Local execution stopped");
                        const call = HostComputerCallSchema.parse({ name, input });
                        return (
                          await run.rpc.hostExecutions.tool(
                            { runId: run.meta.runId, token: run.token, id, call },
                            {
                              signal: AbortSignal.any([
                                run.abort.signal,
                                AbortSignal.timeout(60_000),
                              ]),
                            },
                          )
                        ).result;
                      },
                    }
                  : undefined,
              );
            },
          },
        ],
        undefined,
        (runId) => {
          const run = this.runs.get(runId);
          if (run) {
            run.dirty = true;
            queueMicrotask(() => void this.pump(run));
          }
        },
      );
      this.services.set(id, service);
    }
    return service;
  }
  private async restore(origin: string, userId: string, spaceId: string) {
    const scopeKey = key([origin, userId, spaceId]);
    if (this.restoring.has(scopeKey)) return;
    this.restoring.add(scopeKey);
    try {
      for (const file of readdirSync(this.options.root)) {
        if (!/^run-[a-f0-9]{64}\.json$/.test(file)) continue;
        const meta = metaSchema.parse(
          JSON.parse(readFileSync(path.join(this.options.root, file), "utf8")),
        );
        if (
          meta.origin !== origin ||
          meta.userId !== userId ||
          meta.spaceId !== spaceId ||
          this.runs.has(meta.runId)
        )
          continue;
        // Restore only journals. Inspection does not grant permission for another launch.
        const adapter = await (this.options.inspect ?? inspectHostHarness)();
        const service = this.service(meta, adapter);
        const snapshot = service.recover(meta.runId, this.scope(meta));
        if (!snapshot) {
          rmSync(path.join(this.options.root, file));
          continue;
        }
        const run = this.entry(meta, service, snapshot.generation);
        this.runs.set(meta.runId, run);
        await this.pump(run);
      }
    } finally {
      this.restoring.delete(scopeKey);
    }
  }
  private entry(
    meta: Metadata,
    service: NativeHarnessExecutionService,
    generation: string,
  ): Active {
    return {
      meta,
      service,
      rpc: this.client(meta.origin, meta.spaceId),
      control: { runId: meta.runId, scope: this.scope(meta), generation, fence: 1 },
      token: this.proof(meta),
      abort: new AbortController(),
      dirty: true,
      finished: false,
    };
  }
  async profiles(origin: string, input: { spaceId: string }) {
    const { userId } = await this.owner(origin, input.spaceId);
    await this.restore(origin, userId, input.spaceId);
    return [(await (this.options.inspect ?? inspectHostHarness)()).profile];
  }
  async selection(origin: string, input: { spaceId: string; botId: string }) {
    const { userId } = await this.owner(origin, input.spaceId);
    await this.restore(origin, userId, input.spaceId);
    return (
      this.state.selections[this.selectionKey(origin, userId, input.spaceId, input.botId)] ?? null
    );
  }
  async configure(
    origin: string,
    input: {
      botId: string;
      spaceId: string;
      profileId: string | null;
      target?: "workspace" | "computer";
    },
  ) {
    this.revoke(origin, input);
    const intent = this.intent(origin, input);
    try {
      const { rpc, userId } = await this.owner(origin, input.spaceId);
      await rpc.bots.get({ botId: input.botId });
      this.assertIntent(intent);
      const id = this.selectionKey(origin, userId, input.spaceId, input.botId);
      if (
        [...this.runs.values()].some(
          (run) =>
            !run.finished &&
            run.meta.origin === origin &&
            run.meta.spaceId === input.spaceId &&
            run.meta.botId === input.botId,
        )
      )
        throw new Error("Stop the current local task before changing its agent");
      if (input.profileId === null) {
        delete this.state.selections[id];
        this.saveState();
        return null;
      }
      const adapter = await (this.options.inspect ?? inspectHostHarness)();
      this.assertIntent(intent);
      if (adapter.profile.id !== input.profileId || adapter.profile.status !== "ready")
        throw new Error("Local agent unavailable");
      const target = input.target ?? this.state.selections[id]?.target ?? "workspace";
      const scratch = path.join(this.options.root, "scratch", id);
      if (target === "computer") mkdirSync(scratch, { recursive: true, mode: 0o700 });
      const picked = target === "computer" ? scratch : await this.options.chooseDirectory();
      this.assertIntent(intent);
      if (!picked) return this.state.selections[id] ?? null;
      const workspace = await realpath(picked);
      if (!(await this.options.confirm({ origin, workspace, target })))
        return this.state.selections[id] ?? null;
      if ((await this.owner(origin, input.spaceId)).userId !== userId)
        throw new Error("Local execution scope changed");
      this.assertIntent(intent);
      if (
        [...this.runs.values()].some(
          (run) =>
            !run.finished &&
            run.meta.origin === origin &&
            run.meta.spaceId === input.spaceId &&
            run.meta.botId === input.botId,
        )
      )
        throw new Error("Stop the current local task before changing its agent");
      const selection = { profileId: input.profileId, workspace, target };
      this.state.selections[id] = selection;
      this.saveState();
      return selection;
    } finally {
      this.pending.delete(intent);
    }
  }
  async send(
    origin: string,
    input: { botId: string; spaceId: string; text: string; clientNonce: string },
  ) {
    const intent = this.intent(origin, input);
    try {
      const { rpc, userId } = await this.owner(origin, input.spaceId);
      this.assertIntent(intent);
      const id = key([origin, userId, input.spaceId, input.botId, input.clientNonce]);
      const previous = this.dispatches.get(id);
      if (previous) return await previous;
      const dispatch = this.dispatch(intent, rpc, userId, input).finally(() =>
        this.dispatches.delete(id),
      );
      this.dispatches.set(id, dispatch);
      return await dispatch;
    } finally {
      this.pending.delete(intent);
    }
  }
  private async dispatch(
    intent: Intent,
    rpc: Client,
    userId: string,
    input: { botId: string; spaceId: string; text: string; clientNonce: string },
  ) {
    const { origin } = intent;
    const selection =
      this.state.selections[this.selectionKey(origin, userId, input.spaceId, input.botId)];
    if (!selection) throw new Error("Choose a local workspace first");
    const adapter = await (this.options.inspect ?? inspectHostHarness)();
    this.assertIntent(intent);
    if (
      this.state.selections[this.selectionKey(origin, userId, input.spaceId, input.botId)] !==
      selection
    )
      throw new Error("Local execution scope changed");
    if (
      adapter.profile.status !== "ready" ||
      adapter.profile.id !== selection.profileId ||
      !adapter.version ||
      !adapter.identity
    )
      throw new Error("Local agent unavailable");
    const grant = await rpc.hostExecutions.start(
      {
        botId: input.botId,
        text: input.text,
        clientNonce: input.clientNonce,
        token: this.proof({ ...input, origin, userId }),
        installationId: this.state.installationId,
        profileId: this.profileId(selection, adapter.identity),
        revision: 1,
        engineVersion: adapter.version,
        target: selection.target,
        ...(selection.model ? { model: selection.model } : {}),
      },
      { signal: AbortSignal.any([intent.abort.signal, AbortSignal.timeout(20_000)]) },
    );
    if (grant.userId !== userId || grant.spaceId !== input.spaceId)
      throw new Error("Local execution scope changed");
    if (grant.stopped || this.runs.has(grant.runId))
      return { runId: grant.runId, taskId: grant.taskId, seq: grant.seq };
    const meta: Metadata = {
      botId: input.botId,
      spaceId: input.spaceId,
      clientNonce: input.clientNonce,
      origin,
      userId,
      runId: grant.runId,
      taskId: grant.taskId,
      threadId: grant.threadId,
      version: adapter.version,
      identity: adapter.identity,
      selection,
      cursor: grant.cursor,
      after: 0,
      leaseExpiresAt: grant.leaseExpiresAt,
    };
    const service = this.service(meta, adapter);
    // Persist dispatch identity before the journal starts. Recovery never dispatches it again.
    this.write(this.metaFile(meta.runId), meta);
    try {
      this.assertIntent(intent);
      if ((await this.owner(origin, input.spaceId)).userId !== userId)
        throw new Error("Local execution scope changed");
      this.assertIntent(intent);
      if (
        this.state.selections[this.selectionKey(origin, userId, input.spaceId, input.botId)] !==
        selection
      )
        throw new Error("Local execution scope changed");
    } catch (error) {
      await service.stop({ runId: grant.runId, scope: this.scope(meta), fence: 1 });
      const snapshot = service.recover(meta.runId, this.scope(meta))!;
      const run = this.entry(meta, service, snapshot.generation);
      this.runs.set(meta.runId, run);
      if (!this.closing) await this.pump(run);
      throw error;
    }
    this.launching.set(grant.runId, intent);
    const snapshot = await service
      .start({
        runId: grant.runId,
        scope: this.scope(meta),
        fence: 1,
        leaseExpiresAt: grant.leaseExpiresAt,
        instructions: grant.instructions,
        prompt: input.text,
        context: grant.context,
        session: grant.session,
        ...(selection.model ? { model: selection.model } : {}),
      })
      .finally(() => this.launching.delete(grant.runId));
    if (this.runs.has(meta.runId))
      return { runId: grant.runId, taskId: grant.taskId, seq: grant.seq };
    const run = this.entry(meta, service, snapshot.generation);
    this.runs.set(meta.runId, run);
    run.heartbeat = setInterval(() => {
      run.dirty = true;
      void this.pump(run);
    }, 30_000);
    run.heartbeat.unref();
    void this.listen(run);
    void this.pump(run);
    return { runId: grant.runId, taskId: grant.taskId, seq: grant.seq };
  }
  private async listen(run: Active) {
    try {
      const stream = await run.rpc.threads.subscribe(
        { botId: run.meta.botId, cursor: run.meta.cursor },
        { signal: run.abort.signal },
      );
      for await (const event of stream) {
        if (run.finished) break;
        run.meta.cursor = event.seq;
        if (
          event.runId === run.meta.runId &&
          ["run.cancelled", "run.failed", "run.completed"].includes(event.type)
        ) {
          await run.service.cancel(run.control);
          run.dirty = true;
          await this.pump(run);
        } else if (event.type === "thread.message.updated") {
          run.dirty = true;
          await this.pump(run);
        }
      }
      if (!run.finished) throw new Error("Execution stream ended");
    } catch (error) {
      if (!run.finished && !this.closing) await this.disconnected(run, error);
    }
  }
  private async pump(run: Active, shutdown?: AbortSignal): Promise<void> {
    if (run.pumping || run.finished || (this.closing && !shutdown)) return run.pumping;
    run.pumping = (async () => {
      while (run.dirty && !run.finished && (!this.closing || shutdown) && !shutdown?.aborted) {
        run.dirty = false;
        const snapshot = run.service.recover(run.meta.runId, run.control.scope);
        if (!snapshot) throw new Error("Local execution journal unavailable");
        const frames = snapshot.frames.filter((frame) => frame.sequence > run.meta.after);
        // recover returns the first page; attach reads the next durable page.
        const page = await run.service.attach({
          ...run.control,
          after: run.meta.after,
          leaseExpiresAt: run.meta.leaseExpiresAt,
        });
        const result = await run.rpc.hostExecutions.sync(
          { runId: run.meta.runId, token: run.token, frames: page.frames as HostFrame[] },
          {
            signal: AbortSignal.any([AbortSignal.timeout(15_000), ...(shutdown ? [shutdown] : [])]),
          },
        );
        shutdown?.throwIfAborted();
        if (result.after < run.meta.after || result.after > page.nextSequence)
          throw new Error("Execution acknowledgement mismatch");
        run.meta.after = result.after;
        run.meta.leaseExpiresAt = result.leaseExpiresAt;
        this.saveRun(run);
        if (result.stopped) {
          await run.service.cancel(run.control);
          this.finished(run);
          break;
        }
        await run.service.attach({
          ...run.control,
          after: run.meta.after,
          leaseExpiresAt: result.leaseExpiresAt,
        });
        for (const answer of this.closing ? [] : result.answers)
          await run.service.respond({ ...run.control, ...answer });
        if (page.frames.length === 128 || frames.length === 128) run.dirty = true;
      }
    })()
      .catch((error) => {
        if (!this.closing) return this.disconnected(run, error);
      })
      .finally(() => {
        run.pumping = undefined;
        if (run.dirty && !run.finished && !this.closing && !run.abort.signal.aborted)
          queueMicrotask(() => void this.pump(run));
      });
    return run.pumping;
  }
  private async disconnected(run: Active, error?: unknown) {
    // An uncertain transport result authorizes event replay only, never a prompt replay.
    let stopped = false;
    try {
      await run.service.cancel(run.control);
      stopped = true;
    } catch {
      // Keep the entry live so Stop and Quit cannot claim unconfirmed process cleanup.
    }
    clearInterval(run.heartbeat);
    run.abort.abort();
    if (!stopped) return;
    const code = error && typeof error === "object" && "code" in error ? error.code : undefined;
    if (
      this.options.currentOrigin() !== run.meta.origin ||
      ["UNAUTHORIZED", "FORBIDDEN", "NOT_FOUND"].includes(String(code)) ||
      Date.parse(run.meta.leaseExpiresAt) <= Date.now()
    ) {
      this.park(run);
      return;
    }
    if (run.finished || this.closing || run.retry) return;
    run.retry = setTimeout(() => {
      run.retry = undefined;
      run.dirty = true;
      void this.pump(run);
    }, 3_000);
    run.retry.unref();
  }
  private park(run: Active) {
    run.finished = true;
    clearInterval(run.heartbeat);
    clearTimeout(run.retry);
    run.abort.abort();
    this.runs.delete(run.meta.runId);
    // Retain unacknowledged events for a future authenticated reconciliation.
  }
  private finished(run: Active) {
    run.finished = true;
    clearInterval(run.heartbeat);
    clearTimeout(run.retry);
    run.abort.abort();
    rmSync(this.metaFile(run.meta.runId), { force: true });
  }
  async answer(origin: string, input: { runId: string; messageId: string; answer: string }) {
    const run = this.runs.get(input.runId);
    if (!run || run.meta.origin !== origin || run.finished) return false;
    const { userId } = await this.owner(origin, run.meta.spaceId);
    if (userId !== run.meta.userId) throw new Error("Local execution scope changed");
    const result = await run.rpc.hostExecutions.answer({
      runId: input.runId,
      token: run.token,
      messageId: input.messageId,
      answer: input.answer,
    });
    if (!result.ok) throw new Error("The local request expired");
    run.dirty = true;
    await this.pump(run);
    return true;
  }
  async stop(origin: string, input: { botId: string; spaceId: string }) {
    this.revoke(origin, input);
    const { userId } = await this.owner(origin, input.spaceId, true);
    await Promise.all(
      [...this.runs.values()]
        .filter(
          (run) =>
            run.meta.origin === origin &&
            run.meta.userId === userId &&
            run.meta.spaceId === input.spaceId &&
            run.meta.botId === input.botId &&
            !run.finished,
        )
        .map(async (run) => {
          await run.service.cancel(run.control);
          run.dirty = true;
          await this.pump(run, this.closing ? AbortSignal.timeout(5000) : undefined);
        }),
    );
  }
  hasRuns() {
    return (
      !this.closed &&
      (this.pending.size > 0 || [...this.runs.values()].some((run) => !run.finished))
    );
  }
  close() {
    if (this.shutdown) return this.shutdown;
    this.closing = true;
    this.revoke();
    for (const run of this.runs.values()) {
      clearInterval(run.heartbeat);
      clearTimeout(run.retry);
      run.abort.abort();
    }
    this.shutdown = (async () => {
      await Promise.all(
        [...this.services.values()].map((service) => service.close({ cancelled: true })),
      );
      const abort = new AbortController();
      let timeout: NodeJS.Timeout | undefined;
      try {
        await Promise.race([
          Promise.all(
            [...this.runs.values()].map(async (run) => {
              await run.pumping;
              run.dirty = true;
              await this.pump(run, abort.signal);
            }),
          ),
          new Promise<void>((resolve) => {
            timeout = setTimeout(() => {
              abort.abort();
              resolve();
            }, 5000);
          }),
        ]);
      } finally {
        clearTimeout(timeout);
        abort.abort();
      }
      this.closed = true;
    })().catch((error) => {
      this.shutdown = undefined;
      throw error;
    });
    return this.shutdown;
  }
  /** A navigation loses its old native authority immediately, before another page runs. */
  async disconnectedWindow() {
    this.revoke();
    await Promise.all(
      [...this.runs.values()]
        .filter((run) => !run.finished)
        .map(async (run) => {
          await run.service.cancel(run.control);
          run.dirty = true;
          await this.pump(run);
          if (!run.finished) this.park(run);
        }),
    );
  }
}

const scopeInput = { botId: z.string().min(1).max(256), spaceId: z.string().min(1).max(256) };
export const hostIpcSchemas = {
  profiles: z.object({ spaceId: scopeInput.spaceId }).strict(),
  selection: z.object(scopeInput).strict(),
  configure: z
    .object({
      ...scopeInput,
      profileId: z.string().max(256).nullable(),
      target: z.enum(["workspace", "computer"]).optional(),
    })
    .strict(),
  send: z
    .object({
      ...scopeInput,
      text: z.string().trim().min(1).max(100_000),
      clientNonce: z.string().min(1).max(256),
    })
    .strict(),
  answer: z
    .object({
      runId: z.string().min(1).max(256),
      messageId: z.string().min(1).max(256),
      answer: z.string().min(1).max(16_384),
    })
    .strict(),
  stop: z.object(scopeInput).strict(),
  disconnect: z.object({}).strict(),
} satisfies { [Key in keyof DesktopHostBridge]: z.ZodType };

export * from "./host-adapter.js";
