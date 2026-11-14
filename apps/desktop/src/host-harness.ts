import { DesktopHarness, hostIpcSchemas } from "@rakazo/adapters/host-harness";
import type { BrowserWindow, IpcMainInvokeEvent } from "electron";
import { app, dialog, ipcMain, net } from "electron";
import { t } from "./i18n.js";

/** Electron supplies trusted IPC, session cookies, native consent and quit ordering. */
export function prepareDesktopHarness(options: {
  root: string;
  currentOrigin(): string | null;
  originForEvent(event: IpcMainInvokeEvent): string | null;
  mainWindow(): BrowserWindow | null;
  onQuitFailure(): void;
}) {
  const harness = new DesktopHarness({
    root: options.root,
    currentOrigin: options.currentOrigin,
    fetch: (url, init) => {
      const window = options.mainWindow();
      return (window && !window.isDestroyed() ? window.webContents.session : net).fetch(
        url instanceof URL ? url.toString() : url,
        { ...init, bypassCustomProtocolHandlers: true },
      );
    },
    chooseDirectory: async () => {
      const result = await dialog.showOpenDialog({
        properties: ["openDirectory"],
        title: "Choose workspace",
      });
      return result.canceled ? null : (result.filePaths[0] ?? null);
    },
    confirm: async ({ origin, workspace, target }) => {
      const result = await dialog.showMessageBox({
        type: "question",
        title: "Use local agent?",
        message:
          target === "computer"
            ? "Allow the local agent to use this server's computer when you send a message on this device?"
            : "Allow the local agent to work in this folder when you send a message on this device?",
        detail: target === "computer" ? origin : `${origin}\n${workspace}`,
        buttons: [t("Allow"), t("Cancel")],
        defaultId: 1,
        cancelId: 1,
      });
      return result.response === 0;
    },
  });
  for (const method of [
    "profiles",
    "selection",
    "configure",
    "send",
    "answer",
    "stop",
    "disconnect",
  ] as const) {
    ipcMain.handle(`desktop.harness.${method}`, async (event, input: unknown) => {
      const origin = options.originForEvent(event);
      if (!origin) {
        if (method === "profiles") return [];
        if (method === "selection") return null;
        if (method === "answer") return false;
        if (method === "stop" || method === "disconnect") return;
        throw new Error("Local agent unavailable");
      }
      switch (method) {
        case "profiles":
          return harness.profiles(origin, hostIpcSchemas.profiles.parse(input));
        case "selection":
          return harness.selection(origin, hostIpcSchemas.selection.parse(input));
        case "configure":
          return harness.configure(origin, hostIpcSchemas.configure.parse(input));
        case "send":
          return harness.send(origin, hostIpcSchemas.send.parse(input));
        case "answer":
          return harness.answer(origin, hostIpcSchemas.answer.parse(input));
        case "stop":
          return harness.stop(origin, hostIpcSchemas.stop.parse(input));
        case "disconnect":
          hostIpcSchemas.disconnect.parse(input);
          return harness.disconnectedWindow();
      }
    });
  }
  app.on("web-contents-created", (_event, contents) => {
    contents.on("did-start-navigation", (_event, _url, isInPlace, isMainFrame) => {
      if (contents === options.mainWindow()?.webContents && isMainFrame && !isInPlace)
        void harness.disconnectedWindow();
    });
  });
  return (event: { preventDefault(): void }): boolean => {
    if (!harness.hasRuns()) return false;
    event.preventDefault();
    void harness
      .close()
      .then(() => app.quit())
      .catch(() => {
        options.onQuitFailure();
        dialog.showErrorBox("Could not stop local agent", "Stop the local task before quitting.");
      });
    return true;
  };
}
