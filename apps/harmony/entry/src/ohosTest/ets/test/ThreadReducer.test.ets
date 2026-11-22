// Layer-2 replay: the thread reducer port must agree value-for-value with the fixture generated
// from the REAL core cluster (reduceThreadSnapshot / applyThreadSendReceipt / rememberTerminalRun /
// mergeThreadSnapshot / reconcileRefreshedThread / reduceLiveMessageBlocks). Pure logic, no network.
// Comparison is canonical JSON of the normalized snapshot (activeRuns defaulted, optional fields
// absent when undefined) — the same shape the generator pins.
import { describe, expect, it } from '@ohos/hypium';
import { fixtureThread } from './fixtures.generated';
import { recordOf, arrayOf, stringField } from './test-utils';
import {
  applyThreadSendReceipt,
  mergeThreadSnapshot,
  reconcileRefreshedThread,
  reduceLiveMessageBlocks,
  reduceThreadSnapshot,
  rememberTerminalRun,
} from '../../../main/ets/thread/thread-snapshot';
import type {
  LiveMessage,
  LiveRun,
  SendReceipt,
  ThreadEvent,
  ThreadMember,
  ThreadSnapshot,
} from '../../../main/ets/thread/thread-snapshot';

function optString(record: Record<string, Object>, key: string): string | undefined {
  const value = record[key];
  return typeof value === 'string' ? value as string : undefined;
}

function nullableString(record: Record<string, Object>, key: string): string | null {
  const value = record[key];
  return typeof value === 'string' ? value as string : null;
}

function runOf(json: Object | null): LiveRun | null {
  if (json === null || json === undefined) {
    return null;
  }
  const r = json as Record<string, Object>;
  const run: LiveRun = {
    id: stringField(r, 'id'),
    botId: stringField(r, 'botId'),
    threadId: stringField(r, 'threadId'),
    taskId: stringField(r, 'taskId'),
    status: stringField(r, 'status'),
    trigger: stringField(r, 'trigger'),
    routineId: nullableString(r, 'routineId'),
    modelProvider: nullableString(r, 'modelProvider'),
    modelId: nullableString(r, 'modelId'),
    error: nullableString(r, 'error'),
    startedAt: nullableString(r, 'startedAt'),
    completedAt: nullableString(r, 'completedAt'),
    createdAt: stringField(r, 'createdAt'),
  };
  const userId = optString(r, 'userId');
  if (userId !== undefined) {
    run.userId = userId;
  }
  const routineName = optString(r, 'routineName');
  if (routineName !== undefined) {
    run.routineName = routineName;
  }
  return run;
}

function runsOf(json: Object | null): LiveRun[] {
  const runs: LiveRun[] = [];
  if (json === null || json === undefined || !Array.isArray(json)) {
    return runs;
  }
  for (const item of json as Object[]) {
    const run = runOf(item);
    if (run !== null) {
      runs.push(run);
    }
  }
  return runs;
}

function blocksOf(json: Object | null): Record<string, Object>[] {
  const blocks: Record<string, Object>[] = [];
  if (json !== null && json !== undefined && Array.isArray(json)) {
    for (const item of json as Object[]) {
      blocks.push(item as Record<string, Object>);
    }
  }
  return blocks;
}

function messageOf(json: Object): LiveMessage {
  const r = json as Record<string, Object>;
  const message: LiveMessage = {
    id: stringField(r, 'id'),
    threadId: stringField(r, 'threadId'),
    role: stringField(r, 'role'),
    blocks: blocksOf(r['blocks']),
    createdAt: stringField(r, 'createdAt'),
  };
  const seq = r['seq'];
  if (typeof seq === 'number') {
    message.seq = seq as number;
  }
  const botId = optString(r, 'botId');
  if (botId !== undefined) {
    message.botId = botId;
  }
  const runId = optString(r, 'runId');
  if (runId !== undefined) {
    message.runId = runId;
  }
  const callId = optString(r, 'callId');
  if (callId !== undefined) {
    message.callId = callId;
  }
  const author = r['author'];
  if (author !== null && author !== undefined && typeof author === 'object') {
    message.author = author as Record<string, Object>;
  }
  const replyToMessageId = optString(r, 'replyToMessageId');
  if (replyToMessageId !== undefined) {
    message.replyToMessageId = replyToMessageId;
  }
  const replyQuote = optString(r, 'replyQuote');
  if (replyQuote !== undefined) {
    message.replyQuote = replyQuote;
  }
  const replyPreview = r['replyPreview'];
  if (replyPreview === null) {
    message.replyPreview = null;
  } else if (replyPreview !== undefined && typeof replyPreview === 'object') {
    message.replyPreview = replyPreview as Record<string, Object>;
  }
  return message;
}

function messagesOf(json: Object | null): LiveMessage[] {
  const messages: LiveMessage[] = [];
  if (json !== null && json !== undefined && Array.isArray(json)) {
    for (const item of json as Object[]) {
      messages.push(messageOf(item));
    }
  }
  return messages;
}

function snapshotOf(json: Object | null): ThreadSnapshot | null {
  if (json === null || json === undefined) {
    return null;
  }
  const r = json as Record<string, Object>;
  const cursor = r['cursor'];
  const olderCursor = r['olderCursor'];
  const run = runOf(r['run']);
  const snapshot: ThreadSnapshot = {
    threadId: stringField(r, 'threadId'),
    cursor: typeof cursor === 'number' ? cursor as number : -1,
    olderCursor: typeof olderCursor === 'number' ? olderCursor as number : null,
    messages: messagesOf(r['messages']),
    run: run,
    activeRuns: runsOf(r['activeRuns']),
  };
  const botId = optString(r, 'botId');
  if (botId !== undefined) {
    snapshot.botId = botId;
  }
  const groupId = optString(r, 'groupId');
  if (groupId !== undefined) {
    snapshot.groupId = groupId;
  }
  const membersRaw = r['members'];
  if (membersRaw !== null && membersRaw !== undefined && Array.isArray(membersRaw)) {
    const members: ThreadMember[] = [];
    for (const item of membersRaw as Object[]) {
      const m = item as Record<string, Object>;
      const member: ThreadMember = {
        botId: stringField(m, 'botId'), name: stringField(m, 'name'), color: stringField(m, 'color'),
      };
      const status = optString(m, 'status');
      if (status !== undefined) {
        member.status = status;
      }
      members.push(member);
    }
    snapshot.members = members;
  }
  return snapshot;
}

function eventOf(json: Object): ThreadEvent {
  const r = json as Record<string, Object>;
  const payload = r['payload'];
  const event: ThreadEvent = {
    type: stringField(r, 'type'),
    payload: payload !== null && payload !== undefined && typeof payload === 'object'
      ? payload as Record<string, Object> : {},
  };
  const id = optString(r, 'id');
  if (id !== undefined) {
    event.id = id;
  }
  const seq = r['seq'];
  if (typeof seq === 'number') {
    event.seq = seq as number;
  }
  const threadId = optString(r, 'threadId');
  if (threadId !== undefined) {
    event.threadId = threadId;
  }
  const botId = optString(r, 'botId');
  if (botId !== undefined) {
    event.botId = botId;
  }
  const runId = optString(r, 'runId');
  if (runId !== undefined) {
    event.runId = runId;
  }
  const createdAt = optString(r, 'createdAt');
  if (createdAt !== undefined) {
    event.createdAt = createdAt;
  }
  return event;
}

/**
 * The generator's normalized snapshot shape as canonical JSON. Built by hand because ArkTS
 * Record<string, Object> values cannot be null — the JSON text carries the nulls itself.
 */
function normalized(snapshot: ThreadSnapshot | null): string {
  if (snapshot === null) {
    return 'null';
  }
  const parts: string[] = [];
  parts.push(`"activeRuns":${canonical(snapshot.activeRuns)}`);
  if (snapshot.botId !== undefined) {
    parts.push(`"botId":${JSON.stringify(snapshot.botId)}`);
  }
  parts.push(`"cursor":${snapshot.cursor}`);
  if (snapshot.groupId !== undefined) {
    parts.push(`"groupId":${JSON.stringify(snapshot.groupId)}`);
  }
  if (snapshot.members !== undefined) {
    parts.push(`"members":${canonical(snapshot.members)}`);
  }
  parts.push(`"messages":${canonical(snapshot.messages)}`);
  parts.push(`"olderCursor":${snapshot.olderCursor === null ? 'null' : `${snapshot.olderCursor}`}`);
  parts.push(`"run":${snapshot.run === null ? 'null' : canonical(snapshot.run)}`);
  parts.push(`"threadId":${JSON.stringify(snapshot.threadId)}`);
  return `{${parts.join(',')}}`;
}

function expectedJson(value: Object | null): string {
  // Canonicalize by sorting keys at every level: the fixture JSON's key order is the generator's,
  // the port's is its own, so neither side's order can be trusted.
  return value === null || value === undefined ? 'null' : canonical(value);
}

function canonical(value: Object | null): string {
  if (value === null || value === undefined || typeof value !== 'object') {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    const items: string[] = [];
    for (const item of value as Object[]) {
      items.push(canonical(item));
    }
    return `[${items.join(',')}]`;
  }
  const record = value as Record<string, Object>;
  const keys = Object.keys(record).sort();
  const parts: string[] = [];
  for (const key of keys) {
    parts.push(`${JSON.stringify(key)}:${canonical(record[key])}`);
  }
  return `{${parts.join(',')}}`;
}

export default function threadReducerTest() {
  describe('ThreadReducerFixture', () => {
    const fixture = recordOf(fixtureThread);

    it('reduce_matches_core_event_by_event', 0, () => {
      for (const item of arrayOf(JSON.stringify(fixture['reduce']))) {
        const scenario = item as Record<string, Object>;
        const name = stringField(scenario, 'name');
        let current = snapshotOf(scenario['initial']);
        const events = arrayOf(JSON.stringify(scenario['events']));
        const expected = arrayOf(JSON.stringify(scenario['expected']));
        expect(events.length).assertEqual(expected.length);
        for (let index = 0; index < events.length; index += 1) {
          const spec = eventOf(events[index]);
          current = reduceThreadSnapshot(current, spec);
          if (normalized(current) !== expectedJson(expected[index])) {
            throw new Error(`${name} step ${index}: type=${spec.type} seq=${spec.seq ?? 'none'}`
              + ` payload=${JSON.stringify(spec.payload)} got=${normalized(current)}`
              + ` want=${expectedJson(expected[index])}`);
          }
        }
      }
    });

    it('receipt_matches_core_applyThreadSendReceipt', 0, () => {
      for (const item of arrayOf(JSON.stringify(fixture['receipt']))) {
        const scenario = item as Record<string, Object>;
        const initial = snapshotOf(scenario['initial']);
        const r = scenario['receipt'] as Record<string, Object>;
        const receipt: SendReceipt = {
          botId: stringField(r, 'botId'),
          runId: stringField(r, 'runId'),
          taskId: stringField(r, 'taskId'),
        };
        const createdAt = optString(r, 'createdAt');
        if (createdAt !== undefined) {
          receipt.createdAt = createdAt;
        }
        const terminal: Set<string> = new Set();
        for (const id of arrayOf(JSON.stringify(scenario['terminalRunIds']))) {
          terminal.add(id as string);
        }
        const result = applyThreadSendReceipt(initial, receipt, terminal, stringField(scenario, 'now'));
        expect(normalized(result)).assertEqual(expectedJson(scenario['expected']));
      }
    });

    it('refresh_matches_core_reconcileRefreshedThread', 0, () => {
      for (const item of arrayOf(JSON.stringify(fixture['refresh']))) {
        const scenario = item as Record<string, Object>;
        const prev = snapshotOf(scenario['prev']);
        const next = snapshotOf(scenario['next']);
        expect(next !== null).assertTrue();
        const result = reconcileRefreshedThread(prev, next!, scenario['preserveLoadedHistory'] === true);
        expect(normalized(result)).assertEqual(expectedJson(scenario['expected']));
      }
    });

    it('merge_matches_core_mergeThreadSnapshot', 0, () => {
      for (const item of arrayOf(JSON.stringify(fixture['merge']))) {
        const scenario = item as Record<string, Object>;
        const prev = snapshotOf(scenario['prev']);
        const next = snapshotOf(scenario['next']);
        expect(next !== null).assertTrue();
        const result = mergeThreadSnapshot(prev, next!, scenario['preserveLoadedHistory'] === true);
        expect(normalized(result)).assertEqual(expectedJson(scenario['expected']));
      }
    });

    it('terminal_memory_matches_core_rememberTerminalRun', 0, () => {
      for (const item of arrayOf(JSON.stringify(fixture['terminal']))) {
        const scenario = item as Record<string, Object>;
        const set: Set<string> = new Set();
        for (const id of arrayOf(JSON.stringify(scenario['initial']))) {
          set.add(id as string);
        }
        for (const spec of arrayOf(JSON.stringify(scenario['events']))) {
          rememberTerminalRun(set, eventOf(spec));
        }
        const actual: string[] = [];
        for (const id of set) {
          actual.push(id);
        }
        expect(canonical(actual)).assertEqual(canonical(scenario['expected']));
      }
    });

    it('live_blocks_match_core_reduceLiveMessageBlocks', 0, () => {
      for (const item of arrayOf(JSON.stringify(fixture['blocks']))) {
        const scenario = item as Record<string, Object>;
        let blocks = blocksOf(scenario['current']);
        const updates = arrayOf(JSON.stringify(scenario['updates']));
        const expected = arrayOf(JSON.stringify(scenario['expected']));
        expect(updates.length).assertEqual(expected.length);
        for (let index = 0; index < updates.length; index += 1) {
          const update = updates[index] as Record<string, Object>;
          const type = stringField(update, 'type');
          if (type === 'progress') {
            const payload = update['payload'] as Record<string, Object>;
            blocks = reduceLiveMessageBlocks(blocks, 'progress', payload, '');
          } else {
            blocks = reduceLiveMessageBlocks(blocks, 'tool', {}, stringField(update, 'name'));
          }
          expect(canonical(blocks)).assertEqual(canonical(expected[index]));
        }
      }
    });
  });
}
