// Differential check for the OpenAI-compatible address port (M9): the same inputs against the
// real contracts normalizeOpenAiCompatibleBaseUrl and the ArkTS port, which is the .ets source
// loaded as erasable TypeScript with the HarmonyOS URL kit replaced by the standard WHATWG URL.
// The models fixture records the contract's answers for the device replay (ModelConnect.test.ets),
// where the kit's own URL parser runs.
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { normalizeOpenAiCompatibleBaseUrl } from "@rakazo/contracts";
import { afterAll, describe, expect, it } from "vitest";
import type * as urlPort from "../entry/src/main/ets/features/models/compatible-url.ets";

const appRoot = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const outDir = mkdtempSync(path.join(tmpdir(), "harmony-model-url-"));
afterAll(() => rmSync(outDir, { force: true, recursive: true }));
writeFileSync(
  path.join(outDir, "compatible-url.ts"),
  readFileSync(
    path.join(appRoot, "entry/src/main/ets/features/models/compatible-url.ets"),
    "utf8",
  ).replace(
    "import { url } from '@kit.ArkTS';",
    "const url = { URL: { parseURL: (value: string): URL => new URL(value) } };",
  ),
);
const port = (await import(
  pathToFileURL(path.join(outDir, "compatible-url.ts")).href
)) as typeof urlPort;

interface ModelsFixture {
  normalize: { input: string; ok: boolean; url?: string; error?: string }[];
}
const fixture = JSON.parse(
  readFileSync(path.join(appRoot, "contract/fixtures/models.json"), "utf8"),
) as ModelsFixture;

describe("compatible base URL port", () => {
  it("matches the real contract on every recorded case", () => {
    for (const entry of fixture.normalize) {
      const expected = entry.ok
        ? { ok: true, url: entry.url, error: "" }
        : { ok: false, url: "", error: entry.error };
      expect(port.normalizeOpenAiCompatibleBaseUrl(entry.input), entry.input).toEqual(expected);
    }
  });

  it("matches the real contract on unrecorded edges", () => {
    const edges = [
      "https://example.com/v2beta/chat/completions/",
      "https://example.com/a/b/v3",
      "http://example.com:8080",
      "https://[::1]/v1",
      "https://[2001:db8::1]/v4/",
      "HTTPS://Example.COM:8443/x",
      "https://example.com//v1",
      "https://example.com/chat/completions/",
    ];
    for (const input of edges) {
      let expected: { ok: boolean; url?: string; error?: string };
      try {
        expected = { ok: true, url: normalizeOpenAiCompatibleBaseUrl(input) };
      } catch (error) {
        expected = { ok: false, error: (error as Error).message };
      }
      const actual = port.normalizeOpenAiCompatibleBaseUrl(input);
      expect(actual.ok, input).toBe(expected.ok);
      if (expected.ok) expect(actual.url, input).toBe(expected.url);
      else expect(actual.error, input).toBe(expected.error);
    }
  });
});
