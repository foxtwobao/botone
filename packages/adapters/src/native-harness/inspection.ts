import assert from "node:assert/strict";
import { stat } from "node:fs/promises";
import type { NativeExecutionStart } from "@rakazo/adapter-kit";
import { launchComputerHarness } from "./computer-process.js";
import { resolveComputerTarget } from "./computer-target.js";
import type { ComputerExecutionProfile } from "./launch-arguments.js";

export async function inspectComputerHarness(
  profile: ComputerExecutionProfile,
  request: NativeExecutionStart,
  root: string,
  mode: "version" | "authentication" | "isolation",
  timeoutMs = 15_000,
) {
  const process = await launchComputerHarness(profile, request, root, mode);
  let output = "";
  process.onLine((line) => {
    if (output.length < 16_384) output += `${line}\n`;
  });
  try {
    const code = await new Promise<number | null | undefined>((resolve) => {
      const timeout = setTimeout(() => {
        void process.stop().finally(() => resolve(undefined));
      }, timeoutMs);
      process.onExit((code) => {
        clearTimeout(timeout);
        resolve(code);
      });
    });
    return { code, output };
  } finally {
    await process.stop();
  }
}

export async function verifyComputerIsolation(
  profile: ComputerExecutionProfile,
  request: NativeExecutionStart,
  root: string,
  timeoutMs = 10_000,
) {
  const computer = await resolveComputerTarget(profile.computer, request.scope);
  const result = await inspectComputerHarness(profile, request, root, "isolation", timeoutMs);
  assert.equal(result.code, 0);
  const report = JSON.parse(result.output);
  assert.deepEqual(report.privatePaths, [false, false]);
  assert.equal(report.deploymentEnvironment, false);
  assert.equal(report.uid, computer.uid);
  assert(report.groups.every((group: number) => group === computer.gid));
  assert.equal(report.cgroup, "0::/");
  assert(Number.isInteger(report.pidNamespace));
  assert.notEqual(report.pidNamespace, (await stat("/proc/self/ns/pid")).ino);
  assert.notEqual(report.pidNamespace, (await stat(`/proc/${computer.pid}/ns/pid`)).ino);
}
