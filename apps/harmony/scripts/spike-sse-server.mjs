// Offline fixture server for the instrumented suites. Run on the host:
// node scripts/spike-sse-server.mjs [port]; the emulator reaches it at http://10.0.2.2:<port>.
//
// M0 S3 routes (unchanged): /sse splits one frame across writes, cutting a multi-byte UTF-8
// character mid-byte; /sse-cut closes mid-frame; a wrong Accept header is answered 400.
//
// M1 routes: a wire-format-faithful fake of the RPC/auth surface the net layer ports —
// health, me (401 by bearer/space), spaces/list, error/timeout/oversize branches, better-auth
// sign-in token shapes, capabilities, and sign-out with a delivery log at GET /__state.
// All credentials here are fake probes, never real ones.
import { createServer } from "node:http";

const port = Number(process.argv[2] ?? 8787);

// 鸿 is U+9E3F (UTF-8 E9 B8 BF); cutting after its first byte forces one character to
// span two writes, so the client must reassemble UTF-8 across chunk boundaries.
const splitFrame = Buffer.from('data: {"json":{"type":"split","seq":2,"text":"鸿蒙"}}\n\n');
const cut = splitFrame.indexOf("鸿") + 1;

const signOuts = [];
// Every x-rakazo-client-build header the client sends, so tests can pin the build handshake.
const clientBuilds = [];
const ME = {
  userId: "user-fake",
  email: "ada@example.com",
  name: "Ada",
  spaceId: "space-fake",
  needsModel: false,
  defaultProvider: "fake-provider",
  defaultModel: "fake-model",
};

// M4: the read-only model display's catalog. The default names the first entry, so the settings
// row shows the SERVER label; /__models lets a test move the default off the catalog to prove the
// generic fallback (no raw id ever reaches the screen). Every id here is a fake probe.
let MODELS = [
  {
    provider: "fake-provider",
    id: "fake-model",
    label: "Fake Fast Model",
    providerName: "Fake Maker",
    billing: "credits",
  },
  { provider: "fake-provider", id: "fake-slow", label: "Fake Slow Model", billing: "credits" },
];
function resetModels() {
  MODELS = [
    {
      provider: "fake-provider",
      id: "fake-model",
      label: "Fake Fast Model",
      providerName: "Fake Maker",
      billing: "credits",
    },
    { provider: "fake-provider", id: "fake-slow", label: "Fake Slow Model", billing: "credits" },
  ];
  ME.defaultProvider = "fake-provider";
  ME.defaultModel = "fake-model";
}

// ---- M2 roster state -------------------------------------------------------
// A mutable fake roster so archive/restore and signal-driven re-reads have something to change.
// Every /rpc request is logged (path + body + sequence) so a test can prove reads happen only on
// a signal or foreground, never on a timer. All ids/credentials here are fake probes.
const SPACE = "space-fake";
let seq = 0;
const requests = [];
const notificationClients = new Set();

function makeBot(id, name, over = {}) {
  return {
    id,
    spaceId: SPACE,
    name,
    title: "",
    color: "#3EC5A8",
    pinned: false,
    sectionId: null,
    unread: false,
    snoozedUntil: null,
    parentBotId: null,
    preview: "",
    status: "idle",
    runErrorId: null,
    updatedAt: "2026-11-21T10:00:00.000Z",
    archivedAt: null,
    ...over,
  };
}
function makeGroup(id, name, over = {}) {
  return {
    id,
    spaceId: SPACE,
    name,
    pinned: false,
    sectionId: null,
    members: [],
    preview: "",
    unread: false,
    snoozedUntil: null,
    updatedAt: "2026-11-21T10:00:00.000Z",
    archivedAt: null,
    ...over,
  };
}

let bots = [];
let groups = [];
// When offline, read RPCs drop the connection (a transport failure, not an HTTP answer) so the
// client's offline banner + memory-cache fallback can be exercised without stopping the server.
let offline = false;
const OFFLINE_READS = new Set([
  "/rpc/spaces/list",
  "/rpc/models/list",
  "/rpc/bots/list",
  "/rpc/bots/listArchived",
  "/rpc/groups/listArchived",
  // M3: the thread reads and stream are reads too — offline drops them the same way.
  "/rpc/threads/get",
  "/rpc/threads/head",
  "/rpc/threads/messages",
  "/rpc/threads/subscribe",
]);
function resetRoster() {
  bots = [
    makeBot("bot-1", "Alpha", {
      pinned: true,
      unread: true,
      status: "running",
      color: "#3EC5A8",
      preview: "Working on it",
      updatedAt: "2026-11-21T12:00:00.000Z",
    }),
    makeBot("bot-2", "Beta", {
      color: "#F5A03C",
      preview: "Hi there",
      updatedAt: "2026-11-21T11:00:00.000Z",
    }),
    makeBot("bot-3", "Gamma", { color: "#6A6BF5", archivedAt: "2026-11-20T09:00:00.000Z" }),
  ];
  groups = [
    makeGroup("group-1", "Team", {
      unread: true,
      preview: "Group chat",
      updatedAt: "2026-11-21T11:30:00.000Z",
    }),
    makeGroup("group-2", "Old Team", { archivedAt: "2026-11-19T09:00:00.000Z" }),
  ];
}
resetRoster();

const activeBots = () => bots.filter((b) => b.archivedAt === null);
const archivedBots = () => bots.filter((b) => b.archivedAt !== null);
const activeGroups = () => groups.filter((g) => g.archivedAt === null);
const archivedGroups = () => groups.filter((g) => g.archivedAt !== null);

function navigation() {
  return {
    current: {
      id: SPACE,
      name: "Ada’s Space",
      bots: activeBots(),
      groups: activeGroups(),
      botSections: [],
    },
    spaces: [],
    firstBotDue: false,
  };
}

/** Push one signal frame to every open notifications/subscribe stream. */
function sendSignal(type) {
  const frame = `data: ${JSON.stringify({ json: { type } })}\n\n`;
  for (const res of notificationClients) {
    res.write(frame);
  }
}

// ---- M3 thread state -------------------------------------------------------
// A scripted thread per target: threads/get returns its snapshot, threads/subscribe replays
// events after the requested cursor then stays open, threads/send appends the durable events
// (user echo + run.started) and answers the receipt, /__threadEvent injects one event (another
// device's activity), /__threadReset restores the script. Every id here is a fake probe.
const THREAD_SCRIPTS = new Map();
const threadClients = new Map(); // threadId -> Set<res>
let threadRefusals = 0;
let threadStall = null;

function threadEvent(threadId, seq, type, extra = {}) {
  return {
    id: `evt-${threadId}-${seq}`,
    spaceId: SPACE,
    threadId,
    botId: "bot-1",
    seq,
    type,
    createdAt: new Date().toISOString(),
    payload: {},
    ...extra,
  };
}

function scriptThread(threadId, botId) {
  const events = [
    threadEvent(threadId, 1, "thread.message.created", {
      payload: {
        messageId: `${threadId}-m1`,
        seq: 1,
        role: "user",
        blocks: [{ kind: "text", text: "hello" }],
      },
    }),
    threadEvent(threadId, 2, "run.started", {
      runId: `${threadId}-r1`,
      payload: { trigger: "user" },
    }),
    threadEvent(threadId, 3, "thread.progress", {
      runId: `${threadId}-r1`,
      payload: { delta: "Hi" },
    }),
    threadEvent(threadId, 4, "thread.progress", {
      runId: `${threadId}-r1`,
      payload: { delta: " there." },
    }),
    threadEvent(threadId, 5, "thread.message.created", {
      runId: `${threadId}-r1`,
      payload: {
        messageId: `${threadId}-m2`,
        seq: 2,
        role: "bot",
        blocks: [{ kind: "text", text: "Hi there." }],
      },
    }),
    threadEvent(threadId, 6, "run.completed", { runId: `${threadId}-r1` }),
  ];
  const state = { threadId, botId, events, sends: 0 };
  THREAD_SCRIPTS.set(threadId, state);
  return state;
}

function threadState(target) {
  const threadId = target.groupId ? `thread-${target.groupId}` : `thread-${target.botId}`;
  return THREAD_SCRIPTS.get(threadId) ?? scriptThread(threadId, target.botId ?? threadId);
}

// A seeded long thread (/__threadSeed): `count` durable user/bot message pairs numbered so the
// transcript order is provable, plus an optional trailing event script (an open ask, a running
// run, an unknown block). Seeded history lives outside `events` — pages read it directly, the
// snapshot returns only the server-shaped recent page (100 messages, olderCursor at its floor).
const THREAD_PAGE_SIZE = 100;
function seedThread(threadId, botId, count, tail = []) {
  const history = [];
  for (let i = 1; i <= count; i += 1) {
    const role = i % 2 === 1 ? "user" : "bot";
    history.push({
      id: `${threadId}-h${i}`,
      threadId,
      seq: i,
      role,
      blocks: [{ kind: "text", text: `history ${i}` }],
      botId,
      createdAt: new Date(Date.now() - (count - i) * 60_000).toISOString(),
    });
  }
  const events = tail.map((spec, index) =>
    threadEvent(threadId, count + index + 1, spec.type, {
      ...(spec.runId ? { runId: spec.runId } : {}),
      payload: spec.payload ?? {},
    }),
  );
  const state = { threadId, botId, events, sends: 0, history };
  THREAD_SCRIPTS.set(threadId, state);
  return state;
}

/** Durable messages: seeded history plus the message events, in seq order. */
function durableMessages(state) {
  const rows = [...(state.history ?? [])];
  for (const event of state.events) {
    if (event.type === "thread.message.created" || event.type === "thread.message.updated") {
      const payload = event.payload;
      const row = {
        id: payload.messageId ?? event.id,
        threadId: state.threadId,
        seq: payload.seq ?? event.seq,
        role: payload.role ?? "bot",
        blocks: payload.blocks ?? [],
        botId: event.botId,
        createdAt: event.createdAt,
      };
      if (event.runId) row.runId = event.runId;
      const index = rows.findIndex((m) => m.id === row.id);
      if (index >= 0) rows[index] = row;
      else rows.push(row);
    }
  }
  return rows.sort((a, b) => (a.seq ?? 0) - (b.seq ?? 0));
}

/** One history page older than `before`, server-shaped (THREAD_MESSAGE_PAGE_SIZE + olderCursor). */
function messagePage(state, before) {
  const rows = durableMessages(state).filter((m) => (m.seq ?? 0) < before);
  const page = rows.slice(-THREAD_PAGE_SIZE);
  const older = rows.length > page.length ? (page[0]?.seq ?? null) : null;
  return { threadId: state.threadId, messages: page, olderCursor: older };
}

/** The snapshot threads/get returns: the recent durable page plus the latest run record. */
function threadSnapshotOf(state) {
  let run = null;
  let cursor = (state.history ?? []).reduce((max, m) => Math.max(max, m.seq ?? 0), 0);
  for (const event of state.events) {
    cursor = Math.max(cursor, event.seq);
    if (event.type === "run.started") {
      run = {
        id: event.runId,
        botId: event.botId,
        threadId: state.threadId,
        taskId: event.runId,
        status: "running",
        trigger: event.payload.trigger ?? "user",
        routineId: null,
        modelProvider: null,
        modelId: null,
        error: null,
        startedAt: event.createdAt,
        completedAt: null,
        createdAt: event.createdAt,
      };
    }
    if (event.type === "run.completed" || event.type === "run.cancelled") run = null;
    if (event.type === "run.failed" && run)
      run = { ...run, status: "failed", error: event.payload.error ?? null };
    if (event.type === "run.waiting_input" && run) run = { ...run, status: "waiting_input" };
  }
  const page = messagePage(state, Number.MAX_SAFE_INTEGER);
  const snapshot = {
    threadId: state.threadId,
    cursor,
    messages: page.messages,
    olderCursor: page.olderCursor,
    run,
    activeRuns: run ? [run] : [],
  };
  if (state.botId) snapshot.botId = state.botId;
  return snapshot;
}

function pushThreadEvent(state, event) {
  state.events.push(event);
  const frame = `data: ${JSON.stringify({ json: event })}\n\n`;
  for (const res of threadClients.get(state.threadId) ?? []) {
    res.write(frame);
  }
  // Chat activity reaches the inbox as a roster signal (the M2 decision).
  sendSignal("roster");
}

function handleThreadSubscribe(req, res, body) {
  // A stream is one connection for its whole life: never share it with unary requests through
  // the client's connection pool (the kit can hand a pooled stream connection to a unary call,
  // which then waits forever — observed on the emulator as "Operation timeout", zero transfer).
  res.setHeader("connection", "close");
  if (req.headers.accept !== "text/event-stream") {
    res.writeHead(400).end();
    return;
  }
  if (bearer(req) !== "fake-token") {
    return rpcError(res, 401, "UNAUTHORIZED", "Session expired");
  }
  if (threadRefusals > 0) {
    threadRefusals -= 1;
    return rpcError(res, 403, "FORBIDDEN", "Thread access refused");
  }
  const input = JSON.parse(body || "{}").json ?? {};
  const state = threadState(input);
  const cursor = typeof input.cursor === "number" ? input.cursor : -1;
  if (threadStall === "headers") {
    threadStall = null;
    return; // never answer: the client's connect/read deadline must fire
  }
  res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
  if (threadStall === "body") {
    threadStall = null;
    return; // headers sent, no frames: the stream stays open but silent
  }
  for (const event of state.events) {
    if (event.seq > cursor) {
      res.write(`data: ${JSON.stringify({ json: event })}\n\n`);
    }
  }
  if (!threadClients.has(state.threadId)) threadClients.set(state.threadId, new Set());
  threadClients.get(state.threadId).add(res);
  res.on("close", () => threadClients.get(state.threadId)?.delete(res));
}

// ---- M3 consent state ------------------------------------------------------
// The fake deployment's AI data recipients: two providers (model + memory), neither allowed
// until aiConsent/allow saves the key. /__consentReset restores the unallowed state.
const CONSENT_SCOPE = "fake-consent-scope";
const CONSENT_VERSION = "2026-11-12";
let consentRecipients = [];
function resetConsent() {
  consentRecipients = [
    { key: "model-key", name: "Fake Model Provider", use: "model", detail: "", allowed: false },
    { key: "memory-key", name: "Fake Memory Provider", use: "memory", detail: "", allowed: false },
  ];
}
resetConsent();

// A scripted consent response queue (/__consentScript): each entry answers the next aiConsent
// request in order — {status?, body?, fail?} — so the device replay reproduces the exact transport
// conditions the TS fixture recorded (404, failed allow, …). Empty queue = the live fake state.
let consentScript = [];
let consentScriptIndex = 0;

function handleConsentRpc(req, res, body) {
  const path = req.url;
  if (bearer(req) !== "fake-token") {
    return rpcError(res, 401, "UNAUTHORIZED", "Session expired");
  }
  if (consentScriptIndex < consentScript.length) {
    const spec = consentScript[consentScriptIndex];
    // A fail spec answers every retry of the same request (the kit may retry a dropped
    // connection); only a real answer advances the queue.
    if (!spec.fail) {
      consentScriptIndex += 1;
    }
    if (spec.fail) {
      res.destroy();
      return;
    }
    const answer = () => {
      if (spec.body !== undefined) {
        // Only a successful allow updates the live state; a scripted failure leaves it unallowed.
        if (path === "/rpc/aiConsent/allow" && (spec.status ?? 200) < 300) {
          const input = JSON.parse(body || "{}").json ?? {};
          const keys = Array.isArray(input.keys) ? input.keys : [];
          for (const recipient of consentRecipients) {
            if (keys.includes(recipient.key)) recipient.allowed = true;
          }
        }
        return json(res, spec.status ?? 200, spec.body);
      }
      return rpcError(res, spec.status ?? 500, "INTERNAL", "Server fault");
    };
    if (typeof spec.delayMs === "number" && spec.delayMs > 0) {
      setTimeout(answer, spec.delayMs);
      return;
    }
    return answer();
  }
  const input = JSON.parse(body || "{}").json ?? {};
  if (path === "/rpc/aiConsent/status") {
    const uses = Array.isArray(input.uses) ? input.uses : ["model", "memory"];
    return json(res, 200, {
      json: {
        scope: CONSENT_SCOPE,
        version: CONSENT_VERSION,
        recipients: consentRecipients.filter((r) => uses.includes(r.use)),
        privacyUrl: "https://example.com/privacy",
      },
    });
  }
  if (path === "/rpc/aiConsent/allow") {
    const keys = Array.isArray(input.keys) ? input.keys : [];
    for (const recipient of consentRecipients) {
      if (keys.includes(recipient.key)) recipient.allowed = true;
    }
    return json(res, 200, {
      json: { scope: CONSENT_SCOPE, version: CONSENT_VERSION, recipients: consentRecipients },
    });
  }
  return rpcError(res, 404, "NOT_FOUND", "Not found");
}

function handleThreadRpc(req, res, body) {
  const path = req.url;
  if (bearer(req) !== "fake-token") {
    return rpcError(res, 401, "UNAUTHORIZED", "Session expired");
  }
  const input = JSON.parse(body || "{}").json ?? {};
  const state = threadState(input);
  if (path === "/rpc/threads/get") {
    return json(res, 200, { json: threadSnapshotOf(state) });
  }
  if (path === "/rpc/threads/head") {
    const cursor = state.events.reduce((max, e) => Math.max(max, e.seq), -1);
    return json(res, 200, { json: { threadId: state.threadId, cursor } });
  }
  if (path === "/rpc/threads/messages") {
    // One page of durable history older than `before` (server-shaped: 100 rows + olderCursor).
    const before = typeof input.before === "number" ? input.before : Number.MAX_SAFE_INTEGER;
    return json(res, 200, { json: messagePage(state, before) });
  }
  if (path === "/rpc/threads/send") {
    state.sends += 1;
    const messageId = `${state.threadId}-user-${state.sends}`;
    const seq = nextEventSeq(state);
    const messageSeq = snapshotMessageSeq(state) + 1;
    // A composer send while the viewer's run waits on an ask ANSWERS that run (the real server's
    // answerWaitingRunWithText): the user message is recorded, the card marks answered, and the
    // SAME run resumes — no new run is created.
    const snapshot = threadSnapshotOf(state);
    const waiting = snapshot.run && snapshot.run.status === "waiting_input" ? snapshot.run : null;
    const runId = waiting ? waiting.id : `${state.threadId}-send-${state.sends}`;
    pushThreadEvent(
      state,
      threadEvent(state.threadId, seq + 1, "thread.message.created", {
        runId,
        payload: {
          messageId,
          seq: messageSeq,
          role: "user",
          blocks: [{ kind: "text", text: input.text ?? "" }],
          author: { id: ME.userId, name: ME.name },
        },
      }),
    );
    if (waiting) {
      const asked = durableMessages(state).find(
        (m) =>
          m.runId === waiting.id &&
          (m.blocks ?? []).some((b) => b.kind === "ask" && b.status !== "answered"),
      );
      if (asked) {
        const blocks = asked.blocks.map((b) =>
          b.kind === "ask" ? { ...b, status: "answered", answer: input.text ?? "" } : b,
        );
        pushThreadEvent(
          state,
          threadEvent(state.threadId, seq + 2, "thread.message.updated", {
            runId,
            payload: { messageId: asked.id, seq: asked.seq, role: asked.role, blocks },
          }),
        );
      }
    }
    pushThreadEvent(
      state,
      threadEvent(state.threadId, seq + (waiting ? 3 : 2), "run.started", {
        runId,
        payload: { trigger: waiting ? "resume" : "user", userId: ME.userId },
      }),
    );
    return json(res, 200, { json: { taskId: runId, runId, seq: messageSeq } });
  }
  if (path === "/rpc/threads/answer") {
    const seq = nextEventSeq(state);
    // Keep the answered card's own question/actions; only status+answer change (the real server
    // updates the stored block, it does not replace the card). The run resumes (queued → the
    // worker's run.started); no user message is created — only a composer SEND records one.
    const asked = durableMessages(state).find((m) => m.id === input.messageId);
    const askBlock = (asked?.blocks ?? []).find((b) => b.kind === "ask") ?? {
      kind: "ask",
      text: "Proceed?",
    };
    const blocks = (asked?.blocks ?? [askBlock]).map((b) =>
      b.kind === "ask" ? { ...b, status: "answered", answer: input.answer } : b,
    );
    pushThreadEvent(
      state,
      threadEvent(state.threadId, seq + 1, "thread.message.updated", {
        runId: input.runId,
        payload: {
          messageId: input.messageId,
          seq: asked?.seq,
          role: asked?.role ?? "bot",
          blocks,
        },
      }),
    );
    pushThreadEvent(
      state,
      threadEvent(state.threadId, seq + 2, "run.started", {
        runId: input.runId,
        payload: { trigger: "resume" },
      }),
    );
    return json(res, 200, { json: { ok: true } });
  }
  if (path === "/rpc/threads/stop") {
    const snapshot = threadSnapshotOf(state);
    if (snapshot.run) {
      const seq = nextEventSeq(state);
      pushThreadEvent(
        state,
        threadEvent(state.threadId, seq + 1, "run.cancelled", { runId: snapshot.run.id }),
      );
    }
    return json(res, 200, { json: { ok: true } });
  }
  if (path === "/rpc/threads/markRead") {
    return json(res, 200, { json: { ok: true, unreadAfterSeq: null } });
  }
  return rpcError(res, 404, "NOT_FOUND", "Not found");
}

function snapshotMessageSeq(state) {
  return durableMessages(state).reduce((max, m) => Math.max(max, m.seq ?? 0), 0);
}

/** The next event seq: above every event AND every seeded history row. */
function nextEventSeq(state) {
  return Math.max(
    state.events.reduce((max, e) => Math.max(max, e.seq), 0),
    (state.history ?? []).reduce((max, m) => Math.max(max, m.seq ?? 0), 0),
  );
}

function json(res, status, value, headers = {}) {
  res.writeHead(status, { "content-type": "application/json", ...headers });
  res.end(JSON.stringify(value));
}

function rpcError(res, status, code, message, headers = {}) {
  json(res, status, { json: { code, status, message } }, headers);
}

function bearer(req) {
  const header = req.headers.authorization ?? "";
  return header.startsWith("Bearer ") ? header.slice(7) : "";
}

function handleRpc(req, res, body) {
  const path = req.url;
  const token = bearer(req);
  const space = req.headers["x-rakazo-space-id"] ?? "";
  if (path === "/rpc/health") {
    const mode = req.headers["x-test-health"] ?? "ok";
    if (mode === "bad") return json(res, 200, { json: { ok: false } });
    if (mode === "error") return json(res, 200, { error: { message: "nope" } });
    if (mode === "html") {
      res.writeHead(200, { "content-type": "text/html" });
      return res.end("<html>proxy</html>");
    }
    if (mode === "404") return rpcError(res, 404, "NOT_FOUND", "Not found");
    return json(res, 200, { json: { ok: true, version: "fake-1.0.0" } });
  }
  if (path === "/rpc/me") {
    if (token !== "fake-token") return rpcError(res, 401, "UNAUTHORIZED", "Session expired");
    if (space === "space-stale") return rpcError(res, 401, "UNAUTHORIZED", "Space inaccessible");
    return json(res, 200, { json: ME });
  }
  if (path === "/rpc/spaces/list") {
    if (token !== "fake-token") return rpcError(res, 401, "UNAUTHORIZED", "Session expired");
    if (space === "space-stale") return rpcError(res, 401, "UNAUTHORIZED", "Space inaccessible");
    return json(res, 200, { json: navigation() });
  }
  if (path === "/rpc/models/list") {
    if (token !== "fake-token") return rpcError(res, 401, "UNAUTHORIZED", "Session expired");
    return json(res, 200, { json: MODELS });
  }
  if (path === "/rpc/bots/list") {
    if (token !== "fake-token") return rpcError(res, 401, "UNAUTHORIZED", "Session expired");
    return json(res, 200, { json: activeBots() });
  }
  if (path === "/rpc/bots/listArchived") {
    if (token !== "fake-token") return rpcError(res, 401, "UNAUTHORIZED", "Session expired");
    return json(res, 200, { json: archivedBots() });
  }
  if (path === "/rpc/groups/listArchived") {
    if (token !== "fake-token") return rpcError(res, 401, "UNAUTHORIZED", "Session expired");
    return json(res, 200, { json: archivedGroups() });
  }
  if (path === "/rpc/bots/archive" || path === "/rpc/bots/restore") {
    if (token !== "fake-token") return rpcError(res, 401, "UNAUTHORIZED", "Session expired");
    const input = JSON.parse(body || "{}").json ?? {};
    const bot = bots.find((b) => b.id === input.botId);
    if (!bot) return rpcError(res, 404, "NOT_FOUND", "Bot not found");
    bot.archivedAt = path.endsWith("/archive") ? new Date().toISOString() : null;
    sendSignal("roster");
    return json(res, 200, { json: { ok: true } });
  }
  if (path === "/rpc/groups/archive" || path === "/rpc/groups/restore") {
    if (token !== "fake-token") return rpcError(res, 401, "UNAUTHORIZED", "Session expired");
    const input = JSON.parse(body || "{}").json ?? {};
    const group = groups.find((g) => g.id === input.groupId);
    if (!group) return rpcError(res, 404, "NOT_FOUND", "Group not found");
    group.archivedAt = path.endsWith("/archive") ? new Date().toISOString() : null;
    sendSignal("roster");
    return json(res, 200, { json: { ok: true } });
  }
  if (path === "/rpc/error500")
    return rpcError(res, 500, "INTERNAL", "Server fault", { "retry-after": "2" });
  if (path === "/rpc/update426")
    return rpcError(res, 426, "CLIENT_UPDATE_REQUIRED", "Update required");
  if (path === "/rpc/proxy502") {
    res.writeHead(502, { "content-type": "text/html" });
    return res.end("<html>bad gateway</html>");
  }
  if (path === "/rpc/notjson") {
    res.writeHead(200, { "content-type": "text/html" });
    return res.end("<html>not json</html>");
  }
  if (path === "/rpc/slow") return setTimeout(() => json(res, 200, { json: {} }), 12_000);
  if (path === "/rpc/big") return json(res, 200, { json: { pad: "x".repeat(17 * 1024 * 1024) } });
  if (path === "/rpc/echo") return json(res, 200, { json: JSON.parse(body || "{}").json ?? {} });
  return rpcError(res, 404, "NOT_FOUND", "Not found");
}

function handleAuth(req, res, body) {
  const input = body ? JSON.parse(body) : {};
  const path = req.url;
  if (path === "/api/auth/capabilities" && req.method === "GET") {
    return json(res, 200, {
      passwordAuth: true,
      passwordReset: true,
      resetUrl: "https://example.com/reset",
      emailCode: true,
      sso: null,
    });
  }
  if (req.method !== "POST") return json(res, 405, {});
  if (path === "/api/auth/sign-in/email") {
    if (input.password === "good") {
      // Header wins over the body token; both are present to pin the extraction order.
      return json(res, 200, { token: "body-token" }, { "set-auth-token": "fake-token" });
    }
    if (input.password === "cookie") {
      return json(
        res,
        200,
        {},
        { "set-cookie": "better-auth.session_token=cookie-token; Path=/; HttpOnly" },
      );
    }
    if (input.password === "body") return json(res, 200, { token: "body-token" });
    return json(res, 401, {
      code: "INVALID_LOGIN_CREDENTIALS",
      message: "Invalid email or password",
    });
  }
  if (path === "/api/auth/sign-up/email") {
    if (String(input.email).startsWith("verify")) return json(res, 200, { token: null });
    return json(res, 200, {}, { "set-auth-token": "fake-token" });
  }
  if (path === "/api/auth/email-otp/send-verification-otp") return json(res, 200, {});
  if (path === "/api/auth/sign-in/email-otp") {
    if (input.otp === "123456") return json(res, 200, {}, { "set-auth-token": "fake-token" });
    return json(res, 400, { code: "INVALID_OTP", message: "Invalid code" });
  }
  if (path === "/api/auth/sign-out") {
    const token = bearer(req);
    signOuts.push(token);
    console.log(`sign-out token=${token}`);
    if (token === "retry-token") return json(res, 500, {});
    if (token === "gone-token") return json(res, 401, {});
    return json(res, 200, {});
  }
  return json(res, 404, {});
}

function handleSse(req, res) {
  if (req.headers.accept !== "text/event-stream") {
    res.writeHead(400).end();
    return;
  }
  res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
  if (req.url === "/sse-cut") {
    res.write('data: {"json":{"type":"cut"}}\n');
    setTimeout(() => res.destroy(), 300);
    return;
  }
  if (req.url === "/sse-idle") {
    // One frame, then silence: the client's 45s idle rule must end the stream.
    res.write('data: {"json":{"type":"probe","seq":1}}\n\n');
    return;
  }
  res.write('data: {"json":{"type":"probe","seq":1}}\n\n');
  setTimeout(() => {
    res.write(splitFrame.subarray(0, cut));
    setTimeout(() => {
      res.write(splitFrame.subarray(cut));
      res.write('data: {"json":{"type":"heartbeat"}}\n\n');
      setTimeout(() => {
        res.write('data: {"json":{"type":"done"}}\n\n');
        res.end();
      }, 300);
    }, 200);
  }, 200);
}

// notifications/subscribe: the roster signal stream. Opens with each signal once (reconnect
// catches up), then stays open; /__signal pushes a frame so a test can drive a re-read on demand.
function handleNotifications(req, res) {
  res.setHeader("connection", "close");
  if (req.headers.accept !== "text/event-stream") {
    res.writeHead(400).end();
    return;
  }
  if (bearer(req) !== "fake-token") {
    return rpcError(res, 401, "UNAUTHORIZED", "Session expired");
  }
  res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
  for (const type of [
    "roster",
    "computerUpdates",
    "runs",
    "routines",
    "meetings",
    "artifacts",
    "meetingCalendar",
    "organizations",
  ]) {
    res.write(`data: ${JSON.stringify({ json: { type } })}\n\n`);
  }
  notificationClients.add(res);
  // res 'close' is the connection ending; req 'close' fires once the POST body is consumed,
  // which would drop a still-open SSE client before any injected signal could reach it.
  res.on("close", () => notificationClients.delete(res));
}

createServer((req, res) => {
  let body = "";
  req.on("data", (chunk) => {
    body += chunk;
  });
  req.on("end", () => {
    console.log(`${req.method} ${req.url}`);
    if (req.url.startsWith("/rpc/threads/")) {
      res.on("close", () => console.log(`CLOSE ${req.url} writable=${res.writableEnded}`));
    }
    const clientBuild = req.headers["x-rakazo-client-build"];
    if (clientBuild) clientBuilds.push(clientBuild);
    if (req.url.startsWith("/rpc/")) {
      seq += 1;
      requests.push({ seq, path: req.url, body, t: Date.now() });
    }
    if (req.url === "/__state") {
      return json(res, 200, { signOuts, clientBuilds, streams: notificationClients.size });
    }
    if (req.url === "/__requests") {
      return json(res, 200, { requests, seq });
    }
    if (req.url === "/__signal") {
      const input = body ? JSON.parse(body) : {};
      sendSignal(input.type || "roster");
      return json(res, 200, { ok: true });
    }
    if (req.url === "/__mutate") {
      // Simulate another device's chat activity WITHOUT a signal: the client must not notice
      // until a signal (or foreground) tells it to re-read.
      const input = body ? JSON.parse(body) : {};
      const bot = bots.find((b) => b.id === input.botId);
      if (bot) {
        if (typeof input.preview === "string") bot.preview = input.preview;
        if (typeof input.unread === "boolean") bot.unread = input.unread;
        if (typeof input.status === "string") bot.status = input.status;
      }
      return json(res, 200, { ok: true });
    }
    if (req.url === "/__models") {
      // Move the account default / catalog so the settings model row can be driven to either
      // branch: {defaultProvider?, defaultModel?, catalog?: [...]}.
      const input = body ? JSON.parse(body) : {};
      if ("defaultProvider" in input) ME.defaultProvider = input.defaultProvider;
      if ("defaultModel" in input) ME.defaultModel = input.defaultModel;
      if (Array.isArray(input.catalog)) MODELS = input.catalog;
      return json(res, 200, { ok: true });
    }
    if (req.url === "/__offline") {
      const input = body ? JSON.parse(body) : {};
      offline = input.on === true;
      return json(res, 200, { ok: true, offline });
    }
    if (req.url === "/__threadEvent") {
      // Inject one thread event (another device's activity): {botId|groupId, type, runId?, payload?}.
      const input = body ? JSON.parse(body) : {};
      const state = threadState(input);
      const nextSeq = nextEventSeq(state) + 1;
      const event = threadEvent(state.threadId, nextSeq, input.type || "thread.progress", {
        ...(input.runId ? { runId: input.runId } : {}),
        ...(input.botId && input.groupId ? { botId: input.botId } : {}),
        payload: input.payload ?? {},
      });
      pushThreadEvent(state, event);
      return json(res, 200, { ok: true, seq: nextSeq });
    }
    if (req.url === "/__threadSeed") {
      // Seed a long thread: {botId, count, tail?: [{type, runId?, payload?}]}. The recent page
      // stays server-shaped (100 messages); older history pages come from threads/messages.
      const input = body ? JSON.parse(body) : {};
      const botId = input.botId || "bot-1";
      const count = Math.max(0, Math.min(20_000, Number(input.count) || 0));
      const state = seedThread(
        `thread-${botId}`,
        botId,
        count,
        Array.isArray(input.tail) ? input.tail : [],
      );
      if (!bots.some((b) => b.id === botId)) {
        bots.push(makeBot(botId, input.name || `Seeded ${botId}`));
        sendSignal("roster");
      }
      return json(res, 200, { ok: true, threadId: state.threadId, count });
    }
    if (req.url === "/__inboxSeed") {
      // Bulk-inbox load for the M4 long-list measurement: {count} bots with staggered times,
      // rotating previews and every 7th unread — one roster signal at the end (not per row).
      const input = body ? JSON.parse(body) : {};
      const count = Math.max(0, Math.min(5000, Number(input.count) || 0));
      const now = Date.now();
      for (let i = 0; i < count; i++) {
        const id = `seed-${i}`;
        if (!bots.some((b) => b.id === id)) {
          bots.push(
            makeBot(id, `Load ${i + 1}`, {
              updatedAt: new Date(now - i * 61_000).toISOString(),
              preview: `Preview line ${i + 1}`,
              unread: i % 7 === 0,
            }),
          );
        }
      }
      sendSignal("roster");
      return json(res, 200, { ok: true, added: count, total: bots.length });
    }
    if (req.url === "/__threadCut") {
      // End every open stream for a thread without an HTTP answer (a deploy closing connections).
      const input = body ? JSON.parse(body) : {};
      const state = threadState(input);
      for (const res of threadClients.get(state.threadId) ?? []) {
        res.destroy();
      }
      return json(res, 200, { ok: true });
    }
    if (req.url === "/__threadRefuse") {
      // The next N threads/subscribe attempts answer 403 (a non-retryable refusal).
      const input = body ? JSON.parse(body) : {};
      threadRefusals = typeof input.count === "number" ? input.count : 1;
      return json(res, 200, { ok: true });
    }
    if (req.url === "/__threadStall") {
      // Hold the next threads/subscribe open without answering (headers or body), so the
      // client's request deadline fires. mode: "headers" (default) or "body".
      const input = body ? JSON.parse(body) : {};
      threadStall = input.mode === "body" ? "body" : "headers";
      return json(res, 200, { ok: true });
    }
    if (req.url === "/__threadReset") {
      THREAD_SCRIPTS.clear();
      return json(res, 200, { ok: true });
    }
    if (req.url === "/__reset") {
      signOuts.length = 0;
      clientBuilds.length = 0;
      requests.length = 0;
      seq = 0;
      offline = false;
      resetRoster();
      THREAD_SCRIPTS.clear();
      threadRefusals = 0;
      threadStall = null;
      resetModels();
      resetConsent();
      consentScript = [];
      consentScriptIndex = 0;
      return json(res, 200, {});
    }
    if (offline && OFFLINE_READS.has(req.url)) {
      res.destroy();
      return;
    }
    if (req.url === "/__consentReset") {
      resetConsent();
      consentScript = [];
      consentScriptIndex = 0;
      return json(res, 200, { ok: true });
    }
    if (req.url === "/__consentScript") {
      const input = body ? JSON.parse(body) : {};
      consentScript = Array.isArray(input.responses) ? input.responses : [];
      consentScriptIndex = 0;
      return json(res, 200, { ok: true, count: consentScript.length });
    }
    if (req.url === "/rpc/notifications/subscribe") return handleNotifications(req, res);
    if (req.url.startsWith("/rpc/aiConsent/")) return handleConsentRpc(req, res, body);
    if (req.url === "/rpc/threads/subscribe") return handleThreadSubscribe(req, res, body);
    if (req.url.startsWith("/rpc/threads/")) return handleThreadRpc(req, res, body);
    if (req.url.startsWith("/rpc/")) return handleRpc(req, res, body);
    if (req.url.startsWith("/api/auth/")) return handleAuth(req, res, body);
    if (req.url.startsWith("/sse")) {
      if (req.method !== "POST") {
        res.writeHead(405).end();
        return;
      }
      return handleSse(req, res);
    }
    res.writeHead(404).end();
  });
}).listen(port, () => console.log(`fixture server on :${port}`));
