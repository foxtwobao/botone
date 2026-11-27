// The Space summary decoder (A1), replayed from the real ArkTS source so its parse rules are
// checked offline on every push (hypium needs a device). The one type-only import is replaced
// with an empty shape; nothing else in the file is ArkTS-specific.
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { afterAll, expect, it } from "vitest";
import type * as decode from "../entry/src/main/ets/contract/decode.ets";

const directory = mkdtempSync(path.join(tmpdir(), "harmony-space-decode-"));
afterAll(() => rmSync(directory, { force: true, recursive: true }));

const source = readFileSync(
  new URL("../entry/src/main/ets/contract/decode.ets", import.meta.url),
  "utf8",
);
const stripped = source.replace(
  "import type { UploadLimits } from '../thread/attachments';",
  "interface UploadLimits { maxUploadSizeBytes?: number; maxAttachmentsPerMessage?: number }",
);
if (stripped === source) throw new Error("decode.ets no longer imports UploadLimits as expected");
writeFileSync(path.join(directory, "decode.ts"), stripped);
const decoder: typeof decode = await import(pathToFileURL(path.join(directory, "decode.ts")).href);

it("reads the Space list row by row, dropping bad rows", () => {
  const spaces = decoder.decodeSpaceSummaries({
    current: { id: "s1", name: "One" },
    spaces: [
      { id: "s1", name: "One", bots: [], groups: [] },
      { id: "", name: "Empty id" },
      { id: "s2" },
      "junk",
      { id: "s3", name: "Three" },
    ],
  });
  expect(spaces).toEqual([
    { id: "s1", name: "One" },
    { id: "s3", name: "Three" },
  ]);
});

it("fails whole when the Space list is missing or not an array", () => {
  expect(decoder.decodeSpaceSummaries({ current: { id: "s1", name: "One" } })).toBeNull();
  expect(decoder.decodeSpaceSummaries({ spaces: {} })).toBeNull();
  expect(decoder.decodeSpaceSummaries(null)).toBeNull();
});
