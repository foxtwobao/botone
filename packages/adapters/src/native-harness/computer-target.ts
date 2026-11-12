import { execFile } from "node:child_process";
import { realpath } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";
import type { NativeExecutionStart } from "@rakazo/adapter-kit";

const execute = promisify(execFile);
export type ComputerTarget = { homeKey: string; workspace: string };
export type ComputerInspection = {
  Id: string;
  Config: { User: string; Labels: Record<string, string>; Env: string[] };
  HostConfig: { Privileged: boolean; NetworkMode: string; PidMode?: string };
  State: { Running: boolean; Pid: number };
  Mounts: Array<{ Source: string; Destination: string; RW: boolean }>;
};

export function validateComputerTarget(
  computer: ComputerInspection,
  target: ComputerTarget,
  scope: NativeExecutionStart["scope"],
) {
  const labels = computer.Config.Labels;
  const user = /^(\d+):(\d+)$/.exec(computer.Config.User);
  const computerEnvironment = Object.fromEntries(
    computer.Config.Env.map((entry) => {
      const index = entry.indexOf("=");
      return [entry.slice(0, index), entry.slice(index + 1)];
    }),
  );
  const home = computerEnvironment.HOME;
  const mount = computer.Mounts.find((mount) => mount.Destination === home && mount.RW);
  if (
    labels["rakazo.managed"] !== "true" ||
    labels["rakazo.spaceId"] !== scope.spaceId ||
    labels["rakazo.botId"] !== target.homeKey ||
    !user ||
    Number(user[1]) === 0 ||
    Number(user[2]) === 0 ||
    !home ||
    !mount ||
    !target.workspace.startsWith(`${home}/`) ||
    target.workspace.split("/").includes("..") ||
    computer.HostConfig.Privileged ||
    computer.HostConfig.NetworkMode === "host" ||
    computer.HostConfig.PidMode === "host"
  )
    throw new Error("computer_execution_not_authorized");
  return {
    uid: Number(user[1]),
    gid: Number(user[2]),
    home,
    source: mount.Source,
    env: computerEnvironment,
  };
}

export async function resolveComputerTarget(
  target: ComputerTarget,
  scope: NativeExecutionStart["scope"],
) {
  const ids = (
    await execute("/usr/bin/docker", [
      "ps",
      "-aq",
      "--no-trunc",
      "--filter",
      "label=rakazo.managed=true",
      "--filter",
      `label=rakazo.spaceId=${scope.spaceId}`,
      "--filter",
      `label=rakazo.botId=${target.homeKey}`,
    ])
  ).stdout
    .trim()
    .split(/\s+/);
  if (ids.length !== 1 || !/^[a-f0-9]{64}$/.test(ids[0]!)) throw new Error("computer_unavailable");
  const computer = JSON.parse(
    (await execute("/usr/bin/docker", ["inspect", ids[0]!], { maxBuffer: 1024 * 1024 })).stdout,
  )[0] as ComputerInspection;
  const account = validateComputerTarget(computer, target, scope);
  if (!computer.State.Running || computer.State.Pid <= 1) throw new Error("computer_unavailable");
  const source = await realpath(account.source);
  const workspace = path.join(source, path.relative(account.home, target.workspace));
  const resolved = await realpath(workspace);
  if (!resolved.startsWith(`${source}${path.sep}`))
    throw new Error("computer_workspace_outside_home");
  const allowed = new Set([
    "DISPLAY",
    "LANG",
    "LC_ALL",
    "LD_PRELOAD",
    "NSS_WRAPPER_PASSWD",
    "NSS_WRAPPER_GROUP",
    "DBUS_SESSION_BUS_ADDRESS",
    "XAUTHORITY",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "NO_PROXY",
    "http_proxy",
    "https_proxy",
    "no_proxy",
  ]);
  const env = Object.fromEntries(
    Object.entries(account.env).filter(([key]) => allowed.has(key) || key.startsWith("XDG_")),
  );
  const { PATH: computerPath } = account.env;
  return {
    ...account,
    source,
    pid: computer.State.Pid,
    workspace: resolved,
    env: {
      ...env,
      HOME: account.home,
      PATH: `${account.home}/.local/bin:${computerPath || "/usr/local/bin:/usr/bin:/bin"}`,
    },
  };
}
