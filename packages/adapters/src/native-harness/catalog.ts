import type { HarnessDriverFactory } from "./driver.js";

/** Composition only. Shared contracts and stored settings carry opaque profile IDs. */
export async function nativeHarnessDriver(engine: string): Promise<HarnessDriverFactory> {
  switch (engine) {
    case "codex":
      return (await import("./codex.js")).createCodexDriver;
    case "claude":
      return (await import("./claude.js")).createClaudeDriver;
    case "deepseek":
      return (await import("./deepseek.js")).createDeepseekDriver;
    default:
      throw new Error("Unsupported execution engine");
  }
}
