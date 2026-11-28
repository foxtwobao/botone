// better-auth REST (design §1.3), ported from apps/mobile/lib/auth/api-auth.ts: bearer-only
// (the kit shares no cookies), token extraction set-auth-token → session cookie → body,
// generation-guarded saves, and a revocation record for a token whose save lost the race —
// a server that cannot be reached now still ends that session later.
import { postJson, getJson, parseJsonObject, RPC_TIMEOUT_MS, MAX_AUTH_RESPONSE_BYTES } from './http';
import type { HttpResponseView } from './http';
import { authResponseErrorText } from './errors';
import { currentApiBase } from './server-store';
import { serverHeaders } from './server-headers';
import {
  clearSessionToken,
  currentSessionGeneration,
  saveSessionToken,
  snapshotSessionToken,
} from './session';
import { savePendingSignOut, deliverSignOutRecord } from './sign-out';
import type { PendingSignOut } from './sign-out';
import { clearSelectedSpace } from './space-selection';
import { outbox } from '../outbox/outbox';
import { decodeAuthCapabilities } from '../contract/decode';
import type { AuthCapabilitiesView } from '../contract/decode';
import { currentLocale, t } from '../i18n/i18n';

interface AuthResponse {
  response: HttpResponseView;
  body: Record<string, Object> | null;
  invalidJson: boolean;
}

/** One better-auth POST, with the server's custom headers, app origin and locale; SSO adds
 *  its own headers on top (x-skip-oauth-proxy). Exported: net/sso.ets starts its flow here. */
export async function postAuth(path: string, input: Record<string, Object>, apiBase: string,
  extraHeaders: Record<string, string> = {}): Promise<AuthResponse> {
  const headers: Record<string, string> = {};
  const custom = serverHeaders(apiBase);
  for (const key of Object.keys(custom)) {
    headers[key] = custom[key];
  }
  for (const key of Object.keys(extraHeaders)) {
    headers[key] = extraHeaders[key];
  }
  headers['content-type'] = 'application/json';
  headers['origin'] = 'rakazo://';
  // Emails sent before an account has a language follow the one this app shows.
  headers['accept-language'] = currentLocale();
  const response = await postJson(`${apiBase}/api/auth/${path}`, headers, JSON.stringify(input),
    RPC_TIMEOUT_MS, MAX_AUTH_RESPONSE_BYTES);
  const ok = response.status >= 200 && response.status < 300;
  const body = parseJsonObject(response.body);
  const result: AuthResponse = {
    response: response,
    body: body,
    invalidJson: ok && body === null,
  };
  return result;
}

/**
 * The server only accepts a signed bearer: set-auth-token and the session cookie are signed on
 * every server version; the body token is signed only by servers that refuse unsigned bearers.
 */
export function tokenFromAuthResponse(headers: Record<string, string>, body: Record<string, Object> | null): string {
  const headerToken = headers['set-auth-token'] ?? '';
  const cookies = headers['set-cookie'] ?? '';
  const cookieMatch = /(?:^|,\s*)(?:__Secure-)?better-auth\.session_token=([^;,]*)/.exec(cookies);
  const encoded = headerToken || (cookieMatch !== null ? cookieMatch[1] : '');
  if (encoded) {
    try {
      return decodeURIComponent(encoded);
    } catch (err) {
      return '';
    }
  }
  if (body === null) {
    return '';
  }
  const token = body['token'];
  if (typeof token === 'string' && token) {
    return token as string;
  }
  const session = body['session'];
  if (session !== null && session !== undefined && typeof session === 'object') {
    const sessionToken = (session as Record<string, Object>)['token'];
    if (typeof sessionToken === 'string') {
      return sessionToken as string;
    }
  }
  return '';
}

export interface AuthenticateResult {
  verificationRequired: boolean;
}

/**
 * Saves a token a sign-in (password, code or SSO) just issued, guarded by the server address
 * and session generation captured when the flow started: a switch or a new session while the
 * flow was away means the token is not saved here — it is recorded for revocation instead.
 * Throws with user copy when the session could not be kept or saved.
 */
export async function saveIssuedSession(token: string, apiBase: string, generation: number,
  headers: Record<string, string> = serverHeaders(apiBase)): Promise<void> {
  // A switch replaces the stored headers; the cleanup below may still need this server's.
  const current = (): boolean =>
    apiBase === currentApiBase() && generation === currentSessionGeneration();
  let saved = false;
  if (current()) {
    try {
      await saveSessionToken(token);
      // A change that lands while the token is being written clears it again.
      saved = currentSessionGeneration() === generation + 1 && apiBase === currentApiBase();
    } catch (err) {
      throw new Error(t('Could not save your sign-in on this device. Try again.'));
    }
    if (saved) {
      // A fresh session starts with an empty outbox: the previous session's unsent messages
      // never belong to the account that just signed in (B3, silent like the switch below).
      outbox.clearAll();
    }
  }
  if (!saved) {
    // Recorded like a sign-out, so a server that cannot be reached now still ends it later.
    const revocation: PendingSignOut = {
      apiBase: apiBase,
      token: token,
      headers: headers,
      recordedAt: Date.now(),
      provisional: false,
    };
    const persisted = await savePendingSignOut(revocation);
    void deliverSignOutRecord(revocation, persisted);
    throw new Error(t('Could not continue'));
  }
}

async function authenticate(path: string, input: Record<string, Object>,
  missingSession: string): Promise<AuthenticateResult> {
  const apiBase = currentApiBase();
  const generation = currentSessionGeneration();
  // Captured before the request: a switch mid-flight replaces the saved set, and the
  // revocation record for the token this flow issues must still carry this server's headers.
  const headers = serverHeaders(apiBase);
  const auth = await postAuth(path, input, apiBase);
  const ok = auth.response.status >= 200 && auth.response.status < 300;
  if (!ok || auth.invalidJson) {
    throw new Error(authResponseErrorText(auth.response.status, auth.body, auth.invalidJson));
  }
  const token = tokenFromAuthResponse(auth.response.headers, auth.body);
  // sign-up with a null token means the server must verify the email first.
  if (path === 'sign-up/email' && auth.body !== null && auth.body['token'] === null) {
    const verification: AuthenticateResult = { verificationRequired: true };
    return verification;
  }
  if (!token) {
    throw new Error(missingSession);
  }
  await saveIssuedSession(token, apiBase, generation, headers);
  const result: AuthenticateResult = { verificationRequired: false };
  return result;
}

export function signIn(email: string, password: string): Promise<AuthenticateResult> {
  const input: Record<string, Object> = {};
  input['email'] = email;
  input['password'] = password;
  return authenticate('sign-in/email', input, t('Sign-in did not return a session'));
}

export function signUp(email: string, password: string, name: string): Promise<AuthenticateResult> {
  const input: Record<string, Object> = {};
  input['email'] = email;
  input['password'] = password;
  input['name'] = name;
  return authenticate('sign-up/email', input, t('Sign-up did not return a session'));
}

/** Always succeeds when the server accepts the request, whether or not an email was sent. */
export async function sendSignInCode(email: string): Promise<void> {
  const input: Record<string, Object> = {};
  input['email'] = email;
  input['type'] = 'sign-in';
  const auth = await postAuth('email-otp/send-verification-otp', input, currentApiBase());
  const ok = auth.response.status >= 200 && auth.response.status < 300;
  if (!ok) {
    throw new Error(authResponseErrorText(auth.response.status, auth.body, auth.invalidJson));
  }
}

/** Signs in with an emailed code, creating the account (with name) when none exists. */
export function signInWithCode(email: string, code: string, name: string | null): Promise<AuthenticateResult> {
  const input: Record<string, Object> = {};
  input['email'] = email;
  input['otp'] = code;
  if (name !== null && name) {
    input['name'] = name;
  }
  return authenticate('sign-in/email-otp', input, t('Sign-in did not return a session'));
}

export async function authCapabilities(): Promise<AuthCapabilitiesView> {
  const apiBase = currentApiBase();
  const headers: Record<string, string> = {};
  headers['origin'] = 'rakazo://';
  const custom = serverHeaders(apiBase);
  for (const key of Object.keys(custom)) {
    headers[key] = custom[key];
  }
  let response: HttpResponseView;
  try {
    response = await getJson(`${apiBase}/api/auth/capabilities`, headers, RPC_TIMEOUT_MS, MAX_AUTH_RESPONSE_BYTES);
  } catch (err) {
    throw new Error(t('Could not load sign-in options'));
  }
  const ok = response.status >= 200 && response.status < 300;
  const capabilities = ok ? decodeAuthCapabilities(parseJsonObject(response.body)) : null;
  if (capabilities === null) {
    throw new Error(t('Could not load sign-in options'));
  }
  return capabilities;
}

/** Asks the server to email a reset link, delivered to the server's own reset page. */
export async function requestPasswordReset(email: string, redirectTo: string): Promise<void> {
  const input: Record<string, Object> = {};
  input['email'] = email;
  input['redirectTo'] = redirectTo;
  const auth = await postAuth('request-password-reset', input, currentApiBase());
  const ok = auth.response.status >= 200 && auth.response.status < 300;
  if (!ok) {
    throw new Error(authResponseErrorText(auth.response.status, auth.body, auth.invalidJson,
      t('Could not send reset email')));
  }
}

/** Who a bearer token belongs to: better-auth's get-session, read the way mobile does before
 *  an SSO token is kept. `headers` are the access headers captured when the flow started
 *  (same-origin only; a third-party authorization domain never receives them). Returns the
 *  user id, '' when the answer is not a session. */
export async function sessionUser(apiBase: string, token: string,
  headers: Record<string, string> = serverHeaders(apiBase)): Promise<string> {
  const requestHeaders: Record<string, string> = {};
  for (const key of Object.keys(headers)) {
    requestHeaders[key] = headers[key];
  }
  requestHeaders['origin'] = 'rakazo://';
  requestHeaders['authorization'] = `Bearer ${token}`;
  let response: HttpResponseView;
  try {
    response = await getJson(`${apiBase}/api/auth/get-session`, requestHeaders, RPC_TIMEOUT_MS,
      MAX_AUTH_RESPONSE_BYTES);
  } catch (err) {
    return '';
  }
  const ok = response.status >= 200 && response.status < 300;
  const body = parseJsonObject(response.body);
  if (!ok || body === null) {
    return '';
  }
  const user = body['user'];
  if (user === null || user === undefined || typeof user !== 'object') {
    return '';
  }
  const id = (user as Record<string, Object>)['id'];
  return typeof id === 'string' ? id as string : '';
}

/**
 * Sign-out: the revocation record is written before the local clear, so a process that dies
 * mid-sign-out still revokes later; the local clear never waits on the network.
 */
export async function signOut(): Promise<void> {
  const apiBase = currentApiBase();
  const generation = currentSessionGeneration();
  const snapshot = await snapshotSessionToken();
  if (!snapshot.ok) {
    throw new Error(t('Could not clear the local session'));
  }
  const token = snapshot.value;
  let record: PendingSignOut | null = null;
  let persisted = false;
  if (token) {
    record = {
      apiBase: apiBase,
      token: token,
      headers: serverHeaders(apiBase),
      recordedAt: Date.now(),
      provisional: false,
    };
    persisted = await savePendingSignOut(record);
  }
  // A sign-in that saved its token since the read has no record; the sign-out stops here.
  if (generation !== currentSessionGeneration()) {
    throw new Error(t('Could not clear the local session'));
  }
  if (!(await clearSessionToken())) {
    throw new Error(t('Could not clear the local session'));
  }
  // The user confirmed the delete in the settings prompt (B3); a rejected session keeps the
  // records on disk for the same account's next restore.
  outbox.clearAll();
  // The Space belonged to the session that just ended; a later sign-in starts from the default.
  void clearSelectedSpace();
  if (record !== null) {
    void deliverSignOutRecord(record, persisted);
  }
}
