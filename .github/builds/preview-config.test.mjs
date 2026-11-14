import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { mobilePreviewConfig } from "./prepare-mobile.mjs";

const source = JSON.parse(readFileSync(new URL("../../apps/mobile/app.json", import.meta.url)));

test("mobile previews cannot fetch upstream updates or register upstream push tokens", () => {
  const original = structuredClone(source);
  const { expo: app } = mobilePreviewConfig(source, "123");
  assert.deepEqual(source, original);
  assert.deepEqual(app.updates, { enabled: false });
  assert.equal(app.owner, undefined);
  assert.equal(app.extra.eas, undefined);
  assert.equal(app.android.googleServicesFile, undefined);
  assert.equal(app.android.package, "dev.botone.preview");
  assert.equal(app.ios.bundleIdentifier, app.android.package);
  assert.equal(app.android.versionCode, 123);
  assert.equal(app.ios.buildNumber, "123");
  const sharing = app.plugins.find(
    (plugin) => Array.isArray(plugin) && plugin[0] === "expo-sharing",
  );
  assert.equal(sharing[1].ios.appGroupId, `group.${app.ios.bundleIdentifier}`);
});

test("desktop previews embed the configured server and reject credential-bearing addresses", () => {
  const configFile = fileURLToPath(new URL("./desktop.cjs", import.meta.url));
  const code = "console.log(require(process.argv[1]).extraMetadata.defaultServerUrl)";
  const run = (address) =>
    execFileSync(process.execPath, ["-e", code, configFile], {
      env: { ...process.env, EXPO_PUBLIC_API_URL: address },
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
  assert.equal(run("https://app.example.com/").trim(), "https://app.example.com");
  for (const address of [
    "http://app.example.com",
    "https://user:secret@app.example.com",
    "https://app.example.com?token=fake",
  ]) {
    assert.throws(() => run(address));
  }
});

test("mobile previews reject invalid or overflowing native build numbers", () => {
  for (const value of [undefined, "", "0", "-1", "1.2", "001", "2100000001", "1; echo unsafe"]) {
    assert.throws(() => mobilePreviewConfig(source, value));
  }
});

test("desktop previews keep resources and entitlements but disable upstream updates", () => {
  const require = createRequire(import.meta.url);
  const config = require("./desktop.cjs");
  const { build } = require("../../apps/desktop/package.json");
  assert.equal(config.publish, null);
  assert.equal(config.appId, "dev.botone.preview.desktop");
  assert.equal(config.productName, "BotONE Preview");
  assert.equal(config.extraMetadata.productName, "BotONE Preview");
  assert.notEqual(config.extraMetadata.name, build.extraMetadata.name);
  assert.equal(config.mac.identity, "-");
  assert.equal(config.mac.notarize, false);
  assert.equal(config.mac.entitlements, build.mac.entitlements);
  assert.equal(config.mac.entitlementsInherit, build.mac.entitlementsInherit);
  assert.deepEqual(config.extraResources, build.extraResources);
  assert.ok(config.mac.extraResources.some((resource) => resource.to === "speech/rakazo-speech"));
  assert.ok(!config.mac.extraResources.some((resource) => resource.to === "server-bundle.json"));
  assert.ok(build.mac.extraResources.some((resource) => resource.to === "server-bundle.json"));
});
