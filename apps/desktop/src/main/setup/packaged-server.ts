import { readFileSync } from "node:fs";
import path from "node:path";

export function readPackagedServer(appPath: string) {
  const { defaultServerUrl, startAtDefaultServer } = JSON.parse(
    readFileSync(path.join(appPath, "package.json"), "utf8"),
  ) as { defaultServerUrl?: unknown; startAtDefaultServer?: unknown };
  return { defaultServerUrl, startAtDefaultServer: startAtDefaultServer === true };
}
