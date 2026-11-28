import type { DesktopReachability } from "@rakazo/contracts";
import { app, dialog, net } from "electron";
import { desktop } from "../desktop-state.js";
import { t } from "../i18n.js";
import { PROBE_TIMEOUT_MS } from "../windows/app-window.js";
import {
  isRakazoHealth,
  normalizeServerUrl,
  probeFailureMessage,
  readProbeJson,
} from "./setup-config.js";

export async function probeServer(
  rawUrl: string,
  signal?: AbortSignal,
  headers: Record<string, string> = {},
): Promise<DesktopReachability> {
  const url = normalizeServerUrl(rawUrl);
  if (url === null) return { ok: false, error: t("Enter a valid http:// or https:// address.") };
  const timeout = AbortSignal.timeout(PROBE_TIMEOUT_MS);

  try {
    const response = await net.fetch(`${url}/rpc/health`, {
      method: "POST",
      headers: { ...headers, "content-type": "application/json" },
      body: JSON.stringify({ json: {} }),
      cache: "no-store",
      credentials: "omit",
      redirect: "manual",
      signal: signal ? AbortSignal.any([timeout, signal]) : timeout,
    });
    if (response.status >= 300 && response.status < 400) {
      return {
        ok: false,
        status: response.status,
        url,
        error: t("That address redirects elsewhere. Enter the final Rakazo server address."),
      };
    }
    if (!response.ok) {
      return {
        ok: false,
        status: response.status,
        url,
        error: t("The server answered with HTTP {status}.", { status: response.status }),
      };
    }
    const health = await readProbeJson(response);
    if (!isRakazoHealth(health)) {
      return {
        ok: false,
        status: response.status,
        url,
        error: t("That address did not respond like a Rakazo server."),
      };
    }
    return {
      ok: true,
      status: response.status,
      url,
    };
  } catch (error) {
    return { ok: false, url, error: probeFailureMessage(error) };
  }
}

/** A release retries the same server without opening the instance chooser. */
export function createFixedServerStartup(connect: (url: string) => Promise<string | null>) {
  let inProgress = false;
  return {
    busy: () => inProgress,
    async open(url: string) {
      if (inProgress) return;
      inProgress = true;
      try {
        while (!desktop.quitting) {
          const error = await connect(url);
          if (desktop.quitting) return;
          if (error === null) {
            if (process.platform !== "darwin" && desktop.mainWindow === null) app.quit();
            return;
          }
          const { response } = await dialog.showMessageBox({
            type: "warning",
            title: app.getName(),
            message: error,
            detail: url,
            buttons: [t("Retry"), t("Quit")],
            defaultId: 0,
            cancelId: 1,
            noLink: true,
          });
          if (response !== 0) {
            app.quit();
            return;
          }
        }
      } finally {
        inProgress = false;
      }
    },
  };
}
