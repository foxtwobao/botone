// Composition root (design §6.3): one observable app state the pages render. The backend owns
// orchestration; the pages express intent. Session changes (sign-out, server rejection, switch)
// drive the screen through the session listener, never through polling.
import { common, Want } from '@kit.AbilityKit';
import { rpc, setUpdateHandler } from '../net/rpc';
import { RpcError, errorText } from '../net/errors';
import { decodeMe, decodeSpaceNavigation } from '../contract/decode';
import type { MeView } from '../contract/decode';
import {
  currentSessionGeneration,
  loadSessionToken,
  setSelectedSpace,
  subscribeSession,
} from '../net/session';
import { currentApiBase, initServerStore } from '../net/server-store';
import { flushPendingSignOut } from '../net/sign-out';
import type { SignOutContext } from '../net/sign-out';
import { loadI18n } from '../i18n/i18n';
import { appearance } from '../uikit/theme';

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

  /** Called after a committed server switch; screens watching serverBase re-read. */
  noteServerChanged(): void {
    this.serverBase = currentApiBase();
  }

  async bootstrap(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    appearance.update(context.config.colorMode);
    setUpdateHandler((): void => {
      this.updateRequired = true;
    });
    subscribeSession((): void => {
      this.sessionChanged();
    });
    try {
      await initServerStore(context);
      await loadI18n(context);
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
      await this.loadMe();
    } else {
      this.phase = 'signIn';
    }
  }

  private sessionChanged(): void {
    void loadSessionToken().then((token: string): void => {
      if (!token) {
        this.me = null;
        this.spaceName = '';
        this.meError = '';
        this.phase = 'signIn';
      }
    });
  }

  /** Reads the account and its default Space once; a late response from a changed session is dropped. */
  async loadMe(): Promise<void> {
    if (this.meLoading) {
      return;
    }
    this.meLoading = true;
    this.meError = '';
    const generation = currentSessionGeneration();
    try {
      const me = decodeMe(await rpc('me', {}));
      if (me === null) {
        throw new RpcError('Unexpected response from the server');
      }
      if (generation !== currentSessionGeneration()) {
        return;
      }
      // Phase 1 is single-Space: every later read/write uses this spaceId (design Q5).
      setSelectedSpace(me.spaceId);
      const spaces = decodeSpaceNavigation(await rpc('spaces/list', {}));
      if (generation !== currentSessionGeneration()) {
        return;
      }
      this.me = me;
      this.spaceName = spaces !== null ? spaces.currentName : '';
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
