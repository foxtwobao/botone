// The contract JSON is regenerated through Biome: JSON.stringify(x, null, 2) expands the
// short arrays Biome collapses, so without this the committed files fail `biome check`
// right after every HARMONY_UPDATE_* run. Spawning the repo's own Biome binary keeps one
// formatter instead of re-implementing its array-wrapping rules here.
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const biome = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../../node_modules/.bin/biome",
);

export type GeneratedFormatter = (file: string, text: string) => string;

/** Formats `text` the way Biome would format the file at `file`; throws when Biome cannot. */
export const formatWithBiome: GeneratedFormatter = (file, text) =>
  execFileSync(biome, ["format", `--stdin-file-path=${file}`], {
    input: text,
    encoding: "utf8",
  });

/**
 * Writes `value` as the JSON file at `file`, formatted. The file is replaced only once
 * formatting succeeded, so a failing formatter leaves what was there untouched.
 */
export function writeGenerated(
  file: string,
  value: unknown,
  format: GeneratedFormatter = formatWithBiome,
): void {
  const formatted = format(file, `${JSON.stringify(value, null, 2)}\n`);
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, formatted);
}
