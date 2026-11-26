# M7 notes — 语音Ⅰ：听写、朗读、bot 声音设置

Started on `origin/harmony/m6-attachments` `213c2cd95` (the M6 fix push). Scope, design §7.2 M7:
dictation into the composer, read-aloud from a message, the bot's device voice, and the Voice
settings page. Decisions were written down before any code in [m7-scope.md](m7-scope.md); this
file records what shipped, what the device showed, and what the scope could not cover.

**Status: verified on the emulator.** Hypium 218/218 (17 cases added after the second review
round), the capability probe's findings hold in the shipped code, every walkthrough row measured,
15 captures.

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
device-voice switch back. Its two decisions are ports the fixture pins against the real rules:
which provider to show is lifted from mobile's screen file, and what its form offers is the
contracts package's `voiceConnectionForm`.

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
| `pnpm checks` | all green (160) |
| `pnpm lint` (Biome) | 0 errors (25 warnings and 24 infos; Biome does not read `.ets`) |
| `harmony:codegen`, `devecocli build`, `devecocli build --modules entry@ohosTest` | both **BUILD SUCCESSFUL** after `devecocli build clean`: **no ArkTS warning in any file M7 added or changed** |
| hypium on the emulator | **218 / 218** (the full suite, fixture servers on 8787/8788) |
| screenshots `m7-*.png` | 15 captures covering every row below |

"No warning in an M7 file" is not "no warning in the build". Six warnings remain, all in files
from earlier milestones that M7 never touched, and they are left as they are:
`features/chat/consent-dialog.ets:56` (`AlertDialog` and `show` are deprecated; M3), and
"Function may throw" in `net/asset-store.ets:56`, `net/server-store.ets:32` and `:33` and
`net/sse.ets:200` (M1). The test build adds `ohosTest/ets/test/SseSmoke.test.ets:33` (M0).

The emulator is the owner-started `devphone`; no power or license was touched, and the HAPs were
debug-signed with a borrowed local config, reverted after each build. In this round
`devecocli signature generate` answered that the CLI's online services are not available in its
detected region, so the borrowed config names signing material an earlier session had generated.

The full hypium suite ran three times on the fixed code: 214/214, 213/214, then 214/214 on the
same build. The one failure was `offline_read_keeps_the_last_rows_painted` in
`RosterRealtime.test` (M3, the roster's offline banner), which read an empty error right after the
banner appeared. It passed alone and in the other two runs, and nothing in this round touches the
roster. Those three ran before the finishing timeout below; with it the full suite ran 215/215,
and with its cancel 216/216. After the rebase onto main and the synchronization below it ran
218/218.

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
| voice consent | 试听 before the use is allowed | the disclosure dialog with 暂不/允许/隐私政策 (`m7-voice-consent`); Allow speaks |
| Speak message | long-press a bot message | 回复 / 朗读消息 / 选择文本 / 复制, mobile's order (`m7-longpress-menu`) |
| hosted playback | tap 朗读消息 | the bar shows the speaker (Alpha, its roster color), Pause and Stop while the clip plays (`m7-playback-bar`); Stop clears it |
| mic button | the composer's 🎙 | the system permission dialog with the reason 听写时把语音转成文字。 (`m7-mic-permission`); Allow opens the bar |
| dictation bar | after Allow | 取消 / 电平条 / 停止 / 发送 (`m7-dictation-bar`, `m7-dictation-live`); the level row moves with the mic |
| provider dictation | stop the recording | the fixture's transcription lands in the draft as words, status returns (`m7-dictation-transcribed`) |
| empty-draft send (review B1) | during a hosted recording, tap 发送 on the empty draft | the recording stops keeping its words, the transcription ("Fake dictated words") lands in the draft and the message sends (`m7-review-empty-draft-send`) |
| backgrounding during dictation (review B3) | Home while the mic records | the session ends: back on the thread the bar is gone and the composer is its own row again |

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

## Review findings (Codex's second round)

The independent review of `3093cbf60` asked for changes — three blockers, three should-fixes
and a nit — centred on the dictation's send semantics and the microphone's lifecycle. All fixed,
each with a machine-run test:

| # | Finding | Fix |
| --- | --- | --- |
| B1 | Tapping Send during dictation cancelled the session: a hosted recording was dropped, the device recognizer missed its final words, and an empty draft greyed Send out before it could ever send one. | A session now knows whether its microphone is open (`recording`). A send during recording stores its callback (`afterWords`) and calls the session's own `finish`: the hosted recording stops to keep its words and transcribes them, the device path runs `finishListening`, and the send fires once the words land. A send while still preparing has no words to keep, so it drops the setup and runs at once. The Send button stays enabled (and fully opaque) on an empty draft while dictating. Tested on both paths, for the empty draft, and for the preparing case (`DictationLifecycle.test`, `VoiceHosted.test`). |
| B2 | The AudioCapturer kept running after listening ended: only backgrounding `release()` closed it, so the microphone stayed held after a stop or a leave. | `abort()` stops and releases the microphone with the engine session; the 60 s cap still rotates segments without touching it (`closeSession` never closes it), so a rotating segment keeps its capture. The uninstall the dictation stop runs ends the capture on every leave path. Tested for stop, cancel and leave-thread (`DictationHardware`). |
| B3 | Backgrounding stopped the recognizer module but not the composer's own session: the controller stayed "listening" and a hosted recording kept capturing. | A registry of controllers with an open session gives `stopAllComposerDictation()`, and `install.ets`'s foreground handler now ends the composer session with everything else, on both paths. Tested device and hosted (`DictationLifecycle`, `VoiceHosted`). |
| S1 | The engine callbacks discarded their `sessionId`, so a late word, completion or error from an old segment could write into or clear the running one (60 s rotation, cancel-then-reopen). | Every listener callback now belongs to the session it names (`isCurrent`): a callback for an old segment arriving after the next one started is dropped, while the just-finished segment's own end still restarts it. The old-after-new ordering is tested. |
| S2 | A bot row from an older server without `autoSpeak` failed to decode, dropping the whole bot from the list. | `readAutoSpeak`: missing or null reads as false (no reading aloud); a value of another type still fails the row. An old-response test was added to `Decode.test`. |
| S3 | `pcmLevel` read the S16LE pairs unsigned — a negative half-wave read as a huge positive — and both capture paths repainted the meter once per microphone buffer. | The pair is read signed, and the level is paced at ten a second (`paceLevel`) on both the recording and the recognizer path. A signed-reading test covers the arithmetic. |
| nit | These notes claimed no ArkTS warning in any M7 file while a clean build showed nine "Function may throw" warnings in `voice-prefs.ets` and `clip-player.ets` — the incremental builds had hidden them. | The throwing kit calls (preferences `get`/`put`/`flush`, both `openSync`, `createAVPlayer`, and the engine's `createEngine`) are wrapped, and no M7 file warns against a clean build. The build's other warnings are listed under Verification. |

The seams the tests need follow the module's own pattern — the recognizer and microphone behind
`setHardware` on `DeviceRecognizer` (the dictation state machine already injected its engines),
the microphone grant and the clip recorder behind `setVoiceMicrophoneGrant`/`setClipRecorder`.

## Review findings (Codex's third round: the recognizer's lifecycle)

A re-read of `47d619a89` closed B3, S2, S3 and the warning nit, judged B1, B2 and S1 not closed
in substance, and found one more race (N1). All of it sits in `device-recognizer.ets`, so it was
fixed as one state machine: the engine was probed on the emulator first, the states and every
asynchronous entry were written down, and the code followed. A further read of the result
(`eaa7fbc62`) closed all six rows and left one should-fix, the finishing timeout in the last row.

### What the engine does

A probe against the device engine in the hypium process (not committed; noise, and speech
synthesized on the device with `playType: 0` and fed in real time).

| Question | The engine's answer |
| --- | --- |
| A segment asked to `finish` | Its final words, then `onComplete`, 0–15 ms later. A finish 1.2 s into 「你好，今天天气怎么样」 answered 「你好今天。」 where the interim had been 「你好」. The 0–15 ms is one emulator's observation: `FINISH_GRACE_MS` leaves two orders of magnitude over it |
| A segment cancelled | No final words: `onComplete` alone, or `onError(1002200010)` then `onComplete` |
| An error around a finish | `onError(1002200010, "Write audio failed because the start listening is failed.")` comes in some runs and not in others, before the final words (which follow 15 ms later) or after them. The same error answers a frame written into a segment that already ended |
| The 60 s cap | The engine ends the segment itself at about 59.6 s (`onEvent(3)`, final words, `onComplete`). `writeAudio` does not throw: 1,700 frames written back to back past the cap, no exception. The segment started after it hears normally |
| `finish` or `cancel` on a session the engine does not know | Nothing is thrown. `onError(1002200004)` or `onError(1002200005)` names that session, and no completion follows |
| A segment finished before any audio | `onComplete`, no result |
| Two segments listening at once | Both get the error. The next segment may start the moment the last one was finished or cancelled |

So `onError` is a notice the engine sends around a normal finish, not the end of anything. The
adapter ended the segment on it, which on the device delivers a send without the engine's last
words.

### The state table

A segment is one engine session. `session` holds the running one, `closed` the one that left
last, `awaiting` whether the engine still owes that one its end.

| Entry | opening | recording | finishing | closing | idle |
| --- | --- | --- | --- | --- | --- |
| | the engine listens, its microphone is being opened | the microphone feeds the engine | the engine was asked to finish or cancel; its last words and its end are awaited | the engine ended the segment; a restart or a stop is still owed | nothing is left to count |
| `onEvent`, `onResult` naming the running or the closed segment | counts | counts | counts: the awaited last words | counts | dropped |
| Any callback naming another segment | dropped | dropped | dropped | dropped | dropped |
| `onComplete` of that segment | to closing, one `end` | to closing, one `end` | to closing, one `end` | dropped: already ended | dropped |
| `onError` of that segment | to closing, `error` and one `end` | the same | `error` only; the end waits for the completion, except a refused finish (1002200004), which ends at once | dropped | dropped |
| `start` (a restart, a new listen) | — | — | to opening, clean | to opening, clean | to opening |
| `finish` (a send or a stop, keeping the words) | engine `finish`, to finishing; the microphone being opened is released when it answers | engine `finish`, to finishing | nothing: already asked | `end` at once | `end` at once |
| `abort` (a cancel) | engine `cancel`, to finishing; the microphone stops and is released | the same | engine `cancel` for the segment it still owes; the microphone is released | the microphone is released | nothing |
| The microphone's open answers | taken only if the same segment still runs, else released | — | released | released | released |
| The microphone's stop and release settle | no state changes; a failure is logged | the same | the same | the same | the same |
| The app leaves the foreground (`release`) | as `abort`, then the engine is shut down: idle | the same | the same | idle | idle |
| Listening ends (the `listen` uninstall) | as `abort`: idle | the same | the same | idle | idle |

A cancel passes through *finishing* because the state machine's quiet restart cancels a segment
and waits for its end to restart, and the engine reports that end after a cancel too.

An `abort` cancels whatever segment the engine still owes (`awaiting`): the one running, or the
one it was asked to finish. By the time a normal `end` reaches `abort()` the engine has already
ended the segment, so a finish that delivered its words is never cancelled behind them.

### The fixes

| # | Finding | Fix | Hypium case |
| --- | --- | --- | --- |
| B1 | A send on the device path cancelled the engine segment, so the words it had not reported yet were lost. The existing case only injected an interim before the send. | The dictation port takes an optional `SpeechRecognizer.finish`: a caller's finish asks the recognizer to finish keeping its words, and the turn ends on the recognizer's `end`, which a `finishing` flag makes deliver instead of restart. The device recognizer answers with the engine's `finish`, waits for the final words and the completion, and the microphone goes with the turn. A recognizer without it is aborted as before, so the fixture replay still matches mobile. | `send_during_device_listening_waits_for_the_engine_final_then_sends`, `an_engine_error_during_the_finish_does_not_cut_off_the_final_words`, `a_finish_the_engine_refuses_still_sends`, `a_finish_the_engine_throws_on_still_sends`, `leaving_while_the_engine_finishes_drops_the_late_words` |
| B2 | `mic.stop().then(release).catch(…)` skipped the release when the stop rejected, and swallowed the error. | `stopMicrophone` and `releaseMicrophone`: each step in its own catch, a failure logged, the release always runs. | `a_microphone_whose_stop_fails_is_still_released` |
| S1 | With no segment running, any callback was accepted, so an old segment's late word, error or end landed in the gap before the next restart. | The segment that left last is kept until the next one starts. In the gap only its own callbacks count, and among them only its results: its end was already reported. | `an_older_segments_callbacks_are_dropped_between_two_segments` |
| N1 | A cancel during the asynchronous `openMicrophone`, then an immediate restart: the old open returned, saw a session running and was adopted by it. The new open then overwrote it, and the first microphone stayed open. | `openMicrophone` checks after each wait that the segment which asked for it still runs. One that ended takes no microphone, and the microphone opened for it is released. | `a_microphone_created_for_a_cancelled_segment_is_released_not_adopted`, `a_microphone_that_started_for_a_cancelled_segment_is_stopped_and_released` |
| Silent catches | The last round's `.catch(() => undefined)` chains and its kit-call wrappers dropped failures with a comment. | ArkTS cannot import `@rakazo/logging`, so this app's `bestEffort` is a catch with `hilog.warn(0, 'Voice', …)`, as `thread/attachment-files.ets` writes it. A promise-taking helper would not do: `bestEffort(label, mic.stop())` runs the kit call before its own try, and kit calls throw outright. Logged now: the microphone's stop, release, open, start and listener; the engine's creation, preparation, cancel, finish and shutdown; the preferences reads and the bot-voice save. Left as they are because the caller is told: the preference `put` (rethrown as the save failure) and `clip-player`'s three wrappers (each throws the clip failure). | none: a log line is not asserted |
| New, from the probe | Every engine error ended its segment at once, and the completion that followed ended it again. On the device that is every cancel and every 60 s rotation: two `end`s, the restart armed twice, a dead restart counted twice. Around a send it cut off the last words. | An error is reported and waited out while the engine owes the segment its end. A segment's end is reported once, and its results keep counting after it. | `the_end_a_cancelled_segment_still_reports_reaches_the_listener`, `a_completed_segment_is_not_ended_twice`, `the_words_after_an_engine_error_still_reach_the_listener` |
| Finish timeout (should-fix) | A finish the engine neither completes nor refuses hung the send. On `eaa7fbc62` a wedged engine held it for 30 s: the composer's silence limit delivered the words then, and the quiet restart's abort had already closed the microphone at 15 s while the bar still said listening. No engine path was found that does it; the case scripts one. | `FINISH_GRACE_MS`: a caller's finish arms a 2 s timer on the session's own clock, and a turn whose recognizer has not reported its end by then ends with the words heard. `stop()` disarms it, and a normal `end` delivers first. The `abort()` that ends the turn then cancels the segment the engine still owed, so the next listen does not find the engine inside that finish; a segment the engine already ended is never cancelled. | `a_finish_the_engine_never_answers_still_sends_what_was_heard`, `a_finish_the_engine_never_answers_cancels_the_segment_it_still_owes` |

**Red before, green after.** With those cases on the unfixed code (`47d619a89`), `DictationLifecycle`
ran 10 with 5 failures and `DictationHardware` ran 10 with 7 failures. On the fixed code
(`eaa7fbc62`) both were 10/10 and the full suite 214/214; with the finishing timeout they were
11/11 and 10/10 and the full suite 215/215; with its cancel they are 12/12 and 10/10, and the
full suite 216/216.
`send_between_two_segments_ends_at_once_without_cancelling` passes before and after: a send in the
gap between two segments found nothing to cancel in either version, and now guards the `end` the
recognizer reports at once there.

**The finishing timeout, measured** (a temporary probe, not committed): on `eaa7fbc62` a finish
the scripted engine never answered sent at 30,011 ms, and the microphone had stopped at
15,089 ms. With the timeout the same finish sent at 2,001 ms and the microphone stopped at
2,031 ms. Both ran with 「你好」 heard and delivered twice. The cancel case was red on
`559c43f21`: it waits five seconds for the engine's `cancel`, and none came, because `abort()`
made no engine call while the segment was finishing.

**On the device engine itself** (a probe, not committed): the shipped recognizer and composer
over the device engine, with a scripted microphone feeding synthesized speech. A send 1.2 s into
「你好，今天天气怎么样」 asked the recognizer for `finish`; the interims 「你」 and 「你好」 were
followed within milliseconds by 「你好今天。」, which landed with the report and with the
delivery, and the send ran in the same millisecond. A cancel at the same point left the two
interims and nothing else. In every run the microphone stopped and was released.

The seams these cases need stay in the test: a run can hand its microphones over late
(`ScriptedRun.late`), the engine can refuse a finish and announce a start, a microphone can fail
its stop or hold its start, and `GrantedRecognizer` answers the microphone question so the
composer can run over the real recognizer on scripted hardware.

**Not verified.** The emulator's microphone records silence, so no screen shows a device send
keeping its words: the probe is the evidence, and a physical device is still the acceptance.

## Base synchronization

The branch was rebased onto main once the upstream sync (PR #71) and M6 (PR #72) had landed. The
five commits replayed unchanged, but the sync had changed a rule this milestone ports:
`voiceConnectionForm` in `packages/contracts/src/models/voice-connection-ui.ts`. The account's
model connection no longer stands in for a key. A connection's form needs a key, and the account's
model connections to it are offered as explicit choices, or a sign-in where it has none yet.

- **The port and the fixture follow.** `voice-settings-model.ets` is re-ported from the new rule,
  and `settingsForm` in `fixtures/voice.json` is regenerated from the real function: 16 cases. The
  three that described the stand-in gave way to seven, covering the offered choices, a named link,
  a legacy link with several choices and with one, a link to a connection the account no longer
  holds, and the sign-in. The rebase had left two contract cases red, `fixture voice matches the
  committed mobile and core behavior` and `the settings screen shows the connection and the form
  the real rules choose`; both are green again, 131/131.
- **The decoders read the new fields** the way S2's `autoSpeak` is read: `modelConnections` and
  `modelSignIn` on a catalog entry, `modelCredentialId` on a saved connection. Absent or null is
  none offered; a value of another shape fails the row (`Decode.test`, two cases). The flag they
  replace, `modelConnection`, is no longer read, and the layer-1 voice snapshots carry the new
  fields.
- **The page did not change.** The rule's `modelConnections` and `modelSignIn` are decoded and not
  rendered. With an empty key and no explicit choice, Connect stays disabled and the key field
  still asks for one (`Paste your API key`), as it does for any connection without a key: that is
  what the new rule says. No wording was added, so there is no new msgid and no new capture;
  `m7-voice-provider-form` already shows this state.

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
- **A final result that trails the engine's completion** (this round): seen once, with noise and
  empty. The recognizer waits for the completion, so such a result lands while a turn is still
  open (a rotation) but not on a send. A physical device should show whether speech does it.
- **Speech in a rotation gap**: the engine ends a segment at a pause and the state machine
  restarts it after its 250 ms backoff, so what is said in between is not recognized. The
  adapter's header no longer claims a rotating segment never drops audio.
- **Recognition quality** on the emulator: its engine hears 「你好今天。」 for a 2.5 s synthesized
  sentence, which shows the wiring and nothing about accuracy.
- **The voice page's model connection choices** (M11, Models): the rule offers the account's model
  connections and a sign-in, and the decoders read them, but the page renders neither.
  `voice/connect`'s `modelCredentialId` goes with that work. **Known limitation until then:** a
  connection whose voice would authenticate through a model connection needs a pasted API key on
  this device.

## Filenames

The captures live in `screenshots/m7-*.png`: settings-voice-row, voice-device, voice-device-sample-bar,
voice-provider-menu, voice-provider-form, voice-connected, voice-consent, longpress-menu,
playback-bar, composer-mic, mic-permission, dictation-bar, dictation-live,
dictation-transcribed, review-empty-draft-send.
