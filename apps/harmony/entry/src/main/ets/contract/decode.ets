// Phase 1 contract subset decoders (design §4): explicit per-field reads with runtime type
// guards, the S1-verified ArkTS style. No zod/oRPC on device. A decoder returns null when a
// consumed field is missing or mistyped; fields outside the M1 view are ignored (forward
// compatible). The layer-1 snapshots pin exactly these views to the real contract schemas.

export interface HealthOutput {
  ok: boolean;
  version: string;
}

export interface MeView {
  userId: string;
  email: string;
  name: string;
  spaceId: string;
  needsModel: boolean;
  defaultProvider: string | null;
  defaultModel: string | null;
}

export interface SpaceNavigationView {
  currentId: string;
  currentName: string;
}

export interface SignInProviderView {
  id: string;
  name: string;
}

export interface AuthCapabilitiesView {
  passwordAuth: boolean;
  passwordReset: boolean;
  resetUrl: string | null;
  emailCode: boolean;
  ssoName: string | null;
  providers: SignInProviderView[];
}

export function asRecord(value: Object | null | undefined): Record<string, Object> | null {
  if (value === null || value === undefined || typeof value !== 'object' || Array.isArray(value)) {
    return null;
  }
  return value as Record<string, Object>;
}

function readString(record: Record<string, Object>, key: string): string | null {
  const value = record[key];
  return typeof value === 'string' ? value as string : null;
}

function readBoolean(record: Record<string, Object>, key: string): boolean | null {
  const value = record[key];
  return typeof value === 'boolean' ? value as boolean : null;
}

function readNullableString(record: Record<string, Object>, key: string): string | null | undefined {
  const value = record[key];
  if (value === null) {
    return null;
  }
  return typeof value === 'string' ? value as string : undefined;
}

export function decodeHealth(json: Object | null): HealthOutput | null {
  const record = asRecord(json);
  if (record === null) {
    return null;
  }
  const ok = readBoolean(record, 'ok');
  const version = readString(record, 'version');
  if (ok !== true || version === null) {
    return null;
  }
  const result: HealthOutput = { ok: ok, version: version };
  return result;
}

export function decodeMe(json: Object | null): MeView | null {
  const record = asRecord(json);
  if (record === null) {
    return null;
  }
  const userId = readString(record, 'userId');
  const email = readString(record, 'email');
  const name = readString(record, 'name');
  const spaceId = readString(record, 'spaceId');
  const needsModel = readBoolean(record, 'needsModel');
  const defaultProvider = readNullableString(record, 'defaultProvider');
  const defaultModel = readNullableString(record, 'defaultModel');
  if (userId === null || !userId || email === null || name === null || spaceId === null || !spaceId
    || needsModel === null || defaultProvider === undefined || defaultModel === undefined) {
    return null;
  }
  const result: MeView = {
    userId: userId,
    email: email,
    name: name,
    spaceId: spaceId,
    needsModel: needsModel,
    defaultProvider: defaultProvider,
    defaultModel: defaultModel,
  };
  return result;
}

export function decodeSpaceNavigation(json: Object | null): SpaceNavigationView | null {
  const record = asRecord(json);
  if (record === null) {
    return null;
  }
  const current = asRecord(record['current']);
  if (current === null) {
    return null;
  }
  const id = readString(current, 'id');
  const name = readString(current, 'name');
  if (id === null || !id || name === null) {
    return null;
  }
  const result: SpaceNavigationView = { currentId: id, currentName: name };
  return result;
}

/**
 * GET /api/auth/capabilities. Modern servers send passwordAuth/sso; pre-SSO servers omit both
 * and only had credential accounts (legacyAuthCapabilitiesSchema: passwordAuth true, sso null).
 * providers wins when present, including an empty list; otherwise sso alone (signInProviders).
 */
export function decodeAuthCapabilities(json: Object | null): AuthCapabilitiesView | null {
  const record = asRecord(json);
  if (record === null) {
    return null;
  }
  const passwordReset = readBoolean(record, 'passwordReset');
  const resetUrl = readNullableString(record, 'resetUrl');
  if (passwordReset === null || resetUrl === undefined) {
    return null;
  }
  const passwordAuthRaw = readBoolean(record, 'passwordAuth');
  const passwordAuth = passwordAuthRaw === null ? true : passwordAuthRaw;
  const emailCodeRaw = readBoolean(record, 'emailCode');
  const emailCode = emailCodeRaw === null ? false : emailCodeRaw;
  let ssoName: string | null = null;
  const sso = asRecord(record['sso']);
  if (sso !== null) {
    const ssoNameRaw = readString(sso, 'name');
    if (ssoNameRaw === null || !ssoNameRaw) {
      return null;
    }
    ssoName = ssoNameRaw;
  }
  const providers: SignInProviderView[] = [];
  const providersRaw = record['providers'];
  if (providersRaw !== undefined && providersRaw !== null) {
    if (!Array.isArray(providersRaw)) {
      return null;
    }
    for (const item of providersRaw as Object[]) {
      const provider = asRecord(item);
      if (provider === null) {
        return null;
      }
      const id = readString(provider, 'id');
      const name = readString(provider, 'name');
      if (id === null || !id || name === null || !name) {
        return null;
      }
      const view: SignInProviderView = { id: id, name: name };
      providers.push(view);
    }
  } else if (ssoName !== null) {
    const legacy: SignInProviderView = { id: 'oidc', name: ssoName };
    providers.push(legacy);
  }
  const result: AuthCapabilitiesView = {
    passwordAuth: passwordAuth,
    passwordReset: passwordReset,
    resetUrl: resetUrl,
    emailCode: emailCode,
    ssoName: ssoName,
    providers: providers,
  };
  return result;
}
