// This file is part of a port of md4c (MIT), made for this app from the sources the mobile
// renderer's parser is built from. md4c's notice follows, as its license asks.
/*
 * MD4C: Markdown parser for C
 * (https://github.com/mity/md4c)
 *
 * Copyright (c) 2016-2026 Martin Mitáš
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 * OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 * IN THE SOFTWARE.
 */
// Mark collection of the markdown parser port (M5): md4c's md_collect_marks with its code span and
// autolink scanners, transcribed from the sources the mobile renderer's parser is built from. A
// mark is a position where an inline construct may start or end; later passes join marks into
// spans. This file also holds the state the inline passes share. Pure: no ArkUI, no kits.
import type { MdRefDefScanner } from './markdown-refdefs';
import type { MdLine } from './markdown-line-scanners';
import {
  asciiEq,
  isAlnumChar,
  isAnyOfChar,
  isBlankChar,
  isControlChar,
  isNewlineChar,
  isPunctChar,
  isUnicodePunctAt,
  isUnicodePunctBefore,
  isUnicodeWhitespaceAt,
  isUnicodeWhitespaceBefore,
  isWhitespaceChar,
} from './markdown-chars';

/* Mark flags (they apply to every mark type). */
export const POTENTIAL_OPENER = 0x01;
export const POTENTIAL_CLOSER = 0x02;
export const OPENER = 0x04;
export const CLOSER = 0x08;
export const RESOLVED = 0x10;
/* Flags of particular mark types (the bits are reused). */
export const EMPH_OC = 0x20;
export const EMPH_MOD3_0 = 0x40;
export const EMPH_MOD3_1 = 0x80;
export const EMPH_MOD3_2 = 0xc0;
export const EMPH_MOD3_MASK = 0xc0;
export const AUTOLINK = 0x20;
export const AUTOLINK_MISSING_MAILTO = 0x40;
export const VALID_PERMISSIVE_AUTOLINK = 0x20;
export const BRACKET_CAN_BE_IMAGE = 0x20;
export const BRACKET_HAS_NESTED = 0x40;

export const BACKSLASH = 92;
export const STAR = 42;
export const UNDERSCORE = 95;
export const BACKTICK = 96;
export const AMPERSAND = 38;
export const SEMICOLON = 59;
export const LESS = 60;
export const GREATER = 62;
export const BRACKET_OPEN = 91;
export const BANG = 33;
export const BRACKET_CLOSE = 93;
export const AT = 64;
export const COLON = 58;
export const DOT = 46;
export const TILDE = 126;
export const PIPE = 124;
export const DUMMY = 68;
export const SPACE = 32;

/** Opener stacks, in the reference's order. */
export const ASTERISK_STACK = 0;
export const UNDERSCORE_STACK = 6;
export const TILDE_STACK_1 = 12;
export const TILDE_STACK_2 = 13;
export const BRACKET_STACK = 14;
export const PIPE_STACK = 16;
export const STACK_COUNT = 20;

export const CODESPAN_MARK_MAXLEN = 32;

/** The characters that can start or end an inline construct. */
export const MARK_CHARS = "\\*_`&;<>[]!~|@:.";

/**
 * One significant position in the text (MD_MARK). For a resolved link or image opener, the two
 * marks after it hold the destination (as a byte range) and the title.
 */
export class Mark {
  beg: number = 0;
  end: number = 0;
  prev: number = -1;
  next: number = -1;
  ch: number = 0;
  flags: number = 0;
  title: Uint8Array | null = null;
}

/** What a link resolves to: a destination range in the document and an optional title. */
export class LinkAttr {
  destBeg: number = 0;
  destEnd: number = 0;
  title: Uint8Array | null = null;
}

/** The reference's list of table cell boundaries (a linked list through `next`). */
export class BoundaryList {
  head: number = -1;
  tail: number = -1;
  count: number = 0;
}

export function filled(length: number, value: number): number[] {
  const out: number[] = [];
  for (let index = 0; index < length; index += 1) {
    out.push(value);
  }
  return out;
}

/** The line holding `off`, or the one after it when `off` falls in a line break. */
export function lookupLine(off: number, lines: MdLine[]): number {
  let lo = 0;
  let hi = lines.length - 1;
  while (lo <= hi) {
    const pivot = Math.floor((lo + hi) / 2);
    const line = lines[pivot];
    if (off < line.beg) {
      if (hi === 0 || lines[hi - 1].end < off) {
        return pivot;
      }
      hi = pivot - 1;
    } else if (off > line.end) {
      lo = pivot + 1;
    } else {
      return pivot;
    }
  }
  return lines.length - 1;
}

/** Interconnects an opener and its closer and marks both as resolved. */
export function resolveRangeIn(marks: Mark[], openerIndex: number, closerIndex: number): void {
  const opener = marks[openerIndex];
  const closer = marks[closerIndex];
  opener.next = closerIndex;
  closer.prev = openerIndex;
  opener.flags |= OPENER | RESOLVED;
  closer.flags |= CLOSER | RESOLVED;
}

/**
 * What every inline pass shares: the document, its reference definitions, the marks collected
 * from one block's lines, and the opener stacks the span analysis works with.
 */
export class MdInlineState {
  readonly text: Uint8Array;
  readonly size: number;
  readonly refs: MdRefDefScanner;
  /** Every mark of the block being read, ending with a dummy past the last line. */
  marks: Mark[] = [];
  /** The top of each opener stack, as a mark index (-1: empty). */
  tops: number[] = filled(STACK_COUNT, -1);
  /** The `[` `]` pairs not yet resolved, chained through the openers' `prev`. */
  unresolvedLinkHead: number = -1;
  unresolvedLinkTail: number = -1;
  /** The pipes that split a table row. */
  boundaries: BoundaryList = new BoundaryList();
  /** Where the latest resolved link and image begin and end (nested pairs are checked against them). */
  lastLinkBeg: number = 0;
  lastLinkEnd: number = 0;
  lastImageBeg: number = 0;
  lastImageEnd: number = 0;
  /** The next pair to look at while resolving brackets (a full reference link skips one). */
  nextIndex: number = -1;
  /** How far the left and right mark cursors got during the last segment scan. */
  leftCursor: number = 0;
  rightCursor: number = 0;
  /** Where the last segment scan ended. */
  segmentEnd: number = 0;

  constructor(text: Uint8Array, refs: MdRefDefScanner) {
    this.text = text;
    this.size = text.length;
    this.refs = refs;
  }

  stackPush(stack: number, markIndex: number): void {
    this.marks[markIndex].next = this.tops[stack];
    this.tops[stack] = markIndex;
  }

  stackPop(stack: number): number {
    const top = this.tops[stack];
    if (top >= 0) {
      this.tops[stack] = this.marks[top].next;
    }
    return top;
  }

  resolveRange(openerIndex: number, closerIndex: number): void {
    resolveRangeIn(this.marks, openerIndex, closerIndex);
  }

  /** Forgets every remembered opener from `openerIndex` on, so no ranges cross. */
  popOpeners(openerIndex: number): void {
    for (let stack = 0; stack < STACK_COUNT; stack += 1) {
      while (this.tops[stack] >= openerIndex) {
        this.stackPop(stack);
      }
    }
  }

  disableMarks(markIndex0: number, markIndex1: number): void {
    for (let index = markIndex0; index < markIndex1; index += 1) {
      this.marks[index].ch = DUMMY;
      this.marks[index].flags = 0;
    }
  }

  emphStack(ch: number, flags: number): number {
    let stack = ch === STAR ? ASTERISK_STACK : UNDERSCORE_STACK;
    if ((flags & EMPH_OC) !== 0) {
      stack += 3;
    }
    return stack + ((flags & EMPH_MOD3_MASK) === EMPH_MOD3_0 ? 0
      : (flags & EMPH_MOD3_MASK) === EMPH_MOD3_1 ? 1 : 2);
  }

  openerStack(markIndex: number): number {
    const mark = this.marks[markIndex];
    if (mark.ch === STAR || mark.ch === UNDERSCORE) {
      return this.emphStack(mark.ch, mark.flags);
    }
    if (mark.ch === TILDE) {
      return mark.end - mark.beg === 1 ? TILDE_STACK_1 : TILDE_STACK_2;
    }
    return PIPE_STACK;
  }
}

/** Collects the marks of one block. */
export class MdMarkCollector {
  private readonly text: Uint8Array;
  private readonly size: number;
  private marks: Mark[] = [];
  /** Where the last autolink scanner stopped. */
  private scanEnd: number = 0;

  private codespanLastClosers: number[] = filled(CODESPAN_MARK_MAXLEN, 0);
  private codespanScannedTillEnd: boolean = false;

  constructor(text: Uint8Array) {
    this.text = text;
    this.size = text.length;
  }

  private addMark(ch: number, beg: number, end: number, flags: number): void {
    const mark = new Mark();
    mark.beg = beg;
    mark.end = end;
    mark.prev = -1;
    mark.next = -1;
    mark.ch = ch;
    mark.flags = flags;
    this.marks.push(mark);
  }

  /** The marks of these lines, ending with a dummy past the last one. */
  collect(lines: MdLine[], tableMode: boolean): Mark[] {
    const text = this.text;
    const size = this.size;
    const nLines = lines.length;
    this.marks = [];
    this.codespanLastClosers = filled(CODESPAN_MARK_MAXLEN, 0);
    this.codespanScannedTillEnd = false;
    for (let lineIndex = 0; lineIndex < nLines; lineIndex += 1) {
      let line = lines[lineIndex];
      let off = line.beg;
      while (true) {
        while (off < line.end && text[off] !== 0 && !isAnyOfChar(text[off], MARK_CHARS)) {
          off += 1;
        }
        if (off >= line.end) {
          break;
        }
        const ch = text[off];

        // A backslash escape (it may reach over the line break, as a hard break).
        if (ch === BACKSLASH && off + 1 < size && (isPunctChar(text[off + 1]) || isNewlineChar(text[off + 1]))) {
          // A hard break cannot be on the last line of the block.
          if (!isNewlineChar(text[off + 1]) || lineIndex + 1 < nLines) {
            this.addMark(ch, off, off + 2, RESOLVED);
          }
          off += 2;
          continue;
        }

        // A possible emphasis start or end.
        if (ch === STAR || ch === UNDERSCORE) {
          let tmp = off + 1;
          while (tmp < line.end && text[tmp] === ch) {
            tmp += 1;
          }
          // What precedes and what follows: 0 whitespace, 1 punctuation, 2 another character.
          let leftLevel = 0;
          if (!(off === line.beg || isUnicodeWhitespaceBefore(text, off))) {
            leftLevel = isUnicodePunctBefore(text, off) ? 1 : 2;
          }
          let rightLevel = 0;
          if (!(tmp === line.end || isUnicodeWhitespaceAt(text, tmp))) {
            rightLevel = isUnicodePunctAt(text, tmp) ? 1 : 2;
          }
          // An underscore inside a word has no special meaning.
          if (ch === UNDERSCORE && leftLevel === 2 && rightLevel === 2) {
            leftLevel = 0;
            rightLevel = 0;
          }
          if (leftLevel !== 0 || rightLevel !== 0) {
            let flags = 0;
            if (leftLevel > 0 && leftLevel >= rightLevel) {
              flags |= POTENTIAL_CLOSER;
            }
            if (rightLevel > 0 && rightLevel >= leftLevel) {
              flags |= POTENTIAL_OPENER;
            }
            if (flags === (POTENTIAL_OPENER | POTENTIAL_CLOSER)) {
              flags |= EMPH_OC;
            }
            // The run's length modulo three, for "the rule of three".
            flags |= (tmp - off) % 3 === 0 ? EMPH_MOD3_0 : (tmp - off) % 3 === 1 ? EMPH_MOD3_1 : EMPH_MOD3_2;
            this.addMark(ch, off, tmp, flags);
            // Resolving may have to split the run into separate starts and ends: keep room for that.
            off += 1;
            while (off < tmp) {
              this.addMark(DUMMY, off, off, 0);
              off += 1;
            }
            continue;
          }
          off = tmp;
          continue;
        }

        // A possible code span.
        if (ch === BACKTICK) {
          const opener = new Mark();
          const closer = new Mark();
          if (this.isCodeSpan(lines, lineIndex, off, opener, closer)) {
            this.addMark(opener.ch, opener.beg, opener.end, opener.flags);
            this.addMark(closer.ch, closer.beg, closer.end, closer.flags);
            resolveRangeIn(this.marks, this.marks.length - 2, this.marks.length - 1);
            off = closer.end;
            // The span may have run over several lines.
            if (off > line.end) {
              lineIndex = lookupLine(off, lines);
              line = lines[lineIndex];
            }
            continue;
          }
          off = opener.end;
          continue;
        }

        // A possible entity start, and its end (only right after a start).
        if (ch === AMPERSAND) {
          this.addMark(ch, off, off + 1, POTENTIAL_OPENER);
          off += 1;
          continue;
        }
        if (ch === SEMICOLON) {
          if (this.marks.length > 0 && this.marks[this.marks.length - 1].ch === AMPERSAND) {
            this.addMark(ch, off, off + 1, POTENTIAL_CLOSER);
          }
          off += 1;
          continue;
        }

        // A possible autolink in angle brackets.
        if (ch === LESS) {
          const kind = this.isAutolink(off, lines[nLines - 1].end);
          const autolinkEnd = this.scanEnd;
          if (kind !== 0) {
            let flags = RESOLVED | AUTOLINK;
            if (kind === 2) {
              flags |= AUTOLINK_MISSING_MAILTO;
            }
            this.addMark(LESS, off, off + 1, OPENER | flags);
            this.addMark(GREATER, autolinkEnd - 1, autolinkEnd, CLOSER | flags);
            this.marks[this.marks.length - 2].next = this.marks.length - 1;
            this.marks[this.marks.length - 1].prev = this.marks.length - 2;
            off = autolinkEnd;
            continue;
          }
          off += 1;
          continue;
        }

        // A possible link or image label.
        if (ch === BRACKET_OPEN || (ch === BANG && off + 1 < line.end && text[off + 1] === BRACKET_OPEN)) {
          if (ch === BANG) {
            this.addMark(ch, off + 1, off + 2, POTENTIAL_OPENER | BRACKET_CAN_BE_IMAGE);
            off += 2;
          } else {
            this.addMark(ch, off, off + 1, POTENTIAL_OPENER);
            off += 1;
          }
          // Two dummies, to have room for the link's destination and title.
          this.addMark(DUMMY, off, off, 0);
          this.addMark(DUMMY, off, off, 0);
          continue;
        }
        if (ch === BRACKET_CLOSE) {
          this.addMark(ch, off, off + 1, POTENTIAL_CLOSER);
          off += 1;
          continue;
        }

        // A possible bare e-mail address.
        if (ch === AT) {
          if (line.beg + 1 <= off && isAlnumChar(text[off - 1]) && off + 3 < line.end
            && isAlnumChar(text[off + 1])) {
            this.addMark(ch, off, off + 1, POTENTIAL_OPENER);
            this.addMark(DUMMY, line.beg, line.end, 0);
          }
          off += 1;
          continue;
        }

        // A possible bare URL (http://, https:// or ftp://).
        if (ch === COLON) {
          const schemes: string[] = ['http', 'https', 'ftp'];
          for (const scheme of schemes) {
            if (line.beg + scheme.length <= off && asciiEq(text, off - scheme.length, scheme, scheme.length)
              && off + 3 < line.end && asciiEq(text, off + 1, '//', 2)) {
              this.addMark(ch, off - scheme.length, off + 3, POTENTIAL_OPENER);
              this.addMark(DUMMY, line.beg, line.end, 0);
              off += 3;
              break;
            }
          }
          off += 1;
          continue;
        }

        // A possible bare address starting with "www.".
        if (ch === DOT) {
          if (line.beg + 3 <= off && asciiEq(text, off - 3, 'www', 3)
            && (off - 3 === line.beg || isUnicodeWhitespaceBefore(text, off - 3)
              || isUnicodePunctBefore(text, off - 3))) {
            this.addMark(ch, off - 3, off + 1, POTENTIAL_OPENER);
            this.addMark(DUMMY, line.beg, line.end, 0);
            off += 1;
            continue;
          }
          off += 1;
          continue;
        }

        // Pipes: cell boundaries in a table row, a spoiler when they come in pairs.
        if (ch === PIPE) {
          let tmp = off + 1;
          while (tmp < line.end && text[tmp] === ch) {
            tmp += 1;
          }
          if (tableMode || tmp - off === 2) {
            this.addMark(ch, off, tmp, POTENTIAL_OPENER | POTENTIAL_CLOSER);
          }
          off = tmp;
          continue;
        }

        // A possible strikethrough start or end.
        if (ch === TILDE) {
          let tmp = off + 1;
          while (tmp < line.end && text[tmp] === ch) {
            tmp += 1;
          }
          if (tmp - off <= 2) {
            // The usual left/right-flanking rules.
            let flags = POTENTIAL_OPENER | POTENTIAL_CLOSER;
            if (off > line.beg && !isUnicodeWhitespaceBefore(text, off) && !isUnicodePunctBefore(text, off)) {
              flags &= ~POTENTIAL_OPENER;
            }
            if (tmp < line.end && !isUnicodeWhitespaceAt(text, tmp) && !isUnicodePunctAt(text, tmp)) {
              flags &= ~POTENTIAL_CLOSER;
            }
            if (flags !== 0) {
              this.addMark(ch, off, tmp, flags);
            }
          }
          off = tmp;
          continue;
        }

        // A run of whitespace other than one space becomes one space.
        if (isWhitespaceChar(ch)) {
          let tmp = off + 1;
          while (tmp < line.end && isWhitespaceChar(text[tmp])) {
            tmp += 1;
          }
          if (tmp - off > 1 || ch !== SPACE) {
            this.addMark(ch, off, tmp, RESOLVED);
          }
          off = tmp;
          continue;
        }

        // A NUL character.
        if (ch === 0) {
          this.addMark(ch, off, off + 1, RESOLVED);
          off += 1;
          continue;
        }

        off += 1;
      }
    }

    // A dummy at the end simplifies the rendering loop.
    this.addMark(127, size, size, RESOLVED);
    return this.marks;
  }

  /** A `<scheme:…>` URI or `<name@host>` address at `beg`; 0 for neither, 2 for the address. */
  private isAutolink(beg: number, maxEnd: number): number {
    const text = this.text;
    let off = beg + 1;
    // A URI: a scheme of at least two characters, then anything but space and angle brackets.
    if (off < maxEnd && isAlnumChar(text[off])) {
      off += 1;
      let scheme = false;
      while (true) {
        if (off >= maxEnd || off - beg > 32) {
          break;
        }
        if (text[off] === COLON && off - beg >= 3) {
          scheme = true;
          break;
        }
        if (!isAlnumChar(text[off]) && text[off] !== 43 && text[off] !== 45 && text[off] !== DOT) {
          break;
        }
        off += 1;
      }
      if (scheme) {
        while (off < maxEnd && text[off] !== GREATER) {
          if (isWhitespaceChar(text[off]) || isControlChar(text[off]) || text[off] === LESS) {
            break;
          }
          off += 1;
        }
        if (off < maxEnd && text[off] === GREATER) {
          this.scanEnd = off + 1;
          return 1;
        }
      }
    }
    // An address: `user@labels`, each label 1 to 63 letters, digits or inner hyphens.
    off = beg + 1;
    while (off < maxEnd && (isAlnumChar(text[off]) || isAnyOfChar(text[off], ".!#$%&'*+/=?^_`{|}~-"))) {
      off += 1;
    }
    if (off <= beg + 1) {
      return 0;
    }
    if (off >= maxEnd || text[off] !== AT) {
      return 0;
    }
    off += 1;
    let labelLength = 0;
    while (off < maxEnd) {
      if (isAlnumChar(text[off])) {
        labelLength += 1;
      } else if (text[off] === 45 && labelLength > 0) {
        labelLength += 1;
      } else if (text[off] === DOT && labelLength > 0 && text[off - 1] !== 45) {
        labelLength = 0;
      } else {
        break;
      }
      if (labelLength > 63) {
        return 0;
      }
      off += 1;
    }
    if (labelLength <= 0 || off >= maxEnd || text[off] !== GREATER || text[off - 1] === 45) {
      return 0;
    }
    this.scanEnd = off + 1;
    return 2;
  }

  /**
   * The code span opening at `beg`, if a run of as many backticks closes it in the block; the
   * lines are read from `from`, the one the backtick is on.
   */
  private isCodeSpan(lines: MdLine[], from: number, beg: number, opener: Mark, closer: Mark): boolean {
    const text = this.text;
    const size = this.size;
    const lastClosers = this.codespanLastClosers;
    const nLines = lines.length - from;
    let lineEnd = lines[from].end;
    const openerBeg = beg;
    let openerEnd = beg;
    while (openerEnd < lineEnd && text[openerEnd] === BACKTICK) {
      openerEnd += 1;
    }
    const hasSpaceAfterOpener = openerEnd < lineEnd && text[openerEnd] === SPACE;
    const hasEolAfterOpener = openerEnd === lineEnd;
    // The caller needs the opening mark's end even when this fails.
    opener.end = openerEnd;
    const markLength = openerEnd - openerBeg;
    if (markLength > CODESPAN_MARK_MAXLEN) {
      return false;
    }
    // A closer of this length is known to be absent: scanning again would find nothing.
    if (lastClosers[markLength - 1] >= lines[lines.length - 1].end
      || (this.codespanScannedTillEnd && lastClosers[markLength - 1] < openerEnd)) {
      return false;
    }
    let closerBeg = openerEnd;
    let closerEnd = openerEnd;
    let hasSpaceBeforeCloser = false;
    let hasEolBeforeCloser = false;
    let hasOnlySpace = true;
    let lineIndex = 0;
    while (true) {
      while (closerBeg < lineEnd && text[closerBeg] !== BACKTICK) {
        if (text[closerBeg] !== SPACE) {
          hasOnlySpace = false;
        }
        closerBeg += 1;
      }
      closerEnd = closerBeg;
      while (closerEnd < lineEnd && text[closerEnd] === BACKTICK) {
        closerEnd += 1;
      }
      if (closerEnd - closerBeg === markLength) {
        hasSpaceBeforeCloser = closerBeg > lines[from + lineIndex].beg && text[closerBeg - 1] === SPACE;
        hasEolBeforeCloser = closerBeg === lines[from + lineIndex].beg;
        break;
      }
      if (closerEnd - closerBeg > 0) {
        // A run of another length: remember it as a potential closer of its own.
        hasOnlySpace = false;
        if (closerEnd - closerBeg < CODESPAN_MARK_MAXLEN
          && closerBeg > lastClosers[closerEnd - closerBeg - 1]) {
          lastClosers[closerEnd - closerBeg - 1] = closerBeg;
        }
      }
      if (closerEnd >= lineEnd) {
        lineIndex += 1;
        if (lineIndex >= nLines) {
          this.codespanScannedTillEnd = true;
          return false;
        }
        lineEnd = lines[from + lineIndex].end;
        closerBeg = lines[from + lineIndex].beg;
      } else {
        closerBeg = closerEnd;
      }
    }
    // A space or line break on both sides (in a span that is not all spaces) belongs to the marks.
    if (!hasOnlySpace && (hasSpaceAfterOpener || hasEolAfterOpener) && (hasSpaceBeforeCloser || hasEolBeforeCloser)) {
      if (hasSpaceAfterOpener) {
        openerEnd += 1;
      } else {
        openerEnd = lines[from + 1].beg;
      }
      if (hasSpaceBeforeCloser) {
        closerBeg -= 1;
      } else {
        // Back to the end of the previous line, after its trailing blanks.
        closerBeg = lines[from + lineIndex - 1].end;
        while (closerBeg < size && isBlankChar(text[closerBeg])) {
          closerBeg += 1;
        }
      }
    }
    opener.ch = BACKTICK;
    opener.beg = openerBeg;
    opener.end = openerEnd;
    opener.flags = POTENTIAL_OPENER;
    closer.ch = BACKTICK;
    closer.beg = closerBeg;
    closer.end = closerEnd;
    closer.flags = POTENTIAL_CLOSER;
    return true;
  }
}
