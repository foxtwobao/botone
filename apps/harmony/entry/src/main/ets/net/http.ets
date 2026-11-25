// Unary transport over @ohos.net.http (design §5.1): one total deadline per request, a response
// byte cap, lowercase response headers, and transport failures as RpcError. Cookies are never
// shared (the kit's default), so a server's session cookie cannot outlive a switch — the app
// authenticates by bearer only, like mobile's credentials: "omit".
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { RpcError } from './errors';
import type { RequestCancellation } from './request-cancellation';

export interface HttpResponseView {
  status: number;
  headers: Record<string, string>;
  body: string;
}

export const RPC_TIMEOUT_MS = 8_000;
export const MAX_AUTH_RESPONSE_BYTES = 256 * 1024;
export const MAX_RPC_RESPONSE_BYTES = 16 * 1024 * 1024;

function responseHeaders(raw: Object): Record<string, string> {
  const record = raw as Record<string, Object>;
  const headers: Record<string, string> = {};
  for (const key of Object.keys(record)) {
    const value = record[key];
    headers[key.toLowerCase()] = value === undefined || value === null ? '' : String(value);
  }
  return headers;
}

export function bodyBytes(body: string): number {
  return new util.TextEncoder().encodeInto(body).byteLength;
}

/**
 * One request with a total deadline: the kit's own timeouts are per-phase, so a timer destroys
 * the request at the deadline instead. A destroyed request rejects; the timer flag tells a
 * timeout from a transport failure.
 *
 * The kit's per-phase timeouts sit a step behind the timer (KIT_TIMEOUT_GRACE_MS). Set to the same
 * value, either one may fire first: when the kit wins, the flag is still false and a timeout is
 * reported as an unreachable server (offline banner, the wrong retry path and copy).
 */
const KIT_TIMEOUT_GRACE_MS = 250;

export async function requestJson(method: http.RequestMethod, url: string, headers: Record<string, string>,
  body: string | null, timeoutMs: number, maxBytes: number,
  cancellation?: RequestCancellation): Promise<HttpResponseView> {
  cancellation?.check();
  const request = http.createHttp();
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    request.destroy();
  }, timeoutMs);
  try {
    const options: http.HttpRequestOptions = {
      method: method,
      header: headers,
      connectTimeout: timeoutMs + KIT_TIMEOUT_GRACE_MS,
      readTimeout: timeoutMs + KIT_TIMEOUT_GRACE_MS,
      expectDataType: http.HttpDataType.STRING,
      // The kit stops at 5 MiB by default, below the RPC cap an artifact reply needs. Twice the cap
      // lets the check below answer first; past it the kit refuses with the same message.
      maxLimit: MAX_RPC_RESPONSE_BYTES * 2,
      // Mobile rejects redirects wherever it sends credentials; a 3xx answer is never delivery.
      maxRedirects: 0,
    };
    if (body !== null) {
      options.extraData = body;
    }
    const transfer = request.request(url, options);
    // The kit can leave the request promise pending after destroy(). Settle the caller ourselves.
    const response = cancellation === undefined ? await transfer : await new Promise<http.HttpResponse>(
      (resolve: (response: http.HttpResponse) => void, reject: (error: Object) => void): void => {
        cancellation.listen((): void => {
          try {
            cancellation.check();
          } catch (err) {
            reject(err as Object);
          }
          request.destroy();
        });
        void transfer.then(resolve, reject);
      });
    cancellation?.check();
    const text = typeof response.result === 'string' ? response.result as string : JSON.stringify(response.result);
    if (text.length > maxBytes || bodyBytes(text) > maxBytes) {
      throw new RpcError(`Response exceeds ${maxBytes} bytes`, response.responseCode);
    }
    const view: HttpResponseView = {
      status: response.responseCode,
      headers: responseHeaders(response.header),
      body: text,
    };
    return view;
  } catch (err) {
    cancellation?.check();
    if (err instanceof RpcError) {
      throw err;
    }
    // The kit rejects with a plain BusinessError object ({code, message}), not an Error instance;
    // read its fields directly so the user copy survives ("Operation timeout", not [object Object]).
    const record = err !== null && typeof err === 'object' ? err as Record<string, Object> : null;
    const rawMessage = record !== null && typeof record['message'] === 'string' ? record['message'] as string : '';
    const message = err instanceof Error ? (err as Error).message : rawMessage || String(err);
    const code = record !== null && record['code'] !== undefined ? String(record['code']) : '';
    if (code === '2300063') {
      throw new RpcError(`Response exceeds ${maxBytes} bytes`);
    }
    throw new RpcError(message || code, 0, '', -1, !timedOut, timedOut);
  } finally {
    cancellation?.listen(null);
    clearTimeout(timer);
    request.destroy();
  }
}

export function postJson(url: string, headers: Record<string, string>, body: string,
  timeoutMs: number, maxBytes: number, cancellation?: RequestCancellation): Promise<HttpResponseView> {
  return requestJson(http.RequestMethod.POST, url, headers, body, timeoutMs, maxBytes, cancellation);
}

export function getJson(url: string, headers: Record<string, string>,
  timeoutMs: number, maxBytes: number): Promise<HttpResponseView> {
  return requestJson(http.RequestMethod.GET, url, headers, null, timeoutMs, maxBytes);
}

/** Parse a JSON body defensively; null when it is not a JSON object. */
export function parseJsonObject(text: string): Record<string, Object> | null {
  let parsed: Object;
  try {
    parsed = JSON.parse(text);
  } catch (err) {
    return null;
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return null;
  }
  return parsed as Record<string, Object>;
}
