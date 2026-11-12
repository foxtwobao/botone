import { createHash } from "node:crypto";
import { createAdapterContext, supportsComputerExecution } from "@rakazo/adapter-kit";
import { personalComputerWhere, toComputerRef } from "@rakazo/adapters";
import type { Actor } from "@rakazo/contracts";
import type { RouterDeps } from "./router.js";

/** Provision only the selected, personally owned computer; never boot it to open settings. */
export async function ensureAutomaticExecution(
  deps: RouterDeps,
  actor: Actor,
  computerId: string | null,
) {
  if (!supportsComputerExecution(deps.sandbox) || !computerId) return;
  const computer = await deps.prisma.computer.findFirst({
    where: { id: computerId, ...personalComputerWhere(actor) },
  });
  if (!computer) return;
  const scope = { spaceId: actor.spaceId, userId: actor.userId, computerId };
  const id = `managed-${createHash("sha256").update(JSON.stringify(scope)).digest("hex")}`;
  const existing = await deps.prisma.executionConnection.findUnique({ where: { id } });
  if (existing?.revokedAt) return;
  if (!computer.providerRef)
    return { id, computerId, label: "Computer", online: false, profiles: [] };
  if (computer.state === "running" && deps.sandbox)
    await deps.sandbox.prepare(
      toComputerRef(computer),
      createAdapterContext(actor, "", "execution-initialization"),
    );
  const client = await deps.sandbox.execution(
    { ...toComputerRef(computer), id: computer.id },
    createAdapterContext(actor, "", "execution-discovery"),
  );
  if (!client) return;
  const plaintext = JSON.stringify(scope);
  if (existing && (await deps.secrets.load(existing.secretRef, id)) === plaintext) return;
  const description = await client.describe().catch(() => null);
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
