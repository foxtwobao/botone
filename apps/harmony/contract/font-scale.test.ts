// The accessibility font cap (design §6.1/§8-5, M4 calibration). HarmonyOS follows the system font
// only when AppScope's configuration profile opts in, and caps it at one of a FIXED set of enum
// values. ui-tokens' MAX_FONT_SCALE is the product's bound (body text stops growing at 23pt), so the
// configured cap must be the largest allowed enum that still respects it. This pins the calibration
// to the real tokens: an upstream typeScale change that moves the bound goes red here.
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { MAX_FONT_SCALE, typeScale } from "@rakazo/ui-tokens";
import { describe, expect, it } from "vitest";

/** The only values HarmonyOS accepts for fontSizeMaxScale (SDK modulecheck/configuration.json). */
const ALLOWED_CAPS = [1, 1.15, 1.3, 1.45, 1.75, 2, 3.2];

const profilePath = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../AppScope/resources/base/profile/configuration.json",
);

function profile(): { fontSizeScale: string; fontSizeMaxScale: string } {
  return JSON.parse(readFileSync(profilePath, "utf8")).configuration;
}

describe("harmony accessibility font scale", () => {
  it("opts in to following the system font", () => {
    // Without this the app ignores the system font size entirely (the platform default).
    expect(profile().fontSizeScale).toBe("followSystem");
  });

  it("caps at the largest allowed step that keeps body text within MAX_FONT_SCALE", () => {
    const cap = Number(profile().fontSizeMaxScale);
    expect(ALLOWED_CAPS).toContain(cap);
    expect(cap).toBeLessThanOrEqual(MAX_FONT_SCALE);
    // The next step up would overshoot the product bound, so this is the closest safe cap.
    const next = ALLOWED_CAPS.find((value) => value > cap);
    if (next !== undefined) expect(next).toBeGreaterThan(MAX_FONT_SCALE);
    // The bound itself: body text never renders larger than the tokens' 23pt ceiling.
    expect(typeScale.body.fontSize * cap).toBeLessThanOrEqual(
      typeScale.body.fontSize * MAX_FONT_SCALE,
    );
  });

  it("is referenced by the app manifest", () => {
    const app = readFileSync(path.resolve(path.dirname(profilePath), "../../../app.json5"), "utf8");
    expect(app).toContain('"configuration": "$profile:configuration"');
  });
});
