// Harmony-only copy (design Q4/R10): strings with no existing catalog msgid, declared in one
// place. They render in English until the translation workflow extracts .ets sources; feature
// PRs never run intl:extract or edit messages.po. Everything else reuses the shared catalog.

/** A server that offers only SSO/provider sign-in, which Phase 1 does not implement yet. */
export const SSO_ONLY_SERVER = 'Sign-in with this provider is not available on this device yet.';
