# M4 notes — settings + quality close-out

Stacked on `harmony/m3-chat` (M3, dbdabac31, PR #55). Scope: design §7.2 M4 — SettingsPage, the
i18n/ICU close-out, performance calibration (font scale + long lists), the repeatable emulator
smoke, the offline/error-copy and ux-declutter walkthroughs, and the Phase 1 acceptance checklist.
**Fix round (same branch):** the independent verification's two blockers — the hot-locale
Pinned-heading residue (fixed, `HotLocale.test.ets` + device walkthrough) and the 10k memory
claim (redone as the design-R4 history window, `perf-sample.mjs` + the measured curve below) —
plus the four documentation corrections (hypium re-run timeout, smoke coverage wording, the
SP_daemon real-display precondition, the changed-areas budget note and screenshot dedup).
All product code lives under `apps/harmony/` plus one line in `.github/scripts/changed-areas.test.py`
(the trigger assertion for the newly consumed reference — an M0-approved budget file; the
coordinator ruled it stays in this milestone, the verifier's boundary exception is accepted);
the committed `build-profile.json5` keeps `signingConfigs: []` (signing material is injected
locally for emulator installs only).

Environment: same as M1–M3 (DevEco 26.0.1.290 / API 26 Beta1, `devphone` emulator at
127.0.0.1:5557, guest reaches host at 10.0.2.2). Fixture servers on host 8787/8788; every
verification below ran on the emulator with debug-signed HAPs unless marked otherwise.

## SettingsPage (design §7.2 M4, Q6)

One read-first screen: identity (name + email), Space, server (navigates to the M1 ServerPage),
model (read-only), appearance, language, version, sign-out. Structure: cards of label/value rows;
appearance and language rows open native `bindMenu` menus with `selected` marks; sign-out is the
single destructive action at the bottom. The M3 `MePage` is deleted (the inbox avatar now opens
settings; its accessible name is the shared `Settings` msgid).

Verified on device (fixture server, zh-CN system locale):

| What | How | Result |
| --- | --- | --- |
| Identity + Space + server rows | sign in → avatar | Ada / ada@example.com / Ada's Space / server URL |
| Model row, matched | `defaultModelEntry(me, catalog)` | server label "Fake Fast Model" |
| Model row, no match | `POST /__models {"catalog":[]}` + roster signal | 「空间默认」 (reused `Space default` msgid) — never a raw id |
| Model row, live refresh | roster signal while the page is open | label swaps both ways without reopening |
| Appearance menu | tap 外观 → 系统/浅色/深色 | palette + label flip live; preference survives app restart |
| Language menu | tap 语言 → 系统/English/简体中文/繁體中文 | whole screen re-renders live; survives restart; back to 系统 follows the device locale |
| Version row | `bundleManager.getBundleInfoForSelf` | 1.0.0 |
| Server row | tap | pushes the M1 ServerPage |
| Sign-out | tap 退出登录 | server `auth/signOut` seen; lands on the sign-in screen |

Two device-found ArkTS fixes worth keeping in mind:

- **@Builder parameters bind once.** A label/value row built as a @Builder with primitive params
  never refreshes: the model label, appearance label and language label all rendered their first
  value forever (the model row stayed stale through roster signals; the appearance row showed 系统
  after picking 深色 even though the palette flipped — the palette re-rendered through a different
  traced read). `ValueRow` is a `@ComponentV2` child with `@Param` values, which re-sync on the
  parent's re-render. Same class of bug: a `CustomBuilder` passed *through* a @Builder parameter
  never opens — `bindMenu` must sit on the row in `build()`.
- **The session-phase swap only replaces the root screen.** After sign-out the pushed settings
  destination stayed on top of the sign-in page (an empty settings screen). `doSignOut` now calls
  `stack.clear()` after the RPC resolves.

## i18n close-out

**ICU-lite, whole catalog.** The fixture now covers every brace-bearing catalog entry (interpolation
and plural) — 1,698 replay cases (566 msgids × 3 locales), replayed under hypium against the
committed `contract/fixtures/icu.json` (lingui `activateUiLocale` produces the expected strings at
generation time). Edge corrections found by the fixture: the plural category is chosen on
`count - offset` (not the raw count), `=N` matches the raw count, `#` renders through a cached
`Intl.NumberFormat` per locale, a missing value renders empty, and a negative count needs
`hashValue: number | null` (0 is a value). Two known limits are documented in code, not silently
dropped: `quote()` handles only single-character escapes (no `'{name}'` literal sections — no
catalog entry needs them; the shortcut comment says to upgrade if one appears), and the three
synthetic quote cases were removed from the fixture because lingui's quoted-section behavior
diverged from ICU for them.

**Dates.** `contract/fixtures/dates.json` grew from 27 to 45 cases and now covers both product
date surfaces, each generated from the real reference and replayed on device:

- inbox row times — mobile `formatThreadTime` (today clock / weekday / short date);
- thread day separators — core `formatTimeSeparator` (Today/Yesterday + clock, weekday + clock,
  short date + clock, the year only when it differs). The separator port (`i18n/dates.ets`)
  replaced the old unlocalized `YYYY/M/D` day label; the labels ride in the fixture per case so
  the replay needs no loaded catalog.

Platform Intl divergences found on device and handled explicitly (all documented in the replay's
normalization comment):

- Node puts U+202F (narrow no-break space) between clock and AM/PM; the device uses U+0020. The
  replay normalizes both sides — the fixture pins the rule, not the byte.
- The device pads a single-digit hour ("09:30") where Node does not ("9:30"); normalized too.
- The device's zh-CN default hour cycle is h12 (下午2:44) where Node/ICU default to h23 (14:44).
  The port pins the cycle per shipped locale (`HOUR_CYCLES`: en h12, zh-CN h23, zh-TW h12 — the
  CLDR defaults every other surface uses), so the separator clock matches web/mobile.
- A cache-key bug the fixture exposed: two option sets under one locale need two formatter caches
  (the same-year pattern cached first made the different-year case silently drop the year).

**Fixture drift picked up by the regeneration.** The whole-catalog regeneration also recorded two
upstream reference changes since M3: the endpoint fixture's not-a-server copy now reads
"That URL did not look like a BotONE server" (the product rename), and the password-policy msgid
interpolates `{MAX_PASSWORD_LENGTH}` instead of `{max}`. Both fixtures, their embedded hypium
constants and the replays move together (the documented update path); vitest 83/83 and hypium
145/145 run against the new set.

**New copy: none.** M4 adds zero new msgids. The model fallback reuses `Space default`; the
appearance row reuses `System`/`Light`/`Dark`; the language row reuses `System`; locale names
(English / 简体中文 / 繁體中文) are product data, not copy (core `APP_LOCALE_LABELS`). The
harmony-only strings in `i18n/harmony-strings.ets` are unchanged, pre-existing M1/M3 copy: the SSO
notice, `AI_CONSENT_REQUIRED`, the consent title/summaries, and the unsupported-block placeholder
(six strings; they render in English until the translation workflow extracts `.ets` sources —
feature PRs never run `intl:extract`).

**Preference plumbing.** Appearance and language choices persist in `preferences`
(`rakazo.uiAppearance`, `rakazo.uiLocale`), System hands the window back to the OS
(`setColorMode(NOT_SET)`) so native surfaces follow the system mode, and `onConfigurationUpdate`
re-resolves the locale only when the choice is System and the device locale actually moved. The
catalog reload bumps a `revision` trace so a same-locale reload still re-renders.

**Fix round — the hot-locale blocker (verifier 4b).** A locale switch with the Inbox open left
the Pinned heading in the previous language: `items()` baked `t('Pinned')` into the list item at
projection time, and the render read the stored string — the revision trace re-rendered the
header but never the stored label. The rule now: **projections carry data, translations resolve
in `build()`**. The inbox projection (`inboxDisplayItems`) is pure — the heading item holds no
text, the entry builder renders `t('Pinned')`, and the LazyForEach key is locale-independent
(`heading`, not `heading-<translated>`). The same class was fixed preemptively in the thread:
day-separator rows carry the timestamp (`dayAt`), and `daySeparatorLabel` resolves at build time.
Pinned by `HotLocale.test.ets`: the projection carries no baked text, and a real catalog switch
re-translates `t('Pinned')` and the separator in **both directions** (zh-TW → en and en → zh-TW,
the two the verifier reproduced); device walkthrough below re-checked both first-return screens.

Device walkthrough (fixture 8787, layout-tree assertions at every step): en inbox shows
`Chats / Archived / Pinned`; switch 繁體中文 in settings, first Back lands on `聊天 / 已封存 /
置頂` — no `Pinned` residue; switch back to English, first Back shows `Chats / Archived / Pinned`
— no `置頂` residue; a second en → zh-TW pass returns to `置頂` again, and the open thread's day
separator renders `今天 上午10:35` live. The old code reproduced the bug in both directions
before the fix (verifier 4b captures); the same two directions now pass on the fixed build.

## Performance calibration

**Font scale / accessibility.** `AppScope/resources/base/profile/configuration.json` opts into
`followSystem` and caps at `fontSizeMaxScale: 1.3` — the largest allowed enum step that keeps body
text within ui-tokens' `MAX_FONT_SCALE` (23pt ceiling); `contract/font-scale.test.ts` pins the
calibration to the real tokens (mutation-checked: a cap change, an enum violation, or dropping the
manifest reference goes red). On device, the system font set to 最大 (特大, 5.0× sample text)
leaves every screen intact — settings rows ellipsize their values, the inbox keeps one row per
line, the thread stays readable (screenshots `m4-inbox-font-max.png`, `m4-thread-font-max.png`,
`m4-settings-font-max.png`); the emulator's standard scale is 0.85.

**Long lists.** Method: `uitest uiInput fling` drives fixed-velocity full-screen flings;
`SP_daemon -r -PID <pid> -print` samples `pss` (kB) around them. Seeded with the new fixture hooks
`/__inboxSeed` (500 rows) and `/__threadSeed` (10,000 messages, unchanged from M3).

500-row inbox (PSS):

| point | PSS |
| --- | --- |
| after first paint | 63.8 MB |
| after traversal 1 (20 flings) | 107.9 MB |
| after traversal 2 (reverse) | 122.7 MB |
| after traversal 3 | 129.5 MB |
| after traversals 4 / 5 | 131.3 / 129.1 MB |

Per-traversal deltas 44 → 15 → 7 → 2 → −2 MB: the allocator's high-water mark converges (~130 MB)
and one traversal went down — the LazyForEach window (List + `LazyForEach` + `cachedCount(8)`) is
not building 500 rows, and there is no per-traversal leak.

10k-message thread — **the history window (design §9 R4)**. The original M4 claim ("full
traversal, memory flat") did not survive independent verification: 40 flings only reached
`history 9501`, and paging entry-by-entry to `history 1` grew PSS ~81% over the open point —
every loaded page stayed in the store, so memory grew linearly with history, exactly what R4
forbids. The fix is the paging window R4 names: **at most 1,000 durable messages stay loaded**
(`thread/thread-window.ets`, applied at the stream's single commit point, so open/settle/
disconnect refreshes and prepends all pass through it). Paging back moves the reading position
to the OLD end, so the window keeps the oldest loaded messages and evicts the NEWEST side —
evicting the old end would drop the page the reader just loaded. `olderCursor` keeps pointing
below the oldest loaded message (the next page reads on), and live progress/subagent rows always
survive. When the newest side was evicted the transcript offers **Jump to latest** (existing
catalog msgid, mobile's `JumpToLatestButton` pattern): one `threads/get` re-reads the recent page
without a reopen — the live cursor, run state and stream survive (`historyExpanded` clears, so
the refresh replaces instead of preserving).

**Why 1,000 (ten server pages of 100):** ~10× a screenful of bubbles, so eviction never fires
near the reading position; the 500-row inbox calibration above showed the render/allocator
high-water mark converges around that scale; and the measured plateau below confirms the budget
holds. The window is a count of messages, not pages, so a short final page cannot shrink it.

Repeatable measurement: **`node apps/harmony/scripts/perf-sample.mjs`** (committed; preconditions
in its header — fixture 8787, connected emulator, installed app). It seeds 10k, signs in, opens
the thread, pages to `history 1` through the paging entry (the verifier's route — flings stop
wherever the window lands; the list's own onReachStart may absorb a page, progress is measured
by the loaded floor moving older), samples `SP_daemon -r -PID <pid> -print` total PSS (raw kB)
at open, every 10 pages, at the end, and after Jump to latest; it asserts the traversal really
reached `history 1` and prints the curve. Re-run numbers (emulator, debug-signed HAP, final
build of this branch):

| point | PSS (kB) |
| --- | --- |
| open + settle (recent 100) | 98,020 |
| page 10 (window full — 1,000 loaded) | 114,113 |
| page 20 / 30 / 40 | 105,402 / 114,069 / 114,281 |
| page 50 / 60 / 70 | 115,111 / 94,893 / 104,776 |
| page 80 / 90 | 109,027 / 110,337 |
| end — `history 1` painted, no older entry (98 pages) | 113,643 |
| after Jump to latest (recent page again) | 114,171 |

Reading: the first ten pages (open → window full) cost ~16 MB; from there to the very first
message the curve is **flat** (94.9–115.1 MB band, no upward trend across 88 more pages) —
memory no longer grows with history depth (design R4's goal). Budget: **≤ ~125 MB PSS
(open + ~28%) for any depth**; the pre-fix build measured +81% over open at the same endpoint.
The jump back to latest costs nothing (+0.5 MB) and re-reads exactly one page.

The earlier 40-fling numbers are kept only as the record of what the claim was based on; they
are NOT a full traversal and must not be cited as one:

| point | value |
| --- | --- |
| open latency (tap → composer visible, 0.5 s poll bound) | ≤ 1.5 s |
| PSS after open + settle | 122.5 MB |
| PSS mid-traversal (20 flings, reached `history 9601`) | 106.0 MB |
| PSS after 40 flings (reached `history 9501`, NOT the end) | 105.5 MB |
| per-fling injection cadence | 0.22 s — identical to the inbox's 0.21 s |

**Frame rate, and why the number is not an fps.** This emulator's composer exposes no frame
statistics: `SP_daemon -f` reads `fps=0` through every mode (`-print`, `-start/-stop` csv,
`-VIEW DisplayNode`), `hidumper -s RenderService` has no frame dump, and an in-process
`displaySync` probe delivered zero callbacks even while host-driven flings ran (that probe was
tried and removed — it cannot work from the test runner's context). The repeatable replacements,
recorded above: open latency, full-traversal cadence (flat vs the small-list control), and the PSS
curve. The S5 CI runner (real display) is where `SP_daemon -f` works; the recipe is
`SP_daemon -start -f -PKG com.botone.app -OUT …` around the same fling loop, in the harmony job
once the runner variables exist. **Precondition: a connectable Harmony device with a real
display** — the recipe is unverified until S5 provides one; the current hosted workflow only
configures build and upload, and the emulator cannot stand in for it (`fps=0` above).

## Repeatable emulator smoke — `scripts/smoke.mjs`

`node apps/harmony/scripts/smoke.mjs` walks the Phase 1 flow with a loud-failure assertion
at every step: fixture reset → launch → (clean a leftover session) → server page → sign in →
inbox → open chat → send through the AI-consent gate (waits for the dialog, taps Allow, verifies
the echo) → receive a fixture-injected bot reply → settings (asserts the model row's server label)
→ sign out → sign-in page. **Coverage, precisely:** send, the consent gate, the user echo and an
injected reply — NOT live streaming progress, ask cards or a user-initiated Stop; those ride the
hypium suites (ThreadRealtime/ConsentGate) and the M3 real-backend runs. Preconditions and the
run-twice recipe are in the file header; every assertion accepts the zh-CN and en strings of the
same msgid.

Proven repeatable: **two consecutive full passes on an unchanged build** (plus the passes during
bring-up). Three timing facts it encodes, all found the hard way:

- `devecocli ui text` truncates at the first space — the script types through
  `hdc shell "uitest uiInput text '…'"` instead.
- The consent sheet swallows a click during its opening takeover — the script taps, verifies the
  dialog closed, and retries.
- While the keyboard is open the transcript's rows are not in the layout tree and the send button
  sits at a moving position — the script folds the keyboard (Back) before tapping send.

## Offline/error-copy walkthrough

- All 82 msgids the app passes to `t()` exist in the shared catalog (checked mechanically against
  `packages/i18n/locales/en/messages.po`; the fix round added `Jump to latest`, already cataloged
  for all three locales): no invented strings, no lookups that would silently render English on a
  zh screen — except the six declared `harmony-strings` above.
- No raw ids on error paths: `errorText` shows either the server's message (user copy by contract)
  or catalog copy; the decode sentinel "Unexpected response from the server" — an internal marker
  thrown by ten call sites — used to pass through to the screen in English; it is now classified
  as technical and renders the translated `Something went wrong. Try again.`
- Technical-term leaks: the `TECHNICAL_MESSAGE` list (validation paths, stacks, bare codes, JSON,
  HTTP dumps, node error idioms) matches core's `user-error.ts`, plus the sentinel above.
- Offline copy is the shared `Could not reach the server` banner (M2), unchanged and catalog-backed.

## ux-declutter walkthrough (screenshots/)

Every Phase 1 screen reviewed from a screenshot (`m4-ux-*.png`): sign-in, server, inbox, archived,
chat, consent dialog, settings. Per the skill: inventory → remove/merge/disclose → order → one
accent → newcomer read. (`m4-settings-system.png` in the appearance section and
`m4-ux-settings.png` here are deliberately the same capture — one settings screen, two walkthrough
references, not two screens.)

- **sign-in** — title, server row + one link, tab pair, two labeled fields, one primary button,
  one secondary, one footer link. Colors: ink, gray, one blue accent. No change.
- **server** — read-first (current server shown before the edit form), recents as rows. No change.
- **inbox** — one title, one link, avatar, pinned heading, rows with preview/time/unread dot; bot
  identity colors are the design's one identity color. No change.
- **archived** — restore is the page's one job; one button per row, two rows. No change.
- **chat** — back + name, day separator, messages, composer. The M4 localized separator reads
  「今天 20:55」 — the date and the (optional) clock in one calm line. No change.
- **consent dialog** — **fixed**: the three actions were three same-blue text buttons (three equal
  choices); Allow is now ink + primary, Not now quiet gray, Privacy policy stays the link. Verified
  on device (`m4-ux-consent.png` after).
- **settings** — read-first cards, pickers open native menus, version plain, one destructive
  action at the bottom. No change.

## CI (design §8)

`harmony.yml` final shape is unchanged from M0's design: a `pull_request`/`push`-paths job on the
hosted `macos-26` runner that installs the pinned command-line-tools, runs codegen, builds the
unsigned HAP (`devecocli build`), and uploads it for 7 days; no secrets, no signing. **S5 runner
verification is still blocked** on the repo variables `HARMONY_CMDLINE_TOOLS_URL` and
`HARMONY_CMDLINE_TOOLS_VERSION` — the job fails loudly with the exact instruction when they are
unset (by design). To unblock: pick the release on the download center, set both variables, run
the workflow once on a branch touching `apps/harmony/**`.

**Phase 2 update (PR #64, done):** the pull-request and push job moved off the hosted runner.
Twice in one day the hosted macOS ARM64 queue gave up on a pull request's build after fifteen
minutes ("The job was not acquired by Runner of type hosted even after multiple attempts"), so
`Unsigned HAP` now runs on the repository's own macOS ARM64 runner — the one the manual
`harmony-build-selfhosted.yml` already used — and finds DevEco Studio the same way, so the
command-line-tools download, its cache and the two `HARMONY_CMDLINE_TOOLS_*` variables are no
longer read by `harmony.yml` (the variables may stay or go). First run on the new job: six
minutes end to end. Because that runner is a persistent personal machine, the job runs for
pushes and for pull requests from `harmony/*` or `t3/*` branches only; fork pull requests and the
automation branches (`i18n/*`, `deps/*`, `codex/*`) are skipped, and the manual workflow builds
those on purpose.

**S5 on the self-hosted runner.** The owner chose the repository's manual self-hosted macOS ARM64
runner for now: `harmony-build-selfhosted.yml` ("BotONE HarmonyOS build (self-hosted)") is a
dedicated `workflow_dispatch`-only workflow for it — it first landed as a `harmony` platform
option inside the desktop self-hosted workflow and then moved to its own file for a clear
Actions-list name, and the desktop workflow's copy is reverted in this branch. Like the rest of
that workflow it is manual only (a public repository must not run pull-request code on a
personal machine); it finds the DevEco Studio installed on the runner (`HARMONY_DEVECO_STUDIO_PATH`
repository variable, default `~/Applications/DevEco-Studio.app`), runs the codegen and
`devecocli build`, and uploads the unsigned HAP for 7 days. Desktop-only steps (the Electron
binary, the web/desktop build, packaging) are skipped. Evidence: run 45324006653 on `fcf27a41c`
— "harmony preview on self-hosted runner" in 4m35s, artifact `botone-harmony-selfhosted-12`
(1,460,047-byte `entry-default-unsigned.hap`, bundle `com.botone.app`, no signature entries). A
first run (45323021878) failed in the shared install step on the Electron binary download, which
the HarmonyOS package does not use; that step is now split so it cannot recur. Not covered here:
the hosted `macos-26` path (still behind the two variables), hypium on CI (needs a device), and the
real-display fps recipe. The runner is persistent, which differs from design B-4's short-lived
isolated-runner condition; that is the owner's decision for this repository.

The TS alignment path runs in the required unit-tests job, not this workflow: the vitest include
(`apps/harmony/contract`), the devDep edges (contracts, core, ui-tokens, i18n, mobile) that make
`turbo ls --affected` select `apps/harmony` for a pure i18n/mobile change, and the
`changed-areas.test.py` assertions (11/11 OK). M4 adds one pinned case: a change to core's
`messages/time-separators.ts` (the new separator fixture's reference) selects every unit shard.

## Phase 1 acceptance checklist (design §7.2 M0–M4)

| Milestone | DoD item | Where |
| --- | --- | --- |
| M0 | debug-signed HAP installs and starts on a device | emulator ✓ (debug-signed install + launch, every session); **real device ✗ — no device/account exists (§9 R3), the known Phase 1 leftover** |
| M0 | S1–S6 written conclusions | m0-spike.md ✓ (S5: CI loud-fail design; blocked on repo variables, see CI above) |
| M0 | CI can produce an unsigned HAP | ✓ on the self-hosted runner (CI section); the hosted harmony.yml path stays behind the S5 variables, not on code |
| M1 | login → me → sign-out → re-login against a real server | fixture ✓ (hypium + smoke, both servers); real backend ✓ (M1/M3 runs, API_PORT=3110); **real device ✗ (same leftover)** |
| M1 | token survives restart; server switch rolls back | hypium SessionAndSignOut ✓ + on-emulator restart checks ✓ |
| M1 | 401/426/timeout/unreachable copy; retry/endpoint fixtures | hypium Net/Retry/Endpoint ✓; catalog copy audit above ✓ |
| M1 | layer-1 snapshots in CI | vitest 83/83 ✓ in unit shards |
| M2 | list matches server; signal-driven refresh, no polling | hypium Roster* ✓; fixture request log proves reads only on signal/foreground ✓ |
| M2 | offline/recover, kill+reopen, foreground catch-up | hypium ✓ + on-device offline banner (M2 notes) |
| M2 | archive/restore loop | hypium + on-device ✓ |
| M2 | 500+ conversations scroll smoothly | measured above (converging memory, flat cadence) ✓ |
| M3 | full chat loop: send → streaming reply → ask → stop | M3 notes (fixture + real Ollama run) ✓; smoke.mjs re-proves send/consent/echo/injected reply each run; progress, ask and Stop ride hypium + the M3 runs ✓ |
| M3 | consent loop (disclose → Allow → send; Not now keeps input) | hypium ConsentGate ✓ + on-device dialog (this milestone's screenshot) ✓ |
| M3 | 10k thread paging + scrolling | history window + perf-sample.mjs re-run above ✓ |
| M3 | unknown block renders a placeholder | M3 notes + hypium ✓ |
| M4 | SettingsPage (server/model/appearance/language/version/sign-out) | verification matrix above ✓ |
| M4 | i18n ICU-lite + three catalogs | 1,698 ICU cases + 45 date cases on device ✓ |
| M4 | performance calibration (font/a11y, long lists) | above ✓ (fps on a real display rides the S5 runner) |
| M4 | CI green (build + unit + alignment) | vitest 83/83, `pnpm checks` 152/152, changed-areas 11/11 ✓ (unsigned-HAP job awaits the two repo variables) |
| M4 | repeatable smoke script | smoke.mjs, two consecutive passes ✓ |
| M4 | offline/error-copy + ux-declutter walkthroughs | above ✓ (one finding fixed) |
| M4 | PR description with screenshots + new-copy justification | this file carries the evidence; **zero new msgids**, six pre-existing harmony-only strings listed |

Real-device leftovers (all Phase 1, all one root cause — no device/AGC account, design §9 R3):
install-and-start, the M1/M2 real-server and signal-capture runs, and the M3 real-device chat
loop. Everything else verified on the emulator against both fixture servers and, where marked,
the real backend.

## Final suite state on the M4 branch

- vitest `apps/harmony/contract`: **83/83** (workspace alignment, layer-1 snapshots incl. the new
  models/list views, layer-2 fixtures incl. the 45-case dates and 1,698-case ICU sets, codegen).
- hypium full suite (fixture servers on 8787+8788): **152/152** after the fix round (145 + 3
  HotLocale + 3 ThreadWindow + 1 history-window integration case). **Re-run recipe — use a 90 s
  per-case timeout**, not the M0 example's 30 s: the SSE idle case legitimately waits 45 s, so
  30 s reports a false 144/145:
  `hdc shell aa test -b com.botone.app -m entry_test -s unittest OpenHarmonyTestRunner -s timeout 90000`.
- `pnpm checks`: **152/152**. Biome clean over `apps/harmony`.
- smoke.mjs: two consecutive passes on the final build.
- perf-sample.mjs: the 10k page-by-page traversal re-run above (the R4 window's measured curve).

## Jump-to-latest regression coverage (fix round 3)

A clean rebuild of the app and test HAPs, with only the final `preserveLiveRows` call changed to return the refreshed snapshot, fails the full hypium suite on both jump cases:

- `jump_to_latest_keeps_live_progress_and_the_existing_subscription_at_equal_cursor`: `expect  equals verify progress before jump`
- `jump_to_latest_keeps_live_progress_when_the_server_snapshot_is_ahead`: `expect  equals verify progress before jump`

The first covers a refresh whose cursor equals the live cursor. The second injects another device's durable message through `/__threadEvent` after live progress, so the refreshed snapshot is ahead, contains that message, and contains no progress row. Restoring the call passes the same clean full suite three times: 154 passed, 0 failed. The existing fixture servers on 8787 and 8788 were reused; the committed signing configuration stays empty.

## Base synchronization and fixture isolation

The dependency audit failure on M0 was already fixed on current main by the `effect` override; the
stack merges that override instead of duplicating it. The required Harmony alignment suite caught
two new notification kinds, `pages` and `nativeCalendar`. Their snapshots are refreshed from the
real contract and roster forwards them to their readers (an ignored signal must never block the
stream); the device replay covers both. The latest catalogs also changed existing ICU fixtures;
the device replay now checks the number of embedded cases rather than a hard-coded old total.

**Upstream sync through 2026-11-24.** The same suite caught two more notification kinds,
`deploymentModel` and `preferences`; their snapshots are refreshed and roster forwards them, still
without a reader (the mobile reference re-reads `me` and the model lists on them). The thread
snapshots gained an optional `routineUpdate` payload on ask blocks and a `webhook` flag on routine
events. Neither changed port code: such an ask renders as the plain card, whose `detail` the
contract keeps readable, and `routine_event` reads only `name` and `change`. The ICU fixture is
refreshed from the current catalogs (1,809 cases). For this sync the unsigned app and ohosTest
HAPs were built, and the ICU fixture was replayed through `formatIcu` under Node rather than on a
device. The roster replay's new assertions compile but have not run under hypium.

The consent fixture's delayed-answer timer was originally attached to `req.close`, which Node
fires when the request body finishes. That cancelled the answer and left the kit waiting until
its timeout. The timer now attaches to the response close, is bounded to 60 seconds, and is
`unref()`ed. No product transport or consent semantics changed. The full device replay,
including the generation-change-in-flight case, passes after the fixture correction.

### S5 hosted verification (final)

The two repository variables are set (26.0.1.290, macOS ARM64 command-line-tools; the signed CDN
link is valid for ten years, so it is stable as a variable). First hosted run at head `d43743cf1`:
`Unsigned HAP` in 13m37s including the 2.5 GB download; the toolchain cache was saved, so later
runs restore it. Artifact `harmony-unsigned-hap` verified locally: 1,460,047-byte unsigned HAP,
`com.botone.app`, no signature entries. Two fixes the first pass needed, both found by simulating
a Studio-less machine locally before spending hosted minutes: `DEVECO_CLI_CLT_PATH` must point at
the tools (otherwise the CLI errors "DevEco Studio installation not found"), and `JAVA_HOME` is
pinned to the tools' bundled JRE so the packing step's `java` never depends on the runner image.
The same commit was cherry-picked to all five stacked branches so every PR check runs the fixed
workflow.
