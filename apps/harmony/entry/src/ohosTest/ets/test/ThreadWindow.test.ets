// The history window (design §9 R4), pure logic: loaded history caps at 1,000 durable messages,
// the OLD end survives (that is where paging reads), the newest side is evicted and reachable
// through Jump to latest, live rows always survive, and the gap affordance tracks the eviction.
import { describe, expect, it } from '@ohos/hypium';
import { HISTORY_WINDOW_MESSAGES, historyGapAtEnd, trimHistoryWindow } from '../../../main/ets/thread/thread-window';
import type { LiveMessage, ThreadSnapshot } from '../../../main/ets/thread/thread-snapshot';

function message(seq: number): LiveMessage {
  const block: Record<string, Object> = {};
  block['kind'] = 'text';
  block['text'] = `history ${seq}`;
  return {
    id: `m${seq}`, threadId: 't1', seq: seq, role: 'user', blocks: [block],
    createdAt: '2026-11-22T10:00:00Z',
  };
}

function liveRow(id: string): LiveMessage {
  const block: Record<string, Object> = {};
  block['kind'] = 'progress';
  block['text'] = 'streaming';
  return { id: id, threadId: 't1', role: 'bot', blocks: [block], createdAt: '2026-11-22T10:00:00Z' };
}

function snapshotOf(messages: LiveMessage[], olderCursor: number | null, cursor: number): ThreadSnapshot {
  return { threadId: 't1', cursor: cursor, olderCursor: olderCursor, messages: messages, run: null, activeRuns: [] };
}

function range(from: number, to: number): LiveMessage[] {
  const messages: LiveMessage[] = [];
  for (let seq = from; seq <= to; seq += 1) {
    messages.push(message(seq));
  }
  return messages;
}

export default function threadWindowTest() {
  describe('ThreadHistoryWindow', () => {
    it('under_the_cap_the_snapshot_is_untouched', 0, () => {
      const snapshot = snapshotOf(range(1, HISTORY_WINDOW_MESSAGES), null, HISTORY_WINDOW_MESSAGES);
      expect(trimHistoryWindow(snapshot) === snapshot).assertEqual(true);
      expect(historyGapAtEnd(snapshot, HISTORY_WINDOW_MESSAGES)).assertEqual(false);
      expect(historyGapAtEnd(null, 100)).assertEqual(false);
    });

    it('over_the_cap_the_newest_side_is_evicted_and_the_old_end_survives', 0, () => {
      // A prepend landed while 1,000 were loaded: 1,100 durable + a live progress row.
      const messages = range(1, HISTORY_WINDOW_MESSAGES + 100);
      messages.push(liveRow('progress:run-1'));
      const snapshot = snapshotOf(messages, 1, HISTORY_WINDOW_MESSAGES + 100);
      const trimmed = trimHistoryWindow(snapshot);
      // The oldest 1,000 stay (the reading position is at the old end); the newest 100 go.
      expect(trimmed.messages.length).assertEqual(HISTORY_WINDOW_MESSAGES + 1);
      expect(trimmed.messages[0].id).assertEqual('m1');
      expect(trimmed.messages[HISTORY_WINDOW_MESSAGES - 1].id).assertEqual(`m${HISTORY_WINDOW_MESSAGES}`);
      expect(trimmed.messages[HISTORY_WINDOW_MESSAGES].id).assertEqual('progress:run-1');
      // olderCursor still points below the oldest loaded message — the next page reads on.
      expect(trimmed.olderCursor).assertEqual(1);
      // The event cursor and run state are untouched.
      expect(trimmed.cursor).assertEqual(snapshot.cursor);
      expect(trimmed.run).assertEqual(null);
      // Idempotent: a second pass changes nothing.
      expect(trimHistoryWindow(trimmed) === trimmed).assertEqual(true);
    });

    it('the_gap_affordance_tracks_the_newest_side', 0, () => {
      // Window slid back: newest held seq 9900, newest ever seen 10000 → offer the jump.
      const slid = snapshotOf(range(8901, 9900), 8901, 10_000);
      expect(historyGapAtEnd(slid, 10_000)).assertEqual(true);
      // Back at the recent page: no gap even though the event cursor is far ahead.
      const recent = snapshotOf(range(9901, 10_000), 9901, 10_000);
      expect(historyGapAtEnd(recent, 10_000)).assertEqual(false);
      // An empty transcript (open in flight) never offers the jump.
      expect(historyGapAtEnd(snapshotOf([], null, 0), -1)).assertEqual(false);
    });
  });
}
