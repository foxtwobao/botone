// Read the server-owned limit without importing or executing the adapters package. The limit
// lives in a file of its own that holds the one declaration, so the whole file is checked against
// that shape: anything else in it — a block comment, a string, a second statement, an initializer
// that is not a literal product — is reported, never guessed. Line comments may precede the
// declaration; they cannot hide one, since each ends at its line.
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const NAME = "MAX_TRANSCRIBE_BYTES";
const sourceFile = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../../packages/adapters/src/voice/transcribe-limit.ts",
);

const DECLARATION = new RegExp(`^export const ${NAME}\\s*=\\s*(\\d+(?:\\s*\\*\\s*\\d+)*)\\s*;$`);

export function readMaxTranscribeBytes(source = readFileSync(sourceFile, "utf8")): number {
  const lines = source.split(/\r\n|\r|\n/);
  const kept: string[] = [];
  for (const line of lines) {
    if (/^\s*\/\//.test(line)) {
      continue;
    }
    kept.push(line);
  }
  const code = kept.join("\n").trim();
  const match = DECLARATION.exec(code);
  if (match === null) {
    throw new Error(
      `Expected ${sourceFile} to hold only \`${NAME} = <number> * <number>;\`, with line comments at most`,
    );
  }
  return product(match[1] ?? "");
}

/** The value of `8 * 1024 * 1024`: every factor and every partial product a safe positive integer. */
function product(expression: string): number {
  let value = 1;
  for (const factor of expression.split("*")) {
    const next = value * Number(factor.trim());
    if (!Number.isSafeInteger(next) || next <= 0) {
      throw new Error(`Unsupported ${NAME} product in ${sourceFile}: ${expression}`);
    }
    value = next;
  }
  return value;
}
