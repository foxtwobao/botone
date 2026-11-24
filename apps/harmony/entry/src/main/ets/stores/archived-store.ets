// ArchivedStore (design §6.3/§7.2 M2): the archived bots and groups, and the restore write. Reads
// go through the QueryCache (paint first, scope-guarded); the list re-reads on a roster signal or
// foreground, never on a timer. Restore is a SaveController: pinned at the tap, single-flight, and
// on success it marks the roster and both archived lists stale and re-reads them.
import { rpc } from '../net/rpc';
import type { RpcContext } from '../net/rpc';
import { RpcError, errorText, isServerUnreachable } from '../net/errors';
import { decodeBotList, decodeGroupList, decodeOk } from '../contract/decode';
import type { BotView, GroupView } from '../contract/decode';
import { queryCache } from '../query/query-cache';
import { SaveController } from '../query/save-controller';
import type { SaveSend } from '../query/save-controller';
import { selectedSpaceId } from '../net/session';
import { subscribeRoster } from '../realtime/roster';
import { foreground } from '../realtime/foreground';
import { ROSTER_STALE } from './roster-projection';
import type { InboxRow } from './roster-projection';

const EMPTY_INPUT: Record<string, Object> = {};

function archivedRows(bots: BotView[], groups: GroupView[]): InboxRow[] {
  const rows: InboxRow[] = [];
  for (const bot of bots) {
    const row: InboxRow = {
      kind: 'bot', id: bot.id, name: bot.name, preview: bot.preview, updatedAt: bot.updatedAt,
      unread: false, pinned: false, color: bot.color, working: false,
    };
    rows.push(row);
  }
  for (const group of groups) {
    const row: InboxRow = {
      kind: 'group', id: group.id, name: group.name, preview: group.preview, updatedAt: group.updatedAt,
      unread: false, pinned: false, color: '', working: false,
    };
    rows.push(row);
  }
  return rows;
}

@ObservedV2
export class ArchivedStore {
  @Trace rows: InboxRow[] = [];
  @Trace loading: boolean = false;
  @Trace error: string = '';
  @Trace offline: boolean = false;
  @Trace loaded: boolean = false;
  readonly restore: SaveController;
  private requestId: number = 0;
  private unlisten: (() => void) | null = null;
  private changeListeners: Set<() => void> = new Set();

  /** Screens reload their list source on this; LazyForEach needs an explicit reload signal. */
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

  constructor() {
    this.restore = new SaveController({
      save: async (input: Record<string, Object>, send: SaveSend): Promise<void> => {
        const kind = typeof input['kind'] === 'string' ? input['kind'] as string : '';
        const id = typeof input['id'] === 'string' ? input['id'] as string : '';
        const body: Record<string, Object> = {};
        if (kind === 'bot') {
          body['botId'] = id;
          if (!decodeOk(await send('bots/restore', body))) {
            throw new RpcError('Unexpected response from the server');
          }
        } else {
          body['groupId'] = id;
          if (!decodeOk(await send('groups/restore', body))) {
            throw new RpcError('Unexpected response from the server');
          }
        }
      },
      stale: ROSTER_STALE,
      onSaved: (): void => {
        void this.load();
      },
    });
  }

  start(): void {
    if (this.unlisten !== null) {
      return;
    }
    const offRoster = subscribeRoster((): void => {
      void this.load();
    });
    const offForeground = foreground.subscribe((isForeground: boolean): void => {
      if (isForeground) {
        void this.load();
      }
    });
    this.unlisten = (): void => {
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
    this.rows = [];
    this.error = '';
    this.offline = false;
    this.loaded = false;
    this.loading = false;
    this.restore.reset();
    this.notifyChanges();
  }

  async load(): Promise<void> {
    if (!selectedSpaceId()) {
      return;
    }
    const requestId = ++this.requestId;
    this.loading = true;
    this.error = '';
    const cachedBots = queryCache.peek('bots/listArchived', EMPTY_INPUT);
    const cachedGroups = queryCache.peek('groups/listArchived', EMPTY_INPUT);
    if (cachedBots !== null && cachedGroups !== null) {
      const bots = decodeBotList(cachedBots);
      const groups = decodeGroupList(cachedGroups);
      if (bots !== null && groups !== null) {
        this.rows = archivedRows(bots, groups);
      }
    }
    try {
      const botsValue = await queryCache.read('bots/listArchived', EMPTY_INPUT,
        (context: RpcContext): Promise<Object> => rpc('bots/listArchived', EMPTY_INPUT, { context: context }));
      const groupsValue = await queryCache.read('groups/listArchived', EMPTY_INPUT,
        (context: RpcContext): Promise<Object> => rpc('groups/listArchived', EMPTY_INPUT, { context: context }));
      if (requestId !== this.requestId || botsValue === null || groupsValue === null) {
        return;
      }
      const bots = decodeBotList(botsValue);
      const groups = decodeGroupList(groupsValue);
      if (bots === null || groups === null) {
        throw new RpcError('Unexpected response from the server');
      }
      this.rows = archivedRows(bots, groups);
      this.offline = false;
      this.loaded = true;
      this.notifyChanges();
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

export const archivedStore: ArchivedStore = new ArchivedStore();
