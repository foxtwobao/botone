// Differential check for the group-rules port (M8): the port's decisions against the real
// contract defaultGroupName, plus handwritten expectations for the mobile group-settings merge
// and the membership-conflict recognition. The port is the .ets source loaded as erasable
// TypeScript, the same trick the other harmony port tests use; where the two disagree the
// assertion prints the case.
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { defaultGroupName as realDefaultGroupName } from "@rakazo/contracts";
import { afterAll, describe, expect, it } from "vitest";
import type * as groupRulesPort from "../entry/src/main/ets/features/groups/group-rules.ets";

const appRoot = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const groupsDir = path.join(appRoot, "entry/src/main/ets/features/groups");
// A directory of this run's own: two runs (another worktree, another worker) must not read each
// other's copy of the port.
const outDir = mkdtempSync(path.join(tmpdir(), "harmony-group-rules-"));
afterAll(() => rmSync(outDir, { force: true, recursive: true }));
writeFileSync(
  path.join(outDir, "group-rules.ts"),
  readFileSync(path.join(groupsDir, "group-rules.ets"), "utf8")
    .replace(/from '\.\/([a-z.-]+?)'/g, "from './$1.ts'")
    .replace(/Record<string, Object>/g, "Record<string, object>"),
);
const rules = (await import(
  pathToFileURL(path.join(outDir, "group-rules.ts")).href
)) as typeof groupRulesPort;

interface GroupFixture {
  defaultName: { names: string[]; expected: string }[];
}
const fixture = JSON.parse(
  readFileSync(path.join(appRoot, "contract/fixtures/group.json"), "utf8"),
) as GroupFixture;

describe("group default name port", () => {
  it("matches the real contract on every recorded case", () => {
    for (const entry of fixture.defaultName) {
      expect(rules.defaultGroupName(entry.names), JSON.stringify(entry.names)).toBe(entry.expected);
    }
  });

  it("matches the real contract on unrecorded edges", () => {
    const edges: string[][] = [
      [],
      ["Alpha"],
      ["Alpha", "Beta", "Gamma"],
      ["A".repeat(80)],
      [`${"A".repeat(80)}B`],
      [`a${"😀".repeat(41)}`],
      ["  Alpha  ", " Beta "],
      ["", ""],
      [""],
    ];
    for (const names of edges) {
      expect(rules.defaultGroupName(names), JSON.stringify(names)).toBe(
        realDefaultGroupName(names),
      );
    }
  });
});

describe("group edit rebase", () => {
  const active = ["b1", "b2", "b3"];
  const edit = (groupId: string, members: string[]) => ({ groupId, members });

  const cases: {
    name: string;
    previous: { groupId: string; members: string[] };
    next: { groupId: string; members: string[] };
    selectable: string[];
    selected: string[];
    deselected: string[];
    expected: string[];
  }[] = [
    {
      name: "nothing changed keeps the selection",
      previous: edit("g1", ["b1", "b2"]),
      next: edit("g1", ["b1", "b2"]),
      selectable: active,
      selected: ["b1", "b2"],
      deselected: [],
      expected: ["b1", "b2"],
    },
    {
      name: "another client's new member joins",
      previous: edit("g1", ["b1", "b2"]),
      next: edit("g1", ["b1", "b2", "b3"]),
      selectable: active,
      selected: ["b1", "b2"],
      deselected: [],
      expected: ["b1", "b2", "b3"],
    },
    {
      name: "another client's removed member leaves",
      previous: edit("g1", ["b1", "b2", "b3"]),
      next: edit("g1", ["b1", "b2"]),
      selectable: active,
      selected: ["b1", "b2", "b3"],
      deselected: [],
      expected: ["b1", "b2"],
    },
    {
      name: "a local deselect is kept over the refresh",
      previous: edit("g1", ["b1", "b2"]),
      next: edit("g1", ["b1", "b2", "b3"]),
      selectable: active,
      selected: ["b1"],
      deselected: ["b2"],
      expected: ["b1", "b3"],
    },
    {
      name: "another group starts from its own members and forgets deselects",
      previous: edit("g9", ["b1", "b2"]),
      next: edit("g1", ["b2", "b3"]),
      selectable: active,
      selected: ["b1"],
      deselected: ["b1"],
      expected: ["b2", "b3"],
    },
    {
      name: "a locally added bot is kept",
      previous: edit("g1", ["b1", "b2"]),
      next: edit("g1", ["b1", "b2"]),
      selectable: active,
      selected: ["b1", "b2", "b3"],
      deselected: [],
      expected: ["b1", "b2", "b3"],
    },
    {
      name: "a locally added bot that was archived meanwhile is dropped",
      previous: edit("g1", ["b1", "b2"]),
      next: edit("g1", ["b1", "b2"]),
      selectable: ["b1", "b2"],
      selected: ["b1", "b2", "b3"],
      deselected: [],
      expected: ["b1", "b2"],
    },
  ];

  for (const c of cases) {
    it(c.name, () => {
      const deselected = new Set(c.deselected);
      const merged = rules.rebaseGroupEdit(
        c.previous,
        c.next,
        c.selectable,
        c.selected,
        deselected,
      );
      expect(merged).toEqual(c.expected);
      if (c.previous.groupId !== c.next.groupId) {
        expect([...deselected]).toEqual([]);
      }
    });
  }
});

describe("group membership conflict recognition", () => {
  it("recognizes exactly the server's precondition refusal", () => {
    const error = (status: number, message: string) => ({ status, message });
    expect(
      rules.isGroupChangedError(
        error(404, "Group members changed. Refresh and try again.") as never,
      ),
    ).toBe(true);
    expect(rules.isGroupChangedError(error(404, "Group not found") as never)).toBe(false);
    expect(
      rules.isGroupChangedError(
        error(400, "Group members changed. Refresh and try again.") as never,
      ),
    ).toBe(false);
    expect(rules.isGroupChangedError(null)).toBe(false);
  });

  // The port's GROUP_MEMBERS_CHANGED literal mirrors packages/db/src/spaces/groups.ts:476, the
  // server's precondition refusal; harmony cannot import @rakazo/db, so the case above spells the
  // same text and this needs no assertion of its own.
});

describe("group update input", () => {
  it("sends nothing when neither the name nor the membership changed", () => {
    expect(rules.groupUpdateInput("g1", "Team", "Team", ["b1", "b2"], ["b1", "b2"])).toBeNull();
    expect(rules.groupUpdateInput("g1", "Team", " Team ", ["b1", "b2"], ["b1", "b2"])).toBeNull();
  });

  it("sends only the trimmed name when the membership is untouched", () => {
    expect(rules.groupUpdateInput("g1", "Team", " Renamed ", ["b1", "b2"], ["b1", "b2"])).toEqual({
      groupId: "g1",
      name: "Renamed",
    });
  });

  it("sends the membership with the baseline the server checks", () => {
    expect(rules.groupUpdateInput("g1", "Team", "Team", ["b1", "b2"], ["b1", "b3"])).toEqual({
      groupId: "g1",
      botIds: ["b1", "b3"],
      expectedBotIds: ["b1", "b2"],
    });
  });

  it("sends both when both changed", () => {
    expect(
      rules.groupUpdateInput("g1", "Team", "Renamed", ["b1", "b2"], ["b1", "b2", "b3"]),
    ).toEqual({
      groupId: "g1",
      name: "Renamed",
      botIds: ["b1", "b2", "b3"],
      expectedBotIds: ["b1", "b2"],
    });
  });
});
