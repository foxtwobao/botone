// The Space switch state machine (A2), replayed from the real ArkTS source so its transitions
// are checked offline on every push (hypium needs a device). The machine is pure; the controller
// that feeds it events and performs the effects is covered on the fixture server by
// ohosTest/ets/test/SpaceSwitch.test.ets.
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { afterAll, describe, expect, it } from "vitest";
import type * as spaceSwitch from "../entry/src/main/ets/features/spaces/space-switch.ets";

const appRoot = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
// A directory of this run's own: two runs (another worktree, another worker) must not read each
// other's copy of the port.
const outDir = mkdtempSync(path.join(tmpdir(), "harmony-space-switch-"));
afterAll(() => rmSync(outDir, { force: true, recursive: true }));
writeFileSync(
  path.join(outDir, "space-switch.ts"),
  readFileSync(path.join(appRoot, "entry/src/main/ets/features/spaces/space-switch.ets"), "utf8"),
);
const machine = (await import(
  pathToFileURL(path.join(outDir, "space-switch.ts")).href
)) as typeof spaceSwitch;

const select = (from: string, target: string) => machine.spaceSwitchEvent("select", from, target);
const event = (kind: string) => machine.spaceSwitchEvent(kind, "", "");
const switching = machine.spaceSwitchStep(machine.idleSwitchState(), select("space-a", "space-b"));

describe("space switch machine", () => {
  it("starts a switch from any settled phase when a different Space is picked", () => {
    expect(switching).toMatchObject({
      phase: "switching",
      from: "space-a",
      target: "space-b",
      kept: "space-b",
      reason: "",
    });
    const done = machine.spaceSwitchStep(switching, event("ok"));
    // A completed switch does not stop the next one.
    expect(machine.spaceSwitchStep(done, select("space-b", "space-c"))).toMatchObject({
      phase: "switching",
      from: "space-b",
      target: "space-c",
    });
  });

  it("ignores the selected Space and an empty target", () => {
    const state = machine.idleSwitchState();
    expect(machine.spaceSwitchStep(state, select("space-a", "space-a"))).toBe(state);
    expect(machine.spaceSwitchStep(state, select("space-a", ""))).toBe(state);
  });

  it("keeps the new Space on success", () => {
    expect(machine.spaceSwitchStep(switching, event("ok"))).toMatchObject({
      phase: "done",
      kept: "space-b",
      reason: "",
    });
  });

  it("rolls back to where the switch started when the disk write fails", () => {
    expect(machine.spaceSwitchStep(switching, event("disk_fail"))).toMatchObject({
      phase: "failed",
      kept: "space-a",
      reason: "disk",
    });
  });

  it("keeps the new Space when the network cannot prove it, and lets a retry run", () => {
    const failed = machine.spaceSwitchStep(switching, event("net_fail"));
    expect(failed).toMatchObject({ phase: "failed", kept: "space-b", reason: "unreachable" });
    expect(machine.spaceSwitchStep(failed, event("retry"))).toMatchObject({
      phase: "switching",
      from: "space-a",
      target: "space-b",
      kept: "space-b",
    });
  });

  it("leaves a target the server no longer grants to the recovery", () => {
    expect(machine.spaceSwitchStep(switching, event("target_gone"))).toMatchObject({
      phase: "idle",
      kept: "",
      reason: "gone",
    });
  });

  it("refuses events that do not fit the phase", () => {
    // A late answer from a superseded step is one instance; the retry is only for the network.
    expect(machine.spaceSwitchStep(switching, select("space-a", "space-c"))).toBe(switching);
    const idle = machine.idleSwitchState();
    expect(machine.spaceSwitchStep(idle, event("retry"))).toBe(idle);
    const disk = machine.spaceSwitchStep(switching, event("disk_fail"));
    expect(machine.spaceSwitchStep(disk, event("retry"))).toBe(disk);
    const done = machine.spaceSwitchStep(switching, event("ok"));
    expect(machine.spaceSwitchStep(done, event("net_fail"))).toBe(done);
  });
});
