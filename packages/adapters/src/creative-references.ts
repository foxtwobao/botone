import { createHash } from "node:crypto";
import type { AdapterContext, ArtifactStore } from "@rakazo/adapter-kit";
import { ATTACHMENT_MAX_BYTES } from "@rakazo/contracts";
import type { PrismaClient } from "@rakazo/db";
import { z } from "zod";
import type { UserAccessCredential } from "./configured-apps.js";
import type {
  CreativeCapabilities,
  CreativeInput,
  CreativeReferenceKind,
  CreativeToolInput,
} from "./creative-contracts.js";
import { creativeReferenceKindSchema } from "./creative-contracts.js";
import type { CreativeProvider } from "./creative-provider.js";
import { CreativeServiceError } from "./creative-provider.js";

export const referencePlanSchema = z.object({
  maxBytes: z.number().int().positive(),
  artifacts: z.array(
    z.object({
      id: z.string(),
      storageKey: z.string(),
      size: z.number().int().positive(),
      hash: z.string(),
      maxBytes: z.number().int().positive().optional(),
    }),
  ),
  allowedKinds: z.array(creativeReferenceKindSchema).optional(),
  maxCounts: z
    .object({
      image: z.number().nonnegative().optional(),
      video: z.number().nonnegative().optional(),
      audio: z.number().nonnegative().optional(),
    })
    .optional(),
  referenceSeconds: z.number().nonnegative().optional(),
  mode: z.enum(["frames", "reference"]).optional(),
  requireImage: z.boolean().optional(),
  audioOnly: z.boolean().optional(),
});
export type ReferencePlan = z.infer<typeof referencePlanSchema>;
export const referenceTransferSchema = z.object({
  digest: z.string(),
  referenceId: z.uuid().optional(),
  kind: creativeReferenceKindSchema.optional(),
  durationMs: z.number().nonnegative().optional(),
});
type Transfer = z.infer<typeof referenceTransferSchema>;
type Dependencies = { prisma: PrismaClient; artifacts: ArtifactStore; maxUploadSizeBytes?: number };

function mediaKind(mimeType: string): CreativeReferenceKind {
  const parsed = creativeReferenceKindSchema.safeParse(mimeType.split("/")[0]);
  if (!parsed.success) throw new CreativeServiceError("unsupported_media", 415);
  return parsed.data;
}
function referenceError(kind: CreativeReferenceKind, size: boolean): CreativeServiceError {
  return new CreativeServiceError(
    size
      ? kind === "image"
        ? "reference_image_too_large"
        : "reference_media_too_large"
      : kind === "image"
        ? "invalid_reference_image"
        : "invalid_reference_media",
    size ? 413 : 422,
  );
}

async function scopedArtifacts(
  deps: Dependencies,
  context: AdapterContext,
  threadId: string,
  ids: string[],
) {
  const thread = await deps.prisma.thread.findFirst({
    where: { id: threadId, spaceId: context.spaceId, userId: context.userId },
  });
  if (!thread) throw new CreativeServiceError("forbidden", 403);
  const rows = await deps.prisma.artifact.findMany({
    where: {
      id: { in: ids },
      userId: context.userId,
      spaceId: context.spaceId,
      ...(thread.groupId ? { groupId: thread.groupId } : { botId: context.botId, groupId: null }),
    },
  });
  const byId = new Map(rows.map((row) => [row.id, row]));
  return ids.map((id) => {
    const row = byId.get(id);
    if (!row) throw new CreativeServiceError("not_found", 404);
    mediaKind(row.mimeType);
    return row;
  });
}

/** Freeze the selected owned attachments and the service's advertised byte limit before uploading. */
export async function planCreativeReferences(
  deps: Dependencies,
  context: AdapterContext,
  threadId: string,
  input: CreativeToolInput,
  catalog: CreativeCapabilities,
): Promise<ReferencePlan> {
  const model = catalog.models.find(
    (model) => model.id === input.model && model.kind === input.kind,
  );
  const ids = input.referenceArtifactIds ?? [];
  if (input.kind === "music" || !model || catalog.submission?.referenceMedia !== true)
    throw new CreativeServiceError("invalid_parameters", 422);
  const kinds: CreativeReferenceKind[] = ["image", "video", "audio"];
  const permissions = {
    image: model.inputs?.referenceImages,
    video: input.kind === "video" && model.inputs?.referenceVideos,
    audio: input.kind === "video" && model.inputs?.referenceAudios,
  };
  const allowedKinds = kinds.filter(
    (kind) => permissions[kind] && catalog.submission?.referenceKinds?.includes(kind),
  );
  const limits = {
    image: catalog.submission.maxReferenceImageBytes,
    video: catalog.submission.maxReferenceMediaBytes,
    audio: catalog.submission.maxReferenceMediaBytes,
  };
  const constraints = model.constraints ?? {};
  const maximums = {
    image: input.kind === "image" ? constraints.maxReferences : constraints.maxImages,
    video: constraints.maxVideos,
    audio: constraints.maxAudios,
  };
  const maxCounts: NonNullable<ReferencePlan["maxCounts"]> = {};
  for (const kind of kinds)
    if (typeof maximums[kind] === "number" && maximums[kind] >= 0) maxCounts[kind] = maximums[kind];
  const rows = await scopedArtifacts(deps, context, threadId, ids);
  const artifacts = rows.map(({ id, storageKey, size, hash, mimeType }) => {
    const kind = mediaKind(mimeType);
    // Audio-only MP4 and video MP4 share a container; trust the upload's byte-derived kind.
    const possible =
      mimeType === "video/mp4" || mimeType === "audio/mp4" ? ["video", "audio"] : [kind];
    if (
      !possible.some((kind) => allowedKinds.includes(kind as CreativeReferenceKind)) ||
      !limits[kind]
    )
      throw new CreativeServiceError("invalid_parameters", 422);
    const maxBytes = Math.min(limits[kind]!, deps.maxUploadSizeBytes ?? ATTACHMENT_MAX_BYTES);
    if (size <= 0) throw referenceError(kind, false);
    if (size > maxBytes) throw referenceError(kind, true);
    return { id, storageKey, size, hash, maxBytes };
  });
  const mode = input.kind === "video" ? input.parameters?.mode : undefined;
  if (mode !== undefined && (typeof mode !== "string" || !["frames", "reference"].includes(mode)))
    throw new CreativeServiceError("invalid_parameters", 422);
  // Preflight unambiguous counts; MP4 classification is finalized by the service.
  for (const kind of kinds)
    if (
      maxCounts[kind] !== undefined &&
      rows.filter(
        (row) =>
          row.mimeType.startsWith(`${kind}/`) && !["video/mp4", "audio/mp4"].includes(row.mimeType),
      ).length > maxCounts[kind]!
    )
      throw new CreativeServiceError("invalid_parameters", 422);
  return {
    maxBytes: Math.max(...artifacts.map((row) => row.maxBytes)),
    artifacts,
    allowedKinds,
    maxCounts,
    ...(typeof constraints.referenceSeconds === "number" && constraints.referenceSeconds >= 0
      ? { referenceSeconds: constraints.referenceSeconds }
      : {}),
    ...(mode === "frames" || mode === "reference" ? { mode } : {}),
    ...(typeof constraints.requireImage === "boolean"
      ? { requireImage: constraints.requireImage }
      : {}),
    ...(typeof constraints.audioOnly === "boolean" ? { audioOnly: constraints.audioOnly } : {}),
  };
}

function validateReferenceInputs(plan: ReferencePlan, references: Transfer[]) {
  const counts = { image: 0, video: 0, audio: 0 };
  const durations = { video: 0, audio: 0 };
  for (const reference of references) {
    const kind = reference.kind ?? "image"; // Existing persisted image-only receipts have no kind.
    if (!(plan.allowedKinds ?? ["image"]).includes(kind))
      throw new CreativeServiceError("invalid_parameters", 422);
    counts[kind]++;
    if (kind !== "image" && plan.referenceSeconds !== undefined) {
      if (reference.durationMs === undefined || reference.durationMs <= 0)
        throw new CreativeServiceError("invalid_reference_media", 422);
      durations[kind] += reference.durationMs;
    }
  }
  for (const kind of ["image", "video", "audio"] as const)
    if (plan.maxCounts?.[kind] !== undefined && counts[kind] > plan.maxCounts[kind]!)
      throw new CreativeServiceError("invalid_parameters", 422);
  if (
    plan.referenceSeconds !== undefined &&
    (durations.video > plan.referenceSeconds * 1_000 ||
      durations.audio > plan.referenceSeconds * 1_000)
  )
    throw new CreativeServiceError("invalid_parameters", 422);
  if (
    (plan.mode === "frames" && (counts.video || counts.audio)) ||
    (plan.requireImage && !counts.image) ||
    (plan.audioOnly === false && counts.audio > 0 && !counts.image && !counts.video)
  )
    throw new CreativeServiceError("invalid_parameters", 422);
}

/** Each digest and upload receipt commits under the operation lease before the billed PUT. */
export async function uploadCreativeReferences(options: {
  deps: Dependencies;
  context: AdapterContext;
  threadId: string;
  plan: ReferencePlan;
  identity: () => Promise<UserAccessCredential>;
  provider: CreativeProvider;
  transfers: Record<string, Transfer>;
  save(): Promise<boolean>;
}): Promise<string[] | null> {
  const { deps, context, plan, transfers } = options;
  const rows = await scopedArtifacts(
    deps,
    context,
    options.threadId,
    plan.artifacts.map((row) => row.id),
  );
  const ids: string[] = [];
  const uploaded: Transfer[] = [];
  for (let index = 0; index < plan.artifacts.length; index++) {
    const source = plan.artifacts[index]!;
    const row = rows[index]!;
    if (
      row.storageKey !== source.storageKey ||
      row.size !== source.size ||
      row.hash !== source.hash
    )
      throw new CreativeServiceError("operation_conflict", 409);
    const key = createHash("sha256").update(source.id).digest("hex");
    if (!transfers[key]?.referenceId) {
      const bytes = await deps.artifacts.get(row.storageKey, context);
      if (!bytes.byteLength) throw referenceError(mediaKind(row.mimeType), false);
      if (bytes.byteLength !== source.size)
        throw new CreativeServiceError("operation_conflict", 409);
      if (bytes.byteLength > (source.maxBytes ?? plan.maxBytes))
        throw referenceError(mediaKind(row.mimeType), true);
      const digest = createHash("sha256").update(bytes).digest("hex");
      if (transfers[key] && transfers[key].digest !== digest)
        throw new CreativeServiceError("operation_conflict", 409);
      transfers[key] = { digest };
      if (!(await options.save())) return null;
      const reference = await options.provider.uploadReference(
        await options.identity(),
        bytes,
        context.signal,
      );
      transfers[key] = {
        digest,
        referenceId: reference.id,
        kind: reference.kind ?? mediaKind(reference.mimeType),
        ...(reference.durationMs !== undefined ? { durationMs: reference.durationMs } : {}),
      };
      if (!(await options.save())) return null;
    }
    ids.push(transfers[key]!.referenceId!);
    uploaded.push(transfers[key]!);
  }
  validateReferenceInputs(plan, uploaded);
  return ids;
}

export function creativeSubmission(input: CreativeToolInput, references?: string[]): CreativeInput {
  const { referenceArtifactIds: _local, ...request } = input;
  return { ...request, ...(references?.length ? { references } : {}) };
}
