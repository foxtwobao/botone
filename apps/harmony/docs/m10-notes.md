# M10 notes — Spaces: a persisted selection, and switching between Spaces (slices A1 + A2)

Scope (design §7.2 M10, slices A1 and A2): the app always speaks for one Space, and the person
can change which one from the inbox. A1 made the selection real: it is stored beside the session,
every read, write, stream and cache entry is pinned to it, and changing it resets every painted
store before the streams reopen. A2 puts a switcher on the inbox title: tapping the Space name
opens the list of Spaces, picking one claims it, writes it to disk, and proves it with one
`spaces/list` read before the switch counts. Out of this slice: sharing a Space's content (B1),
moving a bot between Spaces (B2), and persisting unsent drafts across a switch (B3).

**Status: verified on the emulator.** The full hypium suite passes, the switch flows were walked
with captures in `apps/harmony/screenshots/m10-space-*.png`, and the controller fixes Codex's
review asked for are in (§Review findings).

## What ships

| Layer | File | What it does |
| --- | --- | --- |
| disk | `net/space-selection.ets` (A1) | the stored Space id beside the token; a corrupt or empty value reads as no choice; clearing is best effort |
| rules | `features/spaces/space-switch.ets` | the switch's pure state machine: idle → switching → done \| failed, and what each outcome leaves the selection holding |
| state | `features/spaces/space-switch-controller.ets`, `stores/space-store.ets` (extended) | the effects: claim in memory, persist, prove with one read, roll back on a disk failure, retry a network failure, hand a refused Space to the 401 recovery. `noteSelection` names a claimed Space before its answer arrives |
| UI | `features/inbox/InboxPage.ets` (extended), `features/settings/SettingsPage.ets` (extended), `features/chat/thread-route.ets`, `features/chat/ThreadPage.ets` (extended), `features/chat/share-target-sheet.ets`, `pages/Index.ets` | the title becomes the current Space's name with a ▾ menu when more than one Space exists, the settings Space row follows the live selection, and every chat route carries the Space it was opened in |
| tests | `contract/space-switch-port.test.ts`, `ohosTest/ets/test/SpaceSwitch.test.ets` | the state machine replayed offline as TypeScript; the controller driven against the fixture server (claim, proof read, switch back, deleted target, offline retry) |

## The interaction

- **The title is the Space.** With one Space it is a plain heading (the server's name, or
  `Chats` until the first read names it); with more, it gains a ▾ and opens the Space menu.
  The current Space carries the check mark, like the appearance and language menus in Settings.
- **Picking the current Space is not a switch.** The menu closes and nothing else happens: no
  generation bump, no request. A1's claim always notifies, so a same-value claim would reset every
  store and reopen the roster stream for nothing.
- **A switch claims first, then writes, then proves.** The claim resets the painted stores and
  reopens the roster stream under the new header at once, so the old Space's rows never sit under
  the new name. The proof read is one `spaces/list` under the new Space; its `current.id` must be
  the target, and its answer refills the name and the Space list.
- **Outcomes.** The disk write is the only step that rolls back: memory and disk both return to
  the Space the switch started from, and the failure row says `Could not switch spaces`. An
  unreachable server does **not** roll back — the new Space is chosen and only the proof is
  missing — and the row offers `Try again.`, which re-runs the proof once the network is back. A
  Space the server no longer grants 401s the proof; the existing recovery clears the selection
  and its stored copy, the switch returns to idle without an error, and the account is read again,
  landing on the server's default Space.
- **A completed switch clears the navigation stack** so no chat opened in the old Space stays in
  front. In practice the menu is only reachable from the inbox, which is the root; the clear is
  what makes the guarantee true rather than incidental.

## Key decisions

- **The state machine is pure and import-free.** It is the only part of the switch the contract
  suite can load as erasure-only TypeScript, so the transitions (rollback, keep, retry, gone) are
  pinned on every push without a device. A late answer from a superseded step arrives as an event
  that does not fit the phase and leaves the state untouched.
- **A chat remembers the Space it was opened in.** `ThreadRoute` gained an optional `spaceId`;
  the inbox and the share sheet fill it. `ThreadPage` closes, clears its draft and pops the stack
  only when the selection moves away from that Space; a switch that leaves it selected keeps the
  page. `pages/Index.ets` refuses to render a chat whose Space is not the current one, a
  defensive path because the switch already cleared the stack.
- **Settings reads the live name, not the boot value.** The Space row shows
  `spaceStore.currentName`, falling back to `app.spaceName` (the value the launch read stored)
  until the first navigation read fills the store. Settings has no switcher: the inbox title is
  the one entry, matching where the Space's content lives.
- **The switch does not go through the query cache.** Its proof read is a direct `spaces/list`
  under the new Space: the roster's own read follows the stream's reopen signal, and the cached
  roster is already unusable because the scope changed.

## Verification

| Gate | Result |
| --- | --- |
| `pnpm --filter @rakazo/harmony harmony:codegen` | regenerated tokens, tables, link patterns, notices, the three locale catalogs (2639 messages each), client build, voice limits and the embedded fixtures |
| `pnpm exec vitest run apps/harmony/contract` | **189 / 189** (19 files), the new state-machine file included |
| `pnpm checks` | all green (172) |
| `devecocli build`, `devecocli build --modules entry@ohosTest` | both **BUILD SUCCESSFUL** after `devecocli build clean`; **no ArkTS warning in any file A2 added or changed** |
| fixture smoke (`spike-sse-server.mjs` on 8799, curl) | `spaces/list` answers per `x-rakazo-space-id` (space-second names Second Space and its bot), `space-stale` answers 401, the header-less probe answers 200, and `/__offline` drops the read's connection; `/__requests` records the header |
| hypium on the emulator | **291 / 291**, the three A2 cases included; one case that waits on the fixture also after a destroyed connection passes with a warm-up read |
| device captures | `m10-space-title`, `m10-space-menu`, `m10-space-switched`, `m10-space-settings`, `m10-space-persisted`, `m10-space-switch-failed`, `m10-space-retried`, each opened and checked |

"No warning in an A2 file" is not "no warning in the build": the six remaining ones are the M0/M1
files the M7 notes list (`asset-store.ets:56`, `server-store.ets:33` and `:34`, `sse.ets:200`,
`consent-dialog.ets:56` twice), untouched here.

### Walkthrough (run on the emulator)

1. Inbox title reads the Space's name with ▾ beside it; the menu lists both fixture Spaces, the
   current one checked.
2. Picking the other Space: the title changes, the rows become that Space's bot, and the menu now
   checks that Space. A restart (or a settings visit) shows the same Space.
3. Picking the current Space: the menu closes, nothing else moves.
4. `/__offline {"on":true}` then a switch: the title shows the Space that was claimed (the switch
   keeps it), one row says `Could not switch spaces` with `Try again.`, and the roster's own
   offline banner gives way to it. Turning the fixture online and tapping `Try again.` completes
   the switch; the rows then need the banner's own retry once, because the emulator's HTTP client
   wedges the first request after a connection the fixture destroyed.
5. Switching to `space-stale` (a deleted Space): no error, the title falls back to the default
   Space and the menu lists the same two Spaces.

## Review findings (this round's own)

1. **A save under a switch could pop one page too many.** `ModelConnectionPage` and
   `GroupSettingsPage` had the same shape the M8 review found: a success callback popping without
   asking whether its page was still the one on top. The Space controller repeats the check after
   its own await instead: a `200` that names another Space clears the claim (memory and disk)
   before the account is read again, and a retry no longer re-claims the Space it already holds.
2. **Two failure rows for one failure.** With the server unreachable a failed switch showed
   `Could not switch spaces` above the roster's `Could not reach the server`, each with its own
   retry. The banner now yields to the switch row.

## Known limitations

- **A switch loses an unsent draft.** A thread in front of the inbox would be popped by the
  switch anyway, and drafts have no disk home until B3. This matches the current behavior of
  leaving a chat; nothing new is stored.
- **The Space list can lag one navigation read.** `spaceStore.spaces` changes only when a
  `spaces/list` answer arrives (launch, the switch's proof, a roster re-read). A Space created or
  deleted from another device shows in the menu at the next such read, never on a timer.
- **Settings cannot switch Spaces.** It shows the selection; the inbox title is the only entry,
  as intended for this slice.
- **A 200 answer naming another Space is treated as gone.** Only a deleted Space is expected to
  refuse (401), so the anomalous 200 path clears the claim itself before the account is read
  again; the fixture does not stage it.
- **A disk-write rollback cannot restore the page a switch already popped.** The claim fires
  before the write is attempted, so the chat in front of the inbox is closed; rolling the
  selection back does not reopen it. Until B3 keeps drafts on disk this costs the draft, the same
  as leaving the chat does.
- **One failure row at a time.** A switch that failed because the server was unreachable suppresses
  the roster's own offline banner: the switch row already names the failure and carries
  `Try again.`