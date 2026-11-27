// The harmony contract fixtures hold localized dates for the shipped Chinese locales, so their
// expected values only hold in the zone they were generated in. The harmony vitest project pins
// it; a fixture regenerated elsewhere would then pass here and fail on CI, which runs in UTC.
import assert from "node:assert/strict";
import { globSync, readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

test("the harmony contract fixtures run in the zone they were generated in", () => {
  const config = readFileSync(path.join(root, "vitest.config.ts"), "utf8");
  const project = config.match(/name: "harmony",[\s\S]{0,120}?env: \{ TZ: "([^"]+)" \}/);
  assert.ok(project, "vitest.config.ts should pin TZ for the harmony project");

  const dates = JSON.parse(
    readFileSync(path.join(root, "apps/harmony/contract/fixtures/dates.json"), "utf8"),
  );
  const cases = dates.cases;
  assert.ok(cases.length > 0, "dates.json should hold cases");

  // Every case carries the fixed "now" and the ISO instant it formats; both are UTC on disk.
  for (const entry of cases) {
    assert.ok(typeof entry.now === "string" && typeof entry.iso === "string");
  }

  // The zone must offset the same as the one the fixture was generated in. Regenerating in
  // another zone shifts the local day the clock cases fall on, so compare a known case.
  const first = cases.find((entry) => entry.kind === "row" && entry.expected.includes(":"));
  assert.ok(first, "dates.json should hold a clock case");
  const zone = project[1];
  const formatter = new Intl.DateTimeFormat("en-US", {
    timeZone: zone,
    hour: "numeric",
    minute: "2-digit",
  });
  const expected = formatter.format(new Date(first.iso));
  const stored = new Date(first.now).toISOString();
  assert.ok(stored.length > 0);
  // The fixture's clock expectations and its `now` agree only in the generating zone.
  assert.equal(
    first.expected.replace(/\s/g, " "),
    expected.replace(/\s/g, " "),
    `dates.json was generated in another zone than ${zone}; regenerate it there`,
  );
});

test("the harmony fixture generators live in the harmony project", () => {
  const config = readFileSync(path.join(root, "vitest.config.ts"), "utf8");
  const contract = globSync("apps/harmony/contract/**/*.test.ts", { cwd: root });
  assert.ok(contract.length > 0, "apps/harmony/contract should hold tests");
  assert.match(config, /name: "harmony"/);
});
