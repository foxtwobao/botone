// Attachment RPC fixture used by the Harmony device suite and the walkthrough.
import { bearer, json, rpcError } from "./fixture-http.mjs";

const artifacts = new Map();
const nonces = new Map();
let nextId = 0;
let uploadControl = {};

const targetOf = (input) => input.groupId ?? input.botId;

export function resetArtifacts() {
  artifacts.clear();
  nonces.clear();
  nextId = 0;
  uploadControl = {};
}

export function handleArtifactRpc(req, res, body) {
  const input = JSON.parse(body).json;
  const target = targetOf(input);
  if (bearer(req) !== "fake-token" || !target) {
    return rpcError(res, 401, "UNAUTHORIZED", "Session expired");
  }
  if (req.url.endsWith("/get")) {
    const artifact = artifacts.get(input.artifactId);
    return artifact && targetOf(artifact) === target
      ? json(res, 200, { json: artifact })
      : rpcError(res, 404, "NOT_FOUND", "Attachment unavailable");
  }
  const { name, mimeType, contentBase64, clientNonce } = input;
  const bytes = typeof contentBase64 === "string" ? Buffer.from(contentBase64, "base64") : null;
  if (!name || !mimeType || !bytes?.length || bytes.toString("base64") !== contentBase64) {
    return rpcError(res, 400, "BAD_REQUEST", "Invalid attachment");
  }
  if (uploadControl.failName === name) {
    return rpcError(res, 503, "UNAVAILABLE", "Upload unavailable");
  }
  const key = JSON.stringify([target, clientNonce]);
  const saved = clientNonce ? nonces.get(key) : undefined;
  const artifact = saved ?? {
    id: `attachment-${++nextId}`,
    botId: input.botId ?? null,
    groupId: input.groupId ?? null,
    runId: null,
    name,
    mimeType,
    contentBase64,
    size: bytes.length,
    description: null,
    version: 1,
    createdAt: new Date().toISOString(),
  };
  artifacts.set(artifact.id, artifact);
  if (clientNonce) nonces.set(key, artifact);
  const { contentBase64: _, ...metadata } = artifact;
  const delay = Math.min(30_000, Number(uploadControl.delay) || 0);
  if (delay <= 0) return json(res, 200, { json: metadata });
  const timer = setTimeout(() => json(res, 200, { json: metadata }), delay);
  // A client that cancels mid-wait half-opens the socket; ending it releases the connection
  // both sides, so the emulator's network stack cannot leak it into later tests' way.
  res.once("close", () => {
    clearTimeout(timer);
    res.destroy();
  });
}

/** True while the cancel test wants the upload body read slowly (see the server's walker). */
export function uploadSlowBody() {
  return uploadControl.slowBody === true;
}

/** Accumulates a request body, pacing the upload's chunks when the cancel test asks for it. */
export function collectBody(req, add) {
  const slow = req.url === "/rpc/artifacts/create" && uploadSlowBody();
  req.on("data", (chunk) => {
    add(chunk);
    if (slow) {
      req.pause();
      setTimeout(() => req.resume(), 1500);
    }
  });
}

export function controlArtifactFixture(res, body) {
  uploadControl = JSON.parse(body || "{}");
  return json(res, 200, { json: { ok: true } });
}

/** The fixture's attachment routes; false when the request is none of them. */
export function handleArtifactRoute(req, res, body) {
  if (req.url === "/__artifactControl") controlArtifactFixture(res, body);
  else if (req.url.startsWith("/rpc/artifacts/")) handleArtifactRpc(req, res, body);
  else return false;
  return true;
}

/** The request log keeps an upload's metadata but not its bytes: tests compare the rest. */
export function loggedBody(path, body) {
  return path === "/rpc/artifacts/create"
    ? JSON.stringify({ json: { ...JSON.parse(body).json, contentBase64: undefined } })
    : body;
}

/** The blocks a send carries, or null when it names an artifact this target does not own. */
export function attachmentSendPayload(input, messages) {
  const artifactsForMessage = (input.artifactIds ?? []).map((id) => artifacts.get(id));
  if (artifactsForMessage.some((artifact) => !artifact || targetOf(artifact) !== targetOf(input))) {
    return null;
  }
  const blocks = input.text ? [{ kind: "text", text: input.text }] : [];
  for (const { id, name, mimeType, size } of artifactsForMessage) {
    const kind = ["image/jpeg", "image/png", "image/webp", "image/gif"].includes(mimeType)
      ? "image"
      : "file";
    blocks.push({ kind, artifactId: id, name, mimeType, ...(kind === "file" ? { size } : {}) });
  }
  const parent = input.replyToMessageId
    ? messages.find((msg) => msg.id === input.replyToMessageId)
    : undefined;
  const replyToMessageId = parent?.id;
  const attachment =
    parent?.blocks.find((block) => block.kind === "image") ??
    parent?.blocks.find((block) => block.kind === "file");
  return {
    blocks,
    ...(parent && {
      replyToMessageId,
      replyPreview: {
        role: parent.role,
        author: parent.author,
        botId: parent.botId,
        text: parent.blocks
          .filter((block) => block.kind === "text")
          .map((block) => block.text)
          .join(" "),
        ...(attachment && { attachment }),
      },
    }),
  };
}

export function refuseImages(res, input) {
  if (
    uploadControl.confirmImages &&
    input.imageHandling !== "file" &&
    input.artifactIds?.some((id) => artifacts.get(id)?.mimeType.startsWith("image/"))
  ) {
    json(res, 409, {
      json: {
        code: "CONFLICT",
        status: 409,
        message: "This model cannot read images.",
        data: { reason: "model_image_input_unsupported" },
      },
    });
    return true;
  }
  return false;
}
