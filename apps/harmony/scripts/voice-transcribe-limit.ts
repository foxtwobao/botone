// Read the server-owned limit without importing or executing the adapters package.
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const sourceFile = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../../packages/adapters/src/voice/voice-factory.ts",
);

export function readMaxTranscribeBytes(source = readFileSync(sourceFile, "utf8")): number {
  const matches = [...source.matchAll(/^export const MAX_TRANSCRIBE_BYTES = (.+);$/gm)];
  if (matches.length !== 1) {
    throw new Error(`Expected one MAX_TRANSCRIBE_BYTES definition in ${sourceFile}`);
  }

  const expression = matches[0][1];
  if (!/^(?:\d+)(?:\s*\*\s*\d+)*$/.test(expression)) {
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
