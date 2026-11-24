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

export function writeGenerated(file: string, value: unknown): void {
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
  execFileSync(biome, ["format", "--write", file], { stdio: "pipe" });
}
