// The client thread reducer cluster, ported from packages/core/src/threads/thread-snapshot-events.ts
// with its events.ts / message-pages.ts / message-replies.ts / run-state.ts helpers (design §4.3:
// port behavior, fixture-aligned). Blocks stay raw JSON records — the reducer reads inside a block
// only for subagent/cloud-agent identity and ask status, so full decode belongs to the render layer
// (three-tier degradation), not here. Not ported (m3-notes records why): projectMessages (server
// replay), thread-window/search-jump paging, tool-history split/replay, secret redaction, the
// durable subscription state machine, computer status, identity-display provenance (a Symbol the
// JSON wire never carries).
import { url } from '@kit.ArkTS';
import { blockKind, reduceLiveMessageBlocks } from './live-blocks';
export { reduceLiveMessageBlocks } from './live-blocks';

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
  replyToMessageId?: string;
  replyQuote?: string;
  replyPreview?: Record<string, Object> | null;
  createdAt: string;
}

/** A group member's live status (the snapshot's members row, status patched by events). */
export interface ThreadMember {
  botId: string;
  name: string;
  color: string;
  status?: string;
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
  members?: ThreadMember[];
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

/** A pause ends the current helper execution, even when the run later resumes (core stopsRunHelpers). */
export function stopsRunHelpers(event: ThreadEvent): boolean {
  return isRunTerminalEvent(event) || event.type === 'run.waiting_input'
    || event.type === 'computer.takeover.requested';
}

/** A question shows as its own card; its call never adds to the live working line. */
export function showsAsLiveStep(toolName: string): boolean {
  return toolName !== 'ask_user';
}

/** Settle a run's still-running subagent cards when it ends or pauses (core settleRunSubagents). */
function settleRunSubagents(messages: LiveMessage[], runId: string | undefined): LiveMessage[] {
  if (runId === undefined) {
    return messages;
  }
  let changed = false;
  const next = messages.map((message: LiveMessage): LiveMessage => {
    if (message.runId !== runId) {
      return message;
    }
    let settled = false;
    const blocks = message.blocks.map((block: Record<string, Object>): Record<string, Object> => {
      if (blockKind(block) !== 'subagent' || block['status'] !== 'running') {
        return block;
      }
      settled = true;
      const updated: Record<string, Object> = {};
      for (const key of Object.keys(block)) {
        updated[key] = block[key];
      }
      updated['status'] = 'failed';
      updated['result'] = 'stopped';
      return updated;
    });
    if (!settled) {
      return message;
    }
    changed = true;
    const updatedMessage: LiveMessage = {
      id: message.id, threadId: message.threadId, role: message.role, blocks: blocks,
      createdAt: message.createdAt,
    };
    copyMessageOptionals(message, updatedMessage);
    return updatedMessage;
  });
  return changed ? next : messages;
}

/** Copy the optional message fields a rebuild must keep (seq/botId/runId/callId/author/reply). */
function copyMessageOptionals(from: LiveMessage, to: LiveMessage): void {
  if (from.seq !== undefined) {
    to.seq = from.seq;
  }
  if (from.botId !== undefined) {
    to.botId = from.botId;
  }
  if (from.runId !== undefined) {
    to.runId = from.runId;
  }
  if (from.callId !== undefined) {
    to.callId = from.callId;
  }
  if (from.author !== undefined) {
    to.author = from.author;
  }
  if (from.replyToMessageId !== undefined) {
    to.replyToMessageId = from.replyToMessageId;
  }
  if (from.replyQuote !== undefined) {
    to.replyQuote = from.replyQuote;
  }
  if (from.replyPreview !== undefined) {
    to.replyPreview = from.replyPreview;
  }
}

/** The author a live message event carries; updates omit it, so keep the known one. */
function payloadAuthor(payload: Record<string, Object>, known: LiveMessage | null): Record<string, Object> | undefined {
  const raw = payload['author'];
  if (raw !== null && raw !== undefined && typeof raw === 'object' && !Array.isArray(raw)) {
    const record = raw as Record<string, Object>;
    if (typeof record['id'] === 'string' && (record['id'] as string).length > 0
      && typeof record['name'] === 'string') {
      return record;
    }
  }
  return known?.author;
}

/** Updates may omit reply metadata; retain it until an authoritative value arrives. */
function applyReplyMetadata(payload: Record<string, Object>, known: LiveMessage | null, next: LiveMessage): void {
  const toId = payloadString(payload, 'replyToMessageId') ?? known?.replyToMessageId;
  if (toId !== undefined) {
    next.replyToMessageId = toId;
  }
  const quote = payloadString(payload, 'replyQuote') ?? known?.replyQuote;
  if (quote !== undefined) {
    next.replyQuote = quote;
  }
  const previewRaw = payload['replyPreview'];
  if (previewRaw === null) {
    next.replyPreview = null;
  } else if (previewRaw !== undefined && typeof previewRaw === 'object' && !Array.isArray(previewRaw)) {
    const preview = previewRaw as Record<string, Object>;
    if (typeof preview['text'] === 'string'
      && (preview['role'] === 'user' || preview['role'] === 'bot' || preview['role'] === 'system')) {
      next.replyPreview = preview;
    } else if (known?.replyPreview !== undefined) {
      next.replyPreview = known.replyPreview;
    }
  } else if (known?.replyPreview !== undefined) {
    next.replyPreview = known.replyPreview;
  }
}

/** Patch one member's status; the same array when nothing changed (core updateMemberStatus). */
function updateMemberStatus(members: ThreadMember[] | undefined, botId: string | undefined,
  status: string): ThreadMember[] | undefined {
  if (botId === undefined || members === undefined) {
    return members;
  }
  const member = members.find((candidate: ThreadMember): boolean => candidate.botId === botId);
  if (member === undefined || member.status === status) {
    return members;
  }
  return members.map((candidate: ThreadMember): ThreadMember => {
    if (candidate.botId !== botId) {
      return candidate;
    }
    const updated: ThreadMember = { botId: candidate.botId, name: candidate.name, color: candidate.color, status: status };
    return updated;
  });
}

/** A snapshot copy with the common fields carried (the port's spread). */
function withSnapshot(prev: ThreadSnapshot, cursor: number, messages: LiveMessage[],
  run: LiveRun | null, activeRuns: LiveRun[], members: ThreadMember[] | undefined): ThreadSnapshot {
  const next: ThreadSnapshot = {
    threadId: prev.threadId, cursor: cursor, olderCursor: prev.olderCursor,
    messages: messages, run: run, activeRuns: activeRuns,
  };
  if (prev.botId !== undefined) {
    next.botId = prev.botId;
  }
  if (prev.groupId !== undefined) {
    next.groupId = prev.groupId;
  }
  if (members !== undefined) {
    next.members = members;
  }
  return next;
}

/** A run copy with its optional fields carried. */
function copyRun(run: LiveRun): LiveRun {
  const copy: LiveRun = {
    id: run.id, botId: run.botId, threadId: run.threadId, taskId: run.taskId, status: run.status,
    trigger: run.trigger, routineId: run.routineId, modelProvider: run.modelProvider, modelId: run.modelId,
    error: run.error, startedAt: run.startedAt, completedAt: run.completedAt, createdAt: run.createdAt,
  };
  if (run.routineName !== undefined) {
    copy.routineName = run.routineName;
  }
  if (run.userId !== undefined) {
    copy.userId = run.userId;
  }
  return copy;
}

function clampRunFailure(message: string): string {
  return message.length > 300 ? `${message.slice(0, 300)}…` : message;
}

interface FallbackBackup {
  provider: string;
  modelId: string;
  reason: string;
  status: string;
}

/** Read a persisted model-fallback failure envelope (core parseModelFallbackFailure). */
function parseModelFallbackFailure(details: string): FallbackBackup[] | null {
  let parsed: Object;
  try {
    parsed = JSON.parse(details.trim());
  } catch (err) {
    return null;
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return null;
  }
  const record = parsed as Record<string, Object>;
  if (record['modelFallbackVersion'] !== 1 || typeof record['primaryError'] !== 'string'
    || !Array.isArray(record['backups']) || (record['backups'] as Object[]).length === 0) {
    return null;
  }
  const backups: FallbackBackup[] = [];
  for (const item of record['backups'] as Object[]) {
    if (item === null || typeof item !== 'object' || Array.isArray(item)) {
      return null;
    }
    const outcome = item as Record<string, Object>;
    if (typeof outcome['provider'] !== 'string' || typeof outcome['modelId'] !== 'string'
      || typeof outcome['reason'] !== 'string'
      || (outcome['status'] !== 'failed' && outcome['status'] !== 'skipped')) {
      return null;
    }
    const backup: FallbackBackup = {
      provider: outcome['provider'] as string, modelId: outcome['modelId'] as string,
      reason: outcome['reason'] as string, status: outcome['status'] as string,
    };
    backups.push(backup);
  }
  return backups;
}

/** A run failure clamped for display, or null (core runFailureError incl. the fallback envelope). */
export function runFailureError(event: ThreadEvent): string | null {
  if (event.type !== 'run.failed') {
    return null;
  }
  const error = payloadString(event.payload, 'error');
  if (error === undefined || !error.trim()) {
    return null;
  }
  const message = error.trim();
  const backups = parseModelFallbackFailure(message);
  if (backups !== null) {
    let primaryError = '';
    try {
      const record = JSON.parse(message) as Record<string, Object>;
      primaryError = record['primaryError'] as string;
    } catch (err) {
      primaryError = '';
    }
    const envelope: Record<string, Object> = {};
    envelope['modelFallbackVersion'] = 1;
    envelope['primaryError'] = clampRunFailure(primaryError);
    const clamped: Object[] = [];
    for (const backup of backups) {
      const item: Record<string, Object> = {};
      item['provider'] = backup.provider;
      item['modelId'] = backup.modelId;
      item['reason'] = clampRunFailure(backup.reason);
      item['status'] = backup.status;
      clamped.push(item);
    }
    envelope['backups'] = clamped;
    return JSON.stringify(envelope);
  }
  return clampRunFailure(message);
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
 * Apply one live event (core reduceThreadSnapshot, full client cluster). Returns the same object
 * when nothing changed so callers can skip a commit; the cursor advances on every applied event.
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
  let base = prev;
  if (stopsRunHelpers(event)) {
    const messages = settleRunSubagents(base.messages, event.runId);
    if (messages !== base.messages) {
      base = withSnapshot(base, base.cursor, messages, base.run, base.activeRuns, base.members);
    }
  }

  if (event.type === 'thread.cleared') {
    const cleared = withSnapshot(base, cursor, [], null, [], base.members);
    cleared.olderCursor = null;
    return cleared;
  }
  if (event.type === 'run.started') {
    // Background runs (ticket work) stay invisible; guard a late arrival.
    if (payloadString(payload, 'trigger') === 'tickets') {
      return advance(base, cursor);
    }
    const members = updateMemberStatus(base.members, event.botId, 'running');
    if (event.runId === undefined) {
      return members === base.members ? advance(base, cursor)
        : withSnapshot(base, cursor, base.messages, base.run, base.activeRuns, members);
    }
    const runId = event.runId;
    const previousRun = base.activeRuns.find((candidate: LiveRun): boolean => candidate.id === runId)
      ?? (base.run !== null && base.run.id === runId ? base.run : null);
    const run = runFromStartedEvent(event, runId, previousRun);
    if (run.userId === undefined && base.run !== null && base.run.id === run.id
      && base.run.userId !== undefined) {
      run.userId = base.run.userId;
    }
    // Paused cards remain answerable when new work starts in any thread.
    const activeRuns = [
      ...base.activeRuns.filter((candidate: LiveRun): boolean =>
        candidate.id !== run.id && isActive(candidate.status)),
      run,
    ];
    // A group failure lives only in run; keep it until dismiss so a late member start cannot
    // wipe the banner (activeRuns still tracks the new work).
    const keepFailedGroup = base.groupId !== undefined && base.run !== null
      && base.run.status === 'failed' && base.run.id !== run.id;
    return withSnapshot(base, cursor, base.messages, keepFailedGroup ? base.run : run, activeRuns, members);
  }
  if (event.type === 'run.waiting_input' || event.type === 'computer.takeover.requested') {
    const status = event.type === 'run.waiting_input' ? 'waiting_input' : 'waiting_takeover';
    const runId = event.runId;
    const payloadUserId = payloadString(payload, 'userId');
    const userId = event.type === 'run.waiting_input' && payloadUserId !== undefined && payloadUserId.length > 0
      ? payloadUserId : undefined;
    const knownInRun = runId !== undefined && base.run !== null && base.run.id === runId;
    const knownInActive = runId !== undefined
      && base.activeRuns.some((candidate: LiveRun): boolean => candidate.id === runId);
    // Peer bot_message runs are omitted from snapshots while busy; the first wait event is how
    // an open thread learns they need ask/takeover UI.
    const needsInsert = runId !== undefined && !knownInRun && !knownInActive;
    const changes = (candidate: LiveRun): boolean =>
      candidate.status !== status || (userId !== undefined && candidate.userId !== userId);
    const runChanged = knownInRun && base.run !== null && changes(base.run);
    const activeRunChanged = knownInActive
      && base.activeRuns.some((candidate: LiveRun): boolean => candidate.id === runId && changes(candidate));
    const members = updateMemberStatus(base.members, event.botId, status);
    // Both pauses delete the run's progress events server-side; drop the live bubble so a
    // missed message.created cannot leave "working…" stuck next to the waiting card.
    const liveId = progressMessageId(event);
    const messages = base.messages.some((message: LiveMessage): boolean => message.id === liveId)
      ? base.messages.filter((message: LiveMessage): boolean => message.id !== liveId)
      : base.messages;
    if (!runChanged && !activeRunChanged && !needsInsert && members === base.members
      && messages === base.messages) {
      return advance(base, cursor);
    }
    const settle = (candidate: LiveRun): LiveRun => {
      const updated = copyRun(candidate);
      updated.status = status;
      if (userId !== undefined) {
        updated.userId = userId;
      }
      return updated;
    };
    if (needsInsert && runId !== undefined) {
      const waitingRun: LiveRun = {
        id: runId,
        botId: event.botId ?? '',
        threadId: event.threadId ?? base.threadId,
        taskId: runId,
        status: status,
        trigger: payloadString(payload, 'trigger') === 'helper' ? 'helper' : 'bot_message',
        routineId: null,
        modelProvider: null,
        modelId: null,
        error: null,
        startedAt: event.createdAt ?? null,
        completedAt: null,
        createdAt: event.createdAt ?? '',
      };
      if (userId !== undefined) {
        waitingRun.userId = userId;
      }
      const activeRuns = [
        ...base.activeRuns.filter((candidate: LiveRun): boolean => candidate.id !== runId),
        waitingRun,
      ];
      const promoteWaiting = base.run === null
        || (waitingRun.trigger !== 'helper' && base.run.status !== 'waiting_input'
          && base.run.status !== 'waiting_takeover');
      return withSnapshot(base, cursor, messages, promoteWaiting ? waitingRun : base.run, activeRuns, members);
    }
    return withSnapshot(base, cursor, messages,
      runChanged && base.run !== null ? settle(base.run) : base.run,
      activeRunChanged
        ? base.activeRuns.map((candidate: LiveRun): LiveRun =>
          candidate.id === runId ? settle(candidate) : candidate)
        : base.activeRuns,
      members);
  }
  if (event.type === 'computer.takeover.released') {
    const runId = event.runId;
    const settle = (candidate: LiveRun): LiveRun => {
      if (runId !== undefined && candidate.id === runId && candidate.status === 'waiting_takeover') {
        const updated = copyRun(candidate);
        updated.status = 'queued';
        return updated;
      }
      return candidate;
    };
    const nextRun = base.run !== null ? settle(base.run) : base.run;
    const activeChanged = runId !== undefined && base.activeRuns.some((candidate: LiveRun): boolean =>
      candidate.id === runId && candidate.status === 'waiting_takeover');
    if (nextRun === base.run && !activeChanged) {
      return advance(base, cursor);
    }
    const members = base.members !== undefined && base.members.some((member: ThreadMember): boolean =>
      member.botId === event.botId && member.status === 'waiting_takeover')
      ? updateMemberStatus(base.members, event.botId, 'queued')
      : base.members;
    return withSnapshot(base, cursor, base.messages, nextRun,
      activeChanged ? base.activeRuns.map(settle) : base.activeRuns, members);
  }
  if (isRunTerminalEvent(event)) {
    const activeRuns = base.activeRuns.filter((candidate: LiveRun): boolean => candidate.id !== event.runId);
    const nextMemberRun = activeRuns.find((candidate: LiveRun): boolean => candidate.botId === event.botId);
    const failure = runFailureError(event);
    const primaryEnded = base.run !== null && base.run.id === event.runId ? base.run : null;
    // In a group the failing run may be a member run rather than the displayed one, so look
    // it up in activeRuns as well or its error would be dropped with it.
    const endedRun = primaryEnded
      ?? base.activeRuns.find((candidate: LiveRun): boolean => candidate.id === event.runId)
      ?? null;
    let run: LiveRun | null;
    if (endedRun !== null && failure !== null) {
      const failed = copyRun(endedRun);
      failed.status = 'failed';
      failed.error = failure;
      run = failed;
    } else if (primaryEnded !== null) {
      run = activeRuns.length > 0 ? activeRuns[0] : null;
    } else {
      run = base.run;
    }
    const messages = base.messages.filter((message: LiveMessage): boolean =>
      message.id !== progressMessageId(event));
    const members = updateMemberStatus(base.members, event.botId, nextMemberRun?.status ?? 'idle');
    return withSnapshot(base, cursor, messages, run, activeRuns, members);
  }
  if (event.type === 'agent.tool.called' && !showsAsLiveStep(payloadString(payload, 'name') ?? '')) {
    return advance(base, cursor);
  }
  if (event.type === 'thread.progress' || event.type === 'agent.tool.called') {
    const liveId = progressMessageId(event);
    const previous = previousLiveMessage(base.messages, liveId);
    const remaining = takeLiveMessage(base.messages, liveId);
    const blocks = reduceLiveMessageBlocks(previous?.blocks ?? [],
      event.type === 'thread.progress' ? 'progress' : 'tool', payload,
      payloadString(payload, 'name') ?? '');
    return withSnapshot(base, cursor, [...remaining, liveRow(base, event, liveId, blocks)],
      base.run, base.activeRuns, base.members);
  }
  if (event.type === 'agent.tool.completed') {
    return advance(base, cursor);
  }
  if (event.type === 'thread.subagent') {
    const block = subagentBlockFromPayload(payload);
    const agentId = block['agentId'] as string;
    const next = liveRow(base, event, `subagent:${agentId}`, [block]);
    // The subagent row goes before the run's streamed answer, which keeps growing below it.
    const without: LiveMessage[] = [];
    const kept: LiveMessage[] = [];
    for (const message of base.messages) {
      if (message.id === next.id) {
        continue;
      }
      if (message.id.startsWith('progress:')) {
        if (message.runId !== undefined) {
          kept.push(message);
        }
      } else {
        without.push(message);
      }
    }
    return withSnapshot(base, cursor, [...without, next, ...kept], base.run, base.activeRuns, base.members);
  }
  if (event.type === 'thread.cloud_agent') {
    return withSnapshot(base, cursor, updateCloudAgentMessages(base.messages, payload),
      base.run, base.activeRuns, base.members);
  }
  if (event.type === 'thread.message.created' || event.type === 'thread.message.updated') {
    const blocksRaw = payload['blocks'];
    const blocks: Record<string, Object>[] = Array.isArray(blocksRaw)
      ? (blocksRaw as Object[]).map((item: Object): Record<string, Object> => item as Record<string, Object>)
      : [];
    const messageId = payloadString(payload, 'messageId');
    const id = messageId ?? event.id ?? `msg:${cursor}`;
    const known = base.messages.find((message: LiveMessage): boolean => message.id === id) ?? null;
    const seqRaw = payload['seq'];
    const seq = typeof seqRaw === 'number' ? seqRaw as number : known?.seq;
    const next: LiveMessage = {
      id: id,
      threadId: known?.threadId ?? event.threadId ?? base.threadId,
      role: payloadString(payload, 'role') ?? 'bot',
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
    // An update can leave the call id out — the end_call marker does — so keep the known one.
    const callId = payloadString(payload, 'callId') ?? known?.callId;
    if (callId !== undefined) {
      next.callId = callId;
    }
    const author = payloadAuthor(payload, known);
    if (author !== undefined) {
      next.author = author;
    }
    applyReplyMetadata(payload, known, next);
    const replacedSubagentIds: Set<string> = new Set();
    for (const block of blocks) {
      if (blockKind(block) === 'subagent' && typeof block['agentId'] === 'string') {
        replacedSubagentIds.add(block['agentId'] as string);
      }
    }
    const remaining = takeLiveMessage(base.messages, progressMessageId(event));
    // A live subagent placeholder gives way to the saved card; the saved card itself stays put.
    const without = remaining.filter((message: LiveMessage): boolean =>
      message.id === id || !replacedSubagent(message, replacedSubagentIds));
    // Helper execution stays in its own thread. Answering its visible card ends the chat's
    // waiting state; no hidden run.started event will arrive here to do that.
    const requestRunId = event.runId ?? known?.runId;
    const answeredHelper = blocks.some((block: Record<string, Object>): boolean => blockKind(block) === 'ask')
      && blocks.every((block: Record<string, Object>): boolean =>
        blockKind(block) !== 'ask' || block['status'] === 'answered')
      && base.activeRuns.some((run: LiveRun): boolean =>
        run.id === requestRunId && run.trigger === 'helper');
    const activeRuns = answeredHelper
      ? base.activeRuns.filter((run: LiveRun): boolean => run.id !== requestRunId)
      : base.activeRuns;
    const run = answeredHelper && base.run !== null && base.run.id === requestRunId
      ? (activeRuns.length > 0 ? activeRuns[0] : null) : base.run;
    return withSnapshot(base, cursor, upsertMessageById(without, next), run, activeRuns, base.members);
  }
  // A type this reducer does not know leaves the snapshot whole — the reference returns prev
  // unchanged (the stream's own replay cursor advances regardless; that lives in the stream).
  return prev;
}

function advance(prev: ThreadSnapshot, cursor: number): ThreadSnapshot {
  if (cursor === prev.cursor) {
    return prev;
  }
  return withSnapshot(prev, cursor, prev.messages, prev.run, prev.activeRuns, prev.members);
}

function replacedSubagent(message: LiveMessage, agentIds: Set<string>): boolean {
  if (agentIds.size === 0) {
    return false;
  }
  return message.blocks.some((block: Record<string, Object>): boolean =>
    blockKind(block) === 'subagent' && typeof block['agentId'] === 'string'
    && agentIds.has(block['agentId'] as string));
}

/** The subagent card a thread.subagent event projects (core subagentBlockFromPayload; the
 * identity-display provenance is a runtime Symbol the JSON wire never carries, so it drops). */
export function subagentBlockFromPayload(payload: Record<string, Object>): Record<string, Object> {
  const status = payload['status'];
  const block: Record<string, Object> = {};
  block['kind'] = 'subagent';
  block['agentId'] = payload['agentId'] === null || payload['agentId'] === undefined
    ? '' : String(payload['agentId']);
  block['name'] = payload['name'] === null || payload['name'] === undefined ? '' : String(payload['name']);
  block['task'] = payload['task'] === null || payload['task'] === undefined ? '' : String(payload['task']);
  block['status'] = status === 'completed' || status === 'failed' ? status : 'running';
  if (payload['progress']) {
    block['progress'] = String(payload['progress']);
  }
  if (payload['result']) {
    block['result'] = String(payload['result']);
  }
  return block;
}

function cloudAgentHttpsUrl(value: string): string | undefined {
  if (!value) {
    return undefined;
  }
  try {
    const parsed = url.URL.parseURL(value);
    return parsed.protocol === 'https:' && !parsed.username && !parsed.password ? value : undefined;
  } catch (err) {
    return undefined;
  }
}

/** The cloud-agent card a thread.cloud_agent event projects (core cloudAgentBlockFromPayload). */
export function cloudAgentBlockFromPayload(payload: Record<string, Object>): Record<string, Object> {
  const status = payload['status'];
  const block: Record<string, Object> = {};
  block['kind'] = 'cloud_agent';
  block['agentId'] = payload['agentId'] === null || payload['agentId'] === undefined
    ? '' : String(payload['agentId']);
  block['title'] = payload['title'] === null || payload['title'] === undefined
    ? 'Cloud agent' : String(payload['title']);
  block['status'] = status === 'finished' || status === 'failed' || status === 'cancelled' || status === 'expired'
    ? status : 'running';
  block['url'] = cloudAgentHttpsUrl(payload['url'] === null || payload['url'] === undefined
    ? '' : String(payload['url'])) ?? '';
  if (payload['branch']) {
    block['branch'] = String(payload['branch']);
  }
  const prUrl = payload['prUrl'] === null || payload['prUrl'] === undefined ? '' : String(payload['prUrl']);
  if (cloudAgentHttpsUrl(prUrl) !== undefined) {
    block['prUrl'] = prUrl;
  }
  if (payload['latestRunId']) {
    block['latestRunId'] = String(payload['latestRunId']);
  }
  return block;
}

/** Replace the matching cloud-agent card in place (core updateCloudAgentMessages). */
function updateCloudAgentMessages(messages: LiveMessage[], payload: Record<string, Object>): LiveMessage[] {
  const agentId = payload['agentId'] === null || payload['agentId'] === undefined
    ? '' : String(payload['agentId']);
  const messageId = payload['messageId'] === null || payload['messageId'] === undefined
    ? '' : String(payload['messageId']);
  const block = cloudAgentBlockFromPayload(payload);
  return messages.map((message: LiveMessage): LiveMessage => {
    const matches = (messageId !== '' && message.id === messageId)
      || message.blocks.some((existing: Record<string, Object>): boolean =>
        blockKind(existing) === 'cloud_agent' && existing['agentId'] === agentId);
    if (!matches) {
      return message;
    }
    const blocks = message.blocks.map((existing: Record<string, Object>): Record<string, Object> =>
      blockKind(existing) === 'cloud_agent' && existing['agentId'] === agentId ? block : existing);
    const updated: LiveMessage = {
      id: message.id, threadId: message.threadId, role: message.role, blocks: blocks,
      createdAt: message.createdAt,
    };
    copyMessageOptionals(message, updated);
    return updated;
  });
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
  if (snapshot.members !== undefined) {
    next.members = snapshot.members;
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
  return snapshot;
}
