import { oc } from "@orpc/contract";
import { z } from "zod";
import { Id } from "./ids.js";

export const ExecutionModelsSchema = z
  .array(z.object({ id: z.string().min(1).max(256), label: z.string().min(1).max(100) }))
  .max(500);

export const ExecutionProfileSchema = z.object({
  id: z.string(),
  revision: z.number().int().positive(),
  label: z.string(),
  engineVersion: z.string(),
  defaultModel: z.string().optional(),
  models: ExecutionModelsSchema.optional(),
  status: z.enum([
    "missing",
    "unsupported",
    "unauthenticated",
    "unverified",
    "unavailable",
    "stopped",
    "ready",
  ]),
});
export const ExecutionConnectionSchema = z.object({
  id: Id,
  computerId: Id,
  label: z.string(),
  online: z.boolean(),
  profiles: z.array(ExecutionProfileSchema),
});
export const BotExecutionSchema = z.object({
  connectionId: Id,
  profileId: z.string().min(1).max(256),
  revision: z.number().int().positive(),
  model: z.string().trim().min(1).max(256).nullable(),
});
export type BotExecutionConfiguration = z.infer<typeof BotExecutionSchema>;
export type ExecutionConnectionView = z.infer<typeof ExecutionConnectionSchema>;
export const executionContract = {
  list: oc.input(z.object({ botId: Id.optional() })).output(z.array(ExecutionConnectionSchema)),
  connect: oc
    .input(
      z.object({
        botId: Id,
        label: z.string().trim().min(1).max(100),
        url: z.string().url().max(2048),
        token: z.string().regex(/^[a-f0-9]{64}$/),
        privateEndpoint: z.boolean().default(false),
      }),
    )
    .output(z.object({ id: Id })),
  revoke: oc.input(z.object({ id: Id })).output(z.object({ ok: z.literal(true) })),
  get: oc.input(z.object({ botId: Id })).output(BotExecutionSchema.nullable()),
  configure: oc
    .input(
      z.object({
        botId: Id,
        configuration: BotExecutionSchema.nullable(),
        stopActiveRuns: z.boolean().optional(),
      }),
    )
    .output(z.object({ ok: z.literal(true) })),
};
