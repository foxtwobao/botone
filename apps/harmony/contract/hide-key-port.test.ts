// Handwritten expectations for the key mask a failed connect shows (M9). There is no reference
// implementation to diff against: sanitizeModelConnectionError also drops key shapes, which this
// client does not port yet, so the one rule here is pinned by its own cases.
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { afterAll, describe, expect, it } from "vitest";
import type * as connectPort from "../entry/src/main/ets/features/models/model-connect-request.ets";

const appRoot = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const modelsDir = path.join(appRoot, "entry/src/main/ets/features/models");
const outDir = mkdtempSync(path.join(tmpdir(), "harmony-hide-key-"));
afterAll(() => rmSync(outDir, { force: true, recursive: true }));
writeFileSync(
  path.join(outDir, "model-providers.ts"),
  readFileSync(path.join(modelsDir, "model-providers.ets"), "utf8"),
);
writeFileSync(
  path.join(outDir, "model-connect-request.ts"),
  readFileSync(path.join(modelsDir, "model-connect-request.ets"), "utf8").replace(
    "from './model-providers'",
    "from './model-providers.ts'",
  ),
);
const connect = (await import(
  pathToFileURL(path.join(outDir, "model-connect-request.ts")).href
)) as typeof connectPort;

describe("failed connect key mask", () => {
  it("replaces every occurrence of the key, case folded, with bullets", () => {
    expect(connect.hideKnownKey("The provider rejected key sk-abcd-1234.", "sk-abcd-1234")).toBe(
      "The provider rejected key •••.",
    );
    expect(connect.hideKnownKey("sk-abcd-1234 and SK-ABCD-1234", "sk-abcd-1234")).toBe(
      "••• and •••",
    );
    expect(connect.hideKnownKey("key sk-abcd-1234 sk-abcd-1234", " sk-abcd-1234 ")).toBe(
      "key ••• •••",
    );
  });

  it("leaves the text alone for a short, empty or missing key", () => {
    const message = "Could not connect this provider";
    expect(connect.hideKnownKey(message, "")).toBe(message);
    expect(connect.hideKnownKey(message, "abc")).toBe(message);
    expect(connect.hideKnownKey(message, "abcd")).toBe(message);
    expect(connect.hideKnownKey("", "sk-abcd-1234")).toBe("");
    expect(connect.hideKnownKey("no key here", "sk-abcd-1234")).toBe("no key here");
  });

  it("treats the key literally, not as a pattern", () => {
    expect(connect.hideKnownKey("token a+b(c)*d", "a+b(c)*d")).toBe("token •••");
  });

  it("does not mask a key too short to be one", () => {
    const message = "aaa123aaa";
    expect(connect.hideKnownKey(message, "123")).toBe(message);
    expect(connect.hideKnownKey("aaaaaa", "aaa")).toBe("aaaaaa");
  });

  it("masks the key's JSON-escaped form too", () => {
    const key = 'sk/ab+cd"ef';
    expect(connect.hideKnownKey('rejected sk/ab+cd"ef now', key)).toBe("rejected ••• now");
    expect(connect.hideKnownKey('rejected sk/ab+cd\\"ef now', key)).toBe("rejected ••• now");
  });

  it("keeps the text's own case where the key is not", () => {
    expect(connect.hideKnownKey("A KEY-abcd, then key-abcd", "KEY-abcd")).toBe("A •••, then •••");
  });
});
