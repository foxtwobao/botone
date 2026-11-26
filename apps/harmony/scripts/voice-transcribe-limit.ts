// Read the server-owned limit without importing or executing the adapters package. The source is
// tokenized first, so text that merely looks like a declaration — inside a comment, a string, a
// template or a regex — is never one. Only a literal multiplication is accepted; anything this
// reader cannot classify is reported, never guessed, because a wrong ceiling would be built in
// silently. (The compiler package shipped here is the native port and offers no parser API.)
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const NAME = "MAX_TRANSCRIBE_BYTES";
const sourceFile = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../../packages/adapters/src/voice/voice-factory.ts",
);

/** Keywords a `/` may follow as the start of a regex rather than a division. */
const REGEX_AFTER_WORD: Set<string> = new Set<string>([
  "return",
  "typeof",
  "instanceof",
  "in",
  "of",
  "new",
  "delete",
  "void",
  "throw",
  "case",
  "do",
  "else",
  "yield",
  "await",
]);
/** Punctuators a `/` may follow as the start of a regex. */
const REGEX_AFTER_PUNCT: Set<string> = new Set<string>([
  "(",
  ",",
  "=",
  ":",
  "[",
  "!",
  "&",
  "|",
  "?",
  "{",
  "}",
  ";",
  "+",
  "-",
  "*",
  "%",
  "<",
  ">",
  "~",
]);

type TokenKind = "identifier" | "number" | "string" | "template" | "regex" | "punct";

interface Token {
  kind: TokenKind;
  text: string;
}

interface Cursor {
  text: string;
  at: number;
}

export function readMaxTranscribeBytes(source = readFileSync(sourceFile, "utf8")): number {
  const tokens = tokenize(source);
  const named = tokens.filter(
    (token: Token): boolean => token.kind === "identifier" && token.text === NAME,
  );
  if (named.length !== 1) {
    throw new Error(`Expected one occurrence of ${NAME} in ${sourceFile}, found ${named.length}`);
  }
  const declaration = findDeclaration(tokens);
  if (declaration === null) {
    throw new Error(`Expected an exported ${NAME} = <number> in ${sourceFile}`);
  }
  return declaration;
}

/** The value of `export const NAME = <literal product>;`, or null when no such statement exists. */
function findDeclaration(tokens: Token[]): number | null {
  const found: number[] = [];
  for (let index = 0; index + 3 < tokens.length; index += 1) {
    if (!isWord(tokens[index], "export") || !isWord(tokens[index + 1], "const")) {
      continue;
    }
    if (!isWord(tokens[index + 2], NAME)) {
      continue;
    }
    // A declaration may carry a type annotation: `NAME: number = ...`.
    let equals = index + 3;
    if (tokens[equals]?.text === ":") {
      equals += 1;
      while (
        tokens[equals] !== undefined &&
        tokens[equals]?.text !== "=" &&
        tokens[equals]?.text !== ";"
      ) {
        equals += 1;
      }
    }
    const marker = tokens[equals];
    if (marker === undefined || marker.text !== "=" || marker.kind !== "punct") {
      continue;
    }
    const product: number[] = [];
    let at = equals + 1;
    for (;;) {
      const factor = tokens[at];
      if (factor === undefined || factor.kind !== "number") {
        throw new Error(`Unsupported ${NAME} expression in ${sourceFile}: expected a number`);
      }
      product.push(literalValue(factor.text));
      const operator = tokens[at + 1];
      if (operator === undefined || operator.kind !== "punct") {
        throw new Error(`Unsupported ${NAME} expression in ${sourceFile}: expected '*' or ';'`);
      }
      if (operator.text === "*") {
        at += 2;
        continue;
      }
      if (operator.text === ";") {
        break;
      }
      throw new Error(`Unsupported ${NAME} expression in ${sourceFile}: ${operator.text}`);
    }
    found.push(product.reduce((left: number, right: number): number => left * right, 1));
    index = at;
  }
  if (found.length > 1) {
    throw new Error(`Expected one exported ${NAME} in ${sourceFile}, found ${found.length}`);
  }
  return found.length === 1 ? (found[0] ?? null) : null;
}

function literalValue(text: string): number {
  const digits = text.replaceAll("_", "");
  if (!/^\d+$/.test(digits)) {
    throw new Error(`Unsupported ${NAME} literal in ${sourceFile}: ${text}`);
  }
  const value = Number(digits);
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`Unsupported ${NAME} literal in ${sourceFile}: ${text}`);
  }
  return value;
}

function isWord(token: Token | undefined, text: string): boolean {
  return token !== undefined && token.kind === "identifier" && token.text === text;
}

// ── the tokenizer ──

function tokenize(source: string): Token[] {
  const tokens: Token[] = [];
  scan({ text: source, at: 0 }, tokens, false);
  return tokens;
}

/** Tokens up to the end, or up to the `}` closing a template's `${` when `inExpression` is set. */
function scan(cursor: Cursor, tokens: Token[], inExpression: boolean): void {
  let depth = 0;
  while (cursor.at < cursor.text.length) {
    const char = cursor.text[cursor.at] ?? "";
    const next = cursor.text[cursor.at + 1] ?? "";
    const previous = tokens[tokens.length - 1];
    if (/\s/.test(char)) {
      cursor.at += 1;
      continue;
    }
    if (char === "/" && next === "/") {
      while (cursor.at < cursor.text.length && !/[\n\r]/.test(cursor.text[cursor.at] ?? "")) {
        cursor.at += 1;
      }
      continue;
    }
    if (char === "/" && next === "*") {
      const close = cursor.text.indexOf("*/", cursor.at + 2);
      if (close === -1) {
        throw new Error(`Unterminated comment in ${sourceFile}`);
      }
      cursor.at = close + 2;
      continue;
    }
    if (char === '"' || char === "'") {
      const text = scanQuoted(cursor, char);
      tokens.push({ kind: "string", text: text });
      continue;
    }
    if (char === "`") {
      scanTemplate(cursor, tokens);
      continue;
    }
    if (char === "/") {
      if (regexAllowed(previous)) {
        tokens.push({ kind: "regex", text: scanRegex(cursor) });
        continue;
      }
      tokens.push({ kind: "punct", text: "/" });
      cursor.at += 1;
      continue;
    }
    if (/[0-9]/.test(char)) {
      tokens.push({ kind: "number", text: scanNumber(cursor) });
      continue;
    }
    if (/[A-Za-z_$]/.test(char)) {
      tokens.push({ kind: "identifier", text: scanWord(cursor) });
      continue;
    }
    if (char === "{") {
      depth += 1;
      tokens.push({ kind: "punct", text: "{" });
      cursor.at += 1;
      continue;
    }
    if (char === "}") {
      if (inExpression && depth === 0) {
        cursor.at += 1;
        return;
      }
      depth -= 1;
      tokens.push({ kind: "punct", text: "}" });
      cursor.at += 1;
      continue;
    }
    tokens.push({ kind: "punct", text: char });
    cursor.at += 1;
  }
}

/** A `/` starts a regex unless what precedes it can end an expression. */
function regexAllowed(previous: Token | undefined): boolean {
  if (previous === undefined) {
    return true;
  }
  if (previous.kind === "identifier") {
    return REGEX_AFTER_WORD.has(previous.text);
  }
  if (previous.kind === "punct") {
    return REGEX_AFTER_PUNCT.has(previous.text);
  }
  return false;
}

function scanQuoted(cursor: Cursor, quote: string): string {
  const start = cursor.at;
  cursor.at += 1;
  while (cursor.at < cursor.text.length) {
    const char = cursor.text[cursor.at] ?? "";
    if (char === "\\") {
      cursor.at += 2;
      continue;
    }
    if (char === quote) {
      cursor.at += 1;
      return cursor.text.slice(start, cursor.at);
    }
    if (char === "\n" || char === "\r") {
      throw new Error(`Unterminated string in ${sourceFile}`);
    }
    cursor.at += 1;
  }
  throw new Error(`Unterminated string in ${sourceFile}`);
}

function scanTemplate(cursor: Cursor, tokens: Token[]): void {
  const start = cursor.at;
  cursor.at += 1;
  while (cursor.at < cursor.text.length) {
    const char = cursor.text[cursor.at] ?? "";
    if (char === "\\") {
      cursor.at += 2;
      continue;
    }
    if (char === "`") {
      cursor.at += 1;
      tokens.push({ kind: "template", text: cursor.text.slice(start, cursor.at) });
      return;
    }
    if (char === "$" && (cursor.text[cursor.at + 1] ?? "") === "{") {
      cursor.at += 2;
      scan(cursor, tokens, true);
      continue;
    }
    cursor.at += 1;
  }
  throw new Error(`Unterminated template in ${sourceFile}`);
}

function scanRegex(cursor: Cursor): string {
  const start = cursor.at;
  cursor.at += 1;
  let inClass = false;
  while (cursor.at < cursor.text.length) {
    const char = cursor.text[cursor.at] ?? "";
    if (char === "\\") {
      cursor.at += 2;
      continue;
    }
    if (char === "[") {
      inClass = true;
      cursor.at += 1;
      continue;
    }
    if (char === "]") {
      inClass = false;
      cursor.at += 1;
      continue;
    }
    if (char === "/" && !inClass) {
      cursor.at += 1;
      while (/[A-Za-z]/.test(cursor.text[cursor.at] ?? "")) {
        cursor.at += 1;
      }
      return cursor.text.slice(start, cursor.at);
    }
    if (char === "\n" || char === "\r") {
      throw new Error(`Unterminated regular expression in ${sourceFile}`);
    }
    cursor.at += 1;
  }
  throw new Error(`Unterminated regular expression in ${sourceFile}`);
}

function scanNumber(cursor: Cursor): string {
  const start = cursor.at;
  while (/[0-9A-Za-z_.]/.test(cursor.text[cursor.at] ?? "")) {
    cursor.at += 1;
  }
  return cursor.text.slice(start, cursor.at);
}

function scanWord(cursor: Cursor): string {
  const start = cursor.at;
  while (/[A-Za-z0-9_$]/.test(cursor.text[cursor.at] ?? "")) {
    cursor.at += 1;
  }
  return cursor.text.slice(start, cursor.at);
}
