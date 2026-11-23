// Codegen (design §6.6, C-1): compile the real lingui catalogs to the msgid → msgstr JSON the
// device loads from rawfile. Phase 1 ships en / zh-CN / zh-TW; other locales fall back to en.
// Reads through lingui's own PO parser (scripts/po.ts) — no hand-rolled PO subset.
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { readCatalog } from "./po.ts";

const here = path.dirname(fileURLToPath(import.meta.url));
const localesDir = path.resolve(here, "../../../packages/i18n/locales");
const outDir = path.resolve(here, "../entry/src/main/resources/rawfile/i18n");

mkdirSync(outDir, { recursive: true });
for (const locale of ["en", "zh-CN", "zh-TW"]) {
  const messages = readCatalog(localesDir, locale);
  writeFileSync(path.join(outDir, `${locale}.json`), `${JSON.stringify(messages, null, 0)}\n`);
  console.log(`gen-i18n: ${locale} (${Object.keys(messages).length} messages)`);
}
