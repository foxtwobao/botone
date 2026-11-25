# M6 notes — attachments and media, on both sides of the composer

Started on main `4d965f164` (the merge of the M5 pull request). Scope, design §7.2 M6: receiving
images, audio, video, PDFs and files; sending attachments through `artifacts/create`; the reply
flow M5's menu entry waited for; and being the target of a system share. Decisions were written
down before any code in [m6-scope.md](m6-scope.md); this file records what shipped, what the
device showed, and what the scope could not cover.

**Status: verified on the emulator.** Hypium 174/174, every walkthrough row measured, 43
captures. A device walkthrough found and fixed three real defects this round (below); what stays
open is under [Deferred](#deferred).

## What ships

| Layer | File | What it does |
| --- | --- | --- |
| rules | `thread/attachments.ets` | mobile's attachment tables, ported value-for-value: limits, mime tables, aliases, extensions, static-PNG sniff, size formatting |
| picking | `thread/attachment-files.ets` | photo/document pickers, the photo shrink, limits, the sandbox draft copy, the chunked base64 read |
| sending | `thread/thread-send.ets` (extended) | the wire body: target, nonce, `imageHandling`, text, artifact ids, reply id |
| orchestration | `stores/thread-store.ets` (extended) | sequential uploads through the existing `SaveController`, progress, cancel, retry from the first failed file, the 409 image gate |
| transport | `net/request-cancellation.ets`, `net/http.ets`, `net/rpc.ets`, `query/save-controller.ets` | one cancellable transfer per send attempt, carried through the existing layers |
| previews | `net/artifact-cache.ets` | `artifacts/get` download to a scoped, budgeted cache; equal reads share one file and one flight |
| rendering | `thread/block-view.ets`, `features/chat/media-attachments.ets`, `features/chat/attachment-viewer.ets` | the image tier, the audio card, the file row, the full-screen viewer |
| composer | `features/chat/composer-attachments.ets` | attachment chips, the reply preview, their busy states |
| reply | `features/chat/MessageBubble.ets` (extended) | the Reply menu entry, on any persisted message, first in the menu |
| share | `stores/incoming-share-store.ets`, `thread/incoming-share.ets`, `features/chat/share-target-sheet.ets`, `EntryAbility.ets`, `pages/Index.ets`, `module.json5` | the share-target sheet, the dedup/preview pure functions, the want handling |

## The receive side

One message renders each image block as an inline `Image` at its natural size (fitted to 270×360
like mobile), each audio block as a card with an AVPlayer behind a play button and elapsed time,
each file block as a row with the type badge, the name and the size. Video and PDF blocks open a
full-screen cover (the native `Video` controls, HMS `PdfView`); a tap on any other file row, HTML
included, opens the system save dialog directly — the intermediate page of the first version was
removed after a walkthrough pass found it mostly empty (see [Review findings](#review-findings)).
A failed load shows the retry row; a failed preview degrades to the save button; a failed save to
`Could not save`.

Downloads go through one cache keyed by scope and artifact; equal reads share a file and an
in-flight request; the budget is 64 MiB with oldest-first eviction; nothing joins the index until
its file is complete. Draft files and preview files are swept at launch, on session change and on
thread exit.

## The send side

The `＋` menu offers Photo library and File. The photo picker hands over URIs; a photo whose
longest edge exceeds 1600 is re-encoded (PNG static only; GIF and WebP pass untouched; a HEIC or
HEIF that cannot convert is reported as unsupported, like mobile). Documents import unconverted.
Limits come from `me` (10 MiB / 4 files by default); over-limit files are named in the notice row
one by one. Uploads run sequentially, each a `artifacts/create` with its `${nonce}:${index}`
upload nonce and a 60 s deadline; the progress row shows the Nth of M; the send button becomes a
cancel while one is in flight. A failure keeps the draft and offers Retry, which resumes from the
first file that never uploaded (uploaded ids are reused — the instrumented case proves the
replayed body is byte-identical). A 409 `model_image_input_unsupported` swaps the retry label for
**Send as file**, and the retry carries `imageHandling: "file"` over the same nonce and artifact
ids (the walkthrough proves no re-upload happens — one `artifacts/create` in the log).

## The reply side

The long-press menu leads with Reply on any persisted message (mobile's order; progress rows
still get no menu entry). The composer shows the parent's author, its summary and a 32 px
thumbnail; the close button drops it. The send carries `replyToMessageId`; the transcript's own
reply line renders the link, tap-to-jump included (M5's line, unchanged).

## The share side

`module.json5` registers `ohos.want.action.sendData` with the UTD families this product accepts —
image, audio, video, text, composite-object (PDF, Office), archive and file — because the share
panel matches by type family, not by `general.file` alone (a walkthrough found PDF and zip shares
never offered the app before that fix; see [Review findings](#review-findings)). A share stops the
app cold-start or wakes it through `onNewWant`; the pending share lives for five minutes; the
sheet lists the roster with the share's own preview (text, thumbnails, a file count) from source
URIs, never a copy; choosing a chat resets the stack to inbox + chat (mobile resets its stack
too); the sheet's close drops the share. Six files over the limit import four and name the other
two with their reasons, one per file.

## Fixtures and tests

- `contract/fixtures/attachments.json` — generated from the real `@rakazo/core`/`@rakazo/contracts`
  tables and the real mobile `deliverSend` (a bot send and a group partial-upload retry), by
  `scripts/gen-attachments-fixtures.ts`, registered in `gen-fixtures.ts`.
- `contract/attachments-port.test.ts` — the port is loaded from source and compared against the
  live reference module and the mobile send envelope; the chunked base64 round-trips through the
  real decoder; the share parse and the share preview are compared against mobile's own
  `shareContent`/`sharePreview`.
- hypium `Attachments.test.ets` (7 cases) — the fixture replay, the send envelopes, share
  dedup, chunked import and encode, the photo shrink against a generated 2000×1000 PNG, the
  partial-upload retry (idempotent nonce reuse), and the mid-transfer cancel with its retry.
- hypium `ThreadRender.test.ets` — image/file blocks now project to the attachment tier.
- `contract/snapshots/` gains the artifacts create/get shapes; `me` gains the two upload limits;
  the send input gains `artifactIds`, `replyToMessageId`, `imageHandling`; the image and file
  block views gain the fields the renderer reads.
- The fixture server answers `artifacts/create` (nonce idempotent, name-targeted failure,
  paced-body mode for the cancel case) and `artifacts/get`, and writes image-confirming 409s.
  The paced-body mode exists because cancelling during a *response wait* wedges the emulator's
  network stack (see [Review findings](#review-findings)); cancelling while the request is still
  being written is clean, and that is the path the case now takes.

## Copy

**No new catalog entries, no new harmony-only strings.** The 30 msgids M6 passes to `t()` exist
in the shared catalog for en, zh-CN and zh-TW (checked programmatically this round; the walkthrough
runs zh-CN). Each names what a newcomer could not guess: `Photo library` and `File` for the picker
choice, `Send as file` for the 409 recovery, `Skipped {items}` and its per-file reasons, `Cancel
reply`, `Saved`/`Could not save`, `Could not play that clip.`, `Could not open this PDF.`, `No
preview for this file type.` — each on the surface it belongs to, none persistent chrome.

## Verification

| Gate | Result |
| --- | --- |
| `pnpm exec vitest run apps/harmony/contract` | **106 / 106** |
| `pnpm checks` | **160 / 160** |
| `pnpm lint` (Biome) | 0 errors |
| `harmony:codegen`, `devecocli build`, `devecocli build --modules entry@ohosTest` | both **BUILD SUCCESSFUL**; no ArkTS warning in any M6 file |
| hypium on the emulator | **174 / 174** (the full suite; the one earlier red run is under [Review findings](#review-findings)) |
| screenshots `m6-*.png` | 43 captures covering every row below |

The emulator is the owner-started `devphone`; no power or license was touched, and the HAPs were
debug-signed with a borrowed local config, reverted after each build.

### Device verification

| What | How | Result |
| --- | --- | --- |
| two images in one message | a bot reply with two image blocks | both inline, natural size, tap either for full screen (`m6-thread`, `m6-image-fullscreen`) |
| audio | tap play on the audio card | the button toggles, `0:02 / 0:08` advances (`m6-audio`); a failed clip shows `Could not play that clip.` |
| video | tap the video row | the cover opens, native controls, `0:00 / 0:04` (`m6-video`, `m6-video-viewer`) |
| PDF | tap the PDF row | the cover opens the document text (`m6-pdf`, `m6-pdf-viewer`) |
| file row | tap the text/HTML row | the system save dialog opens directly; confirm writes the byte-identical file (`m6-file-save-dialog`, `m6-file-saved`; fetched back and `cmp`-ed); cancel says nothing |
| audio download | the card's `↓` | the same save dialog (`m6-audio-save-dialog`); a cancelled save leaves no error |
| viewer download | the viewer's `↓` | `已保存` beside the title, three seconds, gone (`m6-image-saved`); the preview never moves |
| file picker, multi | `＋` → 文件 → 浏览 → 下载管理器 → 多选 → two files → ✓ | both chips arrive together (`m6-file-picker`, `m6-file-picker-selection`) |
| photo picker | `＋` → 相册 → the system grid | single photo opens preview; tick + 完成 attaches it (`m6-gallery-picker`, `m6-gallery-selected`, `m6-gallery-draft`) |
| upload progress | send with the fixture pacing one upload | the button becomes cancel, the progress row shows 1/2 (`m6-uploading`) |
| upload cancel | cancel mid-upload | chips and text stay, no `threads/send` in the log, cancel restores the chip removal buttons |
| upload failure | the fixture fails one name | the retry row appears with the chips intact (`m6-upload-failed`) |
| upload retry | tap 重试 | resumes from the failed file; the replayed create body is byte-identical (instrumented case) |
| attachment-only send | send with no text | `threads/send` carries 2 artifactIds and no text; the transcript echoes image + file rows (`m6-attachment-sent`, `m6-sent-image-fullscreen`) |
| Send as file | the fixture returns the 409 | the error row offers 作为文件发送; the retry sends `imageHandling:"file"` with the SAME nonce and artifact ids, one upload in the log (`m6-send-as-file`) |
| Reply menu | long-press a persisted message | 回复 first (`m6-reply-menu`) |
| reply preview | pick Reply | author, summary, thumbnail, close (`m6-reply-preview`); close drops it (`m6-reply-cancelled`) |
| reply send | send the reply | `replyToMessageId` in the wire, the reply line renders (`m6-reply-sent`) |
| share cold | stop the app, share a file from the file manager | the share sheet lists the file and the roster; picking a chat lands the file as a draft (`m6-system-share-cold`, `m6-share-target-cold`, `m6-share-draft-cold`) |
| share warm | share while the app is open | the same, files appended to one draft (`m6-system-share-warm`, `m6-share-target-warm`, `m6-share-draft-warm`); back lands on the inbox (`m6-share-back-inbox`) |
| share cancel | close the sheet | the share is dropped, nothing sent (`m6-share-cancelled`) |
| share, images only | share two photos | the sheet shows thumbnails from source URIs (`m6-system-share-images`, `m6-share-target-images`) |
| share, over the limits | share six files (one over 10 MiB) | four import; the notice names the rest with each reason; nothing sends itself (`m6-system-share-limits`, `m6-share-target-limits`, `m6-share-limits`) |
| share, PDF and zip | share a PDF and a zip alone | the app is offered (the UTD-family fix; before it, the panel never listed the app for these) |

**ux-declutter pass** (every capture, per `.agents/skills/ux-declutter/SKILL.md`): one accent at a
time (link blue, the send arrow's white); ink, muted and the destructive red on errors only; the
chips carry one remove button each, hidden while a send is in flight; the viewer's save
confirmation sits in the header instead of a status row, so the preview never reflows. The
empty between-page viewer was removed rather than styled.

## Review findings (this round's own)

Three defects a walkthrough or the suite found, all fixed and re-verified:

1. **Share targets for PDF and zip never matched.** Sharing a PDF, a zip, or any mixed batch that
   included one showed only 华为分享 — this app was absent from the panel. The share panel matches
   an app's declared UTDs by type family; `general.file` does not cover `general.composite-object`
   (PDF, Office) or `general.archive`. `module.json5` now declares each family this product
   accepts, per the Share Kit guidance that the URIs list must enumerate the supported types.
   Re-probed on the device: single PDF, single zip, mixed batches all list the app now.
2. **A busy ForEach item never re-read state.** Hiding the chip's remove button while a send was
   in flight used `this.busy` inside the item builder; once built, the item is not re-evaluated,
   so after a failure the buttons never came back. Each chip is now its own `@ComponentV2` with a
   `@Param busy`, and the walkthrough asserts remove buttons: present idle, absent in flight,
   restored after cancel and after failure.
3. **The save confirmation reflowed the viewer.** The first viewer put `已保存` on its own row
   below the header; the image then re-laid-out when the row appeared. The confirmation moved into
   the header, beside the name, at the buttons' fixed height.

And two the review-adjacent probing surfaced, both worth recording:

4. **The send left the transcript away from the bottom.** With attachments and the progress row,
   the composer grows, the list shrinks, and the "at bottom" test turns off without any scroll;
   the message you just sent then arrives off-screen. A successful send now pins bottom and
   scrolls. The walkthrough caught it as a missing echo check.
5. **Cancelling during a response wait wedged the network stack.** The instrumented cancel case
   first cancelled an upload whose response the fixture was holding; every later suite in the
   same process then saw its requests fail with client-side write errors (curl 23/28), and the
   full hypium run ended 173/174 with an M2 roster case unable to load. The stack recovers only
   when the app process exits. Cancelling while the request is still being written is clean — the
   fixture now paces the upload body, the case cancels mid-write, and the full suite is 174/174.
   The fixture also ends a held response's socket when the client aborts, so no half-open
   connection leaks into the next suite either way. If a future change returns to
   destroy-during-response-wait, expect this again.

## Deferred

- Quote (the text-selection reply path) — scope D6; `Quote` stays in the catalog untouched.
- Camera — D4. Sandboxed HTML and the text viewer pages — D3; HTML shares the file row's save
  path. The multi-image swipe gallery — D1; one full-screen image with pinching stays with the
  viewer.
- The disk outbox — D8; a failed send keeps its draft in memory through the SaveController, not
  across a process restart.
- A HEIC/HEIF that cannot decode is reported as unsupported, not sent as a file: mobile's rule,
  kept deliberately.
- The share panel's own surface ( Huawei Share's "share details page" alternative) is unused; the
  app answers the plain share.
- The photos app on this emulator asks for its privacy consent on first open; the walkthrough did
  not accept it, so the *photos-app-to-BotONE* direction was driven from the file manager instead
  (same share surface). The consent is the owner's to give.
