// Group edit rules (M8), ported from the two real sources: contracts' defaultGroupName, and the
// mobile group-settings screen's save input and membership-conflict merge. Pure — no device, no
// network — so the vitest port test loads this file as TypeScript and replays the same decisions.
import type { GroupView } from '../../contract/decode';
import type { RpcError } from '../../net/errors';

/** contracts GROUP_MEMBER_MIN / GROUP_MEMBER_MAX / GROUP_NAME_MAX_LENGTH. */
export const GROUP_MEMBER_MIN = 2;
export const GROUP_MEMBER_MAX = 10;
export const GROUP_NAME_MAX_LENGTH = 80;

/** The server's membership precondition message (groups/update); the client recognizes it. */
export const GROUP_MEMBERS_CHANGED = 'Group members changed. Refresh and try again.';

/** contracts' defaultGroupName: pick order kept, the name limit honored, no split surrogate. */
export function defaultGroupName(names: string[]): string {
  const value = names.join(', ').trim().slice(0, GROUP_NAME_MAX_LENGTH);
  const last = value.charCodeAt(value.length - 1);
  return (last >= 0xd800 && last <= 0xdbff ? value.slice(0, -1) : value).trim();
}

/** True for the one 404 a membership replacement answers when another client changed the group. */
export function isGroupChangedError(error: RpcError | null): boolean {
  return error !== null && error.status === 404 && error.message === GROUP_MEMBERS_CHANGED;
}

/** The members the client and server both count: the ones still in the active bot list. */
export function activeMemberIds(group: GroupView, activeBotIds: string[]): string[] {
  const active = new Set<string>(activeBotIds);
  const ids: string[] = [];
  for (const member of group.members) {
    if (active.has(member.botId)) {
      ids.push(member.botId);
    }
  }
  return ids;
}

/** The group as this visit last read it, which its unsaved edits are kept over. */
export interface GroupEdit {
  groupId: string;
  members: string[];
}

/**
 * Mobile group-settings' merge (apps/mobile/app/group-settings.tsx): after a refresh, another
 * client's member changes land, this visit's unsaved edits stay — a locally deselected member
 * stays off, a locally added bot stays on — and a different group starts from its own members.
 */
export function rebaseGroupEdit(previous: GroupEdit, next: GroupEdit, activeBotIds: string[],
  selected: string[], deselected: Set<string>): string[] {
  if (previous.groupId !== next.groupId) {
    deselected.clear();
    return [...next.members];
  }
  const previousMembers = new Set<string>(previous.members);
  const selectable = new Set<string>(activeBotIds);
  const merged: string[] = [];
  for (const id of next.members) {
    if (!deselected.has(id) && (!previousMembers.has(id) || selected.includes(id))
      && !merged.includes(id)) {
      merged.push(id);
    }
  }
  for (const id of selected) {
    if (!previousMembers.has(id) && selectable.has(id) && !merged.includes(id)) {
      merged.push(id);
    }
  }
  return merged;
}

/**
 * The groups/update body for the edits made: the name when it changed and the membership (with
 * the baseline the server checks it against) when it changed; null when nothing did. The name and
 * membership are compared to the visit's baseline, never a fresher read, as mobile does.
 */
export function groupUpdateInput(groupId: string, baselineName: string, name: string,
  baseline: string[], selected: string[]): Record<string, Object> | null {
  const body: Record<string, Object> = {};
  const nextName = name.trim();
  if (nextName !== baselineName) {
    body['name'] = nextName;
  }
  if (selected.join(',') !== baseline.join(',')) {
    body['botIds'] = selected;
    body['expectedBotIds'] = baseline;
  }
  if (Object.keys(body).length === 0) {
    return null;
  }
  body['groupId'] = groupId;
  return body;
}