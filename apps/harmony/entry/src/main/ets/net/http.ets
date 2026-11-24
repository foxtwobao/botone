// Unary transport over @ohos.net.http (design §5.1): one total deadline per request, a response
// byte cap, lowercase response headers, and transport failures as RpcError. Cookies are never
// shared (the kit's default), so a server's session cookie cannot outlive a switch — the app
// authenticates by bearer only, like mobile's credentials: "omit".
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { RpcError } from './errors';

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
 */
export async function requestJson(method: http.RequestMethod, url: string, headers: Record<string, string>,
  body: string | null, timeoutMs: number, maxBytes: number): Promise<HttpResponseView> {
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
      connectTimeout: timeoutMs,
      readTimeout: timeoutMs,
      expectDataType: http.HttpDataType.STRING,
      // Mobile rejects redirects wherever it sends credentials; a 3xx answer is never delivery.
      maxRedirects: 0,
    };
    if (body !== null) {
      options.extraData = body;
    }
    const response = await request.request(url, options);
    const text = typeof response.result === 'string' ? response.result as string : JSON.stringify(response.result);
    if (bodyBytes(text) > maxBytes) {
      throw new RpcError(`Response exceeds ${maxBytes} bytes`, response.responseCode);
    }
    const view: HttpResponseView = {
      status: response.responseCode,
      headers: responseHeaders(response.header),
      body: text,
    };
    return view;
  } catch (err) {
    if (err instanceof RpcError) {
      throw err;
    }
    const message = err instanceof Error ? (err as Error).message : String(err);
    const code = err instanceof Error ? String((err as BusinessError).code ?? '') : '';
    throw new RpcError(message || code, 0, '', -1, !timedOut, timedOut);
  } finally {
    clearTimeout(timer);
    request.destroy();
  }
}

export function postJson(url: string, headers: Record<string, string>, body: string,
  timeoutMs: number, maxBytes: number): Promise<HttpResponseView> {
  return requestJson(http.RequestMethod.POST, url, headers, body, timeoutMs, maxBytes);
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
