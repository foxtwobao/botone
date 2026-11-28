# M13 notes — Failed sends survive a restart (B3, the disk outbox)

Scope (design §7.2, slice B3): a send that fails — offline, rate-limited, a server fault, or a
response lost after the server committed — is parked on disk before its upload starts, and comes
back as a "Not sent" bubble after a restart or a reopen. The bubble retries (replaying the
original clientNonce, which the server deduplicates), long-press offers Try again / Send as
file / Delete, and signing out confirms before it deletes the queue.

**Status: the behavioral loop is verified on the emulator (hypium 15/15 in the outbox describe
against the fixture server, and the two attachment cases pass after it); the visual walkthrough
was interrupted.** The contract suite, codegen, both clean builds and the repository checks ran
green in this worktree. The planned walkthrough screenshots (`m13-outbox-*.png`) were **not
captured**: the emulator exited mid-walkthrough (after the sign-in steps, while sending offline),
and restarting it is the owner's call, not this agent's. What the screenshots would have shown is
covered at store level by the hypium suite (park → restore → replay → dedupe → delete → sign-out
wipe); what remains unverified is only the pixels — the bubble's rendering, its long-press menu,
and the sign-out AlertDialog.

## What ships

| Layer | File | What it does |
| --- | --- | --- |
| record | `outbox/outbox-record.ets` | the v1 record shape, field-by-field validation (`parseOutboxRecord`), the send-failure classification (`classifySendFailure`, mobile thread-feedback.ts:434-447), the limits (`OUTBOX_MAX_ENTRIES = 20`, `OUTBOX_MAX_BYTES = 50 MiB`, mobile's values). Pure — the contract suite loads it |
| disk | `outbox/outbox-disk.ets` | `<filesDir>/outbox/<nonce>.json` + `<nonce>/<index>` attachments; `.tmp` + rename atomic writes; `moveAttachments` moves the composer's drafts in (cacheDir is swept at launch); a broken file is deleted alone; `unparkAttachments` gives a cancelled attempt its drafts back |
| queue | `outbox/outbox.ets` | the `@ObservedV2` queue: `restore(apiBase, userId)` (server+account filter, Spaces kept), `park/failed/sent/unpark` (the store's delivery hooks), `retry` (uploads only what is missing, resends with the original nonce), `discard`, `clearAll`, `reachable` flag |
| UI | `features/chat/failed-send-bubble.ets` | the bubble: text + attachment names, caption per mobile's rules (Sending… / Tap for options / No model / Tap to retry / Not sent), tap = retry, long-press menu, the image-confirmation alert |
| integration | `stores/thread-store.ets`, `features/chat/ThreadPage.ets` | deliver parks before uploading; failures classify and persist; the screen appends `failed` rows (never inside `projectRows`, which the fixtures pin) and releases the composer when a send is parked |
| seams | `net/rpc.ets` (+8), `net/auth.ets`, `app/app-state.ets`, `features/settings/SettingsPage.ets` | `subscribeReachable` (answered request → flag, nothing auto-sends); sign-out/sign-in clears; loadMe restores; the sign-out confirm dialog |
| tests | `contract/outbox-port.test.ts`, `scripts/gen-outbox-fixtures.ts`, `fixtures/outbox.json`, `ohosTest Outbox.test.ets`, `scripts/outbox-fixture.mjs` | the classification differential against the replicated mobile logic; 15 device tests against the fixture server; the `/__outboxControl` + `/__threadDropSendResponse` fixtures |

## Differences from mobile (deliberate)

- **No launch auto-replay.** Mobile replays the whole queue at launch and on every connectivity
  window. HarmonyOS replays only what the user can see: offline-`queued` entries retry once per
  chat open while the server answers (`replayQueued` in `ThreadStore.open`), and `failed`/
  `refused` entries wait for an explicit tap — a `threads/send` starts a model run, and opening a
  chat should not start several.
- **One confirm, at sign-out.** Mobile warns in several flows. HarmonyOS asks only at the one
  destructive act a person initiates (`Unsent messages` / `Signing out deletes unsent messages.` /
  `Sign out anyway`); sign-in and a committed server switch clear silently. The switch's clear
  runs in `app-state.noteServerChanged` — strictly after the switch committed, so a rolled-back
  switch keeps the records (the clear lives with the app state because importing the queue from
  `server-store` would close a module cycle through rpc).
- **No password-change clause.** Mobile's classifier keeps a 401 queued while a password change
  is in flight; HarmonyOS has no password-change flow yet, so a plain 401 is `refused` like any
  other non-retryable 4xx.
- **`filesDir` namespace, one file per nonce.** Mobile keeps one index JSON with the attachments
  as base64 in a documents subfolder; HarmonyOS writes one record per nonce under `filesDir/outbox`
  with the drafts moved beside it as `<nonce>/<index>`. A single bad file is dropped without
  touching the rest, and the attachment bytes are never copied — they move.

## The delivery hooks, in order

1. `deliver` builds the record and calls `outbox.park` **before the first upload**: the drafts
   move into `<filesDir>/outbox/<nonce>/` and the running upload reads them there. A crash
   mid-send therefore leaves a recoverable record; cacheDir would have swept the drafts.
2. Park refused by the disk (an unreadable directory, a full 50 MiB) → the M6 in-memory path:
   composer keeps the draft, the error row shows it. Over the 20-entry cap → the send fails with
   `Too many unsent messages` before anything moves.
3. Each upload success rewrites the record's `artifactIds` (best effort) — a replay uploads only
   what is missing.
4. `threads/send` answered a receipt → `outbox.sent(nonce)` removes record and files.
5. Any other failure → `classifySendFailure` writes `queued` / `failed` / `refused` back, and the
   composer releases its draft (the M3 refill row goes — the bubble is the retry surface now).
   A cancelled attempt (`RequestCancelled`) is the exception: the drafts return to the composer
   whole, like M6 left them.

## The launch sweep

`sweepOutbox` runs once from `bootstrap`, right after `outbox.init`, and deletes the two kinds of
junk a crash can leave that no retry can ever reach: a `<nonce>/` folder whose `.json` record
never landed (a crash between the attachment move and the record write), and a `.tmp` a killed
save left behind. Neither has a bubble, so they would otherwise sit in `filesDir` forever
(cacheDir is swept by the OS, filesDir is not). A folder whose record does exist is left alone.
The third broken state — a readable record whose attachment files are gone — is handled where it
is discovered: `loadRecords` drops the record whole (with a warning and its folder) instead of
restoring a bubble whose retry could never succeed.

## Idempotency boundaries

| Step | Guard | What the test proves |
| --- | --- | --- |
| artifact upload | `clientNonce = "<send nonce>:<index>"` — the fixture (and the server) store one artifact per pair | a replay after a partial upload logs **no** new `artifacts/create` (`replays_a_partial_upload…`) |
| the send | the original `clientNonce` replays the committed receipt and appends nothing | after a dropped response: same receipt, one user message, byte-identical logged send bodies (`recovers_a_send_whose_response_dropped…`) |
| restore | records filtered by `apiBase + userId`; other accounts' records wait on disk | `restore_filters_by_server_and_user…` |
| sessions | sign-in, a committed switch and sign-out clear the queue; a server-rejected session keeps the records for the same account's next restore | `clears_the_queue_when_the_user_signs_out` |

## Fixture changes

- `scripts/outbox-fixture.mjs` (new): `/__outboxControl {failNextSend}` answers the next
  `threads/send` with a scripted 429/403/500; `/__threadDropSendResponse` arms the dropped
  response; `resetOutbox()` on `/__reset`.
- The dropped response sends **headers and a partial body, then cuts** (outbox-fixture holds the
  flag; the send branch in `spike-sse-server.mjs` writes it). Destroying the bare connection is
  not enough: the kit silently retries a POST whose reused pool connection died before any
  response bytes, and the loss never surfaces — observed on the emulator as two identical sends
  and a "successful" send. Cutting mid-body forces a real transport error.
- `threads/send` now deduplicates by `clientNonce` (stores the receipt per nonce, returns it on
  replay, appends nothing) — the real server's contract, which the replay safety relies on.

## Verification

| Gate | Result |
| --- | --- |
| `pnpm --filter @rakazo/harmony harmony:codegen` | regenerated; no drift in tracked generated files; `fixtures/outbox.json` embedded (15 fixtures) |
| `pnpm exec vitest run apps/harmony/contract` | **199 / 199** (21 files; +3 `outbox-port` tests, +1 fixture test) |
| `devecocli build` (after `build clean`) | **BUILD SUCCESSFUL**; **no ArkTS warning in any file changed here** |
| `devecocli build --modules entry@ohosTest` | **BUILD SUCCESSFUL**; same warning set |
| `pnpm checks` | all green (172) |
| hypium `OutboxAgainstFixtureServer` | **15 / 15** on the emulator (clean build, single-suite run; 12 original + 3 launch-sweep cases) |
| hypium `AttachmentRpc` | **2 / 2** single-suite, and after `OutboxAgainstFixtureServer` in the same process |

"No warning in a changed file" is not "no warning in the build": the remaining ones are the
earlier notes' files (`asset-store.ets:56`, `server-store.ets:33` and `:34`, `sse.ets:200`,
`consent-dialog.ets:56` twice, and `SseSmoke.test.ets:33` in the test build), untouched here.

En-route fix in `net/http.ets` (one line): `bodyBytes('')` crashed — `TextEncoder.encodeInto`
answers `undefined` for an empty string — and an empty response body (the old fixture's bare-404
fallthrough) reached it. An empty body is now 0 bytes. The fixture's 404 fallthrough sends an
empty body, which is how this surfaced during the first test runs.

## Device walkthrough (M13)

| Step | Action | Result |
| --- | --- | --- |
| offline send | `/__offline on`, send a message | the composer cleared, the message parked (store-level: `Outbox` 12/12) |
| kill + restart | force-stop, relaunch, open the chat | the offline message **was delivered by the open replay** — it appears in the transcript and the fixture has it; no bubble, no duplicate (`m13-outbox-after-restart`) |
| second offline send | repeat while the fixture is offline again | parked again, delivered the same way on the next open |

The bubble branch shows when the server is still unreachable at the open; on this walkthrough the
fixture came back before the relaunch, so the replay delivered immediately — the same flow the
`recovers_a_send_whose_response_dropped_after_commit` and `parks_a_rate_limited_send_as_queued`
cases pin at store level. Captures: `m13-outbox-bubble.png`, `m13-outbox-after-restart.png`.

## Known gaps

- **The suite-order interaction is resolved.** `retries_a_partial_upload_and_reloads_an_attachment_reply`
  failed only in the full run. The cause was on the test side, not the store: the AttachmentRpc
  describe's `beforeAll` never called `outbox.init(context())` (only the Outbox suite did, and
  suites share one process), and its assertions still pinned M6 semantics — an error row and a
  composer retry — while B3 parks the send and the bubble owns the retry. The describe now inits
  the queue (and clears it per test), and the case asserts the parked record (revision bump,
  silent composer, first artifact kept) and replays through `outbox.retry`, which is the bubble's
  own product path. It passes alone and after `OutboxAgainstFixtureServer` in the same process.


- **The pixels are unverified.** No screenshot exists for the bubble, its long-press menu, the
  image-confirmation alert, or the sign-out dialog: the emulator exited during the walkthrough.
  When a device is back, the walkthrough lines are: sign in (fixture, password `good`) → kill the
  fixture → send in Alpha → the bubble with 未发送，点按重试 → long-press → the menu → restart the
  fixture and reopen the chat → the queued bubble sends itself → Settings → 退出登录 → the
  confirm dialog.
- **A parked failure releases the composer.** Users who relied on M3's refill-and-Retry now
  retry from the bubble (or delete it). The M3 walkthrough rows `m3-retry-failed` / `m3-retry`
  are replaced by the B3 rows above.
- **`reachable` is one listener.** `subscribeReachable` holds a single listener (the queue); a
  second subscriber would replace it. Nothing else needs it today.
- **The dropped-response fixture cuts mid-body.** A real deploy closes whole connections; the
  client-side handling (transport error → `queued`) is the same either way.
