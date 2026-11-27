// The OpenAI-compatible address rule (M9), ported from contracts' normalizeOpenAiCompatibleBaseUrl
// (openai-compatible-ui.ts): trailing slashes dropped, a pasted request path (/chat/completions,
// /models, …) removed, /v1 added only when no path segment is already a version (v1, v4, v1beta).
// The result is the address the server stores; this client sends it to models/probeOpenAiCompatible
// and lets the server normalize the one models/connect receives, as mobile does. Errors are the
// contract's own messages. The kit's URL is used exactly like net/endpoint.ets does.
import { url } from '@kit.ArkTS';

export interface CompatibleUrlResult {
  ok: boolean;
  url: string;
  error: string;
}

const PASTED_ENDPOINT_SUFFIX = /\/(?:chat\/completions|completions|responses|models|embeddings)$/i;
const VERSION_SEGMENT = /^v\d+[a-z]*$/;

/** The contract's origin. The kit and WHATWG may disagree on a default port, so drop it here. */
function withoutDefaultPort(protocol: string, host: string): string {
  if (protocol === 'https:' && host.endsWith(':443')) {
    return host.slice(0, -4);
  }
  if (protocol === 'http:' && host.endsWith(':80')) {
    return host.slice(0, -3);
  }
  return host;
}

function urlError(message: string): CompatibleUrlResult {
  const result: CompatibleUrlResult = { ok: false, url: '', error: message };
  return result;
}

export function normalizeOpenAiCompatibleBaseUrl(raw: string): CompatibleUrlResult {
  const trimmed = raw.trim();
  if (!trimmed) {
    return urlError('Base URL must be an absolute HTTP(S) URL');
  }
  let parsed: url.URL;
  try {
    parsed = url.URL.parseURL(trimmed);
  } catch (err) {
    return urlError('Base URL must be an absolute HTTP(S) URL');
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    return urlError('Base URL must use http or https');
  }
  if (parsed.username || parsed.password) {
    return urlError('Base URL must not contain credentials');
  }
  let path = parsed.pathname.replace(/\/+$/, '').replace(PASTED_ENDPOINT_SUFFIX, '');
  let versioned = false;
  for (const segment of path.split('/')) {
    if (VERSION_SEGMENT.test(segment)) {
      versioned = true;
      break;
    }
  }
  if (!versioned) {
    path = path ? `${path}/v1` : '/v1';
  }
  const result: CompatibleUrlResult = {
    ok: true,
    url: `${parsed.protocol}//${withoutDefaultPort(parsed.protocol, parsed.host)}${path}`,
    error: '',
  };
  return result;
}