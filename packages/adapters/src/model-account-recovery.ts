import type { ExternalModelAccountReference, JobPublisher } from "@rakazo/adapter-kit";
import { modelAccountAuthorizationCheckpoint, runContinueJob } from "@rakazo/adapter-kit";
import type { PrismaClient, Run } from "@rakazo/db";
import { IsolationError, requireMembership } from "@rakazo/db";
import type { ExecutorDeps } from "./executor-deps.js";
import { parseModelSecret } from "./pi-oauth.js";

export async function resumeModelAccountRuns(
  prisma: PrismaClient,
  jobs: JobPublisher,
  userId: string,
  reference: ExternalModelAccountReference,
): Promise<void> {
  const checkpoint = modelAccountAuthorizationCheckpoint(reference);
  let cursor: string | undefined;
  for (;;) {
    const runs = await prisma.run.findMany({
      where: {
        userId,
        status: "waiting_input",
        checkpoint,
        ...(cursor ? { id: { gt: cursor } } : {}),
      },
      orderBy: { id: "asc" },
      take: 100,
      select: { id: true, spaceId: true },
    });
    await Promise.all(
      runs.map(async (run) => {
        try {
          await requireMembership(prisma, userId, run.spaceId);
        } catch (error) {
          if (error instanceof IsolationError) return;
          throw error;
        }
        const changed = await prisma.run.updateMany({
          where: { id: run.id, userId, status: "waiting_input", checkpoint },
          data: { status: "queued", checkpoint: null, error: null, wakeAt: null },
        });
        if (changed.count === 1) await jobs.enqueue(runContinueJob(run.id)).catch(() => undefined);
      }),
    );
    if (runs.length < 100) return;
    cursor = runs.at(-1)!.id;
  }
}

export async function pauseModelAccountRun(
  deps: Pick<
    ExecutorDeps,
    "events" | "prisma" | "jobs" | "secretStore" | "externalModelKey" | "shutdownSignal"
  >,
  run: Pick<Run, "id" | "spaceId" | "threadId" | "botId" | "userId">,
  lease: { attemptId: string; workerId: string; fence: number },
  reference: ExternalModelAccountReference,
  credential: { secretId: string } | null,
): Promise<void> {
  const paused = await deps.events.pauseRunForInput({
    spaceId: run.spaceId,
    threadId: run.threadId,
    botId: run.botId,
    runId: run.id,
    attemptId: lease.attemptId,
    leaseOwner: lease.workerId,
    leaseFence: lease.fence,
    checkpoint: modelAccountAuthorizationCheckpoint(reference),
    blocks: [
      { kind: "text", text: "Authorize the model account in Settings to continue this task." },
    ],
  });
  if (!paused || !deps.externalModelKey || !credential) return;
  try {
    const row = await deps.prisma.secret.findFirst({
      where: { id: credential.secretId, userId: run.userId, spaceId: null },
    });
    if (!row) return;
    const secret = parseModelSecret(await deps.secretStore.load(row.ciphertext, row.id));
    if (secret.kind !== "openai_compatible") return;
    await deps.externalModelKey(run.userId, reference, secret.baseUrl, deps.shutdownSignal);
  } catch {
    return;
  }
  await resumeModelAccountRuns(deps.prisma, deps.jobs, run.userId, reference);
}
