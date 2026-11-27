// QueryCache (design §5/§6.3), the semantics of apps/mobile/lib/query/query.ts without react-query:
// a read belongs to the (server, sessionGeneration, space) scope it was sent in; screens paint the
// cached value first and revalidate in the background; a session change clears everything; a late
// answer whose scope moved on is refused. Invalidation has three entry points — a roster/space
// signal, a write's stale declaration, and returning to the foreground — each of which re-reads.
// There is no staleTime timer and no polling: nothing here re-reads on a clock.
import { captureContext } from '../net/rpc';
import type { RpcContext } from '../net/rpc';
import { currentApiBase } from '../net/server-store';
import { currentSessionGeneration, selectedSpaceId } from '../net/session';

/** The three-layer scope a read is cached under and judged by. */
export function currentScope(): string {
  return `server:${currentApiBase()}\nsession:${currentSessionGeneration()}\nspace:${selectedSpaceId()}`;
}

/** The scope a pinned request carries, read from what the request itself presents. */
export function requestScope(context: RpcContext): string {
  const space = context.headers['x-rakazo-space-id'] ?? '';
  return `server:${context.apiBase}\nsession:${context.generation}\nspace:${space}`;
}

/** Deterministic key for an input object: sorted keys so equal inputs share one cache entry. */
function stableKey(value: Object | null | undefined): string {
  if (value === null || value === undefined || typeof value !== 'object') {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    const items: string[] = [];
    for (const item of value as Object[]) {
      items.push(stableKey(item));
    }
    return `[${items.join(',')}]`;
  }
  const record = value as Record<string, Object>;
  const keys = Object.keys(record).sort();
  const parts: string[] = [];
  for (const key of keys) {
    parts.push(`${JSON.stringify(key)}:${stableKey(record[key])}`);
  }
  return `{${parts.join(',')}}`;
}

interface CacheEntry {
  scope: string;
  value: Object;
}

export class QueryCache {
  private entries: Map<string, CacheEntry> = new Map();

  private key(proc: string, input: Record<string, Object>): string {
    return `${proc}\n${stableKey(input)}`;
  }

  /** The cached answer, only when it belongs to the current scope; null otherwise (paint first). */
  peek(proc: string, input: Record<string, Object>): Object | null {
    const entry = this.entries.get(this.key(proc, input));
    if (entry !== undefined && entry.scope === currentScope()) {
      return entry.value;
    }
    return null;
  }

  /**
   * Reads through the pinned context. The answer is cached only under the scope it was sent in;
   * if the server, session or Space moved on while it was in flight, it is refused (null) and
   * nothing is cached. `fetch` is the transport, injectable so tests replay offline.
   */
  async read(proc: string, input: Record<string, Object>,
    fetch: (context: RpcContext) => Promise<Object>): Promise<Object | null> {
    const scope = currentScope();
    const context = await captureContext();
    const value = await fetch(context);
    if (currentScope() !== scope) {
      return null;
    }
    const entry: CacheEntry = { scope: scope, value: value };
    this.entries.set(this.key(proc, input), entry);
    return value;
  }

  /** Forgets one procedure's answers (every input): a write or signal made them out of date. */
  invalidate(proc: string): void {
    const prefix = `${proc}\n`;
    const doomed: string[] = [];
    for (const key of this.entries.keys()) {
      if (key.startsWith(prefix)) {
        doomed.push(key);
      }
    }
    for (const key of doomed) {
      this.entries.delete(key);
    }
  }

  /** Forgets every cached read; the session registers this so sign-out never shows old data. */
  clear(): void {
    this.entries.clear();
  }
}

export const queryCache: QueryCache = new QueryCache();
