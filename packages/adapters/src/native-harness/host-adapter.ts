import { createHash, randomUUID } from "node:crypto";
import { access, realpath, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import type { DesktopHostProfile } from "@rakazo/contracts";
import { createHostCodexDriver } from "@rakazo/native-runtime/codex";
import type { HarnessDriverFactory, HarnessProcess } from "@rakazo/native-runtime/driver";
import { hostDisabledFeatures } from "@rakazo/native-runtime/host-policy";
import { HarnessRpc } from "@rakazo/native-runtime/rpc";
import { launchHostProcess } from "./host-process.js";
import type { HostProcessMarker } from "./host-process-macos.js";
import { createHostProcessMarker } from "./host-process-macos.js";
import { hostProcessOwnershipAvailable } from "./host-process-owner.js";

// A tested protocol version is an admission requirement, not a guess based on semver.
export const HOST_ENGINE_VERSION = "0.167.0";
const profile = { id: "native-cli", label: "Codex · This device" };

export function hostLaunchArguments() {
  return [
    ...hostDisabledFeatures.flatMap((feature) => ["--disable", feature]),
    "-c",
    "mcp_servers={}",
    "-c",
    "notify=[]",
    "-c",
    'web_search="disabled"',
    "-c",
    "allow_login_shell=false",
    "-c",
    'shell_environment_policy.inherit="none"',
    "app-server",
  ];
}

export function hostMcpOverride(servers: string[]) {
  // The CLI parses the override key separately; quoted names belong in its TOML value.
  const value = `mcp_servers={${servers.map((name) => `${JSON.stringify(name)}={enabled=false}`).join(",")}}`;
  if (servers.length > 256 || value.length > 64_000)
    throw new Error("host_configuration_not_confirmed");
  return value;
}

export function hostFilesystemOverride(
  permissions: string,
  readOnly: boolean,
  marker?: HostProcessMarker,
) {
  const entries = [
    `":root"="${readOnly ? "deny" : "read"}"`,
    '":minimal"="read"',
    `":workspace_roots"={"."="${readOnly ? "read" : "write"}"}`,
    ...(marker
      ? [`${JSON.stringify(marker.allow)}="read"`, `${JSON.stringify(marker.deny)}="deny"`]
      : []),
  ];
  return `permissions.${permissions}.filesystem={${entries.join(",")}}`;
}

/** Preserve the native sign-in, without exporting product server credentials into the CLI. */
export function hostEnvironment(source: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {};
  for (const key of [
    "PATH",
    "HOME",
    "USERPROFILE",
    "APPDATA",
    "LOCALAPPDATA",
    "SYSTEMROOT",
    "WINDIR",
    "COMSPEC",
    "TEMP",
    "TMP",
    "TMPDIR",
    "LANG",
    "LC_ALL",
    "CODEX_HOME",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
    "XDG_CACHE_HOME",
    "DBUS_SESSION_BUS_ADDRESS",
    "DISPLAY",
    "WAYLAND_DISPLAY",
  ]) {
    const actual = Object.keys(source).find((name) => name.toUpperCase() === key);
    if (actual && source[actual]) env[key] = source[actual];
  }
  return env;
}

async function file(candidate: string) {
  try {
    await access(candidate);
    return (await stat(candidate)).isFile() ? await realpath(candidate) : undefined;
  } catch {
    return undefined;
  }
}

/** Known native installations only. A Windows .cmd is never evaluated by a shell. */
export async function resolveHostExecutable(
  options: {
    platform?: NodeJS.Platform;
    arch?: string;
    env?: NodeJS.ProcessEnv;
    home?: string;
  } = {},
) {
  const platform = options.platform ?? process.platform;
  const arch = options.arch ?? process.arch;
  const env = options.env ?? process.env;
  const home = options.home ?? os.homedir();
  const windows = platform === "win32";
  const directories = [
    ...(env.PATH ?? env.Path ?? "").split(windows ? ";" : ":"),
    path.join(home, ".local", "bin"),
    ...(windows
      ? [path.join(env.APPDATA ?? home, "npm")]
      : ["/opt/homebrew/bin", "/usr/local/bin"]),
  ].filter((dir) => path.isAbsolute(dir));
  for (const directory of directories) {
    const native = await file(path.join(directory, windows ? "codex.exe" : "codex"));
    if (native && (!windows || native.toLowerCase().endsWith(".exe"))) return native;
    if (!windows) continue;
    // The official npm shim resolves to a native optional package. Do not execute shim text.
    const triplet = arch === "arm64" ? "aarch64-pc-windows-msvc" : "x86_64-pc-windows-msvc";
    const packageName = arch === "arm64" ? "codex-win32-arm64" : "codex-win32-x64";
    for (const relative of [
      ["node_modules", "@openai", "codex", "vendor", triplet, "codex", "codex.exe"],
      ["node_modules", "@openai", packageName, "vendor", triplet, "codex", "codex.exe"],
      [
        "node_modules",
        "@openai",
        "codex",
        "node_modules",
        "@openai",
        packageName,
        "vendor",
        triplet,
        "codex",
        "codex.exe",
      ],
    ]) {
      const executable = await file(path.join(directory, ...relative));
      if (executable) return executable;
    }
  }
  return undefined;
}

async function versionOf(executable: string, workspace: string, env: NodeJS.ProcessEnv) {
  const child = await launchHostProcess({ executable, args: ["--version"], workspace, env });
  try {
    return await new Promise<string>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("host_probe_timeout")), 5_000);
      let result = "";
      child.onLine((line) => {
        result += line;
        if (result.length > 1024) reject(new Error("host_probe_failed"));
      });
      child.onExit((code) => {
        clearTimeout(timer);
        const match = /^codex-cli (\d+\.\d+\.\d+)$/.exec(result);
        if (code === 0 && match) resolve(match[1]!);
        else reject(new Error("host_probe_failed"));
      });
    });
  } finally {
    await child.stop();
  }
}

export interface HostHarnessAdapter {
  profile: DesktopHostProfile;
  version?: string;
  identity?: string;
  launch(
    workspace: string,
    tools?: Omit<NonNullable<HarnessProcess["externalTools"]>, "permissions">,
  ): Promise<HarnessProcess>;
  driver: HarnessDriverFactory;
}

export async function inspectHostHarness(): Promise<HostHarnessAdapter> {
  const workspace = os.homedir();
  const env = hostEnvironment();
  const owned = await hostProcessOwnershipAvailable();
  const executable = owned ? await resolveHostExecutable() : undefined;
  const adapter: HostHarnessAdapter = {
    profile: { ...profile, status: owned ? "missing" : "unsupported" },
    launch: async (directory, tools) => {
      if (!executable || adapter.profile.status !== "ready")
        throw new Error("Local agent unavailable");
      const args = hostLaunchArguments();
      const marker = process.platform === "darwin" ? await createHostProcessMarker() : undefined;
      const permissions =
        tools || marker ? `rakazo_host_${randomUUID().replaceAll("-", "")}` : undefined;
      if (permissions)
        args.splice(
          args.length - 1,
          0,
          ...(tools ? ["shell_tool", "unified_exec", "view_image", "code_mode"] : []).flatMap(
            (feature) => ["--disable", feature],
          ),
          "-c",
          hostFilesystemOverride(permissions, !!tools, marker),
          "-c",
          `permissions.${permissions}.network.enabled=false`,
          "-c",
          `default_permissions=${JSON.stringify(permissions)}`,
        );
      const probe = await launchHostProcess({
        executable,
        args,
        workspace: directory,
        env,
        marker,
      });
      let servers: string[];
      try {
        const rpc = new HarnessRpc(
          probe,
          async (message) => {
            if (message.id !== undefined) await rpc.reject(message.id as string | number);
          },
          () => {},
        );
        await rpc.request(
          "initialize",
          { clientInfo: { name: "rakazo", version: "1" }, capabilities: { experimentalApi: true } },
          5_000,
        );
        await rpc.notify("initialized", {});
        const effective = (await rpc.request(
          "config/read",
          { cwd: directory, includeLayers: false },
          5_000,
        )) as { config?: { mcp_servers?: Record<string, unknown> } };
        if (!effective.config) throw new Error("host_configuration_not_confirmed");
        servers = Object.keys(effective.config.mcp_servers ?? {});
      } finally {
        await probe.stop();
      }
      // Empty TOML maps merge with user/project maps. Disable each effective server explicitly.
      args.splice(args.length - 1, 0, "-c", hostMcpOverride(servers));
      const launched = await launchHostProcess({
        executable,
        args,
        workspace: directory,
        env,
        marker,
      });
      if (tools && permissions) launched.externalTools = { ...tools, permissions };
      if (marker && permissions) launched.hostPermissions = { id: permissions, ...marker };
      return launched;
    },
    driver: createHostCodexDriver,
  };
  if (!executable) return adapter;
  adapter.profile.status = "unsupported";
  try {
    adapter.version = await versionOf(executable, workspace, env);
    if (adapter.version !== HOST_ENGINE_VERSION) return adapter;
    adapter.profile.status = "unauthenticated";
    const child = await launchHostProcess({
      executable,
      args: hostLaunchArguments(),
      workspace,
      env,
    });
    try {
      const rpc = new HarnessRpc(
        child,
        async (message) => {
          if (message.id !== undefined) await rpc.reject(message.id as string | number);
        },
        () => {},
      );
      await rpc.request(
        "initialize",
        { clientInfo: { name: "rakazo", version: "1" }, capabilities: { experimentalApi: true } },
        5_000,
      );
      await rpc.notify("initialized", {});
      const account = (await rpc.request("account/read", { refreshToken: false }, 5_000)) as {
        account?: unknown;
        requiresOpenaiAuth?: boolean;
      };
      if (account.account || account.requiresOpenaiAuth === false) {
        const auth = await stat(
          path.join(env.CODEX_HOME ?? path.join(workspace, ".codex"), "auth.json"),
        ).catch(() => null);
        adapter.identity = createHash("sha256")
          .update(
            JSON.stringify([account.account ?? null, auth?.mtimeMs ?? null, auth?.size ?? null]),
          )
          .digest("hex");
        adapter.profile.status = "ready";
      }
    } finally {
      await child.stop();
    }
  } catch {
    /* A failed probe never authorizes a process. */
  }
  return adapter;
}
