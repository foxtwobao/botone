// The scripted scenarios themselves (M7): the speech playback, the dictation session and the
// composer's draft. Each is run against the mobile module when the layer-2 voice fixture is
// generated (contract/fixtures/voice.json records what mobile does) and against the ArkTS ports
// wherever the contract suite runs, through the runner in voice-scenarios.ts; the fixture
// embeds each scenario next to its recorded run so hypium replays the same inputs. Dev-time
// code: nothing here ships.

import { GRACE, QUIET, RESTART_CAP, SILENCE } from "./voice-scenarios.ts";

// ── the scenarios ──

const SPEAK_FIRST = { on: "play", nth: 1 };

export const SPEECH_SCENARIOS: SpeechScenario[] = [
  {
    name: "hosted: one utterance plays and the bar returns to idle",
    choice: "0",
    statusReady: true,
    prepare: ["First."],
    fail: {},
    hooks: [],
    queue: false,
    items: [{ text: "Read this", botId: "bot-1" }],
  },
  {
    name: "hosted: each utterance renders one clip ahead and plays in order",
    choice: "0",
    statusReady: true,
    prepare: ["First.", "Second.", "Third one."],
    fail: {},
    hooks: [],
    queue: false,
    items: [{ text: "Read this", botId: "bot-1" }],
  },
  {
    name: "hosted: no voice is set up, so nothing renders and the speak answers false",
    choice: "0",
    statusReady: false,
    prepare: null,
    fail: {},
    hooks: [],
    queue: false,
    items: [{ text: "Read this", botId: "bot-1" }],
  },
  {
    name: "queue: two bot messages speak one after the other and the bar stays up between them",
    choice: "0",
    statusReady: true,
    prepare: ["One."],
    fail: {},
    hooks: [],
    queue: true,
    items: [
      { text: "First reply", botId: "bot-1" },
      { text: "Second reply", botId: "bot-2" },
    ],
  },
  {
    name: "queue: an unspoken first item answers false and the rest is not spoken",
    choice: "0",
    statusReady: false,
    prepare: null,
    fail: {},
    hooks: [],
    queue: true,
    items: [
      { text: "First reply", botId: "bot-1" },
      { text: "Second reply", botId: "bot-2" },
    ],
  },
  {
    name: "stop while the voice is being prepared ends the speech before anything plays",
    choice: "0",
    statusReady: true,
    prepare: ["First."],
    fail: {},
    queue: false,
    hooks: [{ on: "prepare", nth: 1, action: "stop" }],
    items: [{ text: "Read this", botId: "bot-1" }],
  },
  {
    name: "stop during a hosted clip stops the player and clears the bar",
    choice: "0",
    statusReady: true,
    prepare: ["First.", "Second."],
    fail: {},
    queue: false,
    hooks: [{ ...SPEAK_FIRST, action: "stop" }],
    items: [{ text: "Read this", botId: "bot-1" }],
  },
  {
    name: "a newer speak replaces the one playing",
    choice: "0",
    statusReady: true,
    prepare: ["First.", "Second."],
    fail: {},
    queue: false,
    hooks: [{ ...SPEAK_FIRST, action: "speak", text: "Later reply", botId: "bot-2" }],
    items: [{ text: "Read this", botId: "bot-1" }],
  },
  {
    name: "pause then resume a hosted clip",
    choice: "0",
    statusReady: true,
    prepare: ["First."],
    fail: {},
    queue: false,
    hooks: [
      { ...SPEAK_FIRST, action: "pause" },
      { on: "player.pause", nth: 1, action: "resume", later: true },
    ],
    items: [{ text: "Read this", botId: "bot-1" }],
  },
  {
    name: "pause then stop a hosted clip",
    choice: "0",
    statusReady: true,
    prepare: ["First."],
    fail: {},
    queue: false,
    hooks: [
      { ...SPEAK_FIRST, action: "pause" },
      { on: "player.pause", nth: 1, action: "stop", later: true },
    ],
    items: [{ text: "Read this", botId: "bot-1" }],
  },
  {
    name: "a failed prepare ends the speech with its error",
    choice: "0",
    statusReady: true,
    prepare: ["First."],
    fail: { prepare: 1 },
    hooks: [],
    queue: false,
    items: [{ text: "Read this", botId: "bot-1" }],
  },
  {
    name: "a failed render of the second clip ends the speech after the first played",
    choice: "0",
    statusReady: true,
    prepare: ["First.", "Second.", "Third."],
    fail: { render: 2 },
    hooks: [],
    queue: false,
    items: [{ text: "Read this", botId: "bot-1" }],
  },
  {
    name: "device voice on: the utterances are spoken by the device in the bot's voice",
    choice: "1",
    statusReady: true,
    prepare: ["First."],
    fail: {},
    hooks: [],
    queue: false,
    items: [{ text: "Hello there. How are you today?", botId: "bot-1" }],
  },
  {
    name: "device voice on: text with nothing speakable answers false without touching the bar",
    choice: "1",
    statusReady: true,
    prepare: null,
    fail: {},
    hooks: [],
    queue: false,
    items: [{ text: "!!!", botId: "bot-1" }],
  },
  {
    name: "device voice on: stop mid-speech stops the device engine",
    choice: "1",
    statusReady: true,
    prepare: null,
    fail: {},
    queue: false,
    hooks: [{ on: "deviceSpeak", nth: 1, action: "stop" }],
    items: [{ text: "Hello there. How are you today?", botId: "bot-1" }],
  },
  {
    name: "device voice on: pause then resume",
    choice: "1",
    statusReady: true,
    prepare: null,
    fail: {},
    queue: false,
    hooks: [
      { on: "deviceSpeak", nth: 1, action: "pause" },
      { on: "device.pause", nth: 1, action: "resume" },
    ],
    items: [{ text: "Hello there. How are you today?", botId: "bot-1" }],
  },
  {
    name: "the device-voice choice cannot be read, so the reply stays on the device",
    choice: "throws",
    statusReady: true,
    prepare: ["First."],
    fail: {},
    hooks: [],
    queue: false,
    items: [{ text: "Hello there. How are you today?", botId: "bot-1" }],
  },
  {
    name: "never chosen and a voice is set up: the hosted voice is used and the choice is saved as off",
    choice: null,
    statusReady: true,
    prepare: ["First."],
    fail: {},
    hooks: [],
    queue: false,
    items: [{ text: "Read this", botId: "bot-1" }],
  },
  {
    name: "never chosen and no voice is set up: the device voice is used and the choice is saved as on",
    choice: null,
    statusReady: false,
    prepare: null,
    fail: {},
    hooks: [],
    queue: false,
    items: [{ text: "Hello there. How are you today?", botId: "bot-1" }],
  },
  {
    name: "the session changes during a hosted clip",
    choice: "0",
    statusReady: true,
    prepare: ["First.", "Second."],
    fail: {},
    queue: false,
    hooks: [{ ...SPEAK_FIRST, action: "session" }],
    items: [{ text: "Read this", botId: "bot-1" }],
  },
  {
    name: "the session changes while the queue captures its context",
    choice: "0",
    statusReady: true,
    prepare: ["First."],
    fail: {},
    queue: true,
    hooks: [{ on: "capture", nth: 1, action: "session" }],
    items: [{ text: "Read this", botId: "bot-1" }],
  },
  {
    name: "the session changes while a single speak captures its context",
    choice: "0",
    statusReady: true,
    prepare: ["First."],
    fail: {},
    queue: false,
    hooks: [{ on: "capture", nth: 1, action: "session" }],
    items: [{ text: "Read this", botId: "bot-1" }],
  },
];

// Step builders, so each step does one thing in the order the mobile test does it.
const A = (ms: number): DictationStep => ({ advance: ms });
const H = (transcript: string, final = false): DictationStep => ({ hear: [transcript, final] });
const E = (): DictationStep => ({ end: true });
const F = (error: string): DictationStep => ({ fail: error });
const SE = (): DictationStep => ({ speechEnd: true });
const SS = (): DictationStep => ({ speechStart: true });
/** The recognizer ends and the restart delay passes, `attempts` times. */
const RESTARTS = (attempts: number, error?: string): DictationStep[] =>
  Array.from({ length: attempts }, () => [
    ...(error ? [F(error)] : []),
    E(),
    A(RESTART_CAP),
  ]).flat();
const LISTENED = (steps: DictationStep[], endpointMs?: number): DictationScenario => ({
  name: "",
  steps,
  ...(endpointMs ? { endpointMs } : {}),
});

export const DICTATION_SCENARIOS: DictationScenario[] = [
  {
    ...LISTENED([A(29_999), A(1)], 30_000),
    name: "closes a mic that hears nothing within its own endpoint",
  },
  {
    ...LISTENED(
      [
        H("buy milk"),
        ...Array.from({ length: 3 }, () => [A(10_000), H("buy milk")]).flat(),
        A(10_000),
      ],
      30_000,
    ),
    name: "does not count a repeated result as new words against its own endpoint",
  },
  {
    ...LISTENED(
      [
        H("buy milk", true),
        ...Array.from({ length: 8 }, () => [E(), A(RESTART_CAP)]).flat(),
        A(30_000),
      ],
      30_000,
    ),
    name: "restarts through a quiet pause until its own endpoint ends it",
  },
  {
    ...LISTENED([H("buy milk", true), A(SILENCE * 5), H("and eggs"), { finish: true }], 30_000),
    name: "keeps listening through pauses shorter than its endpoint until finished",
  },
  {
    ...LISTENED([
      H("how is the"),
      H("how is the", true),
      A(SILENCE - 400),
      H("deploy going"),
      A(SILENCE - 1),
      A(1),
    ]),
    name: "ends the turn only after the silence window, not on the recognizer's own final",
  },
  {
    ...LISTENED([
      H("how is the"),
      SE(),
      H("how is the deploy going"),
      A(400),
      H("how is the deploy going", true),
      A(GRACE - 1),
      A(1),
    ]),
    name: "ends the turn a short grace after the recognizer reports the end of speech and its final",
  },
  {
    ...LISTENED([H("status please", true), A(100), SE(), A(GRACE - 1), A(1)]),
    name: "ends the turn a short grace after an end of speech that follows the final",
  },
  {
    ...LISTENED([H("buy milk"), SE(), H("buy milk", true), A(300), H("and"), A(SILENCE - 1), A(1)]),
    name: "waits the full silence window when the caller keeps talking after the final",
  },
  {
    ...LISTENED([SE(), H("buy milk", true), A(300), H("and eggs", true), A(SILENCE - 1), A(1)]),
    name: "waits the full silence window when a new phrase arrives straight as a final",
  },
  {
    ...LISTENED([
      H("buy milk"),
      SE(),
      H("buy milk", true),
      A(300),
      SS(),
      A(SILENCE - 300 - 1),
      A(1),
    ]),
    name: "waits the full silence window when the recognizer hears speech start again",
  },
  {
    ...LISTENED([
      SE(),
      H("buy milk", true),
      A(300),
      H("and eggs"),
      H("and eggs", true),
      A(GRACE),
      SE(),
      A(GRACE - 1),
      A(1),
    ]),
    name: "shortens the gap again once the next phrase also ends",
  },
  {
    ...LISTENED([H("status please", true), A(SILENCE - 1), A(1)]),
    name: "keeps the full silence window when the recognizer reports only a final",
  },
  {
    ...LISTENED([H("status please"), SE(), A(SILENCE - 1), A(1)]),
    name: "keeps the full silence window when the recognizer reports only the end of speech",
  },
  {
    ...LISTENED([SE(), H("status please", true), E(), A(SILENCE - 1), A(1)]),
    name: "keeps the full silence window when the recognizer reports both, then ends",
  },
  {
    ...LISTENED([H("buy"), SE(), H("buy milk", true), A(SILENCE * 5)], 30_000),
    name: "never shortens a pause limit the caller chose",
  },
  {
    ...LISTENED([A(QUIET - 1), A(1), E(), A(250)]),
    name: "restarts a session that reports nothing for too long",
  },
  {
    ...LISTENED(Array.from({ length: 3 }, () => [A(5_000), H("")]).flat()),
    name: "restarts a quiet session that keeps reporting empty results",
  },
  {
    ...LISTENED([A(QUIET - 100), H("still there"), A(100)]),
    name: "keeps a session that is hearing the caller",
  },
  {
    ...LISTENED([H("hello there"), E(), A(250), H("friend"), A(SILENCE)]),
    name: "restarts a session that ended mid-turn and carries the words already heard",
  },
  {
    ...LISTENED([H("half a sentence"), ...RESTARTS(6)]),
    name: "gives up after restarts that hear nothing",
  },
  { ...LISTENED([...RESTARTS(6), E()]), name: "notifies the caller when empty restarts give up" },
  {
    ...LISTENED([H("open the door"), F("not-allowed"), E(), A(RESTART_CAP)]),
    name: "notifies the caller when recognition is not allowed",
  },
  {
    ...LISTENED([F("no-speech"), E(), A(250)]),
    name: "restarts after a routine no-speech error without disabling recognition",
  },
  {
    ...LISTENED([F("network"), E(), A(250), H("status please"), A(SILENCE)]),
    name: "delivers a turn after a transient network error and restart",
  },
  {
    ...LISTENED(RESTARTS(6, "network")),
    name: "fails after empty restarts ending in transient errors",
  },
  {
    ...LISTENED([
      F("network"),
      E(),
      A(RESTART_CAP),
      ...Array.from({ length: 5 }, () => [F("no-speech"), E(), A(RESTART_CAP)]).flat(),
    ]),
    name: "stays idle after empty restarts even after an earlier transient error",
  },
  {
    ...LISTENED([{ startThrows: true }, E(), A(RESTART_CAP)]),
    name: "notifies the caller when start throws on restart",
  },
  {
    ...LISTENED([{ listen: "while loading" }]),
    name: "never starts the recognizer when the signal is cancelled while loading",
  },
  {
    ...LISTENED([H("cancel this"), { cancel: true }, H("and this", true), E(), A(10_000)]),
    name: "never finalizes a cancelled session",
  },
  {
    ...LISTENED([{ listen: "cancelled" }, H("still here"), A(SILENCE)]),
    name: "leaves a newer session running when a cancelled request arrives late",
  },
  {
    ...LISTENED([{ level: -2 }, { level: 5 }, { level: 12 }]),
    name: "reports the microphone's loudness to a caller that follows it",
  },
  {
    name: "dictation is unavailable when the recognizer is missing",
    available: false,
    steps: [{ available: true }],
  },
  {
    name: "dictation is unavailable when the microphone is refused",
    permission: "denied",
    steps: [{ available: true }],
  },
  {
    name: "dictation is unavailable when the permission cannot be read",
    permission: "throws",
    steps: [{ available: true }],
  },
];

// ── the composer's draft ──

/** One thing a draft case does, in this order: the microphone opens, the draft is edited, words
 *  arrive, the dictation is discarded. */
export interface DraftStep {
  open?: boolean;
  /** The draft as someone edits it meanwhile. */
  edit?: string;
  /** [words, final]: what the microphone heard live, or a provider's one final transcript. */
  words?: [string, boolean?];
  discard?: boolean;
}

export interface DraftSubject {
  /** The microphone opens on the draft as it is. */
  open(draft: string): void;
  /** The draft after words arrive; null when they are not written (live words over an edit, or no
   *  dictation open). */
  show(draft: string, words: string, final: boolean): string | null;
  /** True while the draft still shows exactly what the dictation put there. */
  owns(draft: string): boolean;
  close(): void;
}

/** Runs one draft case from an empty draft; each outcome is the draft as it then stands. */
export function runDraftCase(steps: DraftStep[], subject: DraftSubject): string[] {
  let draft = "";
  const out: string[] = [];
  for (const step of steps) {
    if (step.open) subject.open(draft);
    if (step.edit !== undefined) draft = step.edit;
    if (step.words !== undefined) {
      const next = subject.show(draft, step.words[0], step.words[1] ?? false);
      if (next !== null) draft = next;
    }
    if (step.discard) {
      if (subject.owns(draft)) draft = subject.show(draft, "", false) ?? draft;
      subject.close();
    }
    out.push(draft);
  }
  return out;
}

const OPEN = (): DraftStep => ({ open: true });
const SAYS = (words: string, final = false): DraftStep => ({ words: [words, final] });
const EDITED = (edit: string): DraftStep => ({ edit });
const DISCARD = (): DraftStep => ({ discard: true });

export const DRAFT_CASES: { name: string; steps: DraftStep[] }[] = [
  {
    name: "words follow the text the microphone opened on",
    steps: [EDITED("Hi"), OPEN(), SAYS("there")],
  },
  {
    name: "live words grow as the speaker talks",
    steps: [OPEN(), SAYS("buy"), SAYS("buy milk"), SAYS("buy milk and")],
  },
  {
    name: "the first word of an empty draft gets no space before it",
    steps: [OPEN(), SAYS("hello")],
  },
  {
    name: "an edit meanwhile drops the live words",
    steps: [EDITED("Note:"), OPEN(), SAYS("buy"), EDITED("Note: buy, please"), SAYS("buy milk")],
  },
  {
    name: "a provider's final transcript joins the edited text",
    steps: [EDITED("Note:"), OPEN(), EDITED("Edited:"), SAYS("buy milk", true)],
  },
  {
    name: "live words after that final go back to the text the microphone opened on",
    steps: [OPEN(), EDITED("Edit:"), SAYS("one", true), SAYS("two")],
  },
  {
    name: "a discard undoes the words and keeps what was typed before",
    steps: [EDITED("Hi"), OPEN(), SAYS("there"), DISCARD()],
  },
  {
    name: "a discard keeps an edit made meanwhile",
    steps: [EDITED("Hi"), OPEN(), SAYS("Hi there"), EDITED("my edit"), DISCARD()],
  },
  {
    name: "a discard after a final over an edit restores the text the microphone opened on",
    steps: [EDITED("Hi"), OPEN(), EDITED("x"), SAYS("y", true), DISCARD()],
  },
  {
    name: "words with no dictation open are dropped",
    steps: [EDITED("draft"), SAYS("a"), SAYS("b", true)],
  },
  { name: "a discard with no dictation open changes nothing", steps: [EDITED("draft"), DISCARD()] },
  {
    name: "a new dictation opens on the draft as it is then",
    steps: [OPEN(), SAYS("a"), DISCARD(), EDITED("z"), OPEN(), SAYS("b")],
  },
  {
    name: "each live result replaces the words of the one before",
    steps: [OPEN(), SAYS("a"), SAYS("a b"), SAYS("a b c")],
  },
  {
    name: "spaces at the end of the earlier text are trimmed once",
    steps: [EDITED("Hi   "), OPEN(), SAYS("you"), SAYS("you too")],
  },
  {
    name: "a final transcript after live words continues them",
    steps: [OPEN(), SAYS("one"), SAYS("two", true), SAYS("three", true)],
  },
];

/**
 * A clip player that follows the script. Every call is recorded, and a clip ends as soon as it
 * starts unless a hook stopped or paused it first. It answers expo-audio's player (the status
 * listener mobile's speech reads) and the port's player (a promise per clip) from one object, so
 * both sides see the same calls.
 */
export class ScriptedPlayer {
  private listener: ((status: Record<string, unknown>) => void) | null = null;
  private ended: (() => void) | null = null;
  /** Runs as the clip ends, before anything awaiting it goes on (the port's player lets go of
   *  the session's handle here, as mobile's own finish does). */
  onEnd: (() => void) | null = null;
  private readonly script: ScenarioScript;

  constructor(script: ScenarioScript) {
    this.script = script;
  }

  /** As expo-audio's player: the one status listener the speech session reads. */
  addListener = (
    _event: string,
    listener: (status: Record<string, unknown>) => void,
  ): { remove: () => void } => {
    this.listener = listener;
    return {
      remove: (): void => {
        this.listener = null;
      },
    };
  };

  play = (): void => {
    // Mobile's module learns that a clip ended from its expo-audio status listener; the port
    // awaits the clip. Whichever side is driving, the clip ends the moment it would start, and
    // only the mobile run logs the play its own listener made.
    if (this.listener) this.listener({ didJustFinish: true });
    else this.finishNow();
  };

  pause = (): void => {
    this.script.hit("player.pause");
  };

  release = (): void => undefined;

  /** As the port's player: resolves when the clip ended or was stopped. */
  playToEnd = (): Promise<void> =>
    new Promise<void>((resolve) => {
      this.ended = resolve;
    });

  /** Ends the clip now (what mobile's own finish does after a stop). */
  finishNow = (): void => {
    const ended = this.ended;
    this.ended = null;
    this.listener = null;
    this.onEnd?.();
    ended?.();
  };

  /** The handle a speech session pauses, resumes and stops the clip through. */
  handle = (): { pause(): void; resume(): void; stopNow(): void } => ({
    pause: this.pause,
    resume: this.play,
    stopNow: (): void => {
      this.pause();
      this.finishNow();
    },
  });
}
