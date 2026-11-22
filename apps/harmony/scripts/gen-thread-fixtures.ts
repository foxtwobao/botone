// Layer 2 thread-reducer fixtures (design §4.3.3, M3): drive the REAL core reducer cluster
// (reduceThreadSnapshot, applyThreadSendReceipt, rememberTerminalRun, mergeThreadSnapshot,
// reconcileRefreshedThread, reduceLiveMessageBlocks) with scripted event sequences and record
// every observable snapshot. The vitest test regenerates and diffs; the ArkTS port replays the
// same files under hypium. Snapshots are compared as plain JSON (key order irrelevant); optional
// fields the reference leaves undefined are absent, and the port must not invent them.

import type { LiveThreadMessage, LiveThreadRun, LiveThreadSnapshot } from "@rakazo/core";
import {
  applyThreadSendReceipt,
  mergeThreadSnapshot,
  reconcileRefreshedThread,
  reduceLiveMessageBlocks,
  reduceThreadSnapshot,
  rememberTerminalRun,
} from "@rakazo/core";

// ---------------------------------------------------------------- shapes

type Json = Record<string, unknown>;

/** The reducer's snapshot as the fixture pins it: activeRuns normalized, no computer. */
interface FixtureSnapshot {
  threadId: string;
  botId?: string;
  groupId?: string;
  cursor?: number;
  olderCursor: number | null;
  messages: Json[];
  run: Json | null;
  activeRuns: Json[];
}

function snapshotOf(value: LiveThreadSnapshot | null): FixtureSnapshot | null {
  if (!value) return null;
  return JSON.parse(
    JSON.stringify({
      threadId: value.threadId,
      ...(value.botId !== undefined ? { botId: value.botId } : {}),
      ...(value.groupId !== undefined ? { groupId: value.groupId } : {}),
      ...(value.cursor !== undefined ? { cursor: value.cursor } : {}),
      olderCursor: value.olderCursor,
      messages: value.messages,
      run: value.run,
      activeRuns: value.activeRuns ?? (value.run ? [value.run] : []),
      ...(value.members !== undefined ? { members: value.members } : {}),
    }),
  ) as FixtureSnapshot;
}

const T0 = "2026-11-21T12:00:00.000Z";
const T1 = "2026-11-21T12:00:01.000Z";
const T2 = "2026-11-21T12:00:02.000Z";
const T3 = "2026-11-21T12:00:03.000Z";

function baseSnapshot(over: Partial<LiveThreadSnapshot> = {}): LiveThreadSnapshot {
  return {
    threadId: "thread-1",
    botId: "bot-1",
    cursor: 0,
    olderCursor: null,
    messages: [],
    run: null,
    activeRuns: [],
    ...over,
  };
}

function run(over: Partial<LiveThreadRun> & { id: string }): LiveThreadRun {
  return {
    botId: "bot-1",
    threadId: "thread-1",
    taskId: over.id,
    status: "running",
    trigger: "user",
    routineId: null,
    modelProvider: null,
    modelId: null,
    error: null,
    startedAt: T0,
    completedAt: null,
    createdAt: T0,
    ...over,
  };
}

function message(over: Partial<LiveThreadMessage> & { id: string }): LiveThreadMessage {
  return {
    threadId: "thread-1",
    role: "bot",
    blocks: [],
    createdAt: T0,
    ...over,
  };
}

interface EventSpec {
  type: string;
  id?: string;
  seq?: number;
  threadId?: string;
  botId?: string;
  runId?: string;
  createdAt?: string;
  payload?: Json;
}

function event(spec: EventSpec): EventSpec {
  return { createdAt: T0, botId: "bot-1", threadId: "thread-1", ...spec };
}

// ---------------------------------------------------------------- reducer scenarios

interface ReduceScenario {
  name: string;
  initial: FixtureSnapshot | null;
  events: EventSpec[];
  expected: (FixtureSnapshot | null)[];
}

function reduceScenario(
  name: string,
  initial: LiveThreadSnapshot | null,
  events: EventSpec[],
): ReduceScenario {
  let current = initial;
  const expected: (FixtureSnapshot | null)[] = [];
  for (const spec of events) {
    current = reduceThreadSnapshot(current, spec);
    expected.push(snapshotOf(current));
  }
  return { name, initial: snapshotOf(initial), events, expected };
}

function progressScenarios(): ReduceScenario[] {
  return [
    reduceScenario("progress deltas accumulate into one live bubble", baseSnapshot(), [
      event({ type: "thread.progress", seq: 1, runId: "run-1", payload: { delta: "Hel" } }),
      event({ type: "thread.progress", seq: 2, runId: "run-1", payload: { delta: "lo" } }),
      event({ type: "thread.progress", seq: 3, runId: "run-1", payload: { delta: " world" } }),
    ]),
    reduceScenario("text payload replaces, delta appends", baseSnapshot(), [
      event({ type: "thread.progress", seq: 1, runId: "run-1", payload: { text: "draft" } }),
      event({ type: "thread.progress", seq: 2, runId: "run-1", payload: { delta: " more" } }),
      event({ type: "thread.progress", seq: 3, runId: "run-1", payload: { text: "replaced" } }),
    ]),
    reduceScenario("reset drops streamed text and keeps waiting tools", baseSnapshot(), [
      event({
        type: "thread.progress",
        seq: 1,
        runId: "run-1",
        payload: { delta: "half a clause" },
      }),
      event({ type: "agent.tool.called", seq: 2, runId: "run-1", payload: { name: "web_search" } }),
      event({
        type: "thread.progress",
        seq: 3,
        runId: "run-1",
        payload: { reset: true, delta: "New start." },
      }),
      event({ type: "thread.progress", seq: 4, runId: "run-1", payload: { delta: " Continues." } }),
    ]),
    reduceScenario("tool call flushes the sentence and becomes a step", baseSnapshot(), [
      event({
        type: "thread.progress",
        seq: 1,
        runId: "run-1",
        payload: { delta: "Let me check." },
      }),
      event({ type: "agent.tool.called", seq: 2, runId: "run-1", payload: { name: "web_search" } }),
      event({ type: "agent.tool.called", seq: 3, runId: "run-1", payload: { name: "web_search" } }),
      event({
        type: "agent.tool.completed",
        seq: 4,
        runId: "run-1",
        payload: { name: "web_search" },
      }),
      event({ type: "thread.progress", seq: 5, runId: "run-1", payload: { delta: "Found it." } }),
    ]),
    reduceScenario("ask_user never joins the live step line", baseSnapshot(), [
      event({ type: "thread.progress", seq: 1, runId: "run-1", payload: { delta: "Working." } }),
      event({ type: "agent.tool.called", seq: 2, runId: "run-1", payload: { name: "ask_user" } }),
      event({ type: "thread.progress", seq: 3, runId: "run-1", payload: { delta: " Still." } }),
    ]),
    reduceScenario("activity progress keeps its flag and replaces narration", baseSnapshot(), [
      event({
        type: "thread.progress",
        seq: 1,
        runId: "run-1",
        payload: { delta: "Thinking about it" },
      }),
      event({
        type: "thread.progress",
        seq: 2,
        runId: "run-1",
        payload: { activity: true, text: "Searching the web: cats" },
      }),
      event({ type: "thread.progress", seq: 3, runId: "run-1", payload: { delta: " answer." } }),
    ]),
    reduceScenario("shown flag survives on the growing tail", baseSnapshot(), [
      event({
        type: "thread.progress",
        seq: 1,
        runId: "run-1",
        payload: { shown: true, delta: "Hi" },
      }),
      event({ type: "thread.progress", seq: 2, runId: "run-1", payload: { delta: " there" } }),
    ]),
    reduceScenario("message.created replaces the live bubble and upserts by id", baseSnapshot(), [
      event({ type: "thread.progress", seq: 1, runId: "run-1", payload: { delta: "streamed" } }),
      event({
        type: "thread.message.created",
        seq: 2,
        runId: "run-1",
        id: "evt-2",
        payload: {
          messageId: "msg-1",
          seq: 7,
          role: "bot",
          blocks: [{ kind: "text", text: "streamed answer" }],
        },
      }),
      event({
        type: "thread.message.updated",
        seq: 3,
        runId: "run-1",
        id: "evt-3",
        payload: { messageId: "msg-1", blocks: [{ kind: "text", text: "edited answer" }] },
      }),
    ]),
    reduceScenario("user echo keeps author and its own seq", baseSnapshot(), [
      event({
        type: "thread.message.created",
        seq: 1,
        id: "evt-1",
        payload: {
          messageId: "msg-u",
          seq: 4,
          role: "user",
          blocks: [{ kind: "text", text: "hello bot" }],
          author: { id: "user-1", name: "Ada" },
        },
      }),
    ]),
    reduceScenario(
      "update keeps the known callId and createdAt",
      baseSnapshot({
        messages: [
          message({
            id: "msg-c",
            seq: 2,
            callId: "call-9",
            createdAt: T1,
            blocks: [{ kind: "text", text: "a" }],
          }),
        ],
        cursor: 2,
      }),
      [
        event({
          type: "thread.message.updated",
          seq: 3,
          id: "evt-3",
          createdAt: T3,
          payload: { messageId: "msg-c", blocks: [{ kind: "text", text: "b" }] },
        }),
      ],
    ),
    reduceScenario("duplicate and out-of-order seq are dropped", baseSnapshot({ cursor: 5 }), [
      event({ type: "thread.progress", seq: 5, runId: "run-1", payload: { delta: "dup" } }),
      event({ type: "thread.progress", seq: 3, runId: "run-1", payload: { delta: "old" } }),
      event({ type: "thread.progress", seq: 6, runId: "run-1", payload: { delta: "new" } }),
    ]),
    // The reference returns prev UNCHANGED for a type it does not reduce — the cursor does not
    // advance on an unknown event (mobile's loop advances its own replay cursor regardless; the
    // stream port owns that, the reducer does not).
    reduceScenario("unknown event types leave the snapshot unchanged", baseSnapshot(), [
      event({ type: "routine.fired", seq: 1, payload: {} }),
      event({ type: "something.new", seq: 2, payload: {} }),
      event({ type: "thread.progress", seq: 3, runId: "run-1", payload: { delta: "after" } }),
    ]),
    reduceScenario("event without seq keeps the cursor", baseSnapshot({ cursor: 4 }), [
      event({ type: "thread.progress", runId: "run-1", payload: { delta: "no seq" } }),
    ]),
  ];
}

function runScenarios(): ReduceScenario[] {
  const longError = "x".repeat(400);
  return [
    reduceScenario("run.started builds the running record and activeRuns", baseSnapshot(), [
      event({
        type: "run.started",
        seq: 1,
        runId: "run-1",
        createdAt: T1,
        payload: { trigger: "user" },
      }),
      event({ type: "run.completed", seq: 2, runId: "run-1", createdAt: T2, payload: {} }),
    ]),
    reduceScenario("send receipt then started then progress then completed", baseSnapshot(), [
      event({ type: "run.started", seq: 1, runId: "run-1", createdAt: T1, payload: {} }),
      event({ type: "thread.progress", seq: 2, runId: "run-1", payload: { delta: "Hi" } }),
      event({
        type: "thread.message.created",
        seq: 3,
        runId: "run-1",
        payload: { messageId: "msg-1", seq: 2, blocks: [{ kind: "text", text: "Hi" }] },
      }),
      event({ type: "run.completed", seq: 4, runId: "run-1", payload: {} }),
    ]),
    reduceScenario("run.failed keeps the clamped error in run", baseSnapshot(), [
      event({ type: "run.started", seq: 1, runId: "run-1", payload: {} }),
      event({ type: "run.failed", seq: 2, runId: "run-1", payload: { error: `  ${longError}  ` } }),
    ]),
    reduceScenario("run.failed without a usable error clears the primary run", baseSnapshot(), [
      event({ type: "run.started", seq: 1, runId: "run-1", payload: {} }),
      event({ type: "run.failed", seq: 2, runId: "run-1", payload: { error: "   " } }),
    ]),
    reduceScenario("run.cancelled drops the live bubble and the run", baseSnapshot(), [
      event({ type: "run.started", seq: 1, runId: "run-1", payload: {} }),
      event({ type: "thread.progress", seq: 2, runId: "run-1", payload: { delta: "half" } }),
      event({ type: "run.cancelled", seq: 3, runId: "run-1", payload: {} }),
    ]),
    reduceScenario("background ticket run stays invisible", baseSnapshot(), [
      event({ type: "run.started", seq: 1, runId: "run-t", payload: { trigger: "tickets" } }),
      event({ type: "thread.progress", seq: 2, runId: "run-1", payload: { delta: "visible" } }),
    ]),
    reduceScenario("second run keeps the waiting card answerable", baseSnapshot(), [
      event({ type: "run.started", seq: 1, runId: "run-1", payload: {} }),
      event({ type: "run.waiting_input", seq: 2, runId: "run-1", payload: { userId: "user-1" } }),
      event({ type: "run.started", seq: 3, runId: "run-2", payload: { trigger: "user" } }),
    ]),
    reduceScenario("waiting_input settles a known run and drops its progress", baseSnapshot(), [
      event({ type: "run.started", seq: 1, runId: "run-1", payload: {} }),
      event({ type: "thread.progress", seq: 2, runId: "run-1", payload: { delta: "working" } }),
      event({ type: "run.waiting_input", seq: 3, runId: "run-1", payload: { userId: "user-1" } }),
    ]),
    reduceScenario("waiting_input inserts an unknown peer run", baseSnapshot(), [
      event({
        type: "run.waiting_input",
        seq: 1,
        runId: "run-peer",
        botId: "bot-2",
        createdAt: T1,
        payload: { userId: "user-1" },
      }),
      event({ type: "run.completed", seq: 2, runId: "run-peer", botId: "bot-2", payload: {} }),
    ]),
    reduceScenario(
      "waiting_input on a helper run does not promote over a waiting card",
      baseSnapshot({
        run: run({ id: "run-0", status: "waiting_input" }),
        activeRuns: [run({ id: "run-0", status: "waiting_input" })],
        cursor: 1,
      }),
      [
        event({
          type: "run.waiting_input",
          seq: 2,
          runId: "run-helper",
          botId: "bot-2",
          createdAt: T1,
          payload: { trigger: "helper", userId: "user-1" },
        }),
      ],
    ),
    reduceScenario("takeover requested then released", baseSnapshot(), [
      event({ type: "run.started", seq: 1, runId: "run-1", payload: {} }),
      event({ type: "thread.progress", seq: 2, runId: "run-1", payload: { delta: "working" } }),
      event({ type: "computer.takeover.requested", seq: 3, runId: "run-1", payload: {} }),
      event({ type: "computer.takeover.released", seq: 4, runId: "run-1", payload: {} }),
      event({ type: "computer.takeover.released", seq: 5, runId: "run-1", payload: {} }),
    ]),
    reduceScenario("takeover release leaves a non-waiting run alone", baseSnapshot(), [
      event({ type: "run.started", seq: 1, runId: "run-1", payload: {} }),
      event({ type: "computer.takeover.released", seq: 2, runId: "run-1", payload: {} }),
    ]),
    reduceScenario(
      "group failure banner survives a late member start",
      baseSnapshot({ groupId: "group-1", botId: undefined }),
      [
        event({ type: "run.started", seq: 1, runId: "run-1", botId: "bot-1", payload: {} }),
        event({
          type: "run.failed",
          seq: 2,
          runId: "run-1",
          botId: "bot-1",
          payload: { error: "member blew up" },
        }),
        event({ type: "run.started", seq: 3, runId: "run-2", botId: "bot-2", payload: {} }),
        event({ type: "run.completed", seq: 4, runId: "run-2", botId: "bot-2", payload: {} }),
      ],
    ),
    reduceScenario(
      "member run failure is found in activeRuns",
      baseSnapshot({ groupId: "group-1", botId: undefined }),
      [
        event({ type: "run.started", seq: 1, runId: "run-1", botId: "bot-1", payload: {} }),
        event({ type: "run.started", seq: 2, runId: "run-2", botId: "bot-2", payload: {} }),
        event({
          type: "run.failed",
          seq: 3,
          runId: "run-1",
          botId: "bot-1",
          payload: { error: "primary failed" },
        }),
      ],
    ),
    reduceScenario("terminal event drops the run's live progress bubble", baseSnapshot(), [
      event({ type: "run.started", seq: 1, runId: "run-1", payload: {} }),
      event({ type: "thread.progress", seq: 2, runId: "run-1", payload: { delta: "working" } }),
      event({ type: "run.completed", seq: 3, runId: "run-1", payload: {} }),
    ]),
    reduceScenario(
      "thread.cleared empties the transcript and runs",
      baseSnapshot({
        cursor: 9,
        olderCursor: 3,
        messages: [message({ id: "msg-1", seq: 1 })],
        run: run({ id: "run-1" }),
        activeRuns: [run({ id: "run-1" })],
      }),
      [
        event({ type: "thread.cleared", seq: 10, payload: {} }),
        event({ type: "thread.progress", seq: 11, runId: "run-2", payload: { delta: "fresh" } }),
      ],
    ),
    reduceScenario(
      "member status follows run lifecycle in a group",
      baseSnapshot({
        groupId: "group-1",
        botId: undefined,
        members: [
          { botId: "bot-1", name: "Alpha", color: "#3EC5A8", status: "idle" },
          { botId: "bot-2", name: "Beta", color: "#F5A03C", status: "idle" },
        ],
      }),
      [
        event({ type: "run.started", seq: 1, runId: "run-1", botId: "bot-1", payload: {} }),
        event({ type: "run.started", seq: 2, runId: "run-2", botId: "bot-2", payload: {} }),
        event({ type: "run.waiting_input", seq: 3, runId: "run-1", botId: "bot-1", payload: {} }),
        event({ type: "run.completed", seq: 4, runId: "run-2", botId: "bot-2", payload: {} }),
        event({ type: "run.completed", seq: 5, runId: "run-1", botId: "bot-1", payload: {} }),
      ],
    ),
    reduceScenario(
      "subagent rows order before the streamed answer and settle on pause",
      baseSnapshot(),
      [
        event({ type: "run.started", seq: 1, runId: "run-1", payload: {} }),
        event({
          type: "thread.progress",
          seq: 2,
          runId: "run-1",
          payload: { delta: "Main answer" },
        }),
        event({
          type: "thread.subagent",
          seq: 3,
          runId: "run-1",
          payload: {
            agentId: "agent-1",
            name: "Researcher",
            task: "find sources",
            status: "running",
            progress: "searching",
          },
        }),
        event({
          type: "thread.subagent",
          seq: 4,
          runId: "run-1",
          payload: {
            agentId: "agent-1",
            name: "Researcher",
            task: "find sources",
            status: "completed",
            result: "3 sources",
          },
        }),
        event({
          type: "thread.progress",
          seq: 5,
          runId: "run-1",
          payload: { delta: " continues" },
        }),
        event({ type: "run.waiting_input", seq: 6, runId: "run-1", payload: {} }),
      ],
    ),
    reduceScenario("running subagent settles to stopped when its run ends", baseSnapshot(), [
      event({ type: "run.started", seq: 1, runId: "run-1", payload: {} }),
      event({
        type: "thread.subagent",
        seq: 2,
        runId: "run-1",
        payload: { agentId: "agent-1", name: "Helper", task: "work", status: "running" },
      }),
      event({ type: "run.cancelled", seq: 3, runId: "run-1", payload: {} }),
    ]),
    reduceScenario("saved subagent card replaces the live placeholder", baseSnapshot(), [
      event({
        type: "thread.subagent",
        seq: 1,
        runId: "run-1",
        payload: { agentId: "agent-1", name: "Helper", task: "work", status: "running" },
      }),
      event({
        type: "thread.message.created",
        seq: 2,
        runId: "run-1",
        payload: {
          messageId: "msg-sub",
          seq: 5,
          blocks: [
            {
              kind: "subagent",
              agentId: "agent-1",
              name: "Helper",
              task: "work",
              status: "completed",
              result: "done",
            },
          ],
        },
      }),
    ]),
    reduceScenario(
      "cloud agent card updates in place",
      baseSnapshot({
        messages: [
          message({
            id: "msg-cloud",
            seq: 1,
            blocks: [
              {
                kind: "cloud_agent",
                agentId: "ca-1",
                title: "Cloud agent",
                status: "running",
                url: "https://example.com/a",
              },
            ],
          }),
        ],
        cursor: 1,
      }),
      [
        event({
          type: "thread.cloud_agent",
          seq: 2,
          payload: {
            agentId: "ca-1",
            messageId: "msg-cloud",
            title: "Fix bug",
            status: "finished",
            url: "https://example.com/a",
            prUrl: "https://example.com/pr/1",
            branch: "fix",
          },
        }),
        event({
          type: "thread.cloud_agent",
          seq: 3,
          payload: { agentId: "ca-1", status: "failed", url: "http://insecure.example.com" },
        }),
      ],
    ),
    reduceScenario(
      "answered helper card ends the chat waiting state",
      baseSnapshot({
        run: run({ id: "run-helper", trigger: "helper", status: "waiting_input" }),
        activeRuns: [run({ id: "run-helper", trigger: "helper", status: "waiting_input" })],
        cursor: 2,
      }),
      [
        event({
          type: "thread.message.updated",
          seq: 3,
          runId: "run-helper",
          payload: {
            messageId: "msg-ask",
            blocks: [{ kind: "ask", text: "Proceed?", status: "answered", answer: "allow" }],
          },
        }),
      ],
    ),
    reduceScenario("reply metadata is kept across updates that omit it", baseSnapshot(), [
      event({
        type: "thread.message.created",
        seq: 1,
        payload: {
          messageId: "msg-r",
          seq: 3,
          role: "user",
          blocks: [{ kind: "text", text: "reply" }],
          replyToMessageId: "msg-parent",
          replyQuote: "quoted line",
          replyPreview: { role: "bot", text: "parent text" },
        },
      }),
      event({
        type: "thread.message.updated",
        seq: 2,
        payload: { messageId: "msg-r", blocks: [{ kind: "text", text: "edited reply" }] },
      }),
    ]),
    reduceScenario("fallback failure envelope clamps each model diagnostic", baseSnapshot(), [
      event({ type: "run.started", seq: 1, runId: "run-1", payload: {} }),
      event({
        type: "run.failed",
        seq: 2,
        runId: "run-1",
        payload: {
          error: JSON.stringify({
            modelFallbackVersion: 1,
            primaryError: "p".repeat(400),
            backups: [
              { provider: "prov-a", modelId: "model-a", reason: "r".repeat(400), status: "failed" },
              { provider: "prov-b", modelId: "model-b", reason: "quota", status: "skipped" },
            ],
          }),
        },
      }),
    ]),
    reduceScenario(
      "started keeps the previous userId and routine fields",
      baseSnapshot({
        run: run({
          id: "run-1",
          userId: "user-9",
          routineId: "routine-1",
          routineName: "Morning",
          taskId: "task-9",
          startedAt: T1,
          createdAt: T1,
        }),
        activeRuns: [
          run({
            id: "run-1",
            userId: "user-9",
            routineId: "routine-1",
            routineName: "Morning",
            taskId: "task-9",
            startedAt: T1,
            createdAt: T1,
          }),
        ],
        cursor: 1,
      }),
      [
        event({
          type: "run.started",
          seq: 2,
          runId: "run-1",
          createdAt: T2,
          payload: { trigger: "resume" },
        }),
      ],
    ),
  ];
}

// ---------------------------------------------------------------- receipt scenarios

interface ReceiptScenario {
  name: string;
  initial: FixtureSnapshot | null;
  receipt: { botId: string; runId: string; taskId: string; createdAt?: string };
  terminalRunIds: string[];
  now: string;
  expected: FixtureSnapshot | null;
}

function receiptScenario(
  name: string,
  initial: LiveThreadSnapshot | null,
  receipt: ReceiptScenario["receipt"],
  terminalRunIds: string[] = [],
): ReceiptScenario {
  // The reference defaults createdAt to the wall clock, which no replay can pin; the fallback
  // itself is covered by the receipt that carries no createdAt against a fixed clock in the
  // port's own unit test. Every fixture receipt carries createdAt so the comparison is exact.
  const pinned = receipt.createdAt === undefined ? { ...receipt, createdAt: T2 } : receipt;
  const expected = applyThreadSendReceipt(initial, pinned, new Set(terminalRunIds), T2);
  return {
    name,
    initial: snapshotOf(initial),
    receipt: pinned,
    terminalRunIds,
    now: T2,
    expected: snapshotOf(expected),
  };
}

function receiptScenarios(): ReceiptScenario[] {
  return [
    receiptScenario("receipt shows the queued run at once", baseSnapshot(), {
      botId: "bot-1",
      runId: "run-1",
      taskId: "task-1",
      createdAt: T1,
    }),
    receiptScenario("receipt createdAt is carried into the queued run", baseSnapshot(), {
      botId: "bot-1",
      runId: "run-1",
      taskId: "task-1",
      createdAt: T1,
    }),
    receiptScenario(
      "a matching live run wins",
      baseSnapshot({
        run: run({ id: "run-1" }),
        activeRuns: [run({ id: "run-1" })],
      }),
      { botId: "bot-1", runId: "run-1", taskId: "task-1", createdAt: T1 },
    ),
    receiptScenario(
      "a queue-holding run refuses the receipt",
      baseSnapshot({
        run: run({ id: "run-0" }),
        activeRuns: [run({ id: "run-0" })],
      }),
      { botId: "bot-1", runId: "run-1", taskId: "task-1", createdAt: T1 },
    ),
    receiptScenario(
      "a waiting card holds no compute; the receipt queues behind it",
      baseSnapshot({
        run: run({ id: "run-0", status: "waiting_input" }),
        activeRuns: [run({ id: "run-0", status: "waiting_input" })],
      }),
      { botId: "bot-1", runId: "run-1", taskId: "task-1", createdAt: T1 },
    ),
    receiptScenario(
      "a terminal run never shows as queued again",
      baseSnapshot(),
      {
        botId: "bot-1",
        runId: "run-1",
        taskId: "task-1",
        createdAt: T1,
      },
      ["run-1"],
    ),
    receiptScenario("another bot's receipt is ignored", baseSnapshot(), {
      botId: "bot-2",
      runId: "run-1",
      taskId: "task-1",
      createdAt: T1,
    }),
    receiptScenario(
      "a group thread takes no direct receipt",
      baseSnapshot({ groupId: "group-1", botId: undefined }),
      {
        botId: "bot-1",
        runId: "run-1",
        taskId: "task-1",
        createdAt: T1,
      },
    ),
    receiptScenario("null snapshot stays null", null, {
      botId: "bot-1",
      runId: "run-1",
      taskId: "task-1",
      createdAt: T1,
    }),
  ];
}

// ---------------------------------------------------------------- refresh / live race

interface RefreshScenario {
  name: string;
  prev: FixtureSnapshot | null;
  next: FixtureSnapshot;
  preserveLoadedHistory: boolean;
  expected: FixtureSnapshot;
}

function refreshScenario(
  name: string,
  prev: LiveThreadSnapshot | null,
  next: LiveThreadSnapshot,
  preserveLoadedHistory = false,
): RefreshScenario {
  const expected = reconcileRefreshedThread(prev, next, null, preserveLoadedHistory).snapshot;
  return {
    name,
    prev: snapshotOf(prev),
    next: snapshotOf(next)!,
    preserveLoadedHistory,
    expected: snapshotOf(expected)!,
  };
}

function refreshScenarios(): RefreshScenario[] {
  const liveProgress = message({
    id: "progress:run-1",
    runId: "run-1",
    blocks: [{ kind: "progress", text: "streaming" }],
  });
  return [
    refreshScenario(
      "newer refresh replaces the snapshot",
      baseSnapshot({ cursor: 1 }),
      baseSnapshot({
        cursor: 5,
        messages: [message({ id: "msg-1", seq: 2 })],
        run: run({ id: "run-1" }),
        activeRuns: [run({ id: "run-1" })],
      }),
    ),
    refreshScenario(
      "older refresh cannot roll the live cursor back",
      baseSnapshot({
        cursor: 6,
        messages: [liveProgress],
        run: run({ id: "run-1" }),
        activeRuns: [run({ id: "run-1" })],
      }),
      baseSnapshot({
        cursor: 4,
        run: run({ id: "run-1", status: "queued" }),
        activeRuns: [run({ id: "run-1", status: "queued" })],
      }),
    ),
    refreshScenario(
      "older refresh hydrates the matching live run after optimistic stop",
      baseSnapshot({
        cursor: 6,
        messages: [liveProgress],
        run: null,
        activeRuns: [],
      }),
      baseSnapshot({ cursor: 4, run: run({ id: "run-1" }), activeRuns: [run({ id: "run-1" })] }),
    ),
    refreshScenario(
      "older refresh without matching progress keeps prev whole",
      baseSnapshot({
        cursor: 6,
        messages: [message({ id: "msg-1", seq: 2 })],
        run: null,
        activeRuns: [],
      }),
      baseSnapshot({ cursor: 4, run: run({ id: "run-2" }), activeRuns: [run({ id: "run-2" })] }),
    ),
    refreshScenario(
      "equal cursor refresh commits (ownership reconcile)",
      baseSnapshot({
        cursor: 4,
        run: run({ id: "run-1" }),
        activeRuns: [run({ id: "run-1" })],
      }),
      baseSnapshot({
        cursor: 4,
        run: run({ id: "run-1", status: "waiting_input" }),
        activeRuns: [run({ id: "run-1", status: "waiting_input" })],
      }),
    ),
    refreshScenario("another thread's refresh replaces wholesale", baseSnapshot({ cursor: 9 }), {
      ...baseSnapshot({ cursor: 1 }),
      threadId: "thread-2",
    }),
    refreshScenario("null prev takes the refresh", null, baseSnapshot({ cursor: 2 })),
    refreshScenario(
      "equal-cursor refresh keeps the event-sourced waiting_takeover",
      baseSnapshot({
        cursor: 4,
        run: run({ id: "run-1", status: "waiting_takeover" }),
        activeRuns: [run({ id: "run-1", status: "waiting_takeover" })],
      }),
      baseSnapshot({
        cursor: 4,
        run: run({ id: "run-1" }),
        activeRuns: [run({ id: "run-1" })],
      }),
    ),
    refreshScenario(
      "newer-cursor refresh replaces the waiting_takeover",
      baseSnapshot({
        cursor: 4,
        run: run({ id: "run-1", status: "waiting_takeover" }),
        activeRuns: [run({ id: "run-1", status: "waiting_takeover" })],
      }),
      baseSnapshot({
        cursor: 6,
        run: run({ id: "run-1" }),
        activeRuns: [run({ id: "run-1" })],
      }),
    ),
    refreshScenario(
      "preserveLoadedHistory keeps older pages under the recent one",
      baseSnapshot({
        cursor: 8,
        olderCursor: 1,
        messages: [
          message({ id: "old-1", seq: 1 }),
          message({ id: "old-2", seq: 2 }),
          message({ id: "msg-3", seq: 3 }),
        ],
      }),
      baseSnapshot({
        cursor: 8,
        olderCursor: 2,
        messages: [
          message({ id: "msg-3", seq: 3, blocks: [{ kind: "text", text: "new" }] }),
          message({ id: "msg-4", seq: 4 }),
        ],
      }),
      true,
    ),
    refreshScenario(
      "without preserveLoadedHistory the recent page stands alone",
      baseSnapshot({
        cursor: 8,
        olderCursor: 1,
        messages: [message({ id: "old-1", seq: 1 }), message({ id: "msg-3", seq: 3 })],
      }),
      baseSnapshot({
        cursor: 8,
        olderCursor: 2,
        messages: [message({ id: "msg-3", seq: 3 }), message({ id: "msg-4", seq: 4 })],
      }),
    ),
  ];
}

// ---------------------------------------------------------------- merge + terminal memory

interface MergeScenario {
  name: string;
  prev: FixtureSnapshot | null;
  next: FixtureSnapshot;
  preserveLoadedHistory: boolean;
  expected: FixtureSnapshot;
}

function mergeScenarios(): MergeScenario[] {
  const cases: {
    name: string;
    prev: LiveThreadSnapshot | null;
    next: LiveThreadSnapshot;
    preserve?: boolean;
  }[] = [
    {
      name: "merge keeps prev when its cursor is ahead",
      prev: baseSnapshot({ cursor: 7 }),
      next: baseSnapshot({ cursor: 3 }),
    },
    {
      name: "merge takes next at equal cursor",
      prev: baseSnapshot({ cursor: 3 }),
      next: baseSnapshot({ cursor: 3, messages: [message({ id: "m", seq: 1 })] }),
    },
    {
      name: "merge across threads takes next",
      prev: baseSnapshot({ cursor: 9 }),
      next: { ...baseSnapshot({ cursor: 1 }), threadId: "thread-2" },
    },
    { name: "merge with null prev takes next", prev: null, next: baseSnapshot({ cursor: 1 }) },
  ];
  return cases.map((c) => ({
    name: c.name,
    prev: snapshotOf(c.prev),
    next: snapshotOf(c.next)!,
    preserveLoadedHistory: c.preserve ?? false,
    expected: snapshotOf(mergeThreadSnapshot(c.prev, c.next, c.preserve ?? false))!,
  }));
}

interface TerminalScenario {
  name: string;
  initial: string[];
  events: EventSpec[];
  expected: string[];
}

function terminalScenarios(): TerminalScenario[] {
  const cases: { name: string; initial: string[]; events: EventSpec[] }[] = [
    {
      name: "terminal events remember their run",
      initial: [],
      events: [
        event({ type: "run.completed", seq: 1, runId: "run-1" }),
        event({ type: "run.failed", seq: 2, runId: "run-2" }),
        event({ type: "run.cancelled", seq: 3, runId: "run-3" }),
        event({ type: "thread.progress", seq: 4, runId: "run-4" }),
        event({ type: "run.completed", seq: 5 }),
      ],
    },
    {
      name: "the memory caps at 100 runs, oldest first",
      initial: Array.from({ length: 100 }, (_, i) => `old-${i}`),
      events: [event({ type: "run.completed", seq: 1, runId: "new-1" })],
    },
  ];
  return cases.map((c) => {
    const set = new Set(c.initial);
    for (const spec of c.events) rememberTerminalRun(set, spec);
    return { name: c.name, initial: c.initial, events: c.events, expected: [...set] };
  });
}

// ---------------------------------------------------------------- live blocks (direct)

interface BlocksCase {
  name: string;
  current: Json[];
  updates: ({ type: "progress"; payload: Json } | { type: "tool"; name: string })[];
  expected: Json[][];
}

function blocksCases(): BlocksCase[] {
  const scripted: { name: string; current: Json[]; updates: BlocksCase["updates"] }[] = [
    {
      name: "empty text update produces no tail",
      current: [],
      updates: [{ type: "progress", payload: { delta: "" } }],
    },
    {
      name: "pending tool waits for the sentence end",
      current: [],
      updates: [
        { type: "progress", payload: { delta: "Checking the" } },
        { type: "tool", name: "read_file" },
        { type: "progress", payload: { delta: " file now." } },
      ],
    },
    {
      name: "activity flush drops the narration",
      current: [],
      updates: [
        { type: "progress", payload: { delta: "Let me look." } },
        { type: "progress", payload: { activity: true, text: "Reading: notes.txt" } },
        { type: "tool", name: "read_file" },
      ],
    },
    {
      name: "reset re-appends waiting tools as steps",
      current: [
        { kind: "text", text: "Earlier answer." },
        {
          kind: "progress",
          text: "unfinished clause",
          pendingToolNames: ["web_search", "web_search"],
        },
      ],
      updates: [{ type: "progress", payload: { reset: true } }],
    },
    {
      name: "steps merge consecutive same-tool calls",
      current: [{ kind: "steps", steps: [{ label: "Web search", count: 2 }] }],
      updates: [
        { type: "tool", name: "web_search" },
        { type: "tool", name: "read_file" },
        { type: "tool", name: "read_file" },
      ],
    },
    {
      name: "text segments merge across flushes",
      current: [{ kind: "text", text: "First." }],
      updates: [
        { type: "progress", payload: { delta: " Second." } },
        { type: "tool", name: "echo" },
        { type: "progress", payload: { delta: "Third." } },
        { type: "tool", name: "echo" },
      ],
    },
  ];
  return scripted.map((c) => {
    let blocks = c.current as never[];
    const expected: Json[][] = [];
    for (const update of c.updates) {
      blocks = reduceLiveMessageBlocks(blocks, update) as never[];
      expected.push(JSON.parse(JSON.stringify(blocks)) as Json[]);
    }
    return { name: c.name, current: c.current, updates: c.updates, expected };
  });
}

// ---------------------------------------------------------------- export

export interface ThreadFixture {
  reduce: ReduceScenario[];
  receipt: ReceiptScenario[];
  refresh: RefreshScenario[];
  merge: MergeScenario[];
  terminal: TerminalScenario[];
  blocks: BlocksCase[];
}

export function generateThreadFixture(): ThreadFixture {
  return {
    reduce: [...progressScenarios(), ...runScenarios()],
    receipt: receiptScenarios(),
    refresh: refreshScenarios(),
    merge: mergeScenarios(),
    terminal: terminalScenarios(),
    blocks: blocksCases(),
  };
}
