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
  const DECLARATION = "export const MAX_TRANSCRIBE_BYTES = 8 * 1024 * 1024;";

  it("reads the declaration the server's limit file holds", () => {
    expect(readMaxTranscribeBytes(`${DECLARATION}\n`)).toBe(8_388_608);
  });

  it("lets the declaration wrap and carry line comments above it", () => {
    const wrapped = [
      "// The most audio, in bytes, the transcribe route accepts.",
      "// export const MAX_TRANSCRIBE_BYTES = 4 * 1024 * 1024;",
      "export const MAX_TRANSCRIBE_BYTES",
      "  = 4",
      "    * 1024",
      "    * 1024;",
      "",
    ].join("\n");
    expect(readMaxTranscribeBytes(wrapped)).toBe(4_194_304);
  });

  it("reports a file that holds anything but the one declaration", () => {
    // Each input was, or could be, read as a stale limit by a text scan of the factory: text that
    // looks like a declaration inside a comment, a string, a template or a regex, beside code a
    // scanner cannot tokenize (a regex after `if (...)`, a division after `a++`). None may be read.
    const rejected = [
      [
        "if (true) /export const MAX_TRANSCRIBE_BYTES = 8 * 1024 * 1024;/.source.length / 2;",
        "let a = 2;",
        "a++ / 2; export const MAX_TRANSCRIBE_BYTES = 4 * 1024 * 1024; /end;/",
      ].join("\n"),
      ["/*", "export const MAX_TRANSCRIBE_BYTES = 8 * 1024 * 1024;", "*/", DECLARATION].join("\n"),
      ['const example = "export const MAX_TRANSCRIBE_BYTES = 8 * 1024 * 1024;";', DECLARATION].join(
        "\n",
      ),
      ["const note = `export const MAX_TRANSCRIBE_BYTES = 8 * 1024 * 1024;`;", DECLARATION].join(
        "\n",
      ),
      `${DECLARATION}\nexport const OTHER = 1;\n`,
      `${DECLARATION} // trailing comment\n`,
      "export const MAX_TRANSCRIBE_BYTES: number = 8 * 1024 * 1024;\n",
      "export const MAX_TRANSCRIBE_BYTES = getLimit();\n",
      "export const MAX_TRANSCRIBE_BYTES = 8388608 as const;\n",
      "export const MAX_TRANSCRIBE_BYTES = Object.freeze(8 * 1024 * 1024);\n",
      "export const MAX_TRANSCRIBE_BYTES = 8 * 1024 * 1024\n",
      "export const OTHER = 1;\n",
      "",
    ];
    for (const initializer of [
      "0x800000",
      "8388608.0",
      "8388608n",
      "8_388_608",
      "8__388__608",
      "0",
      "08",
      "00",
    ]) {
      rejected.push(`export const MAX_TRANSCRIBE_BYTES = ${initializer};\n`);
    }
    // U+2028 and U+2029 end a line in JavaScript: a comment stops at them, so the block comment
    // below opens on real code and hides the first declaration, and the module exports 4.
    for (const lineEnd of ["\u2028", "\u2029"]) {
      rejected.push(
        [
          `//${lineEnd}/*`,
          "export const MAX_TRANSCRIBE_BYTES = 8;",
          `//${lineEnd}*/ export const MAX_TRANSCRIBE_BYTES = 4;`,
        ].join("\n"),
      );
    }
    rejected.push("export const MAX_TRANSCRIBE_BYTES = 9007199254740991 * 3;\n");
    for (const source of rejected) {
      expect(() => readMaxTranscribeBytes(source), source).toThrow(/Expected|Unsupported/);
    }
  });
});
