// Adapted from OpenMausBot server/permission-proxy.ts (Apache-2.0). See NOTICE.md.
// Stdio is exclusively MCP. This proxy has no application credentials.
import { randomUUID } from "node:crypto";
import { connect } from "node:net";
import { createInterface } from "node:readline";

const socketPath = process.argv[2];
const mode = process.argv[3] ?? "permissions";
const definitions = mode === "tools" ? JSON.parse(process.argv[4]) : null;
const send = (frame) => process.stdout.write(`${JSON.stringify(frame)}\n`);
const broker = (tool, input) =>
  new Promise((resolve) => {
    const id = randomUUID();
    const socket = connect(socketPath);
    const reader = createInterface({ input: socket });
    const timer = setTimeout(() => socket.destroy(), 10 * 60_000);
    timer.unref();
    let settled = false;
    const finish = (answer) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reader.close();
      socket.destroy();
      resolve(answer);
    };
    socket.once("connect", () => socket.write(`${JSON.stringify({ id, tool, input, mode })}\n`));
    reader.on("line", (line) => {
      try {
        const message = JSON.parse(line);
        if (message.id === id) finish(message.answer);
      } catch {
        socket.destroy();
      }
    });
    socket.on("error", () => {});
    socket.on("close", () => finish({ behavior: "deny", message: "Approval unavailable" }));
  });
let unfinishedBytes = 0;
process.stdin.on("data", (chunk) => {
  for (const byte of chunk) {
    unfinishedBytes = byte === 10 ? 0 : unfinishedBytes + 1;
    if (unfinishedBytes > 1024 * 1024) process.exit(1);
  }
});
const reader = createInterface({ input: process.stdin });
reader.on("line", (line) => {
  if (Buffer.byteLength(line) > 1024 * 1024) return process.exit(1);
  void (async () => {
    const message = JSON.parse(line);
    const result = (value) => send({ jsonrpc: "2.0", id: message.id, result: value });
    if (message.method === "initialize")
      return result({
        protocolVersion: message.params.protocolVersion,
        capabilities: { tools: {} },
        serverInfo: { name: "permissions", version: "1" },
      });
    if (message.method === "tools/list")
      return result({
        tools: definitions ?? [
          {
            name: "approve",
            description: "Request permission",
            inputSchema: {
              type: "object",
              properties: { tool_name: { type: "string" }, input: { type: "object" } },
              required: ["tool_name", "input"],
            },
          },
        ],
      });
    if (mode === "tools" && message.method === "tools/call") {
      if (!definitions.some((tool) => tool.name === message.params?.name))
        throw new Error("Unsupported tool");
      const answer = await broker(message.params.name, message.params.arguments);
      return result({ content: [{ type: "text", text: JSON.stringify(answer) }] });
    }
    if (message.method === "tools/call" && message.params?.name === "approve") {
      const args = message.params.arguments;
      const answer = await broker(args.tool_name, args.input);
      return result({ content: [{ type: "text", text: JSON.stringify(answer) }] });
    }
    if (message.id !== undefined)
      send({
        jsonrpc: "2.0",
        id: message.id,
        error: { code: -32601, message: "Unsupported request" },
      });
  })().catch(() => process.exit(1));
});
