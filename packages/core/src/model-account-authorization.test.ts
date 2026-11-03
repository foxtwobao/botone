import type { ThreadMessage } from "@rakazo/contracts";
import { expect, it } from "vitest";
import { modelAccountAuthorizationMessageIds } from "./model-account-authorization.js";

const prompt: Pick<ThreadMessage, "id" | "role" | "runId" | "blocks"> = {
  id: "prompt",
  role: "bot",
  runId: "run",
  blocks: [{ kind: "text", text: "Authorization required" }],
};
const run = {
  id: "run",
  userId: "owner",
  status: "waiting_input",
  modelAuthorizationRequired: true,
};

it("exposes the structured authorization action only for its owner's currently paused run", () => {
  expect(modelAccountAuthorizationMessageIds({ messages: [prompt], run }, "owner")).toEqual(
    new Set([prompt.id]),
  );
  expect(
    modelAccountAuthorizationMessageIds({ messages: [prompt], activeRuns: [run] }, "owner"),
  ).toEqual(new Set([prompt.id]));
  for (const userId of ["someone-else", undefined])
    expect(modelAccountAuthorizationMessageIds({ messages: [prompt], run }, userId).size).toBe(0);
  for (const status of ["running", "completed", "failed", "waiting_takeover"])
    expect(
      modelAccountAuthorizationMessageIds({ messages: [prompt], run: { ...run, status } }, "owner")
        .size,
    ).toBe(0);
  for (const message of [
    { ...prompt, role: "user" as const },
    { ...prompt, runId: "other-run" },
  ])
    expect(modelAccountAuthorizationMessageIds({ messages: [message], run }, "owner").size).toBe(0);
  expect(modelAccountAuthorizationMessageIds(null, "owner").size).toBe(0);
});

it("does not reuse old prompts for unrelated input waits and selects only the latest prompt", () => {
  expect(
    modelAccountAuthorizationMessageIds(
      { messages: [prompt], run: { ...run, modelAuthorizationRequired: false } },
      "owner",
    ).size,
  ).toBe(0);
  expect(
    modelAccountAuthorizationMessageIds(
      { messages: [prompt, { ...prompt, id: "newer" }], run },
      "owner",
    ),
  ).toEqual(new Set(["newer"]));
});
