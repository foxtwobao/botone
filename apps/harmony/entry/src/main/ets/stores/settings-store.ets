// SettingsStore (design §6.3/§7.2 M4): the models/list catalog the read-only model display reads.
// It reads once through the QueryCache (paint first, scope-guarded), then re-reads only on a roster
// signal or returning to the foreground — never on a timer. The display itself is the pure
// defaultModelEntry match; this store only owns the read and its offline/error state.
import { rpc } from '../net/rpc';
import type { RpcContext } from '../net/rpc';
import { RpcError, errorText, isServerUnreachable } from '../net/errors';
import { decodeModelCatalog } from '../contract/decode';
import type { ModelCatalogEntryView } from '../contract/decode';
import { queryCache } from '../query/query-cache';
import { selectedSpaceId, subscribeSpaceSelection } from '../net/session';
import { subscribeRoster } from '../realtime/roster';
import { foreground } from '../realtime/foreground';

const EMPTY_INPUT: Record<string, Object> = {};

@ObservedV2
export class SettingsStore {
  @Trace catalog: ModelCatalogEntryView[] = [];
  @Trace loading: boolean = false;
  @Trace error: string = '';
  @Trace offline: boolean = false;
  @Trace loaded: boolean = false;
  private requestId: number = 0;
  private unlisten: (() => void) | null = null;

  /** Wires the signal + foreground catch-up once (bootstrap); a Space selection change resets
   *  the painted catalog before the roster stream reopens. */
  start(): void {
    if (this.unlisten !== null) {
      return;
    }
    const offSpace = subscribeSpaceSelection((): void => {
      this.reset();
    });
    const offRoster = subscribeRoster((): void => {
      void this.load();
    });
    const offForeground = foreground.subscribe((isForeground: boolean): void => {
      if (isForeground) {
        void this.load();
      }
    });
    this.unlisten = (): void => {
      offSpace();
      offRoster();
      offForeground();
    };
  }

  stop(): void {
    this.unlisten?.();
    this.unlisten = null;
  }

  reset(): void {
    this.requestId += 1;
    this.catalog = [];
    this.error = '';
    this.offline = false;
    this.loaded = false;
    this.loading = false;
  }

  async load(): Promise<void> {
    if (!selectedSpaceId()) {
      return;
    }
    const requestId = ++this.requestId;
    this.loading = true;
    this.error = '';
    const cached = queryCache.peek('models/list', EMPTY_INPUT);
    if (cached !== null) {
      const catalog = decodeModelCatalog(cached);
      if (catalog !== null) {
        this.catalog = catalog;
      }
    }
    try {
      const value = await queryCache.read('models/list', EMPTY_INPUT,
        (context: RpcContext): Promise<Object> => rpc('models/list', EMPTY_INPUT, { context: context }));
      if (requestId !== this.requestId || value === null) {
        return;
      }
      const catalog = decodeModelCatalog(value);
      if (catalog === null) {
        throw new RpcError('Unexpected response from the server');
      }
      this.catalog = catalog;
      this.offline = false;
      this.loaded = true;
    } catch (err) {
      if (requestId !== this.requestId) {
        return;
      }
      const error = err instanceof RpcError ? err as RpcError : null;
      if (error !== null && error.status === 401) {
        return;
      }
      this.error = errorText(error);
      this.offline = isServerUnreachable(error);
    } finally {
      if (requestId === this.requestId) {
        this.loading = false;
      }
    }
  }
}

export const settingsStore: SettingsStore = new SettingsStore();
