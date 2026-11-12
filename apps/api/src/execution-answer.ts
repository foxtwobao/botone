import { ORPCError } from "@orpc/server";
import { answerNativeInteraction } from "@rakazo/adapters";
import type { Actor } from "@rakazo/contracts";
import type { RouterDeps } from "./router.js";

/** Null lets the existing thread answer handler continue for built-in prompts. */
export async function answerExecutionInput(
  deps: RouterDeps,
  actor: Actor,
  threadId: string,
  input: { runId: string; messageId: string; answer: string },
): Promise<{ ok: true } | null> {
  const answered = await answerNativeInteraction(deps, {
    spaceId: actor.spaceId,
    userId: actor.userId,
    threadId,
    runId: input.runId,
    messageId: input.messageId,
    answer: input.answer,
  });
  if (answered === null) return null;
  if (!answered)
    throw new ORPCError("CONFLICT", { message: "This prompt is no longer awaiting an answer" });
  return { ok: true };
}
