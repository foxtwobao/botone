// Layer-2 drift detection for voice (M7), by the rule fixtures.test.ts holds every other fixture
// to: regenerate `fixtures/voice.json` from the current mobile and core code and diff it against
// the committed file. The ArkTS ports replay the same file under hypium and in voice-port.test.ts.
//
// It is its own file because the mobile voice modules import the mobile API client, which the
// other generators use for real (the SSE fixture drives the real subscribeThread); the mocks the
// voice modules need must not reach them. The mocks read one `world` the generator scripts, and
// the packages mobile resolves from its own node_modules are mocked by that resolved path, since
// this package does not declare them and a bare `vi.mock("expo-audio")` would miss the import.
// Update path: HARMONY_UPDATE_FIXTURES=1 pnpm exec vitest run apps/harmony/contract.
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type * as botVoicesModule from "@rakazo/mobile/lib/voice/bot-voices.js";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { VoiceWorld } from "../scripts/gen-voice-fixtures";
import { DEVICE_VOICE_KEY, generateVoiceFixture } from "../scripts/gen-voice-fixtures";
import type { FakeClock, ScriptedPlayer } from "../scripts/voice-scenario-list";
import { engineFailure } from "../scripts/voice-scenarios";
import { writeGenerated } from "./write-generated";

const mobileRequire = await vi.hoisted(async () =>
  (await import("node:module")).createRequire(
    new URL("../../mobile/package.json", import.meta.url),
  ),
);

const world = vi.hoisted(
  (): VoiceWorld => ({
    script: null,
    choice: null,
    status: { ready: false, fail: false, gate: undefined },
    prepare: null,
    sessionListeners: new Set(),
    utterance: null,
    platform: "ios",
    locale: "en-US",
    region: null,
    voices: [],
    realVoices: false,
    files: new Map(),
    createPlayer: (): ScriptedPlayer => {
      throw new Error("no speech scenario is running");
    },
    reads: { fail: false, gate: undefined },
    writes: { fail: false, gate: undefined },
  }),
);

vi.mock(mobileRequire.resolve("expo-secure-store"), () => ({
  getItemAsync: vi.fn(async (key: string): Promise<string | null> => {
    if (key !== DEVICE_VOICE_KEY) return null;
    world.script?.hit("deviceVoice");
    if (world.reads.gate) await world.reads.gate;
    if (world.reads.fail || world.choice === "throws") {
      world.reads.fail = false;
      throw new Error("device locked");
    }
    return world.choice;
  }),
  setItemAsync: vi.fn(async (key: string, value: string): Promise<void> => {
    if (key !== DEVICE_VOICE_KEY) return;
    world.script?.hit("saveChoice", value);
    if (world.writes.gate) await world.writes.gate;
    if (world.writes.fail) {
      world.writes.fail = false;
      throw new Error("device locked");
    }
    world.choice = value;
  }),
  deleteItemAsync: vi.fn(async (): Promise<void> => undefined),
}));

vi.mock(mobileRequire.resolve("expo-localization"), () => ({
  getLocales: () => [{ languageTag: world.locale, regionCode: world.region }],
}));

vi.mock(mobileRequire.resolve("expo-file-system"), () => ({
  Paths: { document: "doc", cache: "cache" },
  File: class {
    private readonly key: string;
    uri = "file:///cache/rakazo-voice.mp3";
    constructor(...parts: string[]) {
      this.key = parts.join("/");
    }
    get exists() {
      return world.files.has(this.key);
    }
    create() {
      world.files.set(this.key, "");
    }
    async text() {
      return world.files.get(this.key) ?? "";
    }
    writeSync(content: string) {
      world.files.set(this.key, content);
    }
    delete() {}
  },
}));

vi.mock(mobileRequire.resolve("expo-speech"), () => ({
  getAvailableVoicesAsync: async () => world.voices,
  speak: vi.fn(
    (text: string, options: { voice?: string; onDone?: () => void; onStopped?: () => void }) => {
      world.script?.hit("deviceSpeak", text, options.voice ?? "");
      world.utterance = options;
      // A hook may have stopped the engine already; what it stopped does not finish on its own.
      if (world.utterance === options) options.onDone?.();
    },
  ),
  stop: vi.fn(() => {
    world.script?.hit("deviceStop");
    const current = world.utterance;
    world.utterance = null;
    current?.onStopped?.();
  }),
  pause: vi.fn(() => {
    world.script?.hit("device.pause");
  }),
  resume: vi.fn(() => {
    world.script?.hit("device.resume");
  }),
}));

vi.mock(mobileRequire.resolve("expo-audio"), () => ({
  createAudioPlayer: vi.fn(() => world.createPlayer()),
  setAudioModeAsync: vi.fn(async () => undefined),
  setIsAudioActiveAsync: vi.fn(async () => undefined),
}));

vi.mock(mobileRequire.resolve("react-native"), () => ({
  Platform: {
    get OS() {
      return world.platform;
    },
  },
}));

vi.mock("@rakazo/mobile/lib/api/api.js", () => ({
  rpc: vi.fn(async (proc: string, input: Record<string, unknown>) => {
    if (proc === "voice/status") {
      if (world.status.gate) await world.status.gate;
      if (world.status.fail) throw new Error("offline");
      world.script?.hit("status");
      return { ready: world.status.ready };
    }
    if (proc === "aiConsent/status")
      return { scope: "account-space", version: "2026-09-14", recipients: [] };
    if (proc === "voice/prepare") {
      const script = world.script;
      if (script === null) throw new Error("no scenario script");
      script.hit("prepare", input.text, input.botId);
      if (script.fails("prepare")) throw engineFailure();
      return { ready: world.prepare !== null, utterances: world.prepare ?? [] };
    }
    throw new Error(`unexpected procedure ${proc}`);
  }),
  captureApiRequestContext: vi.fn(async () => {
    world.script?.hit("capture");
    return { apiBase: "https://api.example", headers: {} };
  }),
  allowPromptedAiConsent: vi.fn(async () => undefined),
  aiConsentCoalesceKey: vi.fn(() => "voice-fixture"),
}));

vi.mock("@rakazo/mobile/lib/api/api-server.js", () => ({
  subscribeConfirmedSpaceSwitch: vi.fn(() => () => undefined),
}));

vi.mock("@rakazo/mobile/lib/api/session.js", () => ({
  subscribeSessionGeneration: vi.fn((listener: () => void) => {
    world.sessionListeners.add(listener);
    return () => world.sessionListeners.delete(listener);
  }),
}));

vi.mock("@rakazo/mobile/lib/settings/ai-consent.js", () => ({
  promptAiConsent: vi.fn(async () => true),
}));
vi.mock("@rakazo/mobile/lib/platform/monitoring.js", () => ({ reportMobileError: vi.fn() }));
vi.mock("@rakazo/mobile/lib/i18n/i18n.js", () => ({ getActiveUiLocale: () => "en" }));

// Speech scenarios hand the bot's device voice out themselves; the bot-voice section runs the
// real one over the voices the world lists.
vi.mock("@rakazo/mobile/lib/voice/bot-voices.js", async (importOriginal) => {
  const actual = await importOriginal<typeof botVoicesModule>();
  return {
    ...actual,
    voiceForBot: async (botId: string) => {
      if (world.realVoices) return actual.voiceForBot(botId);
      world.script?.hit("deviceVoiceFor", botId);
      return `voice-${botId}`;
    },
  };
});

const fixturesDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "fixtures");
const update = process.env.HARMONY_UPDATE_FIXTURES === "1";

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("harmony layer-2 voice fixture", () => {
  it("fixture voice matches the committed mobile and core behavior", async () => {
    const generated = await generateVoiceFixture(world, {
      stubFetch: (fetching: (url: string, init: RequestInit) => Promise<Response>) =>
        vi.stubGlobal("fetch", vi.fn(fetching)),
      stubTimers: (clock: FakeClock) => {
        vi.stubGlobal("setTimeout", clock.set);
        vi.stubGlobal("clearTimeout", clock.clear);
      },
      // One macrotask later every microtask queued so far has run.
      flush: () => new Promise<void>((resolve) => setImmediate(resolve)),
    });
    const file = path.join(fixturesDir, "voice.json");
    if (update) {
      writeGenerated(file, generated);
      return;
    }
    expect(existsSync(file), "missing fixture; run HARMONY_UPDATE_FIXTURES=1 vitest").toBe(true);
    // Deep-compare so a formatter's whitespace is not drift; any behavior change still fails. The
    // generated value makes the same JSON trip the file did, so an undefined reads as the null it
    // is stored as.
    expect(JSON.parse(JSON.stringify(generated))).toEqual(JSON.parse(readFileSync(file, "utf8")));
  });
});
