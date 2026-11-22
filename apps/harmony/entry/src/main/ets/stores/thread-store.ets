// ThreadStore (design §6.3): one open thread's snapshot + stream + writes. The screen paints the
// store's observable rows; the stream commits reduced snapshots; sends/answers/stops go through
// SaveController (pinned context, single-flight, owned pending/error). markRead reports on open,
// on foreground, and when a new message arrives while the screen is shown. History pages prepend
// without losing live state. No timed re-read: the stream's own refresh paths are the only reads.
import { rpc } from '../net/rpc';
import { RpcError, errorText, isServerUnreachable } from '../net/errors';
import { SaveController } from '../query/save-controller';
import type { SaveSend } from '../query/save-controller';
import { currentSessionGeneration, selectedSpaceId } from '../net/session';
import { ThreadStream } from '../realtime/thread-stream';
import { foreground } from '../realtime/foreground';
import { applyThreadSendReceipt } from '../thread/thread-snapshot';
import { isRunWorking } from './roster-projection';
import type { LiveMessage, ThreadSnapshot } from '../thread/thread-snapshot';
import { decodeSendOutput, newClientNonce, sendReceipt } from '../thread/thread-send';
import { decodeThreadMessagePage } from '../thread/thread-decode';
import { isDeliveryMessage } from '../thread/block-view';
import { t } from '../i18n/i18n';

/** A transcript row: a day separator or a message (delivery messages never become rows). */
export class ThreadRow {
  type: string = 'message';
  /** The day label for a separator. */
  label: string = '';
  message: LiveMessage | null = null;
  /** The row's render key: content changes force a LazyForEach re-render (the M2 lesson). */
  key: string = '';
}

function dayKey(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) {
    return '';
  }
  return `${date.getFullYear()}-${date.getMonth() + 1}-${date.getDate()}`;
}

function dayLabel(iso: string, now: number): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) {
    return '';
  }
  const startOfDay = (d: Date): number => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const diff = Math.round((startOfDay(new Date(now)) - startOfDay(date)) / 86_400_000);
  if (diff <= 0) {
    return t('Today');
  }
  if (diff === 1) {
    return t('Yesterday');
  }
  return `${date.getFullYear()}/${date.getMonth() + 1}/${date.getDate()}`;
}

/** The visible transcript: day separators between messages, delivery messages hidden whole. */
export function projectRows(snapshot: ThreadSnapshot | null, now: number): ThreadRow[] {
  const rows: ThreadRow[] = [];
  if (snapshot === null) {
    return rows;
  }
  let lastDay = '';
  for (const message of snapshot.messages) {
    if (isDeliveryMessage(message.blocks)) {
      continue;
    }
    const day = dayKey(message.createdAt);
    if (day && day !== lastDay) {
      const separator = new ThreadRow();
      separator.type = 'day';
      separator.label = dayLabel(message.createdAt, now);
      separator.key = `day:${day}`;
      rows.push(separator);
      lastDay = day;
    }
    const row = new ThreadRow();
    row.type = 'message';
    row.message = message;
    row.key = messageKey(message);
    rows.push(row);
  }
  return rows;
}

/** The row key carries the rendered content so a changed message re-renders (M2 LazyForEach). */
export function messageKey(message: LiveMessage): string {
  let blocks = '';
  for (const block of message.blocks) {
    blocks += JSON.stringify(block);
  }
  return `${message.id}|${message.role}|${blocks}`;
}

/** Prepend an older history page without losing live state (core prependThreadHistoryPage). */
function prependPage(snapshot: ThreadSnapshot, page: ThreadSnapshot): ThreadSnapshot {
  const seen: Set<string> = new Set();
  const messages: LiveMessage[] = [];
  for (const message of [...page.messages, ...snapshot.messages]) {
    if (!seen.has(message.id)) {
      seen.add(message.id);
      messages.push(message);
    }
  }
  const next: ThreadSnapshot = {
    threadId: snapshot.threadId, cursor: snapshot.cursor, olderCursor: page.olderCursor,
    messages: messages, run: snapshot.run, activeRuns: snapshot.activeRuns,
  };
  if (snapshot.botId !== undefined) {
    next.botId = snapshot.botId;
  }
  if (snapshot.groupId !== undefined) {
    next.groupId = snapshot.groupId;
  }
  if (snapshot.members !== undefined) {
    next.members = snapshot.members;
  }
  return next;
}

@ObservedV2
export class ThreadStore {
  @Trace rows: ThreadRow[] = [];
  @Trace snapshot: ThreadSnapshot | null = null;
  @Trace loading: boolean = false;
  @Trace error: string = '';
  @Trace offline: boolean = false;
  @Trace connected: boolean = false;
  @Trace olderCursor: number | null = null;
  @Trace loadingOlder: boolean = false;
  /** The text of a failed send, so the composer can restore it for retry. */
  @Trace sendFailedText: string = '';
  readonly send: SaveController;
  readonly answer: SaveController;
  readonly stop: SaveController;
  private stream: ThreadStream | null = null;
  private botId: string = '';
  private groupId: string = '';
  private userId: string = '';
  private changeListeners: Set<() => void> = new Set();
  private offForeground: (() => void) | null = null;
  private started: boolean = false;
  private visible: boolean = false;

  constructor() {
    this.send = new SaveController({
      save: async (input: Record<string, Object>, sendRpc: SaveSend): Promise<void> => {
        const text = typeof input['text'] === 'string' ? input['text'] as string : '';
        const body: Record<string, Object> = {};
        if (this.groupId) {
          body['groupId'] = this.groupId;
        } else {
          body['botId'] = this.botId;
        }
        body['text'] = text;
        body['clientNonce'] = newClientNonce();
        const output = decodeSendOutput(await sendRpc('threads/send', body));
        if (output === null) {
          throw new RpcError('Unexpected response from the server');
        }
        // The receipt shows the queued run at once; the echo arrives over the open stream.
        if (!this.groupId && this.stream !== null) {
          const next = applyThreadSendReceipt(this.stream.current(),
            sendReceipt(this.botId, output), this.stream.terminalRunIds, new Date().toISOString());
          if (next !== this.stream.current()) {
            this.stream.commit(next);
            this.paint(next);
          }
        }
      },
      onSaved: (): void => {
        this.sendFailedText = '';
      },
      onFailed: (error: RpcError): void => {
        // A refusal is the user's choice: no error copy, the composer keeps the text.
        if (error.name === 'AiConsentBlocked' && error.message.includes('Review AI data sharing')) {
          this.send.reset();
        }
        const input = this.send.input;
        this.sendFailedText = input !== null && typeof input['text'] === 'string' ? input['text'] as string : '';
      },
    });
    this.answer = new SaveController({
      save: async (input: Record<string, Object>, sendRpc: SaveSend): Promise<void> => {
        const body: Record<string, Object> = {};
        if (this.groupId) {
          body['groupId'] = this.groupId;
        } else {
          body['botId'] = this.botId;
        }
        body['runId'] = input['runId'];
        body['messageId'] = input['messageId'];
        body['answer'] = input['answer'];
        await sendRpc('threads/answer', body);
        // The answer is saved once the server accepts it; the stream's settle refresh reconciles
        // the card. A failed refresh only delays the card (mobile thread-answer semantics).
      },
      onFailed: (error: RpcError): void => {
        if (error.name === 'AiConsentBlocked' && error.message.includes('Review AI data sharing')) {
          this.answer.reset();
        }
      },
    });
    this.stop = new SaveController({
      save: async (_input: Record<string, Object>, sendRpc: SaveSend): Promise<void> => {
        const body: Record<string, Object> = {};
        if (this.groupId) {
          body['groupId'] = this.groupId;
        } else {
          body['botId'] = this.botId;
        }
        await sendRpc('threads/stop', body);
      },
    });
  }

  subscribeChanges(listener: () => void): () => void {
    this.changeListeners.add(listener);
    return (): void => {
      this.changeListeners.delete(listener);
    };
  }

  private notifyChanges(): void {
    for (const listener of this.changeListeners) {
      listener();
    }
  }

  private paint(snapshot: ThreadSnapshot | null): void {
    this.snapshot = snapshot;
    this.rows = projectRows(snapshot, Date.now());
    this.olderCursor = snapshot?.olderCursor ?? null;
    this.notifyChanges();
  }

  /** The run the chat shows as working (queued/leased/running). */
  working(): boolean {
    return this.snapshot !== null && this.snapshot.run !== null && isRunWorking(this.snapshot.run.status);
  }

  /** The failed run's error copy, when the transcript should say why it stopped. */
  runError(): string {
    if (this.snapshot !== null && this.snapshot.run !== null && this.snapshot.run.status === 'failed') {
      return this.snapshot.run.error ?? '';
    }
    return '';
  }

  /** Open a chat: fresh state, the stream loads the snapshot and subscribes. */
  open(botId: string, groupId: string, userId: string): void {
    this.close();
    this.botId = botId;
    this.groupId = groupId;
    this.userId = userId;
    this.started = true;
    this.error = '';
    this.offline = false;
    this.loading = true;
    const input: Record<string, Object> = {};
    if (groupId) {
      input['groupId'] = groupId;
    } else {
      input['botId'] = botId;
    }
    this.stream = new ThreadStream({
      commit: (snapshot: ThreadSnapshot | null): void => {
        this.loading = false;
        this.paint(snapshot);
      },
      onError: (error: RpcError): void => {
        this.loading = false;
        this.error = errorText(error);
        this.offline = isServerUnreachable(error);
      },
      onUnread: (event): void => {
        // A bot message (or another member's) is new to this viewer; report read while shown.
        const payload = event.payload;
        const role = typeof payload['role'] === 'string' ? payload['role'] as string : 'bot';
        const author = payload['author'];
        const own = author !== null && typeof author === 'object'
          && (author as Record<string, Object>)['id'] === this.userId;
        if ((role === 'bot' || !own) && this.visible) {
          void this.markRead();
        }
      },
    });
    void this.stream.follow(input).then((): void => {
      this.connected = this.stream?.connected ?? false;
    });
    this.offForeground = foreground.subscribe((isForeground: boolean): void => {
      if (isForeground && this.started) {
        this.resume();
      } else if (!isForeground) {
        this.stream?.stop();
        this.connected = false;
      }
    });
    void this.markRead();
  }

  /** Returning to the same chat resumes from the applied cursor (no gaps, no re-read). */
  private resume(): void {
    if (this.stream === null || !this.started) {
      return;
    }
    const cursor = this.stream.cursor;
    const terminal = this.stream.terminalRunIds;
    const snapshot = this.stream.current();
    const input: Record<string, Object> = {};
    if (this.groupId) {
      input['groupId'] = this.groupId;
    } else {
      input['botId'] = this.botId;
    }
    this.stream.stop();
    this.stream = new ThreadStream({
      commit: (next: ThreadSnapshot | null): void => {
        this.paint(next);
      },
      onError: (error: RpcError): void => {
        this.error = errorText(error);
        this.offline = isServerUnreachable(error);
      },
    });
    this.stream.cursor = cursor;
    this.stream.loaded = snapshot !== null;
    for (const id of terminal) {
      this.stream.terminalRunIds.add(id);
    }
    if (snapshot !== null) {
      this.stream.commit(snapshot);
    }
    void this.stream.follow(input);
    this.connected = true;
    void this.markRead();
  }

  /** The screen is shown/hidden (markRead only reports while visible). */
  setVisible(visible: boolean): void {
    this.visible = visible;
    if (visible) {
      void this.markRead();
    }
  }

  async markRead(): Promise<void> {
    if (!this.started || (!this.botId && !this.groupId) || !selectedSpaceId()) {
      return;
    }
    const body: Record<string, Object> = {};
    if (this.groupId) {
      body['groupId'] = this.groupId;
    } else {
      body['botId'] = this.botId;
    }
    try {
      await rpc('threads/markRead', body);
    } catch (err) {
      // Read state is best-effort; the next open/foreground reports again.
    }
  }

  /** Load the next older history page (the screen's top-reach trigger). */
  async loadOlder(): Promise<void> {
    if (this.loadingOlder || this.olderCursor === null || this.snapshot === null || this.stream === null) {
      return;
    }
    this.loadingOlder = true;
    const body: Record<string, Object> = {};
    if (this.groupId) {
      body['groupId'] = this.groupId;
    } else {
      body['botId'] = this.botId;
    }
    body['before'] = this.olderCursor;
    const generation = currentSessionGeneration();
    try {
      const page = decodeThreadMessagePage(await rpc('threads/messages', body));
      if (generation !== currentSessionGeneration() || page === null || this.snapshot === null) {
        return;
      }
      if (page.threadId !== this.snapshot.threadId) {
        return;
      }
      const pageSnapshot: ThreadSnapshot = {
        threadId: page.threadId, cursor: this.snapshot.cursor, olderCursor: page.olderCursor,
        messages: page.messages, run: this.snapshot.run, activeRuns: this.snapshot.activeRuns,
      };
      const merged = prependPage(this.snapshot, pageSnapshot);
      this.stream.commit(merged);
      this.paint(merged);
    } catch (err) {
      const error = err instanceof RpcError ? err as RpcError : null;
      this.error = errorText(error);
    } finally {
      this.loadingOlder = false;
    }
  }

  /** Retry after a failed open (the offline banner's entry). */
  retry(): void {
    if (this.botId || this.groupId) {
      this.open(this.botId, this.groupId, this.userId);
    }
  }

  close(): void {
    this.started = false;
    this.stream?.stop();
    this.stream = null;
    this.offForeground?.();
    this.offForeground = null;
    this.snapshot = null;
    this.rows = [];
    this.olderCursor = null;
    this.error = '';
    this.offline = false;
    this.connected = false;
    this.loading = false;
    this.send.reset();
    this.answer.reset();
    this.stop.reset();
    this.notifyChanges();
  }
}
