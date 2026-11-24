// Repeatable long-thread memory sampling (design §9 R4; the M4 verification blocker: the 10k
// traversal's PSS claim had no re-runnable recipe). Drives the installed app through the seeded
// 10k-message thread page by page to the very first message, sampling PSS around every page,
// then jumps back to the latest page and samples again. Prints one CSV row per sample and a
// summary; exit 0 only when every step verified.
//
//   node apps/harmony/scripts/perf-sample.mjs                 # 10k thread, page-by-page
//   PERF_COUNT=500 node apps/harmony/scripts/perf-sample.mjs  # smaller seed
//
// Preconditions: the fixture server on port 8787 (scripts/spike-sse-server.mjs), a connected
// emulator (hdc list targets), devecocli on PATH, the app installed and debug-signed. The app
// follows the system language; every assertion accepts the zh-CN, zh-TW and en strings of the
// same msgid. PSS comes from `SP_daemon -r -PID <pid> -print` (raw kB, the M4 method).
import { execFileSync } from "node:child_process";
import process from "node:process";

const PORT = process.env.PERF_PORT ?? "8787";
const COUNT = Number(process.env.PERF_COUNT ?? 10_000);
const EMAIL = "ada@example.com";
const PASSWORD = "good";
const PAGE = 100; // the fixture's THREAD_PAGE_SIZE

const run = (file, args, opts = {}) =>
  execFileSync(file, args, {
    encoding: "utf8",
    timeout: 60_000,
    stdio: ["ignore", "pipe", "pipe"],
    ...opts,
  });
const sh = (cmd) => run("/bin/sh", ["-c", cmd]);
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

const findNode = (...variants) =>
  dumpNodes().find((entry) => variants.some((v) => entry.id === v || entry.text.includes(v))) ??
  null;

function waitFor(label, variants, timeoutMs = 15_000) {
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
  sh(`hdc shell "uitest uiInput text '${text}'"`);
  sleep(300);
}

function fixture(path, body) {
  const payload = body === undefined ? "" : ` -d '${JSON.stringify(body)}'`;
  return sh(`curl -s -X POST http://127.0.0.1:${PORT}${path}${payload}`);
}

function appPid() {
  const pid = sh("hdc shell pidof com.botone.app").trim();
  if (!/^\d+$/.test(pid)) throw new Error(`no app pid (${pid})`);
  return pid;
}

/** One PSS sample in kB (SmartPerf raw value; the M4 calibration's unit). The field list has
 * several *HeapPss=… entries — only the bare `pss=` is the process total. */
function pssKb(pid) {
  const out = sh(`hdc shell "SP_daemon -r -PID ${pid} -N 1 -print"`);
  const match = out.match(/\bpss=(\d+)/i);
  if (!match) throw new Error(`no pss in SP_daemon output: ${out.slice(0, 200)}`);
  return Number(match[1]);
}

const samples = [];
function sample(pid, label) {
  const kb = pssKb(pid);
  samples.push({ label, kb });
  console.log(`${label},${kb}`);
  return kb;
}

function launch() {
  sh("hdc shell 'aa force-stop com.botone.app' ; sleep 1");
  sh("hdc shell 'aa start -a EntryAbility -b com.botone.app' >/dev/null");
  sleep(5000);
}

/** The oldest `history N` text currently painted (the transcript's floor). */
function oldestHistoryOnScreen() {
  let oldest = null;
  for (const entry of dumpNodes()) {
    const match = entry.text.match(/^history (\d+)$/);
    if (match) {
      const seq = Number(match[1]);
      if (oldest === null || seq < oldest) oldest = seq;
    }
  }
  return oldest;
}

try {
  console.log(`# perf-sample: count=${COUNT} port=${PORT}`);
  console.log("label,pss_kb");
  fixture("/__reset");
  fixture("/__threadSeed", { botId: "bot-1", count: COUNT });
  launch();

  // A leftover session would land on the inbox; sign out first so every pass starts clean.
  if (findNode("聊天", "Chats")) {
    tap(1168, 234);
    tapText("退出登录", "Sign out");
    waitFor("sign-in", ["欢迎回来", "Welcome back"]);
  }
  typeAt(300, 1250, EMAIL);
  typeAt(300, 1560, PASSWORD);
  sh('hdc shell "uitest uiInput keyEvent Back"');
  sleep(500);
  const submit = dumpNodes()
    .filter((e) => e.text === "登录" || e.text === "Sign in" || e.text === "登入")
    .sort((a, b) => a.bounds[1] - b.bounds[1])
    .pop();
  if (!submit) throw new Error("no submit button");
  tap(...center(submit.bounds));
  waitFor("inbox", ["聊天", "Chats"]);

  tapText("Alpha");
  waitFor("composer", ["thread-send"]);
  sleep(1500); // settle: the recent page painted, stream open
  const pid = appPid();
  const openKb = sample(pid, "open");

  // Page back to the very first message through the paging entry (the verifier's route: the
  // tap, not flings — flings stop wherever the window lands). The list's own onReachStart may
  // land extra pages behind a tap, so progress is measured as "the loaded floor moved older",
  // read BEFORE the tap; the window keeps the oldest 1,000, so PSS must plateau.
  let pages = 0;
  const expectedPages = Math.ceil(COUNT / PAGE) - 1;
  for (;;) {
    const load = findNode("加载更早的消息", "載入更早的訊息", "Load earlier messages");
    if (!load) break; // the first message is painted; no older page exists
    const floorBefore = oldestHistoryOnScreen();
    tap(...center(load.bounds));
    pages += 1;
    const deadline = Date.now() + 15_000;
    for (;;) {
      const floor = oldestHistoryOnScreen();
      const entryGone = !findNode("加载更早的消息", "載入更早的訊息", "Load earlier messages");
      const movedOlder = floor !== null && floorBefore !== null && floor < floorBefore;
      if (movedOlder || (entryGone && floor !== null && floor <= PAGE)) break;
      if (Date.now() > deadline) {
        // The entry's cached bounds can sit offscreen while the list rests at the bottom:
        // one fling toward the top reaches it, and onReachStart loads the page itself.
        sh('hdc shell "uitest uiInput fling 640 900 640 1900 1200"');
        sleep(1500);
        const after = oldestHistoryOnScreen();
        if (after !== null && floorBefore !== null && after < floorBefore) break;
        throw new Error(`page ${pages} did not land (floor ${after}, before ${floorBefore})`);
      }
      sleep(300);
    }
    if (pages % 10 === 0) sample(pid, `page_${pages}`);
    if (pages > expectedPages + 2) throw new Error("paging did not terminate");
  }
  const floor = oldestHistoryOnScreen();
  if (floor !== 1) throw new Error(`traversal ended at history ${floor}, not history 1`);
  sleep(1500);
  const endKb = sample(pid, `end_history_1_pages_${pages}`);

  // Back to the live page: the window's jump affordance (eviction happened on the newest side).
  tapText("跳到最新", "Jump to latest");
  waitFor("latest page", [`history ${COUNT}`]);
  sleep(1500);
  const jumpKb = sample(pid, "jump_to_latest");

  const growthPct = (((endKb - openKb) / openKb) * 100).toFixed(1);
  console.log(
    `# pages=${pages} open=${openKb}kB end=${endKb}kB growth=${growthPct}% jump=${jumpKb}kB`,
  );
  console.log("PERF SAMPLE PASS");
} catch (err) {
  console.error(`PERF SAMPLE FAIL: ${err.message}`);
  process.exit(1);
}
