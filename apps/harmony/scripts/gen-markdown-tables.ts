// Codegen (M5): the character tables and the named-entity table the markdown parser port reads,
// copied from the same md4c sources the mobile renderer's parser is built from (the WASM under
// apps/mobile's react-native-enriched-markdown, built from cpp/enrmrkd/). The port in
// thread/markdown-*.ets must classify exactly as that parser does, so the tables are generated
// from its C rather than hand-copied. This is dev-time codegen input, not shipped logic.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));

/** Where the reference parser's sources live (an installed dependency of apps/mobile). */
export const md4cSourceDir = path.resolve(
  here,
  "../../mobile/node_modules/react-native-enriched-markdown/cpp/enrmrkd",
);

/** The license notice at the top of md4c's source, as written there. */
export function md4cNotice(): string {
  const source = readFileSync(path.join(md4cSourceDir, "enrmrkd.c"), "utf8");
  const end = source.indexOf("*/\n");
  if (!source.startsWith("/*\n * MD4C: Markdown parser for C") || end < 0) {
    throw new Error("md4c's source no longer starts with its license notice");
  }
  return source.slice(0, end + 3);
}

const MIN_FLAG = 0x40000000;
const MAX_FLAG = 0x80000000;

/** The items of a `static const unsigned NAME[] = { ... };` table, encoded as md4c encodes them. */
export function readMap(source: string, name: string): number[] {
  const match = new RegExp(
    `(?:static\\s+)?const\\s+unsigned\\s+${name}\\[\\]\\s*=\\s*\\{([\\s\\S]*?)\\};`,
  ).exec(source);
  if (!match) throw new Error(`md4c source has no table ${name}`);
  const items: number[] = [];
  // R(min, max) is a range (two encoded items), S(cp) one code point, a bare 0x… one data value.
  const item =
    /R\(\s*0x([0-9a-fA-F]+)\s*,\s*0x([0-9a-fA-F]+)\s*\)|S\(\s*0x([0-9a-fA-F]+)\s*\)|0x([0-9a-fA-F]+)/g;
  for (const found of match[1]!.matchAll(item)) {
    if (found[4] !== undefined) {
      items.push(Number.parseInt(found[4], 16));
    } else if (found[3] !== undefined) {
      items.push(Number.parseInt(found[3], 16));
    } else {
      items.push(
        Number.parseInt(found[1]!, 16) | MIN_FLAG,
        Number.parseInt(found[2]!, 16) | MAX_FLAG,
      );
    }
  }
  // Every token the table holds must be one we understood, or the generated copy would be wrong.
  const rest = match[1]!
    .replace(item, "")
    .replace(/#[^\n]*|\/\/[^\n]*/g, "")
    .replace(/[\s,]/g, "");
  if (rest !== "") throw new Error(`md4c table ${name} holds unread tokens: ${rest.slice(0, 40)}`);
  return items;
}

export interface EntityRow {
  /** The reference as written in Markdown, ampersand and semicolon included. */
  name: string;
  codepoints: number[];
}

/** Every named entity of md4c's table, in its order. */
export function readEntities(source: string): EntityRow[] {
  const match = /ENRMRKD_ENTITY_MAP\[\]\s*=\s*\{([\s\S]*?)\n\};/.exec(source);
  if (!match) throw new Error("md4c source has no entity table");
  const rows: EntityRow[] = [];
  const row = /\{\s*"([^"]*)"\s*,\s*\{\s*(\d+)\s*,\s*(\d+)\s*\}\s*\}/g;
  for (const found of match[1]!.matchAll(row)) {
    rows.push({
      name: found[1]!,
      codepoints: [Number(found[2]), Number(found[3])].filter((codepoint) => codepoint !== 0),
    });
  }
  return rows;
}

function wrapped(name: string, doc: string, items: number[], perLine: number): string {
  const lines: string[] = [];
  for (let index = 0; index < items.length; index += perLine) {
    lines.push(`  ${items.slice(index, index + perLine).join(", ")},`);
  }
  return `/** ${doc} */\nexport const ${name}: number[] = [\n${lines.join("\n")}\n];`;
}

/**
 * The generated module: one entry per entity as `codepoints,name` on its own line, so the port
 * builds its lookup once at first use.
 */
export function renderTables(maps: Record<string, number[]>, entities: EntityRow[]): string {
  const table = entities
    .map((entity) => `${entity.codepoints.join(" ")},${entity.name}`)
    .join("\n");
  const sections = [
    wrapped(
      "MD_WHITESPACE_MAP",
      "Unicode Zs (category space separators), encoded as in md4c's whitespace map.",
      maps.whitespace!,
      8,
    ),
    wrapped(
      "MD_PUNCT_MAP",
      "Unicode punctuation and symbols (general categories P and S), encoded as in md4c's map.",
      maps.punct!,
      8,
    ),
    wrapped("MD_FOLD_MAP_1", "Code points that fold to one code point.", maps.fold1!, 10),
    wrapped("MD_FOLD_MAP_1_DATA", "What each MD_FOLD_MAP_1 item folds to.", maps.fold1Data!, 10),
    wrapped("MD_FOLD_MAP_2", "Code points that fold to two code points.", maps.fold2!, 10),
    wrapped(
      "MD_FOLD_MAP_2_DATA",
      "What each MD_FOLD_MAP_2 item folds to, two per item.",
      maps.fold2Data!,
      10,
    ),
    wrapped("MD_FOLD_MAP_3", "Code points that fold to three code points.", maps.fold3!, 10),
    wrapped(
      "MD_FOLD_MAP_3_DATA",
      "What each MD_FOLD_MAP_3 item folds to, three per item.",
      maps.fold3Data!,
      10,
    ),
    `/** Every named entity md4c knows: one \`codepoints,name\` line per entity (md4c's own order). */\nexport const MD_ENTITY_TABLE: string = ${JSON.stringify(table)};`,
  ];
  // The tables are copied out of md4c, so the file carries md4c's notice, as its license asks.
  return (
    `// Generated by scripts/gen-markdown-tables.ts from md4c's C sources. Do not edit.\n` +
    `${md4cNotice()}${sections.join("\n\n")}\n`
  );
}

/** Reads the reference tables; throws when the dependency's sources are not where expected. */
export function loadTables(): { maps: Record<string, number[]>; entities: EntityRow[] } {
  const core = readFileSync(path.join(md4cSourceDir, "enrmrkd.c"), "utf8");
  const entity = readFileSync(path.join(md4cSourceDir, "enrmrkd-entity.c"), "utf8");
  return {
    maps: {
      whitespace: readMap(core, "WHITESPACE_MAP"),
      punct: readMap(core, "PUNCT_MAP"),
      fold1: readMap(core, "FOLD_MAP_1"),
      fold1Data: readMap(core, "FOLD_MAP_1_DATA"),
      fold2: readMap(core, "FOLD_MAP_2"),
      fold2Data: readMap(core, "FOLD_MAP_2_DATA"),
      fold3: readMap(core, "FOLD_MAP_3"),
      fold3Data: readMap(core, "FOLD_MAP_3_DATA"),
    },
    entities: readEntities(entity),
  };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const { maps, entities } = loadTables();
  const outFile = path.resolve(here, "../entry/src/main/ets/thread/markdown-tables.generated.ets");
  mkdirSync(path.dirname(outFile), { recursive: true });
  writeFileSync(outFile, renderTables(maps, entities));
  console.log(
    `gen-markdown-tables: ${entities.length} entities, ${maps.punct!.length} punct entries → thread/markdown-tables.generated.ets`,
  );
}
