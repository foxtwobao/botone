// Link reference definitions for the markdown parser port (M5): md4c's label, destination and
// title recognizers and its definition lookup, transcribed from the sources the mobile renderer's
// parser is built from. A definition is `[label]: destination "title"` at the top of a paragraph;
// the first definition of a label wins and labels compare case-insensitively. Pure: no ArkUI, no
// kits.
import { FoldInfo } from './markdown-types';
import type { MdLine } from './markdown-line-scanners';
import {
  decodeUtf8,
  foldInfo,
  isControlChar,
  isNewlineChar,
  isPunctChar,
  isUnicodeWhitespace,
  isWhitespaceChar,
  utf8CharSize,
} from './markdown-chars';

/** A link reference definition ([label]: destination "title"). */
const GREATER = 62;
const SPACE = 32;

export class MdRefDef {
  key: string = '';
  title: Uint8Array = new Uint8Array(0);
  labelSize: number = 0;
  titleSize: number = 0;
  destBeg: number = 0;
  destEnd: number = 0;
}
/**
 * The label of a link reference as its lookup compares it: case folded, with runs of whitespace
 * read as one space and none at either end.
 */
function labelKey(text: Uint8Array): string {
  const info: FoldInfo = new FoldInfo();
  const parts: number[] = [];
  let off = 0;
  const end = text.length;
  let pendingSpace = false;
  while (off < end) {
    const size = utf8CharSize(text, off, end - off);
    const codepoint = decodeUtf8(text, off, end - off);
    if (isUnicodeWhitespace(codepoint) || isNewlineChar(text[off])) {
      pendingSpace = parts.length > 0;
    } else {
      if (pendingSpace) {
        parts.push(SPACE);
        pendingSpace = false;
      }
      foldInfo(codepoint, info);
      for (let index = 0; index < info.n; index += 1) {
        parts.push(info.codepoints[index]);
      }
    }
    off += size;
  }
  return parts.join(',');
}

/** The bytes of several lines joined, each line break replaced by `joiner`. */
export function mergeLines(
  text: Uint8Array,
  beg: number,
  end: number,
  lines: MdLine[],
  from: number,
  joiner: number,
): Uint8Array {
  const out: number[] = [];
  let lineIndex = from;
  let off = beg;
  while (true) {
    const line = lineIndex < lines.length ? lines[lineIndex] : lines[lines.length - 1];
    const lineEnd = Math.min(line.end, end);
    while (off < lineEnd) {
      out.push(text[off]);
      off += 1;
    }
    if (off >= end) {
      break;
    }
    out.push(joiner);
    lineIndex += 1;
    off = lines[lineIndex].beg;
  }
  return Uint8Array.from(out);
}
/** The definitions of one document. */
export class MdRefDefScanner {
  readonly text: Uint8Array;
  readonly size: number;
  /** Definitions by their folded label. */
  readonly refDefs: Map<string, MdRefDef> = new Map<string, MdRefDef>();
  /** A budget against documents made of nothing but reference links (the reference's guard). */
  private maxRefDefOutput: number;

  constructor(text: Uint8Array) {
    this.text = text;
    this.size = text.length;
    this.maxRefDefOutput = 16 * Math.min(this.size, 65536);
  }

  /**
   * A `[label]` at `beg`: where it ends, where its contents are and on which lines. Returns false
   * for anything else; `result` carries [end, contentsBeg, contentsEnd, begLine, endLine].
   */
  private isLinkLabel(lines: MdLine[], lineIndex: number, nLines: number, beg: number,
    result: number[]): boolean {
    const text = this.text;
    let off = beg;
    let contentsBeg = 0;
    let contentsEnd = 0;
    let len = 0;
    let begLine = lineIndex;
    if (text[off] !== 91) {
      return false;
    }
    off += 1;
    while (true) {
      const lineEnd = lines[lineIndex].end;
      while (off < lineEnd) {
        if (text[off] === 92 && off + 1 < this.size && (isPunctChar(text[off + 1])
          || isNewlineChar(text[off + 1]))) {
          if (contentsEnd === 0) {
            contentsBeg = off;
            begLine = lineIndex;
          }
          contentsEnd = off + 2;
          off += 2;
        } else if (text[off] === 91) {
          return false;
        } else if (text[off] === 93) {
          if (contentsBeg < contentsEnd) {
            result[0] = off + 1;
            result[1] = contentsBeg;
            result[2] = contentsEnd;
            result[3] = begLine;
            result[4] = lineIndex;
            return true;
          }
          // A label needs some non-blank content.
          return false;
        } else {
          const size = utf8CharSize(text, off, this.size - off);
          if (!isUnicodeWhitespace(decodeUtf8(text, off, this.size - off))) {
            if (contentsEnd === 0) {
              contentsBeg = off;
              begLine = lineIndex;
            }
            contentsEnd = off + size;
          }
          off += size;
        }
        len += 1;
        if (len > 999) {
          return false;
        }
      }
      lineIndex += 1;
      len += 1;
      if (lineIndex < nLines) {
        off = lines[lineIndex].beg;
      } else {
        break;
      }
    }
    return false;
  }
  /** A link destination in `<…>` or bare; `result` carries [end, contentsBeg, contentsEnd]. */
  private isLinkDestination(beg: number, maxEnd: number, result: number[]): boolean {
    const text = this.text;
    let off = beg;
    if (text[beg] === 60) {
      off += 1;
      while (off < maxEnd) {
        if (text[off] === 92 && off + 1 < maxEnd && isPunctChar(text[off + 1])) {
          off += 2;
          continue;
        }
        if (isNewlineChar(text[off]) || text[off] === 60) {
          return false;
        }
        if (text[off] === GREATER) {
          result[0] = off + 1;
          result[1] = beg + 1;
          result[2] = off;
          return true;
        }
        off += 1;
      }
      return false;
    }
    let parenthesisLevel = 0;
    while (off < maxEnd) {
      if (text[off] === 92 && off + 1 < maxEnd && isPunctChar(text[off + 1])) {
        off += 2;
        continue;
      }
      if (isWhitespaceChar(text[off]) || isControlChar(text[off])) {
        break;
      }
      // Balanced unescaped parentheses are allowed, up to a nesting level of 32.
      if (text[off] === 40) {
        parenthesisLevel += 1;
        if (parenthesisLevel > 32) {
          return false;
        }
      } else if (text[off] === 41) {
        if (parenthesisLevel === 0) {
          break;
        }
        parenthesisLevel -= 1;
      }
      off += 1;
    }
    if (parenthesisLevel !== 0 || off === beg) {
      return false;
    }
    result[0] = off;
    result[1] = beg;
    result[2] = off;
    return true;
  }
  /**
   * A link title after a blank (and at most one line break): `result` carries
   * [end, contentsBeg, contentsEnd, begLine, endLine], the lines counted from the block's first.
   */
  private isLinkTitle(lines: MdLine[], from: number, nLines: number, beg: number,
    result: number[]): boolean {
    const text = this.text;
    let off = beg;
    let lineIndex = from;
    while (off < lines[lineIndex].end && isWhitespaceChar(text[off])) {
      off += 1;
    }
    if (off >= lines[lineIndex].end) {
      lineIndex += 1;
      if (lineIndex >= nLines) {
        return false;
      }
      off = lines[lineIndex].beg;
    }
    if (off === beg) {
      return false;
    }
    const begLine = lineIndex;
    const opener = text[off];
    let closer = 0;
    if (opener === 34 || opener === 39) {
      closer = opener;
    } else if (opener === 40) {
      closer = 41;
    } else {
      return false;
    }
    off += 1;
    const contentsBeg = off;
    while (lineIndex < nLines) {
      const lineEnd = lines[lineIndex].end;
      while (off < lineEnd) {
        if (text[off] === 92 && off + 1 < this.size && (isPunctChar(text[off + 1])
          || isNewlineChar(text[off + 1]))) {
          off += 1;
        } else if (text[off] === closer) {
          result[0] = off + 1;
          result[1] = contentsBeg;
          result[2] = off;
          result[3] = begLine;
          result[4] = lineIndex;
          return true;
        } else if (closer === 41 && text[off] === 40) {
          // A title in parentheses cannot hold an unescaped parenthesis.
          return false;
        }
        off += 1;
      }
      lineIndex += 1;
    }
    return false;
  }
  /** How many lines a reference definition takes at `from`, or 0 when it is none. */
  isLinkReferenceDefinition(lines: MdLine[], from: number): number {
    const nLines = lines.length;
    const label: number[] = [0, 0, 0, 0, 0];
    const dest: number[] = [0, 0, 0];
    const title: number[] = [0, 0, 0, 0, 0];
    let lineIndex = from;
    if (!this.isLinkLabel(lines, lineIndex, nLines, lines[from].beg, label)) {
      return 0;
    }
    const labelIsMultiline = label[3] !== label[4];
    const labelBegLine = label[3];
    let off = label[0];
    lineIndex = label[4];
    if (off >= lines[lineIndex].end || this.text[off] !== 58) {
      return 0;
    }
    off += 1;
    while (off < lines[lineIndex].end && isWhitespaceChar(this.text[off])) {
      off += 1;
    }
    if (off >= lines[lineIndex].end) {
      lineIndex += 1;
      if (lineIndex >= nLines) {
        return 0;
      }
      off = lines[lineIndex].beg;
    }
    if (!this.isLinkDestination(off, lines[lineIndex].end, dest)) {
      return 0;
    }
    off = dest[0];
    // A title counts as one only when nothing more follows on its last line. The line indexes the
    // title scanner reports count from the destination's line.
    let titleIsMultiline = false;
    let titleBeg = off;
    let titleEnd = off;
    let titleBegLine = 0;
    if (this.isLinkTitle(lines, lineIndex, nLines, off, title) && title[0] >= lines[title[4]].end) {
      titleIsMultiline = title[4] !== title[3];
      titleBegLine = title[3];
      lineIndex = title[4];
      off = title[0];
      titleBeg = title[1];
      titleEnd = title[2];
    }
    // Nothing more can follow on the last line.
    if (off < lines[lineIndex].end) {
      return 0;
    }
    const def = new MdRefDef();
    const labelBytes = labelIsMultiline
      ? mergeLines(this.text, label[1], label[2], lines, labelBegLine, SPACE)
      : this.text.subarray(label[1], label[2]);
    def.key = labelKey(labelBytes);
    def.labelSize = labelBytes.length;
    def.destBeg = dest[1];
    def.destEnd = dest[2];
    def.title = titleIsMultiline
      ? mergeLines(this.text, titleBeg, titleEnd, lines, titleBegLine, 10)
      : this.text.subarray(titleBeg, titleEnd);
    def.titleSize = def.title.length;
    // The first definition of a label wins.
    if (!this.refDefs.has(def.key)) {
      this.refDefs.set(def.key, def);
    }
    return lineIndex + 1 - from;
  }
  /**
   * The definition a link label names, or null. Each use spends part of a budget, so a document
   * cannot turn a few definitions into unlimited links.
   */
  lookupRefDef(labelBytes: Uint8Array): MdRefDef | null {
    if (this.maxRefDefOutput === 0) {
      return null;
    }
    const def = this.refDefs.get(labelKey(labelBytes));
    if (def === undefined) {
      return null;
    }
    const outputSizeEstimation = def.labelSize + def.titleSize + def.destEnd - def.destBeg;
    if (outputSizeEstimation < this.maxRefDefOutput) {
      this.maxRefDefOutput -= outputSizeEstimation;
      return def;
    }
    this.maxRefDefOutput = 0;
    return null;
  }
}
