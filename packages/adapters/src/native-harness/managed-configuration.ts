import { z } from "zod";

export const executionOwnerSchema = z
  .object({
    spaceId: z.string().min(1).max(256),
    userId: z.string().min(1).max(256),
    computerId: z.string().min(1).max(256),
  })
  .strict();

export const executionConnectionSchema = z
  .object({
    url: z.string().url(),
    token: z.string().regex(/^[a-f0-9]{64}$/),
    allowPrivateEndpoint: z.boolean().default(false),
  })
  .strict()
  .superRefine((value, ctx) => {
    const url = new URL(value.url);
    if (
      url.username ||
      url.password ||
      url.search ||
      url.hash ||
      url.pathname !== "/" ||
      (url.protocol !== "https:" && !(url.protocol === "http:" && value.allowPrivateEndpoint))
    )
      ctx.addIssue({ code: "custom", message: "Invalid execution connection" });
  });

/** Deployment configuration is never accepted from an ordinary user's request. */
export function configuredExecutionConnection(value?: string) {
  if (!value?.trim()) return undefined;
  try {
    return executionConnectionSchema.parse(JSON.parse(value));
  } catch {
    throw new Error("Invalid EXECUTION_CONNECTION configuration");
  }
}

export const managedEnvironmentSchema = executionOwnerSchema
  .extend({
    homeKey: z.string().min(1).max(256),
    state: z.string().min(1).max(64),
    connectionRevision: z.string().regex(/^[a-f0-9]{64}$/),
    credentialId: z.string().min(1).max(256),
    credentialCreatedAt: z.string().datetime(),
    models: z.array(z.string().min(1).max(256)).max(500),
    defaults: z
      .object({
        responses: z.string().optional(),
        "anthropic-messages": z.string().optional(),
        "chat-completions": z.string().optional(),
      })
      .strict(),
    initialization: z.object({ url: z.string().url(), token: z.string().min(1) }).strict(),
  })
  .strict();
