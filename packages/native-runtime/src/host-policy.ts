import { record } from "./driver.js";
import { HarnessProtocolError } from "./rpc.js";

export const hostDisabledFeatures = [
  "hooks",
  "plugins",
  "remote_plugin",
  "apps",
  "browser_use",
  "computer_use",
  "image_generation",
  "js_repl",
  "multi_agent",
  "multi_agent_v2",
  "memories",
  "memory_tool",
  "shell_snapshot",
  "skill_mcp_dependency_install",
  "workspace_dependencies",
  "daemon_auto_start",
] as const;

/** Validate effective native settings, including project layers, before submitting any prompt. */
export function assertHostConfiguration(value: unknown) {
  const config = record(value);
  const features = record(config.features);
  if (
    hostDisabledFeatures.some((feature) => features[feature] !== false) ||
    config.allow_login_shell !== false ||
    config.web_search !== "disabled" ||
    !Array.isArray(config.notify) ||
    config.notify.length > 0 ||
    Object.values(record(config.mcp_servers)).some((server) => record(server).enabled !== false)
  )
    throw new HarnessProtocolError("host_configuration_not_confirmed");
}

export function assertRemoteHostConfiguration(value: unknown, permissions: string) {
  assertHostConfiguration(value);
  const config = record(value);
  const features = record(config.features);
  const profile = record(record(config.permissions)[permissions]);
  const filesystem = record(profile.filesystem);
  if (
    ["shell_tool", "unified_exec", "view_image", "code_mode"].some(
      (name) => features[name] !== false,
    ) ||
    Object.entries(profile).some(
      ([name, value]) => !["filesystem", "network"].includes(name) && value !== null,
    ) ||
    Object.keys(filesystem)
      .filter((name) => filesystem[name] !== null)
      .sort()
      .join() !== ":minimal,:root,:workspace_roots" ||
    filesystem[":root"] !== "deny" ||
    filesystem[":minimal"] !== "read" ||
    Object.keys(record(filesystem[":workspace_roots"])).join() !== "." ||
    record(filesystem[":workspace_roots"])["."] !== "read" ||
    Object.entries(record(profile.network)).some(
      ([name, value]) => name !== "enabled" && value !== null,
    ) ||
    record(profile.network).enabled !== false
  )
    throw new HarnessProtocolError("host_remote_boundary_not_confirmed");
}
