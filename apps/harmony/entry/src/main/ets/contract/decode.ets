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

/** A bot inbox row (M2): identity color, unread, preview, run status, pinned order, snooze. */
export interface BotView {
  id: string;
  name: string;
  color: string;
  pinned: boolean;
  unread: boolean;
  preview: string;
  status: string;
  updatedAt: string;
  snoozedUntil: string | null;
}

/** A group inbox row (M2): no identity color (bots carry the only color). */
export interface GroupView {
  id: string;
  name: string;
  pinned: boolean;
  unread: boolean;
  preview: string;
  updatedAt: string;
  snoozedUntil: string | null;
}

/** The default Space's roster: its bots and groups, each decoded row by row. */
export interface RosterView {
  bots: BotView[];
  groups: GroupView[];
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

/** snoozedUntil is nullable-optional: absent or null means not snoozed; a non-string is a failure. */
function readSnoozed(record: Record<string, Object>): string | null | undefined {
  const value = record['snoozedUntil'];
  if (value === undefined || value === null) {
    return null;
  }
  return typeof value === 'string' ? value as string : undefined;
}

export function decodeBot(json: Object | null): BotView | null {
  const record = asRecord(json);
  if (record === null) {
    return null;
  }
  const id = readString(record, 'id');
  const name = readString(record, 'name');
  const color = readString(record, 'color');
  const pinned = readBoolean(record, 'pinned');
  const unread = readBoolean(record, 'unread');
  const preview = readString(record, 'preview');
  const status = readString(record, 'status');
  const updatedAt = readString(record, 'updatedAt');
  const snoozedUntil = readSnoozed(record);
  if (id === null || !id || name === null || color === null || pinned === null || unread === null
    || preview === null || status === null || updatedAt === null || snoozedUntil === undefined) {
    return null;
  }
  const result: BotView = {
    id: id, name: name, color: color, pinned: pinned, unread: unread, preview: preview,
    status: status, updatedAt: updatedAt, snoozedUntil: snoozedUntil,
  };
  return result;
}

export function decodeGroup(json: Object | null): GroupView | null {
  const record = asRecord(json);
  if (record === null) {
    return null;
  }
  const id = readString(record, 'id');
  const name = readString(record, 'name');
  const pinned = readBoolean(record, 'pinned');
  const unread = readBoolean(record, 'unread');
  const preview = readString(record, 'preview');
  const updatedAt = readString(record, 'updatedAt');
  const snoozedUntil = readSnoozed(record);
  if (id === null || !id || name === null || pinned === null || unread === null || preview === null
    || updatedAt === null || snoozedUntil === undefined) {
    return null;
  }
  const result: GroupView = {
    id: id, name: name, pinned: pinned, unread: unread, preview: preview,
    updatedAt: updatedAt, snoozedUntil: snoozedUntil,
  };
  return result;
}

/** A list of rows: a non-array fails; a row that cannot decode is dropped, not fatal (per-entry). */
function decodeRows<T>(json: Object | null, decode: (item: Object | null) => T | null): T[] | null {
  if (json === null || json === undefined || !Array.isArray(json)) {
    return null;
  }
  const rows: T[] = [];
  for (const item of json as Object[]) {
    const row = decode(item);
    if (row !== null) {
      rows.push(row);
    }
  }
  return rows;
}

export function decodeBotList(json: Object | null): BotView[] | null {
  return decodeRows(json, decodeBot);
}

export function decodeGroupList(json: Object | null): GroupView[] | null {
  return decodeRows(json, decodeGroup);
}

/** spaces/list roster: current.bots + current.groups. Identity stays with decodeSpaceNavigation. */
export function decodeRoster(json: Object | null): RosterView | null {
  const record = asRecord(json);
  if (record === null) {
    return null;
  }
  const current = asRecord(record['current']);
  if (current === null) {
    return null;
  }
  const bots = decodeBotList(current['bots']);
  const groups = decodeGroupList(current['groups']);
  if (bots === null || groups === null) {
    return null;
  }
  const result: RosterView = { bots: bots, groups: groups };
  return result;
}

/** archive/restore answer: {ok:true}. */
export function decodeOk(json: Object | null): boolean {
  const record = asRecord(json);
  return record !== null && record['ok'] === true;
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
