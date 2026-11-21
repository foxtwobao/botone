// SaveController (design §6.3), the useSave contract from apps/mobile/lib/query/query.ts: a write
// pins its request context at the tap, flies once (a second tap in the same tick does nothing),
// and owns pending/error — the screen keeps no saving state beside it. `send` writes with that
// pinned context and nothing else, refused once its server/session/Space is no longer current. On
// success the declared reads are marked stale and re-read; once the screen shows another scope, a
// finishing save shows nothing and skips onSaved/onFailed.
import { captureContext, rpc } from '../net/rpc';
import type { RpcContext } from '../net/rpc';
import { RpcError, errorText } from '../net/errors';
import { currentScope, queryCache, requestScope } from './query-cache';
import { t } from '../i18n/i18n';

/** One rpc write of a save, sent with the pinned context. */
export type SaveSend = (proc: string, body: Record<string, Object>) => Promise<Object>;

export interface SaveOptions {
  /** Performs the write through `send`; may send several rpcs under the one pinned context. */
  save: (input: Record<string, Object>, send: SaveSend) => Promise<void>;
  /** Procedures this write makes out of date; invalidated and re-read on success. */
  stale?: string[];
  onSaved?: () => void;
  onFailed?: (error: RpcError) => void;
}

@ObservedV2
export class SaveController {
  @Trace pending: boolean = false;
  @Trace error: string = '';
  /** What the pending or failed save was sent with, so a row can mark itself. */
  @Trace input: Record<string, Object> | null = null;
  private inFlight: boolean = false;
  private options: SaveOptions;

  constructor(options: SaveOptions) {
    this.options = options;
  }

  /** Forgets a finished save's error (the same control on every render). */
  reset(): void {
    if (!this.pending) {
      this.error = '';
      this.input = null;
    }
  }

  run(input: Record<string, Object>): void {
    if (this.inFlight) {
      return;
    }
    this.inFlight = true;
    this.pending = true;
    this.error = '';
    this.input = input;
    const scope = currentScope();
    const pinned: Promise<RpcContext> = captureContext();
    const send: SaveSend = async (proc: string, body: Record<string, Object>): Promise<Object> => {
      const context = await pinned;
      if (requestScope(context) !== scope || currentScope() !== scope) {
        throw new RpcError(t('Something went wrong. Try again.'));
      }
      return rpc(proc, body, { context: context });
    };
    const stale = this.options.stale ?? [];
    void (async (): Promise<void> => {
      await this.options.save(input, send);
      for (const proc of stale) {
        queryCache.invalidate(proc);
      }
    })().then((): void => {
      this.inFlight = false;
      this.pending = false;
      if (currentScope() === scope) {
        this.options.onSaved?.();
      }
    }, (err: Object): void => {
      this.inFlight = false;
      this.pending = false;
      const error = err instanceof RpcError ? err as RpcError : new RpcError(String(err));
      this.error = errorText(error);
      if (currentScope() === scope) {
        this.options.onFailed?.(error);
      }
    });
  }
}
