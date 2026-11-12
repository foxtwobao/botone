import { expect, it } from "vitest";
import type { ComputerInspection, ComputerTarget } from "./computer-target.js";
import { validateComputerTarget } from "./computer-target.js";
import { scope } from "./protocol.test-support.js";

const target: ComputerTarget = {
  homeKey: "shared-home",
  workspace: "/home/user/shared",
};
const computer = (): ComputerInspection => ({
  Id: "a".repeat(64),
  Config: {
    User: "1000:1000",
    Labels: {
      "rakazo.managed": "true",
      "rakazo.spaceId": scope.spaceId,
      "rakazo.botId": target.homeKey,
    },
    Env: ["HOME=/home/user", "PATH=/usr/bin"],
  },
  HostConfig: { Privileged: false, NetworkMode: "isolated" },
  State: { Running: true, Pid: 100 },
  Mounts: [{ Source: "/test/homes/shared", Destination: "/home/user", RW: true }],
});
it("uses the granted computer account and persistent home", () => {
  expect(validateComputerTarget(computer(), target, scope)).toMatchObject({
    uid: 1000,
    gid: 1000,
    home: "/home/user",
    source: "/test/homes/shared",
  });
});
it.each([
  (c: ComputerInspection) => {
    c.Config.Labels["rakazo.spaceId"] = "other-space";
  },
  (c: ComputerInspection) => {
    c.Config.Labels["rakazo.botId"] = "other-home";
  },
  (c: ComputerInspection) => {
    c.Config.Labels["rakazo.managed"] = "false";
  },
  (c: ComputerInspection) => {
    c.Config.User = "0:0";
  },
  (c: ComputerInspection) => {
    c.Config.User = "1000:0";
  },
  (c: ComputerInspection) => {
    c.HostConfig.Privileged = true;
  },
  (c: ComputerInspection) => {
    c.HostConfig.NetworkMode = "host";
  },
  (c: ComputerInspection) => {
    c.HostConfig.PidMode = "host";
  },
  (c: ComputerInspection) => {
    c.Mounts[0]!.RW = false;
  },
])("rejects a computer outside its authorized boundary (%#)", (change) => {
  const c = computer();
  change(c);
  expect(() => validateComputerTarget(c, target, scope)).toThrow(
    "computer_execution_not_authorized",
  );
});
it.each(["/home/other/shared", "/home/user/../other", "/home/user"])(
  "rejects workspace %s",
  (workspace) => {
    expect(() => validateComputerTarget(computer(), { ...target, workspace }, scope)).toThrow();
  },
);
