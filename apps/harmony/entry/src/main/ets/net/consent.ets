// The minimal AI data consent gate (design §5.2), ported from packages/core/src/account/ai-consent.ts
// and the dispatch gate in apps/mobile/lib/api/api.ts: before threads/send or threads/answer leaves
// the device, query aiConsent/status for the target, ask about every unallowed recipient whose use
// the procedure needs (server order), save each explicit Allow via aiConsent/allow, re-check the
// pinned session generation, and only then dispatch the original request with the SAME pinned
// context. Refusal, a failed query/save, or a generation change blocks the dispatch — the private
// text never leaves the device. Concurrent asks for one (server, space, scope, version, key) share
// one prompt. No client-side allow cache: the server is the source of truth, every gated request
// queries status again.
import { rpc } from './rpc';
import type { RpcContext } from './rpc';
import type { RequestCancellation } from './request-cancellation';
import { RpcError, errorText } from './errors';
import { currentSessionGeneration } from './session';
import { asRecord } from '../contract/decode';
import { t } from '../i18n/i18n';
import { AI_CONSENT_REQUIRED, consentSummary } from '../i18n/harmony-strings';

/** One recipient the server reports for a use of AI data (AiRecipientSchema's consumed fields). */
export interface AiRecipient {
  key: string;
  name: string;
  use: string;
  detail: string;
  privacyUrl?: string;
  allowed: boolean;
}

export interface AiConsentStatus {
  scope: string;
  version: string;
  recipients: AiRecipient[];
  privacyUrl?: string;
}

export function decodeAiConsentStatus(json: Object | null): AiConsentStatus | null {
  const record = asRecord(json);
  if (record === null) {
    return null;
  }
  const scope = record['scope'];
  const version = record['version'];
  const recipientsRaw = record['recipients'];
  if (typeof scope !== 'string' || typeof version !== 'string' || !Array.isArray(recipientsRaw)) {
    return null;
  }
  const recipients: AiRecipient[] = [];
  for (const item of recipientsRaw as Object[]) {
    const row = asRecord(item);
    if (row === null) {
      return null;
    }
    const key = row['key'];
    const name = row['name'];
    const use = row['use'];
    const detail = row['detail'];
    const allowed = row['allowed'];
    if (typeof key !== 'string' || typeof name !== 'string' || typeof use !== 'string'
      || typeof detail !== 'string' || typeof allowed !== 'boolean') {
      return null;
    }
    const recipient: AiRecipient = {
      key: key as string, name: name as string, use: use as string, detail: detail as string,
      allowed: allowed as boolean,
    };
    const privacyUrl = row['privacyUrl'];
    if (typeof privacyUrl === 'string') {
      recipient.privacyUrl = privacyUrl as string;
    }
    recipients.push(recipient);
  }
  const status: AiConsentStatus = {
    scope: scope as string, version: version as string, recipients: recipients,
  };
  const privacyUrl = record['privacyUrl'];
  if (typeof privacyUrl === 'string') {
    status.privacyUrl = privacyUrl as string;
  }
  return status;
}

/** Only user actions that can start AI processing need a foreground disclosure (Phase 1 face). */
export function aiDataUsesForProcedure(proc: string): string[] {
  if (proc === 'threads/send' || proc === 'threads/answer') {
    return ['model', 'memory'];
  }
  return [];
}

/** The thread target a gated request names: groupId wins over botId (core aiConsentTarget). */
export function aiConsentTarget(body: Record<string, Object>): Record<string, Object> {
  const target: Record<string, Object> = {};
  const groupId = body['groupId'];
  const botId = body['botId'];
  if (typeof groupId === 'string') {
    target['groupId'] = groupId;
  } else if (typeof botId === 'string') {
    target['botId'] = botId;
  }
  return target;
}

/** A foreground check failed before the requested mutation was dispatched (core AiConsentBlocked). */
export class AiConsentBlocked extends RpcError {
  /** The user answered Not now: their choice, not an error — the composer keeps the draft and
   * shows no failure copy (the gate's refusal message is the contract's AI_CONSENT_REQUIRED). */
  readonly refusedByUser: boolean;

  constructor(message: string, refusedByUser: boolean = false) {
    super(message);
    this.name = 'AiConsentBlocked';
    this.refusedByUser = refusedByUser;
  }
}

/** The user's answer to one disclosure prompt; the UI installs the native dialog. */
export type ConsentPrompt = (recipient: AiRecipient, privacyUrl: string | undefined) => Promise<boolean>;

let promptImpl: ConsentPrompt | null = null;

/** The chat screen installs the AlertDialog; without one every ask refuses (safe default). */
export function setConsentPrompt(prompt: ConsentPrompt | null): void {
  promptImpl = prompt;
}

function askUser(recipient: AiRecipient, privacyUrl: string | undefined): Promise<boolean> {
  if (promptImpl === null) {
    return Promise.resolve(false);
  }
  return promptImpl(recipient, privacyUrl);
}

/** The one-line body: the server's detail when it has one, else the local per-use summary. */
export function consentBody(recipient: AiRecipient): string {
  return recipient.detail.trim() ? recipient.detail : consentSummary(recipient.use);
}

/** The privacy link the prompt offers: the recipient's own, else the deployment's. */
export function consentPrivacyUrl(recipient: AiRecipient, status: AiConsentStatus): string | undefined {
  return recipient.privacyUrl ?? status.privacyUrl;
}

// Concurrent asks for one recipient share one prompt (core pendingAiConsent). The key separates
// servers and Spaces before the account-space scope is applied (mobile aiConsentCoalesceKey).
const pending: Map<string, Promise<void>> = new Map();

function coalesceKey(context: RpcContext, scope: string, version: string, key: string): string {
  const space = context.headers['x-rakazo-space-id'] ?? '';
  return `${context.apiBase}\u0000${space}\u0000${scope}\u0000${version}\u0000${key}`;
}

/** One recipient's ask-or-reuse, Allow save included; the map entry clears when it settles.
 *  `target` is the query's target: a thread's bot or group, or the copy of the settings asked about. */
function ensureRecipient(context: RpcContext, status: AiConsentStatus, recipient: AiRecipient,
  target: Record<string, Object>): Promise<void> {
  const key = coalesceKey(context, status.scope, status.version, recipient.key);
  const existing = pending.get(key);
  if (existing !== undefined) {
    return existing;
  }
  // The map holds the cleanup-wrapped promise: concurrent callers share the same outcome and
  // the entry clears when it settles (core pendingAiConsent's finally).
  const task: Promise<void> = (async (): Promise<void> => {
    const allowed = await askUser(recipient, consentPrivacyUrl(recipient, status));
    if (!allowed) {
      throw new AiConsentBlocked(AI_CONSENT_REQUIRED, true);
    }
    // The allow RPC carries the pinned context; its own dispatch re-check refuses a generation
    // that moved during the prompt (mobile api.ts:726 inside the nested request), so the allow
    // never reaches a session it was not asked for.
    if (context.generation !== currentSessionGeneration()) {
      throw new RpcError(t('Something went wrong. Try again.'));
    }
    const body: Record<string, Object> = {};
    body['scope'] = status.scope;
    body['version'] = status.version;
    body['keys'] = [recipient.key];
    // A query that named a copy of the settings asks about that copy's recipients (core
    // aiConsentTarget), so the Allow is saved for the same copy.
    const settingsScope = target['settingsScope'];
    if (typeof settingsScope === 'string') {
      body['settingsScope'] = settingsScope;
    }
    await rpc('aiConsent/allow', body, { context: context });
  })().then((): void => {
    if (pending.get(key) === task) {
      pending.delete(key);
    }
  }, (err: Object): void => {
    if (pending.get(key) === task) {
      pending.delete(key);
    }
    throw err instanceof Error ? err as Error : new Error(String(err));
  });
  pending.set(key, task);
  return task;
}

/**
 * The dispatch gate (core ensureAiDataConsent + mobile api.ts's pre-dispatch flow). Runs inside
 * the caller's pinned context; throws AiConsentBlocked on any refusal/failure so the original
 * request is never dispatched. A 404 from status means the server predates the procedure.
 */
export async function ensureAiDataConsent(proc: string, body: Record<string, Object>,
  context: RpcContext): Promise<void> {
  const uses = aiDataUsesForProcedure(proc);
  if (uses.length === 0) {
    return;
  }
  await ensureUsesConsent(uses, aiConsentTarget(body), context);
}

/**
 * Asks before audio or text reaches a voice recipient the user has not allowed yet (M7, mobile
 * ensureVoiceConsent): before a reply is spoken, a sample plays or a recording is transcribed.
 * `scope` names the copy of the voice settings a speech uses; undefined means the one that applies.
 * A `cancellation` ends the status read it is asked through.
 */
export async function ensureVoiceConsent(context: RpcContext, scope?: string,
  cancellation?: RequestCancellation): Promise<void> {
  const target: Record<string, Object> = {};
  if (scope !== undefined) {
    target['settingsScope'] = scope;
  }
  await ensureUsesConsent(['voice'], target, context, cancellation);
}

async function ensureUsesConsent(uses: string[], target: Record<string, Object>,
  context: RpcContext, cancellation?: RequestCancellation): Promise<void> {
  const query: Record<string, Object> = {};
  query['uses'] = uses;
  for (const key of Object.keys(target)) {
    query[key] = target[key];
  }
  let status: AiConsentStatus | null;
  try {
    status = decodeAiConsentStatus(
      await rpc('aiConsent/status', query, { context: context, cancellation: cancellation }));
  } catch (err) {
    const error = err instanceof RpcError ? err as RpcError : null;
    if (error !== null && error.status === 404) {
      throw new AiConsentBlocked(t('Update your server to use AI data sharing in this mobile version.'));
    }
    // The blocked error carries the user-facing copy (mobile errorText): transport detail becomes
    // "Could not reach the server", a server message passes through.
    throw new AiConsentBlocked(errorText(error));
  }
  if (status === null) {
    throw new AiConsentBlocked(AI_CONSENT_REQUIRED);
  }
  try {
    for (const recipient of status.recipients) {
      if (recipient.allowed || !uses.includes(recipient.use)) {
        continue;
      }
      await ensureRecipient(context, status, recipient, target);
    }
  } catch (err) {
    if (err instanceof AiConsentBlocked) {
      throw err;
    }
    const error = err instanceof RpcError ? err as RpcError : null;
    throw new AiConsentBlocked(error !== null && error.message ? error.message : AI_CONSENT_REQUIRED);
  }
  // The ask may have outlived the session or server it was pinned to (mobile api.ts:726): the
  // generation re-check refuses the dispatch; the consent stays granted on the server it was for.
  if (context.generation !== currentSessionGeneration()) {
    throw new RpcError(t('Something went wrong. Try again.'));
  }
}
