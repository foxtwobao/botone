import { createHash } from "node:crypto";
import { createAdapterContext } from "@rakazo/adapter-kit";
import {
  configuredExecutionConnection,
  HttpNativeExecutionProvider,
  personalComputerWhere,
  toComputerRef,
} from "@rakazo/adapters";
import type { Actor } from "@rakazo/contracts";
import type { RouterDeps } from "./router.js";

/** Provision only the selected, personally owned computer; never boot it to open settings. */
export async function ensureAutomaticExecution(
  deps: RouterDeps,
  actor: Actor,
  computerId: string | null,
) {
  const connection = configuredExecutionConnection(deps.env.executionConnection);
  if (!connection || !computerId) return;
  const computer = await deps.prisma.computer.findFirst({
    where: { id: computerId, ...personalComputerWhere(actor) },
  });
  if (!computer) return;
  const scope = { spaceId: actor.spaceId, userId: actor.userId, computerId };
  const id = `managed-${createHash("sha256").update(JSON.stringify(scope)).digest("hex")}`;
  const existing = await deps.prisma.executionConnection.findUnique({ where: { id } });
  if (existing?.revokedAt) return;
  if (computer.state === "running" && deps.sandbox)
    await deps.sandbox.prepare(
      toComputerRef(computer),
      createAdapterContext(actor, "", "execution-initialization"),
    );
  const plaintext = JSON.stringify({ ...connection, scope });
  if (existing && (await deps.secrets.load(existing.secretRef, id)) === plaintext) return;
  const description = await new HttpNativeExecutionProvider({ ...connection, scope })
    .describe()
    .catch(() => null);
  if (!description) return { id, computerId, label: "Computer", online: false, profiles: [] };
  // A lost journal is a different service, not permission to revive old dispatches.
  if (existing && existing.identity !== description.id) return;
  const secret = await deps.secrets.put(plaintext, createAdapterContext(actor, "", id), {
    recordId: id,
  });
  if (existing) {
    await deps.prisma.executionConnection.updateMany({
      where: { id, revokedAt: null, secretRef: existing.secretRef },
      data: { secretRef: secret.ref },
    });
  } else {
    await deps.prisma.executionConnection.upsert({
      where: { id },
      create: { id, ...scope, label: "Computer", identity: description.id, secretRef: secret.ref },
      update: {},
    });
  }
}
