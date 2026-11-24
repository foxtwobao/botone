// Harmony-only copy (design Q4/R10): strings with no existing catalog msgid, declared in one
// place. They render in English until the translation workflow extracts .ets sources; feature
// PRs never run intl:extract or edit messages.po. Everything else reuses the shared catalog.

/** A server that offers only SSO/provider sign-in, which Phase 1 does not implement yet. */
export const SSO_ONLY_SERVER = 'Sign-in with this provider is not available on this device yet.';

/** The consent gate's blocked-dispatch reason (the contract's AI_CONSENT_REQUIRED constant; the
 * catalog has no entry for it yet, so it renders in English until the translation workflow). */
export const AI_CONSENT_REQUIRED = 'Review AI data sharing in Account settings before continuing.';

/** The one-line per-use summary shown when asking (mobile consentSummary's msgids; the current
 * catalog carries the full-disclosure variants, not these one-liners, so they live here until
 * the translation workflow extracts them). */
export function consentSummary(use: string): string {
  if (use === 'model') {
    return 'Messages, files, bot instructions, memories and connected-app content are sent to run your bots.';
  }
  if (use === 'memory') {
    return 'Conversations, names and searches are sent to store and recall context.';
  }
  if (use === 'voice') {
    return 'Your recordings and the text you play are sent for transcription and speech.';
  }
  return '';
}

/** The disclosure prompt title (mobile promptAiConsent's msgid, not yet in the catalog). */
export function consentTitle(name: string): string {
  return `Send data to ${name}?`;
}

/** The T3 placeholder for a block this device cannot render (design §6.4; no catalog msgid yet). */
export const UNSUPPORTED_BLOCK = 'This content is not supported on this device yet.';
