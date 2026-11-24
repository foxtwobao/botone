// The history window (design §9 R4: memory must not grow linearly with history length). Loaded
// history is capped at N durable messages. Paging back moves the reading position to the OLD
// end, so the window keeps the oldest loaded messages and evicts the NEWEST side — evicting the
// old end would drop the page the reader just loaded. The evicted newest side is reachable
// through the store's jumpToLatest() (one threads/get back to the recent page; core
// leaveThreadWindow's role, Phase 1 shape). Applied at the stream's single commit point, so
// every path that grows the snapshot — open/settle/disconnect refresh, receipt, prepend —
// passes through it.
import type { LiveMessage, ThreadSnapshot } from './thread-snapshot';

/** Ten server pages of 100 (the fixture's THREAD_PAGE_SIZE): ≈1,000 messages, ~10× a screenful
 * of bubbles — far above any reading position, and the scale where the M4 inbox calibration
 * showed the render/allocator high-water mark converge. Measured budget in m4-notes. */
export const HISTORY_WINDOW_MESSAGES = 1000;

function isLiveRow(message: LiveMessage): boolean {
  return message.id.startsWith('progress:') || message.id.startsWith('subagent:');
}

/** Keep the oldest HISTORY_WINDOW_MESSAGES durable messages plus every live row (progress and
 * subagent rows belong to the open run, not to history). olderCursor is untouched — it points
 * below the oldest loaded message, and the old end is what survives. Idempotent; the same
 * snapshot comes back when nothing is evicted. */
export function trimHistoryWindow(snapshot: ThreadSnapshot): ThreadSnapshot {
  let durable = 0;
  for (const message of snapshot.messages) {
    if (!isLiveRow(message)) {
      durable += 1;
    }
  }
  if (durable <= HISTORY_WINDOW_MESSAGES) {
    return snapshot;
  }
  let keep = HISTORY_WINDOW_MESSAGES;
  const messages: LiveMessage[] = [];
  for (const message of snapshot.messages) {
    if (isLiveRow(message)) {
      messages.push(message);
      continue;
    }
    if (keep > 0) {
      keep -= 1;
      messages.push(message);
    }
  }
  const next: ThreadSnapshot = {
    threadId: snapshot.threadId, cursor: snapshot.cursor, olderCursor: snapshot.olderCursor,
    messages: messages, run: snapshot.run, activeRuns: snapshot.activeRuns,
  };
  if (snapshot.botId !== undefined) {
    next.botId = snapshot.botId;
  }
  if (snapshot.groupId !== undefined) {
    next.groupId = snapshot.groupId;
  }
  if (snapshot.members !== undefined) {
    next.members = snapshot.members;
  }
  return next;
}

/** Whether the transcript ends before the newest message this window ever held: history was
 * evicted on the newest side, so "Jump to latest" is the way back to the live page. The floor
 * is the newest message seq ever painted (not the event cursor — run/progress events advance it
 * without a message), so an idle open thread never shows the affordance. */
export function historyGapAtEnd(snapshot: ThreadSnapshot | null, newestSeenSeq: number): boolean {
  if (snapshot === null) {
    return false;
  }
  let newestSeq = -1;
  for (const message of snapshot.messages) {
    if (!isLiveRow(message) && message.seq !== undefined) {
      newestSeq = Math.max(newestSeq, message.seq);
    }
  }
  return newestSeq < newestSeenSeq;
}
