// The thread stream state machine (design §5.4), driven offline with an injectable open/fetch and
// an overridable wait: open → subscribe from the snapshot cursor, resume from the applied cursor
// without a re-read, disconnect → refresh → resubscribe (no gaps), the reconnect spread, backoff
// growth, non-retryable refusal, coalesced run-settle refresh, and stop. No network, no real timers.
import { describe, expect, it, beforeAll, beforeEach, afterEach } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { ThreadStream } from '../../../main/ets/realtime/thread-stream';
import type { ThreadFetch, ThreadOpen } from '../../../main/ets/realtime/thread-stream';
import { SseHandle } from '../../../main/ets/net/sse';
import type { SseEvent } from '../../../main/ets/net/sse';
import { RpcError } from '../../../main/ets/net/errors';
import type { RpcContext } from '../../../main/ets/net/rpc';
import { initServerStore, switchServer } from '../../../main/ets/net/server-store';
import { clearSessionToken, saveSessionToken, setSelectedSpace } from '../../../main/ets/net/session';
import type { ThreadSnapshot } from '../../../main/ets/thread/thread-snapshot';
import { app } from '../../../main/ets/app/app-state';

const BASE = 'http://10.0.2.2:8787';

/** One controllable fake connection: emit frames, then end it (eof) or fail it. */
class FakeConn {
  resolveDone: () => void = (): void => {};
  rejectDone: (error: RpcError) => void = (): void => {};
  done: Promise<void>;
  handle: SseHandle;
  cursor: number = -1;
  private onEvent: (event: SseEvent) => void;

  constructor(onEvent: (event: SseEvent) => void) {
    this.onEvent = onEvent;
    this.done = new Promise<void>((resolve: () => void, reject: (error: RpcError) => void): void => {
      this.resolveDone = resolve;
      this.rejectDone = reject;
    });
    this.handle = new SseHandle(this.done, (): void => this.resolveDone());
  }

  emit(event: SseEvent): void {
    this.onEvent(event);
  }
}

function frame(seq: number, type: string, runId: string, payload: Record<string, Object>): SseEvent {
  const event: SseEvent = {};
  event['type'] = type;
  event['seq'] = seq;
  event['threadId'] = 'thread-1';
  event['botId'] = 'bot-1';
  event['id'] = `evt-${seq}`;
  event['createdAt'] = '2026-11-21T12:00:00.000Z';
  if (runId) {
    event['runId'] = runId;
  }
  event['payload'] = payload;
  return event;
}

function progress(seq: number, runId: string, delta: string): SseEvent {
  const payload: Record<string, Object> = {};
  payload['delta'] = delta;
  return frame(seq, 'thread.progress', runId, payload);
}

/** A threads/get answer with the given cursor and one durable message. */
function snapshotJson(cursor: number): Object {
  const message: Record<string, Object> = {};
  message['id'] = 'msg-1';
  message['threadId'] = 'thread-1';
  message['seq'] = 1;
  message['role'] = 'bot';
  const block: Record<string, Object> = {};
  block['kind'] = 'text';
  block['text'] = 'saved';
  message['blocks'] = [block];
  message['createdAt'] = '2026-11-21T12:00:00.000Z';
  const snapshot: Record<string, Object> = {};
  snapshot['threadId'] = 'thread-1';
  snapshot['botId'] = 'bot-1';
  snapshot['cursor'] = cursor;
  // olderCursor/run null come from JSON.parse; a Record value cannot hold null in ArkTS.
  const nullable: Record<string, Object> = JSON.parse('{"olderCursor":null,"run":null}') as Record<string, Object>;
  snapshot['olderCursor'] = nullable['olderCursor'];
  snapshot['messages'] = [message];
  snapshot['run'] = nullable['run'];
  return snapshot;
}

interface FetchCall {
  context: RpcContext;
}

/** Scripted fetch answers plus the calls it received. */
class FetchFixture {
  calls: FetchCall[] = [];
  answers: Object[] = [];
  failures: RpcError[] = [];
  fetch: ThreadFetch;

  constructor() {
    this.fetch = (context: RpcContext, _input: Record<string, Object>): Promise<Object> => {
      this.calls.push({ context: context });
      const index = this.calls.length - 1;
      if (index < this.failures.length && this.failures[index] !== null) {
        return Promise.reject(this.failures[index]);
      }
      const answer = index < this.answers.length ? this.answers[index] : snapshotJson(0);
      return Promise.resolve(answer);
    };
  }
}

/** The injectable open plus the connections it created, so a test can drive them. */
class OpenFixture {
  conns: FakeConn[] = [];
  open: ThreadOpen;

  constructor(behavior: (conn: FakeConn, index: number) => void) {
    this.open = (context: RpcContext, input: Record<string, Object>,
      onEvent: (event: SseEvent) => void): SseHandle => {
      const conn = new FakeConn(onEvent);
      const cursor = input['cursor'];
      conn.cursor = typeof cursor === 'number' ? cursor as number : -1;
      this.conns.push(conn);
      behavior(conn, this.conns.length - 1);
      return conn.handle;
    };
  }
}

async function waitFor(condition: () => boolean, label: string): Promise<void> {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    if (condition()) {
      return;
    }
    await new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, 10);
    });
  }
  throw new Error(`timed out waiting for ${label}`);
}

function target(): Record<string, Object> {
  const input: Record<string, Object> = {};
  input['botId'] = 'bot-1';
  return input;
}

export default function threadStreamTest() {
  describe('ThreadStateMachine', () => {
    beforeAll(async () => {
      app.detach();
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext();
      await initServerStore(context);
      await switchServer(BASE, {});
    });

    beforeEach(async () => {
      await saveSessionToken('fake-token');
      setSelectedSpace('space-fake');
    });

    afterEach(async () => {
      await clearSessionToken();
      setSelectedSpace('');
    });

    it('opens_with_snapshot_then_subscribes_from_its_cursor', 0, async () => {
      const fetchFixture = new FetchFixture();
      fetchFixture.answers = [snapshotJson(5)];
      const openFixture = new OpenFixture((_conn: FakeConn, _index: number): void => {});
      const commits: (ThreadSnapshot | null)[] = [];
      const stream = new ThreadStream({
        fetch: fetchFixture.fetch,
        open: openFixture.open,
        commit: (snapshot: ThreadSnapshot | null): void => {
          commits.push(snapshot);
        },
      });
      void stream.follow(target());
      await waitFor((): boolean => openFixture.conns.length === 1, 'first subscribe');
      expect(fetchFixture.calls.length).assertEqual(1);
      expect(openFixture.conns[0].cursor).assertEqual(5);
      expect(commits.length >= 1).assertTrue();
      expect(commits[0]!.messages.length).assertEqual(1);
      openFixture.conns[0].emit(progress(6, 'run-1', 'Hi'));
      await waitFor((): boolean => stream.current() !== null
        && stream.current()!.messages.some((m): boolean => m.id === 'progress:run-1'), 'progress applied');
      expect(stream.cursor).assertEqual(6);
      stream.stop();
    });

    it('resume_reuses_the_applied_cursor_without_a_new_get', 0, async () => {
      const fetchFixture = new FetchFixture();
      fetchFixture.answers = [snapshotJson(2)];
      const openFixture = new OpenFixture((_conn: FakeConn, _index: number): void => {});
      const stream = new ThreadStream({
        fetch: fetchFixture.fetch,
        open: openFixture.open,
        commit: (_snapshot: ThreadSnapshot | null): void => {},
      });
      void stream.follow(target());
      await waitFor((): boolean => openFixture.conns.length === 1, 'first subscribe');
      openFixture.conns[0].emit(progress(9, 'run-1', 'live'));
      await waitFor((): boolean => stream.cursor === 9, 'cursor advanced');
      stream.stop();
      // A new stream object for the same chat resumes from the carried cursor (the store keeps it).
      const resumed = new ThreadStream({
        fetch: fetchFixture.fetch,
        open: openFixture.open,
        commit: (_snapshot: ThreadSnapshot | null): void => {},
      });
      resumed.cursor = stream.cursor;
      resumed.loaded = true;
      void resumed.follow(target());
      await waitFor((): boolean => openFixture.conns.length === 2, 'second subscribe');
      expect(openFixture.conns[1].cursor).assertEqual(9);
      expect(fetchFixture.calls.length).assertEqual(1);
      resumed.stop();
    });

    it('disconnect_refreshes_then_resubscribes_without_gaps', 0, async () => {
      const fetchFixture = new FetchFixture();
      // Open at 2; the disconnect refresh answers a snapshot at 4 (another device's activity).
      fetchFixture.answers = [snapshotJson(2), snapshotJson(4)];
      const openFixture = new OpenFixture((conn: FakeConn, index: number): void => {
        if (index === 0) {
          setTimeout((): void => conn.rejectDone(new RpcError('connection lost', 0, '', -1, true)), 5);
        }
      });
      const stream = new ThreadStream({
        fetch: fetchFixture.fetch,
        open: openFixture.open,
        wait: (_ms: number): Promise<void> => Promise.resolve(),
        commit: (_snapshot: ThreadSnapshot | null): void => {},
      });
      void stream.follow(target());
      await waitFor((): boolean => openFixture.conns.length === 2, 'resubscribe');
      expect(fetchFixture.calls.length).assertEqual(2);
      expect(openFixture.conns[1].cursor).assertEqual(4);
      stream.stop();
    });

    it('stale_refresh_never_rolls_the_live_cursor_back', 0, async () => {
      const fetchFixture = new FetchFixture();
      fetchFixture.answers = [snapshotJson(2), snapshotJson(1)];
      const openFixture = new OpenFixture((conn: FakeConn, index: number): void => {
        if (index === 0) {
          conn.emit(progress(7, 'run-1', 'ahead'));
          setTimeout((): void => conn.rejectDone(new RpcError('connection lost', 0, '', -1, true)), 5);
        }
      });
      const stream = new ThreadStream({
        fetch: fetchFixture.fetch,
        open: openFixture.open,
        wait: (_ms: number): Promise<void> => Promise.resolve(),
        commit: (_snapshot: ThreadSnapshot | null): void => {},
      });
      void stream.follow(target());
      await waitFor((): boolean => openFixture.conns.length === 2, 'resubscribe');
      expect(stream.cursor).assertEqual(7);
      expect(openFixture.conns[1].cursor).assertEqual(7);
      expect(stream.current()!.messages.some((m): boolean => m.id === 'progress:run-1')).assertTrue();
      stream.stop();
    });

    it('backoff_grows_and_caps_at_five_seconds', 0, async () => {
      const fetchFixture = new FetchFixture();
      const waits: number[] = [];
      const openFixture = new OpenFixture((conn: FakeConn, _index: number): void => {
        setTimeout((): void => conn.rejectDone(new RpcError('server fault', 500)), 2);
      });
      const stream = new ThreadStream({
        fetch: fetchFixture.fetch,
        open: openFixture.open,
        wait: (ms: number): Promise<void> => {
          waits.push(ms);
          return Promise.resolve();
        },
        commit: (_snapshot: ThreadSnapshot | null): void => {},
      });
      void stream.follow(target());
      await waitFor((): boolean => waits.length >= 6, 'six backoff waits');
      stream.stop();
      // jitter halves at most: 250→[125,250], 500→[250,500], … capped at 5000.
      expect(waits[0] >= 125 && waits[0] <= 250).assertTrue();
      expect(waits[1] >= 250 && waits[1] <= 500).assertTrue();
      expect(waits[2] >= 500 && waits[2] <= 1000).assertTrue();
      expect(waits[5] <= 5000).assertTrue();
      for (let index = 1; index < waits.length; index += 1) {
        expect(waits[index] >= waits[index - 1] / 2).assertTrue();
      }
    });

    it('clean_eof_spreads_the_reconnect_before_refreshing', 0, async () => {
      const fetchFixture = new FetchFixture();
      const waits: number[] = [];
      const openFixture = new OpenFixture((conn: FakeConn, index: number): void => {
        if (index === 0) {
          setTimeout((): void => conn.resolveDone(), 2);
        }
      });
      const stream = new ThreadStream({
        fetch: fetchFixture.fetch,
        open: openFixture.open,
        wait: (ms: number): Promise<void> => {
          waits.push(ms);
          return Promise.resolve();
        },
        commit: (_snapshot: ThreadSnapshot | null): void => {},
      });
      void stream.follow(target());
      await waitFor((): boolean => openFixture.conns.length === 2, 'resubscribe');
      stream.stop();
      // The spread wait comes first (0–5s), then the retry wait; both were recorded.
      expect(waits.length >= 2).assertTrue();
      expect(waits[0] >= 0 && waits[0] <= 5000).assertTrue();
    });

    it('non_retryable_refusal_stops_the_loop_and_surfaces_the_error', 0, async () => {
      const fetchFixture = new FetchFixture();
      const errors: RpcError[] = [];
      const openFixture = new OpenFixture((conn: FakeConn, _index: number): void => {
        setTimeout((): void => conn.rejectDone(new RpcError('Thread access refused', 403)), 2);
      });
      const stream = new ThreadStream({
        fetch: fetchFixture.fetch,
        open: openFixture.open,
        wait: (_ms: number): Promise<void> => Promise.resolve(),
        commit: (_snapshot: ThreadSnapshot | null): void => {},
        onError: (error: RpcError): void => {
          errors.push(error);
        },
      });
      await stream.follow(target());
      expect(openFixture.conns.length).assertEqual(1);
      expect(errors.length).assertEqual(1);
      expect(errors[0].status).assertEqual(403);
      expect(stream.connected).assertFalse();
    });

    it('run_settle_events_coalesce_into_one_refresh', 0, async () => {
      const fetchFixture = new FetchFixture();
      fetchFixture.answers = [snapshotJson(0)];
      const openFixture = new OpenFixture((_conn: FakeConn, _index: number): void => {});
      const stream = new ThreadStream({
        fetch: fetchFixture.fetch,
        open: openFixture.open,
        commit: (_snapshot: ThreadSnapshot | null): void => {},
      });
      void stream.follow(target());
      await waitFor((): boolean => openFixture.conns.length === 1, 'subscribe');
      const conn = openFixture.conns[0];
      const completed: Record<string, Object> = {};
      conn.emit(frame(1, 'run.completed', 'run-1', completed));
      conn.emit(frame(2, 'run.completed', 'run-2', completed));
      conn.emit(frame(3, 'run.waiting_input', 'run-3', completed));
      await waitFor((): boolean => fetchFixture.calls.length >= 2, 'coalesced refresh');
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 30);
      });
      // Three settle events in one burst cost ONE extra threads/get, not three.
      expect(fetchFixture.calls.length).assertEqual(2);
      stream.stop();
    });

    it('stop_ends_the_stream_and_the_loop', 0, async () => {
      const fetchFixture = new FetchFixture();
      const openFixture = new OpenFixture((_conn: FakeConn, _index: number): void => {});
      const stream = new ThreadStream({
        fetch: fetchFixture.fetch,
        open: openFixture.open,
        commit: (_snapshot: ThreadSnapshot | null): void => {},
      });
      void stream.follow(target());
      await waitFor((): boolean => openFixture.conns.length === 1, 'subscribe');
      stream.stop();
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 20);
      });
      expect(stream.connected).assertFalse();
      expect(openFixture.conns.length).assertEqual(1);
    });

    it('space_change_stops_the_open_stream', 0, async () => {
      // A1: the stream speaks for one Space. Switching does not wait for the screen to close the
      // chat — the open connection is closed by the stream itself and nothing reconnects.
      const fetchFixture = new FetchFixture();
      fetchFixture.answers = [snapshotJson(2)];
      const openFixture = new OpenFixture((_conn: FakeConn, _index: number): void => {});
      const stream = new ThreadStream({
        fetch: fetchFixture.fetch,
        open: openFixture.open,
        commit: (_snapshot: ThreadSnapshot | null): void => {},
      });
      const running = stream.follow(target());
      await waitFor((): boolean => openFixture.conns.length === 1, 'subscribe');
      expect(stream.connected).assertTrue();
      setSelectedSpace('space-second');
      await running;
      expect(stream.connected).assertFalse();
      expect(openFixture.conns.length).assertEqual(1);
      expect(fetchFixture.calls.length).assertEqual(1);
    });

    it('late_snapshot_from_the_previous_space_never_commits', 0, async () => {
      // The open read was pinned to A; the switch happened while it was in flight. Its answer
      // must not paint A's messages into the session now showing B.
      let resolveFetch: (answer: Object) => void = (): void => {};
      let started = false;
      const pending = new Promise<Object>((resolve: (answer: Object) => void): void => {
        resolveFetch = resolve;
      });
      const openFixture = new OpenFixture((_conn: FakeConn, _index: number): void => {});
      const commits: (ThreadSnapshot | null)[] = [];
      const stream = new ThreadStream({
        fetch: (context: RpcContext, _input: Record<string, Object>): Promise<Object> => {
          started = true;
          return pending;
        },
        open: openFixture.open,
        commit: (snapshot: ThreadSnapshot | null): void => {
          commits.push(snapshot);
        },
      });
      const running = stream.follow(target());
      await waitFor((): boolean => started, 'open read in flight');
      setSelectedSpace('space-second');
      resolveFetch(snapshotJson(4));
      await running;
      expect(stream.current()).assertNull();
      expect(commits.length).assertEqual(0);
      expect(openFixture.conns.length).assertEqual(0);
    });

    it('failed_open_read_surfaces_the_error_without_subscribing', 0, async () => {
      const fetchFixture = new FetchFixture();
      fetchFixture.failures = [new RpcError('Thread access refused', 403)];
      const errors: RpcError[] = [];
      const openFixture = new OpenFixture((_conn: FakeConn, _index: number): void => {});
      const stream = new ThreadStream({
        fetch: fetchFixture.fetch,
        open: openFixture.open,
        commit: (_snapshot: ThreadSnapshot | null): void => {},
        onError: (error: RpcError): void => {
          errors.push(error);
        },
      });
      await stream.follow(target());
      expect(openFixture.conns.length).assertEqual(0);
      expect(errors.length).assertEqual(1);
    });
  });
}
