// Codegen: the notices file the app ships (resources/rawfile/THIRD-PARTY-NOTICES.txt), built from
// the license texts of the open-source work the app's markdown code is ported or generated from.
// Each text is read from the dependency's own files, so a dependency update carries its license
// along. The ported sources carry the md4c notice in their headers too; contract/licenses.test.ts
// holds the two to each other.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { md4cNotice } from "./gen-markdown-tables.ts";

const here = path.dirname(fileURLToPath(import.meta.url));
const appRoot = path.resolve(here, "..");

/** A dependency's folder, resolved as `from` (a package.json) resolves it, with its version. */
function dependency(from: string, name: string): { dir: string; version: string; license: string } {
  const dir = path.dirname(createRequire(from).resolve(`${name}/package.json`));
  const manifest = JSON.parse(readFileSync(path.join(dir, "package.json"), "utf8")) as {
    version: string;
    license?: string;
  };
  const licenseFile = ["LICENSE", "LICENSE.txt", "LICENSE.md"].find((file) =>
    existsSync(path.join(dir, file)),
  );
  if (!licenseFile) throw new Error(`${name} ships no license file`);
  return {
    dir,
    version: manifest.version,
    license: readFileSync(path.join(dir, licenseFile), "utf8"),
  };
}

const RULE = "=".repeat(78);
const section = (title: string, text: string): string =>
  `${RULE}\n${title}\n${RULE}\n\n${text.trim()}\n\n`;

/** The whole notices file. */
export function renderNotices(): string {
  const mobile = path.resolve(here, "../../mobile/package.json");
  const chatUi = path.resolve(here, "../../../packages/chat-ui/package.json");
  const enriched = dependency(mobile, "react-native-enriched-markdown");
  const display = dependency(mobile, "@ronradtke/react-native-markdown-display");
  const linkify = dependency(chatUi, "linkify-it");
  // linkify-it builds its patterns from uc.micro's character classes.
  const ucMicro = dependency(path.join(linkify.dir, "package.json"), "uc.micro");
  const markdownIt = dependency(path.join(display.dir, "package.json"), "markdown-it");
  const list = (name: string, found: { version: string; license: string }): string =>
    section(`${name} ${found.version}`, found.license);
  return [
    "Third-party notices",
    "",
    "The Rakazo app for HarmonyOS contains code ported from, and patterns generated from, the",
    "open-source projects listed below. Their licenses follow, as each project writes them.",
    "",
    section("md4c", md4cNotice()),
    list("react-native-enriched-markdown", enriched),
    list("linkify-it", linkify),
    list("uc.micro", ucMicro),
    list("markdown-it", markdownIt),
  ].join("\n");
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const outFile = path.join(appRoot, "entry/src/main/resources/rawfile/THIRD-PARTY-NOTICES.txt");
  mkdirSync(path.dirname(outFile), { recursive: true });
  writeFileSync(outFile, renderNotices());
  console.log(
    `gen-notices: third-party notices → entry/src/main/resources/rawfile/THIRD-PARTY-NOTICES.txt`,
  );
}
