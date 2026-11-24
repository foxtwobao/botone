import { execFileSync } from "node:child_process";
import path from "node:path";
import { describe, expect, it } from "vitest";

const describeFast = process.env.VERIFY_PROVIDERS ? describe.skip : describe;
const repoRoot = path.resolve(import.meta.dirname, "../../../..");

// The smokes fork thousands of stub processes, which takes most of the default 30s where forking is slow (macOS).
describeFast("compose installer smoke scripts", { timeout: 120_000 }, () => {
  it("passes every infra/compose/*.smoke.sh", () => {
    const runner = path.resolve(repoRoot, "infra/compose/run-smokes.sh");
    const output = execFileSync("bash", [runner], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      cwd: repoRoot,
    });
    expect(output).toMatch(/==>/);
  });
});
