# M4 notes — settings + quality close-out

Stacked on `harmony/m3-chat` (M3, dbdabac31, PR #55). Scope: design §7.2 M4 — SettingsPage, the
i18n/ICU close-out, performance calibration (font scale + long lists), the repeatable emulator
smoke, the offline/error-copy and ux-declutter walkthroughs, and the Phase 1 acceptance checklist.
All product code lives under `apps/harmony/` plus one line in `.github/scripts/changed-areas.test.py`
(the trigger assertion for the newly consumed reference); the committed `build-profile.json5` keeps
`signingConfigs: []` (signing material is injected locally for emulator installs only).

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

10k-message thread (100-message recent page, older pages fetched on scroll):

| point | value |
| --- | --- |
| open latency (tap → composer visible, 0.5 s poll bound) | ≤ 1.5 s |
| PSS after open + settle | 122.5 MB |
| PSS mid-traversal (20 flings) | 106.0 MB |
| PSS after full traversal (40 flings, newest → oldest, ~10,000 messages) | 105.5 MB |
| per-fling injection cadence | 0.22 s — identical to the inbox's 0.21 s |

End-to-end traversal of all 10k messages, memory **flat and below the post-open point**: paging
loads history into the store while the render tree stays windowed.

**Frame rate, and why the number is not an fps.** This emulator's composer exposes no frame
statistics: `SP_daemon -f` reads `fps=0` through every mode (`-print`, `-start/-stop` csv,
`-VIEW DisplayNode`), `hidumper -s RenderService` has no frame dump, and an in-process
`displaySync` probe delivered zero callbacks even while host-driven flings ran (that probe was
tried and removed — it cannot work from the test runner's context). The repeatable replacements,
recorded above: open latency, full-traversal cadence (flat vs the small-list control), and the PSS
curve. The S5 CI runner (real display) is where `SP_daemon -f` works; the recipe is simply
`SP_daemon -start -f -PKG com.botone.app -OUT …` around the same fling loop, in the harmony job
once the runner variables exist.

## Repeatable emulator smoke — `scripts/smoke.mjs`

`node apps/harmony/scripts/smoke.mjs` walks the whole Phase 1 flow with a loud-failure assertion
at every step: fixture reset → launch → (clean a leftover session) → server page → sign in →
inbox → open chat → send through the AI-consent gate (waits for the dialog, taps Allow, verifies
the echo) → receive a fixture-injected bot reply → settings (asserts the model row's server label)
→ sign out → sign-in page. Preconditions and the run-twice recipe are in the file header; every
assertion accepts the zh-CN and en strings of the same msgid.

Proven repeatable: **two consecutive full passes on an unchanged build** (plus the passes during
bring-up). Three timing facts it encodes, all found the hard way:

- `devecocli ui text` truncates at the first space — the script types through
  `hdc shell "uitest uiInput text '…'"` instead.
- The consent sheet swallows a click during its opening takeover — the script taps, verifies the
  dialog closed, and retries.
- While the keyboard is open the transcript's rows are not in the layout tree and the send button
  sits at a moving position — the script folds the keyboard (Back) before tapping send.

## Offline/error-copy walkthrough

- All 81 msgids the app passes to `t()` exist in the shared catalog (checked mechanically against
  `packages/i18n/locales/en/messages.po`): no invented strings, no lookups that would silently
  render English on a zh screen — except the six declared `harmony-strings` above.
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
accent → newcomer read.

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
| M0 | CI can produce an unsigned HAP | harmony.yml ✓ (blocked on S5 variables, not on code) |
| M1 | login → me → sign-out → re-login against a real server | fixture ✓ (hypium + smoke, both servers); real backend ✓ (M1/M3 runs, API_PORT=3110); **real device ✗ (same leftover)** |
| M1 | token survives restart; server switch rolls back | hypium SessionAndSignOut ✓ + on-emulator restart checks ✓ |
| M1 | 401/426/timeout/unreachable copy; retry/endpoint fixtures | hypium Net/Retry/Endpoint ✓; catalog copy audit above ✓ |
| M1 | layer-1 snapshots in CI | vitest 83/83 ✓ in unit shards |
| M2 | list matches server; signal-driven refresh, no polling | hypium Roster* ✓; fixture request log proves reads only on signal/foreground ✓ |
| M2 | offline/recover, kill+reopen, foreground catch-up | hypium ✓ + on-device offline banner (M2 notes) |
| M2 | archive/restore loop | hypium + on-device ✓ |
| M2 | 500+ conversations scroll smoothly | measured above (converging memory, flat cadence) ✓ |
| M3 | full chat loop: send → streaming reply → ask → stop | M3 notes (fixture + real Ollama run) ✓; re-proven by smoke.mjs each run ✓ |
| M3 | consent loop (disclose → Allow → send; Not now keeps input) | hypium ConsentGate ✓ + on-device dialog (this milestone's screenshot) ✓ |
| M3 | 10k thread paging + scrolling | measured above ✓ |
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
- hypium full suite (fixture servers on 8787+8788): **145/145** (final build, after the last code
  change).
- `pnpm checks`: **152/152**. Biome clean over `apps/harmony`.
- smoke.mjs: two consecutive passes on the final build.
