import { createRequire } from "node:module";

const desktopRequire = createRequire(new URL("../../apps/desktop/package.json", import.meta.url));
const builderRequire = createRequire(desktopRequire.resolve("electron-builder"));
const appBuilderRequire = createRequire(builderRequire.resolve("app-builder-lib"));
const { extractFile } = appBuilderRequire("@electron/asar");
const metadata = JSON.parse(extractFile(process.argv[2], "package.json").toString("utf8"));
const expected = new URL(process.env.EXPO_PUBLIC_API_URL).origin;
if (metadata.defaultServerUrl !== expected) {
  throw new Error("The packaged app does not contain the configured default server");
}
console.log("Verified the packaged default server.");
