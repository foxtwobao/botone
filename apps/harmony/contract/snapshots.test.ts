// Layer 1 drift detection (design §4.3.2): the consumed contract views are exported as JSON
// Schema and pinned to committed snapshots. Any diff fails — a new optional field can change
// semantics too (review Q8). Fix path: port the change into the ArkTS decoder and update the
// snapshot in the same PR (HARMONY_UPDATE_SNAPSHOTS=1 regenerates the files).
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { getEventIteratorSchemaDetails } from "@orpc/contract";
import {
  appContract,
  MessageBlock,
  MessageRole,
  ProductEventType,
  RunStatus,
  SpaceChangeKind,
} from "@rakazo/contracts";
import { describe, expect, it } from "vitest";
import { z } from "zod";
import {
  botsListArchivedView,
  botsListView,
  botView,
  groupsListArchivedView,
  groupView,
  messageBlockKindsView,
  meView,
  notificationsSubscribeView,
  runView,
  snapshotViews,
  spacesListView,
  threadEventView,
  threadMemberView,
  threadMessageView,
  threadSendOutputView,
  threadSnapshotView,
} from "../scripts/contract-manifest";

const snapshotDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "snapshots");
const update = process.env.HARMONY_UPDATE_SNAPSHOTS === "1";

/** Stable form: sorted keys, no prose metadata a zod release could reword. */
function normalize(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(normalize);
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const key of Object.keys(value as Record<string, unknown>).sort()) {
      if (key === "description" || key === "title" || key === "$schema") continue;
      out[key] = normalize((value as Record<string, unknown>)[key]);
    }
    return out;
  }
  return value;
}

describe("harmony layer-1 contract snapshots", () => {
  it("views project the real procedure outputs, not hand-written copies", () => {
    // health is consumed whole: the view IS the procedure's own output schema.
    expect(snapshotViews.health).toBe(appContract.health["~orpc"].outputSchema);
    // Picked views keep the procedure's own field schemas, so a rebind replaces them and goes red.
    const expectFields = (view: z.ZodObject, source: z.ZodObject, label: string) => {
      const shape = source.shape as Record<string, unknown>;
      for (const [key, field] of Object.entries(view.shape)) {
        expect(field, `${label}.${key}`).toBe(shape[key]);
      }
    };
    expectFields(meView, appContract.me["~orpc"].outputSchema!, "me");

    const spacesOutput = appContract.spaces.list["~orpc"].outputSchema!;
    expect(spacesListView.shape.current.shape.id).toBe(spacesOutput.shape.current.shape.id);
    expect(spacesListView.shape.current.shape.name).toBe(spacesOutput.shape.current.shape.name);
    // The roster rows project the same Bot/Group schemas the list procedures declare.
    expectFields(botView, appContract.bots.list["~orpc"].outputSchema!.element, "bot");
    expectFields(groupView, appContract.groups.list["~orpc"].outputSchema!.element, "group");
    expectFields(spacesListView.shape.current.shape.bots.element, botView, "spaces.bots");
    expectFields(spacesListView.shape.current.shape.groups.element, groupView, "spaces.groups");
    expect(botsListView.element).toBe(botView);
    expect(botsListArchivedView.element).toBe(botView);
    expect(groupsListArchivedView.element).toBe(groupView);
    expectFields(
      botsListView.element,
      appContract.bots.list["~orpc"].outputSchema!.element,
      "bots.list",
    );
    expectFields(
      botsListArchivedView.element,
      appContract.bots.listArchived["~orpc"].outputSchema!.element,
      "bots.listArchived",
    );
    expectFields(
      groupsListArchivedView.element,
      appContract.groups.listArchived["~orpc"].outputSchema!.element,
      "groups.listArchived",
    );

    // archive/restore views ARE the procedures' own input/output schemas.
    const io: [z.ZodType, unknown][] = [
      [snapshotViews["bot-archive-input"], appContract.bots.archive["~orpc"].inputSchema],
      [snapshotViews["bot-archive-output"], appContract.bots.archive["~orpc"].outputSchema],
      [snapshotViews["bot-restore-input"], appContract.bots.restore["~orpc"].inputSchema],
      [snapshotViews["bot-restore-output"], appContract.bots.restore["~orpc"].outputSchema],
      [snapshotViews["group-archive-input"], appContract.groups.archive["~orpc"].inputSchema],
      [snapshotViews["group-archive-output"], appContract.groups.archive["~orpc"].outputSchema],
      [snapshotViews["group-restore-input"], appContract.groups.restore["~orpc"].inputSchema],
      [snapshotViews["group-restore-output"], appContract.groups.restore["~orpc"].outputSchema],
    ];
    for (const [view, schema] of io) {
      expect(view).toBe(schema);
    }

    // The signal enum is the real eventIterator yields type, and the kinds are the real enum.
    const yields = getEventIteratorSchemaDetails(
      appContract.notifications.subscribe["~orpc"].outputSchema,
    )!.yields as z.ZodObject;
    expect(notificationsSubscribeView.shape.type).toBe(yields.shape.type);
    expect(snapshotViews["space-change-kind"]).toBe(SpaceChangeKind);

    // M3: the thread views project the real schemas' own field objects, so a rebind or a field
    // type mutation goes red even where the view rebuilds a refined input (pickRefined).
    const snapshotSource = appContract.threads.get["~orpc"].outputSchema!;
    // The picked scalar fields keep the source's own schemas; messages/members/run/activeRuns
    // are .extend()ed to the projected element schemas (asserted separately below).
    for (const key of ["threadId", "cursor", "olderCursor", "botId", "groupId"]) {
      expect(threadSnapshotView.shape[key], `thread.snapshot.${key}`).toBe(
        snapshotSource.shape[key],
      );
    }
    expectFields(threadMessageView, snapshotSource.shape.messages.element, "thread.message");
    expectFields(runView, snapshotSource.shape.run.unwrap(), "thread.run");
    expectFields(threadMemberView, snapshotSource.shape.members.unwrap().element, "thread.member");
    // The nested arrays reuse the SAME projected element schemas (not fresh copies).
    expect(threadSnapshotView.shape.messages.element).toBe(threadMessageView);
    expect(threadSnapshotView.shape.run.unwrap()).toBe(runView);
    expect(threadSnapshotView.shape.activeRuns.unwrap().element).toBe(runView);
    expect(threadSnapshotView.shape.members.unwrap().element).toBe(threadMemberView);
    expect(snapshotViews["thread-message-page"].shape.messages.element).toBe(threadMessageView);
    // blocks stays the full MessageBlock union (the render layer degrades unknown kinds).
    expect(threadMessageView.shape.blocks.element).toBe(MessageBlock);
    // The send receipt projects the real output's fields.
    expectFields(
      threadSendOutputView,
      appContract.threads.send["~orpc"].outputSchema!,
      "thread.send",
    );
    // The event view IS the real eventIterator yields schema (consumed whole).
    const threadYields = getEventIteratorSchemaDetails(
      appContract.threads.subscribe["~orpc"].outputSchema,
    )!.yields;
    expect(threadEventView).toBe(threadYields);
    // The dispatch enums are the real enums, and the kind list covers every MessageBlock variant.
    expect(snapshotViews["product-event-type"]).toBe(ProductEventType);
    expect(snapshotViews["run-status"]).toBe(RunStatus);
    expect(snapshotViews["message-role"]).toBe(MessageRole);
    expect(messageBlockKindsView.options).toEqual(
      MessageBlock.options.map((option) => option.shape.kind.value),
    );
  });

  for (const [name, schema] of Object.entries(snapshotViews)) {
    it(`snapshot ${name} matches the committed schema`, () => {
      const generated = normalize(z.toJSONSchema(schema));
      const file = path.join(snapshotDir, `${name}.json`);
      if (update) {
        mkdirSync(snapshotDir, { recursive: true });
        writeFileSync(file, `${JSON.stringify(generated, null, 2)}\n`);
        return;
      }
      expect(existsSync(file), `missing snapshot; run HARMONY_UPDATE_SNAPSHOTS=1 vitest`).toBe(
        true,
      );
      // Deep-compare the normalized schema so a formatter's whitespace is not drift; any
      // field/type/required change still fails.
      expect(generated).toEqual(normalize(JSON.parse(readFileSync(file, "utf8"))));
    });
  }
});
