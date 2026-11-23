// The token codegen's only logic: CSS hex carries alpha last, ArkUI reads it first. A silent
// swap would tint every translucent surface, so the conversion is pinned here.
import { describe, expect, it } from "vitest";
import { toArkColor } from "../scripts/color.ts";

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
