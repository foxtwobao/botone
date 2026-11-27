// The group surface of the offline fixture server (M8): the group rows spaces/list renders and
// the write RPCs the group screens send — create, update (with the membership precondition),
// remove, archive and restore. Mounted from spike-sse-server.mjs, the server's one daemon. Every
// group, bot and id here is a fake probe, never a real one.
import { bearer, json, rpcError } from "./fixture-http.mjs";

const SPACE = "space-fake";
const GROUP_MEMBER_MIN = 2;
const GROUP_MEMBER_MAX = 10;
// The server's stores/groups.ts precondition refusal, which the client recognizes by status+text.
const MEMBERS_CHANGED = "Group members changed. Refresh and try again.";

let state = null;

function memberOf(bot) {
  return { botId: bot.id, name: bot.name, color: bot.color };
}

export function makeGroup(id, name, members = [], over = {}) {
  return {
    id,
    spaceId: SPACE,
    name,
    pinned: false,
    sectionId: null,
    members,
    preview: "",
    unread: false,
    snoozedUntil: null,
    updatedAt: "2026-11-21T10:00:00.000Z",
    archivedAt: null,
    ...over,
  };
}

/** Seeds the fake groups over the server's current bots; called on start and on every reset. */
export function resetGroups(bots) {
  const seeded = (id) => {
    const bot = bots.find((entry) => entry.id === id);
    return bot ? memberOf(bot) : null;
  };
  const team = [seeded("bot-1"), seeded("bot-2")].filter(Boolean);
  state = {
    bots,
    groups: [
      makeGroup("group-1", "Team", team, {
        unread: true,
        preview: "Group chat",
        updatedAt: "2026-11-21T11:30:00.000Z",
      }),
      makeGroup("group-2", "Old Team", [], { archivedAt: "2026-11-19T09:00:00.000Z" }),
    ],
    creates: 0,
    writes: [],
  };
}

export function activeGroups() {
  return state.groups.filter((group) => group.archivedAt === null);
}

export function archivedGroups() {
  return state.groups.filter((group) => group.archivedAt !== null);
}

function activeBots() {
  return state.bots.filter((bot) => bot.archivedAt === null);
}

/** The members a botIds list names, or null when the list breaks the membership rule. */
function membersFor(botIds) {
  if (!Array.isArray(botIds)) return null;
  const unique = [...new Set(botIds)];
  if (unique.length < GROUP_MEMBER_MIN || unique.length > GROUP_MEMBER_MAX) return null;
  const members = [];
  for (const botId of unique) {
    const bot = activeBots().find((entry) => entry.id === botId);
    if (!bot) return null;
    members.push(memberOf(bot));
  }
  return members;
}

/** The server compares the precondition against the group's active members, archived excluded. */
function activeMemberIds(group) {
  const active = new Set(activeBots().map((bot) => bot.id));
  return group.members.filter((member) => active.has(member.botId)).map((member) => member.botId);
}

function sameMembers(expected, actual) {
  if (expected.length !== actual.length) return false;
  const wanted = new Set(expected);
  return actual.every((botId) => wanted.has(botId));
}

/** The groups/* RPCs; true when this route answered. signal() sends the roster signal. */
export function handleGroupsRpc(req, res, body, signal) {
  if (!req.url.startsWith("/rpc/groups/")) return false;
  if (bearer(req) !== "fake-token") {
    rpcError(res, 401, "UNAUTHORIZED", "Session expired");
    return true;
  }
  const input = JSON.parse(body || "{}").json ?? {};
  state.writes.push({ path: req.url, input });
  if (req.url === "/rpc/groups/create") {
    const members = membersFor(input.botIds);
    if (!members) {
      rpcError(res, 404, "NOT_FOUND", "Groups require 2 to 10 distinct bots");
      return true;
    }
    state.creates += 1;
    const group = makeGroup(
      `group-new-${state.creates}`,
      String(input.name ?? "").trim(),
      members,
      {
        updatedAt: new Date().toISOString(),
      },
    );
    state.groups.push(group);
    signal("roster");
    json(res, 200, { json: group });
    return true;
  }
  if (req.url === "/rpc/groups/update") {
    const group = state.groups.find((entry) => entry.id === input.groupId);
    if (!group || group.archivedAt !== null) {
      rpcError(res, 404, "NOT_FOUND", "Group not found");
      return true;
    }
    if (Array.isArray(input.expectedBotIds)) {
      const actual = activeMemberIds(group);
      if (!sameMembers([...new Set(input.expectedBotIds)], actual)) {
        rpcError(res, 404, "NOT_FOUND", MEMBERS_CHANGED);
        return true;
      }
    }
    if (Array.isArray(input.botIds)) {
      const members = membersFor(input.botIds);
      if (!members) {
        rpcError(res, 404, "NOT_FOUND", "Groups require 2 to 10 distinct bots");
        return true;
      }
      group.members = members;
    }
    if (typeof input.name === "string") group.name = input.name.trim();
    group.updatedAt = new Date().toISOString();
    signal("roster");
    json(res, 200, { json: group });
    return true;
  }
  if (req.url === "/rpc/groups/remove") {
    const index = state.groups.findIndex((entry) => entry.id === input.groupId);
    if (index < 0) {
      rpcError(res, 404, "NOT_FOUND", "Group not found");
      return true;
    }
    state.groups.splice(index, 1);
    signal("roster");
    json(res, 200, { json: { ok: true } });
    return true;
  }
  if (req.url === "/rpc/groups/archive" || req.url === "/rpc/groups/restore") {
    const group = state.groups.find((entry) => entry.id === input.groupId);
    if (!group) {
      rpcError(res, 404, "NOT_FOUND", "Group not found");
      return true;
    }
    group.archivedAt = req.url.endsWith("/archive") ? new Date().toISOString() : null;
    signal("roster");
    json(res, 200, { json: { ok: true } });
    return true;
  }
  if (req.url === "/rpc/groups/listArchived") {
    json(res, 200, { json: archivedGroups() });
    return true;
  }
  rpcError(res, 404, "NOT_FOUND", "Not found");
  return true;
}

/** The controls the suites read: the groups as bots name them. */
export function handleGroupsControl(req, res) {
  if (req.url === "/__groups") {
    json(res, 200, {
      groups: state.groups.map((group) => ({
        id: group.id,
        name: group.name,
        archivedAt: group.archivedAt,
        botIds: group.members.map((member) => member.botId),
      })),
    });
    return true;
  }
  if (req.url === "/__groupReset") {
    resetGroups(state.bots);
    json(res, 200, { ok: true });
    return true;
  }
  return false;
}
