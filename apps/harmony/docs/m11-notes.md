# M11 notes — Quote a selection (B1)

Scope (design §7.2 M11, slice B1): the long-press menu's Quote entry. It opens the message's
quotable text, each block read-only and selectable; the selected excerpt becomes the reply's
quote, is sent as `replyQuote` beside the reply, and comes back from the server on the re-read.
Out of this slice: quoting across several messages, draft persistence, and any formatting of the
excerpt in the composer.

**Status: verified offline; the device pass is delegated.** The contract suite, codegen, both
builds and the repository checks ran green in this worktree. The hypium run and the walkthrough
captures (`m11-quote-menu`, `m11-quote-sheet`, `m11-quote-selected`, `m11-quote-preview`,
`m11-quote-sent`) belong to the device verification pass on the emulator.

## What ships

| Layer | File | What it does |
| --- | --- | --- |
| rules | `thread/message-quote.ets` | the sheet's segments (`quotableMessageSegments`), the sender-side text conversion (`quoteSourceText`), the reply-quote cap, and the offer rule (`hasQuotableText`) |
| UI | `features/chat/quote-sheet.ets`, `features/chat/MessageBubble.ets` (extended) | the Quote menu entry and one sheet that holds either the select-text or the quote panel |
| send | `thread/thread-send.ets` (extended) | the body's `replyQuote`, trimmed and capped, beside `replyToMessageId` |
| fixtures | `scripts/gen-quote-fixtures.ts`, `contract/fixtures/quote.json`, `contract/quote-port.test.ts`, `ohosTest/ets/test/MessageQuote.test.ets` | the corpus, its generation-time server check on both sides, the offline replay, and one closed loop against the fixture server |

## Key decisions

- **The offered text is the server's, not the preview's.** `deriveMessageQuote` renders a bot
  message's Markdown with remark and searches the selection there, silently sending a plain reply
  on a miss. The mobile sheet's conversion is the reference; `quoteSourceText` reimplements its
  block shapes (list markers, task boxes, table cells, footnotes, HTML blocks, headings, code) and
  replays inline formatting through the existing preview conversion, which already matches the
  server for emphasis, links, escapes and the preview's six entities. Code spans are protected
  through every step so a literal image or pipe inside them survives.
- **A subset that must stay locatable.** The fixture has two corpora: `segments` cases must equal
  the mobile conversion word for word; `quotes` cases (task boxes, loose lists, images, hard
  breaks) only require every offered segment to be found by the real `deriveMessageQuote`. The
  port may render a shape differently but never offer text the server cannot find.
- **Validation runs on both sides at generation time.** `gen-quote-fixtures.ts` loads the Harmony
  port from its `.ets` source (the same copy-to-`.ts` trick the contract test uses) and runs
  `deriveMessageQuote` on the port's own segments too, so a conversion regression fails fixture
  generation instead of only failing on a device.
- **One sheet per bubble.** ArkUI's `bindSheet` is a single slot per node; a second call replaces
  the first, so the Quote and Select text entries share one sheet and a `sheetKind` state
  (`none` / `select` / `quote`) picks the content. Both close callbacks and a
  swipe-down (`onWillDismiss`) return it to `none`.

## Review fixes (this round)

- **Two `bindSheet` calls collapsed into one.** The Select text panel had silently become dead
  code: the Quote binding replaced it on the same node. One sheet, one kind, both panels reachable.
- **The 13 server-miss shapes.** Reference links (`[x][1]`, `[label][ref]`, `[foo][]`, a shortcut
  in a list item) now resolve through the message's link definitions and show their label; image
  syntax inside inline code is left literal; a bare pipe inside table-cell code splits the row as
  GFM does, and body cells truncate to the header's column count; a line ending in an odd
  backslash run drops the backslash (the server's newline folds to the same space the port joins
  with); the renderer's common named entities (`copy`, `reg`, `trade`, `hellip`, `mdash`, `ndash`,
  `laquo`, `raquo`, `times`, `divide`) decode outside code; `<br>` vanishes from block text (a
  table cell keeps salvaging it as a space); a pipe-wrapped line after a table's blank line keeps
  its pipes instead of being flattened; a nested-bracket image drops whole.
- **A fence inside a blockquote lost its body.** Fence body lines now strip the blockquote prefix
  before the close is matched and before the code is kept, so `> ``` ` … `> ``` ` yields its code.
- **The quote sheet raised the keyboard.** `enableKeyboardOnFocus(false)` did not stop the
  long-press; the TextArea now carries an empty custom keyboard, and its padding keeps the
  selection handle inside the viewport. The `ForEach` key also carries the segment's start.

## Verification

| Gate | Result |
| --- | --- |
| `pnpm --filter @rakazo/harmony harmony:codegen` | regenerated tokens, tables, link patterns, notices, the three catalogs (2639 messages each), client build, voice limits and the 14 embedded fixtures |
| `pnpm exec vitest run apps/harmony/contract` | **195 / 195** (20 files); `quote.json` now holds 61 segment cases and 71 quote cases, every port segment server-checked during generation |
| `pnpm checks` | all green (172) |
| `devecocli build`, `devecocli build --modules entry@ohosTest` | both **BUILD SUCCESSFUL** after `devecocli build clean`; **no ArkTS warning in any file changed here** |
| hypium on the emulator | delegated: `MessageQuote.test.ets` replays the regenerated fixture, so the new shapes run with the suite |
| device walkthrough | delegated: captures `m11-quote-menu`, `m11-quote-sheet`, `m11-quote-selected`, `m11-quote-preview`, `m11-quote-sent` in `apps/harmony/screenshots/` |

"No warning in a changed file" is not "no warning in the build": the six remaining ones are the
M0/M1 files the M7 notes list (`asset-store.ets:56`, `server-store.ets:33` and `:34`,
`sse.ets:200`, `consent-dialog.ets:56` twice), untouched here.

## Known gaps

- **The 4096-char preview window.** `plainTextFromMarkdown` keeps only the first 4096 characters
  of a paragraph; a selection in a paragraph past that point cannot be quoted today. The
  shortcut comment in `message-quote.ets` marks where to lift it.
- **Line-level approximation remains.** A hard break and a backslash hard break fold to one space
  in the port where the renderer keeps a newline (the server's search folds both, so a quote still
  validates); table rows are truncated to the header's columns; a reference shortcut the message
  does not define stays literal, as it renders.
- **A selection drag handle is unreliable to drive on the emulator.** The device check uses the
  long-press word selection the system offers; a precise handle drag is left to a real device.
- **A table nested in a list item still offers literal pipes.** The server renders such a table
  (`- | a | b |` plus an indented delimiter) through remark, but `quoteSourceText` keeps the item
  as list text, so a selection there does not validate. This shape was found while probing beyond
  the review's corpus and is left for a follow-up with the other unlisted differences.