// Layer 2 drift detection (design §4.3.3): regenerate every behavior fixture from the current
// TypeScript reference and diff against the committed JSON. The ArkTS ports replay these files
// under hypium; a semantic change upstream goes red here even when no schema moved.
// Update path: HARMONY_UPDATE_FIXTURES=1 pnpm exec vitest run apps/harmony/contract, port the
// change, and commit both together.
vi.mock("@rakazo/mobile/lib/settings/ai-consent.js", () => ({ promptAiConsent: vi.fn() }));
vi.mock("expo-secure-store", () => ({
  getItemAsync: vi.fn(async () => ""),
  setItemAsync: vi.fn(async () => undefined),
  deleteItemAsync: vi.fn(async () => undefined),
}));
vi.mock("@rakazo/mobile/lib/notifications/live-notifications.js", () => ({
  resumeLiveNotifications: vi.fn(async () => undefined),
  stopLiveNotifications: vi.fn(async () => undefined),
}));
vi.mock("@rakazo/mobile/lib/api/network-cache.js", () => ({ clearNetworkCache: vi.fn() }));

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import * as SecureStore from "expo-secure-store";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { fixtureGenerators } from "../scripts/gen-fixtures";

const fixturesDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "fixtures");
const update = process.env.HARMONY_UPDATE_FIXTURES === "1";

beforeEach(() => {
  vi.mocked(SecureStore.getItemAsync).mockResolvedValue("");
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe("harmony layer-2 behavior fixtures", () => {
  for (const [name, generate] of Object.entries(fixtureGenerators)) {
    it(`fixture ${name} matches the committed reference behavior`, async () => {
      const generated = await generate();
      const file = path.join(fixturesDir, `${name}.json`);
      if (update) {
        mkdirSync(fixturesDir, { recursive: true });
        writeFileSync(file, `${JSON.stringify(generated, null, 2)}\n`);
        return;
      }
      expect(existsSync(file), `missing fixture; run HARMONY_UPDATE_FIXTURES=1 vitest`).toBe(true);
      // Deep-compare so a formatter's whitespace is not drift; any behavior change still fails.
      expect(generated).toEqual(JSON.parse(readFileSync(file, "utf8")));
    });
  }
});
