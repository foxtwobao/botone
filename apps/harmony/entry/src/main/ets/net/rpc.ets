// Unary RPC client, field-aligned with apps/mobile/lib/api/api.ts (design §1.3/§5.2):
// POST {apiBase}/rpc/{proc} with {json:body}, 8s deadline, 16MB cap, bearer + Space headers,
// session-generation pinning, the two 401 branches, and 426 → update prompt. The server's
// error message is user copy and travels on RpcError; the UI renders it through errorText.
import { postJson, parseJsonObject, RPC_TIMEOUT_MS, MAX_RPC_RESPONSE_BYTES } from './http';
import type { HttpResponseView } from './http';
import { RpcError, isUnreachableStatus } from './errors';
import { parseRetryAfter } from './retry';
import {
  clearSessionToken,
  currentSessionGeneration,
  loadSessionToken,
  selectedSpaceId,
  setSelectedSpace,
} from './session';
import { currentApiBase } from './server-store';
import { serverHeaders } from './server-headers';
import { clientBuildHeaders } from './client-build';
import { flushPendingSignOut } from './sign-out';
import type { SignOutContext } from './sign-out';
import { t } from '../i18n/i18n';

export interface RpcContext {
  apiBase: string;
  generation: number;
  headers: Record<string, string>;
}

export interface RpcOptions {
  context?: RpcContext;
  timeoutMs?: number;
  skipSpaceAuthRecovery?: boolean;
}

let updateHandler: (() => void) | null = null;
let updateNotified = false;

/** The app decides what a refused build does; the prompt shows once per launch. */
export function setUpdateHandler(handler: () => void): void {
  updateHandler = handler;
}

function noteUpdateRequired(): void {
  if (!updateNotified && updateHandler !== null) {
    updateNotified = true;
    updateHandler();
  }
}

export async function authHeaders(spaceId: string | null): Promise<Record<string, string>> {
  const headers: Record<string, string> = clientBuildHeaders();
  const custom = serverHeaders(currentApiBase());
  for (const key of Object.keys(custom)) {
    headers[key] = custom[key];
  }
  const token = await loadSessionToken();
  if (token) {
    headers['authorization'] = `Bearer ${token}`;
  }
  if (spaceId) {
    headers['x-rakazo-space-id'] = spaceId;
  }
  return headers;
}

/** Pins a request to the current server and session, and to a Space (the selected one by default). */
export async function captureContext(spaceId: string | null = null): Promise<RpcContext> {
  const space = spaceId ?? (selectedSpaceId() || null);
  const generation = currentSessionGeneration();
  const apiBase = currentApiBase();
  const headers = await authHeaders(space);
  if (apiBase !== currentApiBase()) {
    throw new Error(t('The server changed while starting the request'));
  }
  if (generation !== currentSessionGeneration()) {
    throw new Error(t('Something went wrong. Try again.'));
  }
  const context: RpcContext = { apiBase: apiBase, generation: generation, headers: headers };
  return context;
}

/** Every answered request is a connectivity window for a revocation still pending. */
function noteReachable(reachable: boolean, context: RpcContext): void {
  if (context.generation !== currentSessionGeneration() || context.apiBase !== currentApiBase()) {
    return;
  }
  if (reachable) {
    void loadSessionToken().then((token: string): void => {
      const signOutContext: SignOutContext = { apiBase: context.apiBase, activeToken: token };
      void flushPendingSignOut(signOutContext);
    });
  }
}

async function rejectSession(): Promise<void> {
  // The server ended the session; the user never asked to leave. Clearing bumps the generation,
  // so only the first rejection of a session acts and a late 401 cannot clear a newer sign-in.
  await clearSessionToken();
}

/** Calls a procedure; the result is the response's `json` value, decoded by the caller. */
export async function rpc(proc: string, body: Record<string, Object>, options?: RpcOptions): Promise<Object> {
  const context = options?.context ?? await captureContext();
  const requestHeaders: Record<string, string> = {};
  requestHeaders['content-type'] = 'application/json';
  requestHeaders['origin'] = 'rakazo://';
  for (const key of Object.keys(context.headers)) {
    requestHeaders[key] = context.headers[key];
  }
  const requestSpaceId = context.headers['x-rakazo-space-id'] ?? '';
  const envelope: Record<string, Object> = {};
  envelope['json'] = body;
  let response: HttpResponseView;
  try {
    response = await postJson(`${context.apiBase}/rpc/${proc}`, requestHeaders,
      JSON.stringify(envelope), options?.timeoutMs ?? RPC_TIMEOUT_MS, MAX_RPC_RESPONSE_BYTES);
  } catch (err) {
    const error = err instanceof RpcError ? err as RpcError : new RpcError(String(err));
    if (error.transport || error.timedOut) {
      noteReachable(false, context);
    }
    throw error;
  }
  noteReachable(!isUnreachableStatus(response.status), context);
  const parsed = parseJsonObject(response.body);
  if (response.status < 200 || response.status >= 300) {
    // oRPC sends a failure as {json:{code,status,message}}; a proxy may answer with non-JSON.
    const errorJson = parsed !== null && parsed['json'] !== null && typeof parsed['json'] === 'object'
      ? parsed['json'] as Record<string, Object>
      : null;
    const message = errorJson !== null && typeof errorJson['message'] === 'string'
      ? errorJson['message'] as string : '';
    const code = errorJson !== null && typeof errorJson['code'] === 'string' ? errorJson['code'] as string : '';
    const retryAfter = parseRetryAfter(response.headers['retry-after'] ?? null, Date.now()) ?? -1;
    if (response.status === 426) {
      noteUpdateRequired();
    }
    if (response.status === 401 && context.headers['authorization']) {
      if (!requestSpaceId && options?.context === undefined
        && context.generation === currentSessionGeneration()) {
        // No Space header: the server no longer accepts the session itself.
        await rejectSession();
      } else if (requestSpaceId && requestSpaceId === selectedSpaceId()
        && context.generation === currentSessionGeneration()
        && options?.context === undefined && options?.skipSpaceAuthRecovery !== true) {
        // With a Space header the selection may be stale while the session is fine: probe once
        // with a safe read and no Space header. Success clears the selection; a 401 means the
        // session itself is bad. Never replay a mutation — only spaces/list probes.
        const recoveryHeaders: Record<string, string> = {};
        for (const key of Object.keys(context.headers)) {
          if (key !== 'x-rakazo-space-id') {
            recoveryHeaders[key] = context.headers[key];
          }
        }
        const recovery: RpcContext = {
          apiBase: context.apiBase,
          generation: context.generation,
          headers: recoveryHeaders,
        };
        try {
          await rpc('spaces/list', {}, { context: recovery, skipSpaceAuthRecovery: true });
          setSelectedSpace('');
        } catch (retryErr) {
          const retryError = retryErr instanceof RpcError ? retryErr as RpcError : null;
          if (retryError !== null && retryError.status === 401
            && context.generation === currentSessionGeneration()) {
            await rejectSession();
          }
        }
      }
    }
    throw new RpcError(message, response.status, code, retryAfter);
  }
  if (parsed === null || parsed['json'] === undefined || parsed['json'] === null) {
    throw new RpcError('Unexpected response from the server', response.status);
  }
  return parsed['json'];
}
