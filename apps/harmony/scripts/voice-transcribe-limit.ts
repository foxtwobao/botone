// Read the server-owned limit without importing or executing the adapters package. The source is
// read as text: comments come out first, so a commented-out older declaration can never be taken
// for the real one, and the declaration may wrap across lines.
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const sourceFile = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../../packages/adapters/src/voice/voice-factory.ts",
);

/** The source with its comments removed, string literals left as they are. */
export function stripComments(source: string): string {
  let out = "";
  let index = 0;
  let quote: string | null = null;
  while (index < source.length) {
    const char = source[index] ?? "";
    const next = source[index + 1] ?? "";
    if (quote !== null) {
      out += char;
      if (char === "\\") {
        out += next;
        index += 2;
        continue;
      }
      if (char === quote) {
        quote = null;
      }
      index += 1;
      continue;
    }
    if (char === "/" && next === "/") {
      while (index < source.length && source[index] !== "\n") {
        index += 1;
      }
      continue;
    }
    if (char === "/" && next === "*") {
      index += 2;
      while (index < source.length && !(source[index] === "*" && source[index + 1] === "/")) {
        // A comment's newlines still separate whatever surrounds it.
        if (source[index] === "\n") {
          out += "\n";
        }
        index += 1;
      }
      index += 2;
      continue;
    }
    if (char === '"' || char === "'" || char === "`") {
      quote = char;
    }
    out += char;
    index += 1;
  }
  return out;
}

export function readMaxTranscribeBytes(source = readFileSync(sourceFile, "utf8")): number {
  const code = stripComments(source);
  const matches = [...code.matchAll(/export const MAX_TRANSCRIBE_BYTES =([\s\S]*?);/g)];
  if (matches.length !== 1) {
    throw new Error(`Expected one MAX_TRANSCRIBE_BYTES definition in ${sourceFile}`);
  }

  const expression = (matches[0][1] ?? "").trim();
  if (!/^\d+(?:\s*\*\s*\d+)*$/.test(expression)) {
    throw new Error(`Unsupported MAX_TRANSCRIBE_BYTES expression: ${expression}`);
  }

  const value = expression.split("*").reduce((product, factor) => {
    const next = product * Number(factor.trim());
    if (!Number.isSafeInteger(next) || next <= 0) {
      throw new Error(`Invalid MAX_TRANSCRIBE_BYTES expression: ${expression}`);
    }
    return next;
  }, 1);
  return value;
}
