// The roster stream (design §5.4), ported from apps/mobile/lib/api/roster-signals.ts: one
// notifications/subscribe for the whole app, open while any screen holds it and only in the
// foreground. Every (re)connection opens with a roster signal, so reconnecting catches up on what
// was missed; that signal invalidates and re-reads the roster. SpaceChangeKind frames dispatch to
// their readers; organizations is ignored (no organization UI in Phase 1); heartbeats only prove
// liveness (the parser already drops them). Reconnect backoff is 1s→30s before the stream ever
// opened, then the 0–5s reconnect spread once it has; a non-retryable 4xx suspends until the
// session or Space changes. There is NO timed fallback re-read and NO polling: reads happen only
// on a signal, on returning to the foreground, or after a write.
import { captureContext } from '../net/rpc';
import type { RpcContext } from '../net/rpc';
import { RpcError } from '../net/errors';
import { isRetryableError, reconnectDelayMs, retryDelayMs } from '../net/retry';
import { subscribeRpcEvents } from '../net/sse';
import type { SseEvent, SseHandle } from '../net/sse';
import { subscribeSession, subscribeSpaceSelection } from '../net/session';

/** The Space change kinds the stream forwards (the SpaceChangeKind enum, pinned by snapshot). */
export const SPACE_CHANGE_KINDS: string[] =
  ['computerUpdates', 'runs', 'routines', 'meetings', 'artifacts', 'meetingCalendar'];

export function isSpaceChangeKind(type: string): boolean {
  return SPACE_CHANGE_KINDS.includes(type);
}

/** Opens one notifications/subscribe stream; injectable so the state machine replays offline. */
export type RosterOpen = (context: RpcContext, onEvent: (event: SseEvent) => void) => SseHandle;

function realOpen(context: RpcContext, onEvent: (event: SseEvent) => void): SseHandle {
  const input: Record<string, Object> = {};
  return subscribeRpcEvents(context.apiBase, 'notifications/subscribe', input, context.headers, onEvent);
}

const rosterListeners: Set<() => void> = new Set();
const spaceChangeListeners: Set<(kind: string) => void> = new Set();

/** Runs on each roster signal, including the one every (re)connection opens with. */
export function subscribeRoster(listener: () => void): () => void {
  rosterListeners.add(listener);
  return (): void => {
    rosterListeners.delete(listener);
  };
}

/** Runs on each Space change signal of any kind. */
export function subscribeSpaceChange(listener: (kind: string) => void): () => void {
  spaceChangeListeners.add(listener);
  return (): void => {
    spaceChangeListeners.delete(listener);
  };
}

function notifyRoster(): void {
  for (const listener of rosterListeners) {
    listener();
  }
}

function notifySpaceChange(kind: string): void {
  for (const listener of spaceChangeListeners) {
    listener(kind);
  }
}

/** The stream speaks for one session and Space, so either changing reopens it. */
function followIdentity(listener: () => void): () => void {
  const unfollowSpace = subscribeSpaceSelection(listener);
  const unfollowSession = subscribeSession(listener);
  return (): void => {
    unfollowSpace();
    unfollowSession();
  };
}

/** One connection attempt; identity change aborts it so the loop reopens with the new scope. */
class Connection {
  aborted: boolean = false;
}

export class RosterStream {
  stopped: boolean = false;
  /** Overridable wait so tests drive the loop without real backoff timers. */
  wait: (ms: number) => Promise<void> = (ms: number): Promise<void> => this.delay(ms);
  private stopWaiters: Set<() => void> = new Set();
  private handle: SseHandle | null = null;

  /** Resolves after ms, or at once when the stream stops (a cancellable delay). */
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

  /** Resolves when the session or Space changes, or the stream stops (the non-retryable hold). */
  waitIdentity(): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      const done = (): void => {
        unfollow();
        this.stopWaiters.delete(done);
        resolve();
      };
      const unfollow = followIdentity(done);
      this.stopWaiters.add(done);
      if (this.stopped) {
        done();
      }
    });
  }

  stop(): void {
    this.stopped = true;
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

  /** The follow loop: open, dispatch, reconnect with backoff, hold on a refusal. */
  async follow(open: RosterOpen): Promise<void> {
    let retry = 1_000;
    while (!this.stopped) {
      let failure: RpcError | null = null;
      let opened = false;
      const connection = new Connection();
      const abort = (): void => {
        connection.aborted = true;
        this.handle?.close();
      };
      const unfollow = followIdentity(abort);
      try {
        const context = await captureContext();
        if (!this.stopped && !connection.aborted) {
          this.handle = open(context, (event: SseEvent): void => {
            if (connection.aborted) {
              return;
            }
            const type = typeof event['type'] === 'string' ? event['type'] as string : '';
            if (type === 'roster') {
              opened = true;
              notifyRoster();
            } else if (isSpaceChangeKind(type)) {
              notifySpaceChange(type);
            }
            // alert / organizations / unknown: ignored in Phase 1.
          });
          await this.handle.done;
        }
      } catch (err) {
        failure = err instanceof RpcError ? err as RpcError : new RpcError(String(err));
      }
      unfollow();
      this.handle = null;
      if (this.stopped) {
        return;
      }
      if (connection.aborted) {
        // Identity changed: reopen at once with the new session/Space.
        continue;
      }
      if (failure !== null && !isRetryableError(failure)) {
        // Asking again cannot change a refusal, but another session or Space may answer.
        await this.waitIdentity();
        retry = 1_000;
        continue;
      }
      if (opened) {
        retry = 1_000;
      }
      const random = Math.random();
      const delay = opened ? reconnectDelayMs(failure, random) : retryDelayMs(failure, retry, random);
      await this.wait(delay);
      retry = Math.min(retry * 2, 30_000);
    }
  }
}

let holders = 0;
let active: RosterStream | null = null;

/** Keeps the stream open while held; the first holder starts it, the last release stops it. */
export function holdRoster(open: RosterOpen = realOpen): () => void {
  if (holders++ === 0) {
    const stream = new RosterStream();
    active = stream;
    void stream.follow(open);
  }
  let released = false;
  return (): void => {
    if (released) {
      return;
    }
    released = true;
    holders -= 1;
    if (holders > 0) {
      return;
    }
    active?.stop();
    active = null;
  };
}

/** Test seam: the live stream, so a suite can stop it between cases. */
export function activeRosterStream(): RosterStream | null {
  return active;
}
