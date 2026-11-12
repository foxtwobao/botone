import type { NativeExecutionStart } from "@rakazo/adapter-kit";
import { computerMcpServer } from "./bridge-tools.js";

export function nativeLaunchArguments(
  engine: "codex" | "claude" | "deepseek",
  request: NativeExecutionStart,
  socket: string,
) {
  const platformMcpServer = computerMcpServer(socket);
  switch (engine) {
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
        "app-server",
      ];
    case "deepseek":
      return ["dsh", "--profile", "acp"];
    case "claude": {
      const mcp = JSON.stringify({
        mcpServers: {
          platform: { command: platformMcpServer.command, args: platformMcpServer.args },
          permissions: {
            command: computerMcpServer(socket, "permissions").command,
            args: computerMcpServer(socket, "permissions").args,
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
        ...(request.model ? ["--model", request.model] : []),
      ];
    }
  }
}
