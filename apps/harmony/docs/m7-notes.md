# M7 notes — 语音Ⅰ：听写、朗读、bot 声音设置

Started on `origin/harmony/m6-attachments` `213c2cd95` (the M6 fix push). Scope, design §7.2 M7:
dictation into the composer, read-aloud from a message, the bot's device voice, and the Voice
settings page. Decisions were written down before any code in [m7-scope.md](m7-scope.md); this
file records what shipped, what the device showed, and what the scope could not cover.

**Status: verified on the emulator.** Hypium 190/190, the capability probe's findings hold in the
shipped code, every walkthrough row measured, 14 captures.

## What ships

| Layer | File | What it does |
| --- | --- | --- |
| rules | `voice/speech-locale.ets`, `voice/speech-text.ets`, `voice/auto-speak.ets`, `voice/voice-plan.ets`, `voice/voice-assignment.ets`, `voice/bot-voices.ets`, `voice/stop-signal.ets`, `voice/draft-dictation.ets`, `voice/voice-settings-model.ets` | core's and mobile's pure rules, ported value-for-value: locale tags, speakable text and utterances, the auto-speak gate, the voice plan, the unused-voice picker, the bot-voice choice, the composer's draft merge, the settings form rules |
| state machines | `voice/dictation.ets`, `voice/speech.ets`, `voice/device-voice.ets` | mobile's dictation session (silence endpoint, carried/heard folding, restart backoff) and speech playback (one control, queue, session switch), with every recognizer, timer, engine and store injected |
| engines | `voice/device-recognizer.ets`, `voice/device-speech.ets`, `voice/voice-clip.ets`, `voice/clip-player.ets`, `voice/microphone.ets`, `voice/voice-prefs.ets`, `voice/bot-voices-store.ets`, `voice/install.ets` | CoreSpeechKit's recognizer and synthesizer, the AudioCapturer recording (WAV-wrapped PCM), the AVPlayer clip player, the microphone permission, the preferences file for the choices, the wiring at app start |
| transport | `net/http.ets` (extended), `voice/hosted-voice.ets`, `net/consent.ets` (extended), `contract/decode-voice.ets` | one byte-body HTTP request for the speech clip, `voice/prepare`, `/api/voice/speak`, `/api/voice/transcribe`, the voice-use consent gate, the voice contract decoders |
| UI | `features/chat/composer-dictation.ets`, `features/chat/voice-player-bar.ets`, `features/settings/VoicePage.ets`, `stores/voice-settings-store.ets`, `features/chat/ThreadPage.ets` (extended), `features/chat/MessageBubble.ets` (extended), `pages/Index.ets`, `features/settings/SettingsPage.ets`, `uikit/controls.ets` (Field gains `onSubmit`) | the mic button and the dictation bar, the playback bar in the root column, the Voice settings page, the Speak message menu entry, the auto-speak wiring |
| fixture | `scripts/voice-scenarios.ts`, `scripts/voice-scenario-list.ts`, `scripts/voice-fixture-corpora.ts`, `scripts/gen-voice-fixtures.ts`, `scripts/voice-fixture.mjs`, `contract/voice-fixtures.test.ts`, `contract/voice-port.test.ts`, `contract/fixtures/voice.json` | the scenario runner and its lists, the corpora, the generator (its own file, its mocks out of the other generators' graph), the differential replay, and the fixture server's voice routes |

## How the two paths work

The plan (`resolveVoiceCallPlan`, ported and fixture-pinned) picks the engine before anything
listens or speaks: the device's own voice when its choice is on **and** the device recognizer is
available (capability + microphone), else the server's voice provider, else the settings page.
A device-voice read failure counts as on, exactly as mobile: a local-only reply never takes the
hosted path by accident. The plan's answers in the composer:

- **device dictation** — CoreSpeechKit's recognizer fed by the AudioCapturer, its events mapped
  onto the ported session state machine; the microphone's frames go to the engine in its
  1280-byte PCM chunks, the level reaches the bar, and the engine's own 60 s single-session cap
  reads as a session end, which the state machine restarts as any natural end.
- **provider dictation** — the mic records 16 kHz mono S16LE PCM, wrapped in a 44-byte WAV header,
  transcribed through `/api/voice/transcribe` (the voice consent asked first); the words land in
  the draft once, with the merge rule of mobile's own composer (lifted from its source and run by
  the generator, so the fixture pins the real rule).
- **read-aloud** — the long-press menu's Speak message (Reply first, then it, then Select text)
  queues every later bot message with words; a speech is the device's own voice, per bot, or
  `voice/prepare` + `/api/voice/speak` per utterance with the next clip rendered ahead. The
  playback bar sits in the root column under the Navigation: speaker name (the roster's bot
  color), Pause/Resume when it can hold, Stop always. A session or Space switch ends it; so does
  the app leaving the foreground, which also releases both device engines.
- **auto-speak** — the ported gate reads the roster row's new `autoSpeak` field (`botView` and
  the spaces/list snapshot now carry it; the inbox fixture's cases cover it); the thread page
  runs it on every snapshot change and foreground return.

The device voice's engines are created lazily behind `canIUse('SystemCapability.AI.*')` with
dynamic imports, so a device without speech answers with the local failure copy and no ArkTS
warning lands in the new files. `textToSpeech.downloadVoice` is never called: the probe showed it
opens a system download ability and killed the test process.

## Voice settings

The page is a pushed destination from Settings' new Voice row. The provider picker offers 本设备
and the catalog's connections; a chosen connection shows its form (API key; for the self-hosted
protocol the server URL and the two model names), Connect / Reconnect / Replace key, Disconnect,
the voice picker (the listing or free-form when the connection allows it), the speech-model
field when the connection takes one, and 试听. The device voice needs no setup, so it shows none
of it. `VoiceSettingsStore` owns every read (through the QueryCache) and write (invalidate and
re-read), keeps fields typed into since the last load across a refresh, and rolls a failed
device-voice switch back. Its two decisions — which provider to show, what its form offers —
are ports the fixture pins against the real rules, lifted from mobile's screen file.

## Copy

**No new catalog entries.** The 38 msgids the voice surfaces pass to `t()` exist in the shared
catalog for en, zh-CN and zh-TW (checked programmatically; the walkthrough runs zh-CN). One
harmony-only string ships: the microphone permission's reason, a platform resource the system
permission dialog shows (`microphone_reason` in base/zh_CN/zh_TW), which the lingui catalog never
collects.

## Verification

| Gate | Result |
| --- | --- |
| `pnpm exec vitest run apps/harmony/contract` | **131 / 131** |
| `pnpm checks` | all green |
| `pnpm lint` (Biome) | 0 errors |
| `harmony:codegen`, `devecocli build`, `devecocli build --modules entry@ohosTest` | both **BUILD SUCCESSFUL**; no ArkTS warning in any M7 file |
| hypium on the emulator | **190 / 190** (the full suite, fixture servers on 8787/8788) |
| screenshots `m7-*.png` | 14 captures covering every row below |

The emulator is the owner-started `devphone`; no power or license was touched, and the HAPs were
debug-signed with a borrowed local config, reverted after each build.

### The capability probe (before any product code)

| Probe | Finding |
| --- | --- |
| TTS engine | creates for zh-CN person 13 in 211–1384 ms; `listVoices`: `zh_CN/13` INSTALLED (聆小珊), `zh_CN/21` and `en_US/8` GA (need download) |
| TTS playback | advances in real time (a 2.85 s clip completes at +2.78–3.2 s, `isBusy` true throughout); `pause`/`resume` do not throw, `stop()` answers `onStop`; the completion type distinguishes synthesis (0) from playback (1); `onData` yields PCM only with an explicit `playType: 0` |
| ASR engine | creates in 300 ms, `listLanguages` `["zh-CN"]`, `writeAudio` takes 1280-byte PCM frames, `finish` → final result + complete; feeding synthesized speech returns its text (「好。」 from half a clip) |
| microphone | the permission prompt works from the app's own EntryAbility context; the probe inside the hypium process could not take a foreground ability, so the shipped `requestPermissionsFromUser` path was verified through the app itself (see the walkthrough) |
| regex | lookbehind, `\p{Script=Han}`, named groups, emoji ranges all behave; `Intl.Segmenter` is not in the ArkTS standard library (core's fallback branch is the port) |

### Device verification

| What | How | Result |
| --- | --- | --- |
| settings row | Settings → 语音 | the row appears between 模型 and 外观 (`m7-settings-voice-row`) |
| device voice page | open it with nothing connected | Provider 本设备, 试听, no form (`m7-voice-device`) |
| device sample | tap 试听 | the TTS speaks; the playback bar shows `≋ Bot` with Stop and (now that the capability is checked up front) Pause (`m7-voice-device-sample-bar`); it clears when it ends |
| provider picker | tap the Provider row | 本设备 / Fake Voice / Self-hosted, the current one marked (`m7-voice-provider-menu`) |
| connect | pick Fake Voice, paste the key, 连接 | the form gives way to 替换密钥/断开/语音模型/语音 + the voice listing (`m7-voice-connected`) |
| voice picker | tap the Voice row | the listing; picking one POSTs `voice/setVoice` and the row renames (`m7-voice-picker`) |
| voice consent | 试听 before the use is allowed | the disclosure dialog with 暂不/允许/隐私政策 (`m7-voice-consent-speak`); Allow speaks |
| Speak message | long-press a bot message | 回复 / 朗读消息 / 选择文本 / 复制, mobile's order (`m7-longpress-menu`) |
| hosted playback | tap 朗读消息 | the bar shows the speaker (Alpha, its roster color), Pause and Stop while the clip plays (`m7-playback-bar`); Stop clears it |
| mic button | the composer's 🎙 | the system permission dialog with the reason 听写时把语音转成文字。 (`m7-mic-permission`); Allow opens the bar |
| dictation bar | after Allow | 取消 / 电平条 / 停止 / 发送 (`m7-dictation-bar`, `m7-dictation-live`); the level row moves with the mic |
| provider dictation | stop the recording | the fixture's transcription lands in the draft as words, status returns (`m7-dictation-transcribed`) |

**ux-declutter pass** (every capture, per `.agents/skills/ux-declutter/SKILL.md`): the playback
bar is the one accent-less strip the moment needs — speaker name in the bot's color, ink
everywhere else; the settings page reuses the Field/ActionButton rhythm; the device voice shows
no form at all rather than a disabled one. One explainer row written in the first pass («Read
replies aloud on this device…») was removed rather than kept: the picker already says 本设备.

## Review findings (this round's own)

1. **The device engine's pause was a lie.** `canPause` answered whether an engine instance
   existed, so the bar's Pause appeared only after the first speech and vanished after a
   release. The capability is the platform's own, not the engine's lifetime: `canPause` now
   answers `canIUse('SystemCapability.AI.TextToSpeech')`.
2. **The hosted dictation never asked for the microphone.** The plan asks through the device
   recognizer's availability, so a transcribing provider answers without it; the recording then
   found no permission and the session died silently. The hosted path asks for the microphone
   itself before recording.
3. **The hypium fixture replay double-counted the clip's play.** The fake player logged a `play`
   its mobile counterpart made through its own expo-audio listener; the shared player now ends
   the clip without logging a play the recorded run never made, on both the vitest and the
   hypium side.

## Deferred

- **Bot voice picker** (scope D5): no bot settings surface exists here to hang it on, and this
  emulator installs exactly one voice, so the picker has nothing to offer; the assignment logic,
  its persistence and its fixture section shipped, so the surface is all that waits.
- **The settings form's advanced fields** (D7): speech-model listings, the transcription
  vocabulary, the separate transcription server URL/key.
- **Call sounds and call audio** (D8/D9): no calls on this platform yet.
- **`speechModels` listing**: the catalog flag is decoded (so the shape is forward-compatible)
  but the picker behind it waits with the advanced fields.
- **Real dictation input** on the emulator: the emulator's microphone captures silence (the
  probe's capturer read zeros), so live dictation verifies through the recognizer's PCM path —
  the state machine's replay feeds it the same frames the engine consumes. Real-input testing
  needs a physical device.

## Filenames

The captures live in `screenshots/m7-*.png`: composer-mic… wait, no row capture was taken; drop it,
voice-device-sample-bar, voice-provider-menu, voice-provider-form, voice-connected,
voice-consent, voice-consent-speak, longpress-menu, playback-bar, composer-mic,
mic-permission, dictation-bar, dictation-live, dictation-transcribed.
