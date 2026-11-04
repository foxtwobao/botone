import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

const packageJson = JSON.parse(
  readFileSync(path.resolve(import.meta.dirname, "../package.json"), "utf8"),
) as {
  productName?: string;
  build?: {
    productName?: string;
    mac?: {
      extendInfo?: Record<string, string>;
      extraResources?: { from: string; to: string }[];
    };
  };
};

describe("desktop package metadata", () => {
  it("keeps the persisted Electron identity while branding the installer", () => {
    // Electron initializes its profile and encryption identity before the main script.
    expect(packageJson.productName).toBe("Rakazo");
    expect(packageJson.build?.productName).toBe("BotONE");
  });

  it("ships a Spanish version of every macOS permission prompt", () => {
    const strings = readFileSync(
      path.resolve(import.meta.dirname, "../assets/es.lproj/InfoPlist.strings"),
      "utf8",
    );
    const prompts = Object.keys(packageJson.build?.mac?.extendInfo ?? {}).filter((key) =>
      key.endsWith("UsageDescription"),
    );
    expect(prompts.length).toBeGreaterThan(0);
    for (const key of prompts) expect(strings, key).toMatch(new RegExp(`^"${key}" = ".+";$`, "m"));
    expect(packageJson.build?.mac?.extraResources).toContainEqual({
      from: "assets/es.lproj",
      to: "es.lproj",
    });
  });
});
