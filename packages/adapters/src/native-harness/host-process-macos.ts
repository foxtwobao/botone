import type { ChildProcessWithoutNullStreams } from "node:child_process";
import { execFile, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { realpath, stat } from "node:fs/promises";
import { createRequire } from "node:module";
import type { Readable, Writable } from "node:stream";
import type { NativeProcessTree } from "../desktop-process-tree.js";

export interface HostProcessMarker {
  allow: string;
  deny: string;
}

/** No files are created. The probe paths have an immutable, system-owned ancestor. */
export async function createHostProcessMarker(): Promise<HostProcessMarker> {
  const root = "/System/Library";
  const info = await stat(root);
  if ((await realpath(root)) !== root || info.uid !== 0 || (info.mode & 0o022) !== 0)
    throw new Error("host_process_marker_unavailable");
  const prefix = `${root}/rakazo-run-${randomUUID()}`;
  return { allow: `${prefix}-allow`, deny: `${prefix}-deny` };
}

// This is a separate Node process, outside the CLI's sandbox. The existing native FFI
// dependency is also shipped outside asar. No compiler, Python, service, or root is needed.
// libproc/sandbox SPI is capability-probed; unsupported OS versions fail admission.
export const MACOS_HOST_OWNER = String.raw`
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const koffi = require(process.argv[1]);
const system = koffi.load('/usr/lib/libproc.dylib');
const sandbox = koffi.load('/usr/lib/libsandbox.dylib');
const list = system.func('int proc_listpids(uint32_t, uint32_t, void *, int)');
const info = system.func('int proc_pidinfo(int, int, uint64_t, void *, int)');
const signal = system.func('int proc_signal_with_audittoken(void *, int)');
const check = sandbox.func('int sandbox_check(int, const char *, int, ...)');
const noReport = koffi.decode(sandbox.symbol('SANDBOX_CHECK_NO_REPORT'), 'int');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
function identity(pid) {
  const data = Buffer.alloc(56); // proc_uniqidentifierinfo, PROC_PIDUNIQIDENTIFIERINFO
  if (info(pid, 17, 0, data, data.length) !== data.length) return;
  const token = Buffer.alloc(32); // audit_token_t; kernel checks PID and pidversion.
  token.writeUInt32LE(pid, 20);
  token.writeUInt32LE(data.readUInt32LE(32), 28);
  return { pid, unique: data.readBigUInt64LE(16), parent: data.readBigUInt64LE(24), token };
}
function zombie(pid) {
  // proc_listpids includes zombies owned by unrelated parents; they cannot fork.
  const state = Buffer.alloc(64); // proc_bsdshortinfo, PROC_PIDT_SHORTBSDINFO
  return info(pid, 13, 1, state, state.length) === state.length && state.readUInt32LE(12) === 5;
}
function allowed(pid, path) {
  const result = check(pid, 'file-read-data', 1 | noReport, 'str', path);
  if (result < 0) throw new Error('host_process_label_unavailable');
  return result === 0;
}
function matches(pid, marker) {
  return allowed(pid, marker.allow) && !allowed(pid, marker.deny);
}
function enumerate() {
  // PROC_UID_ONLY: never inspect other users' sandboxes. Retry if the list grew.
  for (;;) {
    const length = list(4, process.getuid(), null, 0);
    if (length <= 0) throw new Error('host_process_list_unavailable');
    const data = Buffer.alloc(length + 4096);
    const size = list(4, process.getuid(), data, data.length);
    if (size <= 0) throw new Error('host_process_list_unavailable');
    if (size === data.length) continue;
    return Array.from({ length: Math.floor(size / 4) }, (_, index) => data.readInt32LE(index * 4))
      .filter(pid => pid > 0 && pid !== process.pid);
  }
}
function send(target, signum) {
  const result = signal(target.token, signum);
  // libproc returns errno, not -1. ESRCH includes an exited/reused/exec'd identity.
  if (result !== 0 && result !== 3) throw new Error('host_process_signal_unavailable');
  return result === 0;
}
async function cleanup(root, marker) {
  // Stop the root first. Its unique ID survives exec; pidversion prevents signalling
  // a different exec image between reading its identity and the native signal call.
  const current = root && identity(root.pid);
  if (current && current.unique === root.unique) { send(current, 17); send(current, 9); }
  const deadline = Date.now() + 10000;
  const family = new Set(root ? [root.unique] : []);
  let empty;
  while (Date.now() < deadline) {
    const owned = [];
    const pids = enumerate();
    const identities = [];
    let stable = true;
    for (const pid of pids) {
      const target = identity(pid);
      if (target) identities.push(target);
      else if (!zombie(pid)) stable = false;
    }
    // Native CLI helpers need not enter a tool sandbox. Original-parent unique IDs
    // identify those helpers even after the CLI exits and launchd reparents them.
    // Detached tool chains use the inherited sandbox label, not this ancestry scan.
    let changed;
    do {
      changed = false;
      for (const target of identities) {
        if (family.has(target.parent) && !family.has(target.unique)) {
          family.add(target.unique); changed = true;
        }
      }
    } while (changed);
    for (const before of identities) {
      const pid = before.pid;
      let match;
      try { match = family.has(before.unique) || matches(pid, marker); }
      catch (error) { if (!identity(pid)) { stable = false; continue; } throw error; }
      if (!match) continue;
      const after = identity(pid);
      if (!after || !after.token.equals(before.token)) { stable = false; continue; }
      if (!send(after, 17)) stable = false; // freeze before killing so the matching population cannot grow.
      owned.push(after);
    }
    for (const target of owned) send(target, 9);
    // A parent may fork then exit after proc_listpids took its snapshot. Never
    // confirm cleanup from that one empty scan; require a second complete scan
    // with the same stable process identities and no matching process remaining.
    const snapshot = identities.map(target => target.unique.toString() + ':' + target.token.readUInt32LE(28)).sort().join(',');
    if (stable && owned.length === 0) {
      if (empty === snapshot) return;
      empty = snapshot;
    } else empty = undefined;
    await pause(20);
  }
  throw new Error('host_stop_unconfirmed');
}
function profile(marker) {
  return '(version 1)(allow default)(deny file-read* (literal ' + JSON.stringify(marker.deny) + '))';
}
async function probe() {
  const marker = { allow: '/System/Library/rakazo-probe-' + process.pid + '-allow', deny: '/System/Library/rakazo-probe-' + process.pid + '-deny' };
  const child = spawn('/usr/bin/sandbox-exec', ['-p', profile(marker), '/bin/sleep', '5'], { stdio: 'ignore' });
  const closed = new Promise(resolve => child.once('close', resolve));
  let root;
  try {
    for (let attempt = 0; attempt < 50; attempt++) {
      root = identity(child.pid);
      if (root && matches(child.pid, marker)) break;
      await pause(10);
    }
    if (!root || !matches(child.pid, marker) || matches(process.pid, marker)) throw new Error('host_process_label_unavailable');
    send(root, 17); send(root, 9);
    await closed;
    await cleanup(root, marker);
  } finally { child.kill('SIGKILL'); }
}
async function main() {
  if (process.argv[2] === 'probe') { await probe(); return; }
  const control = fs.createReadStream(null, { fd: 3, autoClose: false });
  let config = '', launched = false, stopping = false, root, marker, child, code = 0, unavailableRoot = false;
  let attempt;
  const stop = () => {
    stopping = true;
    if (!launched) {
      fs.writeSync(4, 'clean\n'); fs.closeSync(4); process.exit(0);
    }
    if (attempt) return;
    attempt = (async () => {
      // Keep owning after a failed bounded attempt; the desktop can retry Stop/Quit.
      for (;;) {
        try {
          if (unavailableRoot && child.exitCode === null && child.signalCode === null) throw new Error('host_root_identity_unavailable');
          await cleanup(root, marker); break;
        }
        catch { await pause(100); }
      }
      fs.writeSync(4, 'clean\n');
      fs.closeSync(4);
      process.exit(code);
    })();
  };
  control.on('end', stop); control.on('error', stop);
  for (const name of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(name, stop);
  control.on('data', data => {
    if (launched || stopping) return;
    config += data;
    if (config.length > 1024 * 1024) process.exit(1);
    const newline = config.indexOf('\n');
    if (newline < 0) return;
    const value = JSON.parse(config.slice(0, newline));
    marker = value.marker;
    const argv = value.sandboxRoot
      ? ['/usr/bin/sandbox-exec', '-p', profile(marker), ...value.argv] : value.argv;
    child = spawn(argv[0], argv.slice(1), { cwd: value.cwd, env: value.env, stdio: ['pipe', 1, 2] });
    launched = true;
    child.once('error', () => { code = 1; stop(); });
    child.once('exit', status => { code = status === null ? 1 : status; stop(); });
    child.stdin.on('error', stop);
    root = child.pid && identity(child.pid);
    if (child.pid && !root) {
      unavailableRoot = true; code = 1; child.stdin.end(); stop();
    } else process.stdin.pipe(child.stdin);
    if (stopping) stop();
  });
}
main().catch(() => process.exit(1));
`;

const modulePath = () => createRequire(import.meta.url).resolve("koffi");

export async function macosHostOwnershipAvailable() {
  try {
    await createHostProcessMarker();
    return await new Promise<boolean>((resolve) => {
      execFile(
        process.execPath,
        ["-e", MACOS_HOST_OWNER, modulePath(), "probe"],
        { env: { ELECTRON_RUN_AS_NODE: "1" }, timeout: 3000, maxBuffer: 1024 },
        (error) => resolve(!error),
      );
    });
  } catch {
    return false;
  }
}

export async function spawnMacosHostCommand(
  argv: string[],
  cwd: string,
  env: NodeJS.ProcessEnv,
  marker?: HostProcessMarker,
): Promise<{ child: ChildProcessWithoutNullStreams; tree: NativeProcessTree }> {
  const actualMarker = marker ?? (await createHostProcessMarker());
  const child = spawn(process.execPath, ["-e", MACOS_HOST_OWNER, modulePath()], {
    cwd,
    env: { ELECTRON_RUN_AS_NODE: "1" },
    shell: false,
    stdio: ["pipe", "pipe", "pipe", "pipe", "pipe"],
  });
  const control = child.stdio[3] as Writable;
  const status = child.stdio[4] as Readable;
  let clean = false;
  let acknowledgement = "";
  child.once("error", () => {
    if (!child.pid) clean = true;
  });
  status.setEncoding("utf8");
  status.on("data", (chunk: string) => {
    acknowledgement += chunk;
    clean = acknowledgement === "clean\n";
  });
  control.on("error", () => {});
  status.on("error", () => {});
  control.write(
    `${JSON.stringify({ argv, cwd, env, marker: actualMarker, sandboxRoot: !marker })}\n`,
  );
  return {
    child: child as ChildProcessWithoutNullStreams,
    tree: {
      alive: () => !clean,
      kill: () => control.end(),
      close() {
        if (clean) {
          control.destroy();
          status.destroy();
        }
      },
    },
  };
}
