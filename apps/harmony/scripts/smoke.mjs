// Emulator smoke (design §7.2 M4): one scripted pass over the whole Phase-1 flow with
// loud-failure verification at every step — launch, server page, sign-in, inbox, open chat,
// send (through the AI-consent gate), receive an injected reply, settings, sign-out. Run it
// twice back to back on an unchanged build to prove repeatability:
//
//   node apps/harmony/scripts/smoke.mjs            # one pass
//   node apps/harmony/scripts/smoke.mjs && node apps/harmony/scripts/smoke.mjs
//
// Preconditions: the fixture server on port 8787 (scripts/spike-sse-server.mjs), a connected
// emulator (hdc list targets), devecocli on PATH, and the app installed. The app follows the
// system language, so every assertion accepts the zh-CN and en strings of the same msgid.
import { execFileSync } from "node:child_process";
import process from "node:process";

const PORT = process.env.SMOKE_PORT ?? "8787";
const EMAIL = "ada@example.com";
const PASSWORD = "good";
const MESSAGE = "smoke hello";
const REPLY = "smoke reply";

const run = (file, args, opts = {}) =>
  execFileSync(file, args, {
    encoding: "utf8",
    timeout: 30_000,
    stdio: ["ignore", "pipe", "pipe"],
    ...opts,
  });
const sh = (cmd) => run("/bin/sh", ["-c", cmd]);

let failed = "";
const step = (name, fn) => {
  try {
    fn();
    console.log(`ok   ${name}`);
  } catch (err) {
    failed = name;
    throw err;
  }
};
const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

function dumpNodes() {
  let raw = "";
  try {
    raw = sh("devecocli ui layout --format json 2>/dev/null");
  } catch {
    return [];
  }
  const start = raw.indexOf("[");
  if (start < 0) return [];
  let parsed;
  try {
    parsed = JSON.parse(raw.slice(start));
  } catch {
    return [];
  }
  const out = [];
  const walk = (node) => {
    if (Array.isArray(node)) {
      for (const child of node) walk(child);
      return;
    }
    const text = typeof node.text === "string" ? node.text : "";
    if (text || node.id) out.push({ text, id: node.id, bounds: node.bounds ?? [] });
    for (const child of node.children ?? []) walk(child);
  };
  walk(parsed);
  return out;
}

/** A node matching any given id or text fragment. */
function findNode(...variants) {
  return (
    dumpNodes().find((entry) => variants.some((v) => entry.id === v || entry.text.includes(v))) ??
    null
  );
}

function waitFor(label, variants, timeoutMs = 12_000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const hit = findNode(...variants);
    if (hit) return hit;
    if (Date.now() > deadline) {
      const seen = dumpNodes()
        .map((e) => e.text)
        .join(" | ");
      throw new Error(`waitFor(${label}) timed out; screen: ${seen.slice(0, 400)}`);
    }
    sleep(400);
  }
}

const center = (bounds) => {
  const [x1, y1, x2, y2] = bounds;
  return [Math.round((x1 + x2) / 2), Math.round((y1 + y2) / 2)];
};

function tap(x, y) {
  sh(`hdc shell "uitest uiInput click ${x} ${y}"`);
  sleep(600);
}

function tapText(...variants) {
  const hit = waitFor(variants[0], variants);
  const [x, y] = center(hit.bounds);
  tap(x, y);
  return hit;
}

function typeAt(x, y, text) {
  tap(x, y);
  // devecocli ui text cuts at the first space; uitest keeps the whole string.
  sh(`hdc shell "uitest uiInput text '${text}'"`);
  sleep(300);
}

function fixture(path, body) {
  const payload = body === undefined ? "" : ` -d '${JSON.stringify(body)}'`;
  sh(`curl -s -X POST http://127.0.0.1:${PORT}${path}${payload}`);
}

function launch() {
  sh("hdc shell 'aa force-stop com.botone.app' ; sleep 1");
  sh("hdc shell 'aa start -a EntryAbility -b com.botone.app' >/dev/null");
  sleep(5000);
}

try {
  step("fixture reset", () => fixture("/__reset"));
  step("launch", launch);

  // A leftover session would land on the inbox; sign out first so every pass starts clean.
  step("clean session if present", () => {
    if (findNode("聊天", "Chats")) {
      tap(1168, 234); // the account avatar opens settings
      tapText("退出登录", "Sign out");
      waitFor("sign-in", ["欢迎回来", "Welcome back"]);
    }
  });

  step("server page", () => {
    tapText("更换服务器", "Change server");
    waitFor("server page", ["使用默认服务器", "Use default server"]);
    sh('hdc shell "uitest uiInput keyEvent Back"');
    sleep(800);
  });

  step("sign in", () => {
    const inputs = dumpNodes().length; // screen settled
    if (inputs < 0) throw new Error("unreachable");
    typeAt(300, 1250, EMAIL);
    typeAt(300, 1560, PASSWORD);
    sh('hdc shell "uitest uiInput keyEvent Back"');
    sleep(500);
    // The form's submit button (not the 登录 tab): the lowest matching text on screen.
    const submit = dumpNodes()
      .filter((e) => e.text === "登录" || e.text === "Sign in")
      .sort((a, b) => a.bounds[1] - b.bounds[1])
      .pop();
    if (!submit) throw new Error("no submit button");
    const [x, y] = center(submit.bounds);
    tap(x, y);
    waitFor("inbox", ["聊天", "Chats"]);
  });

  step("open chat", () => {
    tapText("Alpha");
    waitFor("composer", ["thread-send"]);
  });

  step("send through the consent gate", () => {
    typeAt(640, 2600, MESSAGE);
    // Fold the keyboard first: while it is open the transcript's rows are not in the layout
    // tree, so the echo cannot be verified, and the send button sits at a moving position.
    sh('hdc shell "uitest uiInput keyEvent Back"');
    sleep(800);
    const { bounds } = waitFor("send button", ["thread-send"]);
    const [left, top, right, bottom] = bounds;
    const width = right - left;
    const height = bottom - top;
    if (!(height > 0 && Math.abs(width - height) <= 1)) {
      throw new Error(`send button is not square (${width} × ${height})`);
    }
    tap(...center(bounds));
    // First send in a fresh Space trips AI_CONSENT_REQUIRED; allow it and the send continues.
    // The dialog follows the failed RPC, so poll briefly for it (absent = consent already given).
    const deadline = Date.now() + 5000;
    let consent = null;
    while (Date.now() < deadline && !consent) {
      consent = findNode("允许", "Allow");
      if (!consent) sleep(300);
    }
    if (consent) {
      // The sheet swallows clicks during its opening takeover: tap, verify it took, retry.
      for (let attempt = 0; attempt < 6; attempt++) {
        const button = findNode("允许", "Allow");
        if (!button) break;
        const [x, y] = center(button.bounds);
        tap(x, y);
        sleep(1000);
      }
      if (findNode("暂不", "Not now")) throw new Error("consent dialog did not close");
    }
    waitFor("sent echo", [MESSAGE]);
  });

  step("receive the injected reply", () => {
    fixture("/__threadEvent", {
      botId: "bot-1",
      type: "thread.message.created",
      runId: "smoke-run",
      payload: {
        messageId: "smoke-reply",
        role: "bot",
        blocks: [{ kind: "text", text: REPLY }],
      },
    });
    // Close the run the fixture opened for the send, so the composer returns to idle.
    fixture("/__threadEvent", { botId: "bot-1", type: "run.completed", runId: "smoke-run" });
    waitFor("reply bubble", [REPLY], 15_000);
  });

  step("settings", () => {
    sh('hdc shell "uitest uiInput keyEvent Back"');
    sleep(1200);
    tap(1168, 234); // the account avatar opens settings
    waitFor("settings", ["退出登录", "Sign out"]);
    const model = findNode("Fake Fast Model");
    if (!model) throw new Error("model row missing its server label");
  });

  step("sign out", () => {
    tapText("退出登录", "Sign out");
    waitFor("sign-in", ["欢迎回来", "Welcome back"]);
  });

  console.log("SMOKE PASS");
} catch (err) {
  console.error(`SMOKE FAIL at [${failed}]: ${err.message}`);
  process.exit(1);
}
