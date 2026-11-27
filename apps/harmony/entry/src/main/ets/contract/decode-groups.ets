// Group rows for the settings surface (M8): the inbox row plus its member list. Per-entry
// discipline, as thread-decode holds for thread members: an absent members field reads as none,
// a field of another type fails the whole row (a group it cannot read is not shown), and one
// bad entry is dropped without failing its group. The inbox path stays on decodeGroup.
import { asRecord, decodeGroup, decodeRows, decodeRoster, readString } from './decode';
import type { GroupMemberView, GroupView, RosterView } from './decode';

/** One member row: identity only (avatar set and run status are not read here). */
export function decodeGroupMember(json: Object | null): GroupMemberView | null {
  const record = asRecord(json);
  if (record === null) {
    return null;
  }
  const botId = readString(record, 'botId');
  const name = readString(record, 'name');
  const color = readString(record, 'color');
  if (botId === null || !botId || name === null || color === null) {
    return null;
  }
  const member: GroupMemberView = { botId: botId, name: name, color: color };
  return member;
}

/** Absent reads as no members; a value that is not an array fails the row (undefined only). */
function readMembers(record: Record<string, Object>): GroupMemberView[] | null {
  const raw = record['members'];
  if (raw === undefined) {
    return [];
  }
  if (!Array.isArray(raw)) {
    return null;
  }
  const members: GroupMemberView[] = [];
  for (const item of raw as Object[]) {
    const member = decodeGroupMember(item);
    if (member !== null) {
      members.push(member);
    }
  }
  return members;
}

/** A group row whose members the settings screen can edit; null when the row cannot be read. */
export function decodeGroupWithMembers(json: Object | null): GroupView | null {
  const group = decodeGroup(json);
  if (group === null) {
    return null;
  }
  const record = asRecord(json);
  if (record === null) {
    return null;
  }
  const members = readMembers(record);
  if (members === null) {
    return null;
  }
  group.members = members;
  return group;
}

function decodeGroupRowsWithMembers(json: Object | null): GroupView[] | null {
  return decodeRows(json, decodeGroupWithMembers);
}

/** spaces/list as the roster store reads it: bots plus groups that carry their members. */
export function decodeRosterWithMembers(json: Object | null): RosterView | null {
  return decodeRoster(json, decodeGroupRowsWithMembers);
}