import type * as childProcess from "node:child_process";
import { promisify } from "node:util";
import { afterEach, describe, expect, it, vi } from "vitest";
import { inspectHostHarness } from "./host-adapter.js";
import { hostProcessOwnershipAvailable } from "./host-process-owner.js";

const mocks = vi.hoisted(() => ({ probe: vi.fn(), launch: vi.fn() }));
vi.mock("node:child_process", async (original) => ({
  ...(await original<typeof childProcess>()),
  execFile: mocks.probe,
}));
vi.mock("./host-process.js", () => ({ launchHostProcess: mocks.launch }));
afterEach(() => vi.clearAllMocks());

describe("host descendant ownership admission", () => {
  it("rejects platforms without an owner and keeps Windows on its existing Job path", async () => {
    expect(await hostProcessOwnershipAvailable("freebsd")).toBe(false);
    expect(await hostProcessOwnershipAvailable("win32")).toBe(true);
    expect(mocks.probe).not.toHaveBeenCalled();
    expect(mocks.launch).not.toHaveBeenCalled();
  });

  it.each(["missing interpreter", "pidfd unavailable", "subreaper unavailable", "probe timeout"])(
    "rejects Linux admission on %s",
    async (diagnostic) => {
      mocks.probe.mockImplementation((_file, _args, _options, callback) =>
        callback(new Error(diagnostic)),
      );
      expect(await hostProcessOwnershipAvailable("linux")).toBe(false);
      if (process.platform !== "win32") {
        const adapter = await inspectHostHarness();
        expect(adapter.profile.status).toBe("unsupported");
        await expect(adapter.launch("/fixture/workspace")).rejects.toThrow("unavailable");
      }
      expect(mocks.launch).not.toHaveBeenCalled();
    },
  );

  it.skipIf(process.platform !== "linux")(
    "probes the actual required pidfd operations before a command can launch",
    async () => {
      const actual = await vi.importActual<typeof childProcess>("node:child_process");
      const exec = promisify(actual.execFile);
      mocks.probe.mockImplementation((_file, _args, _options, callback) => callback(null));
      expect(await hostProcessOwnershipAvailable("linux")).toBe(true);
      const program = mocks.probe.mock.calls[0]![1][3] as string;
      await exec("/usr/bin/python3", ["-I", "-u", "-c", program, "probe"], {
        env: {},
        timeout: 3000,
      });
      for (const prefix of [
        "import os; del os.pidfd_open",
        "import signal; del signal.pidfd_send_signal",
        "import os; os.pidfd_open = lambda _: (_ for _ in ()).throw(PermissionError())",
      ]) {
        await expect(
          exec("/usr/bin/python3", ["-I", "-u", "-c", `${prefix}\n${program}`, "probe"], {
            env: {},
            timeout: 3000,
          }),
        ).rejects.toThrow();
      }
    },
  );
});
