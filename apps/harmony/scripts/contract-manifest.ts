// The Phase 1 consumption whitelist (design §4.3.1), as far as M2 decodes it. Every RPC view
// projects its consumed fields from the REAL appContract procedure's output schema — never a
// hand-written copy — so both a type mutation and a procedure rebind go red in the layer-1
// snapshot. Fields outside a view are ignored on device, so upstream changes there must not
// produce snapshot noise (review Q8). Grow the views in the milestone that consumes more, in
// the same PR as the decoder change. This is dev-time codegen input, not shipped code.

import { getEventIteratorSchemaDetails } from "@orpc/contract";
import { appContract, authCapabilitiesSchema, SpaceChangeKind } from "@rakazo/contracts";
import type { z } from "zod";
import { z as zod } from "zod";

/** The output schema a real procedure declares; a missing one is a wiring error, not a view. */
function procedureOutput<T>(procedure: { "~orpc": { outputSchema?: T } }): T {
  const schema = procedure["~orpc"].outputSchema;
  if (!schema) throw new Error("contract procedure declares no output schema");
  return schema;
}

/** The input schema a real procedure declares. */
function procedureInput<T>(procedure: { "~orpc": { inputSchema?: T } }): T {
  const schema = procedure["~orpc"].inputSchema;
  if (!schema) throw new Error("contract procedure declares no input schema");
  return schema;
}

/** The event schema an eventIterator procedure yields (its `returns` is the close value). */
function eventYields<T>(procedure: { "~orpc": { outputSchema?: unknown } }): T {
  const details = getEventIteratorSchemaDetails(procedureOutput(procedure));
  if (!details?.yields) throw new Error("contract procedure is not an event iterator");
  return details.yields as T;
}

const healthOutput = procedureOutput(appContract.health);
const meOutput = procedureOutput(appContract.me);
const spacesListOutput = procedureOutput(appContract.spaces.list);

/** health: consumed whole (server probe and version). */
export const healthView = healthOutput;

/** me: the account fields the sign-in flow and the me page read. */
export const meView = meOutput.pick({
  userId: true,
  email: true,
  name: true,
  spaceId: true,
  needsModel: true,
  defaultProvider: true,
  defaultModel: true,
});

// The roster row fields M2 reads. BotSchema/GroupSchema are the real element schemas the
// procedures declare; picking from them keeps every field bound to the contract (a rebind or a
// type mutation goes red). snoozedUntil is nullable-optional: a snoozed chat hides until it wakes.
const botSchema = procedureOutput(appContract.bots.list).element;
const groupSchema = procedureOutput(appContract.groups.list).element;

/** A bot row: identity color, unread, preview, run status, pinned order, snooze. */
export const botView = botSchema.pick({
  id: true,
  name: true,
  color: true,
  pinned: true,
  unread: true,
  preview: true,
  status: true,
  updatedAt: true,
  snoozedUntil: true,
});

/** A group row: no identity color (bots carry the only color), unread, preview, pinned, snooze. */
export const groupView = groupSchema.pick({
  id: true,
  name: true,
  pinned: true,
  unread: true,
  preview: true,
  updatedAt: true,
  snoozedUntil: true,
});

/** spaces/list: the default Space's identity plus its inbox roster (bots + groups). */
export const spacesListView = spacesListOutput.pick({ current: true }).extend({
  current: spacesListOutput.shape.current.pick({ id: true, name: true }).extend({
    bots: zod.array(botView),
    groups: zod.array(groupView),
  }),
});

/** bots/list and bots/listArchived: the same row shape, active and archived. */
export const botsListView = zod.array(botView);
export const botsListArchivedView = zod.array(botView);
/** groups/listArchived: archived group rows. */
export const groupsListArchivedView = zod.array(groupView);

/** archive/restore: a target id in, {ok:true} out. The write the SaveController pins. */
export const botArchiveInputView = procedureInput(appContract.bots.archive);
export const botArchiveOutputView = procedureOutput(appContract.bots.archive);
export const botRestoreInputView = procedureInput(appContract.bots.restore);
export const botRestoreOutputView = procedureOutput(appContract.bots.restore);
export const groupArchiveInputView = procedureInput(appContract.groups.archive);
export const groupArchiveOutputView = procedureOutput(appContract.groups.archive);
export const groupRestoreInputView = procedureInput(appContract.groups.restore);
export const groupRestoreOutputView = procedureOutput(appContract.groups.restore);

/** notifications/subscribe: the signal type enum the roster stream dispatches on (alert ignored). */
export const notificationsSubscribeView = eventYields<z.ZodObject<{ type: z.ZodEnum }>>(
  appContract.notifications.subscribe,
).pick({ type: true });

/** The Space change kinds the stream forwards to readers; each is one signal frame. */
export const spaceChangeKindView = SpaceChangeKind;

/** GET /api/auth/capabilities: better-auth REST, not an RPC procedure; the schema is the source. */
export const capabilitiesView = authCapabilitiesSchema.pick({
  sso: true,
  providers: true,
  passwordAuth: true,
  passwordReset: true,
  resetUrl: true,
  emailCode: true,
});

/** Every snapshot the layer-1 test pins, keyed by the file name under snapshots/. */
export const snapshotViews: Record<string, z.ZodType> = {
  health: healthView,
  me: meView,
  "spaces-list": spacesListView,
  "bots-list": botsListView,
  "bots-list-archived": botsListArchivedView,
  "groups-list-archived": groupsListArchivedView,
  "bot-archive-input": botArchiveInputView,
  "bot-archive-output": botArchiveOutputView,
  "bot-restore-input": botRestoreInputView,
  "bot-restore-output": botRestoreOutputView,
  "group-archive-input": groupArchiveInputView,
  "group-archive-output": groupArchiveOutputView,
  "group-restore-input": groupRestoreInputView,
  "group-restore-output": groupRestoreOutputView,
  "notifications-subscribe": notificationsSubscribeView,
  "space-change-kind": spaceChangeKindView,
  "auth-capabilities": capabilitiesView,
};
