// RosterStore (design §6.3): the spaces/list projection the inbox renders. It reads once, then
// re-reads only on a roster signal or on returning to the foreground — never on a timer. The last
// rows stay painted while a read is in flight or has failed (the memory-cache offline fallback).
// A late answer from a changed session/Space is refused by the QueryCache scope guard.
import { rpc } from '../net/rpc';
import type { RpcContext } from '../net/rpc';
import { RpcError, errorText, isServerUnreachable } from '../net/errors';
import { decodeOk, decodeSpaceNavigation, decodeSpaceSummaries } from '../contract/decode';
import type { BotView, GroupView } from '../contract/decode';
import { decodeRosterWithMembers } from '../contract/decode-groups';
import { queryCache } from '../query/query-cache';
import { SaveController } from '../query/save-controller';
import type { SaveSend } from '../query/save-controller';
import { selectedSpaceId, subscribeSpaceSelection } from '../net/session';
import { subscribeRoster } from '../realtime/roster';
import { foreground } from '../realtime/foreground';
import { projectInbox, ROSTER_STALE } from './roster-projection';
import type { InboxRow } from './roster-projection';
import { spaceStore } from './space-store';

const EMPTY_INPUT: Record<string, Object> = {};

@ObservedV2
export class RosterStore {
  @Trace rows: InboxRow[] = [];
  /** The active bots and groups as last read: the group screens pick members from these. */
  @Trace bots: BotView[] = [];
  @Trace groups: GroupView[] = [];
  @Trace loading: boolean = false;
  @Trace error: string = '';
  /** The last read could not reach the server; the painted rows are the memory fallback. */
  @Trace offline: boolean = false;
  @Trace loaded: boolean = false;
  readonly archive: SaveController;
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
    this.archive = new SaveController({
      save: async (input: Record<string, Object>, send: SaveSend): Promise<void> => {
        const kind = typeof input['kind'] === 'string' ? input['kind'] as string : '';
        const id = typeof input['id'] === 'string' ? input['id'] as string : '';
        const body: Record<string, Object> = {};
        if (kind === 'bot') {
          body['botId'] = id;
          if (!decodeOk(await send('bots/archive', body))) {
            throw new RpcError('Unexpected response from the server');
          }
        } else {
          body['groupId'] = id;
          if (!decodeOk(await send('groups/archive', body))) {
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

  /** Wires the signal + foreground catch-up once (bootstrap). A Space selection change resets
   *  this store before the roster stream (also listening) reopens and signals its catch-up read,
   *  so the new Space's rows are never painted over the old Space's. */
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
    this.rows = [];
    this.bots = [];
    this.groups = [];
    this.error = '';
    this.offline = false;
    this.loaded = false;
    this.loading = false;
    this.archive.reset();
    this.notifyChanges();
  }

  async load(): Promise<void> {
    // Phase 1 is single-Space: no selected Space means no session to read for.
    if (!selectedSpaceId()) {
      return;
    }
    const requestId = ++this.requestId;
    this.loading = true;
    this.error = '';
    // Paint what we last saw before the network answers.
    const cached = queryCache.peek('spaces/list', EMPTY_INPUT);
    if (cached !== null) {
      const roster = decodeRosterWithMembers(cached);
      if (roster !== null) {
        this.bots = roster.bots;
        this.groups = roster.groups;
        this.rows = projectInbox(roster.bots, roster.groups, Date.now());
      }
    }
    try {
      const value = await queryCache.read('spaces/list', EMPTY_INPUT,
        (context: RpcContext): Promise<Object> => rpc('spaces/list', EMPTY_INPUT, { context: context }));
      if (requestId !== this.requestId || value === null) {
        return;
      }
      const roster = decodeRosterWithMembers(value);
      if (roster === null) {
        throw new RpcError('Unexpected response from the server');
      }
      // The navigation rides the same answer; the Space screens read it without another request.
      spaceStore.updateFromNavigation(decodeSpaceNavigation(value), decodeSpaceSummaries(value));
      this.bots = roster.bots;
      this.groups = roster.groups;
      this.rows = projectInbox(roster.bots, roster.groups, Date.now());
      this.offline = false;
      this.loaded = true;
      this.notifyChanges();
    } catch (err) {
      if (requestId !== this.requestId) {
        return;
      }
      const error = err instanceof RpcError ? err as RpcError : null;
      // A 401 already cleared the session; the session listener owns the screen now.
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

export const rosterStore: RosterStore = new RosterStore();
