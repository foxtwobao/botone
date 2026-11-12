import { expect, it } from "vitest";
import { nativeLaunchArguments } from "./launch-arguments.js";
import { startRequest } from "./protocol.test-support.js";

it("uses each native protocol with the run's own MCP socket and no deployment credentials", () => {
  const request = startRequest({ model: "example-model" });
  const codex = nativeLaunchArguments("codex", request, "/tmp/run-a.sock");
  expect(codex.at(-1)).toBe("app-server");
  expect(codex.join(" ")).toContain("/tmp/run-a.sock");
  expect(codex.join(" ")).not.toContain("model_provider=");
  expect(codex).not.toContain("exec");
  const claude = nativeLaunchArguments("claude", request, "/tmp/run-b.sock");
  expect(claude).toContain("stream-json");
  expect(claude.at(-1)).toBe("example-model");
  expect(claude.join(" ")).toContain("/tmp/run-b.sock");
  expect(nativeLaunchArguments("deepseek", request, "/tmp/run-c.sock")).toEqual([
    "dsh",
    "--profile",
    "acp",
  ]);
});
