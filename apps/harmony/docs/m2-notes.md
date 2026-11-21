# M2 notes — inbox + realtime signals

Stacked on `harmony/m1-network-login` (M1). Scope: design §7.2 M2 + §5/§6 — the roster stream
state machine, QueryCache + SaveController, RosterStore/InboxPage, ArchivedPage with
archive/restore, foreground catch-up, and the offline banner over the memory cache. All product
code lives under `apps/harmony/`; the only other touched file is the automatic `pnpm-lock.yaml`
(the `@orpc/contract` devDependency edge, below). The committed `build-profile.json5` keeps
`signingConfigs: []`; signing material is injected locally for emulator installs only.

Environment: same as M1 (DevEco 26.0.1.290 / API 26 Beta1, `devphone` emulator at 127.0.0.1:5557,
guest reaches host at 10.0.2.2). Fixture servers on host 8787/8788; real backend `API_PORT=3110`.

## What landed

- **QueryCache** (`query/query-cache.ets`): the §5 semantics without react-query. Key =
  (server, sessionGeneration, space, proc, input); `peek` paints the last answer only in the
  current scope; `read` pins the context, refuses a late answer whose scope moved on (returns
  null, caches nothing); `invalidate(proc)` and `clear()` are the write-stale and session-change
  entry points. No staleTime timer, no polling.
- **SaveController** (`query/save-controller.ets`): the `useSave` contract — context pinned at the
  tap, single-flight, `send` writes only with that pinned context and is refused once its
  server/session/Space is no longer current, pending/error owned by the controller, declared
  reads invalidated on success. Archive (inbox) and restore (archived) both use it with
  `stale = [spaces/list, bots/listArchived, groups/listArchived]`.
- **Roster stream** (`realtime/roster.ets`): port of `roster-signals.ts`'s follow loop — one
  `notifications/subscribe` for the app, holder counting, opening roster signal invalidates and
  re-reads, SpaceChangeKind dispatch, organizations ignored, heartbeats only prove liveness.
  Backoff 1s→30s before first open, then the 0–5s reconnect spread; a non-retryable 4xx holds
  until the session/Space changes; identity change reopens at once. No timed fallback re-read.
- **RosterHolder** (`realtime/roster-holder.ets`) + **foreground store** (`realtime/foreground.ets`):
  the hold is owned by the *screen* (InboxPage/ArchivedPage `aboutToAppear`/`aboutToDisappear`),
  gated by foreground, matching "open while any screen holds it, foreground only". EntryAbility
  onForeground/onBackground drive the store; returning to the foreground reopens the stream and
  re-reads (catch-up).
- **RosterStore / ArchivedStore** (`stores/`): read once, then re-read only on a roster signal or
  foreground; last rows stay painted under an offline banner when a read cannot reach the server.
  `subscribeChanges` lets a screen reload its LazyForEach source when rows change.
- **Projection** (`stores/roster-projection.ets`): port of `chatSnoozed` + `isRunWorking` +
  `groupBotsForSidebar` with no sections — bots+groups mixed in server order, pinned first,
  snoozed hidden. `rowKey` carries the rendered content (see the LazyForEach decision below).
- **UI**: InboxPage (identity-color avatars, unread dot, working dot, preview, time, Pinned
  heading, long-press Archive, archived + account entries), ArchivedPage (visible Restore),
  offline banner with Retry. Avatars resolve the server `bots.color` (hex/shape) with the
  generated `botColors[3]` fallback and pick a contrasting initial for light colors. Copy reuses
  catalog msgids (Chats/Archived/Archive/Restore/Pinned/Working…/No messages yet/…); no `.po` edits.
- **Contract surface** (`scripts/contract-manifest.ts` + snapshots): spaces/list grows to the
  roster (bots+groups); bots/list, bots/listArchived, groups/listArchived, bot/group
  archive+restore input+output, notifications/subscribe event-type enum (via
  `getEventIteratorSchemaDetails`), and SpaceChangeKind are pinned. Layer-2 `inbox` fixture drives
  the REAL core helpers and is replayed under hypium.
- **Fixture server** (`scripts/spike-sse-server.mjs`): M2 routes (roster lists, archive/restore),
  a notifications/subscribe SSE stream with opening signals, `/__signal` injection, `/__requests`
  request log (the no-polling proof), `/__mutate`, and `/__offline` (drops read connections).

## Decisions

- **The roster signal alone drives the inbox.** `followRosterChanges` subscribes to the member's
  thread topics as well as roster topics, so chat activity (messages, runs, unread) reaches the
  client as a roster signal (spaced ≤10s server-side). Run lifecycle also emits a `runs`
  SpaceChangeKind, but that is for run readers, not the roster; M2 dispatches it to listeners yet
  no M2 screen subscribes. Verified on device: a send on another session refreshes the inbox
  preview/working dot without any poll.
- **Holder lives in the screen, not app-state.** Wiring the hold to app-state's phase made the
  instrumented process (which bootstraps the global app but never renders the inbox) hold a
  stream and leak holder counts across suites. Screen-scoped RosterHolder fixes that and is the
  faithful "any screen holds it" pattern. Tests also call `app.detach()` so the global app's
  session listener does not load the account or clear caches mid-suite.
- **LazyForEach keys must carry content.** Found on device: with a stable `kind-id` key,
  LazyForEach reuses the ListItem when rows change, so the list showed stale previews/status even
  though the store updated. `rowKey` includes unread/working/updatedAt/preview so a content change
  forces a re-render; unchanged rows still reuse. Screens reload the source via
  `store.subscribeChanges`, not `@Monitor`.
- **Single Space** (design Q5): every read/write uses `me.spaceId`; no Space-switch UI.
- **bots/list is pinned and used as the archive/restore closed-loop ground truth** in tests;
  `groups/list` is not consumed (spaces/list already carries the active roster), so it stays out
  of the snapshot whitelist (review Q8).
- **Working vs waiting**: M2 shows the working dot for `isRunWorking` (queued/leased/running).
  Waiting-on-user attention is an M3 concern (ask cards); snoozed chats are hidden but there is
  no wake clock yet (a wake while idle in foreground appears on the next signal/foreground).

## Test results

- TS alignment (vitest, no SDK): `apps/harmony/contract` 4 files / **31 tests pass** (workspace 6,
  layer-1 snapshots 18, layer-2 fixtures 5, codegen color 2). Regenerate with
  `HARMONY_UPDATE_SNAPSHOTS=1` / `HARMONY_UPDATE_FIXTURES=1`.
- hypium on emulator (fixture servers 8787+8788): **89/89 pass, 0 fail, 0 error** — M1's 54 plus
  inbox-projection fixture replay, new decoders, QueryCache scope/late-refusal/clear,
  SaveController single-flight/pinned-refusal/stale/error, roster state machine (holder count,
  signal dispatch, both backoff regimes, non-retryable hold, identity reopen, stop), and
  RosterRealtime against the fixture server: **no-polling request-log proof**, runs-signal-does-
  not-poll, archive/restore closed loop (bot+group), foreground catch-up, restart re-read,
  offline-keeps-painted-rows.
- `pnpm checks`: **152/152 pass**. Biome clean on `apps/harmony`.
- After the `data/` → `query/` rename (incident below), the whole suite was re-run on the renamed
  tree: vitest 31/31, hypium 89/89 on the emulator (fixture servers 8787+8788, locally injected
  signing), `pnpm checks` 152/152.
- Real backend (3110) by hand on the emulator: sign-in → inbox with live signal-driven
  preview/working dot and unread; archive → archived page; restore → back in inbox; offline
  banner over painted rows when the server is unreachable. Screenshots:
  `screenshots/m2-inbox.png` (working + unread + pinned + identity colors), `m2-archived.png`,
  `m2-offline.png`.

## Incident: the data folder was swallowed by an upstream ignore rule

The first M2 commit shipped without `query-cache.ets` and `save-controller.ets`: they lived in
`entry/src/main/ets/data/`, and the upstream `.gitignore` rule `apps/**/data` silently ignored the
whole folder, so `git add` never staged them. Local builds kept passing (the files were on disk);
only a clean checkout failed to compile — 14 errors in the app build, 28 in ohosTest. Fix: rename
the folder to `ets/query/` (verified with `git check-ignore` that the new path is not ignored) and
update every import. No gitignore negation, no force-add, no upstream file touched. Lesson: after
pushing, verify from a clean checkout (fresh worktree at the pushed commit: codegen + app build +
ohosTest build), never trust a build in the tree where the files were authored. This fix commit was
verified that way; all three builds pass from the clean checkout.

## Upstream files

- `pnpm-lock.yaml`: automatic. M2 adds the harmony devDependency `@orpc/contract` (1.16.2, the
  version contracts pins) for `getEventIteratorSchemaDetails`, used only by the dev-time manifest
  to project the notifications/subscribe event schema. No runtime dependency; the HAP ships no
  mobile/orpc code. No other upstream file changed.

## Left for M3+

- M3: thread reducer port + thread stream + ThreadPage + minimal AI consent gate; the layer-2
  reducer/consent fixtures grow there. Waiting-on-user attention UI lands with ask cards.
- M4: localized row dates (currently today=HH:mm else numeric date), snooze wake clock,
  500+-row scroll/memory measurement, settings page, full CI runner verification (S5).
- Real-device acceptance (M0–M2 DoD remains real-device; emulator used here as instructed).
- Upstream PR: `harmony` client kind in `CLIENT_KINDS` (carried from M1).
