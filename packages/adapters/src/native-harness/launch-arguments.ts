import type { NativeExecutionStart } from "@rakazo/adapter-kit";
import { platformMcpServer } from "./bridge-tools.js";
import type { ComputerTarget } from "./computer-target.js";

export interface ComputerExecutionProfile {
  engine: "codex" | "claude" | "deepseek";
  computer: ComputerTarget;
  modelConnection?: { url: string; apiKey: string; model: string };
  initialization?: { url: string; token: string };
}

export function nativeLaunchArguments(
  profile: ComputerExecutionProfile,
  request: NativeExecutionStart,
) {
  switch (profile.engine) {
    case "codex":
      return [
        "codex",
        "--disable",
        "hooks",
        "--disable",
        "plugins",
        "--disable",
        "remote_plugin",
        "-c",
        `mcp_servers={platform={command=${JSON.stringify(platformMcpServer.command)},args=${JSON.stringify(platformMcpServer.args)}}}`,
        ...(profile.modelConnection
          ? [
              "-c",
              'model_provider="granted"',
              "-c",
              `model_providers.granted={name="Granted connection",base_url=${JSON.stringify(profile.modelConnection.url)},wire_api="responses",env_key="OPENAI_API_KEY"}`,
              "-c",
              `model=${JSON.stringify(profile.modelConnection.model)}`,
            ]
          : []),
        "app-server",
      ];
    case "deepseek":
      return ["dsh", "--profile", "acp"];
    case "claude": {
      const mcp = JSON.stringify({
        mcpServers: {
          platform: { command: platformMcpServer.command, args: platformMcpServer.args },
          permissions: {
            command: "/usr/bin/node",
            args: ["/run/harness/permission-proxy.mjs", "/run/harness/broker/permissions.sock"],
          },
        },
      });
      return [
        "claude",
        "-p",
        "--output-format",
        "stream-json",
        "--input-format",
        "stream-json",
        "--verbose",
        "--include-partial-messages",
        "--permission-mode",
        "default",
        "--permission-prompt-tool",
        "mcp__permissions__approve",
        "--strict-mcp-config",
        "--mcp-config",
        mcp,
        "--settings",
        '{"disableAllHooks":true}',
        "--setting-sources",
        "",
        ...(request.session ? ["--resume", request.session.id] : []),
        ...(request.model || profile.modelConnection
          ? ["--model", request.model ?? profile.modelConnection!.model]
          : []),
      ];
    }
  }
}
