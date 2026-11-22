// threads/get + threads/messages decoders for the reducer's snapshot shape. Per-entry discipline
// (design §6.4): a message that cannot decode is dropped, not fatal; its blocks stay raw records —
// the render layer decodes each block and degrades unknown kinds to a placeholder. The layer-1
// snapshots pin exactly these consumed views to the real contract schemas.
import { asRecord } from '../contract/decode';
import type { LiveMessage, LiveRun, ThreadSnapshot } from './thread-snapshot';

function readString(record: Record<string, Object>, key: string): string | null {
  const value = record[key];
  return typeof value === 'string' ? value as string : null;
}

function readNullableString(record: Record<string, Object>, key: string): string | null | undefined {
  const value = record[key];
  if (value === null || value === undefined) {
    return null;
  }
  return typeof value === 'string' ? value as string : undefined;
}

function readOptionalString(record: Record<string, Object>, key: string): string | undefined {
  const value = record[key];
  return typeof value === 'string' ? value as string : undefined;
}

function readNumber(record: Record<string, Object>, key: string): number | null {
  const value = record[key];
  return typeof value === 'number' ? value as number : null;
}

/** A run record from threads/get. Required fields fail the row; optional ones are tolerated. */
export function decodeRun(json: Object | null): LiveRun | null {
  const record = asRecord(json);
  if (record === null) {
    return null;
  }
  const id = readString(record, 'id');
  const botId = readString(record, 'botId');
  const threadId = readString(record, 'threadId');
  const taskId = readString(record, 'taskId');
  const status = readString(record, 'status');
  const trigger = readString(record, 'trigger');
  const routineId = readNullableString(record, 'routineId');
  const modelProvider = readNullableString(record, 'modelProvider');
  const modelId = readNullableString(record, 'modelId');
  const error = readNullableString(record, 'error');
  const startedAt = readNullableString(record, 'startedAt');
  const completedAt = readNullableString(record, 'completedAt');
  const createdAt = readString(record, 'createdAt');
  if (id === null || !id || botId === null || !botId || threadId === null || !threadId
    || taskId === null || !taskId || status === null || trigger === null
    || routineId === undefined || modelProvider === undefined || modelId === undefined
    || error === undefined || startedAt === undefined || completedAt === undefined
    || createdAt === null) {
    return null;
  }
  const run: LiveRun = {
    id: id, botId: botId, threadId: threadId, taskId: taskId, status: status, trigger: trigger,
    routineId: routineId, modelProvider: modelProvider, modelId: modelId, error: error,
    startedAt: startedAt, completedAt: completedAt, createdAt: createdAt,
  };
  const userId = readOptionalString(record, 'userId');
  if (userId !== undefined) {
    run.userId = userId;
  }
  const routineName = readOptionalString(record, 'routineName');
  if (routineName !== undefined) {
    run.routineName = routineName;
  }
  return run;
}

function decodeRuns(json: Object | null): LiveRun[] | null {
  if (json === null || json === undefined || !Array.isArray(json)) {
    return null;
  }
  const runs: LiveRun[] = [];
  for (const item of json as Object[]) {
    const run = decodeRun(item);
    if (run !== null) {
      runs.push(run);
    }
  }
  return runs;
}

/**
 * A message row from threads/get or threads/messages. Blocks stay raw records; an entry that is
 * not an object is dropped (the render layer never sees it). seq is the message's own sequence.
 */
export function decodeThreadMessage(json: Object | null): LiveMessage | null {
  const record = asRecord(json);
  if (record === null) {
    return null;
  }
  const id = readString(record, 'id');
  const threadId = readString(record, 'threadId');
  const seq = readNumber(record, 'seq');
  const role = readString(record, 'role');
  const createdAt = readString(record, 'createdAt');
  const blocksRaw = record['blocks'];
  if (id === null || !id || threadId === null || !threadId || seq === null || role === null
    || createdAt === null || !Array.isArray(blocksRaw)) {
    return null;
  }
  const blocks: Record<string, Object>[] = [];
  for (const item of blocksRaw as Object[]) {
    const block = asRecord(item);
    if (block !== null) {
      blocks.push(block);
    }
  }
  const message: LiveMessage = {
    id: id, threadId: threadId, seq: seq, role: role, blocks: blocks, createdAt: createdAt,
  };
  const botId = readOptionalString(record, 'botId');
  if (botId !== undefined) {
    message.botId = botId;
  }
  const runId = readOptionalString(record, 'runId');
  if (runId !== undefined) {
    message.runId = runId;
  }
  const callId = readOptionalString(record, 'callId');
  if (callId !== undefined) {
    message.callId = callId;
  }
  const author = asRecord(record['author']);
  if (author !== null) {
    message.author = author;
  }
  return message;
}

function decodeMessages(json: Object | null): LiveMessage[] | null {
  if (json === null || json === undefined || !Array.isArray(json)) {
    return null;
  }
  const messages: LiveMessage[] = [];
  for (const item of json as Object[]) {
    const message = decodeThreadMessage(item);
    if (message !== null) {
      messages.push(message);
    }
  }
  return messages;
}

/** activeRuns defaults to [run] (core activeThreadRuns), matching a snapshot that omits it. */
function runsOrPrimary(run: LiveRun | null, activeRuns: LiveRun[] | null): LiveRun[] {
  if (activeRuns !== null) {
    return activeRuns;
  }
  return run !== null ? [run] : [];
}

/** threads/get → the reducer's snapshot. cursor absent reads -1 (core cursor ?? -1). */
export function decodeThreadSnapshot(json: Object | null): ThreadSnapshot | null {
  const record = asRecord(json);
  if (record === null) {
    return null;
  }
  const threadId = readString(record, 'threadId');
  const messages = decodeMessages(record['messages']);
  const olderCursorRaw = record['olderCursor'];
  const olderCursor = olderCursorRaw === null || olderCursorRaw === undefined
    ? null
    : typeof olderCursorRaw === 'number' ? olderCursorRaw as number : undefined;
  if (threadId === null || !threadId || messages === null || olderCursor === undefined) {
    return null;
  }
  const cursor = readNumber(record, 'cursor') ?? -1;
  const runRaw = record['run'];
  const run = runRaw === null || runRaw === undefined ? null : decodeRun(runRaw);
  if (runRaw !== null && runRaw !== undefined && run === null) {
    return null;
  }
  const activeRunsRaw = record['activeRuns'];
  const activeRuns = activeRunsRaw === null || activeRunsRaw === undefined
    ? null : decodeRuns(activeRunsRaw);
  const snapshot: ThreadSnapshot = {
    threadId: threadId, cursor: cursor, olderCursor: olderCursor, messages: messages,
    run: run, activeRuns: runsOrPrimary(run, activeRuns),
  };
  const botId = readOptionalString(record, 'botId');
  if (botId !== undefined) {
    snapshot.botId = botId;
  }
  const groupId = readOptionalString(record, 'groupId');
  if (groupId !== undefined) {
    snapshot.groupId = groupId;
  }
  return snapshot;
}

export interface ThreadMessagePage {
  threadId: string;
  messages: LiveMessage[];
  olderCursor: number | null;
}

/** threads/messages → a history page (prependThreadHistoryPage consumes it in the UI stage). */
export function decodeThreadMessagePage(json: Object | null): ThreadMessagePage | null {
  const record = asRecord(json);
  if (record === null) {
    return null;
  }
  const threadId = readString(record, 'threadId');
  const messages = decodeMessages(record['messages']);
  const olderCursorRaw = record['olderCursor'];
  const olderCursor = olderCursorRaw === null || olderCursorRaw === undefined
    ? null
    : typeof olderCursorRaw === 'number' ? olderCursorRaw as number : undefined;
  if (threadId === null || !threadId || messages === null || olderCursor === undefined) {
    return null;
  }
  const page: ThreadMessagePage = { threadId: threadId, messages: messages, olderCursor: olderCursor };
  return page;
}
