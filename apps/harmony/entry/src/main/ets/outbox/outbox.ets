// The outbox queue (B3): every send parks on disk before it uploads, and a send that fails or
// loses its response stays there as a "Not sent" bubble the user can retry or delete. Unlike
// mobile — which replays the whole queue at launch and on every connectivity window — HarmonyOS
// replays only on an explicit retry tap, or once per chat open for offline-queued entries while
// the server is reachable (a threads/send starts a model run; opening a chat should not start
// several). The queue mirrors the disk: park/failed/sent write through, restore re-reads.
import { hilog } from '@kit.PerformanceAnalysisKit';
import { rpc, captureContext, subscribeReachable } from '../net/rpc';
import { RpcError, errorText } from '../net/errors';
import { asRecord } from '../contract/decode';
import { readDraftBase64 } from '../thread/attachment-files';
import type { DraftAttachment } from '../thread/attachment-files';
import { RequestCancellation } from '../net/request-cancellation';
import { decodeSendOutput, sendTarget, threadSendBody } from '../thread/thread-send';
import { t } from '../i18n/i18n';
import { clearAll as clearDisk, ensureAdmitted, loadRecords, moveAttachments, removeRecord,
  saveRecord, unparkAttachments, hasAnyRecord } from './outbox-disk';
import { classifySendFailure } from './outbox-record';
import type { OutboxRecord } from './outbox-record';

/** What a bubble renders: the immutable record plus the traced bits the row key carries. */
@ObservedV2
export class OutboxEntry {
  readonly record: OutboxRecord;
  @Trace state: string;
  @Trace error: string = '';
  @Trace busy: boolean = false;

  constructor(record: OutboxRecord) {
    this.record = record;
    this.state = record.state;
    this.error = record.error;
  }

  sync(): void {
    this.state = this.record.state;
    this.error = this.record.error;
  }
}

@ObservedV2
export class Outbox {
  /** The signed-in account's records, as the last restore left them. */
  @Trace entries: OutboxEntry[] = [];
  /** Bumped whenever the entries change; the thread page reloads its row source on it. */
  @Trace revision: number = 0;
  /** An answered request proved the server reachable; replay decisions read this, nothing
   *  auto-sends. Sticky by design: only true is ever delivered, so one answered request keeps
   *  the queue eligible to replay until the app dies. */
  @Trace reachable: boolean = false;
  private context: Context | null = null;
  private sending: Set<string> = new Set();

  constructor() {
    // rpc.ets owns the seam (no import back): every answered request reports reachable here.
    subscribeReachable((reachable: boolean): void => {
      this.reachable = reachable;
    });
  }

  /** Bootstrap hands in the sandbox the records live in. */
  init(context: Context): void {
    this.context = context;
  }

  /** Loads the disk queue for one account on one server; other accounts' records stay on disk. */
  async restore(apiBase: string, userId: string): Promise<void> {
    if (this.context === null) {
      return;
    }
    let records: OutboxRecord[] = [];
    try {
      records = loadRecords(this.context);
    } catch (err) {
      // An unreadable queue is unknown, not empty: keep what is already on screen.
      hilog.warn(0, 'Outbox', 'Could not read the unsent messages');
      return;
    }
    const entries: OutboxEntry[] = [];
    for (const record of records) {
      if (record.apiBase === apiBase && record.userId === userId) {
        entries.push(new OutboxEntry(record));
      }
    }
    this.entries = entries;
    this.revision += 1;
  }

  /** This chat's bubbles; skipNonce hides the record a live composer attempt already owns. */
  entriesFor(botId: string, groupId: string, skipNonce: string): OutboxEntry[] {
    const found: OutboxEntry[] = [];
    for (const entry of this.entries) {
      const record = entry.record;
      if (record.botId === botId && record.groupId === groupId && record.nonce !== skipNonce) {
        found.push(entry);
      }
    }
    return found;
  }

  /** True when unsent messages exist, on screen or only on disk (the sign-out prompt). */
  hasUnsent(): boolean {
    return this.entries.length > 0
      || (this.context !== null && hasAnyRecord(this.context));
  }

  /**
   * Parks a send on disk before its upload starts. Returns false when the disk refused (the
   * caller keeps mobile's M6 in-memory path); throws the localized limit error when the queue
   * itself is over budget.
   */
  park(record: OutboxRecord, drafts: DraftAttachment[]): boolean {
    if (this.context === null) {
      return false;
    }
    // The cap is checked before anything moves: a refused park leaves the composer whole.
    ensureAdmitted(this.context, record.nonce);
    try {
      moveAttachments(this.context, record, drafts);
      saveRecord(this.context, record);
    } catch (err) {
      const message = err instanceof Error ? (err as Error).message : '';
      if (message === 'Too many unsent messages') {
        throw new RpcError(t('Too many unsent messages'));
      }
      hilog.warn(0, 'Outbox', 'Could not save the unsent message');
      removeRecord(this.context, record.nonce);
      return false;
    }
    this.putEntry(record);
    return true;
  }

  /** A parked attempt failed: classify like mobile, persist, and surface the bubble. */
  failed(record: OutboxRecord, error: RpcError): void {
    record.state = classifySendFailure(error.status, error.transport, error.timedOut, error.message);
    record.error = errorText(error, t('Failed to send message'));
    record.imageConfirmation = error.status === 409 && error.reason === 'model_image_input_unsupported';
    this.putEntry(record);
    this.persist(record);
  }

  /** The send completed: the record and its attachments leave the disk. */
  sent(nonce: string): void {
    if (this.context !== null) {
      removeRecord(this.context, nonce);
    }
    this.dropEntry(nonce);
  }

  /** A cancelled attempt goes back to the composer whole: files return, the record goes. */
  unpark(record: OutboxRecord, drafts: DraftAttachment[], originalPaths: string[]): void {
    if (this.context !== null) {
      unparkAttachments(this.context, record, drafts, originalPaths);
    }
    this.dropEntry(record.nonce);
  }

  /** Uploaded one more artifact: the record remembers so a replay skips it. Best effort. */
  progress(record: OutboxRecord): void {
    this.persist(record);
  }

  /** True when a file lives inside the outbox and a record owns it (the composer's cleanup). */
  owns(path: string): boolean {
    if (this.context === null) {
      return false;
    }
    return path.startsWith(`${this.context.filesDir}/outbox`);
  }

  /** The bubble's tap: uploads what is missing, resends with the original nonce (the server's
   *  clientNonce idempotency returns the same receipt for a send it already committed). */
  async retry(nonce: string): Promise<void> {
    const entry = this.find(nonce);
    if (entry === null || this.context === null || this.sending.has(nonce)) {
      return;
    }
    if (entry.busy) {
      // Another replay is already in flight (the open-time one); the bubble already shows its
      // busy state, so there is nothing a second send could add.
      return;
    }
    const record = entry.record;
    const cancellation = new RequestCancellation();
    this.sending.add(nonce);
    entry.busy = true;
    try {
      const context = await captureContext(record.spaceId || null);
      if (context.apiBase !== record.apiBase) {
        // Another server owns the screen now; the record waits for its own to return.
        return;
      }
      const ids: string[] = [];
      for (let index = 0; index < record.attachments.length; index += 1) {
        const uploaded = record.artifactIds[index] ?? '';
        if (uploaded) {
          ids.push(uploaded);
          continue;
        }
        const attachment = record.attachments[index];
        const body = sendTarget(record.botId, record.groupId);
        body['name'] = attachment.name;
        body['mimeType'] = attachment.mimeType;
        body['clientNonce'] = `${record.nonce}:${index}`;
        const draft: DraftAttachment = {
          path: attachment.path, name: attachment.name, mimeType: attachment.mimeType,
          size: attachment.size,
        };
        body['contentBase64'] = await readDraftBase64(draft, cancellation);
        const result = asRecord(await rpc('artifacts/create', body,
          { context: context, timeoutMs: 60_000 }));
        const id = result?.['id'];
        if (typeof id !== 'string' || !id) {
          throw new RpcError('Unexpected response from the server');
        }
        record.artifactIds[index] = id as string;
        ids.push(id as string);
        this.persist(record);
      }
      const sendBody = threadSendBody(record.botId, record.groupId, record.text, ids,
        record.replyToMessageId, record.nonce, record.imageHandling === 'file', record.replyQuote);
      const output = decodeSendOutput(await rpc('threads/send', sendBody, { context: context }));
      if (output === null) {
        throw new RpcError('Unexpected response from the server');
      }
      this.sent(nonce);
    } catch (err) {
      const error = err instanceof RpcError ? err as RpcError : new RpcError(String(err));
      record.state = classifySendFailure(error.status, error.transport, error.timedOut, error.message);
      record.error = errorText(error, t('Failed to send message'));
      record.imageConfirmation = error.status === 409
        && error.reason === 'model_image_input_unsupported';
      entry.sync();
      this.persist(record);
    } finally {
      this.sending.delete(nonce);
      entry.busy = false;
      this.revision += 1;
    }
  }

  /** The image caption of a parked send travels as a file instead (mobile's Send as file). */
  async sendAsFile(nonce: string): Promise<void> {
    const entry = this.find(nonce);
    if (entry === null || entry.record.imageHandling === 'file') {
      return;
    }
    entry.record.imageHandling = 'file';
    this.persist(entry.record);
    await this.retry(nonce);
  }

  /** The bubble's delete: gone from disk and screen, whatever its state. */
  discard(nonce: string): void {
    this.sent(nonce);
  }

  /** Sign-out and server switches clear the whole queue; the user confirmed (or never saw it). */
  clearAll(): void {
    if (this.context !== null) {
      clearDisk(this.context);
    }
    this.entries = [];
    this.revision += 1;
  }

  /** Called once per chat open: offline-queued entries retry now if the server answers (mobile
   *  replays at launch; HarmonyOS only when the user is looking at the chat). */
  replayQueued(botId: string, groupId: string): void {
    if (!this.reachable) {
      return;
    }
    for (const entry of this.entriesFor(botId, groupId, '')) {
      if (entry.record.state === 'queued') {
        void this.retry(entry.record.nonce);
      }
    }
  }

  /** The entry a nonce is parked under, or null (the store asks on a parked retry). */
  find(nonce: string): OutboxEntry | null {
    for (const entry of this.entries) {
      if (entry.record.nonce === nonce) {
        return entry;
      }
    }
    return null;
  }

  private putEntry(record: OutboxRecord): void {
    const existing = this.find(record.nonce);
    if (existing !== null) {
      existing.sync();
    } else {
      this.entries.push(new OutboxEntry(record));
    }
    this.revision += 1;
  }

  private dropEntry(nonce: string): void {
    const kept: OutboxEntry[] = [];
    for (const entry of this.entries) {
      if (entry.record.nonce !== nonce) {
        kept.push(entry);
      }
    }
    if (kept.length !== this.entries.length) {
      this.entries = kept;
      this.revision += 1;
    }
  }

  private persist(record: OutboxRecord): void {
    if (this.context === null) {
      return;
    }
    try {
      saveRecord(this.context, record);
    } catch (err) {
      // The earlier park already holds the message; a failed progress write only means the
      // replay re-uploads an artifact the server deduplicates by clientNonce.
    }
  }
}

export const outbox: Outbox = new Outbox();
