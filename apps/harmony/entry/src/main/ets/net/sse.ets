// SSE over POST (design §1.3/§5.1), isomorphic to apps/mobile/lib/api/api-live.ts:
// frames split on two consecutive LF bytes (a CRLF blank line is NOT a boundary — the verified
// server wire format is single-LF), data: lines trimmed and joined without separator, [DONE]
// and heartbeat skipped, bad JSON skipped silently, a frame over 16MB throws, an incomplete
// tail frame at EOF is dropped. The parser is pure bytes→events so fixtures replay it offline;
// the transport wraps requestInStream with the 45s no-chunk idle rule (any byte resets it).
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { MAX_RPC_RESPONSE_BYTES, RPC_TIMEOUT_MS } from './http';
import { RpcError } from './errors';

export const IDLE_TIMEOUT_MS = 45_000;

export type SseEvent = Record<string, Object>;

export class SseParser {
  private onEvent: (event: SseEvent) => void;
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  private scratch: Uint8Array | null = null;
  private used: number = 0;
  private previousLf: boolean = false;

  constructor(onEvent: (event: SseEvent) => void) {
    this.onEvent = onEvent;
  }

  private append(bytes: Uint8Array): void {
    const required = this.used + bytes.byteLength;
    if (this.scratch === null || this.scratch.byteLength < required) {
      const capacity = Math.min(MAX_RPC_RESPONSE_BYTES,
        Math.max(required, this.scratch !== null ? this.scratch.byteLength * 2 : 1024));
      const grown = new Uint8Array(capacity);
      if (this.scratch !== null && this.used > 0) {
        grown.set(this.scratch.subarray(0, this.used));
      }
      this.scratch = grown;
    }
    this.scratch.set(bytes, this.used);
    this.used = required;
  }

  private emitFrame(bytes: Uint8Array): void {
    const lines = this.decoder.decodeToString(bytes).split('\n');
    const parts: string[] = [];
    for (const line of lines) {
      if (line.startsWith('data:')) {
        parts.push(line.slice(5).trim());
      }
    }
    const data = parts.join('');
    if (!data || data === '[DONE]') {
      return;
    }
    let parsed: Object;
    try {
      parsed = JSON.parse(data);
    } catch (err) {
      // Malformed frames do not interrupt the subscription.
      return;
    }
    if (parsed === null || typeof parsed !== 'object') {
      return;
    }
    const envelope = parsed as Record<string, Object>;
    const json = envelope['json'];
    if (json === null || json === undefined || typeof json !== 'object') {
      return;
    }
    const event = json as Record<string, Object>;
    const type = event['type'];
    // Heartbeats prove liveness only; forwarding one would advance the caller's cursor.
    if (typeof type === 'string' && (type as string) !== 'heartbeat') {
      this.onEvent(event);
    }
  }

  /** Feed one network chunk; throws RangeError when a frame exceeds the byte budget. */
  feed(value: Uint8Array): void {
    let start = 0;
    for (let index = 0; index < value.byteLength; index += 1) {
      if (this.used + index - start >= MAX_RPC_RESPONSE_BYTES) {
        throw new RangeError(`SSE frame exceeds ${MAX_RPC_RESPONSE_BYTES} bytes`);
      }
      const isLf = value[index] === 10;
      if (this.previousLf && isLf) {
        let frame = value.subarray(start, index + 1);
        if (this.used > 0) {
          this.append(frame);
          frame = (this.scratch as Uint8Array).subarray(0, this.used);
        }
        this.emitFrame(frame);
        this.used = 0;
        this.previousLf = false;
        start = index + 1;
      } else {
        this.previousLf = isLf;
      }
    }
    if (start < value.byteLength) {
      this.append(value.subarray(start));
    }
  }
}

export class SseHandle {
  /** Resolves on clean EOF or close; rejects on transport failure, non-2xx, or idle timeout. */
  readonly done: Promise<void>;
  private stop: () => void;

  constructor(done: Promise<void>, stop: () => void) {
    this.done = done;
    this.stop = stop;
  }

  /** Intentional stop: done resolves, the stream is destroyed. */
  close(): void {
    this.stop();
  }
}

/**
 * Opens one SSE stream. A half-open socket never reports done, so 45s without any chunk ends
 * the stream with a rejection the realtime layer treats as a disconnect (M0 S3: an abrupt
 * close rejects the requestInStream promise itself — same handling).
 */
export function openSse(url: string, headers: Record<string, string>, body: string,
  onEvent: (event: SseEvent) => void): SseHandle {
  const request = http.createHttp();
  const parser = new SseParser(onEvent);
  let resolveDone: () => void = (): void => {};
  let rejectDone: (error: RpcError) => void = (): void => {};
  const done = new Promise<void>((resolve: () => void, reject: (error: RpcError) => void): void => {
    resolveDone = resolve;
    rejectDone = reject;
  });
  let settled = false;
  let ended = false;
  let code = 0;
  let idleTimer: number = -1;

  const cleanup = (): void => {
    if (idleTimer !== -1) {
      clearTimeout(idleTimer);
      idleTimer = -1;
    }
    request.destroy();
  };
  const fail = (error: RpcError): void => {
    if (settled) {
      return;
    }
    settled = true;
    cleanup();
    rejectDone(error);
  };
  const finish = (): void => {
    if (settled) {
      return;
    }
    settled = true;
    cleanup();
    resolveDone();
  };
  const armIdle = (): void => {
    if (idleTimer !== -1) {
      clearTimeout(idleTimer);
    }
    idleTimer = setTimeout(() => {
      fail(new RpcError('SSE idle timeout', 0, '', -1, false, true));
    }, IDLE_TIMEOUT_MS);
  };

  request.on('dataReceive', (data: ArrayBuffer) => {
    armIdle();
    try {
      parser.feed(new Uint8Array(data));
    } catch (err) {
      // A frame over the byte budget throws RangeError; the stream ends as a disconnect.
      const message = err instanceof Error ? (err as Error).message : String(err);
      fail(new RpcError(message, 0, '', -1, true, false));
    }
  });
  request.on('dataEnd', () => {
    ended = true;
    if (code !== 0) {
      if (code >= 200 && code < 300) {
        finish();
      } else {
        fail(new RpcError(`SSE request failed (${code})`, code));
      }
    }
  });

  const requestHeaders: Record<string, string> = {};
  for (const key of Object.keys(headers)) {
    requestHeaders[key] = headers[key];
  }
  requestHeaders['accept'] = 'text/event-stream';
  armIdle();
  request.requestInStream(url, {
    method: http.RequestMethod.POST,
    header: requestHeaders,
    extraData: body,
    connectTimeout: RPC_TIMEOUT_MS,
    // The kit's per-read timeout stays above our idle rule so the idle rule fires first.
    readTimeout: IDLE_TIMEOUT_MS + 15_000,
    expectDataType: http.HttpDataType.STRING,
    maxRedirects: 0,
  }).then((responseCode: number) => {
    code = responseCode;
    if (responseCode < 200 || responseCode >= 300) {
      fail(new RpcError(`SSE request failed (${responseCode})`, responseCode));
    } else if (ended) {
      finish();
    }
  }, (err: Object) => {
    const message = err instanceof Error ? (err as Error).message : String(err);
    fail(new RpcError(message, 0, '', -1, true, false));
  });

  return new SseHandle(done, finish);
}

/** Opens an RPC event stream with the pinned context's headers (threads/subscribe shape). */
export function subscribeRpcEvents(apiBase: string, proc: string, input: Record<string, Object>,
  headers: Record<string, string>, onEvent: (event: SseEvent) => void): SseHandle {
  const requestHeaders: Record<string, string> = {};
  requestHeaders['content-type'] = 'application/json';
  requestHeaders['origin'] = 'rakazo://';
  for (const key of Object.keys(headers)) {
    requestHeaders[key] = headers[key];
  }
  const envelope: Record<string, Object> = {};
  envelope['json'] = input;
  return openSse(`${apiBase}/rpc/${proc}`, requestHeaders, JSON.stringify(envelope), onEvent);
}
