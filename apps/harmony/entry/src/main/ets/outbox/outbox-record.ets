// The outbox record and its pure rules (B3): the on-disk failed-send shape, the field-by-field
// validation a load applies, and the send-failure classification ported from mobile
// thread-feedback.ts:434-447. No kit imports: the contract suite loads this file as TypeScript.
// mobile keeps the queue in one index file; HarmonyOS keeps one JSON per nonce (the layout that
// lets a single bad file be dropped without losing the rest).

/** The most unsent messages the disk admits (mobile thread-feedback.ts:173 OUTBOX_MAX_ENTRIES). */
export const OUTBOX_MAX_ENTRIES = 20;
/** The most disk the outbox may hold (mobile outbox-disk.ts:77 OUTBOX_MAX_BYTES). */
export const OUTBOX_MAX_BYTES = 50 * 1024 * 1024;

/** The send rejection a missing model produces (core run-error.ts MODEL_REQUIRED_SEND_ERROR).
 *  Stored errors are display text, so the match is on the string, like mobile's persisted check. */
export const MODEL_REQUIRED_SEND_ERROR_TEXT = 'Connect a model to start a run.';

export function isModelRequiredSendErrorText(error: string): boolean {
  return error.trim() === MODEL_REQUIRED_SEND_ERROR_TEXT;
}

export class OutboxAttachment {
  path: string = '';
  name: string = '';
  mimeType: string = '';
  size: number = 0;
}

/** One unsent message on disk (v1). error carries the server's display text; state is the
 *  mobile classification queued (retry when reachable) / failed (retryable) / refused (not). */
export class OutboxRecord {
  v: number = 1;
  nonce: string = '';
  apiBase: string = '';
  userId: string = '';
  spaceId: string = '';
  botId: string = '';
  groupId: string = '';
  text: string = '';
  replyToMessageId: string = '';
  replyQuote: string = '';
  imageHandling: string = 'confirm';
  artifactIds: string[] = [];
  attachments: OutboxAttachment[] = [];
  state: string = 'queued';
  error: string = '';
  imageConfirmation: boolean = false;
}

function asRecord(value: Object | null): Record<string, Object> | null {
  if (value === null || value === undefined || typeof value !== 'object' || Array.isArray(value)) {
    return null;
  }
  return value as Record<string, Object>;
}

function stringAt(record: Record<string, Object>, key: string): string | null {
  const value = record[key];
  return typeof value === 'string' ? value : null;
}

function numberAt(record: Record<string, Object>, key: string): number | null {
  const value = record[key];
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

/** Copy every declared field, or null when any is missing or of the wrong type: a record this
 *  app cannot trust is deleted whole, never partially kept (mobile's per-field load checks). */
export function parseOutboxRecord(value: Object | null): OutboxRecord | null {
  const record = asRecord(value);
  if (record === null || numberAt(record, 'v') !== 1) {
    return null;
  }
  const nonce = stringAt(record, 'nonce');
  if (nonce === null || !/^[A-Za-z0-9_-]{1,200}$/.test(nonce)) {
    return null;
  }
  const apiBase = stringAt(record, 'apiBase');
  const userId = stringAt(record, 'userId');
  if (apiBase === null || userId === null) {
    return null;
  }
  const state = stringAt(record, 'state');
  if (state !== 'queued' && state !== 'failed' && state !== 'refused') {
    return null;
  }
  const imageHandling = stringAt(record, 'imageHandling');
  if (imageHandling !== 'confirm' && imageHandling !== 'file') {
    return null;
  }
  const rawIds = record['artifactIds'];
  if (!Array.isArray(rawIds)) {
    return null;
  }
  const artifactIds: string[] = [];
  for (const id of rawIds as Object[]) {
    if (typeof id !== 'string') {
      return null;
    }
    artifactIds.push(id);
  }
  const rawAttachments = record['attachments'];
  if (!Array.isArray(rawAttachments)) {
    return null;
  }
  const attachments: OutboxAttachment[] = [];
  for (const raw of rawAttachments as Object[]) {
    const entry = asRecord(raw);
    if (entry === null) {
      return null;
    }
    const path = stringAt(entry, 'path');
    const name = stringAt(entry, 'name');
    const mimeType = stringAt(entry, 'mimeType');
    const size = numberAt(entry, 'size');
    if (path === null || name === null || mimeType === null || size === null || size < 0) {
      return null;
    }
    const attachment = new OutboxAttachment();
    attachment.path = path;
    attachment.name = name;
    attachment.mimeType = mimeType;
    attachment.size = size;
    attachments.push(attachment);
  }
  const imageConfirmation = record['imageConfirmation'];
  if (typeof imageConfirmation !== 'boolean') {
    return null;
  }
  const parsed = new OutboxRecord();
  parsed.v = 1;
  parsed.nonce = nonce;
  parsed.apiBase = apiBase;
  parsed.userId = userId;
  parsed.spaceId = stringAt(record, 'spaceId') ?? '';
  parsed.botId = stringAt(record, 'botId') ?? '';
  parsed.groupId = stringAt(record, 'groupId') ?? '';
  parsed.text = stringAt(record, 'text') ?? '';
  parsed.replyToMessageId = stringAt(record, 'replyToMessageId') ?? '';
  parsed.replyQuote = stringAt(record, 'replyQuote') ?? '';
  parsed.imageHandling = imageHandling;
  parsed.artifactIds = artifactIds;
  parsed.attachments = attachments;
  parsed.state = state;
  parsed.error = stringAt(record, 'error') ?? '';
  parsed.imageConfirmation = imageConfirmation;
  return parsed;
}

/** Mobile thread-feedback.ts:434-447, on primitives: offline or 429 waits for connectivity,
 *  a 4xx the server meant for this message is refused, everything else may be retried. A
 *  missing-model send stays retryable (adding a model fixes it), like mobile's check. */
export function classifySendFailure(status: number, transport: boolean, timedOut: boolean,
  message: string): string {
  const offline = transport || timedOut || status === 502 || status === 503 || status === 504
    || status === 429;
  if (offline) {
    return 'queued';
  }
  const refused = status >= 400 && status < 500 && status !== 408 && status !== 409
    && status !== 425 && status !== 426 && status !== 429 && !isModelRequiredSendErrorText(message);
  return refused ? 'refused' : 'failed';
}
