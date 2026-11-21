// Layer 1 drift detection (design §4.3.2): the consumed contract views are exported as JSON
// Schema and pinned to committed snapshots. Any diff fails — a new optional field can change
// semantics too (review Q8). Fix path: port the change into the ArkTS decoder and update the
// snapshot in the same PR (HARMONY_UPDATE_SNAPSHOTS=1 regenerates the files).
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  appContract,
  authCapabilitiesSchema,
  MeSchema,
  SpaceNavigationSchema,
} from "@rakazo/contracts";
import { describe, expect, it } from "vitest";
import { z } from "zod";
import { snapshotViews } from "./manifest";

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
  it("pins the views to the schemas the real contract procedures use", () => {
    expect(appContract.health["~orpc"].outputSchema).toBeDefined();
    expect(appContract.me["~orpc"].outputSchema).toBe(MeSchema);
    expect(appContract.spaces.list["~orpc"].outputSchema).toBe(SpaceNavigationSchema);
    // capabilities is better-auth REST, not an RPC procedure; its schema is the contract source.
    expect(authCapabilitiesSchema).toBeDefined();
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
