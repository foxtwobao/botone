// The auth-session seam between the sign-in page and the in-app incognito web (mobile
// openAuthSessionAsync's place): write the state cookie into the incognito jar (the SDK wants
// cookie syncing done before the Web loads), push the sso destination, and resolve with the
// rakazo:// callback URL, or null when the person closed the page. A failed cookie write
// never opens the auth page. The network layer (net/sso.ets) only sees this function, so a
// system-browser + deep-linking fallback can replace it wholesale without touching the flow.
import { webview } from '@kit.ArkWeb';
import { t } from '../../i18n/i18n';

export interface SsoRoute {
  url: string;
  /** The raw state-cookie Set-Cookie entry (name=value with attributes) the jar must hold. */
  stateCookie: string;
}

let resolveSession: ((callbackUrl: string | null) => void) | null = null;

/** The seam's stack interface: exactly what the flow needs, so any pusher fits (NavPathStack
 *  is a global ArkUI type, not a module export this net-side file can name). */
export interface SsoStack {
  pushPathByName(name: string, param: Object): void;
  size(): number;
  pop(): void;
}

/** Wraps a real NavPathStack into the seam's interface; ArkTS has no structural typing, so
 *  the cast is the one place the two types meet. */
export function ssoStackOf(stack: object): SsoStack {
  return stack as SsoStack;
}

export function openAuthSession(stack: SsoStack, url: string,
  stateCookie: string): Promise<string | null> {
  if (stateCookie !== '') {
    try {
      webview.WebCookieManager.configCookieSync(url, stateCookie, true);
    } catch (err) {
      return Promise.reject(new Error(t('Could not continue')));
    }
  }
  const route: SsoRoute = { url: url, stateCookie: stateCookie };
  stack.pushPathByName('sso', route);
  return new Promise<string | null>((resolve: (value: string | null) => void): void => {
    resolveSession = resolve;
  });
}

/** The sso page's answer: the intercepted callback URL, or null for a closed page. */
export function completeAuthSession(callbackUrl: string | null): void {
  const resolve = resolveSession;
  resolveSession = null;
  if (resolve !== null) {
    resolve(callbackUrl);
  }
}

/** The route the sso page was pushed with, read once when it appears. */
export function takeSsoRoute(param: Object | null | undefined): SsoRoute | null {
  if (param === null || param === undefined) {
    return null;
  }
  const route = param as SsoRoute;
  return typeof route.url === 'string' && route.url !== '' ? route : null;
}