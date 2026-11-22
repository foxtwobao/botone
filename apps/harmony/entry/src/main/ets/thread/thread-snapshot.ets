// M3 vertical-slice reducer (design §7.2 spike): the receipt → progress → run-end → refresh/live
// race path of packages/core/src/threads/thread-snapshot-events.ts, ported 1:1 where the slice
// reaches. Blocks stay raw JSON records — the reducer's behavior never reads inside a block except
// the subagent identity, so decode belongs to the render layer (three-tier degradation), not here.
// The spike measured this port's throughput; m3-notes records the boundary decision it produced.
// The full cluster port (waiting_input/takeover, subagents, cloud agents, helper settlement,
// member status, history merge) lands in the reducer-port stage on top of these same types.

/** A run as live events report it; absent optional fields carry TS `undefined` semantics. */
export interface LiveRun {
  id: string;
  botId: string;
  threadId: string;
  taskId: string;
  status: string;
  trigger: string;
  routineId: string | null;
  routineName?: string;
  userId?: string;
  modelProvider: string | null;
  modelId: string | null;
  error: string | null;
  startedAt: string | null;
  completedAt: string | null;
  createdAt: string;
}

/** A message between refreshes; live rows (progress:) have no message seq. */
export interface LiveMessage {
  id: string;
  threadId: string;
  seq?: number;
  role: string;
  blocks: Record<string, Object>[];
  botId?: string;
  runId?: string;
  callId?: string;
  author?: Record<string, Object>;
  createdAt: string;
}

/** The parts of a thread snapshot live events patch (core LiveThreadSnapshot). */
export interface ThreadSnapshot {
  threadId: string;
  groupId?: string;
  botId?: string;
  cursor: number;
  olderCursor: number | null;
  messages: LiveMessage[];
  run: LiveRun | null;
  activeRuns: LiveRun[];
}

/** One live stream event (core ThreadSnapshotEvent); payload stays a raw record. */
export interface ThreadEvent {
  type: string;
  id?: string;
  seq?: number;
  threadId?: string;
  botId?: string;
  runId?: string;
  createdAt?: string;
  payload: Record<string, Object>;
}

export const RUN_TRIGGERS: string[] = [
  'user', 'routine', 'resume', 'follow_up', 'reaction', 'call_end', 'spawn', 'skill',
  'bot_message', 'webhook', 'messaging', 'cloud_agent', 'purchase', 'media', 'created',
  'tickets', 'helper', 'helper_result',
];

const ACTIVE_STATUSES: string[] = ['queued', 'leased', 'running', 'waiting_input', 'waiting_takeover'];
/** Runs that hold new work in the queue. A pending card holds no compute. */
const QUEUE_HOLDING_STATUSES: string[] = ['queued', 'leased', 'running', 'waiting_takeover'];

export function isActive(status: string): boolean {
  return ACTIVE_STATUSES.includes(status);
}

export function isRunTerminalEvent(event: ThreadEvent): boolean {
  return event.type === 'run.completed' || event.type === 'run.failed' || event.type === 'run.cancelled';
}

export function progressMessageId(event: ThreadEvent): string {
  return `progress:${event.runId ?? event.id ?? 'live'}`;
}

function payloadString(payload: Record<string, Object>, key: string): string | undefined {
  const value = payload[key];
  return typeof value === 'string' ? value as string : undefined;
}

/** A run failure clamped for display, or null (core runFailureError, minus the fallback envelope
 * re-serialization the slice's scenarios do not reach; the full port carries it). */
export function runFailureError(event: ThreadEvent): string | null {
  if (event.type !== 'run.failed') {
    return null;
  }
  const error = payloadString(event.payload, 'error');
  if (error === undefined || !error.trim()) {
    return null;
  }
  const message = error.trim();
  return message.length > 300 ? `${message.slice(0, 300)}…` : message;
}

/** Remove this run's live message and obsolete unscoped progress without reordering history. */
function takeLiveMessage(messages: LiveMessage[], liveId: string): LiveMessage[] {
  const remaining: LiveMessage[] = [];
  for (const message of messages) {
    if (message.id === liveId) {
      continue;
    }
    if (!message.id.startsWith('progress:') || message.runId) {
      remaining.push(message);
    }
  }
  return remaining;
}

function previousLiveMessage(messages: LiveMessage[], liveId: string): LiveMessage | null {
  for (const message of messages) {
    if (message.id === liveId) {
      return message;
    }
  }
  return null;
}

function upsertMessageById(messages: LiveMessage[], next: LiveMessage): LiveMessage[] {
  const index = messages.findIndex((message: LiveMessage): boolean => message.id === next.id);
  if (index < 0) {
    return [...messages, next];
  }
  const updated = [...messages];
  updated[index] = next;
  return updated;
}

// ---------------------------------------------------------------- live blocks (core events.ts)

function blockText(block: Record<string, Object>): string {
  const text = block['text'];
  return typeof text === 'string' ? text as string : '';
}

function blockKind(block: Record<string, Object>): string {
  const kind = block['kind'];
  return typeof kind === 'string' ? kind as string : '';
}

function liveMessageText(blocks: Record<string, Object>[]): string {
  let text = '';
  for (const block of blocks) {
    if (blockKind(block) === 'text' || blockKind(block) === 'progress') {
      text += blockText(block);
    }
  }
  return text;
}

const SENTENCE_END = /[.!?]["'”’)\]]*\s*$/;

/** True once text ends at a sentence boundary (or is empty) — safe to flush mid-clause never. */
export function endsSentence(text: string): boolean {
  return text.trim() === '' || SENTENCE_END.test(text);
}

export function progressMessageText(payload: Record<string, Object>, previousText: string): string {
  const delta = payload['delta'];
  if (typeof delta === 'string') {
    return previousText + (delta as string);
  }
  const text = payload['text'];
  return text === null || text === undefined ? '' : String(text);
}

export function humanizeToolName(name: string): string {
  const spaced = name.replace(/_/g, ' ').trim();
  if (!spaced) {
    return name;
  }
  const lower = spaced.toLowerCase();
  return lower.charAt(0).toUpperCase() + lower.slice(1);
}

interface ToolStep {
  label: string;
  count: number;
}

function readSteps(block: Record<string, Object>): ToolStep[] {
  const raw = block['steps'];
  if (!Array.isArray(raw)) {
    return [];
  }
  const steps: ToolStep[] = [];
  for (const item of raw as Object[]) {
    const record = item as Record<string, Object>;
    const label = record['label'];
    const count = record['count'];
    if (typeof label === 'string' && typeof count === 'number') {
      const step: ToolStep = { label: label as string, count: count as number };
      steps.push(step);
    }
  }
  return steps;
}

function stepsBlock(steps: ToolStep[]): Record<string, Object> {
  const raw: Object[] = [];
  for (const step of steps) {
    const record: Record<string, Object> = {};
    record['label'] = step.label;
    record['count'] = step.count;
    raw.push(record);
  }
  const block: Record<string, Object> = {};
  block['kind'] = 'steps';
  block['steps'] = raw;
  return block;
}

function appendToolStep(steps: ToolStep[], toolName: string): ToolStep[] {
  const label = humanizeToolName(toolName);
  const last = steps.length > 0 ? steps[steps.length - 1] : null;
  if (last !== null && last.label === label) {
    const merged: ToolStep = { label: label, count: last.count + 1 };
    return [...steps.slice(0, -1), merged];
  }
  const first: ToolStep = { label: label, count: 1 };
  return [...steps, first];
}

function appendTextSegment(segments: Record<string, Object>[], text: string): Record<string, Object>[] {
  if (!text) {
    return [...segments];
  }
  const last = segments.length > 0 ? segments[segments.length - 1] : null;
  if (last !== null && blockKind(last) === 'text') {
    const merged: Record<string, Object> = {};
    merged['kind'] = 'text';
    merged['text'] = blockText(last) + text;
    return [...segments.slice(0, -1), merged];
  }
  const block: Record<string, Object> = {};
  block['kind'] = 'text';
  block['text'] = text;
  return [...segments, block];
}

function appendToolCallSegment(segments: Record<string, Object>[], toolName: string): Record<string, Object>[] {
  const last = segments.length > 0 ? segments[segments.length - 1] : null;
  const priorSteps = last !== null && blockKind(last) === 'steps' ? readSteps(last) : [];
  const steps = appendToolStep(priorSteps, toolName);
  if (last !== null && blockKind(last) === 'steps') {
    return [...segments.slice(0, -1), stepsBlock(steps)];
  }
  return [...segments, stepsBlock(steps)];
}

function pendingNames(block: Record<string, Object> | null): string[] {
  if (block === null || blockKind(block) !== 'progress') {
    return [];
  }
  const raw = block['pendingToolNames'];
  if (!Array.isArray(raw)) {
    return [];
  }
  const names: string[] = [];
  for (const item of raw as Object[]) {
    if (typeof item === 'string') {
      names.push(item as string);
    }
  }
  return names;
}

/**
 * Fold one progress delta or tool call into the live message's blocks (core
 * reduceLiveMessageBlocks): a reset drops streamed text and keeps the steps; pending tools flush
 * at a sentence boundary; otherwise the tail progress block grows.
 */
export function reduceLiveMessageBlocks(current: Record<string, Object>[],
  kind: 'progress' | 'tool', payload: Record<string, Object>, toolName: string): Record<string, Object>[] {
  let blocks = current;
  if (kind === 'progress' && payload['reset'] === true) {
    const waiting = blocks.length > 0 && blockKind(blocks[blocks.length - 1]) === 'progress'
      ? blocks[blocks.length - 1] : null;
    blocks = blocks.filter((block: Record<string, Object>): boolean =>
      blockKind(block) !== 'text' && blockKind(block) !== 'progress');
    for (const name of pendingNames(waiting)) {
      blocks = appendToolCallSegment(blocks, name);
    }
  }
  const tail = blocks.length > 0 ? blocks[blocks.length - 1] : null;
  const tailProgress: Record<string, Object> | null =
    tail !== null && blockKind(tail) === 'progress' ? tail : null;
  const segments = tailProgress !== null ? blocks.slice(0, -1) : blocks;
  const priorText = liveMessageText(blocks);
  const tailLength: number = tailProgress !== null ? blockText(tailProgress).length : 0;
  const flushedLength = tailProgress !== null ? priorText.length - tailLength : priorText.length;
  const tailText = kind === 'progress'
    ? progressMessageText(payload, priorText).slice(flushedLength)
    : tailProgress !== null ? blockText(tailProgress) : '';
  const pendingToolNames = [...pendingNames(tailProgress), ...(kind === 'tool' ? [toolName] : [])];
  const activity = kind === 'progress'
    ? payload['activity'] === true
    : tailProgress !== null && tailProgress['activity'] === true;
  const shown = kind === 'progress'
    ? payload['shown'] === true
    : tailProgress !== null && tailProgress['shown'] === true;

  if (pendingToolNames.length > 0 && endsSentence(tailText)) {
    let next = activity ? [...segments] : appendTextSegment(segments, tailText);
    for (const name of pendingToolNames) {
      next = appendToolCallSegment(next, name);
    }
    return next;
  }
  if (!tailText) {
    return [...segments];
  }
  const progress: Record<string, Object> = {};
  progress['kind'] = 'progress';
  progress['text'] = tailText;
  if (activity) {
    progress['activity'] = true;
  }
  if (shown) {
    progress['shown'] = true;
  }
  if (pendingToolNames.length > 0) {
    progress['pendingToolNames'] = pendingToolNames;
  }
  return [...segments, progress];
}

// ---------------------------------------------------------------- reducer

function runFromStartedEvent(event: ThreadEvent, runId: string, previous: LiveRun | null): LiveRun {
  const trigger = payloadString(event.payload, 'trigger');
  const routineId = payloadString(event.payload, 'routineId');
  const routineName = payloadString(event.payload, 'routineName');
  const userId = payloadString(event.payload, 'userId');
  const run: LiveRun = {
    id: runId,
    botId: event.botId ?? previous?.botId ?? '',
    threadId: event.threadId ?? previous?.threadId ?? '',
    taskId: previous?.taskId ?? runId,
    status: 'running',
    trigger: trigger !== undefined && RUN_TRIGGERS.includes(trigger)
      ? trigger : (previous?.trigger ?? 'user'),
    routineId: routineId !== undefined ? routineId : (previous?.routineId ?? null),
    modelProvider: previous?.modelProvider ?? null,
    modelId: previous?.modelId ?? null,
    error: null,
    startedAt: previous?.startedAt ?? event.createdAt ?? null,
    completedAt: null,
    createdAt: previous?.createdAt ?? event.createdAt ?? '',
  };
  if (routineName !== undefined) {
    run.routineName = routineName;
  } else if (previous?.routineName !== undefined) {
    run.routineName = previous.routineName;
  }
  if (userId !== undefined) {
    run.userId = userId;
  } else if (previous?.userId !== undefined) {
    run.userId = previous.userId;
  }
  return run;
}

function liveRow(prev: ThreadSnapshot, event: ThreadEvent, id: string,
  blocks: Record<string, Object>[]): LiveMessage {
  const row: LiveMessage = {
    id: id,
    threadId: event.threadId ?? prev.threadId,
    role: 'bot',
    blocks: blocks,
    createdAt: event.createdAt ?? '',
  };
  if (event.botId !== undefined) {
    row.botId = event.botId;
  }
  if (event.runId !== undefined) {
    row.runId = event.runId;
  }
  return row;
}

/**
 * Apply one live event (core reduceThreadSnapshot, slice branches). Returns the same object when
 * nothing changed so callers can skip a commit; the cursor advances on every applied event.
 */
export function reduceThreadSnapshot(prev: ThreadSnapshot | null, event: ThreadEvent): ThreadSnapshot | null {
  if (prev === null) {
    return null;
  }
  // A refresh can outrun the stream, which then delivers events the snapshot already holds.
  if (event.seq !== undefined && event.seq <= prev.cursor) {
    return prev;
  }
  const payload = event.payload;
  const cursor = event.seq ?? prev.cursor;

  if (event.type === 'thread.cleared') {
    const cleared: ThreadSnapshot = {
      threadId: prev.threadId, cursor: cursor, olderCursor: null, messages: [], run: null, activeRuns: [],
    };
    if (prev.botId !== undefined) {
      cleared.botId = prev.botId;
    }
    if (prev.groupId !== undefined) {
      cleared.groupId = prev.groupId;
    }
    return cleared;
  }
  if (event.type === 'run.started') {
    // Background runs (ticket work) stay invisible; guard a late arrival.
    if (payloadString(payload, 'trigger') === 'tickets') {
      return advance(prev, cursor);
    }
    if (event.runId === undefined) {
      return advance(prev, cursor);
    }
    const runId = event.runId;
    const previousRun = prev.activeRuns.find((candidate: LiveRun): boolean => candidate.id === runId)
      ?? (prev.run !== null && prev.run.id === runId ? prev.run : null);
    const run = runFromStartedEvent(event, runId, previousRun);
    if (run.userId === undefined && prev.run !== null && prev.run.id === run.id
      && prev.run.userId !== undefined) {
      run.userId = prev.run.userId;
    }
    // Paused cards remain answerable when new work starts in any thread.
    const activeRuns = [
      ...prev.activeRuns.filter((candidate: LiveRun): boolean =>
        candidate.id !== run.id && isActive(candidate.status)),
      run,
    ];
    // A group failure lives only in run; keep it until dismiss so a late member start cannot
    // wipe the banner (activeRuns still tracks the new work).
    const keepFailedGroup = prev.groupId !== undefined && prev.run !== null
      && prev.run.status === 'failed' && prev.run.id !== run.id;
    const next: ThreadSnapshot = {
      threadId: prev.threadId, cursor: cursor, olderCursor: prev.olderCursor,
      messages: prev.messages, run: keepFailedGroup ? prev.run : run, activeRuns: activeRuns,
    };
    if (prev.botId !== undefined) {
      next.botId = prev.botId;
    }
    if (prev.groupId !== undefined) {
      next.groupId = prev.groupId;
    }
    return next;
  }
  if (isRunTerminalEvent(event)) {
    const activeRuns = prev.activeRuns.filter((candidate: LiveRun): boolean => candidate.id !== event.runId);
    const failure = runFailureError(event);
    const primaryEnded = prev.run !== null && prev.run.id === event.runId ? prev.run : null;
    // In a group the failing run may be a member run; look it up in activeRuns too.
    const endedRun = primaryEnded
      ?? prev.activeRuns.find((candidate: LiveRun): boolean => candidate.id === event.runId)
      ?? null;
    let run: LiveRun | null;
    if (endedRun !== null && failure !== null) {
      const failed: LiveRun = {
        id: endedRun.id, botId: endedRun.botId, threadId: endedRun.threadId, taskId: endedRun.taskId,
        status: 'failed', trigger: endedRun.trigger, routineId: endedRun.routineId,
        modelProvider: endedRun.modelProvider, modelId: endedRun.modelId, error: failure,
        startedAt: endedRun.startedAt, completedAt: endedRun.completedAt, createdAt: endedRun.createdAt,
      };
      if (endedRun.routineName !== undefined) {
        failed.routineName = endedRun.routineName;
      }
      if (endedRun.userId !== undefined) {
        failed.userId = endedRun.userId;
      }
      run = failed;
    } else if (primaryEnded !== null) {
      run = activeRuns.length > 0 ? activeRuns[0] : null;
    } else {
      run = prev.run;
    }
    const next: ThreadSnapshot = {
      threadId: prev.threadId, cursor: cursor, olderCursor: prev.olderCursor,
      messages: prev.messages.filter((message: LiveMessage): boolean =>
        message.id !== progressMessageId(event)),
      run: run, activeRuns: activeRuns,
    };
    if (prev.botId !== undefined) {
      next.botId = prev.botId;
    }
    if (prev.groupId !== undefined) {
      next.groupId = prev.groupId;
    }
    return next;
  }
  if (event.type === 'agent.tool.called' && payloadString(payload, 'name') === 'ask_user') {
    return advance(prev, cursor);
  }
  if (event.type === 'thread.progress' || event.type === 'agent.tool.called') {
    const liveId = progressMessageId(event);
    const previous = previousLiveMessage(prev.messages, liveId);
    const remaining = takeLiveMessage(prev.messages, liveId);
    const blocks = reduceLiveMessageBlocks(previous?.blocks ?? [],
      event.type === 'thread.progress' ? 'progress' : 'tool', payload,
      payloadString(payload, 'name') ?? '');
    const next: ThreadSnapshot = {
      threadId: prev.threadId, cursor: cursor, olderCursor: prev.olderCursor,
      messages: [...remaining, liveRow(prev, event, liveId, blocks)],
      run: prev.run, activeRuns: prev.activeRuns,
    };
    if (prev.botId !== undefined) {
      next.botId = prev.botId;
    }
    if (prev.groupId !== undefined) {
      next.groupId = prev.groupId;
    }
    return next;
  }
  if (event.type === 'agent.tool.completed') {
    return advance(prev, cursor);
  }
  if (event.type === 'thread.message.created' || event.type === 'thread.message.updated') {
    const blocksRaw = payload['blocks'];
    const blocks: Record<string, Object>[] = Array.isArray(blocksRaw)
      ? (blocksRaw as Object[]).map((item: Object): Record<string, Object> => item as Record<string, Object>)
      : [];
    const messageId = payloadString(payload, 'messageId');
    const id = messageId ?? event.id ?? `msg:${cursor}`;
    const known = prev.messages.find((message: LiveMessage): boolean => message.id === id) ?? null;
    const seqRaw = payload['seq'];
    const seq = typeof seqRaw === 'number' ? seqRaw as number : known?.seq;
    const role = payloadString(payload, 'role') ?? 'bot';
    const next: LiveMessage = {
      id: id,
      threadId: known?.threadId ?? event.threadId ?? prev.threadId,
      role: role,
      blocks: blocks,
      createdAt: known?.createdAt ?? event.createdAt ?? '',
    };
    if (seq !== undefined) {
      next.seq = seq;
    }
    const botId = event.botId ?? payloadString(payload, 'botId');
    if (botId !== undefined) {
      next.botId = botId;
    }
    if (event.runId !== undefined) {
      next.runId = event.runId;
    }
    const callId = payloadString(payload, 'callId') ?? known?.callId;
    if (callId !== undefined) {
      next.callId = callId;
    }
    const authorRaw = payload['author'];
    const author = authorRaw !== null && authorRaw !== undefined && typeof authorRaw === 'object'
      && !Array.isArray(authorRaw) ? authorRaw as Record<string, Object> : known?.author;
    if (author !== undefined) {
      next.author = author;
    }
    const remaining = takeLiveMessage(prev.messages, progressMessageId(event));
    const without = remaining.filter((message: LiveMessage): boolean => message.id !== id);
    const merged: ThreadSnapshot = {
      threadId: prev.threadId, cursor: cursor, olderCursor: prev.olderCursor,
      messages: upsertMessageById(without, next), run: prev.run, activeRuns: prev.activeRuns,
    };
    if (prev.botId !== undefined) {
      merged.botId = prev.botId;
    }
    if (prev.groupId !== undefined) {
      merged.groupId = prev.groupId;
    }
    return merged;
  }
  // A type this reducer does not know leaves the snapshot whole — the reference returns prev
  // unchanged (the stream's own replay cursor advances regardless; that lives in the stream).
  return prev;
}

function advance(prev: ThreadSnapshot, cursor: number): ThreadSnapshot {
  if (cursor === prev.cursor) {
    return prev;
  }
  const next: ThreadSnapshot = {
    threadId: prev.threadId, cursor: cursor, olderCursor: prev.olderCursor,
    messages: prev.messages, run: prev.run, activeRuns: prev.activeRuns,
  };
  if (prev.botId !== undefined) {
    next.botId = prev.botId;
  }
  if (prev.groupId !== undefined) {
    next.groupId = prev.groupId;
  }
  return next;
}

// ---------------------------------------------------------------- receipt / terminal memory

export interface SendReceipt {
  botId: string;
  runId: string;
  taskId: string;
  createdAt?: string;
}

/**
 * Reflect a committed direct-message send before its follow-up snapshot arrives (core
 * applyThreadSendReceipt). A matching live run always wins; a queue-holding run refuses the
 * receipt; a terminal run the stream already ended never shows as queued again.
 */
export function applyThreadSendReceipt(snapshot: ThreadSnapshot | null, receipt: SendReceipt,
  terminalRunIds: Set<string>, now: string): ThreadSnapshot | null {
  if (snapshot === null || snapshot.groupId !== undefined || snapshot.botId !== receipt.botId
    || (snapshot.run !== null && snapshot.run.id === receipt.runId)
    || terminalRunIds.has(receipt.runId)) {
    return snapshot;
  }
  if (snapshot.activeRuns.some((run: LiveRun): boolean => QUEUE_HOLDING_STATUSES.includes(run.status))) {
    return snapshot;
  }
  const run: LiveRun = {
    id: receipt.runId,
    botId: receipt.botId,
    threadId: snapshot.threadId,
    taskId: receipt.taskId,
    status: 'queued',
    trigger: 'user',
    routineId: null,
    modelProvider: null,
    modelId: null,
    error: null,
    startedAt: null,
    completedAt: null,
    createdAt: receipt.createdAt ?? now,
  };
  const next: ThreadSnapshot = {
    threadId: snapshot.threadId, cursor: snapshot.cursor, olderCursor: snapshot.olderCursor,
    messages: snapshot.messages, run: run,
    activeRuns: [...snapshot.activeRuns.filter((r: LiveRun): boolean => isActive(r.status)), run],
  };
  if (snapshot.botId !== undefined) {
    next.botId = snapshot.botId;
  }
  return next;
}

/** Remember a finished run so a late send receipt cannot show it as queued again (cap 100). */
export function rememberTerminalRun(terminalRunIds: Set<string>, event: ThreadEvent): void {
  if (event.runId === undefined || !isRunTerminalEvent(event)) {
    return;
  }
  terminalRunIds.add(event.runId);
  if (terminalRunIds.size > 100) {
    for (const oldest of terminalRunIds) {
      terminalRunIds.delete(oldest);
      break;
    }
  }
}

// ---------------------------------------------------------------- refresh / live race

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
 * Apply a threads/get refresh (core reconcileRefreshedThread, no computer in Phase 1): an
 * older-cursor refresh hydrates a matching live run without rolling the transcript back, and
 * otherwise keeps the newer live snapshot whole.
 */
export function reconcileRefreshedThread(prev: ThreadSnapshot | null, snap: ThreadSnapshot,
  preserveLoadedHistory: boolean = false): ThreadSnapshot {
  if (prev !== null && prev.threadId === snap.threadId && snap.cursor < prev.cursor) {
    const refreshedRun = snap.run;
    const hasMatchingLiveProgress = refreshedRun !== null && prev.messages.some(
      (message: LiveMessage): boolean =>
        message.runId === refreshedRun.id && message.id === `progress:${refreshedRun.id}`);
    if (prev.run === null && refreshedRun !== null && hasMatchingLiveProgress) {
      const hydrated: ThreadSnapshot = {
        threadId: prev.threadId, cursor: prev.cursor, olderCursor: prev.olderCursor,
        messages: prev.messages, run: refreshedRun, activeRuns: snap.activeRuns,
      };
      if (prev.botId !== undefined) {
        hydrated.botId = prev.botId;
      }
      if (prev.groupId !== undefined) {
        hydrated.groupId = prev.groupId;
      }
      return hydrated;
    }
    return prev;
  }
  return mergeThreadSnapshot(prev, snap, preserveLoadedHistory);
}
