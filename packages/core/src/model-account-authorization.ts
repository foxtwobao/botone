import type { ThreadMessage } from "@rakazo/contracts";

/** Only the owner of a currently paused run sees its account authorization action. */
export function modelAccountAuthorizationMessageIds(
  snapshot: {
    messages: readonly Pick<ThreadMessage, "id" | "role" | "runId" | "blocks">[];
    run?: {
      id: string;
      status: string;
      userId?: string;
      modelAuthorizationRequired?: boolean;
    } | null;
    activeRuns?: readonly {
      id: string;
      status: string;
      userId?: string;
      modelAuthorizationRequired?: boolean;
    }[];
  } | null,
  userId: string | undefined,
): Set<string> {
  const result = new Set<string>();
  if (!snapshot || !userId) return result;
  const ownedRuns = new Set(
    (snapshot.activeRuns ?? (snapshot.run ? [snapshot.run] : []))
      .filter(
        (run) =>
          run.status === "waiting_input" && run.userId === userId && run.modelAuthorizationRequired,
      )
      .map((run) => run.id),
  );
  const seenRuns = new Set<string>();
  for (const message of [...snapshot.messages].reverse()) {
    if (
      message.role === "bot" &&
      message.runId &&
      ownedRuns.has(message.runId) &&
      !seenRuns.has(message.runId)
    ) {
      result.add(message.id);
      seenRuns.add(message.runId);
    }
  }
  return result;
}
