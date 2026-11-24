// The thread stream (design §5.4), ported from apps/mobile/lib/thread/thread-live.ts's loop:
// threads/get once → subscribe from its cursor → reduce events → commit. Returning to the same
// chat resumes from the applied cursor (no gaps); another chat or session starts fresh. On a
// retryable disconnect: refresh first (reconcile, never roll the live cursor back), then resubscribe
// from the cursor; backoff 250ms→5s, a stream that ended without the server's answer spreads its
// reconnect 0–5s. A non-retryable 4xx stops the loop and surfaces the error. run terminal /
// waiting_input events trigger one coalesced snapshot refresh (ask-ownership reconcile).
// No timed re-read: the only reads are the open, the disconnect refresh and the event-driven one.
import { captureContext, rpc } from '../net/rpc';
import type { RpcContext } from '../net/rpc';
import { RpcError, errorText } from '../net/errors';
import { errorStatus, isRetryableError, reconnectDelayMs, retryDelayMs } from '../net/retry';
import { subscribeRpcEvents } from '../net/sse';
import type { SseEvent, SseHandle } from '../net/sse';
import { currentSessionGeneration } from '../net/session';
import { decodeThreadSnapshot } from '../thread/thread-decode';
import {
  isRunTerminalEvent,
  reduceThreadSnapshot,
  rememberTerminalRun,
} from '../thread/thread-snapshot';
import { reconcileRefreshedThread } from '../thread/thread-merge';
import { trimHistoryWindow } from '../thread/thread-window';
import type { ThreadEvent, ThreadSnapshot } from '../thread/thread-snapshot';

/** Opens one threads/subscribe stream; injectable so the state machine replays offline. */
export type ThreadOpen = (context: RpcContext, input: Record<string, Object>,
  onEvent: (event: SseEvent) => void) => SseHandle;

function realOpen(context: RpcContext, input: Record<string, Object>,
  onEvent: (event: SseEvent) => void): SseHandle {
  return subscribeRpcEvents(context.apiBase, 'threads/subscribe', input, context.headers, onEvent);
}

/** Reads one threads/get snapshot; injectable for offline replay. */
export type ThreadFetch = (context: RpcContext, input: Record<string, Object>) => Promise<Object>;

function realFetch(context: RpcContext, input: Record<string, Object>): Promise<Object> {
  return rpc('threads/get', input, { context: context });
}

/** One controllable wait; tests drive the loop without real backoff timers. */
export type ThreadWait = (ms: number) => Promise<void>;

/** The event shape the reducer takes, read defensively from a stream frame. */
export function threadEventFromFrame(frame: SseEvent): ThreadEvent {
  const payloadRaw = frame['payload'];
  const empty: Record<string, Object> = {};
  const payload = payloadRaw !== null && payloadRaw !== undefined && typeof payloadRaw === 'object'
    && !Array.isArray(payloadRaw) ? payloadRaw as Record<string, Object> : empty;
  const event: ThreadEvent = {
    type: typeof frame['type'] === 'string' ? frame['type'] as string : '',
    payload: payload,
  };
  if (typeof frame['id'] === 'string') {
    event.id = frame['id'] as string;
  }
  if (typeof frame['seq'] === 'number') {
    event.seq = frame['seq'] as number;
  }
  if (typeof frame['threadId'] === 'string') {
    event.threadId = frame['threadId'] as string;
  }
  if (typeof frame['botId'] === 'string') {
    event.botId = frame['botId'] as string;
  }
  if (typeof frame['runId'] === 'string') {
    event.runId = frame['runId'] as string;
  }
  if (typeof frame['createdAt'] === 'string') {
    event.createdAt = frame['createdAt'] as string;
  }
  return event;
}

export interface ThreadStreamDeps {
  open?: ThreadOpen;
  fetch?: ThreadFetch;
  wait?: ThreadWait;
  /** Called with each committed snapshot (the store paints it). */
  commit: (snapshot: ThreadSnapshot | null) => void;
  /** A stream failure the loop surfaced (non-retryable, or refresh refusal). */
  onError?: (error: RpcError) => void;
  /** A message.created that is new to this viewer (markRead hook; the UI stage wires it). */
  onUnread?: (event: ThreadEvent) => void;
  /** A run terminal / waiting_input event was applied (the store may reconcile ownership). */
  onRunSettled?: () => void;
}

export class ThreadStream {
  stopped: boolean = false;
  /** The applied cursor; -1 before the first snapshot. Survives a stop/start of the same chat. */
  cursor: number = -1;
  /** Whether a snapshot was loaded for this chat (resume skips the initial threads/get). */
  loaded: boolean = false;
  /** Older history pages were prepended; a refresh must keep them (mobile thread-sync's
   * preserveHistory: expandedHistoryThread === the refreshed thread). */
  historyExpanded: boolean = false;
  connected: boolean = false;
  readonly terminalRunIds: Set<string> = new Set();
  private snapshot: ThreadSnapshot | null = null;
  private handle: SseHandle | null = null;
  private deps: ThreadStreamDeps;
  private open: ThreadOpen;
  private fetch: ThreadFetch;
  private waitImpl: ThreadWait;
  private stopWaiters: Set<() => void> = new Set();
  private refreshDirty: boolean = false;
  private refreshRunning: Promise<void> | null = null;

  constructor(deps: ThreadStreamDeps) {
    this.deps = deps;
    this.open = deps.open ?? realOpen;
    this.fetch = deps.fetch ?? realFetch;
    this.waitImpl = deps.wait ?? ((ms: number): Promise<void> => this.delay(ms));
  }

  /** The last committed snapshot (the receipt path patches it between events). */
  current(): ThreadSnapshot | null {
    return this.snapshot;
  }

  /** Commit a snapshot built outside the stream (the send receipt), keeping the cursor. The
   * history window (design §9 R4) is applied here — the one point every snapshot passes through
   * (refresh, live reduce, receipt, prepend), so loaded history never exceeds the cap. */
  commit(snapshot: ThreadSnapshot | null): void {
    const windowed = snapshot === null ? null : trimHistoryWindow(snapshot);
    this.snapshot = windowed;
    this.deps.commit(windowed);
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      const done = (): void => {
        clearTimeout(timer);
        this.stopWaiters.delete(done);
        resolve();
      };
      const timer = setTimeout((): void => {
        this.stopWaiters.delete(done);
        resolve();
      }, ms);
      this.stopWaiters.add(done);
      if (this.stopped) {
        done();
      }
    });
  }

  stop(): void {
    this.stopped = true;
    this.connected = false;
    this.handle?.close();
    const waiters: (() => void)[] = [];
    for (const waiter of this.stopWaiters) {
      waiters.push(waiter);
    }
    this.stopWaiters.clear();
    for (const waiter of waiters) {
      waiter();
    }
  }

  /**
   * One coalesced refresh (core createRefreshCoalescer): invalidations arriving during a read
   * are retained and drained, so a burst of run events costs one threads/get, not one each.
   */
  private refreshOnce(context: RpcContext, input: Record<string, Object>): Promise<void> {
    const drain = async (): Promise<void> => {
      while (this.refreshDirty && !this.stopped) {
        this.refreshDirty = false;
        try {
          await this.refresh(context, input);
        } catch (err) {
          // The loop's own disconnect refresh reports failures; an event-driven one only delays
          // the reconcile (the live events already carry the state).
        }
      }
      this.refreshRunning = null;
    };
    this.refreshDirty = true;
    if (this.refreshRunning === null) {
      this.refreshRunning = Promise.resolve().then(drain);
    }
    return this.refreshRunning;
  }

  /** One user-driven refresh (the store's jumpToLatest): same coalesced read the settle events
   * use; a failure only delays the jump — the live events already carry the state. */
  async refreshNow(input: Record<string, Object>): Promise<void> {
    const context = await captureContext();
    if (this.stopped || context.generation !== currentSessionGeneration()) {
      return;
    }
    await this.refreshOnce(context, input);
  }

  /** threads/get → reconcile against the live snapshot; a stale answer never rolls state back. */
  private async refresh(context: RpcContext, input: Record<string, Object>): Promise<void> {
    const value = await this.fetch(context, input);
    if (this.stopped || context.generation !== currentSessionGeneration()) {
      return;
    }
    const next = decodeThreadSnapshot(value);
    if (next === null) {
      throw new RpcError('Unexpected response from the server');
    }
    const merged = trimHistoryWindow(reconcileRefreshedThread(this.snapshot, next, this.historyExpanded));
    this.snapshot = merged;
    // The live cursor is the replay position; a refresh behind it must not rewind the stream.
    this.cursor = Math.max(this.cursor, merged.cursor);
    this.loaded = true;
    this.deps.commit(merged);
  }

  /**
   * The follow loop. `input` is the thread target ({botId} or {groupId}); the cursor is appended
   * per attempt. Resolves when stopped or refused; the caller owns restart on identity change.
   */
  async follow(input: Record<string, Object>): Promise<void> {
    const context = await captureContext();
    if (this.stopped) {
      return;
    }
    if (!this.loaded) {
      try {
        await this.refresh(context, input);
      } catch (err) {
        const error = err instanceof RpcError ? err as RpcError : new RpcError(String(err));
        this.deps.onError?.(error);
        // A failed open read leaves the screen empty with its error; retry is the user's tap
        // (restart), not a polling loop.
        return;
      }
    }
    if (this.stopped || context.generation !== currentSessionGeneration()) {
      return;
    }
    let retryMs = 250;
    while (!this.stopped && context.generation === currentSessionGeneration()) {
      let failure: RpcError | null = null;
      const subscribeInput: Record<string, Object> = {};
      for (const key of Object.keys(input)) {
        subscribeInput[key] = input[key];
      }
      subscribeInput['cursor'] = this.cursor;
      try {
        this.connected = true;
        this.handle = this.open(context, subscribeInput, (frame: SseEvent): void => {
          this.applyFrame(context, input, frame);
        });
        await this.handle.done;
      } catch (err) {
        failure = err instanceof RpcError ? err as RpcError : new RpcError(String(err));
      }
      this.connected = false;
      this.handle = null;
      if (this.stopped || context.generation !== currentSessionGeneration()) {
        return;
      }
      // A 4xx other than 408/429 is the server's answer; reconnecting only polls it.
      if (failure !== null && !isRetryableError(failure)) {
        this.deps.onError?.(failure);
        return;
      }
      // Ended without the server's answer: most likely closed under it, as a deploy closes
      // every client's stream at once — spread the reconnect.
      if (errorStatus(failure) === undefined) {
        await this.waitImpl(reconnectDelayMs(failure, Math.random()));
        if (this.stopped || context.generation !== currentSessionGeneration()) {
          return;
        }
      }
      let refreshFailure: RpcError | null = null;
      try {
        await this.refresh(context, input);
      } catch (err) {
        refreshFailure = err instanceof RpcError ? err as RpcError : new RpcError(String(err));
      }
      if (refreshFailure !== null && !isRetryableError(refreshFailure)) {
        this.deps.onError?.(refreshFailure);
        return;
      }
      // Wait as long as either request was asked to (a 429's Retry-After).
      const delay = Math.max(retryDelayMs(failure, retryMs, Math.random()),
        retryDelayMs(refreshFailure, retryMs, Math.random()));
      await this.waitImpl(delay);
      retryMs = Math.min(retryMs * 2, 5_000);
    }
  }

  private applyFrame(context: RpcContext, input: Record<string, Object>, frame: SseEvent): void {
    if (this.stopped || context.generation !== currentSessionGeneration()) {
      return;
    }
    const event = threadEventFromFrame(frame);
    if (!event.type) {
      return;
    }
    const newEvent = (event.seq ?? -1) > this.cursor;
    this.cursor = Math.max(this.cursor, event.seq ?? -1);
    rememberTerminalRun(this.terminalRunIds, event);
    if (!newEvent) {
      return;
    }
    const previous = this.snapshot;
    const reduced = reduceThreadSnapshot(previous, event);
    if (reduced !== previous) {
      this.commit(reduced);
    }
    if (event.type === 'thread.message.created') {
      this.deps.onUnread?.(event);
    }
    if (isRunTerminalEvent(event) || event.type === 'run.waiting_input') {
      // Reconcile run ownership for ask cards first seen through live events.
      void this.refreshOnce(context, input);
      this.deps.onRunSettled?.();
    }
  }
}

/** The error copy a surfaced stream failure shows (the store renders it). */
export function threadStreamErrorText(error: RpcError): string {
  return errorText(error);
}
