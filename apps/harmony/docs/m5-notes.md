# M5 notes — message rendering aligned with mobile

Rebased onto main `256c7a9cb`; it started on `harmony/m4-settings` (M4, PR #57), see
[Integration](#integration). Scope, design §7.2 M5: how a message
*reads* on HarmonyOS — bot Markdown, @Name mentions, the long-press menu, the reply line and text
selection — each decided by the same rules the mobile app uses. Sending a reply, attachments and
the composer side of mentions stay with M6.

**Status: code complete and green offline; the final build has not run on the emulator.** The
device session that verified this milestone ended when the emulator stopped, and the emulator is
still down, waiting on its owner (see [Device verification](#device-verification)). What that
leaves open is listed there and must be closed before this merges. A first review of the pull
request found eleven issues; all are fixed here and each is recorded under
[Review fixes](#review-fixes).

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
- **Copy code** copies the block's code as its author wrote it, tabs included: a Makefile's recipe
  tab, which mobile's copy button keeps, is not turned into four spaces. The bubble still shows
  the code with its tabs expanded, as every client shows it. **Copy** copies the message's text as
  mobile does (`copyableMessageText`, trimmed).

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
  the result to the real function on a corpus and on 8,000 seeded random strings. Bare domains stay
  text (a file name must not link), as on mobile.
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
  from its own bytes, and 29 code shapes are compared with the real extractor: a Makefile's recipe
  tabs, tabs beside spaces, a fence indented by one to three spaces, a fence opened on a list
  item's own line, a fence in a list and in a quote, a list inside a quote, a tilde fence, an
  unclosed one, two blocks in a message, a tab in an info string and on a blank line, a tab inside
  and at the end of a code line, a list item whose own line is code, blank lines inside indented
  code, CRLF.
  One limit is known: inside a quote whose fence line is itself indented (`> ```` plus one space),
  the port leaves one blank more before the code than mobile's copy does. The two parsers disagree
  there about which blank belongs to the quote mark; tabs are still kept. The fix would mean
  porting markdown-it's quote indentation, which is not worth it for that case.
- **Time that grows with the length.** A message may hold 100,000 characters, and the scan that
  found links by restarting at every letter took minutes on one long word. Five long inputs, each
  with no address, with the start of one at every step, or with addresses throughout, run through
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
| hypium on the emulator | **166 / 166 on the build before the tree-rendering fix**; **not run on any later build** |
| screenshots `m5-*.png` | **none for any later build** |

Two checks stand in for the device only while writing assertions, and are not evidence: the
differential test above, and an offline run of `MessageText` and `MarkdownFixture` under node with
a stand-in for hypium (12 passed, including the 484-document replay) on the reviewed tree.

### Device verification

**What ran on the emulator** (debug-signed HAPs, fixture server, zh-CN locale), all on the build
of that session:

| What | How | Result |
| --- | --- | --- |
| hypium full suite | `hdc shell aa test -b com.botone.app -m entry_test -s unittest OpenHarmonyTestRunner -s timeout 90000` | 166 passed, 0 failed |
| parser + rules on device | `MarkdownFixture`, `MessageText`, `ThreadRender` inside that run | passed (the rules have not changed since; one rename was re-checked offline) |
| long-press menu | long-press a bot message | native menu with 回复 / 选择文本 / 复制 / 复制代码, on the build of that session; 回复 is no longer listed |
| select text | tap 选择文本 | sheet with the message as one block (heading, list, quote, code, table flattened) and 完成 |
| reply line | a bot message answering a user message | `↩ 你: What changed in the release?` |
| user bubble | a user message | rendered; its address was not yet styled as a link |

That session's captures showed the same thing it hid: **every block of a bot message rendered as
one run of inline text** — the renderer treated the document root as inline content. The fix (the
root hands each child its own node) is in this tree and compiles; **no one has looked at it on a
screen.** The captures predated the fix, so they are not committed.

**What has to be re-verified on the emulator, on this tree:**

| What | Looks for |
| --- | --- |
| hypium full suite | 167 passed, 0 failed |
| bot Markdown: heading, paragraphs, list, quote, code block, table, divider | blocks in order, each its own block; code block scrolls sideways with Copy code above it |
| task list | an open box for `- [ ]`, a ticked one for `- [x]`; tapping a box changes nothing |
| inline: bold / italic / strikethrough / code / link, nested marks | every run styled, nothing flattened or dropped |
| soft and hard breaks | a paragraph over two source lines reads as one line; two trailing spaces or a backslash break it |
| links with nowhere to go | `[page](page:…)` in a bot message and a literal page link in a user message read as plain text, not underlined |
| reply line after a change | it shows the parent's text once the parent loads, and re-reads its labels after a language switch |
| Copy code, Copy | clipboard holds the code / the message; `Copied` for 2 s; a Makefile block pastes with its recipe tabs |
| user bubble: address, e-mail, `@Name` | underlined run in the text colour; medium-weight name |
| long-press menu | order 选择文本 / 复制 / 复制代码, no 回复; Select text absent for a message without text; Copy code only with exactly one block |
| select-text sheet | selectable across paragraphs; 完成 closes |
| reply line | author from the preview, else the loaded parent; `Original message unavailable` for a reply without a server preview; a tap scrolls to a parent the transcript holds |
| unknown block | the M3 placeholder, still `UNSUPPORTED_BLOCK` |
| ux-declutter pass | inventory of a real capture, per `.agents/skills/ux-declutter/SKILL.md` |
| long message | no visible stall on a bubble or its menu for a message of 100,000 characters (finding its links takes 3 ms at most in node; the device number is unmeasured) |

**The emulator is stopped, and stays so until its owner brings it back.** It sleeps soon after it
is left idle, and a sleeping emulator stops answering `hdc`. Trying to wake it, this session
toggled its power button several times; it shut down instead and did not come back. It cannot be
started right now: the system disk lacks the space it needs (ErrorCode `00801002`, 12 GB), and
past that the command-line tool asks for the emulator license agreement, which it prints for
review before a yes. Both are the owner's to settle — this change neither starts the emulator nor
accepts the agreement. The instance was last started from DevEco Studio.

Recipe once it is back (keep it awake: a long idle stops it again, and `emulator power` toggles
rather than wakes):

1. The owner frees the disk space, then either `devecocli emulator license` — review, then accept
   — or starts `devphone` from DevEco Studio.
2. Fixture servers: `node apps/harmony/scripts/spike-sse-server.mjs 8787` and the same with `8788`.
3. `pnpm --filter @rakazo/harmony harmony:codegen`; inject a local debug signature into
   `build-profile.json5` the way m0-spike S2 does; build both modules; install both HAPs; restore
   `build-profile.json5`.
4. Run hypium with the command above.
5. Sign in through the fixture server, open a chat, inject a user message and a bot reply to it
   through `POST /__threadEvent` (markdown with a heading, list, quote, one code block and a
   table), and capture `m5-markdown-top`, `m5-markdown-code-table`, `m5-long-press-menu`,
   `m5-select-text` and a user bubble with a link and a mention under `screenshots/`.

## Deferred

- Device re-verification of everything above, and the screenshots it produces.
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
