// Differential check for the voice ports (M7): the port's decisions against the real TypeScript
// they were ported from (core's speech text and locale rules, mobile's auto-speak gate, voice plan
// and voice assignment), plus a replay of the layer-2 voice fixture's recorded mobile behavior
// through the same scenario runner that recorded it (bot voices, the device-voice choice, the
// speech playback and the dictation session). The ports are the .ets sources loaded as erasable
// TypeScript, the trick the other harmony port tests use; where the two disagree the assertion
// prints the case. Only the pure ports load here: the device engines need the platform kits.
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { voiceConnectionForm } from "@rakazo/contracts";
import * as core from "@rakazo/core";
import { deferred } from "@rakazo/core/test-async";
import * as mobileVoiceCallEntry from "@rakazo/mobile/lib/calls/voice-call-entry.js";
import * as mobileAutoSpeak from "@rakazo/mobile/lib/voice/auto-speak.js";
import * as mobileVoiceAssignment from "@rakazo/mobile/lib/voice/voice-assignment.js";
import { afterAll, describe, expect, it } from "vitest";
import type { RpcContext } from "../entry/src/main/ets/net/rpc.ets";
import type * as autoSpeakPort from "../entry/src/main/ets/voice/auto-speak.ets";
import type * as botVoicesPort from "../entry/src/main/ets/voice/bot-voices.ets";
import type * as clipLimitPort from "../entry/src/main/ets/voice/clip-limit.ets";
import type * as deviceVoicePort from "../entry/src/main/ets/voice/device-voice.ets";
import type * as dictationPort from "../entry/src/main/ets/voice/dictation.ets";
import type * as draftDictationPort from "../entry/src/main/ets/voice/draft-dictation.ets";
import type * as speechPort from "../entry/src/main/ets/voice/speech.ets";
import type { SpeechEngines } from "../entry/src/main/ets/voice/speech.ets";
import type * as speechLocalePort from "../entry/src/main/ets/voice/speech-locale.ets";
import type * as speechTextPort from "../entry/src/main/ets/voice/speech-text.ets";
import type * as stopSignalPort from "../entry/src/main/ets/voice/stop-signal.ets";
import type * as voiceAssignmentPort from "../entry/src/main/ets/voice/voice-assignment.ets";
import type * as voicePlanPort from "../entry/src/main/ets/voice/voice-plan.ets";
import type * as voiceSettingsPort from "../entry/src/main/ets/voice/voice-settings-model.ets";
import type { ChoiceSubject } from "../scripts/gen-voice-fixtures";
import { CHOICE_CASES, runChoiceCase } from "../scripts/gen-voice-fixtures";
import {
  DICTATION_SCENARIOS,
  runDraftCase,
  ScriptedPlayer,
  SPEECH_SCENARIOS,
} from "../scripts/voice-scenario-list";
import type {
  DictationScenario,
  DictationSubject,
  DraftSubject,
  FakeClock,
  ScenarioScript,
  SpeechItem,
  SpeechScenario,
  SpeechSubject,
} from "../scripts/voice-scenarios";
import {
  createFakeRecognizer,
  engineFailure,
  runDictationScenario,
  runSpeechScenario,
} from "../scripts/voice-scenarios";
import { readMaxTranscribeBytes } from "../scripts/voice-transcribe-limit";

const appRoot = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const voiceDir = path.join(appRoot, "entry/src/main/ets/voice");
const PURE_PORTS = [
  "speech-locale",
  "speech-text",
  "auto-speak",
  "voice-plan",
  "voice-assignment",
  "bot-voices",
  "stop-signal",
  "draft-dictation",
  "voice-settings-model",
  "dictation",
  "device-voice",
  "speech",
  "clip-limit",
];
// A directory of this run's own: two runs (another worktree, another worker) must not read each
// other's copy of the port.
const outDir = mkdtempSync(path.join(tmpdir(), "harmony-voice-port-"));
afterAll(() => rmSync(outDir, { force: true, recursive: true }));
for (const name of PURE_PORTS) {
  writeFileSync(
    path.join(outDir, `${name}.ts`),
    readFileSync(path.join(voiceDir, `${name}.ets`), "utf8")
      .replace(/from '\.\/([a-z.-]+?)'/g, "from './$1.ts'")
      .replace(/Record<string, Object>/g, "Record<string, object>"),
  );
}
const load = async <T>(name: string): Promise<T> =>
  import(pathToFileURL(path.join(outDir, `${name}.ts`)).href) as Promise<T>;

const locales = await load<typeof speechLocalePort>("speech-locale");
const text = await load<typeof speechTextPort>("speech-text");
const autoSpeak = await load<typeof autoSpeakPort>("auto-speak");
const plan = await load<typeof voicePlanPort>("voice-plan");
const assignment = await load<typeof voiceAssignmentPort>("voice-assignment");
const botVoices = await load<typeof botVoicesPort>("bot-voices");
const stopSignals = await load<typeof stopSignalPort>("stop-signal");
const dictation = await load<typeof dictationPort>("dictation");
const deviceVoice = await load<typeof deviceVoicePort>("device-voice");
const speech = await load<typeof speechPort>("speech");
const draftDictation = await load<typeof draftDictationPort>("draft-dictation");
const voiceSettings = await load<typeof voiceSettingsPort>("voice-settings-model");
const clipLimit = await load<typeof clipLimitPort>("clip-limit");

interface VoiceFixture {
  constants: {
    deviceVoiceKey: string;
    endpointSilenceMs: number;
    endOfSpeechGraceMs: number;
    quietRestartMs: number;
  };
  locales: {
    tags: { locale: string; expected: string }[];
    recognition: { locale: string; speaker: string | null; expected: string }[];
    supported: { wanted: string; supported: string[]; expected: string }[];
  };
  speakable: { input: string; expected: string }[];
  sentences: { input: string; expected: string[] }[];
  utterances: { input: string; expected: string[] }[];
  blockSpeech: { blocks: unknown[]; expected: string }[];
  autoSpeak: {
    name: string;
    input: Parameters<typeof mobileAutoSpeak.nextAutoSpeakAction>[0];
    expected: unknown;
  }[];
  speech: { name: string; run: { calls: unknown[][]; states: unknown[]; results: unknown[] } }[];
  dictation: { name: string; calls: unknown[][]; events: unknown[][] }[];
  choice: { name: string; expected: unknown[] }[];
  draft: { name: string; steps: unknown[]; expected: string[] }[];
  settingsForm: { name: string; input: unknown; expected: unknown }[];
  pickProvider: {
    name: string;
    input: { catalog: unknown[]; inUse: string | null; asked: string | null };
    expected: unknown;
  }[];
  botVoices: {
    name: string;
    platform: "ios" | "android";
    locale: string;
    region: string | null;
    bots: string[];
    voices: { identifier: string; language: string }[];
    listed: string[];
    picked: Array<string | null>;
  }[];
}

const fixture = JSON.parse(
  readFileSync(path.join(appRoot, "contract/fixtures/voice.json"), "utf8"),
) as VoiceFixture;

// One macrotask later every microtask queued so far has run.
const settle = (): Promise<void> => new Promise<void>((resolve) => setImmediate(resolve));

function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const key of Object.keys(value as Record<string, unknown>).sort()) {
      const item = (value as Record<string, unknown>)[key];
      if (item !== undefined) out[key] = canonical(item);
    }
    return out;
  }
  return value;
}

const noScript: ScenarioScript = { hit: (): void => undefined, fails: (): boolean => false };

/** The port's engines over the scenario script: what the device and the server would be asked. */
function portSpeechSubject(): SpeechSubject {
  const scenario = { current: SPEECH_SCENARIOS[0] as SpeechScenario };
  const device = { pending: null as (() => void) | null };
  let script = noScript;
  let choice: string | null = null;
  let statusReady = false;
  deviceVoice.setDeviceVoiceStore({
    get: async (): Promise<string | null> => {
      script.hit("deviceVoice");
      if (choice === "throws") throw new Error("device locked");
      return choice;
    },
    put: async (_key: string, value: string): Promise<void> => {
      script.hit("saveChoice", value);
      choice = value;
    },
  });
  deviceVoice.setVoiceStatusReader(async (): Promise<boolean> => {
    script.hit("status");
    return statusReady;
  });
  const engines: SpeechEngines = {
    async captureContext(): Promise<RpcContext> {
      script.hit("capture");
      return { apiBase: "https://api.example", generation: 1, headers: {} };
    },
    deviceVoiceEnabled: (): Promise<boolean> => deviceVoice.loadDeviceVoiceEnabled(),
    async deviceVoiceFor(botId: string): Promise<string | undefined> {
      script.hit("deviceVoiceFor", botId);
      return `voice-${botId}`;
    },
    deviceCanPause: (): boolean => true,
    stopDevice(): void {
      script.hit("deviceStop");
      device.pending?.();
      device.pending = null;
    },
    pauseDevice(): void {
      script.hit("device.pause");
    },
    resumeDevice(): void {
      script.hit("device.resume");
    },
    speakOnDevice(utterance: string, voice: string | undefined): Promise<void> {
      return new Promise<void>((resolve) => {
        let current = true;
        device.pending = (): void => {
          current = false;
          resolve();
        };
        // A hook may have stopped the engine already; what it stopped does not finish on its own.
        script.hit("deviceSpeak", utterance, voice ?? "");
        if (current) {
          device.pending = null;
          resolve();
        }
      });
    },
    async prepare(utterance: string, options: { botId?: string }): Promise<string[] | null> {
      script.hit("prepare", utterance, options.botId);
      if (script.fails("prepare")) throw engineFailure();
      return scenario.current.prepare;
    },
    async render(utterance: string): Promise<Uint8Array> {
      script.hit("render", utterance);
      if (script.fails("render")) throw engineFailure();
      return new Uint8Array([1, 2, 3]);
    },
    playClip(
      _bytes: Uint8Array,
      session: { setPlayer(player: unknown): void; isStopped: boolean; isPaused: boolean },
    ): Promise<void> {
      const player = new ScriptedPlayer(script);
      player.onEnd = (): void => session.setPlayer(null);
      const ended = player.playToEnd();
      session.setPlayer(player.handle());
      if (session.isStopped) {
        player.finishNow();
        return Promise.resolve();
      }
      if (session.isPaused) return ended;
      // Neither side has a status listener of its own in this replay: the fake player ends the
      // clip the moment it would start, without logging a play the recorded mobile run made
      // through its own expo-audio listener.
      player.play();
      return ended;
    },
  };
  speech.setSpeechEngines(engines);
  return {
    async reset(next: SpeechScenario, nextScript: ScenarioScript): Promise<void> {
      scenario.current = next;
      script = nextScript;
      choice = next.choice;
      statusReady = next.statusReady;
      await speech.stopVoicePlayback();
      speech.noteSessionChanged();
    },
    subscribe: (listener: () => void): (() => void) => speech.subscribeVoicePlayback(listener),
    async speak(items: SpeechItem[], queue: boolean): Promise<boolean> {
      const spoken = items.map((item) => ({
        text: item.text,
        botId: item.botId,
        ...(item.botId ? { speaker: { name: "Speaker", color: "#102030" } } : {}),
      }));
      return queue ? speech.speakQueue(spoken) : speech.speakText(spoken[0]!.text, spoken[0]!);
    },
    stop: (): void => speech.stopVoicePlayback(),
    pause: (): void => speech.pauseVoicePlayback(),
    resume: (): void => speech.resumeVoicePlayback(),
    sessionChange: (): void => speech.noteSessionChanged(),
    state: (): unknown => speech.getVoicePlaybackState(),
    later: (callback: () => void): void => {
      queueMicrotask(callback);
    },
    settle,
  };
}

/** The port's dictation session over a scripted recognizer and clock. */
function portDictationSubject(): DictationSubject {
  const state = {
    fake: null as ReturnType<typeof createFakeRecognizer> | null,
    signal: null as stopSignalPort.StopSignal | null,
    scenario: null as DictationScenario | null,
    clock: null as FakeClock | null,
    events: [] as unknown[][],
  };
  return {
    async reset(
      next: DictationScenario,
      script: ScenarioScript,
      clock: FakeClock,
      events: unknown[][],
    ): Promise<void> {
      state.scenario = next;
      state.clock = clock;
      state.events = events;
      state.fake?.silence();
      dictation.stop();
      state.fake = createFakeRecognizer(script, clock, next, true);
      const recognizer = state.fake.recognizer;
      dictation.setSpeechRecognizer({
        load: (): Promise<void> => recognizer.load(),
        start: (options: dictationPort.RecognizerStartOptions): void => recognizer.start(options),
        abort: (): void => recognizer.abort(),
        isRecognitionAvailable: (): boolean => recognizer.isRecognitionAvailable(),
        requestPermissions: (): Promise<boolean> => recognizer.requestPermissions(),
        listen: (handlers: dictationPort.RecognizerEvents): (() => void) =>
          recognizer.listen({
            result: handlers.result as never,
            end: handlers.end as never,
            error: handlers.error as never,
            speechstart: handlers.speechStart as never,
            speechend: handlers.speechEnd as never,
            level: handlers.level as never,
          }),
      });
      dictation.setDictationTimers(clock);
      state.signal = null;
    },
    async listen(kind: "fresh" | "cancelled" | "while loading"): Promise<void> {
      const controller = new stopSignals.StopSignal();
      if (kind === "cancelled") controller.cancel();
      const at = (): number => state.clock?.now ?? 0;
      const events = state.events;
      const followsLevel = state.scenario?.steps.some((step) => step.level !== undefined) ?? false;
      const listening = dictation.listen({
        onInterim: (heard: string): void => {
          events.push(["interim", at(), heard]);
        },
        onFinal: (heard: string): void => {
          events.push(["final", at(), heard]);
        },
        onGiveUp: (reason: string): void => {
          events.push(["giveUp", at(), reason]);
        },
        ...(followsLevel
          ? {
              onLevel: (level: number): void => {
                events.push(["level", at(), level]);
              },
            }
          : {}),
        endpointMs: state.scenario?.endpointMs,
        signal: controller,
      });
      if (kind === "while loading") controller.cancel();
      await listening;
      if (kind === "fresh") state.signal = controller;
    },
    cancel: (): void => state.signal?.cancel(),
    finish: (): void => dictation.finishListening(),
    hear: (transcript: string, isFinal: boolean): void => state.fake?.hear(transcript, isFinal),
    end: (): void => state.fake?.end(),
    fail: (error: string): void => state.fake?.fail(error),
    speechStart: (): void => state.fake?.speechStart(),
    speechEnd: (): void => state.fake?.speechEnd(),
    level: (value: number): void => state.fake?.level(value),
    available: async (): Promise<boolean> => dictation.available(),
    nextStartThrows: (): void => state.fake?.nextStartThrows(),
    settle,
  };
}

describe("voice ports against the live references", () => {
  it("locale tags match core", () => {
    for (const { locale } of fixture.locales.tags) {
      expect(locales.speechLocaleTag(locale), locale).toBe(core.speechLocaleTag(locale as never));
    }
    for (const { locale, speaker } of fixture.locales.recognition) {
      expect(locales.recognitionLocaleTag(locale, speaker), `${locale} / ${speaker}`).toBe(
        core.recognitionLocaleTag(locale as never, speaker),
      );
    }
    for (const { wanted, supported } of fixture.locales.supported) {
      expect(locales.supportedSpeechTag(wanted, supported), `${wanted} in ${supported}`).toBe(
        core.supportedSpeechTag(wanted, supported),
      );
    }
  });

  it("speakable text and sentences match core", () => {
    for (const { input } of fixture.speakable) {
      expect(text.speakable(input), JSON.stringify(input)).toBe(core.speakable(input));
    }
    for (const { input } of fixture.sentences) {
      expect(text.splitSentences(input), JSON.stringify(input)).toEqual(core.splitSentences(input));
    }
  });

  it("utterances match core's fallback for a runtime without Intl.Segmenter", () => {
    // The ArkTS standard library declares no Intl.Segmenter, so the port is that path of core.
    const intl = Intl as unknown as { Segmenter?: unknown };
    const segmenter = intl.Segmenter;
    let expected: string[][] = [];
    try {
      intl.Segmenter = undefined;
      expected = fixture.utterances.map((entry) => core.toUtterances(entry.input));
    } finally {
      intl.Segmenter = segmenter;
    }
    fixture.utterances.forEach((entry, index) => {
      expect(text.toUtterances(entry.input), JSON.stringify(entry.input).slice(0, 80)).toEqual(
        expected[index],
      );
    });
  });

  it("what a message says matches core speechFromBlocks", () => {
    fixture.blockSpeech.forEach((entry, index) => {
      expect(text.speechFromBlocks(entry.blocks as never), `case ${index}`).toBe(
        core.speechFromBlocks(entry.blocks as never),
      );
    });
  });

  it("a dictated clip at its cap stays inside the server's transcription limit", () => {
    const MAX_TRANSCRIBE_BYTES = readMaxTranscribeBytes();
    const cap = clipLimit.dictationCapMs(MAX_TRANSCRIBE_BYTES);
    const wavBytes = clipLimit.WAV_HEADER_BYTES + cap * clipLimit.CLIP_BYTES_PER_MS;
    expect(clipLimit.WAV_HEADER_BYTES).toBe(44);
    expect(wavBytes).toBe(8_388_588);
    expect(wavBytes).toBeLessThan(MAX_TRANSCRIBE_BYTES);
    expect(clipLimit.WAV_HEADER_BYTES + (cap + 1) * clipLimit.CLIP_BYTES_PER_MS).toBeGreaterThan(
      MAX_TRANSCRIBE_BYTES,
    );
  });

  it("the auto-speak gate, the voice plan and the voice assignment match mobile", async () => {
    for (const entry of fixture.autoSpeak) {
      expect(canonical(autoSpeak.nextAutoSpeakAction(entry.input as never)), entry.name).toEqual(
        canonical(mobileAutoSpeak.nextAutoSpeakAction(entry.input)),
      );
    }
    const statuses = [
      ["ready", true, false],
      ["transcribes", true, true],
      ["neither", false, false],
      ["transcribe only", false, true],
    ] as const;
    for (const purpose of ["call", "dictation"] as const) {
      for (const device of ["on", "off", "throws"] as const) {
        for (const available of [true, false]) {
          for (const [label, ready, transcribe] of statuses) {
            const deps = {
              loadDeviceVoiceEnabled: async (): Promise<boolean> => {
                if (device === "throws") throw new Error("unreadable");
                return device === "on";
              },
              dictationAvailable: async (): Promise<boolean> => available,
              loadVoiceStatus: async (): Promise<{ ready: boolean; transcribe: boolean }> => ({
                ready,
                transcribe,
              }),
            };
            const name = `${purpose} ${device} ${available} ${label}`;
            expect(canonical(await plan.resolveVoiceCallPlan(deps, purpose)), name).toEqual(
              canonical(await mobileVoiceCallEntry.resolveVoiceCallPlan(deps, purpose)),
            );
          }
        }
      }
    }
    const voices = ["a", "b", "c", "d"];
    for (const botId of ["bot-a", "bot-b", "bot-c", "bot-d", "bot-e", "late-bot"]) {
      for (const taken of [[], ["b"], ["a", "b", "c", "d"]]) {
        expect(assignment.pickUnusedVoice(voices, new Set(taken), botId), `${botId} ${taken}`).toBe(
          mobileVoiceAssignment.pickUnusedVoice(voices, new Set(taken), botId),
        );
      }
    }
  });
});

describe("voice ports replay the recorded mobile behavior", () => {
  it("dictated words land in the draft by the composer's own rule", () => {
    const rule = new draftDictation.DraftDictation();
    const subject: DraftSubject = {
      open: (draft: string): void => rule.open(draft),
      show: (draft: string, words: string, final: boolean): string | null =>
        rule.show(draft, words, final),
      owns: (draft: string): boolean => rule.owns(draft),
      close: (): void => rule.close(),
    };
    for (const entry of fixture.draft) {
      expect(runDraftCase(entry.steps as never, subject), entry.name).toEqual(entry.expected);
    }
  });

  it("the settings screen shows the connection and the form the real rules choose", () => {
    for (const entry of fixture.settingsForm) {
      const input = entry.input as {
        entry: unknown;
        credential: unknown;
        apiKey: string;
        baseUrl: string;
      };
      // The file stores an absent connection as null; the port's signature says undefined.
      const form = {
        entry: (input.entry ?? undefined) as never,
        credential: (input.credential ?? undefined) as never,
        apiKey: input.apiKey,
        baseUrl: input.baseUrl,
      };
      expect(canonical(voiceSettings.voiceConnectionForm(form)), entry.name).toEqual(
        canonical(voiceConnectionForm(form)),
      );
    }
    for (const entry of fixture.pickProvider) {
      const status = {
        configured: false,
        ready: false,
        transcribe: false,
        voiceId: "",
        provider: entry.input.inUse,
      };
      expect(
        voiceSettings.pickProvider(
          entry.input.catalog as never,
          status as never,
          entry.input.asked ?? undefined,
        ),
        entry.name,
      ).toBe(entry.expected);
    }
  });

  it("keeps the mobile constants and the device-voice key", () => {
    expect(deviceVoice.DEVICE_VOICE_KEY).toBe(fixture.constants.deviceVoiceKey);
    expect(dictation.ENDPOINT_SILENCE_MS).toBe(fixture.constants.endpointSilenceMs);
    expect(dictation.END_OF_SPEECH_GRACE_MS).toBe(fixture.constants.endOfSpeechGraceMs);
    expect(dictation.QUIET_RESTART_MS).toBe(fixture.constants.quietRestartMs);
  });

  it("bot voices are listed and handed out as mobile does", () => {
    for (const entry of fixture.botVoices) {
      // Android's own clause (explicitly local voices only) has no counterpart here, so the
      // replay applies it before the port, as that platform would.
      const listed =
        entry.platform === "android"
          ? entry.voices.filter((voice) => /-local$/i.test(voice.identifier))
          : entry.voices;
      const available = botVoices.assignableDeviceVoices(
        listed as never,
        entry.locale.split("-")[0]!.toLowerCase(),
      );
      expect(
        available.map((voice) => voice.identifier),
        entry.name,
      ).toEqual(entry.listed);
      const assignments: Record<string, string> = {};
      const results: Array<string | null> = [];
      for (const botId of entry.bots) {
        const voice = botVoices.chooseBotVoice(
          available as never,
          assignments,
          botId,
          entry.locale.toLowerCase(),
          entry.region?.toLowerCase() ?? null,
        );
        if (voice !== undefined) assignments[botId] = voice;
        results.push(voice ?? null);
      }
      expect(results, entry.name).toEqual(entry.picked);
    }
  });

  it("the device-voice choice behaves as mobile's module does", async () => {
    const state = {
      choice: null as string | null,
      ready: false,
      fail: false,
      statusGate: undefined as Promise<void> | undefined,
      writeGate: undefined as Promise<void> | undefined,
      readFails: false,
      writeFails: false,
    };
    deviceVoice.setDeviceVoiceStore({
      get: async (): Promise<string | null> => {
        if (state.readFails) {
          state.readFails = false;
          throw new Error("device locked");
        }
        return state.choice;
      },
      put: async (_key: string, value: string): Promise<void> => {
        if (state.writeGate) await state.writeGate;
        if (state.writeFails) {
          state.writeFails = false;
          throw new Error("device locked");
        }
        state.choice = value;
      },
    });
    let releaseStatus: (() => void) | null = null;
    let releaseWrite: (() => void) | null = null;
    deviceVoice.setVoiceStatusReader(async (): Promise<boolean> => {
      if (state.statusGate) await state.statusGate;
      if (state.fail) throw new Error("offline");
      return state.ready;
    });
    const gate = (): { promise: Promise<void>; release: () => void } => {
      const held = deferred<void>();
      return { promise: held.promise, release: held.resolve };
    };
    const subject: ChoiceSubject = {
      load: () => deviceVoice.loadDeviceVoiceEnabled(),
      save: (on: boolean) => deviceVoice.saveDeviceVoiceEnabled(on),
      listen: (listener: () => void) => deviceVoice.subscribeDeviceVoiceChoice(listener),
      status: (mode: "ready" | "fail" | "hold"): void => {
        const held = mode === "hold" ? gate() : null;
        releaseStatus = held?.release ?? null;
        state.statusGate = held?.promise;
        state.ready = mode === "ready";
        state.fail = mode === "fail";
      },
      release: (): void => {
        releaseStatus?.();
        releaseStatus = null;
        releaseWrite?.();
        releaseWrite = null;
      },
      readFails: (): void => {
        state.readFails = true;
      },
      writeFails: (): void => {
        state.writeFails = true;
      },
      holdWrite: (): void => {
        const held = gate();
        releaseWrite = held.release;
        state.writeGate = held.promise;
      },
      stored: (): string | null => state.choice,
    };
    for (const entry of CHOICE_CASES) {
      state.choice = null;
      state.ready = false;
      state.fail = false;
      const recorded = fixture.choice.find((record) => record.name === entry.name);
      expect(recorded, entry.name).toBeDefined();
      expect(await runChoiceCase(entry.steps, subject, settle), entry.name).toEqual(
        recorded!.expected,
      );
    }
  });

  it("speech playback follows the recorded engine calls, states and outcomes", async () => {
    const subject = portSpeechSubject();
    for (const scenario of SPEECH_SCENARIOS) {
      const recorded = fixture.speech.find((record) => record.name === scenario.name);
      expect(recorded, scenario.name).toBeDefined();
      expect(await runSpeechScenario(scenario, subject), scenario.name).toEqual(recorded!.run);
    }
  });

  it("the dictation session follows the recorded recognizer calls and caller events", async () => {
    const subject = portDictationSubject();
    for (const scenario of DICTATION_SCENARIOS) {
      const recorded = fixture.dictation.find((record) => record.name === scenario.name);
      expect(recorded, scenario.name).toBeDefined();
      expect(await runDictationScenario(scenario, subject), scenario.name).toEqual({
        calls: recorded!.calls,
        events: recorded!.events,
      });
    }
  });
});
