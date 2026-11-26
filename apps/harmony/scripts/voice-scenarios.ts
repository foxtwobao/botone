// The runner of the scripted scenarios for the two speech state machines, the read-aloud playback
// and the dictation session: the subjects the mobile module and the ArkTS port each sit behind,
// the fake clock and the fake recognizer both sides share, and the clip player the port's player
// and the script's status listener answer at once. A scenario names the engine calls it fails at
// and the actions it takes when a call happens, so both sides see the same sequence. The
// scenarios themselves live in voice-scenario-list.ts. Dev-time code: nothing here ships.

export interface SpeechItem {
  text: string;
  botId?: string;
}

/** An action taken while a scenario runs, when a named call happens for the nth time. */
export interface SpeechHook {
  on: string;
  nth: number;
  /** stop | pause | resume | session (what the app does when the session changes) | speak */
  action: string;
  text?: string;
  botId?: string;
  /** True to act once the call this hook hangs on has returned (a second tap, not one inside the first). */
  later?: boolean;
}

export interface SpeechScenario {
  name: string;
  /** What the saved device-voice choice reads: "1" on, "0" off, null never chosen, "throws" unreadable. */
  choice: string | null;
  /** Whether the server's voice is ready (it decides the default when nothing was chosen). */
  statusReady: boolean;
  /** What voice/prepare answers: the utterances, or null for "no voice is set up". */
  prepare: string[] | null;
  /** The 1-based occurrence of a call that fails. */
  fail: Record<string, number>;
  hooks: SpeechHook[];
  /** True to queue the items (speakQueue), false to speak the first alone (speakText). */
  queue: boolean;
  items: SpeechItem[];
}

/** What the fakes of a running scenario share: the call log and the hooks. */
export interface ScenarioScript {
  hit(name: string, ...args: unknown[]): void;
  /** True when the call just recorded is the one the scenario fails. */
  fails(name: string): boolean;
}

export interface SpeechSubject {
  /** Clears module state and installs the scripted engines (storage, server voice, players). */
  reset(scenario: SpeechScenario, script: ScenarioScript): Promise<void>;
  subscribe(listener: () => void): () => void;
  speak(items: SpeechItem[], queue: boolean): Promise<boolean>;
  stop(): void;
  pause(): void;
  resume(): void;
  /** What the app does when the session changes (stop playback, forget the speaker). */
  sessionChange(): void;
  /** Runs `callback` once the current call stack has unwound. */
  later(callback: () => void): void;
  state(): unknown;
  /** Lets every callback the scenario queued so far run. */
  settle(): Promise<void>;
}

export interface ScenarioRun {
  /** [call, ...args]: every engine call in order. */
  calls: unknown[][];
  /** The playback state after each change. */
  states: unknown[];
  /** Each speak's outcome, in the order they settled. */
  results: Array<{ value?: boolean; error?: string }>;
}

const FAILURE = "Voice engine unavailable";

/** The failure a scripted engine throws; a human message, so the module passes it through. */
export function engineFailure(): Error {
  return new Error(FAILURE);
}

export async function runSpeechScenario(
  scenario: SpeechScenario,
  subject: SpeechSubject,
): Promise<ScenarioRun> {
  const calls: unknown[][] = [];
  const states: unknown[] = [];
  const results: ScenarioRun["results"] = [];
  const counts: Record<string, number> = {};
  const track = (speaking: Promise<boolean>): void => {
    void speaking.then(
      (value) => {
        results.push({ value });
      },
      (error: unknown) => {
        results.push({ error: String((error as { message?: unknown } | null)?.message ?? error) });
      },
    );
  };
  const now = (hook: SpeechHook): void => {
    if (hook.action === "stop") subject.stop();
    else if (hook.action === "pause") subject.pause();
    else if (hook.action === "resume") subject.resume();
    else if (hook.action === "session") subject.sessionChange();
    else if (hook.action === "speak")
      track(subject.speak([{ text: hook.text ?? "", botId: hook.botId }], false));
  };
  const script: ScenarioScript = {
    hit(name: string, ...args: unknown[]): void {
      calls.push([name, ...args]);
      counts[name] = (counts[name] ?? 0) + 1;
      for (const hook of scenario.hooks) {
        if (hook.on === name && hook.nth === counts[name]) {
          if (hook.later) subject.later((): void => now(hook));
          else now(hook);
        }
      }
    },
    fails(name: string): boolean {
      return scenario.fail[name] === counts[name];
    },
  };
  await subject.reset(scenario, script);
  const unsubscribe = subject.subscribe(() => {
    states.push(subject.state());
  });
  track(subject.speak(scenario.items, scenario.queue));
  await subject.settle();
  unsubscribe();
  return { calls, states, results };
}

// ── dictation ──

/** One thing a step does. `advance` runs last, after the action, when a step has both. */
export interface DictationStep {
  advance?: number;
  /** A result: [transcript, final]. */
  hear?: [string, boolean?];
  end?: boolean;
  fail?: string;
  speechStart?: boolean;
  speechEnd?: boolean;
  /** The microphone's loudness on the recognizer's own scale (-2 to 10). */
  level?: number;
  finish?: boolean;
  /** Cancels the signal of the running listen. */
  cancel?: boolean;
  /** Makes the recognizer's next start throw. */
  startThrows?: boolean;
  /** Starts another listen: on a fresh signal, an already-cancelled one, or one cancelled while loading. */
  listen?: "fresh" | "cancelled" | "while loading";
  /** Records whether dictation is available. */
  available?: boolean;
}

export interface DictationScenario {
  name: string;
  endpointMs?: number;
  available?: boolean;
  permission?: "granted" | "denied" | "throws";
  steps: DictationStep[];
}

export interface DictationSubject {
  /** Clears module state and installs the fake recognizer and clock; the caller's events go to `events`. */
  reset(
    scenario: DictationScenario,
    script: ScenarioScript,
    clock: FakeClock,
    events: unknown[][],
  ): Promise<void>;
  listen(signal: "fresh" | "cancelled" | "while loading"): Promise<void>;
  cancel(): void;
  finish(): void;
  hear(transcript: string, isFinal: boolean): void;
  end(): void;
  fail(error: string): void;
  speechStart(): void;
  speechEnd(): void;
  level(value: number): void;
  available(): Promise<boolean>;
  nextStartThrows(): void;
  settle(): Promise<void>;
}

export interface DictationRun {
  /** [start|abort, at ms, and for start its lang and whether it follows the level]. */
  calls: unknown[][];
  /** [interim|final|giveUp|level|available, at ms, the text, the reason or the value]. */
  events: unknown[][];
}

export const QUIET = 15_000;
export const SILENCE = 1_200;
export const GRACE = 500;
export const RESTART_CAP = 2_000;

/** A scripted clock: the scenario advances it and the due timers run in order. */
export class FakeClock {
  now = 0;
  private nextId = 1;
  private due = new Map<number, { at: number; callback: () => void }>();

  set = (callback: () => void, ms: number): number => {
    const id = this.nextId++;
    this.due.set(id, { at: this.now + ms, callback });
    return id;
  };

  clear = (id: number): void => {
    this.due.delete(id);
  };

  /** Runs every timer due within `ms`, each at its own time, including ones they schedule. */
  advance(ms: number): void {
    const until = this.now + ms;
    for (;;) {
      let first: { id: number; at: number } | null = null;
      for (const [id, timer] of this.due) {
        if (timer.at <= until && (first === null || timer.at < first.at))
          first = { id, at: timer.at };
      }
      if (first === null) break;
      const timer = this.due.get(first.id)!;
      this.due.delete(first.id);
      this.now = timer.at;
      timer.callback();
    }
    this.now = until;
  }
}

/** Recognizer events in the shape mobile's dictation module registers for. */
type MobileListener = (payload: never) => void;

/**
 * The recognizer every side of a dictation scenario talks to. It answers the mobile module's
 * interface (addListener and emitted events) and the port's (load and listen) at once, and logs
 * through the scenario's script: start and abort, each with the clock's time (the port hands the
 * port's listen its handlers for each session and takes them back afterwards, where the mobile
 * module keeps one listener set, so that taking-back is not logged). The port's interface takes
 * the loudness as 0 to 1, so for it the raw scale is converted here, where the device engine's
 * adapter does it in the app.
 */
export function createFakeRecognizer(
  script: ScenarioScript,
  clock: FakeClock,
  scenario: DictationScenario,
  portStyle: boolean,
) {
  const listeners = new Map<string, Set<MobileListener>>();
  let routing: Record<string, MobileListener> | null = null;
  let throwNextStart = false;
  // False once the scenario moved on: the session it belonged to is stopped after that, and
  // that stop must not land in the finished scenario's log.
  let live = true;
  const note = (name: string, ...args: unknown[]): void => {
    if (live) script.hit(name, ...args);
  };
  const emit = (event: string, payload: unknown): void => {
    for (const listener of [...(listeners.get(event) ?? [])])
      (listener as (p: unknown) => void)(payload);
    routing?.[event]?.(payload as never);
  };
  const request = async (): Promise<{ granted: boolean }> => {
    if (scenario.permission === "throws") throw new Error("Permissions unavailable");
    return { granted: (scenario.permission ?? "granted") === "granted" };
  };
  const recognizer = {
    load: async (): Promise<void> => undefined,
    start: (options: unknown): void => {
      const typed = options as {
        lang: string;
        level?: boolean;
        volumeChangeEventOptions?: unknown;
      };
      note(
        "start",
        clock.now,
        typed.lang,
        typed.level ?? typed.volumeChangeEventOptions !== undefined,
      );
      if (throwNextStart) {
        throwNextStart = false;
        throw new Error("recognizer unavailable");
      }
    },
    abort: (): void => {
      note("abort", clock.now);
    },
    listen(events: Record<string, MobileListener>): () => void {
      routing = events;
      return (): void => {
        if (routing === events) routing = null;
      };
    },
    stop: (): void => undefined,
    isRecognitionAvailable: (): boolean => scenario.available ?? true,
    requestPermissions: async (): Promise<boolean> => (await request()).granted,
    requestPermissionsAsync: request,
    getSupportedLocales: async (): Promise<{ locales: string[] }> => ({ locales: [] }),
    addListener: (event: string, listener: MobileListener): { remove: () => void } => {
      const set = listeners.get(event) ?? new Set<MobileListener>();
      set.add(listener);
      listeners.set(event, set);
      return {
        remove: (): void => {
          set.delete(listener);
        },
      };
    },
  };
  return {
    recognizer,
    nextStartThrows: (): void => {
      throwNextStart = true;
    },
    silence: (): void => {
      live = false;
    },
    hear: (transcript: string, isFinal = false): void => {
      if (portStyle) routing?.result?.({ isFinal, transcript } as never);
      else emit("result", { isFinal, results: [{ transcript, confidence: 0.9 }] });
    },
    end: (): void => emit("end", null),
    fail: (error: string): void => emit("error", { error }),
    speechStart: (): void => emit("speechstart", null),
    speechEnd: (): void => emit("speechend", null),
    level: (value: number): void => {
      if (portStyle) routing?.level?.(Math.min(1, Math.max(0, value / 10)) as never);
      else emit("volumechange", { value });
    },
  };
}

export async function runDictationScenario(
  scenario: DictationScenario,
  subject: DictationSubject,
): Promise<DictationRun> {
  const calls: unknown[][] = [];
  const events: unknown[][] = [];
  const clock = new FakeClock();
  const script: ScenarioScript = {
    hit: (name: string, ...args: unknown[]): void => {
      calls.push([name, ...args]);
    },
    fails: (): boolean => false,
  };
  await subject.reset(scenario, script, clock, events);
  // Each listen is told about its caller the same way: what it heard, when, and how it ended.
  const listen = async (signal: "fresh" | "cancelled" | "while loading"): Promise<void> => {
    await subject.listen(signal);
    await subject.settle();
  };
  await listen("fresh");
  for (const step of scenario.steps) {
    if (step.listen) await listen(step.listen);
    if (step.startThrows) subject.nextStartThrows();
    if (step.hear) subject.hear(step.hear[0], step.hear[1] ?? false);
    if (step.end) subject.end();
    if (step.fail) subject.fail(step.fail);
    if (step.speechStart) subject.speechStart();
    if (step.speechEnd) subject.speechEnd();
    if (step.level !== undefined) subject.level(step.level);
    if (step.finish) subject.finish();
    if (step.cancel) subject.cancel();
    await subject.settle();
    if (step.available !== undefined)
      events.push(["available", clock.now, await subject.available()]);
    if (step.advance) {
      clock.advance(step.advance);
      await subject.settle();
    }
  }
  return { calls, events };
}
