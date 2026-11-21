// The Phase 1 consumption whitelist (design §4.3.1), as far as M1 decodes it. Each entry is the
// exact view the ArkTS decoders read: fields outside the view are ignored on device, so upstream
// changes there must not produce snapshot noise (review Q8). Grow the views in the milestone that
// consumes more, in the same PR as the decoder change.

import { authCapabilitiesSchema, MeSchema, SpaceNavigationSchema } from "@rakazo/contracts";
import { z } from "zod";

/** health: consumed whole (server probe and version). */
export const healthView = z.object({ ok: z.literal(true), version: z.string() });

/** me: the account fields the sign-in flow and the me page read. */
export const meView = MeSchema.pick({
  userId: true,
  email: true,
  name: true,
  spaceId: true,
  needsModel: true,
  defaultProvider: true,
  defaultModel: true,
});

/** spaces/list: M1 reads only the default Space's identity for the me page; M2 grows this. */
export const spacesListView = z.object({
  current: z.object({
    id: SpaceNavigationSchema.shape.current.shape.id,
    name: SpaceNavigationSchema.shape.current.shape.name,
  }),
});

/** GET /api/auth/capabilities: the fields the sign-in page renders from. */
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
