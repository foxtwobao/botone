// Layer 1 drift detection (design §4.3.2): the consumed contract views are exported as JSON
// Schema and pinned to committed snapshots. Any diff fails — a new optional field can change
// semantics too (review Q8). Fix path: port the change into the ArkTS decoder and update the
// snapshot in the same PR (HARMONY_UPDATE_SNAPSHOTS=1 regenerates the files).
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { appContract } from "@rakazo/contracts";
import { describe, expect, it } from "vitest";
import { z } from "zod";
import { meView, snapshotViews, spacesListView } from "../scripts/contract-manifest";

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
    const meOutput = appContract.me["~orpc"].outputSchema!;
    const meShape = meOutput.shape as Record<string, unknown>;
    for (const [key, field] of Object.entries(meView.shape)) {
      expect(field, `me.${key}`).toBe(meShape[key]);
    }
    const spacesOutput = appContract.spaces.list["~orpc"].outputSchema!;
    expect(spacesListView.shape.current.shape.id).toBe(spacesOutput.shape.current.shape.id);
    expect(spacesListView.shape.current.shape.name).toBe(spacesOutput.shape.current.shape.name);
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
