// The refresh / live race, ported from packages/core/src/threads/message-pages.ts and
// thread-snapshot-events.ts (mergeThreadSnapshot / reconcileRefreshedThread): a threads/get refresh
// behind the live cursor must not wipe newer event-sourced state, and a stale equal-cursor refresh
// must not clobber a local waiting_takeover. Split out of thread-snapshot.ets (the 1,000-line cap).
import { blockKind } from './live-blocks';
import { copyRun, isActive, withSnapshot } from './thread-snapshot';
import type { LiveMessage, LiveRun, ThreadSnapshot } from './thread-snapshot';

/** Union by id, first occurrence wins (core mergeMessagesById). */
function mergeMessagesById(first: LiveMessage[], second: LiveMessage[]): LiveMessage[] {
  const seen: Set<string> = new Set();
  const merged: LiveMessage[] = [];
  for (const message of [...first, ...second]) {
    if (!seen.has(message.id)) {
      seen.add(message.id);
      merged.push(message);
    }
  }
  return merged;
}

function isDurableMessage(message: LiveMessage): boolean {
  return !message.id.startsWith('progress:') && !message.id.startsWith('subagent:');
}

/** A recent page can omit SSE rows even while their runs are still streaming. */
function preserveLiveRows(previous: ThreadSnapshot, refreshed: ThreadSnapshot): ThreadSnapshot {
  const runningIds = new Set<string>();
  for (const run of refreshed.activeRuns) {
    if (run.status === 'running') {
      runningIds.add(run.id);
    }
  }
  if (runningIds.size === 0) {
    return refreshed;
  }
  const live = previous.messages.filter((message: LiveMessage): boolean =>
    !isDurableMessage(message) && message.runId !== undefined && runningIds.has(message.runId));
  if (live.length === 0) {
    return refreshed;
  }
  const refreshedIds: Set<string> = new Set();
  for (const message of refreshed.messages) {
    refreshedIds.add(message.id);
    for (const block of message.blocks) {
      if (blockKind(block) === 'subagent' && typeof block['agentId'] === 'string') {
        refreshedIds.add(`subagent:${block['agentId']}`);
      }
    }
  }
  const missing = live.filter((message: LiveMessage): boolean => !refreshedIds.has(message.id));
  if (missing.length === 0) {
    return refreshed;
  }
  return withSnapshot(refreshed, refreshed.cursor, [...refreshed.messages, ...missing],
    refreshed.run, refreshed.activeRuns, refreshed.members);
}

/** Keep loaded history older than the recent page, then the recent page (core mergeMessagePages). */
function mergeMessagePages(previous: LiveMessage[], recent: LiveMessage[]): LiveMessage[] {
  let firstRecentSeq: number | null = null;
  for (const message of recent) {
    if (isDurableMessage(message) && message.seq !== undefined) {
      firstRecentSeq = firstRecentSeq === null ? message.seq : Math.min(firstRecentSeq, message.seq);
    }
  }
  const floor = firstRecentSeq;
  const retained = floor === null ? [] : previous.filter((message: LiveMessage): boolean =>
    isDurableMessage(message) && message.seq !== undefined && message.seq < floor);
  return mergeMessagesById(retained, recent);
}

/** core mergeThreadHistory: same thread + preserveLoadedHistory keeps older pages. */
function mergeThreadHistory(previous: ThreadSnapshot | null, recent: ThreadSnapshot,
  preserveLoadedHistory: boolean): ThreadSnapshot {
  if (previous === null || previous.threadId !== recent.threadId || !preserveLoadedHistory) {
    return recent;
  }
  const merged: ThreadSnapshot = {
    threadId: recent.threadId, cursor: recent.cursor, olderCursor: previous.olderCursor,
    messages: mergeMessagePages(previous.messages, recent.messages),
    run: recent.run, activeRuns: recent.activeRuns,
  };
  if (recent.botId !== undefined) {
    merged.botId = recent.botId;
  }
  if (recent.groupId !== undefined) {
    merged.groupId = recent.groupId;
  }
  if (recent.members !== undefined) {
    merged.members = recent.members;
  }
  return merged;
}

/** core mergeThreadSnapshot: a refresh behind the live cursor must not wipe newer live state. */
export function mergeThreadSnapshot(prev: ThreadSnapshot | null, next: ThreadSnapshot,
  preserveLoadedHistory: boolean = false): ThreadSnapshot {
  if (prev !== null && prev.threadId === next.threadId && prev.cursor > next.cursor) {
    return prev;
  }
  return mergeThreadHistory(prev, next, preserveLoadedHistory);
}

/**
 * Apply a threads/get refresh without clobbering newer event-sourced takeover state (core
 * reconcileRefreshedThread; Phase 1 has no computer field, so its branches drop and only the
 * snapshot reconciliation remains). A refresh that started earlier can still return running
 * after the client applied waiting_takeover; that stale snapshot shares the cursor already
 * applied, and the local waiting status wins until a newer cursor replaces it.
 */
export function reconcileRefreshedThread(prev: ThreadSnapshot | null, snap: ThreadSnapshot,
  preserveLoadedHistory: boolean = false): ThreadSnapshot {
  const sameThread = prev !== null && prev.threadId === snap.threadId;
  if (sameThread && prev !== null && snap.cursor < prev.cursor) {
    // A subscription can advance the cursor with progress before the send-triggered refresh
    // returns the new run record. Hydrate that matching run without rolling the transcript back.
    // Optimistic stop removes the matching progress message, so an older refresh cannot revive it.
    const refreshedRun = snap.run;
    const hasMatchingLiveProgress = refreshedRun !== null && prev.messages.some(
      (message: LiveMessage): boolean =>
        message.runId === refreshedRun.id && message.id === `progress:${refreshedRun.id}`);
    if (prev.run === null && refreshedRun !== null && hasMatchingLiveProgress) {
      return withSnapshot(prev, prev.cursor, prev.messages, refreshedRun, snap.activeRuns, prev.members);
    }
    return prev;
  }
  let snapshot = mergeThreadSnapshot(prev, snap, preserveLoadedHistory);
  const localWaiting = sameThread && prev !== null
    && prev.cursor === snapshot.cursor
    && prev.run !== null && prev.run.status === 'waiting_takeover'
    && snapshot.run !== null && snapshot.run.id === prev.run.id
    && snapshot.run.status !== 'waiting_takeover'
    && isActive(snapshot.run.status);
  if (localWaiting && snapshot.run !== null && prev !== null && prev.run !== null) {
    const runId = snapshot.run.id;
    const waitingRun = copyRun(snapshot.run);
    waitingRun.status = 'waiting_takeover';
    const activeRuns = snapshot.activeRuns.map((run: LiveRun): LiveRun => {
      if (run.id !== runId) {
        return run;
      }
      const updated = copyRun(run);
      updated.status = 'waiting_takeover';
      return updated;
    });
    snapshot = withSnapshot(snapshot, snapshot.cursor, snapshot.messages, waitingRun, activeRuns,
      snapshot.members);
  }
  // Jump to latest replaces the history page, but the open stream still owns its live rows.
  return sameThread && prev !== null ? preserveLiveRows(prev, snapshot) : snapshot;
}
