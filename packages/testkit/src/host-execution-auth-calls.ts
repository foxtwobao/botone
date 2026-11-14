export const hostExecutionAuthCalls = [
  [
    "executions/host/start",
    {
      botId: "missing",
      text: "fixture",
      clientNonce: "fixture",
      token: "offline-fixture-proof-with-32-characters",
      installationId: "fixture",
      profileId: "fixture",
      revision: 1,
      engineVersion: "fixture",
      target: "workspace",
    },
  ],
  [
    "executions/host/sync",
    { runId: "missing", token: "offline-fixture-proof-with-32-characters", frames: [] },
  ],
  [
    "executions/host/answer",
    {
      runId: "missing",
      token: "offline-fixture-proof-with-32-characters",
      messageId: "missing",
      answer: "deny",
    },
  ],
  [
    "executions/host/tool",
    {
      runId: "missing",
      token: "offline-fixture-proof-with-32-characters",
      id: "missing",
      call: { name: "computer_list_files", input: { path: "." } },
    },
  ],
] as const;
