import { z } from "zod";
import { permissionProgram } from "./permission-program.js";

export const bridgeInputSchemas = {
  publish_file: z.object({ path: z.string().min(1).max(1024) }).strict(),
  recall_memory: z.object({ query: z.string().min(1).max(4000) }).strict(),
  message_bot: z
    .object({
      bot_id: z.string().optional(),
      confirm_name: z.string().optional(),
      message: z.string().min(1).max(16_000),
      intent: z.enum(["request", "result", "question", "status", "fyi"]).optional(),
    })
    .strict(),
};
export const bridgeToolDefinitions = Object.entries(bridgeInputSchemas).map(([name, schema]) => ({
  name,
  description:
    name === "publish_file"
      ? "Attach a workspace file (up to 1 MiB) to this chat; requires approval"
      : name === "recall_memory"
        ? "Search this bot's authorized memory"
        : "Send a message to an authorized teammate; requires approval",
  inputSchema: z.toJSONSchema(schema),
}));
export function computerMcpServer(socket: string, mode = "tools") {
  return {
    name: mode === "tools" ? "platform" : "permissions",
    type: "stdio",
    command: "/usr/local/bin/node",
    args: [
      "--input-type=module",
      "--eval",
      permissionProgram,
      "bridge",
      socket,
      mode,
      ...(mode === "tools" ? [JSON.stringify(bridgeToolDefinitions)] : []),
    ],
    env: [],
  };
}
