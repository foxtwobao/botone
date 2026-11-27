// The Space surface of the offline fixture server (A1): spaces/list answers per selected Space
// (x-rakazo-space-id), every answer carries the Space list, a deleted Space answers 401, and a
// hold control keeps one spaces/list answer in flight so a switch can be driven under it.
// Mounted from spike-sse-server.mjs, the server's one daemon. Every id and name here is a fake
// probe, never a real one.
import { bearer, json, rpcError } from "./fixture-http.mjs";
import { activeGroups } from "./group-fixture.mjs";

const SPACE_FAKE = "space-fake";
const SPACE_SECOND = "space-second";
const STALE = new Set(["space-stale"]);

// The server's current roster array; resetRoster rebuilds it, so resetSpaces re-points this.
let bots = [];
// One answer held in flight (the in-flight switch case); released on demand or dropped on reset.
let holdNext = false;
let held = [];

function secondBot() {
  return {
    autoSpeak: false,
    id: "bot-s1",
    spaceId: SPACE_SECOND,
    name: "Solo",
    title: "",
    color: "#6A6BF5",
    pinned: false,
    sectionId: null,
    unread: false,
    snoozedUntil: null,
    parentBotId: null,
    preview: "Only chat",
    status: "idle",
    runErrorId: null,
    updatedAt: "2026-11-21T09:30:00.000Z",
    archivedAt: null,
  };
}

/** Every Space the person can open: id and name are what the client reads. */
function spaces() {
  return [
    {
      id: SPACE_FAKE,
      name: "Ada’s Space",
      isDefault: true,
      hasContent: true,
      bots: [],
      groups: [],
      externalConversations: [],
      botSections: [],
    },
    {
      id: SPACE_SECOND,
      name: "Second Space",
      isDefault: false,
      hasContent: true,
      bots: [],
      groups: [],
      externalConversations: [],
      botSections: [],
    },
  ];
}

function navigation(spaceId) {
  if (spaceId === SPACE_SECOND) {
    return {
      current: {
        id: SPACE_SECOND,
        name: "Second Space",
        bots: [secondBot()],
        groups: [],
        botSections: [],
      },
      spaces: spaces(),
      firstBotDue: false,
    };
  }
  return {
    current: {
      id: SPACE_FAKE,
      name: "Ada’s Space",
      bots: bots.filter((bot) => bot.archivedAt === null),
      groups: activeGroups(),
      botSections: [],
    },
    spaces: spaces(),
    firstBotDue: false,
  };
}

/** Re-points this fixture at the server's rebuilt roster array; drops a leftover held answer. */
export function resetSpaces(rosterBots) {
  bots = rosterBots;
  holdNext = false;
  for (const entry of held.splice(0)) entry.res.destroy();
}

function answerSpacesList(req, res) {
  if (bearer(req) !== "fake-token") {
    return rpcError(res, 401, "UNAUTHORIZED", "Session expired");
  }
  const space = req.headers["x-rakazo-space-id"] ?? "";
  if (STALE.has(space)) {
    return rpcError(res, 401, "UNAUTHORIZED", "Space inaccessible");
  }
  if (holdNext) {
    holdNext = false;
    held.push({ res, space });
    res.on("close", () => {
      held = held.filter((entry) => entry.res !== res);
    });
    return;
  }
  json(res, 200, { json: navigation(space) });
}

/** spaces/list and the two hold controls; true when this route answered. */
export function handleSpaceRoute(req, res) {
  if (req.url === "/rpc/spaces/list") {
    answerSpacesList(req, res);
    return true;
  }
  if (req.url === "/__holdSpacesList") {
    holdNext = true;
    json(res, 200, { ok: true });
    return true;
  }
  if (req.url === "/__releaseSpacesList") {
    for (const entry of held.splice(0)) {
      if (!entry.res.destroyed) {
        json(entry.res, 200, { json: navigation(entry.space) });
      }
    }
    json(res, 200, { ok: true });
    return true;
  }
  return false;
}
