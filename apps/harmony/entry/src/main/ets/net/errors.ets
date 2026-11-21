// Error shape and user-facing copy, ported from apps/mobile/lib/api/user-error.ts and
// packages/core/src/primitives/user-error.ts. The server's message is user copy and passes
// through; transport detail and implementation noise become local copy. Sentinels: status 0
// means no response, retryAfterMs -1 means no Retry-After, code "" means none.
import { t } from '../i18n/i18n';

export class RpcError extends Error {
  status: number;
  code: string;
  retryAfterMs: number;
  /** The request never reached the server (connection, DNS, a dropped transfer). */
  transport: boolean;
  /** The client gave up on its own deadline. */
  timedOut: boolean;

  constructor(message: string, status: number = 0, code: string = '', retryAfterMs: number = -1,
    transport: boolean = false, timedOut: boolean = false) {
    super(message);
    this.name = 'RpcError';
    this.status = status;
    this.code = code;
    this.retryAfterMs = retryAfterMs;
    this.transport = transport;
    this.timedOut = timedOut;
  }
}

/** True for the gateway answers a proxy gives while the server is down or restarting. */
export function isUnreachableStatus(status: number): boolean {
  return status === 502 || status === 503 || status === 504;
}

/** True when the request may never have reached the server, so sending it again later is safe. */
export function isServerUnreachable(error: RpcError | null): boolean {
  if (error === null) {
    return false;
  }
  return error.transport || error.timedOut || isUnreachableStatus(error.status);
}

/** Implementation detail that should never reach the screen as-is (core user-error.ts). */
const TECHNICAL_MESSAGE: RegExp[] = [
  /\[(?:body|query|params|headers)(?:\.[^\]]*)?\]/,
  /\w+Exception\b/,
  /^\w*Error:/,
  /\(at \S+:\d+|\bat \S+ \(\S+:\d+(?::\d+)?\)|\.(?:swift|kt|java|mm?|[cm]?[jt]sx?):\d+/,
  /^\s*[[{]/,
  /^rpc \S+ failed|\(\d{3}\)|\bstatus(?: code)? \d{3}\b/i,
  /\bE(?:CONN[A-Z]+|TIMEDOUT|NOTFOUND|AI_AGAIN|PIPE|HOSTUNREACH|NETUNREACH)\b/,
  /^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+$/,
  /\d+ bytes\b/,
  /unexpected token|is not a function|cannot read propert|undefined is not|null is not an object|json parse error/i,
  /^input validation failed\b/i,
];

function isTechnicalMessage(message: string): boolean {
  for (const pattern of TECHNICAL_MESSAGE) {
    if (pattern.test(message)) {
      return true;
    }
  }
  return false;
}

/** Text for a failure: human messages pass through; network and implementation detail become copy. */
export function errorText(error: RpcError | null): string {
  if (isServerUnreachable(error)) {
    return t('Could not reach the server');
  }
  const message = error === null ? '' : error.message.trim();
  return message && !isTechnicalMessage(message) ? message : t('Something went wrong. Try again.');
}

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
/** Catches empty or malformed credentials before they round-trip to the server. */
export function credentialIssue(email: string, password: string | null): 'email' | 'password' | null {
  if (!EMAIL.test(email.trim())) {
    return 'email';
  }
  if (password !== null && !password) {
    return 'password';
  }
  return null;
}

function credentialText(field: 'email' | 'password'): string {
  return field === 'email' ? t('Enter a valid email') : t('Enter a password');
}

/** Copy for a failed auth response body ({ code, message }), ported from authErrorText. */
export function authErrorText(body: Record<string, Object> | null, fallback: string): string {
  const record: Record<string, Object> = body ?? {};
  const code = typeof record['code'] === 'string' ? record['code'] as string : '';
  const message = typeof record['message'] === 'string' ? (record['message'] as string).trim() : '';
  if (code === 'SSO_UNAVAILABLE') {
    return t('SSO is temporarily unavailable. Try again.');
  }
  if (code === 'account_not_linked') {
    return t('Sign in to your account, then link this provider in settings');
  }
  if (code === 'email_does_not_match') {
    return t('Use an account with the same email address');
  }
  if (code === 'ACCOUNT_DEACTIVATED') {
    return t('This account is deactivated');
  }
  if (code === 'REGISTRATION_CLOSED') {
    return t('Registration is closed');
  }
  if (code === 'EMAIL_NOT_ALLOWED') {
    return t('Email is not allowed to register');
  }
  if (code === 'EMAIL_VERIFICATION_REQUIRED' || code === 'unable_to_link_account') {
    return t('Email verification required');
  }
  if (code === 'REAUTHENTICATION_REQUIRED') {
    return t('Sign in again');
  }
  if (code === 'PASSWORD_AUTH_DISABLED') {
    return t('Password sign-in is turned off on this server');
  }
  if (code === 'PASSWORD_TOO_LONG') {
    // MAX_PASSWORD_LENGTH from packages/core/src/account/password-policy.ts.
    const values: Record<string, string | number> = {};
    values['max'] = 128;
    return t('Password must be {max} characters or fewer', values);
  }
  if (code === 'INVALID_OTP') {
    return t('Invalid code');
  }
  if (code === 'OTP_EXPIRED' || code === 'TOO_MANY_ATTEMPTS') {
    return t('Request a new code');
  }
  if (code === 'VALIDATION_ERROR') {
    if (/\[body\.email/.test(message)) {
      return credentialText('email');
    }
    if (/\[body\.password/.test(message)) {
      return credentialText('password');
    }
    return fallback;
  }
  return message && !isTechnicalMessage(message) ? message : fallback;
}

/** Status copy is a fallback: keep human server messages and known auth codes. */
export function authResponseErrorText(status: number, body: Record<string, Object> | null,
  invalidJson: boolean): string {
  const fallback = status === 429
    ? t('Too many attempts. Try again in a few minutes.')
    : isUnreachableStatus(status)
      ? t('Could not reach the server')
      : status >= 500 || invalidJson
        ? t('The server had a problem. Try again in a moment.')
        : t('Could not continue');
  const text = authErrorText(body, fallback).trim();
  return text || fallback;
}
