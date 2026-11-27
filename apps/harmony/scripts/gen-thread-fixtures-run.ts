// Run-lifecycle reduce scenarios for the layer-2 thread fixtures, split out of
// gen-thread-fixtures.ts (the 1,000-line cap). Same contract: drive the REAL core reducer and
// pin every observable snapshot; the shared builders live in gen-thread-fixtures.ts.

import type { LiveThreadMessage, LiveThreadRun } from "@rakazo/core";
import type { ReduceScenario } from "./gen-thread-fixtures";
import { baseSnapshot, event, reduceScenario } from "./gen-thread-fixtures";

export const T1 = "2026-11-21T12:00:01.000Z";
export const T2 = "2026-11-21T12:00:02.000Z";

export function run(over: Partial<LiveThreadRun> & { id: string }): LiveThreadRun {
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
    startedAt: "2026-11-21T12:00:00.000Z",
    completedAt: null,
    createdAt: "2026-11-21T12:00:00.000Z",
    ...over,
  };
}

export function message(over: Partial<LiveThreadMessage> & { id: string }): LiveThreadMessage {
  return {
    threadId: "thread-1",
    role: "bot",
    blocks: [],
    createdAt: "2026-11-21T12:00:00.000Z",
    ...over,
  };
}

export function runScenarios(): ReduceScenario[] {
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
