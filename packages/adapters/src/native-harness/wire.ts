import { z } from "zod";

const id = z.string().min(1).max(256);
export const executionScopeSchema = z
  .object({
    spaceId: id,
    userId: id,
    botId: id,
    threadId: id,
    computerId: id,
    profileId: id,
    revision: z.number().int().positive(),
  })
  .strict();
const session = z.object({ id, engineVersion: z.string().min(1).max(100) }).strict();
const fence = z.number().int().nonnegative().max(2_147_483_647);
const leaseExpiresAt = z.iso.datetime();
export const executionStartSchema = z
  .object({
    runId: id,
    scope: executionScopeSchema,
    fence,
    leaseExpiresAt,
    prompt: z
      .string()
      .min(1)
      .max(1024 * 1024),
    instructions: z.string().max(1024 * 1024),
    context: z
      .array(
        z
          .object({
            role: z.enum(["user", "assistant", "system"]),
            content: z.string().max(128 * 1024),
          })
          .strict(),
      )
      .max(200)
      .optional(),
    session: session.optional(),
    model: z.string().min(1).max(256).optional(),
  })
  .strict();
export const executionControlSchema = z
  .object({ runId: id, scope: executionScopeSchema, fence, generation: id })
  .strict();
export const executionAttachSchema = executionControlSchema.extend({
  after: z.number().int().nonnegative(),
  leaseExpiresAt,
});
export const executionStopSchema = executionControlSchema.omit({ generation: true });
export const executionResponseSchema = executionControlSchema.extend({
  requestId: id,
  answer: z.string().min(1).max(16_384),
});
export const executionToolResultSchema = executionControlSchema.extend({
  requestId: id,
  result: z.string().max(256 * 1024),
});
export const executionSteerSchema = executionControlSchema.extend({
  id,
  text: z
    .string()
    .min(1)
    .max(128 * 1024),
});
export const executionCapabilitiesSchema = z
  .object({
    images: z.boolean(),
    resume: z.boolean(),
    steer: z.boolean(),
    permissions: z.boolean(),
    questions: z.boolean(),
    tools: z.boolean(),
  })
  .strict();
const event = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("file"),
    name: z.string().min(1).max(256),
    content: z
      .string()
      .max(1_398_104)
      .regex(/^[A-Za-z0-9+/]*={0,2}$/),
  }),
  z.object({
    type: z.literal("tool_requested"),
    id,
    name: z.string().max(100),
    input: z.record(z.string(), z.unknown()),
  }),
  z.object({ type: z.literal("text"), text: z.string().max(1024 * 1024) }),
  z.object({ type: z.literal("session"), session }),
  z.object({
    type: z.literal("operation"),
    id,
    name: z.string().max(500),
    status: z.enum(["running", "completed", "failed"]),
    detail: z
      .string()
      .max(128 * 1024)
      .optional(),
  }),
  z.object({
    type: z.literal("interaction"),
    request: z.object({
      id,
      kind: z.enum(["permission", "question"]),
      title: z.string().max(16_384),
      detail: z
        .string()
        .max(128 * 1024)
        .optional(),
      actions: z.array(z.object({ id, label: z.string().max(500) })).max(100),
    }),
  }),
  z.object({ type: z.literal("interaction_closed"), id, status: z.enum(["delivered", "expired"]) }),
  z.object({
    type: z.literal("usage"),
    scope: z.enum(["run", "session"]).optional(),
    inputTokens: z.number().int().nonnegative().nullable(),
    outputTokens: z.number().int().nonnegative().nullable(),
    costUsd: z.number().nonnegative().nullable(),
  }),
  z.object({ type: z.literal("completed") }),
  z.object({ type: z.literal("cancelled") }),
  z.object({ type: z.literal("failed"), code: z.string().max(100) }),
]);
export const executionSnapshotSchema = z.object({
  generation: id,
  state: z.enum(["running", "completed", "cancelled", "failed"]),
  capabilities: executionCapabilitiesSchema,
  frames: z.array(z.object({ sequence: z.number().int().positive(), event })).max(128),
  nextSequence: z.number().int().nonnegative(),
});
