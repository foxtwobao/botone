// The inbox projection (design §6.3 RosterStore), ported from the core helpers mobile composes:
// chatSnoozed (packages/core/src/threads/chat-snooze.ts), isRunWorking (runs/run-state.ts) and
// groupBotsForSidebar (bots/bot-sections.ts) with no sections. Chats arrive in server order (pinned
// first, then position); bots precede groups within each bucket. A snoozed chat hides until it
// wakes. The layer-2 inbox fixture drives the REAL core functions and this port replays it.
import type { BotView, GroupView } from '../contract/decode';

/** The reads an archive/restore makes out of date (the roster and both archived lists). */
export const ROSTER_STALE: string[] = ['spaces/list', 'bots/listArchived', 'groups/listArchived'];

/** Runs the bot is working on, which the row shows as working (WORKING_RUN_STATUSES). */
const WORKING_RUN_STATUSES: string[] = ['queued', 'leased', 'running'];

export function isRunWorking(status: string): boolean {
  return WORKING_RUN_STATUSES.includes(status);
}

/** Hidden from the list: snoozed into the future (chatSnoozed). */
export function chatSnoozed(snoozedUntil: string | null, now: number): boolean {
  if (snoozedUntil === null || !snoozedUntil) {
    return false;
  }
  const wake = Date.parse(snoozedUntil);
  return !Number.isNaN(wake) && wake > now;
}

/**
 * LazyForEach reuses a ListItem while its key is unchanged, so the key must carry the rendered
 * content: a new preview/status/unread changes the key and forces the row to re-render.
 */
export function rowKey(row: InboxRow): string {
  return `${row.kind}-${row.id}-${row.unread ? 1 : 0}-${row.working ? 1 : 0}-${row.updatedAt}-${row.preview}`;
}

/** One inbox row, bot or group, with the fields the row renders. */
export interface InboxRow {
  kind: string;
  id: string;
  name: string;
  preview: string;
  updatedAt: string;
  unread: boolean;
  pinned: boolean;
  /** The bot's identity color; empty for a group (bots carry the only color). */
  color: string;
  working: boolean;
}

/**
 * Mixed bots + groups, pinned first, server order preserved, snoozed chats hidden. With no
 * sections this is groupBotsForSidebar's pinned bucket followed by its unassigned bucket.
 */
export function projectInbox(bots: BotView[], groups: GroupView[], now: number): InboxRow[] {
  const pinned: InboxRow[] = [];
  const rest: InboxRow[] = [];
  for (const bot of bots) {
    if (chatSnoozed(bot.snoozedUntil, now)) {
      continue;
    }
    const row: InboxRow = {
      kind: 'bot', id: bot.id, name: bot.name, preview: bot.preview, updatedAt: bot.updatedAt,
      unread: bot.unread, pinned: bot.pinned, color: bot.color, working: isRunWorking(bot.status),
    };
    (bot.pinned ? pinned : rest).push(row);
  }
  for (const group of groups) {
    if (chatSnoozed(group.snoozedUntil, now)) {
      continue;
    }
    const row: InboxRow = {
      kind: 'group', id: group.id, name: group.name, preview: group.preview, updatedAt: group.updatedAt,
      unread: group.unread, pinned: group.pinned, color: '', working: false,
    };
    (group.pinned ? pinned : rest).push(row);
  }
  return [...pinned, ...rest];
}
