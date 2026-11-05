import { z } from "zod";

export const creativeKindSchema = z.enum(["image", "video", "music"]);
export const creativeReferenceKindSchema = z.enum(["image", "video", "audio"]);
/** The service owns parameter schemas, combination rules and default presets. */
export const creativeCapabilitiesSchema = z
  .object({
    models: z
      .array(
        z.object({
          id: z.string().min(1).max(200),
          name: z.string().min(1).max(200).optional(),
          description: z.string().max(2_000).optional(),
          kind: creativeKindSchema,
          inputs: z
            .object({
              referenceImages: z.boolean(),
              referenceVideos: z.boolean().optional(),
              referenceAudios: z.boolean().optional(),
            })
            .optional(),
          /** Service-owned JSON Schema and supplemental rules; never preset values. */
          parameters: z.record(z.string(), z.json()).optional(),
          constraints: z.record(z.string(), z.json()).optional(),
          presets: z
            .array(
              z.object({
                id: z.string().min(1).max(200),
                parameters: z.record(z.string().max(100), z.json()),
              }),
            )
            .min(1)
            .max(100),
          defaultPreset: z.string().min(1).max(200),
        }),
      )
      .max(200),
    defaults: z.object({
      image: z.string().optional(),
      video: z.string().optional(),
      music: z.string().optional(),
    }),
    submission: z
      .object({
        presetOnly: z.boolean(),
        referenceMedia: z.boolean(),
        referenceKinds: z.array(z.string().min(1)).optional(),
        maxReferenceImageBytes: z.number().int().positive().optional(),
        maxReferenceMediaBytes: z.number().int().positive().optional(),
      })
      .optional(),
  })
  .superRefine((capabilities, ctx) => {
    const ids = capabilities.models.map((model) => model.id);
    if (
      new Set(ids).size !== ids.length ||
      Object.entries(capabilities.defaults).some(
        ([kind, id]) =>
          !capabilities.models.some((model) => model.id === id && model.kind === kind),
      ) ||
      capabilities.models.some(
        (model) =>
          !model.presets.some((preset) => preset.id === model.defaultPreset) ||
          new Set(model.presets.map((preset) => preset.id)).size !== model.presets.length,
      )
    )
      ctx.addIssue({ code: "custom", message: "Invalid model or preset selection" });
  });
export const creativeInputSchema = z.strictObject({
  kind: creativeKindSchema,
  model: z.string().min(1).max(200),
  preset: z.string().min(1).max(200).optional(),
  prompt: z.string().trim().min(1).max(4_000),
  parameters: z.record(z.string().min(1).max(100), z.json()).optional(),
  references: z.array(z.uuid()).max(100).optional(),
});
/** Tools select owned chat attachments; only the backend translates them to remote reference IDs. */
export const creativeToolInputSchema = creativeInputSchema.omit({ references: true }).extend({
  referenceArtifactIds: z.array(z.string().min(1).max(200)).max(100).optional(),
});
export const creativeReferenceSchema = z
  .object({
    id: z.uuid(),
    kind: creativeReferenceKindSchema.optional(),
    mimeType: z.string().regex(/^(image|video|audio)\//),
    bytes: z.number().int().positive(),
    width: z.number().int().positive().optional(),
    height: z.number().int().positive().optional(),
    durationMs: z.number().nonnegative().optional(),
  })
  .superRefine((reference, context) => {
    const kind = reference.mimeType.split("/")[0];
    if (
      (reference.kind && reference.kind !== kind) ||
      (kind === "image" && (!reference.width || !reference.height))
    )
      context.addIssue({ code: "custom", message: "Invalid reference metadata" });
  });
export const creativeJobSchema = z
  .object({
    operationId: z.uuid(),
    status: z.enum(["queued", "running", "succeeded", "failed", "unknown"]),
    outputs: z
      .array(
        z.object({
          id: z.string().min(1).max(200),
          mimeType: z.string().min(1).max(100),
          name: z.string().min(1).max(255),
        }),
      )
      .max(20),
    errorCode: z
      .string()
      .regex(/^[a-zA-Z0-9_]{1,80}$/)
      .optional(),
  })
  .superRefine((job, ctx) => {
    if (
      new Set(job.outputs.map((output) => output.id)).size !== job.outputs.length ||
      (!["succeeded", "unknown"].includes(job.status) && job.outputs.length > 0)
    )
      ctx.addIssue({ code: "custom", message: "Invalid job outputs" });
  });
export type CreativeCapabilities = z.infer<typeof creativeCapabilitiesSchema>;
export type CreativeInput = z.infer<typeof creativeInputSchema>;
export type CreativeToolInput = z.infer<typeof creativeToolInputSchema>;
export type CreativeReference = z.infer<typeof creativeReferenceSchema>;
export type CreativeReferenceKind = z.infer<typeof creativeReferenceKindSchema>;
export type CreativeJob = z.infer<typeof creativeJobSchema>;
