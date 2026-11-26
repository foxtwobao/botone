// The layer-2 voice fixture (M7), generated from the real code the ArkTS ports were written from:
// core's speech text and locale rules, and mobile's auto-speak gate, voice plan, voice assignment,
// bot voices, device-voice choice, speech playback and dictation session. The two state machines
// run as scenarios (voice-scenarios.ts): the same script drives the mobile module here and the
// port in voice-port.test.ts and under hypium. Not one of `fixtureGenerators`: its mocks must stay
// out of the other generators' module graph (see contract/voice-fixtures.test.ts).
// Dev-time code: nothing here ships.

import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import { runInNewContext } from "node:vm";
import { OPENAI_COMPATIBLE_PROVIDER_ID, voiceConnectionForm } from "@rakazo/contracts";
import * as core from "@rakazo/core";
import { randomDocuments } from "./markdown-fixture-corpus.ts";
import {
  autoSpeakInputs,
  blockSpeechCases,
  botVoiceCases,
  planInputs,
  SPEAKABLE_DOCS,
  SPEAKERS,
  SPEECH_LOCALES,
  SUPPORTED,
  utteranceInputs,
} from "./voice-fixture-corpora.ts";
import {
  DICTATION_SCENARIOS,
  DRAFT_CASES,
  runDraftCase,
  ScriptedPlayer,
  SPEECH_SCENARIOS,
} from "./voice-scenario-list.ts";
import type {
  DictationScenario,
  DictationSubject,
  DraftSubject,
  ScenarioScript,
  SpeechItem,
  SpeechScenario,
  SpeechSubject,
} from "./voice-scenarios.ts";
import {
  createFakeRecognizer,
  engineFailure,
  FakeClock,
  runDictationScenario,
  runSpeechScenario,
} from "./voice-scenarios.ts";

/** The key the mobile module keeps the device-voice choice under; the fixture pins it. */
export const DEVICE_VOICE_KEY = "rakazo.device-voice";

type MobileVoice = typeof import("@rakazo/mobile/lib/voice/voice.js");
type MobileDictation = typeof import("@rakazo/mobile/lib/voice/dictation.js");
type MobileDeviceVoice = typeof import("@rakazo/mobile/lib/voice/device-voice.js");

/** What the mobile voice modules are mocked with; the test file owns and scripts it. */
export interface VoiceWorld {
  script: ScenarioScript | null;
  /** The saved device-voice choice; "throws" makes reading it fail. */
  choice: string | null;
  /** How voice/status answers: ready, or a failure; `gate` holds the answer until it resolves. */
  status: { ready: boolean; fail: boolean; gate: Promise<void> | undefined };
  prepare: string[] | null;
  sessionListeners: Set<() => void>;
  /** What the device engine is saying now: its done and stopped callbacks. */
  utterance: { onDone?: () => void; onStopped?: () => void } | null;
  platform: "ios" | "android";
  locale: string;
  region: string | null;
  voices: unknown[];
  /** True while the bot-voice section runs the real voiceForBot over `voices`. */
  realVoices: boolean;
  /** The document directory the bot-voice assignments live in. */
  files: Map<string, string>;
  /** Makes one scripted clip player for a speech scenario. */
  createPlayer: () => ScriptedPlayer;
  /** Store scripting for the device-voice cases: the next read or write fails, or waits. */
  reads: { fail: boolean; gate: Promise<void> | undefined };
  writes: { fail: boolean; gate: Promise<void> | undefined };
}

/** What the test file lends the generator: global stubs and a way to let microtasks run. */
export interface VoiceHarness {
  stubFetch(fetching: (url: string, init: RequestInit) => Promise<Response>): void;
  /** Routes the module's setTimeout and clearTimeout through the scenario's clock. */
  stubTimers(clock: FakeClock): void;
  /** Lets every microtask queued so far run. */
  flush(): Promise<void>;
}

const SPEAKER = { name: "Speaker", color: "#102030" };

async function mobileModules() {
  const [voice, dictation, deviceVoice, botVoices, autoSpeak, voiceCallEntry, voiceAssignment] =
    await Promise.all([
      import("@rakazo/mobile/lib/voice/voice.js"),
      import("@rakazo/mobile/lib/voice/dictation.js"),
      import("@rakazo/mobile/lib/voice/device-voice.js"),
      import("@rakazo/mobile/lib/voice/bot-voices.js"),
      import("@rakazo/mobile/lib/voice/auto-speak.js"),
      import("@rakazo/mobile/lib/calls/voice-call-entry.js"),
      import("@rakazo/mobile/lib/voice/voice-assignment.js"),
    ]);
  return { voice, dictation, deviceVoice, botVoices, autoSpeak, voiceCallEntry, voiceAssignment };
}

function mobileSpeechSubject(
  world: VoiceWorld,
  harness: VoiceHarness,
  voice: MobileVoice,
): SpeechSubject {
  const sessionChanged = (): void => {
    for (const listener of [...world.sessionListeners]) listener();
  };
  return {
    async reset(scenario: SpeechScenario, script: ScenarioScript): Promise<void> {
      world.script = script;
      world.choice = scenario.choice;
      world.status = { ready: scenario.statusReady, fail: false, gate: undefined };
      world.prepare = scenario.prepare;
      world.utterance = null;
      world.createPlayer = (): ScriptedPlayer => new ScriptedPlayer(script);
      harness.stubTimers(new FakeClock());
      harness.stubFetch(async (_url: string, init: RequestInit) => {
        const body = JSON.parse(String(init.body)) as { text: string };
        script.hit("render", body.text);
        if (script.fails("render")) throw engineFailure();
        return new Response(new Uint8Array([1, 2, 3]), { status: 200 });
      });
      await voice.stopVoicePlayback();
      sessionChanged();
    },
    subscribe: (listener: () => void) => voice.subscribeVoicePlayback(listener),
    async speak(items: SpeechItem[], queue: boolean): Promise<boolean> {
      const spoken = items.map((item) => ({
        text: item.text,
        botId: item.botId,
        ...(item.botId ? { speaker: SPEAKER } : {}),
      }));
      return queue ? voice.speakQueue(spoken) : voice.speakText(spoken[0]!.text, spoken[0]!);
    },
    stop: (): void => voice.stopVoicePlayback(),
    pause: (): void => voice.pauseVoicePlayback(),
    resume: (): void => voice.resumeVoicePlayback(),
    sessionChange: sessionChanged,
    state: (): unknown => voice.getVoicePlaybackState(),
    later: (callback: () => void): void => {
      queueMicrotask(callback);
    },
    settle: (): Promise<void> => harness.flush(),
  };
}

function mobileDictationSubject(
  world: VoiceWorld,
  harness: VoiceHarness,
  dictation: MobileDictation,
): DictationSubject {
  let fake: ReturnType<typeof createFakeRecognizer> | null = null;
  let signal: AbortController | null = null;
  let scenario: DictationScenario | null = null;
  let clock: FakeClock | null = null;
  let events: unknown[][] = [];
  return {
    async reset(
      next: DictationScenario,
      script: ScenarioScript,
      nextClock: FakeClock,
      sink: unknown[][],
    ): Promise<void> {
      scenario = next;
      clock = nextClock;
      events = sink;
      world.script = script;
      fake?.silence();
      dictation.stop();
      fake = createFakeRecognizer(script, nextClock, next, false);
      dictation.setSpeechRecognizer(fake.recognizer as never);
      signal = null;
      harness.stubTimers(nextClock);
    },
    async listen(kind: "fresh" | "cancelled" | "while loading"): Promise<void> {
      const controller = new AbortController();
      if (kind === "cancelled") controller.abort();
      const at = (): number => clock?.now ?? 0;
      const listening = dictation.listen({
        onInterim: (text: string) => {
          events.push(["interim", at(), text]);
        },
        onFinal: (text: string) => {
          events.push(["final", at(), text]);
        },
        onGiveUp: (reason: string) => {
          events.push(["giveUp", at(), reason]);
        },
        ...(scenario?.steps.some((step) => step.level !== undefined)
          ? {
              onLevel: (level: number) => {
                events.push(["level", at(), level]);
              },
            }
          : {}),
        endpointMs: scenario?.endpointMs,
        signal: controller.signal,
      });
      if (kind === "while loading") controller.abort();
      await listening;
      if (kind === "fresh") signal = controller;
    },
    cancel: (): void => signal?.abort(),
    finish: (): void => dictation.finishListening(),
    hear: (transcript: string, isFinal: boolean): void => fake?.hear(transcript, isFinal),
    end: (): void => fake?.end(),
    fail: (error: string): void => fake?.fail(error),
    speechStart: (): void => fake?.speechStart(),
    speechEnd: (): void => fake?.speechEnd(),
    level: (value: number): void => fake?.level(value),
    available: async (): Promise<boolean> => dictation.available(),
    nextStartThrows: (): void => fake?.nextStartThrows(),
    settle: (): Promise<void> => harness.flush(),
  };
}

// ── the composer's draft, and the settings screen's two choices ──

type Lifted = (...args: never[]) => unknown;

/**
 * Runs one function of a screen file as it is written there. The draft's merge rule and the
 * connection choice live inside the screen files, where no import reaches them: the function's
 * own source is cut from its file, stripped of types the way Node runs any .ts, and evaluated
 * over the values it closes over.
 */
function liftFunction(file: string, name: string, bindings: Record<string, unknown>): Lifted {
  const lines = readFileSync(new URL(file, import.meta.url), "utf8").split("\n");
  const opening = new RegExp(`^\\s*function ${name}\\(`);
  const start = lines.findIndex((line) => opening.test(line));
  if (start === -1) throw new Error(`${name} is not in ${file}`);
  const indent = lines[start]!.match(/^\s*/)![0];
  let end = start + 1;
  while (end < lines.length && lines[end] !== `${indent}}`) end += 1;
  if (end === lines.length) throw new Error(`${name} in ${file} does not close`);
  const source = stripTypeScriptTypes(`${lines.slice(start, end + 1).join("\n")}\n${name}`);
  return runInNewContext(source, bindings) as Lifted;
}

/** The composer's merge rule over the refs it closes over, as thread-composer.tsx holds them. */
function mobileDraftSubject(): DraftSubject {
  const refs = {
    dictatedBase: { current: null as string | null },
    dictated: { current: "" },
    draftRef: { current: "" },
  };
  let writes = 0;
  const showDictation = liftFunction(
    "../../mobile/components/composer/thread-composer.tsx",
    "showDictation",
    {
      ...refs,
      setDraft: () => {
        writes += 1;
      },
      pendingNativeEdit: { current: null },
      nativeSelection: { current: { start: 0, end: 0 } },
      selectionHistory: { current: [] },
      completedSelection: { current: null },
      setSelection: () => undefined,
      setMentionQuery: () => undefined,
      setSlashQuery: () => undefined,
    },
  );
  return {
    // toggleDictation, when the microphone opens.
    open: (draft: string) => {
      refs.dictatedBase.current = draft;
      refs.dictated.current = draft;
    },
    show: (draft: string, words: string, final: boolean) => {
      refs.draftRef.current = draft;
      const before = writes;
      void showDictation(words, final);
      return writes === before ? null : refs.draftRef.current;
    },
    // discardDictation's condition and its last line.
    owns: (draft: string) => refs.dictatedBase.current !== null && draft === refs.dictated.current,
    close: () => {
      refs.dictatedBase.current = null;
    },
  };
}

function connectionFormCases() {
  const entry = (over: Record<string, unknown>) => ({
    id: "fake-voice",
    name: "Fake Voice",
    transcribe: true,
    ...over,
  });
  const work = { id: "model-work", label: "Work" };
  const home = { id: "model-home", label: "Home" };
  const cases = [
    {
      name: "a hosted connection with no key yet",
      entry: entry({}),
      credential: null,
      apiKey: "",
      baseUrl: "",
    },
    {
      name: "a key too short to be one",
      entry: entry({}),
      credential: null,
      apiKey: "short",
      baseUrl: "",
    },
    {
      name: "a key of eight characters",
      entry: entry({}),
      credential: null,
      apiKey: "sk-fake-key",
      baseUrl: "",
    },
    {
      name: "a key counts without the spaces around it",
      entry: entry({}),
      credential: null,
      apiKey: "  sk-fake-key  ",
      baseUrl: "",
    },
    {
      name: "a keyless connection needs nothing",
      entry: entry({ keyless: true }),
      credential: null,
      apiKey: "",
      baseUrl: "",
    },
    {
      name: "a keyless connection connects whatever is typed",
      entry: entry({ keyless: true }),
      credential: null,
      apiKey: "short",
      baseUrl: "",
    },
    {
      name: "the account's model connections are offered, and a key is still needed",
      entry: entry({ modelConnections: [work, home] }),
      credential: null,
      apiKey: "",
      baseUrl: "",
    },
    {
      name: "a sign-in is offered where the account holds no model connection yet",
      entry: entry({ modelSignIn: "Sign in to Fake Maker" }),
      credential: null,
      apiKey: "",
      baseUrl: "",
    },
    {
      name: "linked through a named model connection: the others stay offered",
      entry: entry({ modelConnections: [work, home] }),
      credential: { hasKey: false, modelCredentialId: work.id },
      apiKey: "",
      baseUrl: "",
    },
    {
      name: "a legacy link offers every model connection",
      entry: entry({ modelConnections: [work, home] }),
      credential: { hasKey: false },
      apiKey: "",
      baseUrl: "",
    },
    {
      name: "a legacy link with one model connection offers none",
      entry: entry({ modelConnections: [work] }),
      credential: { hasKey: false },
      apiKey: "",
      baseUrl: "",
    },
    {
      name: "a link to a model connection the account no longer holds",
      entry: entry({ modelConnections: [work] }),
      credential: { hasKey: false, modelCredentialId: "model-gone" },
      apiKey: "",
      baseUrl: "",
    },
    {
      name: "a saved connection without a key is not linked when none is offered",
      entry: entry({}),
      credential: { hasKey: false },
      apiKey: "",
      baseUrl: "",
    },
    {
      name: "the self-hosted connection needs its address",
      entry: entry({ id: OPENAI_COMPATIBLE_PROVIDER_ID }),
      credential: null,
      apiKey: "",
      baseUrl: "",
    },
    {
      name: "the self-hosted connection with its address and no key",
      entry: entry({ id: OPENAI_COMPATIBLE_PROVIDER_ID }),
      credential: null,
      apiKey: "",
      baseUrl: " http://192.168.1.10:8880/v1 ",
    },
    {
      name: "no connection chosen: the key alone reads as enough",
      entry: null,
      credential: null,
      apiKey: "sk-fake-key",
      baseUrl: "http://host.test/v1",
    },
  ];
  return cases.map(({ name, ...input }) => ({
    name,
    input,
    expected: voiceConnectionForm(input as never),
  }));
}

function pickProviderCases(pickProvider: Lifted) {
  const catalog = [
    { id: "fake-voice", name: "Fake Voice", transcribe: true },
    { id: "fake-second", name: "Second Voice", transcribe: false },
    { id: "fake-third", name: "Third Voice", transcribe: true },
  ];
  const cases = [
    { name: "the connection in use", catalog, inUse: "fake-second", asked: null },
    { name: "the one asked for comes first", catalog, inUse: "fake-second", asked: "fake-third" },
    {
      name: "one asked for that the catalog no longer has",
      catalog,
      inUse: "fake-voice",
      asked: "fake-gone",
    },
    { name: "the catalog's first when none is in use", catalog, inUse: null, asked: null },
    {
      name: "a connection in use that the catalog no longer lists",
      catalog,
      inUse: "fake-gone",
      asked: null,
    },
    { name: "nothing, with an empty catalog", catalog: [], inUse: null, asked: "fake-voice" },
  ];
  return cases.map(({ name, ...input }) => ({
    name,
    input,
    expected: pickProvider(input.catalog, { provider: input.inUse }, input.asked ?? undefined),
  }));
}

// ── the device-voice cases: a small script both sides replay against their own store ──

export interface ChoiceStep {
  /** Reads the choice and waits for the answer. */
  load?: boolean;
  /** Starts a read without waiting for it. */
  loadStart?: boolean;
  /** Saves a choice and waits for the write. */
  save?: "on" | "off";
  /** Starts a save without waiting for it. */
  saveStart?: "on" | "off";
  /** Waits for every read and save started so far, recording each outcome. */
  collect?: boolean;
  /** How voice/status answers from now on: ready, a failure, or held until `release`. */
  status?: "ready" | "fail" | "hold";
  /** Lets a held status answer or write go. */
  release?: boolean;
  readFails?: boolean;
  writeFails?: boolean;
  /** Makes the next write wait for `release`. */
  holdWrite?: boolean;
  /** Subscribes a listener that throws; the case ends with how many times it heard. */
  listenerThrows?: boolean;
  /** Records the stored choice. */
  stored?: boolean;
}

export const CHOICE_CASES: { name: string; steps: ChoiceStep[] }[] = [
  {
    name: "defaults to on, and keeps that answer, when no hosted voice is ready",
    steps: [{ load: true }, { status: "ready" }, { load: true }, { stored: true }],
  },
  {
    name: "keeps a hosted voice that is already ready",
    steps: [
      { status: "ready" },
      { load: true },
      { status: "fail" },
      { load: true },
      { stored: true },
    ],
  },
  {
    name: "uses this device without remembering it when the server cannot answer",
    steps: [
      { status: "fail" },
      { load: true },
      { status: "ready" },
      { load: true },
      { stored: true },
    ],
  },
  {
    name: "persists on and off",
    steps: [{ save: "on" }, { load: true }, { save: "off" }, { load: true }, { stored: true }],
  },
  {
    name: "never overwrites a choice saved while the default was being worked out",
    steps: [
      { status: "hold" },
      { loadStart: true },
      { save: "on" },
      { release: true },
      { collect: true },
      { stored: true },
    ],
  },
  {
    name: "reads a choice still being saved instead of writing a default over it",
    steps: [
      { status: "ready" },
      { holdWrite: true },
      { saveStart: "on" },
      { loadStart: true },
      { release: true },
      { collect: true },
      { stored: true },
    ],
  },
  {
    name: "tells listeners at once and keeps a save that a listener fails in",
    steps: [{ listenerThrows: true }, { save: "on" }],
  },
  {
    name: "rejects when the store cannot write, so callers can roll back",
    steps: [
      { status: "ready" },
      { writeFails: true },
      { save: "on" },
      { load: true },
      { stored: true },
    ],
  },
  {
    name: "rejects when the store cannot be read, instead of treating the preference as off",
    steps: [{ readFails: true }, { load: true }],
  },
];

/** The device-voice module and the knobs its store and status read expose to a case. Before the
 *  first `status` a status read answers that no voice is ready. */
export interface ChoiceSubject {
  load(): Promise<boolean>;
  save(on: boolean): Promise<void>;
  listen(listener: () => void): () => void;
  status(mode: "ready" | "fail" | "hold"): void;
  release(): void;
  readFails(): void;
  writeFails(): void;
  holdWrite(): void;
  stored(): string | null;
}

/** Runs one device-voice case; each outcome is true, false, "ok" or the failure's message. */
export async function runChoiceCase(
  steps: ChoiceStep[],
  subject: ChoiceSubject,
  flush: () => Promise<void>,
): Promise<unknown[]> {
  const out: unknown[] = [];
  const started: Array<Promise<unknown>> = [];
  // A read answers true or false; a save that resolves answers "ok".
  const outcome = (work: Promise<unknown>): Promise<unknown> =>
    work.then(
      (value) => (value === undefined ? "ok" : value),
      (error: unknown) => (error as Error).message,
    );
  let notified: number | null = null;
  for (const step of steps) {
    if (step.status) subject.status(step.status);
    if (step.readFails) subject.readFails();
    if (step.writeFails) subject.writeFails();
    if (step.holdWrite) subject.holdWrite();
    if (step.listenerThrows) {
      notified = 0;
      subject.listen((): void => {
        notified = (notified ?? 0) + 1;
        throw new Error("listener broke");
      });
    }
    if (step.load) out.push(await outcome(subject.load()));
    if (step.save) out.push(await outcome(subject.save(step.save === "on")));
    if (step.loadStart) started.push(subject.load());
    if (step.saveStart) started.push(outcome(subject.save(step.saveStart === "on")));
    await flush();
    if (step.release) subject.release();
    await flush();
    if (step.collect) {
      for (const work of started.splice(0)) out.push(await outcome(work));
    }
    if (step.stored) out.push(subject.stored());
  }
  if (notified !== null) out.push(["notified", notified]);
  return out;
}

function mobileChoiceSubject(world: VoiceWorld, deviceVoice: MobileDeviceVoice): ChoiceSubject {
  let releaseStatus: (() => void) | null = null;
  let releaseWrite: (() => void) | null = null;
  const gate = (): { promise: Promise<void>; release: () => void } => {
    let release: () => void = () => undefined;
    const promise = new Promise<void>((resolve) => {
      release = resolve;
    });
    return { promise, release };
  };
  return {
    load: async (): Promise<boolean> => deviceVoice.loadDeviceVoiceEnabled(),
    save: async (on: boolean): Promise<void> => deviceVoice.saveDeviceVoiceEnabled(on),
    listen: (listener: () => void): (() => void) =>
      deviceVoice.subscribeDeviceVoiceChoice(listener),
    status: (mode: "ready" | "fail" | "hold"): void => {
      const held = mode === "hold" ? gate() : null;
      releaseStatus = held?.release ?? null;
      world.status = { ready: mode === "ready", fail: mode === "fail", gate: held?.promise };
    },
    release: (): void => {
      releaseStatus?.();
      releaseStatus = null;
      releaseWrite?.();
      releaseWrite = null;
    },
    readFails: (): void => {
      world.reads.fail = true;
    },
    writeFails: (): void => {
      world.writes.fail = true;
    },
    holdWrite: (): void => {
      const held = gate();
      releaseWrite = held.release;
      world.writes.gate = held.promise;
    },
    stored: (): string | null => world.choice,
  };
}

// ── the fixture ──

export async function generateVoiceFixture(
  world: VoiceWorld,
  harness: VoiceHarness,
): Promise<unknown> {
  const { voice, dictation, deviceVoice, botVoices, autoSpeak, voiceCallEntry, voiceAssignment } =
    await mobileModules();

  const inputs = utteranceInputs();
  const intl = Intl as unknown as { Segmenter?: unknown };
  const segmenter = intl.Segmenter;
  let withSegmenter: string[][] = [];
  let utterances: string[][] = [];
  try {
    withSegmenter = inputs.map((input) => core.toUtterances(input));
    // The ArkTS standard library declares no Intl.Segmenter, so the port is core's own fallback
    // for such runtimes; the fixture pins that path and lists where the two differ.
    intl.Segmenter = undefined;
    utterances = inputs.map((input) => core.toUtterances(input));
  } finally {
    intl.Segmenter = segmenter;
  }

  // Bot voices: the real voiceForBot over the listed voices, with its assignment file in memory.
  world.realVoices = true;
  const botVoiceRuns = [];
  for (const scenario of botVoiceCases()) {
    world.files.clear();
    world.platform = scenario.platform;
    world.locale = scenario.locale;
    world.region = scenario.region;
    world.voices = scenario.voices;
    const listed = (await botVoices.deviceVoices()).map((entry) => entry.identifier);
    const picked = [];
    for (const botId of scenario.bots) picked.push(await botVoices.voiceForBot(botId));
    botVoiceRuns.push({ ...scenario, listed, picked });
  }
  world.realVoices = false;

  // Device voice: the real module over the scripted store and status read.
  const choiceSubject = mobileChoiceSubject(world, deviceVoice);
  const choiceRuns = [];
  for (const scenario of CHOICE_CASES) {
    world.choice = null;
    world.reads = { fail: false, gate: undefined };
    world.writes = { fail: false, gate: undefined };
    choiceRuns.push({
      name: scenario.name,
      expected: await runChoiceCase(scenario.steps, choiceSubject, harness.flush),
    });
  }
  world.choice = null;
  world.reads = { fail: false, gate: undefined };
  world.writes = { fail: false, gate: undefined };

  // One subject for every scenario of a kind, as the replay does: its reset silences the last
  // scenario's recognizer before stopping a session that outlived it, so that stop is not logged.
  // The scenario rides with its recorded run, so hypium replays the same inputs from this file
  // without importing the runner's TS list.
  const speech = [];
  const speechSubject = mobileSpeechSubject(world, harness, voice);
  for (const scenario of SPEECH_SCENARIOS) {
    speech.push({
      name: scenario.name,
      scenario,
      run: await runSpeechScenario(scenario, speechSubject),
    });
  }
  const dictationRuns = [];
  const dictationSubject = mobileDictationSubject(world, harness, dictation);
  for (const scenario of DICTATION_SCENARIOS) {
    dictationRuns.push({
      name: scenario.name,
      scenario,
      ...(await runDictationScenario(scenario, dictationSubject)),
    });
  }

  const fourVoices = [
    "en-us-x-iob-local",
    "en-us-x-iog-local",
    "en-us-x-iol-local",
    "en-us-x-iom-local",
  ];
  const assignment: [string[], string[], string[]][] = [
    [["bot-a", "bot-b", "bot-c", "bot-d"], fourVoices, []],
    [["bot-a", "bot-b", "bot-c", "bot-d", "late-bot"], fourVoices, fourVoices],
    [["bot-e", "bot-f", "bot-g"], fourVoices, ["en-us-x-iog-local"]],
  ];
  const blocks = blockSpeechCases();
  // The settings screen's choice of connection, from its own file.
  const pickProvider = liftFunction("../../mobile/app/(settings)/voice.tsx", "pickProvider", {});
  return {
    constants: {
      deviceVoiceKey: deviceVoice.DEVICE_VOICE_KEY,
      endpointSilenceMs: dictation.ENDPOINT_SILENCE_MS,
      endOfSpeechGraceMs: dictation.END_OF_SPEECH_GRACE_MS,
      quietRestartMs: dictation.QUIET_RESTART_MS,
    },
    locales: {
      tags: SPEECH_LOCALES.map((locale) => ({
        locale,
        expected: core.speechLocaleTag(locale as SpeechLocale),
      })),
      recognition: SPEECH_LOCALES.flatMap((locale) =>
        SPEAKERS.map((speaker) => ({
          locale,
          speaker,
          expected: core.recognitionLocaleTag(locale as SpeechLocale, speaker),
        })),
      ),
      supported: ["es-AR", "en-DE", "zh-CN", "en", "es", "de-CH", "fr", "xx-YY", "pt-BR"].flatMap(
        (wanted) =>
          SUPPORTED.map((supported) => ({
            wanted,
            supported,
            expected: core.supportedSpeechTag(wanted, supported),
          })),
      ),
    },
    speakable: [
      ...SPEAKABLE_DOCS,
      ...randomDocuments(160, 11).map((document) => document.markdown),
    ].map((input) => ({ input, expected: core.speakable(input) })),
    sentences: inputs.map((input) => ({ input, expected: core.splitSentences(input) })),
    utterances: inputs.map((input, index) => ({ input, expected: utterances[index] })),
    utterancesWhereTheSegmenterDiffers: inputs
      .map((input, index) =>
        JSON.stringify(withSegmenter[index]) === JSON.stringify(utterances[index])
          ? null
          : { input, withSegmenter: withSegmenter[index], without: utterances[index] },
      )
      .filter((entry) => entry !== null),
    blockSpeech: blocks.map((entry) => ({
      blocks: entry.blocks,
      expected: core.speechFromBlocks(entry.blocks as never),
    })),
    autoSpeak: autoSpeakInputs().map((entry) => ({
      name: entry.name,
      input: entry.input,
      expected: autoSpeak.nextAutoSpeakAction(entry.input),
    })),
    plan: await Promise.all(
      planInputs().map(async (entry) => ({
        name: entry.name,
        // A status read that fails is the plan's answer too: it propagates to the caller.
        expected: await voiceCallEntry
          .resolveVoiceCallPlan(
            {
              loadDeviceVoiceEnabled: async () => {
                if (entry.device === "throws") throw new Error("unreadable");
                return entry.device === "on";
              },
              dictationAvailable: async () => entry.available,
              loadVoiceStatus: async () => {
                if (entry.status === "fails") throw new Error("offline");
                return { ready: entry.ready, transcribe: entry.transcribe };
              },
            },
            entry.purpose,
          )
          .catch((error: unknown) => ({ error: (error as Error).message })),
      })),
    ),
    assignment: assignment.map(([botIds, list, taken]) => ({
      voices: list,
      taken,
      picked: botIds.map((botId) => voiceAssignment.pickUnusedVoice(list, new Set(taken), botId)),
    })),
    botVoices: botVoiceRuns,
    choice: choiceRuns,
    speech,
    dictation: dictationRuns,
    draft: DRAFT_CASES.map((entry) => ({
      name: entry.name,
      steps: entry.steps,
      expected: runDraftCase(entry.steps, mobileDraftSubject()),
    })),
    settingsForm: connectionFormCases(),
    pickProvider: pickProviderCases(pickProvider),
  };
}
