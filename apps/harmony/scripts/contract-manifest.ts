// The Phase 1 consumption whitelist (design §4.3.1), as far as M1 decodes it. Every RPC view
// projects its consumed fields from the REAL appContract procedure's output schema — never a
// hand-written copy — so both a type mutation and a procedure rebind go red in the layer-1
// snapshot. Fields outside a view are ignored on device, so upstream changes there must not
// produce snapshot noise (review Q8). Grow the views in the milestone that consumes more, in
// the same PR as the decoder change. This is dev-time codegen input, not shipped code.

import { appContract, authCapabilitiesSchema } from "@rakazo/contracts";
import type { z } from "zod";

/** The output schema a real procedure declares; a missing one is a wiring error, not a view. */
function procedureOutput<T>(procedure: { "~orpc": { outputSchema?: T } }): T {
  const schema = procedure["~orpc"].outputSchema;
  if (!schema) throw new Error("contract procedure declares no output schema");
  return schema;
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

/** spaces/list: M1 reads only the default Space's identity for the me page; M2 grows this. */
export const spacesListView = spacesListOutput.pick({ current: true }).extend({
  current: spacesListOutput.shape.current.pick({ id: true, name: true }),
});

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
  "auth-capabilities": capabilitiesView,
};
