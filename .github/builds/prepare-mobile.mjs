import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Only the disposable CI checkout changes. The upstream Expo configuration stays in Git.
export function mobilePreviewConfig(source, buildNumber) {
  if (!/^[1-9]\d*$/.test(buildNumber) || Number(buildNumber) > 2_100_000_000) {
    throw new Error("The build number must be a positive Android-compatible integer.");
  }
  const result = structuredClone(source);
  const app = result.expo;
  const identifier = "dev.botone.preview";
  const group = `group.${identifier}`;
  app.slug = "botone-preview";
  app.scheme = "botone-preview";
  delete app.owner;
  delete app.extra.eas;
  app.updates = { enabled: false };
  app.android.package = identifier;
  app.android.versionCode = Number(buildNumber);
  delete app.android.googleServicesFile;
  app.ios.bundleIdentifier = identifier;
  app.ios.buildNumber = buildNumber;
  app.plugins = app.plugins.map((plugin) => {
    if (Array.isArray(plugin) && plugin[0] === "expo-sharing") {
      plugin[1].ios.appGroupId = group;
    }
    return plugin;
  });
  return result;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const file = new URL("../../apps/mobile/app.json", import.meta.url);
  const source = JSON.parse(readFileSync(file, "utf8"));
  writeFileSync(file, `${JSON.stringify(mobilePreviewConfig(source, process.argv[2]), null, 2)}\n`);
}
