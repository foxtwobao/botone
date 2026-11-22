# M3 notes — chat

Stacked on `harmony/m2-inbox-realtime` (M2, f94edc5bb). Scope: design §7.2 M3 — the vertical-slice
spike and its port-boundary decision (stage A), the reducer cluster port (stage B), the minimal AI
consent gate (stage C), ThreadPage (stage D), contract surface + fixtures + screenshots (stage E).
All product code lives under `apps/harmony/`; the committed `build-profile.json5` keeps
`signingConfigs: []` (signing material is injected locally for emulator installs only).

Environment: same as M1/M2 (DevEco 26.0.1.290 / API 26 Beta1, `devphone` emulator at
127.0.0.1:5557, guest reaches host at 10.0.2.2). Fixture servers on host 8787/8788; real backend
`API_PORT=3110 pnpm dev` with a throwaway account (`harmony-m3-spike@example.com`, fake password)
whose bot runs a local chat model (ollama `qwen3:0.6b` via the openai-compatible connection) so
real runs complete offline.

## Stage A — vertical-slice spike (done)

The spike ran the representative vertical slice end to end before any bulk port: send receipt →
progress deltas → run end → refresh/live race, fixture-driven AND against the real backend.

What landed for the slice:

- `thread/thread-snapshot.ets` — the slice branches of core `reduceThreadSnapshot`
  (progress/tool folding, message created/updated upsert, run.started/terminal, thread.cleared,
  seq dedupe), `applyThreadSendReceipt`, `rememberTerminalRun`, `mergeThreadSnapshot`,
  `reconcileRefreshedThread` (no computer in Phase 1), and the live-block helpers
  (`reduceLiveMessageBlocks`, sentence flush, tool steps, reset). Blocks stay raw JSON records:
  the reducer never reads inside a block except identity, so decode belongs to the render layer.
- `thread/thread-decode.ets` — threads/get + threads/messages decoders into the reducer's shape
  (per-entry: a bad message is dropped, a bad block is left to the render tier).
- `thread/thread-send.ets` — send receipt decode + the core `newClientId` UUID nonce.
- `realtime/thread-stream.ets` — the `thread-live.ts` loop: get once → subscribe from the cursor →
  reduce → commit; resume from the applied cursor (no re-read), disconnect → refresh (reconcile,
  never rewind) → resubscribe; 250ms→5s backoff, 0–5s spread on a clean EOF, non-retryable 4xx
  stops with the error surfaced; run terminal/waiting events trigger ONE coalesced refresh
  (core `createRefreshCoalescer` semantics). No timed re-read anywhere.
- Layer-2 `thread` fixture (`scripts/gen-thread-fixtures.ts` → `contract/fixtures/thread.json`):
  24 reduce scenarios, 9 receipt, 9 refresh-race, 4 merge, 2 terminal-memory, 6 live-block cases,
  all generated from the REAL core cluster and replayed under hypium value-for-value.
- Fixture server M3 routes: scripted threads (get/head/messages/subscribe/send/answer/stop/
  markRead), `/__threadEvent` injection, `/__threadCut` (deploy-style close), `/__threadRefuse`,
  `/__threadStall`, offline mode extended to the thread reads.
- `RealThreadSmoke` (opt-in `-s realBase/realEmail/realPassword`): real sign-in → real bot →
  threads/get → send → receipt queued run → user echo over the real stream → **live progress
  bubble observed** → run.completed → reconnect from the carried cursor with no gaps/duplicates.

### Measured ArkTS port throughput (the spike's decision input)

- First pass of the slice reducer: **750 lines of ArkTS covering ~600 lines of core reference**
  (thread-snapshot-events.ts whole + the events.ts/message-pages.ts helpers it calls), written in
  one ~75-minute session including reading the reference. Rework after the first device run:
  ~40 lines changed across 4 spots. Effective rate ≈ **500–600 reference lines/hour** including
  fixture-driven debugging; the mechanical translation itself is faster, the cost is the ArkTS
  static-constraint rework and the on-device verification loop (~2 min per build+install+run).
- Rework rate ≈ **5%** of ported lines. Every rework was one of four ArkTS constraints, all now
  known patterns (below); none was a semantic surprise except one (unknown-event cursor).
- Fixture alignment caught **two real semantic errors** in the first pass that code review would
  likely have missed: (1) unknown event types must leave the snapshot UNCHANGED (the reference
  returns `prev`; the stream's own replay cursor advances separately — mobile's loop owns that);
  (2) the receipt's `createdAt` fallback is the wall clock, which no fixture can pin — the
  generator pins it explicitly and the port takes `now` as a parameter.
- The SSE byte fixture (M1, 16 cases incl. the 45s idle) needed **zero** rework for M3 — the
  parser/transport were already aligned; the thread stream reuses them as-is.

### Port-boundary decision (challengeable)

**Decision: port the full client reducer cluster (~2.2k reference lines), not a subset with
refetch fallbacks.** Evidence and reasoning:

1. The slice proved the per-line cost is low and bounded (above). The remaining ~1.6k lines are
   the SAME patterns (record spreads → explicit copies, optional fields → `undefined` guards,
   `find/filter/map` → typed loops); no new ArkTS constraint is expected. Extrapolated cost:
   ~3–4 sessions, inside the M3 budget.
2. A refetch fallback cannot reproduce the behaviors the remaining branches exist for:
   waiting_input/takeover pauses delete the progress events server-side, so a refetch shows a
   waiting card with a stuck "working…" bubble unless the reducer drops it; subagent ordering and
   helper settlement are event projections absent from snapshots; the group-failure banner lives
   only in `run` between refreshes. These are exactly the ask-card semantics M3 must ship.
3. The drift defense (layer-2 fixtures regenerated from the real core every CI run) makes the
   full port's maintenance cost a normal PR, not an incident — the same argument the design made
   for the slice, now measured rather than estimated.
4. What is deliberately NOT ported (refetch/refresh covers it, or out of Phase 1 scope):
   `projectMessages` (server-side replay), `openThreadWindow`/`appendNewerThreadPage`/search-jump
   paging (Phase 1 pages backward only via `prependThreadHistoryPage`), tool-history split/replay
   (`withToolStepOutcomes` etc. — server-owned), secret redaction (server-owned), the durable
   `runThreadSubscription` state machine (design §5.4 already rejects it), computer status
   (own reducer, Phase 2), `displayIdentity`/avatar feed (mobile附加层, out of Phase 1).
   `reconcileRefreshedThread`'s computer branches drop with the computer field; the
   waiting_takeover local-preserve branch IS ported (takeover events reach the thread stream).

**The decision is challengeable on**: the extrapolation assumes the remaining branches hold no
new ArkTS constraint (the spike hit 4 kinds; a 5th would raise the rework rate); and the
waiting_takeover/helper semantics are the hardest to fixture — if their fixtures prove
unstable, the fallback is to keep those branches refetch-driven and say so here.

### ArkTS constraints hit in stage A (additions to M1's list)

- `Record<string, Object>` values cannot be `null` — build nullable JSON fields via
  `JSON.parse('{"x":null}')` or hand-built canonical JSON text; never assign null into a Record.
- A boolean-narrowed variable (`tailIsProgress`) does NOT narrow the object for later member
  access — bind the narrowed object itself (`const tailProgress: Record | null = …`).
- `number | null` arithmetic needs an explicit `number` local; closure-captured nullable
  comparisons need a const alias (`const floor = firstRecentSeq`).
- `Set.values().next().value` is `any` — iterate with `for…of` + `break` for the oldest entry.
- hypium's `expect(a).assertEqual(b)` on strings is order-sensitive; canonical-JSON comparison
  must sort keys on BOTH sides explicitly (the M1 `stableJson` helper's sort was not enough for
  the hand-built side — the reducer test now builds its canonical form sorted by construction).

### Emulator network-stack finding (cost the spike most of its debugging time)

Symptom: after the M2 roster suite ran, the FIRST unary request of the thread suite queued
~50–60s and then failed with the kit's own "Operation timeout" (extendInfo all zeros — the
request never started a transfer), while the server log showed it never arrived. Streams opened
fine; a raw `postJson` to the same URL worked; the same `rpc` call worked in isolation.

Root cause (observed, not documented): the API 26 emulator's `@ohos.net.http` connection pool
can hand a connection a long-lived SSE stream used to a later unary request, which then waits
forever. `reuseConnections: false` on the unary side alone did NOT fix it; the fixture server
sending `Connection: close` on its SSE responses (so stream connections never enter the pool)
DID, together with running the thread suites before the roster suite in the shared test process.

What shipped: the fixture server's streams send `Connection: close` (a stream is one connection
for its whole life — correct server behavior anyway); the test order runs the thread suites
before the roster integration suite. The app's net layer is UNCHANGED (no reuse flag) — the
real server's stream handling is upstream's and the real-backend smoke passes with streams and
unary calls interleaved. **Risk to watch on real devices**: if the same pooling hazard appears
against a real server, the fix is `reuseConnections: false` on unary RPCs (one handshake per
call) — recorded here so M4's real-device pass checks it explicitly.

## Test results (stage A)

- TS alignment (vitest, no SDK): `apps/harmony/contract` 5 files / **32 tests pass** (was 31;
  +1 thread fixture). Regenerate with `HARMONY_UPDATE_FIXTURES=1`.
- hypium on emulator (fixture servers 8787+8788): **112/112 pass, 0 fail, 0 error** — M2's 89
  plus the thread reducer fixture replay (6), the thread state machine offline (10), the thread
  integration suite against the fixture server (6: scripted open, send→receipt→echo→progress→
  run end, cut-stream reconnect without gaps, no-polling request-log proof, stop/terminal-receipt
  guard, offline open + retry recovery), and the real-thread smoke placeholder.
- Real backend (3110) with `-s realBase/realEmail/realPassword`: **112/112 pass** including
  `RealBackendSmoke` (M1) and `RealThreadSmoke`: real send receipt → queued run shown → user
  echo → live progress bubble → run.completed → reconnect from cursor, no gaps, no duplicates
  (hilog evidence captured in the run log).
- `pnpm checks`: run at stage E (full gate before push).

## Stage B — full reducer cluster port (done)

Per the stage-A decision, the whole client cluster is ported on the same types:

- `run.waiting_input` / `computer.takeover.requested`: settle a known run (status + userId),
  insert an unknown peer run (the first wait event is how an open thread learns a busy peer needs
  ask/takeover UI), promote unless a waiting card already holds the primary slot, drop the run's
  live progress bubble (both pauses delete its progress events server-side).
- `computer.takeover.released`: waiting_takeover → queued, members follow; a second release is a
  no-op. `reconcileRefreshedThread` keeps the event-sourced waiting_takeover at an equal-cursor
  refresh and lets a newer cursor replace it.
- `thread.subagent`: live rows order before the streamed answer; a pause/terminal settles running
  cards to failed/stopped (`settleRunSubagents`); a saved card replaces the live placeholder by
  agentId. `thread.cloud_agent`: in-place card update with the https-only URL filter.
- Helper semantics: an answered helper ask card ends the chat's waiting state without a
  run.started; a helper wait never promotes over a waiting card.
- Group member status follows the run lifecycle (running/waiting/idle) via `updateMemberStatus`;
  the group-failure banner survives late member starts (already in the slice).
- `runFailureError` carries the model-fallback envelope: each model's diagnostic clamped to 300
  chars and re-serialized (the UI reads the envelope, not a truncated blob).
- Reply metadata (`replyToMessageId`/`replyQuote`/`replyPreview`) and author survive updates that
  omit them; the decoders read them and the group members row.
- `live-blocks.ets` split out of the reducer file (the 1,000-line cap): the block folding helpers
  are their own module, re-exported for the existing import path.

The thread fixture grew to **38 reduce scenarios + 11 refresh-race** (plus receipt/merge/terminal/
blocks), all regenerated from the real core and replayed green on the FIRST device run after the
port — the stage-A patterns held; the only new constraint was `URL` (ArkTS uses
`url.URL.parseURL`, not the global constructor).

Not ported, as decided: projectMessages, window/search paging, tool-history split/replay, secret
redaction, durable subscription, computer status, identity-display provenance (Symbol, never on
the JSON wire — documented in the reducer header).

Tests: vitest 32/32; hypium **112/112** (fixture servers), full-cluster replay 6/6.

## Stages C–E

(in progress — this section grows as each stage lands)
