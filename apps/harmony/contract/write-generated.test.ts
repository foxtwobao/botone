import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { expect, onTestFinished, test } from "vitest";
import { writeGenerated } from "./write-generated";

/** A fresh file path in its own temporary directory, removed when the test ends. */
function scratchFile(): string {
  const dir = mkdtempSync(path.join(tmpdir(), "write-generated-"));
  onTestFinished(() => rmSync(dir, { recursive: true, force: true }));
  return path.join(dir, "out.json");
}

test("a failing formatter leaves the existing file untouched", () => {
  const file = scratchFile();
  writeFileSync(file, "previous\n");
  const failing = (): string => {
    throw new Error("formatter down");
  };
  expect(() => writeGenerated(file, { a: 1 }, failing)).toThrow("formatter down");
  expect(readFileSync(file, "utf8")).toBe("previous\n");
});

test("a failing formatter creates no file", () => {
  const file = path.join(scratchFile(), "..", "missing", "out.json");
  const failing = (): string => {
    throw new Error("formatter down");
  };
  expect(() => writeGenerated(file, { a: 1 }, failing)).toThrow("formatter down");
  expect(existsSync(file)).toBe(false);
});

test("the file only ever receives the formatter's output", () => {
  const file = scratchFile();
  writeGenerated(file, { a: 1 }, () => "formatted\n");
  expect(readFileSync(file, "utf8")).toBe("formatted\n");
});

test("Biome collapses the short arrays JSON.stringify expands", () => {
  const file = scratchFile();
  writeGenerated(file, { required: ["ok", "version"], nested: { type: ["string", "null"] } });
  const written = readFileSync(file, "utf8");
  expect(written).toContain('"required": ["ok", "version"]');
  expect(written).toContain('"type": ["string", "null"]');
});
