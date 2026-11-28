import { deferred } from "@rakazo/core/test-async";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { createFixedServerStartup } from "./startup-connection.js";

const { showMessageBox, quit } = vi.hoisted(() => ({
  showMessageBox: vi.fn(),
  quit: vi.fn(),
}));
vi.mock("electron", () => ({
  app: { getName: () => "BotONE", quit },
  dialog: { showMessageBox },
}));
vi.mock("../windows/app-window.js", () => ({ PROBE_TIMEOUT_MS: 8_000 }));
vi.mock("../desktop-state.js", () => ({ desktop: { quitting: false, mainWindow: {} } }));

describe("fixed-server startup", () => {
  const url = "https://app.example.com";
  const error = "Timed out reaching that address.";

  beforeEach(() => {
    showMessageBox.mockReset();
    quit.mockReset();
  });

  it("opens the packaged server without a dialog when reachable", async () => {
    const connect = vi.fn().mockResolvedValue(null);

    await createFixedServerStartup(connect).open(url);

    expect(connect).toHaveBeenCalledExactlyOnceWith(url);
    expect(showMessageBox).not.toHaveBeenCalled();
    expect(quit).not.toHaveBeenCalled();
  });

  it("offers one retry dialog and retries the same server", async () => {
    const answer = deferred<{ response: number }>();
    const connect = vi.fn().mockResolvedValueOnce(error).mockResolvedValueOnce(null);
    const startup = createFixedServerStartup(connect);
    showMessageBox.mockReturnValueOnce(answer.promise);

    const opening = startup.open(url);
    await vi.waitFor(() =>
      expect(showMessageBox).toHaveBeenCalledExactlyOnceWith(
        expect.objectContaining({ detail: url, message: error, buttons: ["Retry", "Quit"] }),
      ),
    );
    await startup.open(url);
    expect(startup.busy()).toBe(true);
    expect(connect).toHaveBeenCalledExactlyOnceWith(url);
    answer.resolve({ response: 0 });
    await opening;

    expect(connect.mock.calls).toEqual([[url], [url]]);
    expect(startup.busy()).toBe(false);
  });

  it("quits when the user dismisses the retry dialog", async () => {
    const connect = vi.fn().mockResolvedValue(error);
    showMessageBox.mockResolvedValue({ response: 1 });

    await createFixedServerStartup(connect).open(url);

    expect(connect).toHaveBeenCalledExactlyOnceWith(url);
    expect(quit).toHaveBeenCalledOnce();
  });
});
