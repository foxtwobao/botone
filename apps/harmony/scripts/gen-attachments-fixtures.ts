import {
  ATTACHMENT_ALLOWED_MIME_TYPES,
  ATTACHMENT_IMAGE_MAX_EDGE,
  ATTACHMENT_IMAGE_QUALITY,
  ATTACHMENT_MAX_BYTES,
  ATTACHMENT_MAX_COUNT,
  artifactPreviewKind,
  attachmentMaxBytes,
  attachmentMaxCount,
  isAttachmentAudioMimeType,
  isAttachmentImageMimeType,
} from "@rakazo/contracts";
import {
  artifactTypeLabel,
  attachmentExtensionForMimeType,
  attachmentStoredName,
  decodeAttachmentBase64,
  formatFileSize,
  inferAttachmentMimeType,
  isStaticPng,
  messageBlockForArtifact,
  resolveComposerSendPlan,
} from "@rakazo/core";
import type { rpc } from "@rakazo/mobile/lib/api/api.js";
import { attachmentSkipReason } from "@rakazo/mobile/lib/composer/pick-attachments-filter.js";
import { fitImageSize, isInlineImageMimeType } from "@rakazo/mobile/lib/messages/inline-image.js";
import type { SendAttempt, SendPayload } from "@rakazo/mobile/lib/thread/send/thread-feedback.js";
import { deliverSend } from "@rakazo/mobile/lib/thread/send/thread-feedback.js";

const mimeTypes = [
  ...ATTACHMENT_ALLOWED_MIME_TYPES,
  "image/svg+xml",
  "image/jpeg;profile=step-screenshot",
  "text/html; charset=utf-8",
  "TEXT/PLAIN",
  "application/octet-stream",
  "",
];
const formats = ["en", "zh-CN", "zh-TW", "fr"];

function pngHeader(type: string): Buffer {
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13]),
    Buffer.from("IHDR"),
    Buffer.alloc(17),
    Buffer.alloc(4),
    Buffer.from(type),
  ]);
}

/** Preserve mobile's order and kwargs at the RPC boundary, including a partially uploaded retry. */
async function sendCase(
  group: boolean,
  text: string,
  count: number,
  reuseFirst: boolean,
  asFile: boolean,
) {
  const attachments = Array.from({ length: count }, (_, index) => ({
    id: `draft-${index}`,
    name: index ? "notes.txt" : "photo.png",
    mimeType: index ? ("text/plain" as const) : ("image/png" as const),
    contentBase64: "YWJj",
  }));
  const payload: SendPayload = {
    originThreadKey: "thread-probe",
    botTarget: group ? undefined : "bot-probe",
    groupTarget: group ? "group-probe" : undefined,
    displayText: text,
    replyPreview: null,
    reroutedToGroup: false,
    plan: resolveComposerSendPlan({ text, mentions: [], hasAttachments: count > 0 }),
    attachments,
    replyTargetId: group ? "message-probe" : undefined,
    replyQuote: null,
  };
  const attempt: SendAttempt = {
    payload,
    clientNonce: "nonce-probe",
    artifactIds: new Map(),
    session: 1,
    apiBase: "https://example.test",
    spaceId: "space-probe",
    userId: "user-probe",
    cacheSession: "cache-probe",
    state: "pending",
    imageHandling: asFile ? "file" : undefined,
  };
  if (reuseFirst) attempt.artifactIds.set("draft-0", "retained-artifact");
  const calls: { path: string; body: unknown; timeout?: number }[] = [];
  const request = (async (path: string, body: unknown, options?: { timeoutMs?: number }) => {
    calls.push({
      path,
      body: JSON.parse(JSON.stringify(body)),
      ...(options?.timeoutMs ? { timeout: options.timeoutMs } : {}),
    });
    return path === "artifacts/create"
      ? { id: `artifact-${calls.length}` }
      : { seq: 9, taskId: "task-probe", runId: "run-probe" };
  }) as typeof rpc;
  await deliverSend(payload, attempt, request);
  return {
    calls,
    blocks: attachments.map(({ name, mimeType, contentBase64 }, index) =>
      messageBlockForArtifact({
        id: attempt.artifactIds.get(`draft-${index}`)!,
        name,
        mimeType,
        size: decodeAttachmentBase64(contentBase64).length,
      }),
    ),
  };
}

export async function generateAttachmentsFixture() {
  const candidates: Array<{
    name: string;
    size: number;
    mimeType: string | null;
    existingCount: number;
  }> = [
    { name: "edge.pdf", size: ATTACHMENT_MAX_BYTES, mimeType: "application/pdf", existingCount: 0 },
    {
      name: "large.pdf",
      size: ATTACHMENT_MAX_BYTES + 1,
      mimeType: "application/pdf",
      existingCount: 0,
    },
    { name: "unknown", size: 1, mimeType: null, existingCount: 0 },
    {
      name: "extra.pdf",
      size: 1,
      mimeType: "application/pdf",
      existingCount: ATTACHMENT_MAX_COUNT,
    },
  ];
  return {
    constants: { imageMaxEdge: ATTACHMENT_IMAGE_MAX_EDGE, imageQuality: ATTACHMENT_IMAGE_QUALITY },
    limits: [null, {}, { maxUploadSizeBytes: 20 * 1024 * 1024, maxAttachmentsPerMessage: 8 }].map(
      (config) => ({
        config,
        bytes: attachmentMaxBytes(config),
        count: attachmentMaxCount(config),
      }),
    ),
    mime: mimeTypes.map((mimeType) => ({
      mimeType,
      image: isAttachmentImageMimeType(mimeType),
      audio: isAttachmentAudioMimeType(mimeType),
      inline: isInlineImageMimeType(mimeType),
      kind: artifactPreviewKind(mimeType),
      label: artifactTypeLabel(mimeType),
      extension: attachmentExtensionForMimeType(mimeType),
      storedName: attachmentStoredName("probe.original", mimeType),
    })),
    inference: [
      ["photo.JPG", ""],
      ["notes.md", "text/plain"],
      ["sheet.csv", "application/vnd.ms-excel"],
      ["archive", "application/x-zip-compressed"],
      ["archive", "application/x-rar"],
      ["archive", "application/x-7z"],
      ["clip", "audio/mp3"],
      ["clip", "audio/vnd.wave"],
      ["clip.m4a", "audio/aac"],
      ["unknown.exe", "constructor"],
      ["photo.heic", ""],
      ["file.pdf", "application/octet-stream"],
    ].map(([name, reported]) => ({
      name,
      reported,
      expected: inferAttachmentMimeType(name!, reported),
    })),
    staticPng: [...["IDAT", "acTL", "IEND"].map(pngHeader), Buffer.alloc(20)].map((bytes) => ({
      bytes: bytes.toString("base64"),
      expected: isStaticPng(bytes),
    })),
    fileSize: formats.flatMap((locale) =>
      [-1, 0, 512, 1536, 1024 ** 2 - 1, 1024 ** 4].map((bytes) => ({
        bytes,
        locale,
        expected: formatFileSize(bytes, locale),
      })),
    ),
    fit: [
      { width: 1, height: 10 },
      { width: 1600, height: 900 },
      { width: 500, height: 3000 },
    ].map((size) => ({
      size,
      expected: fitImageSize(size, 270, 360),
    })),
    skip: candidates.map((candidate) => ({
      ...candidate,
      expected: attachmentSkipReason(candidate, candidate.existingCount, 0) ?? "",
    })),
    send: [
      await sendCase(false, "Caption", 2, false, false),
      await sendCase(true, "", 2, true, true),
    ],
  };
}
