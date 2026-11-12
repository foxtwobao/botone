// Runs as namespace init. The agent runs as the computer's ordinary user, with no control fds.
import { spawn, spawnSync } from "node:child_process";
import { closeSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { Socket } from "node:net";

const configuration = JSON.parse(readFileSync(3, "utf8"));
closeSync(3);
const mount = (args) => {
  const result = spawnSync("/usr/bin/mount", args, { stdio: "ignore" });
  if (result.status !== 0) throw new Error("computer_mount_failed");
};
mkdirSync("/run/harness", { recursive: true });
mount(["-t", "tmpfs", "-o", "mode=755", "tmpfs", "/run/harness"]);
mkdirSync("/run/harness/broker");
mount(["--bind", configuration.broker, "/run/harness/broker"]);
writeFileSync("/run/harness/permission-proxy.mjs", configuration.proxy, { mode: 0o444 });
mkdirSync("/workspace", { recursive: true });
mount(["--bind", configuration.workspace, "/workspace"]);
const child = spawn(
  "/usr/bin/setpriv",
  [
    `--reuid=${configuration.uid}`,
    `--regid=${configuration.gid}`,
    "--clear-groups",
    "--no-new-privs",
    "--bounding-set=-all",
    "--",
    ...configuration.command,
  ],
  { cwd: "/workspace", env: configuration.env, stdio: ["pipe", "inherit", "ignore"] },
);
const input = new Socket({ fd: 5, readable: true, writable: false });
input.pipe(child.stdin);
child.stdin.on("error", () => {});
// Closing namespace init terminates every descendant, including detached tools and PTYs.
for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) process.on(signal, () => process.exit(0));
input.on("end", () => process.exit(0));
child.on("error", () => process.exit(1));
child.on("close", (code) => process.exit(code ?? 1));
