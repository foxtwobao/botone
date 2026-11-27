// Provider sign-in over Better Auth's Expo proxy, ported from apps/mobile/lib/auth/sso.ts's
// sign-in branch (network layer identical; only the auth browser differs): POST
// sign-in/social without a redirect carries the state cookie in set-cookie; the auth session
// opens the proxy URL, the provider returns to /api/auth/callback/<id>, and the server 302s
// to rakazo://sign-in?cookie=<session cookie>. The callback URL holds the session, so it is
// never logged.
import { authErrorText, authResponseErrorText } from './errors';
import { currentApiBase } from './server-store';
import { currentSessionGeneration } from './session';
import { postAuth, saveIssuedSession, sessionUser, tokenFromAuthResponse } from './auth';
import { url } from '@kit.ArkTS';
import { t } from '../i18n/i18n';

/** The flow reads its params off a parsed URL; URLParams is @ohos.url's non-deprecated form. */
type UrlParams = url.URLParams;

export const SIGN_IN_CALLBACK = 'rakazo://sign-in';

/** The URL the auth session opens: the server's proxy, which 302s into the provider. */
export function proxyUrl(apiBase: string, authorizationUrl: string, oauthState: string): string {
  const params = new url.URLParams('');
  params.set('authorizationURL', authorizationUrl);
  if (oauthState) {
    params.set('oauthState', oauthState);
  }
  return `${apiBase}/api/auth/expo-authorization-proxy?${params.toString()}`;
}

/** The OAuth state cookie from a sign-in/social response's set-cookie header, '' when absent. */
export function stateCookieFromHeaders(setCookie: string): string {
  const match = /(?:^|,\s*)(?:__Secure-)?better-auth\.oauth_state=([^;,]*)/.exec(setCookie);
  const encoded = match !== null ? match[1] : '';
  if (!encoded) {
    return '';
  }
  try {
    return decodeURIComponent(encoded);
  } catch (err) {
    return '';
  }
}

/** The issued session token a callback carries in its cookie parameter, '' when absent. */
export function tokenFromCallbackCookie(cookie: string): string {
  const headers: Record<string, string> = {};
  headers['set-cookie'] = cookie;
  return tokenFromAuthResponse(headers, null);
}

/** One provider sign-in flow. Returns true when the session was saved; false when the person
 *  closed the auth session (no error, no state change). Throws user copy otherwise. */
export async function continueWithSso(provider: string,
  openSession: (url: string, stateCookie: string) => Promise<string | null>): Promise<boolean> {
  const apiBase = currentApiBase();
  const generation = currentSessionGeneration();
  const requireCurrentSession = (): void => {
    if (apiBase !== currentApiBase() || generation !== currentSessionGeneration()) {
      throw new Error(t('Could not continue'));
    }
  };
  requireCurrentSession();
  const input: Record<string, Object> = {};
  input['provider'] = provider;
  input['callbackURL'] = SIGN_IN_CALLBACK;
  input['errorCallbackURL'] = SIGN_IN_CALLBACK;
  input['disableRedirect'] = true;
  // x-skip-oauth-proxy: the answer must be the authorization URL itself, not a redirect.
  const extraHeaders: Record<string, string> = {};
  extraHeaders['x-skip-oauth-proxy'] = 'true';
  const auth = await postAuth('sign-in/social', input, apiBase, extraHeaders);
  const ok = auth.response.status >= 200 && auth.response.status < 300;
  if (!ok || auth.invalidJson) {
    throw new Error(authResponseErrorText(auth.response.status, auth.body, auth.invalidJson));
  }
  const rawBody: Record<string, Object> | null = auth.body;
  const rawUrl = rawBody !== null && typeof rawBody['url'] === 'string'
    ? rawBody['url'] as string : '';
  if (!rawUrl) {
    throw new Error(t('Could not continue'));
  }
  const authorizationUrl = parseAuthorizationUrl(rawUrl);
  if (authorizationUrl === null) {
    throw new Error(t('Could not continue'));
  }
  const stateCookie = stateCookieFromHeaders(auth.response.headers['set-cookie'] ?? '');
  requireCurrentSession();
  const callback = await openSession(proxyUrl(apiBase, authorizationUrl, stateCookie), stateCookie);
  if (callback === null) {
    // The person closed the auth session: no error, no state change.
    return false;
  }
  return await completeSsoSignIn(callback, apiBase, generation);
}

/** https only, with a state parameter; anything else is a flow the server cannot answer. */
function parseAuthorizationUrl(raw: string): string | null {
  let parsed: url.URL;
  try {
    parsed = url.URL.parseURL(raw);
  } catch (err) {
    return null;
  }
  if (parsed.protocol !== 'https:' || !parsed.params.get('state')) {
    return null;
  }
  return raw;
}

/** Parses and saves the callback the auth session returned. Exported for the seam: a system
 *  browser fallback lands in the same place. */
export async function completeSsoSignIn(callbackUrl: string, apiBase: string,
  generation: number): Promise<boolean> {
  const callback = parseCallbackUrl(callbackUrl);
  if (callback === null) {
    throw new Error(t('Could not continue'));
  }
  const params = callback.params;
  const errorValue = params.get('error');
  const error = errorValue !== null && errorValue !== undefined ? errorValue : '';
  if (error) {
    const body: Record<string, Object> = {};
    body['code'] = error;
    throw new Error(authErrorText(body, t('Could not continue')));
  }
  if (currentApiBase() !== apiBase || generation !== currentSessionGeneration()) {
    throw new Error(t('Could not continue'));
  }
  const cookieValue = params.get('cookie');
  const cookie = cookieValue !== null && cookieValue !== undefined ? cookieValue : '';
  const token = cookie ? tokenFromCallbackCookie(cookie) : '';
  if (!token) {
    throw new Error(t('Sign-in did not return a session'));
  }
  const user = await sessionUser(apiBase, token);
  if (!user) {
    throw new Error(t('Could not continue'));
  }
  if (currentApiBase() !== apiBase || generation !== currentSessionGeneration()) {
    throw new Error(t('Could not continue'));
  }
  await saveIssuedSession(token, apiBase, generation);
  return true;
}

export interface CallbackView {
  params: UrlParams;
}

/** The callback must be the app's own deep link exactly: rakazo://sign-in, no path, no junk.
 *  Anything else could carry a session somewhere this flow did not ask for. */
function parseCallbackUrl(raw: string): CallbackView | null {
  let parsed: url.URL;
  try {
    parsed = url.URL.parseURL(raw);
  } catch (err) {
    return null;
  }
  // WHATWG parsing lowercases the scheme; the host compares exactly, like mobile's URL check.
  if (parsed.protocol.toLowerCase() !== 'rakazo:' || parsed.host !== 'sign-in') {
    return null;
  }
  if (parsed.pathname && parsed.pathname !== '/') {
    return null;
  }
  const view: CallbackView = { params: parsed.params };
  return view;
}
