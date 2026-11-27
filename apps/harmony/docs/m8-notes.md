# M8 notes — groups: create, rename, members, delete

Scope (design §7.2 M8): the group surfaces above the M2 inbox. Creating a group (pick the bots,
then name it), renaming it, editing its members and deleting it, plus the member-carrying decode
the settings screen needs. The group chat itself stays M2/M3's thread; M8 gives its header the
settings entry.

**Status: verified on the emulator.** Hypium 265/265 on the device, the real-backend smokes all
green against a local stack on real Postgres, every walkthrough row measured, 11 captures in
`apps/harmony/screenshots/`.

## What ships

| Layer | File | What it does |
| --- | --- | --- |
| rules | `features/groups/group-rules.ets` | contracts' `defaultGroupName` ported value-for-value; the update body built against the visit's baseline; the membership-conflict recognition; mobile's merge of a re-read over unsaved edits |
| decode | `contract/decode-groups.ets`, `contract/decode.ets` (extended) | the group row with its members (per-entry discipline, as thread members have), and the roster read through `decodeRoster`'s own groups reader |
| UI | `features/groups/NewGroupPage.ets`, `features/groups/GroupSettingsPage.ets`, `features/groups/group-pickers.ets`, `features/inbox/InboxPage.ets` (extended), `features/chat/ThreadPage.ets` (extended), `pages/Index.ets` (extended) | the new-group two steps, the settings form with its member checklist and delete confirm, the shared bot checklist (a full selection dims the rows it cannot take), the inbox's `+` menu, the thread header's settings entry |
| state | `stores/roster-store.ets` (extended) | the store keeps the decoded bots and groups beside the inbox rows; the group screens read members from there |
| fixture | `scripts/group-fixture.mjs`, `scripts/spike-sse-server.mjs` (mount), `scripts/gen-fixtures.ts` (group section), `contract/fixtures/group.json` | the fake group rows and the four write RPCs with the membership precondition, the control routes the suite reads, and the default-name fixture generated from the real contracts function |
| tests | `contract/group-rules-port.test.ts`, `ohosTest/ets/test/GroupRules.test.ets`, `ohosTest/ets/test/GroupWrite.test.ets` | the differential port replay (the `.ets` file loaded as TypeScript), the member decode, and the writes against the fixture server through the real RpcClient and RosterStore |

## Key decisions

- **The baseline carries the active members only.** `activeMemberIds` filters a group's members
  to the bots the roster still lists before `expectedBotIds` is sent, and the server compares
  against the same filter (`bot.archivedAt === null`). A group whose member was archived since it
  was last read would otherwise refuse every membership save.
- **The conflict is recognized by status and message.** The server's refusal is an
  `IsolationError`, which reaches the client as 404 NOT_FOUND with
  "Group members changed. Refresh and try again."; no stable code is carried, so
  `isGroupChangedError` asks for both. On it the screen re-reads the roster and merges this
  visit's edits over the new members (mobile's rule: a local deselect stays off, a locally added
  bot stays on, a different group starts from its own members); the user saves again.
- **The update sends only what changed, against what this visit read.** `groupUpdateInput` puts
  the name and/or the membership in the body only when they differ from the visit's baseline,
  never a fresher read; nothing changed pops the screen without a request, as a saved one.
- **A delete clears the stack.** The chat beneath the settings page holds a group that no longer
  exists, so it leaves the whole stack (`stack.clear()`) rather than popping the settings page.
- **A create returns to the inbox.** Mobile replaces its new-group sheet with the new group's
  thread; Harmony pops back and re-reads the roster, whose new row carries the bots' default name
  and opens like any other thread.

## Verification

| Gate | Result |
| --- | --- |
| `pnpm exec vitest run apps/harmony/contract` | **158 / 158** (159 before the review round removed the tautological message-text case) |
| `pnpm checks` | all green (172) |
| `devecocli build`, `devecocli build --modules entry@ohosTest` | both **BUILD SUCCESSFUL** after `devecocli build clean`: **no ArkTS warning in any file M8 added or changed** |
| hypium on the emulator | **265 / 265** (the full suite, fixture servers on 8787/8788); the review round removed one duplicated case, so the suite now holds 264 |
| real backend | the opt-in real-backend smokes on the device (`-s realBase`), a local stack on real Postgres: ALL PASS |
| screenshots | 11 captures `apps/harmony/screenshots/m8-group-*.png`, one for each row below; each opened and checked at its final path |

"No warning in an M8 file" is not "no warning in the build": the remaining ones are the M0/M1/M3
files the M7 notes list (`asset-store.ets:56`, `server-store.ets:32` and `:33`, `sse.ets:200`,
`consent-dialog.ets:56` twice), untouched here.

### Device walkthrough

| What | Capture |
| --- | --- |
| the inbox lists the seeded group above the bots (Team, "Group chat") | `m8-group-inbox` |
| the `+` menu's New group chat opens the picker: 成员 (2), Alpha and Beta checked, 下一步 | `m8-group-new-members` |
| the name step: 群组名称 with the placeholder 例如：猎鹰计划; a blank name reads 跳过 | `m8-group-new-name` |
| creating returns to the inbox, whose new row is the bots' default name (Alpha, Beta, 还没有消息) | `m8-group-created` |
| the group's thread answers a sent hello; its header shows the group name and the settings chevron | `m8-group-chat` |
| the header's chevron opens 群组设置: the name field, 成员 (2) checked, 保存 and 删除群组 | `m8-group-settings` |
| a rename typed in the field (Renamed Team) | `m8-group-renamed-edit` |
| saving returns to the chat, whose header still reads the old name until it is reopened (M3's limitation; the capture shows it) | `m8-group-renamed` |
| 删除群组 asks 要删除 Renamed Team 吗? / Bot 和它们自己的聊天会保留。 | `m8-group-delete-confirm` |
| deleting clears to the inbox; the group is gone | `m8-group-deleted` |
| unchecking a member leaves 成员 (1) and disables 保存 (the minimum of two) | `m8-group-member-min` |

## Review findings (the acceptance round)

| # | Finding | Fix |
| --- | --- | --- |
| M1 | A save still in flight could pop the chat under the settings page: the success callback popped unconditionally, so backing out during the request lost two pages. | `onSaved` returns when the page is no longer active, the flag the conflict rebase already holds. |
| m1 | An offline first read with no cache answered "Group not found". | The post-load check reads the roster store's own error first; the message field now carries either that text or "not found". |
| m2 | Tapping the 11th bot in a full selection did nothing and said nothing. | The checklist takes the cap (`max`), dims a row the cap leaves out and does not take its tap; both screens pass `GROUP_MEMBER_MAX`. |
| m3 | The fixture answered an invalid member count with 400 BAD_REQUEST where the real server's `IsolationError` is 404 NOT_FOUND. | Both answers now carry 404 NOT_FOUND with the same text. |
| m4 | `decode-groups.ets` repeated `decode.ets`'s row loop and roster read line by line. | `decodeRows` is exported, `decodeRoster` takes the groups reader (its existing callers keep the inbox reader), and the settings decoders are thin wrappers over both. |
| tests | The hypium default-name replay repeated the vitest differential case, and the vitest message-text pin asserted a constant against itself. | The hypium case was removed (the fixture replay stays on the vitest side); the pin became a comment naming `packages/db/src/spaces/groups.ts:476`, where the literal lives. |

The M1, m1 and m2 paths are UI state on branches no case asserts and the fixture walkthrough
cannot reach (the cap needs eleven bots and the fixture has two; the save race needs a slow
response; the offline read needs the server down), so they rest on the builds. m4 is exercised by
the existing decode cases; m3's fixture status is what the writes' suite runs against.

## Known limitations

- **A rename does not reach the open chat's header.** M3's thread page reads its title when it
  opens, so after saving a rename the chat under it keeps the old name until it is reopened; the
  inbox's row and the settings field show the new one. `m8-group-renamed` shows the stale header
  and `m8-group-delete-confirm` shows the new name landed.
- **`BotChecklist` renders with `ForEach`, not `LazyForEach`.** The membership cap is 10 and the
  fixture carries a handful of bots, so the list is short; a much larger bot list would want the
  lazy list.

## Filenames

`m8-group-inbox.png`, `m8-group-new-members.png`, `m8-group-new-name.png`,
`m8-group-created.png`, `m8-group-chat.png`, `m8-group-settings.png`,
`m8-group-renamed-edit.png`, `m8-group-renamed.png`, `m8-group-delete-confirm.png`,
`m8-group-deleted.png`, `m8-group-member-min.png`, in `apps/harmony/screenshots/`.