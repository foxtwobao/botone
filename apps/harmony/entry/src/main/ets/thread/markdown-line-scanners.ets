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
// Line scanners of the markdown parser port (M5): md4c's recognizers for the things one line can
// start (a thematic break, a heading, a code fence, an HTML block, a list marker, a table
// underline), transcribed from the sources the mobile renderer's parser is built from, with the
// record types the block pass hands around. Each scanner leaves where it stopped in `scanEnd` (the
// C functions' `p_end`), on failure too where the reference relies on that. Pure: no ArkUI, no kits.
import {
  asciiCaseEq,
  asciiEq,
  isAlnumChar,
  isAlphaChar,
  isAnyOfChar,
  isBlankChar,
  isDigitChar,
  isNewlineChar,
  isWhitespaceChar,
} from './markdown-chars';

/** Line kinds (MD_LINETYPE). */
export const LINE_BLANK = 0;
export const LINE_HR = 1;
export const LINE_ATXHEADER = 2;
export const LINE_SETEXTUNDERLINE = 4;
export const LINE_INDENTEDCODE = 5;
export const LINE_FENCEDCODE = 6;
export const LINE_HTML = 7;
export const LINE_TEXT = 8;
export const LINE_TABLE = 9;
export const LINE_TABLEUNDERLINE = 10;

/** Block kinds, named as the tree names them. */
export const BLOCK_UL = 'ul';
export const BLOCK_OL = 'ol';
export const BLOCK_LI = 'li';
export const BLOCK_QUOTE = 'quote';
export const BLOCK_ADMONITION = 'admonition';
export const BLOCK_HR = 'hr';
export const BLOCK_H = 'h';
export const BLOCK_CODE = 'codeblock';
export const BLOCK_HTML = 'html';
export const BLOCK_P = 'p';
export const BLOCK_TABLE = 'table';

export const BLOCK_OPENER = 0x01;
export const BLOCK_CLOSER = 0x02;
export const BLOCK_LOOSE_LIST = 0x04;
export const BLOCK_SETEXT_HEADER = 0x08;

export const ADMONITION_TAGS: string[] = ['note', 'tip', 'important', 'warning', 'caution'];

/** One text line of a leaf block, as byte offsets into the document. */
export class MdLine {
  beg: number = 0;
  end: number = 0;
}

/** One line of a code or HTML block: the same offsets, plus the indentation to restore. */
export class MdVerbatimLine {
  beg: number = 0;
  end: number = 0;
  indent: number = 0;
  /** Where the line starts in the document, and where its content begins after the `>` marks. */
  start: number = 0;
  afterMarks: number = 0;
}

/** What one line of the document is (MD_LINE_ANALYSIS). */
export class MdLineAnalysis {
  type: number = LINE_BLANK;
  data: number = 0;
  enforceNewBlock: boolean = false;
  beg: number = 0;
  end: number = 0;
  indent: number = 0;
  start: number = 0;
  afterMarks: number = 0;
}

/** An open container (a block quote, or a list and the item being read). */
export class MdContainer {
  ch: number = 0;
  isLoose: boolean = false;
  isTask: boolean = false;
  isAdmonition: boolean = false;
  admonitionType: number = 0;
  start: number = 0;
  markIndent: number = 0;
  contentsIndent: number = 0;
  /** Where the list's opener sits in the block list, so a later blank line can mark it loose. */
  blockIndex: number = 0;
  taskMarkOff: number = 0;

  /** An independent copy of the mark, as the reference keeps when it opens the container. */
  copy(): MdContainer {
    const out = new MdContainer();
    out.ch = this.ch;
    out.isLoose = this.isLoose;
    out.isTask = this.isTask;
    out.isAdmonition = this.isAdmonition;
    out.admonitionType = this.admonitionType;
    out.start = this.start;
    out.markIndent = this.markIndent;
    out.contentsIndent = this.contentsIndent;
    out.blockIndex = this.blockIndex;
    out.taskMarkOff = this.taskMarkOff;
    return out;
  }
}

/**
 * One entry of the flat block list: a container opener or closer (flags say which) or a leaf
 * block with its lines. `data` and `nLines` carry what each kind needs, as in the reference:
 * heading level, fenced-or-indented, the task mark and its offset, the list's start number, the
 * table's column count.
 */
export class MdBlock {
  type: string = '';
  flags: number = 0;
  data: number = 0;
  nLines: number = 0;
  lines: MdLine[] = [];
  vlines: MdVerbatimLine[] = [];
}
export const CODE_INDENT = 4;
export const GREATER = 62;
const SPACE = 32;

/** Tags that start an HTML block of type 1 (ended by their own closing tag). */
const HTML_BLOCK_TYPE_1: string[] = ['pre', 'script', 'style', 'textarea'];

/** Tags that start an HTML block of type 6 (ended by a blank line), by first letter. */
const HTML_BLOCK_TYPE_6: string[][] = [
  ['address', 'article', 'aside'],
  ['base', 'basefont', 'blockquote', 'body'],
  ['caption', 'center', 'col', 'colgroup'],
  ['dd', 'details', 'dialog', 'dir', 'div', 'dl', 'dt'],
  [],
  ['fieldset', 'figcaption', 'figure', 'footer', 'form', 'frame', 'frameset'],
  [],
  ['h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'head', 'header', 'hr', 'html'],
  ['iframe'],
  [],
  [],
  ['legend', 'li', 'link'],
  ['main', 'menu', 'menuitem'],
  ['nav', 'noframes'],
  ['ol', 'optgroup', 'option'],
  ['p', 'param'],
  [],
  [],
  ['search', 'section', 'summary'],
  ['table', 'tbody', 'td', 'tfoot', 'th', 'thead', 'title', 'tr', 'track'],
  ['ul'],
  ['video'],
  [],
  [],
  [],
];

/** The scanners, over one document. */
export class MdLineScanner {
  readonly text: Uint8Array;
  readonly size: number;
  /** The opening fence's length, for recognizing its closing fence. */
  codeFenceLength: number = 0;
  /** The HTML block being read (1 to 7), or 0 outside one. */
  htmlBlockType: number = 0;
  /** Where the last scanner stopped. */
  scanEnd: number = 0;
  /** The last scanner's second result (a heading level or a table's column count). */
  scanLevel: number = 0;

  constructor(text: Uint8Array) {
    this.text = text;
    this.size = text.length;
  }

  /** Leading blanks from `off`, with a tab advancing to the next multiple of four. */
  /** Called by the block pass for each run of blanks after a mark. */
  lineIndentation(totalIndent: number, off: number): number {
    const text = this.text;
    let indent = totalIndent;
    let end = off;
    while (end < this.size && isBlankChar(text[end])) {
      if (text[end] === 9) {
        indent = (indent + 4) & ~3;
      } else {
        indent += 1;
      }
      end += 1;
    }
    this.scanEnd = end;
    return indent - totalIndent;
  }

  /* ------------------------------- line analysis ------------------------------- */

  /** A line of only `-`, `_` or `*` (three or more, spaces between). */
  isHrLine(beg: number): boolean {
    const text = this.text;
    const mark = text[beg];
    if (mark !== 45 && mark !== 95 && mark !== 42) {
      return false;
    }
    let off = beg + 1;
    let n = 1;
    while (off < this.size && (text[off] === mark || text[off] === SPACE || text[off] === 9)) {
      if (text[off] === mark) {
        n += 1;
      }
      off += 1;
    }
    if (n < 3 || (off < this.size && !isNewlineChar(text[off]))) {
      // Where the scan stopped: nothing before it can be a break either.
      this.scanEnd = off;
      return false;
    }
    this.scanEnd = off;
    return true;
  }

  /** `#` one to six times, a blank, then the heading text. */
  isAtxHeaderLine(beg: number): boolean {
    const text = this.text;
    let off = beg + 1;
    while (off < this.size && text[off] === 35 && off - beg < 7) {
      off += 1;
    }
    const n = off - beg;
    if (n > 6) {
      return false;
    }
    if (off < this.size && !isBlankChar(text[off]) && !isNewlineChar(text[off])) {
      return false;
    }
    while (off < this.size && isBlankChar(text[off])) {
      off += 1;
    }
    this.scanEnd = off;
    this.scanLevel = n;
    return true;
  }

  /** A line of `=` (level one) or `-` (level two), optional trailing blanks. */
  isSetextUnderline(beg: number): boolean {
    const text = this.text;
    let off = beg + 1;
    while (off < this.size && text[off] === text[beg]) {
      off += 1;
    }
    while (off < this.size && isBlankChar(text[off])) {
      off += 1;
    }
    if (off < this.size && !isNewlineChar(text[off])) {
      return false;
    }
    this.scanEnd = off;
    this.scanLevel = text[beg] === 61 ? 1 : 2;
    return true;
  }

  /** `---`, `:--`, `--:` or `:--:` cells separated by pipes; sets the column count. */
  isTableUnderline(beg: number): boolean {
    const text = this.text;
    let off = beg;
    let foundPipe = false;
    let colCount = 0;
    if (off < this.size && text[off] === 124) {
      foundPipe = true;
      off += 1;
      while (off < this.size && isWhitespaceChar(text[off])) {
        off += 1;
      }
    }
    while (true) {
      let delimited = false;
      if (off < this.size && text[off] === 58) {
        off += 1;
      }
      if (off >= this.size || text[off] !== 45) {
        return false;
      }
      while (off < this.size && text[off] === 45) {
        off += 1;
      }
      if (off < this.size && text[off] === 58) {
        off += 1;
      }
      colCount += 1;
      while (off < this.size && isWhitespaceChar(text[off])) {
        off += 1;
      }
      if (off < this.size && text[off] === 124) {
        delimited = true;
        foundPipe = true;
        off += 1;
        while (off < this.size && isWhitespaceChar(text[off])) {
          off += 1;
        }
      }
      if (off >= this.size || isNewlineChar(text[off])) {
        break;
      }
      if (!delimited) {
        return false;
      }
    }
    if (!foundPipe) {
      return false;
    }
    this.scanEnd = off;
    this.scanLevel = colCount;
    return true;
  }

  /** At least three backticks or tildes; a backtick fence's info string holds no backtick. */
  isOpeningCodeFence(beg: number): boolean {
    const text = this.text;
    let off = beg;
    while (off < this.size && text[off] === text[beg]) {
      off += 1;
    }
    if (off - beg < 3) {
      return false;
    }
    this.codeFenceLength = off - beg;
    while (off < this.size && text[off] === SPACE) {
      off += 1;
    }
    while (off < this.size && !isNewlineChar(text[off])) {
      if (text[beg] === 96 && text[off] === 96) {
        return false;
      }
      off += 1;
    }
    this.scanEnd = off;
    return true;
  }

  /** The same character as the opening fence, at least as long, then nothing but blanks. */
  isClosingCodeFence(ch: number, beg: number): boolean {
    const text = this.text;
    let off = beg;
    while (off < this.size && text[off] === ch) {
      off += 1;
    }
    let closed = false;
    if (off - beg >= this.codeFenceLength) {
      while (off < this.size && (text[off] === SPACE || text[off] === 9)) {
        off += 1;
      }
      closed = off >= this.size || isNewlineChar(text[off]);
    }
    this.scanEnd = off;
    return closed;
  }

  isHtmlBlockStartCondition(beg: number): number {
    const text = this.text;
    const size = this.size;
    const off = beg + 1;
    // Type 1: <script, <pre, <style or <textarea.
    for (const name of HTML_BLOCK_TYPE_1) {
      if (asciiCaseEq(text, off, name, name.length)) {
        return 1;
      }
    }
    // Type 2: a comment.
    if (off + 3 < size && text[off] === 33 && text[off + 1] === 45 && text[off + 2] === 45) {
      return 2;
    }
    // Type 3: a processing instruction.
    if (off < size && text[off] === 63) {
      return 3;
    }
    // Types 4 and 5: a declaration, or CDATA.
    if (off < size && text[off] === 33) {
      if (off + 1 < size && isAlphaChar(text[off + 1])) {
        return 4;
      }
      if (off + 8 < size && asciiEq(text, off, '![CDATA[', 8)) {
        return 5;
      }
    }
    // Type 6: a block-level tag, opened or closed.
    if (off + 1 < size && (isAlphaChar(text[off]) || (text[off] === 47 && isAlphaChar(text[off + 1])))) {
      let at = off;
      if (text[at] === 47) {
        at += 1;
      }
      const slot = text[at] >= 65 && text[at] <= 90 ? text[at] - 65 : text[at] - 97;
      for (const name of HTML_BLOCK_TYPE_6[slot]) {
        if (asciiCaseEq(text, at, name, name.length)) {
          const after = at + name.length;
          if (after >= size) {
            return 6;
          }
          if (isBlankChar(text[after]) || isNewlineChar(text[after]) || text[after] === GREATER) {
            return 6;
          }
          if (after + 1 < size && text[after] === 47 && text[after + 1] === GREATER) {
            return 6;
          }
          break;
        }
      }
    }
    // Type 7: any other complete tag, alone on its line.
    if (off + 1 < size && this.isHtmlTag(beg, size)) {
      let end = this.scanEnd;
      while (end < size && isWhitespaceChar(text[end])) {
        end += 1;
      }
      if (end >= size || isNewlineChar(text[end])) {
        return 7;
      }
    }
    return 0;
  }

  /** md_line_contains: a search to the end of the line, setting the scan end whether or not it finds it. */
  lineContains(beg: number, what: string): boolean {
    const text = this.text;
    let off = beg;
    for (; off + what.length < this.size; off += 1) {
      if (isNewlineChar(text[off])) {
        break;
      }
      let same = true;
      for (let index = 0; index < what.length; index += 1) {
        if (text[off + index] !== what.charCodeAt(index)) {
          same = false;
          break;
        }
      }
      if (same) {
        this.scanEnd = off + what.length;
        return true;
      }
    }
    this.scanEnd = off;
    return false;
  }

  /** One HTML tag, complete on a single line (the form the type-7 start condition needs). */
  isHtmlTag(beg: number, maxEnd: number): boolean {
    const text = this.text;
    const lineEnd = this.size;
    let off = beg + 1;
    if (off >= lineEnd) {
      return false;
    }
    // -1: no attributes may follow (a closing tag); 0: an attribute may follow after a blank;
    // 1: after a blank; 2: after an attribute name; 3: after '='; 41-43: inside a value.
    let state = 0;
    if (text[off] === 47) {
      state = -1;
      off += 1;
    }
    if (off >= lineEnd || !isAlphaChar(text[off])) {
      return false;
    }
    off += 1;
    while (off < lineEnd && (isAlnumChar(text[off]) || text[off] === 45)) {
      off += 1;
    }
    while (off < lineEnd && !isNewlineChar(text[off])) {
      if (state > 40) {
        if (state === 41 && (isBlankChar(text[off]) || isAnyOfChar(text[off], "\"'=<>`"))) {
          state = 0;
          // The character is read again in the new state.
          off -= 1;
        } else if (state === 42 && text[off] === 39) {
          state = 0;
        } else if (state === 43 && text[off] === 34) {
          state = 0;
        }
        off += 1;
      } else if (isWhitespaceChar(text[off])) {
        if (state === 0) {
          state = 1;
        }
        off += 1;
      } else if (state <= 2 && text[off] === GREATER) {
        this.scanEnd = off + 1;
        return off < maxEnd;
      } else if (state <= 2 && text[off] === 47 && off + 1 < lineEnd && text[off + 1] === GREATER) {
        this.scanEnd = off + 2;
        return off + 1 < maxEnd;
      } else if ((state === 1 || state === 2)
        && (isAlphaChar(text[off]) || text[off] === 95 || text[off] === 58)) {
        off += 1;
        while (off < lineEnd && (isAlnumChar(text[off]) || isAnyOfChar(text[off], '_.:-'))) {
          off += 1;
        }
        state = 2;
      } else if (state === 2 && text[off] === 61) {
        off += 1;
        state = 3;
      } else if (state === 3) {
        if (text[off] === 34) {
          state = 43;
        } else if (text[off] === 39) {
          state = 42;
        } else if (!isAnyOfChar(text[off], "\"'=<>`") && !isNewlineChar(text[off])) {
          state = 41;
        } else {
          return false;
        }
        off += 1;
      } else {
        return false;
      }
    }
    // A tag has to be on a single line.
    return false;
  }

  /**
   * What ends the HTML block being read, or 0. The scan end is where the end condition ends, even
   * when it is not met: the caller then reads the rest of the line without parsing it.
   */
  isHtmlBlockEndCondition(beg: number): number {
    const text = this.text;
    const size = this.size;
    switch (this.htmlBlockType) {
      case 1: {
        // Type 1 ends at its own closing tag.
        let off = beg;
        while (off + 1 < size && !isNewlineChar(text[off])) {
          if (text[off] === 60 && text[off + 1] === 47) {
            for (const name of HTML_BLOCK_TYPE_1) {
              if (off + 2 + name.length < size && asciiCaseEq(text, off + 2, name, name.length)
                && text[off + 2 + name.length] === GREATER) {
                this.scanEnd = off + 2 + name.length + 1;
                return 1;
              }
            }
          }
          off += 1;
        }
        this.scanEnd = off;
        return 0;
      }
      case 2:
        return this.lineContains(beg, '-->') ? 2 : 0;
      case 3:
        return this.lineContains(beg, '?>') ? 3 : 0;
      case 4:
        return this.lineContains(beg, '>') ? 4 : 0;
      case 5:
        return this.lineContains(beg, ']]>') ? 5 : 0;
      default:
        // A blank line ends types 6 and 7.
        if (beg >= size || isNewlineChar(text[beg])) {
          this.scanEnd = beg;
          return this.htmlBlockType;
        }
        return 0;
    }
  }

  isContainerCompatible(pivot: MdContainer, container: MdContainer): boolean {
    // A block quote has no items, as lists do.
    if (container.ch === GREATER) {
      return false;
    }
    return container.ch === pivot.ch && container.markIndent <= pivot.contentsIndent;
  }

  /** A `>` or a list marker at `off`; fills `container` and leaves the mark's end in `scanEnd`. */
  isContainerMark(indent: number, beg: number, container: MdContainer): boolean {
    const text = this.text;
    const size = this.size;
    let off = beg;
    if (off >= size || indent >= CODE_INDENT) {
      return false;
    }
    if (text[off] === GREATER) {
      off += 1;
      container.ch = GREATER;
      container.isLoose = false;
      container.isTask = false;
      container.markIndent = indent;
      container.contentsIndent = indent + 1;
      this.scanEnd = off;
      return true;
    }
    if (isAnyOfChar(text[off], '-+*') && (off + 1 >= size || isBlankChar(text[off + 1])
      || isNewlineChar(text[off + 1]))) {
      container.ch = text[off];
      container.isLoose = false;
      container.isTask = false;
      container.markIndent = indent;
      container.contentsIndent = indent + 1;
      this.scanEnd = off + 1;
      return true;
    }
    const maxEnd = Math.min(off + 9, size);
    container.start = 0;
    while (off < maxEnd && isDigitChar(text[off])) {
      container.start = container.start * 10 + text[off] - 48;
      off += 1;
    }
    if (off > beg && off < size && (text[off] === 46 || text[off] === 41)
      && (off + 1 >= size || isBlankChar(text[off + 1]) || isNewlineChar(text[off + 1]))) {
      container.ch = text[off];
      container.isLoose = false;
      container.isTask = false;
      container.markIndent = indent;
      container.contentsIndent = indent + off - beg + 1;
      this.scanEnd = off + 1;
      return true;
    }
    return false;
  }

}
