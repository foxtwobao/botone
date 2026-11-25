# M5 notes — message rendering aligned with mobile

Rebased onto main `256c7a9cb`; it started on `harmony/m4-settings` (M4, PR #57), see
[Integration](#integration). Scope, design §7.2 M5: how a message
*reads* on HarmonyOS — bot Markdown, @Name mentions, the long-press menu, the reply line and text
selection — each decided by the same rules the mobile app uses. Sending a reply, attachments and
the composer side of mentions stay with M6.

**Status: verified on the emulator.** Two reviews of the pull request found eleven and then five
issues; all are fixed here except the one limit a second review allowed to be disclosed instead
(U4, below), and each is recorded under [Review fixes](#review-fixes). The device run is in
[Device verification](#device-verification) — hypium 167/167, every walkthrough row measured, 12
captures. What remains open is listed under [Deferred](#deferred).

## What the bubble does now

`features/chat/MessageBubble.ets` draws one transcript message; every decision it makes comes from
a pure port under `thread/`, one file per reference module:

| File | Ported from | Decides |
| --- | --- | --- |
| `markdown-*.ets` | md4c (the mobile renderer's parser) | Markdown → a tree; the code a copy button copies |
| `markdown-plain.ets` | core `markdown-plain` | one plain line (reply line, preview) |
| `selectable-text.ets` | mobile `selectable-text` | the text the selection sheet shows |
| `message-text.ets` | core `message-text`, `message-replies`, `display-name` | which text a message carries, reply labels, names |
| `message-links.ets` | chat-ui `markdown.ts`, linkify-it's patterns | plain text → text / links / page links |
| `message-mentions.ets` | core `group-mentions`, mobile `message-mentions` | which `@Name` runs highlight, who they name |
| `features/chat/markdown-runs.ets` | — (new) | a node's inline content as flat styled runs |

### Markdown (bot messages)

The M3 regex-lite is gone. Bot text goes through a function-by-function port of md4c, a
derivative work of md4c (MIT): every ported file starts with md4c's notice, and the app ships the
licenses under `resources/rawfile/THIRD-PARTY-NOTICES.txt`.

What the port is held to is the fixture: the same md4c, compiled to WebAssembly inside the mobile
renderer's dependency, run with the flags `scripts/gen-markdown-fixtures.ts` passes (GitHub flavor,
admonitions, permissive autolinks, spoilers; no underline, math, superscript, subscript, highlight,
hard soft breaks or kept blank lines). That is the configuration the port implements, checked
document by document. It is **not** the whole of the mobile call site's parse:

- **Math is where the two differ.** chat-ui passes no parser flags, so the component's default
  applies: `latexMath` is on, and mobile resolves `$…$` as a math span. This app's mobile build
  ships no math renderer (`enableMath: false` in `apps/mobile/package.json`). The port has no math
  flag either way and leaves `$` as text. What a math span looks like on each mobile platform was
  not checked on a device this round.
- Everything else the fixture covers (blocks, inlines, tables, task lists, admonitions, links,
  entities, emphasis) agrees with that parser, not with a screen: no mobile capture was taken
  beside the HarmonyOS one.

The renderer then draws the subset below and degrades the rest explicitly (the mobile column says
what the library documents, not what was captured; this round took no mobile screenshot):

| Tree node | HarmonyOS | Mobile, for comparison |
| --- | --- | --- |
| paragraph, line breaks | styled runs; a soft break (one newline in the source) reads as a space, two trailing spaces or a backslash make a line break | the library's default (`hardSoftBreaks` off) |
| heading 1–6 | bold; title / headline / body / secondary type scale | same |
| bold, italic, strikethrough, inline code | run styles; nested marks flatten into runs carrying every enclosing style | nested spans |
| list item, ordered list | bullet or number (an ordered list keeps its start) | same |
| task list item (`- [ ]`) | a read-only checkbox where the bullet would be | the native renderer's task list |
| quote | bar + muted text | same |
| admonition (`> [!NOTE]`) | drawn as a quote; no kind label or tint | the native renderer's admonition block |
| fenced / indented code | monospace, the full width to scroll sideways, **Copy code** → **Copied** for 2 s | icon button on the block's corner |
| table | rows in order, header cells bold, cells wrap | the native renderer's table |
| link | link colour + underline for the addresses the app may follow (http, https, mailto, tel), which open outside the app; any other destination, a page link and a bot link included, is plain text, since nothing opens yet | page opens in the app, bot sheet opens, external links ask first |
| spoiler | plain text, like any other text | the native renderer's spoiler treatment |
| image | its alternative text | image |
| horizontal rule | divider | same |
| `<video src>` block | the address as a link | the parser reports the block; this app's mobile build excludes the player (`enableVideo: false` in `apps/mobile/package.json`) |

ArkTS's `Span` takes no children, so nested emphasis cannot nest components: `markdown-runs.ets`
flattens the inline tree into runs, each carrying the styles of every enclosing node, and merges
neighbours that share styles. Pure, so hypium checks it.

### User messages: mentions and links

User bubbles stay plain text, as on mobile (`MessageCaption`): explicit http(s) addresses and
e-mail addresses become links, and a link is never searched for names. Following mobile's rule
that link blue is too faint on the user bubble, a link keeps the bubble's text colour and is
underlined; a mentioned name is medium weight in the same colour. **One deliberate difference:**
mobile replaces the `@` with a small bot avatar drawn inline. ArkTS cannot put a component inside a
run of text, so the name keeps its `@` — without the avatar the bare name would read as plain text.

`textWithMentions` (mobile's cut, which folds links into plain runs) is not ported as such: the
bubble needs to know which run is a link, so `userTextRuns` composes the same two real pieces
(`plainTextLinkParts` → `splitMentionText` on the text pieces) and keeps the link.

### Long-press menu

The mobile menu's subset, in its order — **Select text** (the message has text), **Copy**
(always), **Copy code** (a bot message with exactly one code block). Reply, quote, react, speak and
mark-unread come later.

- **Reply is not listed.** The composer's reply flow is M6. An entry that drew and did nothing
  read as a control that failed.
- **Copy code**, from the menu and from the button on the block itself, copies the code as its
  author wrote it, tabs included: a Makefile's recipe tab, which mobile's copy button keeps, is
  not turned into four spaces. The bubble still shows the code with its tabs expanded, as every
  client shows it. **Copy** copies the message's text as mobile does (`copyableMessageText`,
  trimmed).

### Reply line

`ReplyLine` above a message that answers another, by `reply-line.tsx`: nothing for a page-origin
reply; `author: text` from the server's preview, from the loaded parent's text when the preview
has none, or `Original message unavailable` when the server sent no preview for the reply. As in mobile's
`thread-rows.tsx`, the author comes from the preview and falls back to the loaded parent (its
role, author and bot), then to the chat's name, then `Bot`; the signed-in member reads `You`.
Tapping it scrolls the parent to the middle of the list.

### Select text

The long-press entry opens a sheet with the message as one block of selectable text and a **Done**
button (`select-text-sheet.tsx`): bot Markdown converted by `selectableTextFromMarkdown`, so a
selection can span paragraphs, list items and code lines.

## Scope decisions

- **Port md4c rather than write a smaller Markdown parser.** A parser of our own would match
  mobile only where someone remembered to make it match. The port is held to the real parser's
  output document by document (below), so "aligned with mobile" is a measured claim.
- **Link finding runs linkify-it's own patterns.** chat-ui finds links with linkify-it, and a
  hand-written approximation of its rules drew the line wrongly at the edges (a sentence-final
  `alice@example.com.` was not an address; `[https://example.com](https://example.com)` became one
  wrong one). The library itself is not ported. `scripts/gen-linkify-patterns.ts` reads the four
  patterns it compiles for chat-ui's configuration into `link-patterns.generated.ets` (rebuilt by
  `harmony:codegen`, not committed), and `message-links.ets` runs them through the same scan: one
  pass for the schemes, one for addresses written without `mailto:`, then the earliest match wins.
  Which characters belong to an address is the patterns' decision, and the differential test holds
  the result to the real function on a corpus and on 8,000 seeded random strings; a wider one-off
  run of 48,000 (eight seeds) and 9,000 window-stress strings (long runs, brackets, blanks) also
  agreed in full while writing this. Bare domains stay text (a file name must not link), as on
  mobile.

  Two shapes of a long message were still quadratic after that (U1 below): a wall of repeated
  addresses, where the first match swallows the rest, and a parenthesis left unclosed before a
  wall of them, where every candidate's check walked the whole run. The tail is now read through a
  window that ends at the next blank (nothing the patterns read crosses one), or, in a blank-free
  run, through a window that stands only when no bracketed group in it could have closed beyond
  the cut; a candidate that starts inside an address already found is never checked at all, since
  the merge drops it anyway. A run that holds a closing character before an unclosed bracket still
  checks the whole run for each candidate it starts, as linkify-it itself does there.
- **One known gap in the mention rules, found while fixing the link scan and left as it was.**
  core does not count `all` or `所有人` inside a link, and its idea of a link includes a bare
  domain (`x.com/path`). The port finds that range from the links the bubble draws, and those
  leave a bare domain as text, so `x.com/a(@所有人` names `所有人` here and nobody in core. It
  was the same before this round. Over 60,000 seeded strings that mix links and names, the two
  disagree on 122, all of this shape; `mentionSpans` and `mentionStandsAlone` agree on all of
  them. Closing it means porting core's own link pattern (a look-behind and a named group), which
  has to be checked on a device first.
- **`withMentions` is not ported.** It rewrites a message's Markdown to turn bot mentions into
  links (a remark tree walk). The renderer only needs to *read* such links, which arrive in the
  text; producing them belongs to sending (M6).
- **Not wired, and why:** page and bot links (no page surface or bot sheet yet), external-link
  confirmation, the reply line's attachment thumbnail, the mention avatar, a jumped-to message's
  highlight, and loading history around a parent outside the window (mobile's `applyMessageJump`).
  Each needs a surface from a later milestone; none is faked here. A page or bot link is drawn as
  plain text until it has somewhere to go: underlined and inert it read as broken.
- **The reply arrow is a text glyph (`↩`).** It rendered on the emulator, in the system's
  emoji-style blue. Mobile draws a monochrome symbol in the muted colour. A monochrome `SymbolGlyph`
  needs a system symbol name checked on a device, which this round could not do.

## Fixtures and tests

### `contract/fixtures/markdown.json` — 484 documents, layer 2

Expected trees come from the real parser: the same md4c ships as WebAssembly inside the mobile
renderer's dependency, so `scripts/gen-markdown-fixtures.ts` parses every document with *that* and
records the tree. `markdown` is one of `fixtureGenerators`, so `contract/fixtures.test.ts`
regenerates and diffs it like the others, and a change to the
generator fails until the fixture moves with it. The documents: a hand-written corpus (each
construct, tables, entities, nesting, adversarial emphasis), the named-entity table in slices, and
240 seeded random documents from `scripts/markdown-fixture-corpus.ts` — pieces chosen so one
recognizer meets the next one's (`**` beside `_`, backtick runs, full-width punctuation, combining
marks, astral letters).

`ohosTest/.../MarkdownFixture.test.ets` replays all 484 on the device through the ArkTS port and
compares each tree as one JSON string.

During the port the same oracle ran over thousands more fuzz documents with a shrinker; the
differences it found were all in the port (reference-definition titles spanning lines, inline code
across lines, container state leaking between siblings, emphasis marks surviving one block into
the next) and each became a fixture case. Outside the fixture on purpose: a lone surrogate code
unit. The oracle's WebAssembly string bridge replaces it with U+FFFD on the way in while the port
keeps the unit, so the two cannot agree there; well-formed text, astral pairs included, does.

### `contract/message-text-port.test.ts` — differential, not a fixture

The message rules are dozens of small decisions over hand-picked inputs, and their references are
plain TypeScript, so the test compares the port with the real functions directly: the port's `.ets`
loaded as erasable TypeScript against `@rakazo/core`, `@rakazo/mobile`, chat-ui's real link
splitter and its real code block extractor, over a corpus of names, mention texts, links, replies
and Markdown. A disagreement prints the case. It covers display names, mention spans and targets,
user-bubble runs, link parts, selectable and copyable text, block text, reply labels and previews,
the one-line and selectable Markdown conversions, the flat run list, and what the menu copies and
shows. `sanitizeMarkdownUrl` is the one rule written out as literal expectations: chat-ui's
package entries do not re-export it.

Three more cases sit beside it, each written to fail on the code it replaced:

- **Links in seeded random text.** 8,000 short strings built from the characters that decide a
  link's edges, a page link's brackets and the letter case of a scheme included, compared with the
  real splitter. It found two faults no hand-picked input had: an address found by the `mailto:`
  scan was given the scheme twice, and an upper-case `HTTPS://` was dropped.
- **Code as the copy button copies it.** The port reads a code line's indentation as columns and
  shows that many blanks. Mobile's copy button reads the same block with a second parser
  (markdown-it, through the markdown-display package), which takes the indentation off character
  by character and keeps the tabs left over. `markdown-code.ets` reads each line the second way
  from its own bytes, and 35 code shapes are compared with the real extractor: a Makefile's recipe
  tabs, tabs beside spaces, a fence indented by one to three spaces, a fence opened on a list
  item's own line, a fence in a list and in a quote, a list inside a quote, a tilde fence, an
  unclosed one, two blocks in a message, a tab in an info string and on a blank line, a tab inside
  and at the end of a code line, a list item whose own line is code, blank lines inside indented
  code, a tab right after a quote mark, CRLF. The value the button on a block copies is the same
  one, read off the tree the bubble renders, and is compared with the real extractor too; the
  shapes a quote's indented fence line still gets wrong are pinned by literal expectations.
  One limit is known, and a second review allowed it to stay disclosed (U4): inside a quote whose
  fence line is itself indented, the copied indentation can differ from mobile's by the columns
  the two parsers give the quote mark. With a space after the mark (`>  ```) it is one blank; with
  a tab wider than one column in the mark's place the tab itself stays whole where mobile's copy
  may eat columns of it (a fence line reading `>`, tab, fence, over a code line reading `>`, tab,
  tab, copies the whole `\t\tx` here where mobile's copy eats two columns of the first tab). A tab after
  the mark on a plain `> ``` fence line is copied whole, as on mobile. Closing this would mean
  porting markdown-it's quote-mark arithmetic (its `bsCount` and `adjustTab`), which is not worth
  it for shapes that rare; the divergent shapes are pinned by literal expectations so a change is
  seen.
- **Time that grows with the length.** A message may hold 100,000 characters, and the scan that
  found links by restarting at every letter took minutes on one long word. Five long inputs, each
  with no address, with the start of one at every step, with addresses throughout, with one wall
  of repeated addresses and with a parenthesis left unclosed before them, run through
  `expectLinearTime`. On the replaced scan the first of them alone ran 69 s before the limit
  stopped it; on this one each takes under 3 ms in node (best of five). The device is unmeasured.

Each run materializes the port into a directory of its own (`mkdtemp`, removed afterwards): two
runs at once, from two worktrees or two workers, used to delete and read each other's copy.

Loading the reference needs two mocks keyed by resolved path, because this package declares
neither dependency and the link splitter is exported only from chat-ui's native entry, which
imports react-native at module scope (Flow source node cannot load). A bare
`vi.mock("react-native")` is keyed by the bare name here and misses that import, so the test
resolves both files the way mobile's modules see them. If chat-ui's native entry starts importing
another react-native name at module scope, this test names it and the stub gains a line.

### hypium

| Suite | Cases | Checks |
| --- | --- | --- |
| `MarkdownFixture` | 1 | the 484-document replay |
| `MessageText` | 11 | names, mention spans and targets, runs with links, link parts, selectable/copyable/block text, reply rules, previews, both Markdown conversions, the menu, a copied code block keeping its tabs |
| `ThreadRender` | 2 replaced | the old regex-lite cases became `markdown_tree_blocks` and `markdown_inline_spans` |

## Copy

**No new catalog entries, no new harmony-only strings.** The 11 msgids M5 passes to `t()` all exist
in the shared catalog for en, zh-CN and zh-TW, and each names a control whose meaning a newcomer
cannot get from the screen alone:

| msgid | zh-CN | Where | Why the word is needed |
| --- | --- | --- | --- |
| `Select text` | 选择文本 | menu | not guessable from the message it is long-pressed on |
| `Copy` | 复制 | menu | says what the entry puts on the clipboard |
| `Copy code` / `Copied` | 复制代码 / 已复制 | code block | the button acts on the block under it; `Copied` is the only confirmation the clipboard was written |
| `Done` | 完成 | selection sheet | the sheet's one way back; the platform place for it |
| `Original message unavailable` | 原消息不可用 | reply line | replaces an author and text the transcript does not have |
| `Photo` / `Attachment` / `Message` | 照片 / 附件 / 消息 | reply line, preview | stand in for a parent that is not text |
| `You` / `Bot` | 你 / Bot | reply line | the author when the parent is the signed-in member, or a bot the roster does not name |

Each appears only on the surface it belongs to (menu, sheet, code block, reply line), so none is
persistent chrome. `i18n/harmony-strings.ets` is unchanged: its five existing strings (the SSO
notice, `AI_CONSENT_REQUIRED`, `consentSummary`, `consentTitle`, `UNSUPPORTED_BLOCK`) are what they
were; the unsupported-block placeholder reuses `UNSUPPORTED_BLOCK`. `Reply` stays in the shared
catalog for M6; nothing passes it to `t()` in this milestone now.

## Verification

| Gate | Result |
| --- | --- |
| `pnpm exec vitest run apps/harmony/contract` | **96 / 96** on the reviewed tree |
| `pnpm checks` | **160 / 160** on the reviewed tree |
| `pnpm lint` (Biome) | 0 errors |
| `pnpm --filter @rakazo/harmony harmony:codegen`, then `devecocli build` and `devecocli build --modules entry@ohosTest` | both **BUILD SUCCESSFUL** on the reviewed tree, no ArkTS warning in an M5 file (unsigned HAPs: the committed `build-profile.json5` keeps `signingConfigs: []`) |
| the notices file inside the built HAP | `resources/rawfile/THIRD-PARTY-NOTICES.txt` is there, 6.5 KB |
| hypium on the emulator | **167 / 167 on this tree's build** (twice; see [Device verification](#device-verification)) |
| screenshots `m5-*.png` | **12 captures of this tree**, covering every verification row |

Two checks stand in for the device only while writing assertions, and are not evidence: the
differential test above, and an offline run of `MessageText` and `MarkdownFixture` under node with
a stand-in for hypium (12 passed, including the 484-document replay) on the reviewed tree. The
device run since then is the evidence that counts (below).

### Device verification

**Environment this round** (the toolchain moved): DevEco and its SDK live under
`/Volumes/Data/sdk/deveco/`, the emulator (`devphone`, started by the owner) answers `hdc` at
`127.0.0.1:5555`, and this worktree itself now lives on the Data volume. Every device command
sets `DEVECO_CLI_STUDIO_PATH` and friends explicitly, since a non-interactive shell loads no rc
files. The emulator was never powered off or restarted by this round; the walkthrough script keeps
it awake by probing it, never by toggling power.

**What ran on the emulator** (debug-signed HAPs of this tree's build, fixture servers on
8787/8788, zh-CN locale), in the m0-spike S2 shape: `devecocli signature generate --force` writes
a local debug signing config into `build-profile.json5` (reverted after; the committed file keeps
`signingConfigs: []`), both modules build signed, both HAPs install.

| What | How | Result |
| --- | --- | --- |
| hypium full suite | `hdc shell aa test -b com.botone.app -m entry_test -s unittest OpenHarmonyTestRunner -s timeout 90000` | **167 passed, 0 failed** (twice: after install, and again after the fixture fix below) |
| bot Markdown: heading, paragraphs, list, quote, code block, table, divider | a bot reply carrying all of them, screenshot `m5-markdown-top` / `m5-markdown-code-table` | every block its own row, in order; code block scrolls sideways with the copy button above it |
| task list | `- [ ] open task` and `- [x] done task`, taps on the boxes | an open circle and a ticked one; **tapping either changes nothing** |
| inline: bold / italic / strikethrough / code / link, nested marks | the same message | every run styled, nothing flattened or dropped |
| soft and hard breaks | a paragraph over two source lines, then two trailing spaces | one line reads as one; the hard break makes the next line |
| links with nowhere to go | `[dead page link](page:p9)`, a bot link, in a bot message (screenshot `m5-dead-links`) | plain text, no underline; the address beside them is blue and underlined |
| reply line | a bot reply with a server preview (screenshot `m5-reply-jump`) | `↩ 你: What changed?`; a tap scrolls the parent into view |
| reply line after a re-read | leave the thread and re-enter (a `threads/get` refresh) | the reply line stays (see the fixture fix below) |
| reply line after a language switch | — | **not verified**: switching the system language needs the settings app, which this walkthrough could not drive; the code path (the build reads tracked values, not builder-captured ones) is what review approved in S2 |
| Copy code (menu) | long-press → 复制代码; the host clipboard reads the same content | `build:\n\techo hi\n\tcd /tmp` — **the recipe tabs are real tabs** |
| Copy code (button on the block) | tap 复制代码 on the block; screenshot `m5-copy-code-copied` | clipboard the same; **已复制** shows for its two seconds and restores |
| Copy (message text) | long-press → 复制 | the clipboard holds the message's Markdown source, trimmed, as mobile does |
| user bubble: address, e-mail, `@Name` | a user message with all three | the address and the e-mail underlined in the text colour; the medium-weight name needs a member roster the fixture thread did not carry, so only the link styling was seen |
| long-press menu | screenshot `m5-long-press-menu` | 选择文本 / 复制 / 复制代码 in that order, **no 回复**; Select text absent for a message without text (the live progress row); Copy code only with exactly one block |
| select-text sheet | tap 选择文本; screenshot `m5-select-text` | the message as one selectable block (heading, list, quote, code, table flattened; the task markers read `• [ ] open task`, exactly as mobile's conversion renders them — its own test says so) and 完成 closes it |
| unknown block | a `video_call` block; screenshot `m5-unknown-block` | the placeholder, `This content is not supported on this device yet.` |
| long message | a 100,000-character message with 80 addresses, then a long-press on it | the bubble renders in one frame pass; the menu comes up in under 5 s of polling (the walkthrough's own layout dumps take most of that) |
| font scale | `param set persist.ace.fontsize 1.3`, app restarted; screenshot `m5-thread-font-max` | every markdown element still readable; restored to 0.85 afterwards |

**ux-declutter pass** (every M5 screenshot, per `.agents/skills/ux-declutter/SKILL.md`): one
accent colour (link blue) beside ink, muted and the bubble's black; no element repeats another;
the copy button's word form stays the recorded degrade (an icon needs a symbol name checked on a
device, deferred with the reply arrow). Nothing to remove.

**One finding, fixed: the fixture server dropped reply metadata.** The walkthrough's first pass
showed the reply line rendering when the reply arrived live, then losing it after leaving and
re-entering the thread. The store's own merge keeps reply fields; the loss was in
`scripts/spike-sse-server.mjs`: when it materializes a thread's messages for a `threads/get`
refresh, it copies `id/seq/role/blocks/botId/createdAt/runId` and drops `replyToMessageId`,
`replyQuote` and `replyPreview`. Those three fields now ride along (the real server keeps them;
the script only failed to). The walkthrough re-ran green and hypium re-ran 167/167 after the fix.

The captures are in `screenshots/m5-*.png`: markdown-top, markdown-code-table,
copy-code-copied, long-press-menu, select-text, task-list, reply-jump, dead-links,
unknown-block, long-message-menu, paste-menu, thread-font-max.

## Deferred

- Reply (M6): the composer flow and its menu entry, optimistic replies and their reply line.
- A way to read the shipped notices in the app (an entry in Settings). The file ships; no screen
  shows it yet.
- Code copied from a fence inside an indented quote line (one blank more than mobile's copy; see
  the differential test above).
- Page and bot links, external-link confirmation, the mention avatar, the reply thumbnail, the
  jump highlight and loading history around a parent outside the window.
- A monochrome reply arrow, and an icon for Copy code, once symbol names are checked on a device.
- Math spans: the port leaves `$…$` as text; mobile resolves them and this app's mobile build
  cannot draw them either. Whether both should agree on plain text is a product decision.
- Admonition callouts, blurred spoilers, images, video and sideways-scrolling tables.
- Links beyond what chat-ui's configuration finds (fuzzy domains, `www.`), which stay text on
  mobile too.

## Review fixes

A first review of the pull request asked for changes: two blockers, eight should-fixes and a nit.
Each is fixed in this tree; what follows says what was wrong and what changed.

| Finding | What was wrong | What changed |
| --- | --- | --- |
| B1, link scan quadratic | The scan restarted at every letter and cut the text again for each, on the rendering path of every user bubble. Measured in node on the old scan: 1.2 s for 10,000 letters of `a@` repeated, and about two minutes for one word of 100,000 letters, which a send may hold. | One pass per scan with linkify-it's own patterns (above). A regression case runs five long inputs through `expectLinearTime`; the old scan fails it at 69 s, the limit being 3 s. |
| B2, md4c's license missing | Nine files were a function-by-function port of md4c (MIT) and named it, but carried neither its copyright line nor its license; the built app shipped none. | Each ported file starts with md4c's notice, whole and in its original wording; the generated tables carry it too. `resources/rawfile/THIRD-PARTY-NOTICES.txt`, built by `scripts/gen-notices.ts` from each dependency's own license text, ships in the HAP and lists md4c, react-native-enriched-markdown, linkify-it, uc.micro and markdown-it. `contract/licenses.test.ts` holds the headers to the notice in md4c's source, so a dependency update that changes it fails here. |
| S1, Reply placeholder; links with no action | A **Reply** entry drew and did nothing. A page link and a bot link were underlined like links and did nothing. | Reply is not listed until M6 gives it a composer flow. A link is drawn as one only when the app can follow its address; the rest is plain text. The sanitizer chat-ui uses decides, so the bubble no longer keeps a second copy of that rule. |
| S2, reply line built once | The line was drawn by a `@Builder` that took its parts by value, so it kept the parts it was first built with: a parent that loaded later, or a language switch, could leave the old text on screen. | `build()` passes the tracked parts to `ReplyLine` itself. The sheet and the menu read the message the same way, and the menu is a computed value instead of a hand-kept cache. |
| S3, clipboard callback after teardown | A copy whose clipboard write had not returned could still set the copied state and start a new timer after its block was gone. | The block marks itself gone in `aboutToDisappear`, and the callback stops there. |
| S4, fixed temporary directory | Every run of the differential test deleted and rewrote the same folder, so two runs at once (another worktree, another worker) deleted or read each other's copy of the port. | Each run gets a directory of its own and removes it afterwards. |
| S5, copied code lost its tabs | The menu's Copy code offered the code as the bubble shows it, with every tab expanded to blanks, while mobile's copy button keeps them: a copied Makefile no longer built. The test expected whatever a pre-filter matched, so it could not see this. | The code is read as mobile's copy button reads it (`markdown-code.ets`), and the test compares the menu with what mobile builds it from, by its real extractor. |
| S6, link boundaries | `alice@example.com.` at the end of a sentence was not a link, and the literal `[https://example.com](https://example.com)` became one wrong address. | Both come out of the patterns, and both are in the differential corpus. |
| S7, soft breaks | A soft break inside a paragraph was drawn as a line break; mobile draws a space. A test asserted the difference. | A soft break reads as a space, a hard one (two trailing spaces, a backslash) as a line break. The test asserts both. |
| S8, promises too wide | The notes said the port used "the mobile call site's flags" and built "the same tree mobile renders from"; mobile resolves `$…$` as math. The render table said mobile plays video; this app's mobile build has no player. | Both passages now say what was checked and where the two differ (above). |
| Nit | An inline `typeof import(…)` type, and two trailing blank lines. | Top-level `import type`, and a clean `git diff --check`. |
| U1, link scan quadratic again | Two shapes of a long message still grew quadratically: a wall of repeated addresses (the first match swallows the rest, so every later candidate's check re-walked it) and a parenthesis left unclosed before such a wall (every check walked the whole run looking for its closing bracket). Measured in node: 8.2 s and 7.3 s for 200,000 characters. | The tail is matched through a window that ends at the next blank, which nothing the patterns read crosses; a blank-free run is read through a shorter window that stands only when no bracketed group could have closed beyond the cut, and otherwise settles on the whole run. A candidate that starts inside an address already found is never checked: the merge drops it anyway. Both shapes joined the `expectLinearTime` case, which the old code fails at 7.7 s; the port answers both in under 10 ms, and 48,000 random strings and 9,000 window-stress strings still agree with the linkifier. |
| U2, contract tests needed the codegen | On a clean checkout that had not run `harmony:codegen`, three contract tests failed: the port is materialized from files the codegen writes. | The test materializes the generated modules itself, from the same generator functions the codegen runs, so any environment that runs vitest runs it. Verified with the generated files moved away. |
| U3, the button still lost tabs | The copy button on the block itself copied `node.text`, the shown form with tabs expanded; only the menu path had been fixed. | The tree's codeblock node carries the code as written beside the code as shown, and the button copies that. The menu and the button read the same value, one parse serves them, and the differential test compares what the tree carries with the real extractor. |
| U4, quote-mark tabs | A tab right after a quote mark was cut into blanks (`>		x` copied `  	x`); mobile copies `		x`. | The parser takes a column of such a tab for the mark and the copy rule leaves it in the line, so the column is now given back and the tab is copied whole. The reported shape and its plain-fence variants match mobile; a quote whose fence line is itself indented still differs by the mark's columns, disclosed above, and pinned by literal expectations rather than a comparison, since the two parsers disagree there. |
| U5, trailing blank lines | `git diff --check origin/main...<head>` flagged a blank line at the end of two files. | Both trimmed; the check runs clean against the branch head. |

The menu rule lost its `readOnly` and label arguments with the Reply entry: nothing read them.
`MessageMenuLabels` is gone with it.

## Integration

The branch is rebased onto main `256c7a9cb`, which had moved 354 commits past the M4 merge it
started from. Two of its pull requests touch the same files as this work:

- **#61 writes generated JSON through Biome.** This branch once carried its own `style` commit
  formatting the same four files (`fixtures/thread.json`, `snapshots/auth-capabilities.json`,
  `snapshots/health.json`, `snapshots/me.json`). Its result was byte-identical to what #61
  produced — the same four blobs — so git dropped it during the rebase ("patch contents already
  upstream") and nothing of it remains. `markdown` is one of `fixtureGenerators`, so the fixture
  drift test writes it through #61's `write-generated.ts` like the others.
- **#59 makes the composer's send button a square icon button.** `ThreadPage.ets` changed on both
  sides and merged without a textual conflict: the edits are in different places. Kept from #59 as
  it is — `COMPOSER_CONTROL_SIZE`, the icon-only send button (`ButtonType.Circle`, as wide as it
  is tall) with the `sys.symbol.arrow_up` symbol, its `thread-send` id and its `Send` accessible
  name. Kept from this branch — `parentOf`, the
  `parent`, `members`, `meId` and `fallbackAuthor` arguments the bubble now takes, and the
  scroll to the parent inside `onJumpTo`. Against main the file differs by those 26 added lines
  only; the long-press menu and every other M5 surface live in `MessageBubble.ets`, which #59 did
  not touch.
- **The rest: #62 syncs upstream, #60 names the client kind, #63 and #64 fix the hook and CI.** None
  touches an M5 file. The sync moved the reference code the differential test compares against;
  the port still matches it, and the 12 msgids M5 uses are still in all three catalogs.

The dependency install was repeated for the new lockfile. Offline gates on the rebased tree:

| Gate | Before the rebase | After |
| --- | --- | --- |
| `pnpm exec vitest run apps/harmony/contract` | 86 / 86 | **90 / 90** |
| `pnpm checks` | 155 / 155 | **160 / 160** |
| `pnpm lint` | 0 errors | 0 errors |
| `harmony:codegen`, then `devecocli build` and `devecocli build --modules entry@ohosTest` | both built | both **BUILD SUCCESSFUL**, no ArkTS warning in an M5 file |
| strict `tsc` over the ports, and `MessageText` + `MarkdownFixture` run offline under node | passed | passed |

The counts rose because main added cases; nothing of M5 changed in the rebase. The hypium suite
still holds 166 cases, none of them run on this tree: device verification stays as above. The
branch is pushed through the repository's pre-push hook — lint, the whole test suite, the build —
with no step skipped.
