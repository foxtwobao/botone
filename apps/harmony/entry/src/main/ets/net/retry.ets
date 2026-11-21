// Port of packages/core/src/primitives/retry-policy.ts (69 lines, fixture-aligned).
// A failure without a response can succeed on retry, as can 5xx/429/408; any other status is
// the server's answer — repeating it only polls. Sentinels replace TS's undefined: status 0
// means no response, retryAfterMs -1 means the server asked for nothing.
import { RpcError } from './errors';

export const MAX_RETRY_AFTER_MS = 5 * 60_000;
export const RECONNECT_SPREAD_MS = 5_000;

export function errorStatus(error: RpcError | null): number | undefined {
  if (error === null || error.status <= 0) {
    return undefined;
  }
  return error.status;
}

export function isRetryableError(error: RpcError | null): boolean {
  const status = errorStatus(error);
  if (status === undefined || status < 400) {
    return true;
  }
  return status >= 500 || status === 429 || status === 408;
}

/** Retry-After as delta-seconds or an HTTP date, in milliseconds from `now`. */
export function parseRetryAfter(value: string | null, now: number): number | undefined {
  const trimmed = value === null ? '' : value.trim();
  if (!trimmed) {
    return undefined;
  }
  const ms = /^\d+$/.test(trimmed) ? Number(trimmed) * 1000 : Date.parse(trimmed) - now;
  return Number.isFinite(ms) ? Math.min(Math.max(ms, 0), MAX_RETRY_AFTER_MS) : undefined;
}

/** Between half of `ms` and all of it, so clients that failed together retry apart. */
export function jitterMs(ms: number, random: number): number {
  return Math.round(ms - (random * ms) / 2);
}

/**
 * Wait the server asked for (an error's retryAfterMs), otherwise the caller's backoff, jittered
 * after a failure. Without a failure (null) the caller's own interval stands.
 */
export function retryDelayMs(error: RpcError | null, backoffMs: number, random: number): number {
  const asked = error !== null ? error.retryAfterMs : -1;
  if (asked >= 0 && Number.isFinite(asked)) {
    return Math.min(Math.max(asked, backoffMs), MAX_RETRY_AFTER_MS);
  }
  return error === null ? backoffMs : jitterMs(backoffMs, random);
}

/**
 * Wait before reopening a live stream that ended after it was open: a deploy ends every
 * client's stream at once, so each picks its own moment within a few seconds.
 */
export function reconnectDelayMs(error: RpcError | null, random: number): number {
  return Math.max(retryDelayMs(error, 0, random), Math.round(random * RECONNECT_SPREAD_MS));
}
