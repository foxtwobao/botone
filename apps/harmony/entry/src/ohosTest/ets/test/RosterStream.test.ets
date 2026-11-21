// The roster stream state machine (design §5.4), driven offline with an injectable open and an
// overridable wait: holder counting, signal dispatch, the two backoff regimes, the non-retryable
// hold until identity changes, and reopen on a session/Space change. No network and no real timers.
import { describe, expect, it, beforeAll, beforeEach, afterEach } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import {
  activeRosterStream,
  holdRoster,
  isSpaceChangeKind,
  RosterStream,
  subscribeRoster,
  subscribeSpaceChange,
} from '../../../main/ets/realtime/roster';
import type { RosterOpen } from '../../../main/ets/realtime/roster';
import { SseHandle } from '../../../main/ets/net/sse';
import type { SseEvent } from '../../../main/ets/net/sse';
import { RpcError } from '../../../main/ets/net/errors';
import type { RpcContext } from '../../../main/ets/net/rpc';
import { initServerStore, switchServer } from '../../../main/ets/net/server-store';
import { clearSessionToken, saveSessionToken, setSelectedSpace } from '../../../main/ets/net/session';
import { app } from '../../../main/ets/app/app-state';

const BASE = 'http://10.0.2.2:8787';

/** One controllable fake connection: emit signals, then end it (eof) or fail it. */
class FakeConn {
  resolveDone: () => void = (): void => {};
  rejectDone: (error: RpcError) => void = (): void => {};
  done: Promise<void>;
  handle: SseHandle;
  private onEvent: (event: SseEvent) => void;

  constructor(onEvent: (event: SseEvent) => void) {
    this.onEvent = onEvent;
    this.done = new Promise<void>((resolve: () => void, reject: (error: RpcError) => void): void => {
      this.resolveDone = resolve;
      this.rejectDone = reject;
    });
    this.handle = new SseHandle(this.done, (): void => this.resolveDone());
  }

  emit(type: string): void {
    const event: SseEvent = {};
    event['type'] = type;
    this.onEvent(event);
  }
}

/** The injectable open plus the connections it created, so a test can drive them. */
class OpenFixture {
  open: RosterOpen;
  conns: FakeConn[] = [];

  constructor(behavior: (conn: FakeConn, index: number) => void) {
    this.open = (context: RpcContext, onEvent: (event: SseEvent) => void): SseHandle => {
      const conn = new FakeConn(onEvent);
      this.conns.push(conn);
      behavior(conn, this.conns.length - 1);
      return conn.handle;
    };
  }
}

async function waitFor(condition: () => boolean, label: string): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (condition()) {
      return;
    }
    await new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, 20);
    });
  }
  throw new Error(`timed out waiting for ${label}`);
}

function pause(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, ms);
  });
}

export default function rosterStreamTest() {
  describe('RosterStateMachine', () => {
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
      activeRosterStream()?.stop();
      await clearSessionToken();
      setSelectedSpace('');
    });

    it('space_change_kinds_are_the_six_enum_values', 0, () => {
      expect(isSpaceChangeKind('runs')).assertTrue();
      expect(isSpaceChangeKind('computerUpdates')).assertTrue();
      expect(isSpaceChangeKind('roster')).assertFalse();
      expect(isSpaceChangeKind('organizations')).assertFalse();
      expect(isSpaceChangeKind('heartbeat')).assertFalse();
    });

    it('dispatches_roster_and_space_changes_not_organizations', 0, async () => {
      let rosterCount = 0;
      const kinds: string[] = [];
      const offRoster = subscribeRoster((): void => {
        rosterCount += 1;
      });
      const offKind = subscribeSpaceChange((kind: string): void => {
        kinds.push(kind);
      });
      const fx = new OpenFixture((conn: FakeConn): void => {
        conn.emit('roster');
        conn.emit('runs');
        conn.emit('organizations');
        conn.emit('routines');
      });
      const stream = new RosterStream();
      const running = stream.follow(fx.open);
      await waitFor((): boolean => fx.conns.length === 1, 'first connection');
      expect(rosterCount).assertEqual(1);
      expect(kinds.length).assertEqual(2);
      expect(kinds[0]).assertEqual('runs');
      expect(kinds[1]).assertEqual('routines');
      stream.stop();
      await running;
      offRoster();
      offKind();
    });

    it('holder_count_opens_once_and_closes_on_last_release', 0, async () => {
      const fx = new OpenFixture((conn: FakeConn): void => {});
      const release1 = holdRoster(fx.open);
      const stream = activeRosterStream();
      expect(stream !== null).assertTrue();
      const release2 = holdRoster(fx.open);
      expect(activeRosterStream()).assertEqual(stream);
      release1();
      expect(activeRosterStream()).assertEqual(stream);
      release2();
      expect(activeRosterStream()).assertNull();
      expect(stream!.stopped).assertTrue();
    });

    it('never_opened_backoff_is_exponential_1s_to_30s', 0, async () => {
      const fx = new OpenFixture((conn: FakeConn): void => {
        conn.rejectDone(new RpcError('connection dropped', 0, '', -1, true, false));
      });
      const stream = new RosterStream();
      const delays: number[] = [];
      stream.wait = async (ms: number): Promise<void> => {
        delays.push(ms);
        if (delays.length >= 6) {
          stream.stop();
        }
      };
      await stream.follow(fx.open);
      expect(delays.length).assertEqual(6);
      let retry = 1000;
      for (const delay of delays) {
        // jitterMs keeps the wait between half and all of the backoff.
        expect(delay >= retry / 2).assertTrue();
        expect(delay <= retry).assertTrue();
        retry = Math.min(retry * 2, 30000);
      }
    });

    it('opened_reconnect_uses_the_0_to_5s_spread', 0, async () => {
      const fx = new OpenFixture((conn: FakeConn): void => {
        conn.emit('roster');
        conn.resolveDone();
      });
      const stream = new RosterStream();
      const delays: number[] = [];
      stream.wait = async (ms: number): Promise<void> => {
        delays.push(ms);
        if (delays.length >= 6) {
          stream.stop();
        }
      };
      await stream.follow(fx.open);
      expect(delays.length).assertEqual(6);
      for (const delay of delays) {
        expect(delay >= 0).assertTrue();
        expect(delay <= 5000).assertTrue();
      }
    });

    it('non_retryable_4xx_holds_until_identity_changes', 0, async () => {
      const fx = new OpenFixture((conn: FakeConn): void => {
        conn.rejectDone(new RpcError('forbidden', 403));
      });
      const stream = new RosterStream();
      const running = stream.follow(fx.open);
      await waitFor((): boolean => fx.conns.length === 1, 'first refusal');
      // A refusal is the server's answer: asking again only polls, so it waits.
      await pause(120);
      expect(fx.conns.length).assertEqual(1);
      setSelectedSpace('space-other');
      await waitFor((): boolean => fx.conns.length >= 2, 'reopen after identity change');
      stream.stop();
      await running;
    });

    it('session_change_reopens_the_stream', 0, async () => {
      const fx = new OpenFixture((conn: FakeConn): void => {});
      const stream = new RosterStream();
      const running = stream.follow(fx.open);
      await waitFor((): boolean => fx.conns.length === 1, 'first connection');
      await saveSessionToken('new-token');
      await waitFor((): boolean => fx.conns.length >= 2, 'reopen after session change');
      stream.stop();
      await running;
    });

    it('stop_ends_the_loop_and_closes_the_connection', 0, async () => {
      const fx = new OpenFixture((conn: FakeConn): void => {});
      const stream = new RosterStream();
      const running = stream.follow(fx.open);
      await waitFor((): boolean => fx.conns.length === 1, 'first connection');
      stream.stop();
      await running;
      expect(stream.stopped).assertTrue();
      expect(fx.conns.length).assertEqual(1);
    });
  });
}
