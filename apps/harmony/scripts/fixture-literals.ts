// How embed-fixtures.ts writes a fixture JSON as ArkTS: several string literals joined with `+`.

/**
 * The JSON in pieces, each escaping to at most `maxLiteralLength` characters when written as a
 * string literal, so no line of the generated file grows with a fixture. The loop steps by code
 * point, so a literal never ends between the two halves of a surrogate pair.
 */
export function fixtureLiterals(json: string, maxLiteralLength = 2000): string[] {
  const out: string[] = [];
  let current = "";
  let length = 0;
  for (const char of json) {
    const size = JSON.stringify(char).length - 2;
    if (length + size > maxLiteralLength) {
      out.push(current);
      current = "";
      length = 0;
    }
    current += char;
    length += size;
  }
  if (current.length > 0) {
    out.push(current);
  }
  return out;
}
