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
  it("reads only a literal multiplication from the server source", () => {
    expect(readMaxTranscribeBytes("export const MAX_TRANSCRIBE_BYTES = 8 * 1024 * 1024;\n")).toBe(
      8_388_608,
    );
    expect(() =>
      readMaxTranscribeBytes("export const MAX_TRANSCRIBE_BYTES = getLimit();\n"),
    ).toThrow("Unsupported MAX_TRANSCRIBE_BYTES expression");
  });
});
