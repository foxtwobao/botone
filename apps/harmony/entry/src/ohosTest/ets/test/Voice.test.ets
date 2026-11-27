// M7 hypium: the voice ports replay the layer-2 voice fixture on device — the speech playback
// and dictation state machines over scripted engines and a scripted recognizer with a fake
// clock, the composer's draft merge, the settings rules, the bot voices, the auto-speak gate —
// and the hosted transport runs against the offline fixture server's voice routes. Everything
// pure comes from the fixture (single source with the vitest replay); the state machines are the
// app's own modules, so this is the device-side half of the differential.
import { describe, expect, it } from '@ohos/hypium';
import { fixtureVoice } from './fixtures.generated';
import { arrayOf, boolField, numberField, recordOf, stableJson, stringField } from './test-utils';
import { speechLocaleTag, recognitionLocaleTag, supportedSpeechTag } from '../../../main/ets/voice/speech-locale';
import { speakable, splitSentences, toUtterances, speechFromBlocks } from '../../../main/ets/voice/speech-text';
import type { Blocks } from '../../../main/ets/thread/message-text';
import { nextAutoSpeakAction } from '../../../main/ets/voice/auto-speak';
import { resolveVoiceCallPlan } from '../../../main/ets/voice/voice-plan';
import type { VoicePlanDeps } from '../../../main/ets/voice/voice-plan';
import { pickUnusedVoice } from '../../../main/ets/voice/voice-assignment';
import { assignableDeviceVoices, chooseBotVoice } from '../../../main/ets/voice/bot-voices';
import type { ListedVoice } from '../../../main/ets/voice/bot-voices';
import * as dictationPort from '../../../main/ets/voice/dictation';
import type { DictationError, DictationResult, RecognizerEvents, RecognizerStartOptions } from '../../../main/ets/voice/dictation';
import * as deviceVoicePort from '../../../main/ets/voice/device-voice';
import * as speechPort from '../../../main/ets/voice/speech';
import type { SpeechOptions, SpeechQueueItem } from '../../../main/ets/voice/speech';
import { DraftDictation } from '../../../main/ets/voice/draft-dictation';
import { pickProvider, voiceConnectionForm } from '../../../main/ets/voice/voice-settings-model';
import { StopSignal } from '../../../main/ets/voice/stop-signal';
import { prepareSpeech, renderSpeech, transcribeRecording } from '../../../main/ets/voice/hosted-voice';
import { clearSessionToken, saveSessionToken, setSelectedSpace } from '../../../main/ets/net/session';
import { currentApiBase, initServerStore } from '../../../main/ets/net/server-store';
import { rpc, captureContext } from '../../../main/ets/net/rpc';
import type { VoiceCatalogView, VoiceCredentialView, VoiceStatusView } from '../../../main/ets/contract/decode-voice';

const BASE = 'http://10.0.2.2:8787';
const FAILURE = 'Voice engine unavailable';

/** One macrotask later: every microtask the scenario queued so far has run. */
async function settle(): Promise<void> {
  await new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, 0);
  });
}

/** A fixture entry as its own record, or null when the field is absent. */
function entry(record: Record<string, Object>, key: string): Record<string, Object> | null {
  const value = record[key];
  return value !== null && value !== undefined && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, Object> : null;
}

function fields(record: Record<string, Object>, key: string): Record<string, Object>[] {
  const value = record[key];
  if (!Array.isArray(value)) {
    return [];
  }
  const rows: Record<string, Object>[] = [];
  for (const item of value as Object[]) {
    if (item !== null && typeof item === 'object' && !Array.isArray(item)) {
      rows.push(item as Record<string, Object>);
    }
  }
  return rows;
}

/** The playback state as a comparable record: undefined fields are simply absent. */
function playbackRecord(state: speechPort.VoicePlaybackState): Record<string, Object> {
  const out: Record<string, Object> = {};
  out['status'] = state.status;
  out['canPause'] = state.canPause;
  if (state.botId !== undefined) {
    out['botId'] = state.botId;
  }
  if (state.messageId !== undefined) {
    out['messageId'] = state.messageId;
  }
  if (state.speaker !== undefined) {
    out['speaker'] = state.speaker;
  }
  return out;
}

// ── the fake clock, the scripted recognizer, and the dictation runner ──

interface ClockEntry {
  at: number;
  callback: () => void;
}

class FakeClock implements dictationPort.DictationTimers {
  now: number = 0;
  private nextId: number = 1;
  private due: Map<number, ClockEntry> = new Map();

  set = (callback: () => void, ms: number): number => {
    const id = this.nextId;
    this.nextId += 1;
    const timer: ClockEntry = { at: this.now + ms, callback: callback };
    this.due.set(id, timer);
    return id;
  };

  clear = (id: number): void => {
    this.due.delete(id);
  };

  /** Runs every timer due within `ms`, each at its own time, including ones they schedule. */
  advance(ms: number): void {
    const until = this.now + ms;
    for (;;) {
      let first: ClockEntry | null = null;
      let firstId = -1;
      for (const id of this.due.keys()) {
        const timer = this.due.get(id)!;
        if (timer.at <= until && (first === null || timer.at < first.at)) {
          first = timer;
          firstId = id;
        }
      }
      if (first === null) {
        break;
      }
      this.due.delete(firstId);
      this.now = first.at;
      first.callback();
    }
    this.now = until;
  }
}

interface DictationStep {
  advance?: number;
  hear?: [string, boolean];
  end?: boolean;
  fail?: string;
  speechStart?: boolean;
  speechEnd?: boolean;
  level?: number;
  finish?: boolean;
  cancel?: boolean;
  startThrows?: boolean;
  listen?: string;
  available?: boolean;
}

interface DictationScenarioInput {
  name: string;
  endpointMs?: number;
  available?: boolean;
  permission?: string;
  steps: DictationStep[];
}

/** Recognizer events in the shape the port's listen hands them over. */
type Routed = Record<string, (event: Object | null) => void>;

class FakeRecognizer implements dictationPort.SpeechRecognizer {
  private calls: Object[][] = [];
  private clock: FakeClock;
  private scenario: DictationScenarioInput;
  private routing: Routed | null = null;
  private throwNextStart = false;
  private live = true;

  constructor(calls: Object[][], clock: FakeClock, scenario: DictationScenarioInput) {
    this.calls = calls;
    this.clock = clock;
    this.scenario = scenario;
  }

  load = (): Promise<void> => Promise.resolve();

  start = (options: RecognizerStartOptions): void => {
    this.note('start', this.clock.now, options.lang, options.level);
    if (this.throwNextStart) {
      this.throwNextStart = false;
      throw new Error('recognizer unavailable');
    }
  };

  abort = (): void => {
    this.note('abort', this.clock.now);
  };

  isRecognitionAvailable = (): boolean => this.scenario.available ?? true;

  requestPermissions = (): Promise<boolean> => Promise.resolve(
    this.scenario.permission === undefined || this.scenario.permission === 'granted');

  listen = (events: RecognizerEvents): (() => void) => {
    const routed: Routed = {};
    routed['result'] = (event: Object | null): void => events.result(event as DictationResult);
    routed['end'] = (_event: Object | null): void => events.end();
    routed['error'] = (event: Object | null): void => events.error(event as DictationError);
    routed['speechstart'] = (_event: Object | null): void => events.speechStart();
    routed['speechend'] = (_event: Object | null): void => events.speechEnd();
    routed['level'] = (event: Object | null): void => events.level(event as number);
    this.routing = routed;
    return (): void => {
      if (this.routing === routed) {
        this.routing = null;
      }
    };
  };

  private note(name: string, ...args: Object[]): void {
    if (!this.live) {
      return;
    }
    const row: Object[] = [name];
    for (const arg of args) {
      row.push(arg);
    }
    this.calls.push(row);
  }

  /** False once the scenario moved on: the stop after it must not land in its log. */
  silence(): void {
    this.live = false;
  }

  nextStartThrows(): void {
    this.throwNextStart = true;
  }

  hear(transcript: string, isFinal: boolean): void {
    const event: DictationResult = { isFinal: isFinal, transcript: transcript };
    this.routing?.['result'](event as Object);
  }

  end(): void {
    this.routing?.['end'](null);
  }

  fail(error: string): void {
    const event: DictationError = { error: error };
    this.routing?.['error'](event as Object);
  }

  speechStart(): void {
    this.routing?.['speechstart'](null);
  }

  speechEnd(): void {
    this.routing?.['speechend'](null);
  }

  level(value: number): void {
    // The port's interface takes 0 to 1; the fixture's steps use the recognizer's own scale.
    this.routing?.['level'](Math.min(1, Math.max(0, value / 10)) as Object);
  }
}

interface DictationRun {
  calls: Object[][];
  events: Object[][];
}

/** The scenario before this one: its session is stopped once its own recognizer is silenced. */
let lastFake: FakeRecognizer | null = null;

async function runDictationScenario(scenario: DictationScenarioInput): Promise<DictationRun> {
  const calls: Object[][] = [];
  const events: Object[][] = [];
  const clock = new FakeClock();
  // The previous scenario's session is stopped with its own recognizer silenced, so that stop
  // is not logged into the new scenario's calls.
  lastFake?.silence();
  dictationPort.stop();
  lastFake = new FakeRecognizer(calls, clock, scenario);
  const fake = lastFake;
  dictationPort.setDictationTimers(clock);
  dictationPort.setSpeechRecognizer(fake);
  const at = (): number => clock.now;
  const followsLevel = scenario.steps.some((step: DictationStep): boolean => step.level !== undefined);
  const listen = async (kind: string): Promise<void> => {
    const controller = new StopSignal();
    if (kind === 'cancelled') {
      controller.cancel();
    }
    const options: dictationPort.DictationListenOptions = {
      onInterim: (text: string): void => {
        events.push(['interim', at(), text]);
      },
      onFinal: (text: string): void => {
        events.push(['final', at(), text]);
      },
      onGiveUp: (reason: string): void => {
        events.push(['giveUp', at(), reason]);
      },
      endpointMs: scenario.endpointMs,
      signal: controller,
    };
    if (followsLevel) {
      options.onLevel = (level: number): void => {
        events.push(['level', at(), level]);
      };
    }
    const pending = dictationPort.listen(options);
    if (kind === 'while loading') {
      controller.cancel();
    }
    await pending;
  };
  await listen('fresh');
  for (const step of scenario.steps) {
    if (step.listen !== undefined) {
      await listen(step.listen);
    }
    if (step.startThrows === true) {
      fake.nextStartThrows();
    }
    if (step.hear !== undefined) {
      fake.hear(step.hear[0], step.hear[1] ?? false);
    }
    if (step.end === true) {
      fake.end();
    }
    if (step.fail !== undefined) {
      fake.fail(step.fail);
    }
    if (step.speechStart === true) {
      fake.speechStart();
    }
    if (step.speechEnd === true) {
      fake.speechEnd();
    }
    if (step.level !== undefined) {
      fake.level(step.level);
    }
    if (step.finish === true) {
      dictationPort.finishListening();
    }
    if (step.cancel === true) {
      dictationPort.stop();
    }
    await settle();
    if (step.available !== undefined) {
      events.push(['available', at(), await dictationPort.available()]);
    }
    if (step.advance !== undefined) {
      clock.advance(step.advance);
      await settle();
    }
  }
  fake.silence();
  dictationPort.setDictationTimers(null);
  dictationPort.setSpeechRecognizer(null);
  return { calls: calls, events: events };

}

// ── the scripted clip player, the engines, and the speech runner ──

class ScriptedPlayer {
  private listener: ((status: Record<string, Object>) => void) | null = null;
  private ended: (() => void) | null = null;
  /** Runs as the clip ends, before anything awaiting it goes on. */
  onEnd: (() => void) | null = null;
  private hit: (name: string, ...args: Object[]) => void;

  constructor(hit: (name: string, ...args: Object[]) => void) {
    this.hit = hit;
  }

  addListener = (_event: string, listener: (status: Record<string, Object>) => void): ListenerHandle => {
    this.listener = listener;
    const handle: ListenerHandle = {
      remove: (): void => {
        this.listener = null;
      },
    };
    return handle;
  };

  play = (): void => {
    if (this.listener !== null) {
      const status: Record<string, Object> = {};
      status['didJustFinish'] = true;
      this.listener(status);
    } else {
      // The port awaits the clip: with no status listener of its own it ends right here,
      // without logging a play the recorded mobile run never made.
      this.finishNow();
    }
  };

  pause = (): void => {
    this.hit('player.pause');
  };

  release = (): void => undefined;

  playToEnd = (): Promise<void> =>
    new Promise<void>((resolve: () => void): void => {
      this.ended = resolve;
    });

  finishNow = (): void => {
    const ended = this.ended;
    this.ended = null;
    this.listener = null;
    this.onEnd?.();
    ended?.();
  };

  handle = (): speechPort.HostedPlayer => ({
    pause: this.pause,
    resume: this.play,
    stopNow: (): void => {
      this.pause();
      this.finishNow();
    },
  });
}

interface ListenerHandle {
  remove: () => void;
}

interface SpeechHook {
  on: string;
  nth: number;
  action: string;
  text?: string;
  botId?: string;
  later?: boolean;
}

interface SpeechScenarioInput {
  name: string;
  choice: string | null;
  statusReady: boolean;
  prepare: string[] | null;
  fail: Record<string, number>;
  hooks: SpeechHook[];
  queue: boolean;
  items: SpeechItem[];
}

interface SpeechItem {
  text: string;
  botId?: string;
}

/** The plan's status view as the fixture carries it. */
interface PlanStatus {
  ready: boolean;
  transcribe: boolean;
}

interface SpeechResult {
  value?: boolean;
  error?: string;
}

interface SpeechRun {
  calls: Object[][];
  states: Object[];
  results: SpeechResult[];
}

async function runSpeechScenario(scenario: SpeechScenarioInput): Promise<SpeechRun> {
  const calls: Object[][] = [];
  const states: Object[] = [];
  const results: SpeechResult[] = [];
  const counts: Record<string, number> = {};
  let choice: string | null = null;
  let statusReady = false;
  /** What a stop hook can cut: the utterance the device is saying right now. */
  let pendingDevice: (() => void) | null = null;
  const hit = (name: string, ...args: Object[]): void => {
    const row: Object[] = [name];
    for (const arg of args) {
      row.push(arg);
    }
    calls.push(row);
    counts[name] = (counts[name] ?? 0) + 1;
    for (const hook of scenario.hooks) {
      if (hook.on === name && hook.nth === counts[name]) {
        if (hook.later === true) {
          void Promise.resolve().then((): void => {
            act(hook);
          });
        } else {
          act(hook);
        }
      }
    }
  };
  const act = (hook: SpeechHook): void => {
    if (hook.action === 'stop') {
      speechPort.stopVoicePlayback();
    } else if (hook.action === 'pause') {
      speechPort.pauseVoicePlayback();
    } else if (hook.action === 'resume') {
      speechPort.resumeVoicePlayback();
    } else if (hook.action === 'session') {
      speechPort.noteSessionChanged();
    } else if (hook.action === 'speak') {
      const options: SpeechOptions = {};
      if (hook.botId !== undefined) {
        options.botId = hook.botId;
        options.speaker = { name: 'Speaker', color: '#102030' };
      }
      track(speechPort.speakText(hook.text ?? '', options));
    }
  };
  const track = (speaking: Promise<boolean>): void => {
    void speaking.then(
      (value: boolean): void => {
        const found: SpeechResult = { value: value };
        results.push(found);
      },
      (error: Object): void => {
        const message = (error as Error).message;
        const found: SpeechResult = { error: String(message ?? error) };
        results.push(found);
      },
    );
  };
  deviceVoicePort.setDeviceVoiceStore({
    get: async (_key: string): Promise<string | null> => {
      hit('deviceVoice');
      if (choice === 'throws') {
        throw new Error('device locked');
      }
      return choice;
    },
    put: async (_key: string, value: string): Promise<void> => {
      hit('saveChoice', value);
      choice = value;
    },
  });
  deviceVoicePort.setVoiceStatusReader(async (): Promise<boolean> => {
    hit('status');
    return statusReady;
  });
  const renders = (): number => calls.filter((row: Object[]): boolean => row[0] === 'render').length;
  const engines: speechPort.SpeechEngines = {
    captureContext: async (): Promise<speechPort.SpeechContext> => {
      hit('capture');
      return { apiBase: 'https://api.example', generation: 1, selectionGeneration: 1, headers: {} };
    },
    deviceVoiceEnabled: (): Promise<boolean> => deviceVoicePort.loadDeviceVoiceEnabled(),
    deviceVoiceFor: async (botId: string): Promise<string | undefined> => {
      hit('deviceVoiceFor', botId);
      return `voice-${botId}`;
    },
    deviceCanPause: (): boolean => true,
    stopDevice: (): void => {
      hit('deviceStop');
      pendingDevice?.();
      pendingDevice = null;
    },
    pauseDevice: (): void => {
      hit('device.pause');
    },
    resumeDevice: (): void => {
      hit('device.resume');
    },
    speakOnDevice: (utterance: string, voice: string | undefined): Promise<void> =>
      new Promise<void>((resolve: () => void): void => {
        let stopped = false;
        pendingDevice = (): void => {
          stopped = true;
          resolve();
        };
        hit('deviceSpeak', utterance, voice ?? '');
        if (!stopped) {
          pendingDevice = null;
          resolve();
        }
      }),
    prepare: async (text: string, options: SpeechOptions): Promise<string[] | null> => {
      hit('prepare', text, options.botId ?? '');
      if (scenario.fail['prepare'] === counts['prepare']) {
        throw new Error(FAILURE);
      }
      return scenario.prepare;
    },
    render: async (utterance: string): Promise<Uint8Array> => {
      hit('render', utterance);
      if (scenario.fail['render'] === renders()) {
        throw new Error(FAILURE);
      }
      return new Uint8Array([1, 2, 3]);
    },
    playClip: (_bytes: Uint8Array, session: speechPort.HostedSession): Promise<void> => {
      const player = new ScriptedPlayer(hit);
      player.onEnd = (): void => session.setPlayer(null);
      const ended = player.playToEnd();
      session.setPlayer(player.handle());
      if (session.isStopped) {
        player.finishNow();
        return Promise.resolve();
      }
      if (session.isPaused) {
        return ended;
      }
      // Neither side has a status listener of its own in this replay: the fake player ends the
      // clip the moment it would start, so the port's await settles.
      player.play();
      return ended;
    },
  };
  speechPort.setSpeechEngines(engines);
  choice = scenario.choice;
  statusReady = scenario.statusReady;
  await speechPort.stopVoicePlayback();
  speechPort.noteSessionChanged();
  const unsubscribe = speechPort.subscribeVoicePlayback((): void => {
    states.push(playbackRecord(speechPort.getVoicePlaybackState()));
  });
  const spoken: SpeechQueueItem[] = scenario.items.map((item): SpeechQueueItem => {
    const queued: SpeechQueueItem = { text: item.text };
    if (item.botId !== undefined) {
      queued.botId = item.botId;
      queued.speaker = { name: 'Speaker', color: '#102030' };
    }
    return queued;
  });
  track(scenario.queue
    ? speechPort.speakQueue(spoken)
    : speechPort.speakText(spoken[0]!.text, spoken[0]!));
  await settle();
  await settle();
  unsubscribe();
  speechPort.setSpeechEngines(null);
  deviceVoicePort.setDeviceVoiceStore(null);
  deviceVoicePort.setVoiceStatusReader(null);
  return { calls: calls, states: states, results: results };
}

// ── the replayed fixture ──

const fixture: Record<string, Object> = JSON.parse(fixtureVoice) as Record<string, Object>;

function section(name: string): Object[] {
  return arrayOf(JSON.stringify(fixture[name]));
}

/** Records an array of arrays, as the calls/events/steps sections hold. */
function rowsOf(json: string): Object[][] {
  const rows: Object[][] = [];
  for (const row of arrayOf(json)) {
    const values: Object[] = [];
    for (const value of row as Object[]) {
      values.push(value);
    }
    rows.push(values);
  }
  return rows;
}

export default function voiceTest() {
  describe('VoicePortFixture', () => {
    it('locale tags agree with the fixture', 0, () => {
      // locales is the one object section of the fixture: its three lists hang off one record.
      const locales = fixture['locales'] as Record<string, Object>;
      for (const item of fields(locales, 'tags')) {
          expect(speechLocaleTag(stringField(item, 'locale'))).assertEqual(stringField(item, 'expected'));
        }
    });

    it('recognition locales agree with the fixture', 0, () => {
      // locales is the one object section of the fixture: its three lists hang off one record.
      const locales = fixture['locales'] as Record<string, Object>;
      for (const item of fields(locales, 'recognition')) {
          const speaker = item['speaker'];
          expect(recognitionLocaleTag(stringField(item, 'locale'),
            typeof speaker === 'string' ? speaker as string : null)).assertEqual(stringField(item, 'expected'));
        }
    });

    it('supported speech tags agree with the fixture', 0, () => {
      // locales is the one object section of the fixture: its three lists hang off one record.
      const locales = fixture['locales'] as Record<string, Object>;
      for (const item of fields(locales, 'supported')) {
          expect(supportedSpeechTag(stringField(item, 'wanted'),
            JSON.parse(JSON.stringify(item['supported'])) as string[])).assertEqual(stringField(item, 'expected'));
        }
    });

    it('speakable text and utterances agree with the fixture', 0, () => {
      for (const row of section('speakable')) {
        const record = row as Record<string, Object>;
        expect(speakable(stringField(record, 'input'))).assertEqual(stringField(record, 'expected'));
      }
      for (const row of section('sentences')) {
        const record = row as Record<string, Object>;
        expect(stableJson(splitSentences(stringField(record, 'input'))))
          .assertEqual(stableJson(JSON.parse(JSON.stringify(record['expected']))));
      }
      for (const row of section('utterances')) {
        const record = row as Record<string, Object>;
        expect(stableJson(toUtterances(stringField(record, 'input'))))
          .assertEqual(stableJson(JSON.parse(JSON.stringify(record['expected']))));
      }
      for (const row of section('blockSpeech')) {
        const record = row as Record<string, Object>;
        const blocks = JSON.parse(JSON.stringify(record['blocks'])) as Blocks;
        expect(speechFromBlocks(blocks)).assertEqual(stringField(record, 'expected'));
      }
    });

    it('the auto-speak gate agrees with the fixture', 0, () => {
      for (const row of section('autoSpeak')) {
        const record = row as Record<string, Object>;
        const input = record['input'];
        expect(stableJson(nextAutoSpeakAction(JSON.parse(JSON.stringify(input)) as never)))
          .assertEqual(stableJson(record['expected']));
      }
    });

    it('the voice plan agrees with the fixture', 0, async () => {
      const statuses: Record<string, PlanStatus> = {};
      const ready: PlanStatus = { ready: true, transcribe: false };
      const transcribes: PlanStatus = { ready: true, transcribe: true };
      const neither: PlanStatus = { ready: false, transcribe: false };
      const only: PlanStatus = { ready: false, transcribe: true };
      statuses['ready'] = ready;
      statuses['transcribes'] = transcribes;
      statuses['neither'] = neither;
      statuses['transcribe only'] = only;
      for (const row of section('plan')) {
        const record = row as Record<string, Object>;
        const name = stringField(record, 'name');
        const device = name.includes('device on') ? 'on' : name.includes('device throws') ? 'throws' : 'off';
        const available = !name.includes('recognizer off') && !name.includes('recognizer false');
        const status = statuses[name.endsWith('status fails') ? 'neither' : name.split(', ').pop()!] ?? neither;
        const deps: VoicePlanDeps = {
          loadDeviceVoiceEnabled: async (): Promise<boolean> => {
            if (device === 'throws') {
              throw new Error('unreadable');
            }
            return device === 'on';
          },
          dictationAvailable: async (): Promise<boolean> => available,
          loadVoiceStatus: async (): Promise<PlanStatus> => {
            if (name.endsWith('status fails')) {
              throw new Error('offline');
            }
            return status;
          },
        };
        // A status read that fails is the plan's answer too: it rejects to the caller.
        let plan: Object;
        try {
          plan = await resolveVoiceCallPlan(deps,
            name.startsWith('dictation') ? 'dictation' : 'call');
        } catch (err) {
          const failure: Record<string, Object> = {};
          failure['error'] = (err as Error).message;
          plan = failure;
        }
        expect(stableJson(plan)).assertEqual(stableJson(record['expected']));
      }
    });

    it('voice assignment and bot voices agree with the fixture', 0, () => {
      for (const row of section('assignment')) {
        const record = row as Record<string, Object>;
        const voices = JSON.parse(JSON.stringify(record['voices'])) as string[];
        const taken = JSON.parse(JSON.stringify(record['taken'])) as string[];
        const picked = JSON.parse(JSON.stringify(record['picked'])) as string[];
        const bots = ['bot-a', 'bot-b', 'bot-c', 'bot-d', 'late-bot'];
        const held: Set<string> = new Set(taken);
        for (let index = 0; index < picked.length; index += 1) {
          expect(pickUnusedVoice(voices, held, bots[index] ?? 'late-bot')).assertEqual(picked[index]);
          held.add(picked[index]);
        }
      }
      for (const row of section('botVoices')) {
        const record = row as Record<string, Object>;
        const listed: ListedVoice[] = [];
        // Android's own clause (explicitly local voices only) applies here, as on that platform.
        const all = record['platform'] === 'android'
          ? fields(record, 'voices').filter((item: Record<string, Object>): boolean => /-local$/i.test(stringField(item, 'identifier')))
          : fields(record, 'voices');
        for (const item of all) {
          const voice: ListedVoice = {
            identifier: stringField(item, 'identifier'),
            language: stringField(item, 'language'),
          };
          if (typeof item['name'] === 'string') {
            voice.name = item['name'] as string;
          }
          if (typeof item['localService'] === 'boolean') {
            voice.localService = item['localService'] as boolean;
          }
          if (typeof item['requiresNetwork'] === 'boolean') {
            voice.requiresNetwork = item['requiresNetwork'] as boolean;
          }
          if (typeof item['quality'] === 'string') {
            voice.quality = item['quality'] as string;
          }
          listed.push(voice);
        }
        const available = assignableDeviceVoices(listed,
          stringField(record, 'locale').split('-')[0]!.toLowerCase());
        expect(stableJson(available.map((voice: ListedVoice): string => voice.identifier)))
          .assertEqual(stableJson(record['listed']));
        const assignments: Record<string, string> = {};
        const results: Array<string | null> = [];
        for (const botId of JSON.parse(JSON.stringify(record['bots'])) as string[]) {
          const voice = chooseBotVoice(available, assignments, botId,
            stringField(record, 'locale').toLowerCase(),
            stringField(record, 'region').toLowerCase() || null);
          if (voice !== undefined) {
            assignments[botId] = voice;
          }
          results.push(voice ?? null);
        }
        expect(stableJson(results)).assertEqual(stableJson(record['picked']));
      }
    });

    it('dictated words land in the draft by the recorded rule', 0, () => {
      for (const row of section('draft')) {
        const record = row as Record<string, Object>;
        const rule = new DraftDictation();
        let draft = '';
        const expected = JSON.parse(JSON.stringify(record['expected'])) as string[];
        for (const step of fields(record, 'steps')) {
          if (step['open'] === true) {
            rule.open(draft);
          } else if (typeof step['edit'] === 'string') {
            draft = step['edit'] as string;
          } else if (Array.isArray(step['words'])) {
            const words = step['words'] as Object[];
            const next = rule.show(draft, words[0] as string, words[1] === true);
            if (next !== null) {
              draft = next;
            }
          } else if (step['discard'] === true) {
            if (rule.owns(draft)) {
              draft = rule.show(draft, '', false) ?? draft;
            }
            rule.close();
          }
        }
        expect(draft).assertEqual(expected[expected.length - 1]);
      }
    });

    it('the settings rules agree with the fixture', 0, () => {
      for (const row of section('settingsForm')) {
        const record = row as Record<string, Object>;
        const input = record['input'] as Record<string, Object>;
        const form = voiceConnectionForm({
          entry: input['entry'] === null || input['entry'] === undefined
            ? undefined : JSON.parse(JSON.stringify(input['entry'])) as VoiceCatalogView,
          credential: input['credential'] === null || input['credential'] === undefined
            ? undefined : JSON.parse(JSON.stringify(input['credential'])) as VoiceCredentialView,
          apiKey: stringField(input, 'apiKey'),
          baseUrl: stringField(input, 'baseUrl'),
        });
        expect(stableJson(form)).assertEqual(stableJson(record['expected']));
      }
      for (const row of section('pickProvider')) {
        const record = row as Record<string, Object>;
        const input = record['input'] as Record<string, Object>;
        const catalog = JSON.parse(JSON.stringify(input['catalog'])) as VoiceCatalogView[];
        const status: VoiceStatusView = {
          configured: false, ready: false, transcribe: false, voiceId: '',
          provider: input['inUse'] === null ? null : input['inUse'] as string,
        };
        const asked = input['asked'] === null || input['asked'] === undefined
          ? undefined : input['asked'] as string;
        expect(pickProvider(catalog, status, asked)).assertEqual(record['expected'] as string);
      }
    });

    it('speech playback follows the recorded engine calls, states and outcomes', 0, async () => {
      for (const row of section('speech')) {
        const record = row as Record<string, Object>;
        const scenario = decodeSpeechScenario(record['scenario'] as Record<string, Object>);
        const run = await runSpeechScenario(scenario);
        const expected = record['run'] as Record<string, Object>;
        expect(stableJson(run.calls)).assertEqual(stableJson(expected['calls']));
        expect(stableJson(run.states)).assertEqual(stableJson(expected['states']));
        expect(stableJson(run.results)).assertEqual(stableJson(expected['results']));
      }
    });

    it('the dictation session follows the recorded recognizer calls and caller events', 0, async () => {
      for (const row of section('dictation')) {
        const record = row as Record<string, Object>;
        const scenario = decodeDictationScenario(record['scenario'] as Record<string, Object>);
        const run = await runDictationScenario(scenario);
        expect(stableJson(run.calls)).assertEqual(stableJson(record['calls']));
        expect(stableJson(run.events)).assertEqual(stableJson(record['events']));
      }
    });
  });
}
/** A speech scenario as the fixture carries it, next to its recorded run. */
function decodeSpeechScenario(record: Record<string, Object>): SpeechScenarioInput {
  const fail: Record<string, number> = {};
  for (const key of Object.keys(record['fail'] as Record<string, Object>)) {
    const value = (record['fail'] as Record<string, Object>)[key];
    fail[key] = typeof value === 'number' ? value as number : 0;
  }
  const hooks: SpeechHook[] = [];
  for (const item of fields(record, 'hooks')) {
    const hook: SpeechHook = {
      on: stringField(item, 'on'),
      nth: numberField(item, 'nth'),
      action: stringField(item, 'action'),
    };
    if (typeof item['text'] === 'string') {
      hook.text = item['text'] as string;
    }
    if (typeof item['botId'] === 'string') {
      hook.botId = item['botId'] as string;
    }
    if (item['later'] === true) {
      hook.later = true;
    }
    hooks.push(hook);
  }
  const items: SpeechItem[] = [];
  for (const item of fields(record, 'items')) {
    const entry: SpeechItem = { text: stringField(item, 'text') };
    if (typeof item['botId'] === 'string') {
      entry.botId = item['botId'] as string;
    }
    items.push(entry);
  }
  const choice = record['choice'];
  const scenario: SpeechScenarioInput = {
    name: stringField(record, 'name'),
    choice: choice === null ? null : choice as string,
    statusReady: record['statusReady'] === true,
    prepare: record['prepare'] === null ? null : JSON.parse(JSON.stringify(record['prepare'])) as string[],
    fail: fail,
    hooks: hooks,
    queue: record['queue'] === true,
    items: items,
  };
  return scenario;
}

/** A dictation scenario as the fixture carries it, next to its recorded run. */
function decodeDictationScenario(record: Record<string, Object>): DictationScenarioInput {
  const steps: DictationStep[] = [];
  for (const item of fields(record, 'steps')) {
    const step: DictationStep = {};
    if (typeof item['advance'] === 'number') {
      step.advance = item['advance'] as number;
    }
    if (Array.isArray(item['hear'])) {
      const hear = item['hear'] as Object[];
      step.hear = [hear[0] as string, hear[1] === true];
    }
    if (item['end'] === true) {
      step.end = true;
    }
    if (typeof item['fail'] === 'string') {
      step.fail = item['fail'] as string;
    }
    if (item['speechStart'] === true) {
      step.speechStart = true;
    }
    if (item['speechEnd'] === true) {
      step.speechEnd = true;
    }
    if (typeof item['level'] === 'number') {
      step.level = item['level'] as number;
    }
    if (item['finish'] === true) {
      step.finish = true;
    }
    if (item['cancel'] === true) {
      step.cancel = true;
    }
    if (item['startThrows'] === true) {
      step.startThrows = true;
    }
    if (typeof item['listen'] === 'string') {
      step.listen = item['listen'] as string;
    }
    if (typeof item['available'] === 'boolean') {
      step.available = item['available'] as boolean;
    }
    steps.push(step);
  }
  const scenario: DictationScenarioInput = {
    name: stringField(record, 'name'),
    steps: steps,
  };
  if (typeof record['endpointMs'] === 'number') {
    scenario.endpointMs = record['endpointMs'] as number;
  }
  if (typeof record['available'] === 'boolean') {
    scenario.available = record['available'] as boolean;
  }
  if (typeof record['permission'] === 'string') {
    scenario.permission = record['permission'] as string;
  }
  return scenario;
}
