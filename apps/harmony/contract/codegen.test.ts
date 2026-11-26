// The token codegen's only logic: CSS hex carries alpha last, ArkUI reads it first. A silent
// swap would tint every translucent surface, so the conversion is pinned here.
import { describe, expect, it } from "vitest";
import { toArkColor } from "../scripts/color.ts";
import { fixtureLiterals } from "../scripts/fixture-literals.ts";
import { readMaxTranscribeBytes } from "../scripts/voice-transcribe-limit.ts";

describe("token codegen color conversion", () => {
  it("moves the CSS alpha channel to the ArkUI front", () => {
    expect(toArkColor("#FCFCFC26")).toBe("#26FCFCFC");
    expect(toArkColor("#14141416")).toBe("#16141414");
    expect(toArkColor("#00000000")).toBe("#00000000");
  });

  it("passes every other form through unchanged", () => {
    expect(toArkColor("#FCFCFC")).toBe("#FCFCFC");
    expect(toArkColor("#FFF")).toBe("#FFF");
    expect(toArkColor("rgba(0, 0, 0, 0.28)")).toBe("rgba(0, 0, 0, 0.28)");
  });
});

describe("fixture embedding", () => {
  it("joins back to the JSON, in literals no longer than the bound", () => {
    const json = `{\n  "a": "a😀b\u0000c\ud800d"e\\f", "k": "${"😀".repeat(300)}"\n}`;
    const parts = fixtureLiterals(json, 40);
    expect(parts.join("")).toBe(json);
    for (const part of parts) {
      expect(JSON.stringify(part).length).toBeLessThanOrEqual(40 + 2);
    }
    // No literal ends between the two halves of a surrogate pair.
    for (const part of parts) {
      const last = part.charCodeAt(part.length - 1);
      expect(last < 0xd800 || last > 0xdbff).toBe(true);
    }
    expect(fixtureLiterals("")).toEqual([]);
  });
});

describe("voice transcription limit codegen", () => {
  it("reads the literal multiplication the server source declares", () => {
    expect(readMaxTranscribeBytes("export const MAX_TRANSCRIBE_BYTES = 8 * 1024 * 1024;\n")).toBe(
      8_388_608,
    );
  });

  it("finds the declaration by its syntax, never by text that looks like one", () => {
    // The inputs a text scan read wrongly: an old declaration inside a string, a block comment, a
    // template or a regex, each followed by the real 4 MiB declaration.
    const cases: string[] = [
      [
        'const example = "export const MAX_TRANSCRIBE_BYTES = 8 * 1024 * 1024;";',
        "export const MAX_TRANSCRIBE_BYTES: number = 4 * 1024 * 1024;",
      ].join("\n"),
      [
        "/*",
        "export const MAX_TRANSCRIBE_BYTES = 8 * 1024 * 1024;",
        "*/",
        "export const MAX_TRANSCRIBE_BYTES =",
        "  4 * 1024 * 1024;",
      ].join("\n"),
      [
        // The placeholder is the input: it must stay literal text inside the template.
        // biome-ignore lint/suspicious/noTemplateCurlyInString: the fixture's `${...}` is text
        'const note = `history: export const MAX_TRANSCRIBE_BYTES = 8 * 1024 * 1024; ${"history"}`;',
        "export const MAX_TRANSCRIBE_BYTES: number = 4 * 1024 * 1024;",
      ].join("\n"),
      [
        "const pattern = /[//]/;",
        'const spaces = /" /;',
        "export const MAX_TRANSCRIBE_BYTES = 4 * 1024 * 1024;",
      ].join("\n"),
      "// a line comment ended by a bare carriage return\rexport const MAX_TRANSCRIBE_BYTES = 4 * 1024 * 1024;",
    ];
    for (const source of cases) {
      expect(readMaxTranscribeBytes(`${source}\n`), source).toBe(4_194_304);
    }
  });

  it("reads a declaration wrapped across lines", () => {
    const source = ["export const MAX_TRANSCRIBE_BYTES =", "  4 *", "  1024 *", "  1024;", ""].join(
      "\n",
    );
    expect(readMaxTranscribeBytes(source)).toBe(4_194_304);
  });

  it("reports a duplicated, missing or unreadable declaration", () => {
    const twice = [
      "export const MAX_TRANSCRIBE_BYTES = 4 * 1024 * 1024;",
      "export const MAX_TRANSCRIBE_BYTES: number = 6 * 1024 * 1024;",
      "",
    ].join("\n");
    expect(() => readMaxTranscribeBytes(twice)).toThrow("Expected one");
    expect(() => readMaxTranscribeBytes("export const OTHER = 1;\n")).toThrow("Expected one");
    for (const initializer of [
      "getLimit()",
      "4194304 as const",
      "Object.freeze(4 * 1024 * 1024)",
      "4 * 1024 * 1024 satisfies number",
    ]) {
      expect(
        () => readMaxTranscribeBytes(`export const MAX_TRANSCRIBE_BYTES = ${initializer};\n`),
        initializer,
      ).toThrow("Unsupported");
    }
    expect(() =>
      readMaxTranscribeBytes("/* open\nexport const MAX_TRANSCRIBE_BYTES = 1;\n"),
    ).toThrow("Unterminated");
    expect(() =>
      readMaxTranscribeBytes('const a = "open\nexport const MAX_TRANSCRIBE_BYTES = 1;\n'),
    ).toThrow("Unterminated");
  });
});
