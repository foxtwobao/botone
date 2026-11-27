// Composition root (design §6.3): one observable app state the pages render. The backend owns
// orchestration; the pages express intent. Session changes (sign-out, server rejection, switch)
// drive the screen through the session listener, never through polling.
import { common, Want } from '@kit.AbilityKit';
import { rpc, setUpdateHandler } from '../net/rpc';
import { RpcError, errorText } from '../net/errors';
import { decodeMe, decodeSpaceNavigation, decodeSpaceSummaries } from '../contract/decode';
import type { MeView } from '../contract/decode';
import {
  currentSessionGeneration,
  loadSessionToken,
  selectedSpaceId,
  setSelectedSpace,
  subscribeSession,
} from '../net/session';
import { loadSelectedSpace } from '../net/space-selection';
import { currentApiBase, initServerStore } from '../net/server-store';
import { flushPendingSignOut } from '../net/sign-out';
import type { SignOutContext } from '../net/sign-out';
import { clearArtifactCache } from '../net/artifact-cache';
import { cleanAttachmentDirectory, draftDirectory } from '../thread/attachment-files';
import { loadI18n } from '../i18n/i18n';
import { initReturningUser, rememberSignedIn } from '../features/signin/returning-user';
import { appearance } from '../uikit/theme';
import { queryCache } from '../query/query-cache';
import { rosterStore } from '../stores/roster-store';
import { archivedStore } from '../stores/archived-store';
import { settingsStore } from '../stores/settings-store';
import { incomingShare } from '../stores/incoming-share-store';
import { spaceStore } from '../stores/space-store';

@ObservedV2
export class AppState {
  /** loading | signIn | me */
  @Trace phase: string = 'loading';
  @Trace me: MeView | null = null;
  @Trace spaceName: string = '';
  @Trace meError: string = '';
  @Trace meLoading: boolean = false;
  @Trace updateRequired: boolean = false;
  /** Observable mirror of the server store's address so screens refresh after a switch. */
  @Trace serverBase: string = '';
  private context: common.UIAbilityContext | null = null;
  private unwatchSession: (() => void) | null = null;

  /** Called after a committed server switch; screens watching serverBase re-read. */
  noteServerChanged(): void {
    this.serverBase = currentApiBase();
  }

  /** Stops the global session listener so instrumented tests own the session without the app reacting. */
  detach(): void {
    this.unwatchSession?.();
    this.unwatchSession = null;
  }

  async bootstrap(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    clearArtifactCache(context);
    cleanAttachmentDirectory(draftDirectory(context));
    appearance.update(context.config.colorMode);
    setUpdateHandler((): void => {
      this.updateRequired = true;
    });
    this.unwatchSession = this.watchSession();
    // The stores listen for roster signals and foreground catch-up; the screens own the stream
    // holder (RosterHolder), so it opens only while a signed-in screen is actually shown.
    rosterStore.start();
    archivedStore.start();
    settingsStore.start();
    try {
      await initServerStore(context);
      // The Space this person last chose outlives the process; a stale one is healed by the
      // first read's 401 recovery, and loadMe only falls back to the default when none is stored.
      const storedSpace = await loadSelectedSpace();
      if (storedSpace) {
        setSelectedSpace(storedSpace);
      }
      await appearance.init(context);
      await loadI18n(context);
      initReturningUser(context);
    } catch (err) {
      this.phase = 'signIn';
      return;
    }
    this.serverBase = currentApiBase();
    const token = await loadSessionToken();
    // Launch is a forced connectivity window for revocations a dying process left behind.
    const signOutContext: SignOutContext = { apiBase: currentApiBase(), activeToken: token };
    void flushPendingSignOut(signOutContext, true);
    if (token) {
      // A session on disk marks the person as returning, like any save does below.
      void rememberSignedIn();
      await this.loadMe();
    } else {
      this.phase = 'signIn';
    }
  }

  /** Wires the session listener; the returned function stops it. Bootstrap calls this once. */
  watchSession(): () => void {
    return subscribeSession((): void => {
      this.sessionChanged();
    });
  }

  private sessionChanged(): void {
    // A session change crosses an auth boundary: forget every cached read and painted roster so
    // the next session never shows the previous owner's data (mobile clearQueries). The Space
    // selection is part of that boundary — the next account must not inherit this one's Space.
    queryCache.clear();
    // One reset path: the Space listener fires on the change below and clears the painted rows.
    setSelectedSpace('');
    if (this.context !== null) {
      clearArtifactCache(this.context);
    }
    spaceStore.reset();
    void loadSessionToken().then((token: string): void => {
      if (!token) {
        incomingShare.cancel();
        this.me = null;
        this.spaceName = '';
        this.meError = '';
        this.phase = 'signIn';
      } else {
        // Marked on every save, like mobile's saveSessionToken: the next launch opens sign-in.
        void rememberSignedIn();
        if (this.phase === 'signIn') {
          // A sign-in or a rolled-back switch restored the session: the inbox owns the screen.
          void this.loadMe();
        }
      }
    });
  }

  /** Reads the account and the selected Space's navigation once; a late response from a changed
   *  session is dropped, and a stored Space the server refuses falls back to the default. */
  async loadMe(): Promise<void> {
    if (this.meLoading) {
      return;
    }
    this.meLoading = true;
    this.meError = '';
    const generation = currentSessionGeneration();
    try {
      let meValue: Object;
      try {
        meValue = await rpc('me', {});
      } catch (err) {
        const error = err instanceof RpcError ? err as RpcError : null;
        // A stored Space the server no longer grants 401s the first read. The recovery already
        // cleared it and the session itself survived, so read again for the default Space.
        if (error === null || error.status !== 401 || selectedSpaceId()
          || !(await loadSessionToken())) {
          throw err as Error;
        }
        meValue = await rpc('me', {});
      }
      const me = decodeMe(meValue);
      if (me === null) {
        throw new RpcError('Unexpected response from the server');
      }
      if (generation !== currentSessionGeneration()) {
        return;
      }
      // The stored choice wins; only with none does the server's default Space become it.
      if (!selectedSpaceId()) {
        setSelectedSpace(me.spaceId);
      }
      const spacesValue = await rpc('spaces/list', {});
      if (generation !== currentSessionGeneration()) {
        return;
      }
      const navigation = decodeSpaceNavigation(spacesValue);
      // The same answer fills the Space screens: its name and every Space the person can open.
      spaceStore.updateFromNavigation(navigation, decodeSpaceSummaries(spacesValue));
      this.me = me;
      this.spaceName = navigation !== null ? navigation.currentName : '';
      this.phase = 'me';
    } catch (err) {
      if (generation !== currentSessionGeneration()) {
        return;
      }
      const error = err instanceof RpcError ? err as RpcError : null;
      // A 401 already cleared the session; the session listener owns the screen now.
      if (error !== null && error.status === 401) {
        return;
      }
      this.meError = errorText(error);
      this.phase = 'me';
    } finally {
      this.meLoading = false;
    }
  }

  /** The forgot-password path: the server's reset page in the system browser. */
  async openExternal(url: string): Promise<void> {
    if (this.context === null) {
      return;
    }
    const want: Want = { action: 'ohos.want.action.viewData', uri: url };
    try {
      await this.context.startAbility(want);
    } catch (err) {
      // No browser available: nothing to open, the sign-in screen stays usable.
    }
  }

}

export const app: AppState = new AppState();
