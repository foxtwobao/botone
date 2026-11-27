// Phase 1 contract subset decoders (design §4): explicit per-field reads with runtime type
// guards, the S1-verified ArkTS style. No zod/oRPC on device. A decoder returns null when a
// consumed field is missing or mistyped; fields outside the M1 view are ignored (forward
// compatible). The layer-1 snapshots pin exactly these views to the real contract schemas.

import type { UploadLimits } from '../thread/attachments';

export interface HealthOutput {
  ok: boolean;
  version: string;
}

export interface MeView extends UploadLimits {
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
  /** M7: the bot reads its finished replies aloud (the auto-speak gate). */
  autoSpeak: boolean;
}

/** One group member (M8 settings): the identity the picker shows, no avatar set or run status. */
export interface GroupMemberView {
  botId: string;
  name: string;
  color: string;
}

/** A group inbox row (M2): no identity color (bots carry the only color). members is the
 *  settings surface's read (decode-groups); the inbox row carries none. */
export interface GroupView {
  id: string;
  name: string;
  pinned: boolean;
  unread: boolean;
  preview: string;
  updatedAt: string;
  snoozedUntil: string | null;
  members: GroupMemberView[];
}

/** The default Space's roster: its bots and groups, each decoded row by row. */
export interface RosterView {
  bots: BotView[];
  groups: GroupView[];
}

/** A provider button's icon: a viewBox and up to 8 path d strings, each with an optional brand
 *  fill (#rrggbb; absent means the button's text color). Optional end to end: an older server
 *  sends no presentation and the button renders its label alone. A presentation that does not
 *  match the wire schema fails its provider row; the rest of the capabilities still decode. */
export interface ProviderMarkPathView {
  d: string;
  fill: string | null;
}

export interface ProviderMarkView {
  viewBox: string;
  paths: ProviderMarkPathView[];
}

/** One sign-in provider button: id, display name and optional presentation. */
export interface SignInProviderView {
  id: string;
  name: string;
  /** solid | outline; absent reads as solid. */
  variant: string | null;
  mark: ProviderMarkView | null;
}

/** presentation is optional: absent or null reads as no mark; a broken one fails the row. */
function readPresentation(record: Record<string, Object>): [string | null, ProviderMarkView | null] | undefined {
  const value = record['presentation'];
  if (value === undefined || value === null) {
    return [null, null];
  }
  const presentation = asRecord(value);
  if (presentation === null) {
    return undefined;
  }
  const variantRaw = readString(presentation, 'variant');
  const variant = variantRaw === null ? null : variantRaw;
  const markValue = presentation['mark'];
  if (markValue === undefined || markValue === null) {
    return [variant, null];
  }
  const mark = asRecord(markValue);
  const viewBox = mark !== null ? readString(mark, 'viewBox') : null;
  const pathsRaw = mark !== null ? mark['paths'] : undefined;
  if (viewBox === null || !Array.isArray(pathsRaw)) {
    return undefined;
  }
  const paths: ProviderMarkPathView[] = [];
  for (const item of pathsRaw as Object[]) {
    const path = asRecord(item);
    if (path === null) {
      return undefined;
    }
    const d = readString(path, 'd');
    if (d === null) {
      return undefined;
    }
    // The wire schema makes fill optional: absent (or null) inherits the button's text color;
    // a value present but not #rrggbb is invalid and fails the row.
    const fillRaw = path['fill'];
    let fill: string | null = null;
    if (fillRaw !== undefined && fillRaw !== null) {
      if (typeof fillRaw !== 'string' || !/^#[0-9a-fA-F]{6}$/.test(fillRaw as string)) {
        return undefined;
      }
      fill = fillRaw as string;
    }
    const row: ProviderMarkPathView = { d: d, fill: fill };
    paths.push(row);
  }
  const view: ProviderMarkView = { viewBox: viewBox, paths: paths };
  return [variant, view];
}

export interface AuthCapabilitiesView {
  passwordAuth: boolean;
  passwordReset: boolean;
  resetUrl: string | null;
  emailCode: boolean;
  /** Whether this request may create an account; absent reads as open (older servers omit it). */
  registrationOpen: boolean;
  ssoName: string | null;
  providers: SignInProviderView[];
}

export function asRecord(value: Object | null | undefined): Record<string, Object> | null {
  if (value === null || value === undefined || typeof value !== 'object' || Array.isArray(value)) {
    return null;
  }
  return value as Record<string, Object>;
}

export function readString(record: Record<string, Object>, key: string): string | null {
  const value = record[key];
  return typeof value === 'string' ? value as string : null;
}

export function readBoolean(record: Record<string, Object>, key: string): boolean | null {
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
  const maxBytes = record['maxUploadSizeBytes'];
  if (typeof maxBytes === 'number' && Number.isSafeInteger(maxBytes) && (maxBytes as number) > 0) {
    result.maxUploadSizeBytes = maxBytes as number;
  }
  const maxCount = record['maxAttachmentsPerMessage'];
  if (typeof maxCount === 'number' && Number.isSafeInteger(maxCount) && (maxCount as number) > 0) {
    result.maxAttachmentsPerMessage = maxCount as number;
  }
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

/** autoSpeak is optional: an older server sends no such field, and a bot without it does not
 *  read aloud; a value of another type still fails the row. */
function readAutoSpeak(record: Record<string, Object>): boolean | undefined {
  const value = record['autoSpeak'];
  if (value === undefined || value === null) {
    return false;
  }
  return typeof value === 'boolean' ? value as boolean : undefined;
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
  const autoSpeak = readAutoSpeak(record);
  if (id === null || !id || name === null || color === null || pinned === null || unread === null
    || preview === null || status === null || updatedAt === null || snoozedUntil === undefined
    || autoSpeak === undefined) {
    return null;
  }
  const result: BotView = {
    id: id, name: name, color: color, pinned: pinned, unread: unread, preview: preview,
    status: status, updatedAt: updatedAt, snoozedUntil: snoozedUntil, autoSpeak: autoSpeak,
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
    updatedAt: updatedAt, snoozedUntil: snoozedUntil, members: [],
  };
  return result;
}

/** A list of rows: a non-array fails; a row that cannot decode is dropped, not fatal (per-entry). */
export function decodeRows<T>(json: Object | null, decode: (item: Object | null) => T | null): T[] | null {
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

/** spaces/list roster: current.bots + current.groups. Identity stays with decodeSpaceNavigation.
 *  The group rows decode with the caller's reader: the inbox's, or the settings one that also
 *  reads each group's members. */
export function decodeRoster(json: Object | null,
  decodeGroups: (value: Object | null) => GroupView[] | null = decodeGroupList): RosterView | null {
  const record = asRecord(json);
  if (record === null) {
    return null;
  }
  const current = asRecord(record['current']);
  if (current === null) {
    return null;
  }
  const bots = decodeBotList(current['bots']);
  const groups = decodeGroups(current['groups']);
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
  // Optional: older servers omit it, and a mistyped value reads as its absence (open).
  const registrationOpenRaw = readBoolean(record, 'registrationOpen');
  const registrationOpen = registrationOpenRaw === null ? true : registrationOpenRaw;
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
      const presentation = readPresentation(provider);
      // A presentation that does not match the wire schema fails its own row only.
      if (presentation === undefined) {
        continue;
      }
      const view: SignInProviderView = {
        id: id, name: name, variant: presentation[0], mark: presentation[1],
      };
      providers.push(view);
    }
  } else if (ssoName !== null) {
    const legacy: SignInProviderView = { id: 'oidc', name: ssoName, variant: null, mark: null };
    providers.push(legacy);
  }
  const result: AuthCapabilitiesView = {
    passwordAuth: passwordAuth,
    passwordReset: passwordReset,
    resetUrl: resetUrl,
    emailCode: emailCode,
    registrationOpen: registrationOpen,
    ssoName: ssoName,
    providers: providers,
  };
  return result;
}

/** An optional boolean flag: absent or null reads false; a value of another type fails the row. */
function readOptionalFlag(record: Record<string, Object>, key: string): boolean | undefined {
  const value = record[key];
  if (value === undefined || value === null) {
    return false;
  }
  return typeof value === 'boolean' ? value as boolean : undefined;
}

/** One models/list entry (M4 display, M9 connection forms): the consumed fields. providerName
 * is optional (older servers and ordinary chat connections omit it); a non-string is a failure.
 * recommended marks the provider's preselected model; auth is api-key | oauth | both, absent
 * reading as an API key; placeholder marks a catalog stand-in, not a real model. */
export interface ModelCatalogEntryView {
  provider: string;
  id: string;
  label: string;
  providerName: string | null;
  recommended: boolean;
  auth: string | null;
  placeholder: boolean;
}

export function decodeModelCatalogEntry(json: Object | null): ModelCatalogEntryView | null {
  const record = asRecord(json);
  if (record === null) {
    return null;
  }
  const provider = readString(record, 'provider');
  const id = readString(record, 'id');
  const label = readString(record, 'label');
  // providerName is OPTIONAL (older servers and ordinary chat connections omit it): absent or
  // null both read as null; only a non-string non-null value is a decode failure.
  const rawName = record['providerName'];
  const providerName: string | null | undefined = rawName === undefined || rawName === null
    ? null
    : typeof rawName === 'string' ? rawName as string : undefined;
  // recommended/placeholder are optional flags: absent reads false, another type fails the row.
  const recommended = readOptionalFlag(record, 'recommended');
  const placeholder = readOptionalFlag(record, 'placeholder');
  // auth is optional: absent reads null, which the connect screens treat as an API key.
  const rawAuth = record['auth'];
  const auth: string | null | undefined = rawAuth === undefined || rawAuth === null
    ? null
    : typeof rawAuth === 'string' ? rawAuth as string : undefined;
  if (provider === null || !provider || id === null || !id || label === null || providerName === undefined
    || recommended === undefined || placeholder === undefined || auth === undefined) {
    return null;
  }
  const result: ModelCatalogEntryView = {
    provider: provider, id: id, label: label, providerName: providerName,
    recommended: recommended, auth: auth, placeholder: placeholder,
  };
  return result;
}

/** models/list: a non-array fails; an entry that cannot decode is dropped, not fatal (per-entry). */
export function decodeModelCatalog(json: Object | null): ModelCatalogEntryView[] | null {
  return decodeRows(json, decodeModelCatalogEntry);
}
