// A code block as its author wrote it (M5), for the copy button. The parser reports a code line as
// the indentation it has left, in columns, and the bubble shows that many blanks before the code,
// as every client shows it. The copy button on mobile reads the code with another parser, which
// takes the indentation off each line a character at a time and keeps the tabs left over, so a
// pasted Makefile keeps its recipe tabs. This reads the line the same way from its own bytes.
// Pure: no ArkUI, no kits.
import { utf8Slice } from './markdown-chars';
import type { MdVerbatimLine } from './markdown-line-scanners';

const TAB = 9;

/**
 * One code line without the indentation that is not part of the code: the blanks before the code,
 * less the columns the parser leaves (`indent`). A tab that straddles that place becomes the blanks
 * it stands for; the tabs after it stay as written.
 */
function codeLine(text: Uint8Array, line: MdVerbatimLine): string {
  const marks = line.start + line.afterMarks;
  // Each blank's width follows its column in the written line (a tab ends at the next multiple
  // of four), the quote marks before it included.
  const widths: number[] = [];
  let column = 0;
  for (let off = line.start; off < line.beg; off += 1) {
    const width = off < marks || text[off] !== TAB ? 1 : ((column + 4) & ~3) - column;
    if (off >= marks) {
      widths.push(width);
    }
    column += width;
  }
  let total = 0;
  for (const width of widths) {
    total += width;
  }
  // The quote marks' unmatched blanks go back: the parser took a column for each, the copy
  // rule the code is read by leaves it in the line.
  let toEat = total - line.indent - line.unmatchedMarkBlanks;
  let at = marks;
  for (const width of widths) {
    if (toEat <= 0) {
      break;
    }
    if (width > toEat) {
      return ' '.repeat(width - toEat) + utf8Slice(text, at + 1, line.end);
    }
    toEat -= width;
    at += 1;
  }
  return utf8Slice(text, at, line.end);
}

/**
 * The code of a block, as the copy button copies it: the block's lines joined, the fence line left
 * out and, for indented code, blank lines at either end dropped as well.
 */
export function codeBlockAsWritten(text: Uint8Array, lines: MdVerbatimLine[], isFenced: boolean): string {
  const parts: string[] = [];
  let first = 0;
  let count = lines.length;
  if (isFenced) {
    first = 1;
    count -= 1;
  } else {
    while (count > 0 && lines[first].beg === lines[first].end) {
      first += 1;
      count -= 1;
    }
    while (count > 0 && lines[first + count - 1].beg === lines[first + count - 1].end) {
      count -= 1;
    }
  }
  for (let index = first; index < first + count; index += 1) {
    parts.push(codeLine(text, lines[index]));
    parts.push('\n');
  }
  return parts.join('');
}
