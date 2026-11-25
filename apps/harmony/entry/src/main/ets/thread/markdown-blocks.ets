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
// The block pass of the markdown parser port (M5): md4c's md_analyze_line and md_process_line,
// transcribed from the sources the mobile renderer's parser is built from. It reads UTF-8 bytes
// and leaves the flat list of block openers, closers and leaves the tree is rebuilt from (the same
// list md4c walks twice). The recognizers live in markdown-line-scanners.ets and the link
// reference definitions in markdown-refdefs.ets. Pure: no ArkUI, no kits.
import { MdRefDefScanner } from './markdown-refdefs';
import { MdLine, MdLineScanner, MdVerbatimLine } from './markdown-line-scanners';
import {
  BLOCK_H,
  BLOCK_HR,
  BLOCK_HTML,
  BLOCK_LI,
  BLOCK_OL,
  BLOCK_P,
  BLOCK_QUOTE,
  BLOCK_ADMONITION,
  BLOCK_CODE,
  BLOCK_CLOSER,
  BLOCK_LOOSE_LIST,
  BLOCK_OPENER,
  BLOCK_SETEXT_HEADER,
  BLOCK_TABLE,
  BLOCK_UL,
  LINE_ATXHEADER,
  LINE_BLANK,
  LINE_FENCEDCODE,
  LINE_HR,
  LINE_HTML,
  LINE_INDENTEDCODE,
  LINE_SETEXTUNDERLINE,
  LINE_TABLE,
  LINE_TABLEUNDERLINE,
  LINE_TEXT,
  MdBlock,
  MdContainer,
  MdLineAnalysis,
  ADMONITION_TAGS,
  CODE_INDENT,
  GREATER,
} from './markdown-line-scanners';
import { asciiCaseEq, isAnyOfChar, isBlankChar, isNewlineChar, isWhitespaceChar } from './markdown-chars';

const BLANK_LINE: MdLineAnalysis = new MdLineAnalysis();

/** The block pass over one document. */
export class MdBlockParser {
  readonly text: Uint8Array;
  readonly size: number;
  /** The flat block list: openers, closers and leaves in document order. */
  readonly blocks: MdBlock[] = [];
  /** The line recognizers, and the link reference definitions met on the way. */
  readonly scan: MdLineScanner;
  readonly refs: MdRefDefScanner;
  private containers: MdContainer[] = [];
  private current: MdBlock | null = null;
  private lastLineHasListLooseningEffect: boolean = false;
  private consecutiveBlankLines: number = 0;

  constructor(text: Uint8Array) {
    this.text = text;
    this.size = text.length;
    this.scan = new MdLineScanner(text);
    this.refs = new MdRefDefScanner(text);
  }

  private at(off: number): number {
    return this.text[off];
  }


  /** The whole document: group its lines into the flat block list. */
  parse(): void {
    let pivot: MdLineAnalysis = BLANK_LINE;
    const buffers: MdLineAnalysis[] = [new MdLineAnalysis(), new MdLineAnalysis()];
    let which = 0;
    let off = 0;
    while (off < this.size) {
      if (pivot === buffers[which]) {
        which = which === 0 ? 1 : 0;
      }
      const line = buffers[which];
      this.analyzeLine(off, pivot, line);
      off = this.scan.scanEnd;
      pivot = this.processLine(pivot, line);
    }
    this.endCurrentBlock();
    this.leaveChildContainers(0);
  }


  /* ------------------------------- grouping lines into blocks ------------------------------- */

  private startNewBlock(line: MdLineAnalysis): void {
    const block = new MdBlock();
    switch (line.type) {
      case LINE_HR:
        block.type = BLOCK_HR;
        break;
      case LINE_ATXHEADER:
      case LINE_SETEXTUNDERLINE:
        block.type = BLOCK_H;
        break;
      case LINE_FENCEDCODE:
      case LINE_INDENTEDCODE:
        block.type = BLOCK_CODE;
        break;
      case LINE_TEXT:
      case LINE_TABLE:
      case LINE_TABLEUNDERLINE:
        block.type = BLOCK_P;
        break;
      case LINE_HTML:
        block.type = BLOCK_HTML;
        break;
      default:
        block.type = BLOCK_P;
        break;
    }
    block.flags = 0;
    block.data = line.data;
    block.nLines = 0;
    this.blocks.push(block);
    this.current = block;
  }

  private addLineIntoCurrentBlock(line: MdLineAnalysis): void {
    const block = this.current;
    if (block === null) {
      return;
    }
    if (block.type === BLOCK_CODE || block.type === BLOCK_HTML) {
      const verbatim = new MdVerbatimLine();
      verbatim.indent = line.indent;
      verbatim.beg = line.beg;
      verbatim.end = line.end;
      verbatim.start = line.start;
      verbatim.afterMarks = line.afterMarks;
      block.vlines.push(verbatim);
    } else {
      const text = new MdLine();
      text.beg = line.beg;
      text.end = line.end;
      block.lines.push(text);
    }
    block.nLines += 1;
  }

  private pushContainerBytes(type: string, start: number, data: number, flags: number): void {
    this.endCurrentBlock();
    const block = new MdBlock();
    block.type = type;
    block.flags = flags;
    block.data = data;
    block.nLines = start;
    this.blocks.push(block);
  }

  private endCurrentBlock(): void {
    const block = this.current;
    if (block === null) {
      return;
    }
    // A reference definition can take several lines, so it is looked for here rather than while
    // the line was classified.
    if ((block.type === BLOCK_P || (block.type === BLOCK_H && (block.flags & BLOCK_SETEXT_HEADER) !== 0))
      && block.lines[0].beg < this.size && this.at(block.lines[0].beg) === 91) {
      this.consumeLinkReferenceDefinitions();
      if (this.current === null) {
        return;
      }
    }
    if (block.type === BLOCK_H && (block.flags & BLOCK_SETEXT_HEADER) !== 0) {
      if (block.nLines > 1) {
        // The underline is not part of the heading.
        block.nLines -= 1;
        block.lines.pop();
      } else {
        // Only the underline is left after the definitions were eaten: an ordinary paragraph.
        block.type = BLOCK_P;
        return;
      }
    }
    this.current = null;
  }

  private consumeLinkReferenceDefinitions(): void {
    const block = this.current;
    if (block === null) {
      return;
    }
    const lines = block.lines;
    const total = lines.length;
    let n = 0;
    let injectHr = false;
    while (n < total) {
      const consumed = this.refs.isLinkReferenceDefinition(lines, n);
      if (consumed === 0) {
        break;
      }
      n += consumed;
    }
    if (n === 0) {
      return;
    }
    // The first line after the definitions may have to become a thematic break. The check also
    // moves the scan end, which the caller still needs for the line it is reading.
    const lineEnd = this.scan.scanEnd;
    const nextIsBreak = n < total && this.scan.isHrLine(lines[n].beg);
    this.scan.scanEnd = lineEnd;
    if (nextIsBreak) {
      injectHr = true;
      n += 1;
    }
    const rest = lines.slice(n);
    if (rest.length === 0) {
      this.blocks.pop();
      this.current = null;
    } else {
      block.lines = rest;
      block.nLines = rest.length;
    }
    if (injectHr) {
      const hr = new MdBlock();
      hr.type = BLOCK_HR;
      if (this.current !== null) {
        const at = this.blocks.indexOf(this.current);
        this.blocks.splice(at, 0, hr);
      } else {
        this.blocks.push(hr);
      }
    }
  }

  private enterChildContainers(nChildren: number): void {
    const n = this.containers.length;
    for (let index = n - nChildren; index < n; index += 1) {
      const c = this.containers[index];
      const ordered = c.ch === 41 || c.ch === 46;
      if (ordered || c.ch === 45 || c.ch === 43 || c.ch === 42) {
        // Remember where the list's opener landed, to mark the list loose later.
        this.endCurrentBlock();
        c.blockIndex = this.blocks.length;
        this.pushContainerBytes(ordered ? BLOCK_OL : BLOCK_UL, c.start, c.ch, BLOCK_OPENER);
        this.pushContainerBytes(BLOCK_LI, c.taskMarkOff, c.isTask ? this.at(c.taskMarkOff) : 0,
          BLOCK_OPENER);
      } else {
        this.pushContainerBytes(c.isAdmonition ? BLOCK_ADMONITION : BLOCK_QUOTE, 0, c.admonitionType,
          BLOCK_OPENER);
      }
    }
  }

  private leaveChildContainers(nKeep: number): void {
    while (this.containers.length > nKeep) {
      const c = this.containers[this.containers.length - 1];
      const ordered = c.ch === 41 || c.ch === 46;
      if (ordered || c.ch === 45 || c.ch === 43 || c.ch === 42) {
        this.pushContainerBytes(BLOCK_LI, c.taskMarkOff, c.isTask ? this.at(c.taskMarkOff) : 0,
          BLOCK_CLOSER);
        this.pushContainerBytes(ordered ? BLOCK_OL : BLOCK_UL, 0, c.ch, BLOCK_CLOSER);
      } else {
        this.pushContainerBytes(c.isAdmonition ? BLOCK_ADMONITION : BLOCK_QUOTE, 0, c.admonitionType,
          BLOCK_CLOSER);
      }
      this.containers.pop();
    }
  }

  private processLine(pivot: MdLineAnalysis, line: MdLineAnalysis): MdLineAnalysis {
    // A blank line ends the current leaf block.
    if (line.type === LINE_BLANK) {
      this.endCurrentBlock();
      return BLANK_LINE;
    }
    if (line.enforceNewBlock) {
      this.endCurrentBlock();
    }
    // Some line kinds are a block on their own.
    if (line.type === LINE_HR || line.type === LINE_ATXHEADER) {
      this.endCurrentBlock();
      this.startNewBlock(line);
      this.addLineIntoCurrentBlock(line);
      this.endCurrentBlock();
      return BLANK_LINE;
    }
    // A Setext underline turns the current block into a heading and ends it.
    if (line.type === LINE_SETEXTUNDERLINE) {
      const block = this.current;
      if (block !== null) {
        block.type = BLOCK_H;
        block.data = line.data;
        block.flags |= BLOCK_SETEXT_HEADER;
        this.addLineIntoCurrentBlock(line);
        this.endCurrentBlock();
        if (this.current === null) {
          return BLANK_LINE;
        }
        // All the body was eaten as reference definitions: the underline starts a paragraph.
        line.type = LINE_TEXT;
        return line;
      }
    }
    // A table underline turns the current block into a table.
    if (line.type === LINE_TABLEUNDERLINE) {
      const block = this.current;
      if (block !== null) {
        block.type = BLOCK_TABLE;
        block.data = line.data;
        pivot.type = LINE_TABLE;
        this.addLineIntoCurrentBlock(line);
        return pivot;
      }
    }
    // The current block also ends when the line has another kind.
    if (line.type !== pivot.type) {
      this.endCurrentBlock();
    }
    if (this.current === null) {
      this.startNewBlock(line);
      pivot = line;
    }
    this.addLineIntoCurrentBlock(line);
    return pivot;
  }


  /** Classify the line at `beg` and note the containers it opens, joins or leaves. */
  private analyzeLine(beg: number, pivotIn: MdLineAnalysis, line: MdLineAnalysis): void {
    const text = this.text;
    const size = this.size;
    let pivot = pivotIn;
    let totalIndent = 0;
    let nParents = 0;
    let nBrothers = 0;
    let nChildren = 0;
    const container = new MdContainer();
    const prevLineHasListLooseningEffect = this.lastLineHasListLooseningEffect;
    let off = beg;
    let hrKiller = 0;

    line.start = beg;
    line.afterMarks = 0;
    line.indent = this.scan.lineIndentation(totalIndent, off);
    off = this.scan.scanEnd;
    totalIndent += line.indent;
    line.beg = off;
    line.enforceNewBlock = false;

    // Given the indentation and the `>` marks, how many of the open containers are ours?
    while (nParents < this.containers.length) {
      const c = this.containers[nParents];
      if (c.ch === GREATER && line.indent < CODE_INDENT && off < size && text[off] === GREATER) {
        off += 1;
        totalIndent += 1;
        // The `>` and the one blank that may follow it belong to the quote, not to the line.
        line.afterMarks = off - beg;
        if (off < size && text[off] === 32) {
          line.afterMarks += 1;
        }
        line.indent = this.scan.lineIndentation(totalIndent, off);
        off = this.scan.scanEnd;
        totalIndent += line.indent;
        // The optional first space after `>` belongs to the mark.
        if (line.indent > 0) {
          line.indent -= 1;
        }
        line.beg = off;
      } else if (c.ch !== GREATER && line.indent >= c.contentsIndent) {
        line.indent -= c.contentsIndent;
      } else {
        break;
      }
      nParents += 1;
    }

    // A blank line needs no real indentation to sit inside a list.
    if (off >= size || isNewlineChar(text[off])) {
      if (nBrothers + nChildren === 0) {
        while (nParents < this.containers.length && this.containers[nParents].ch !== GREATER) {
          nParents += 1;
        }
      }
    }

    while (true) {
      // A fenced code block continues until its closing fence.
      if (pivot.type === LINE_FENCEDCODE) {
        line.beg = off;
        if (line.indent < CODE_INDENT) {
          const closed = this.scan.isClosingCodeFence(text[pivot.beg], off);
          off = this.scan.scanEnd;
          if (closed) {
            line.type = LINE_BLANK;
            this.lastLineHasListLooseningEffect = false;
            break;
          }
        }
        if (nParents === this.containers.length) {
          if (line.indent > pivot.indent) {
            line.indent -= pivot.indent;
          } else {
            line.indent = 0;
          }
          line.type = LINE_FENCEDCODE;
          break;
        }
      }

      // An HTML block continues until its own end condition, or until its container ends.
      if (pivot.type === LINE_HTML && this.scan.htmlBlockType > 0) {
        if (nParents < this.containers.length) {
          this.scan.htmlBlockType = 0;
        } else {
          const ended = this.scan.isHtmlBlockEndCondition(off);
          off = this.scan.scanEnd;
          if (ended > 0) {
            this.scan.htmlBlockType = 0;
            if (ended === 6 || ended === 7) {
              line.type = LINE_BLANK;
              line.indent = 0;
              break;
            }
          }
          line.type = LINE_HTML;
          nParents = this.containers.length;
          break;
        }
      }

      if (off >= size || isNewlineChar(text[off])) {
        if (pivot.type === LINE_INDENTEDCODE && nParents === this.containers.length) {
          line.type = LINE_INDENTEDCODE;
          if (line.indent > CODE_INDENT) {
            line.indent -= CODE_INDENT;
          } else {
            line.indent = 0;
          }
          this.lastLineHasListLooseningEffect = false;
        } else {
          line.type = LINE_BLANK;
          this.consecutiveBlankLines += 1;
          this.lastLineHasListLooseningEffect = nParents > 0 && nBrothers + nChildren === 0
            && this.containers[nParents - 1].ch !== GREATER;
        }
        break;
      }
      // A list item cannot begin with two blank lines: that forcefully ends the list.
      if (this.consecutiveBlankLines >= 2 && nParents > 0 && nParents === this.containers.length
        && this.containers[nParents - 1].ch !== GREATER && nBrothers + nChildren === 0
        && this.current === null && this.blocks.length > 1
        && this.blocks[this.blocks.length - 1].type === BLOCK_LI) {
        nParents -= 1;
        line.indent = totalIndent;
        if (nParents > 0) {
          line.indent -= Math.min(line.indent, this.containers[nParents - 1].contentsIndent);
        }
      }
      this.consecutiveBlankLines = 0;
      this.lastLineHasListLooseningEffect = false;

      // A Setext underline, under a paragraph.
      if (line.indent < CODE_INDENT && pivot.type === LINE_TEXT && off < size
        && (text[off] === 61 || text[off] === 45) && nParents === this.containers.length) {
        if (this.scan.isSetextUnderline(off)) {
          off = this.scan.scanEnd;
          line.type = LINE_SETEXTUNDERLINE;
          line.data = this.scan.scanLevel;
          break;
        }
      }

      // A thematic break.
      if (line.indent < CODE_INDENT && off < size && off >= hrKiller) {
        if (this.scan.isHrLine(off)) {
          off = this.scan.scanEnd;
          line.type = LINE_HR;
          break;
        }
        hrKiller = this.scan.scanEnd;
      }

      // A "brother": another item of the list already open at this level.
      if (nParents < this.containers.length && nBrothers + nChildren === 0) {
        if (this.scan.isContainerMark(line.indent, off, container)
          && this.scan.isContainerCompatible(this.containers[nParents], container)) {
          pivot = BLANK_LINE;
          off = this.scan.scanEnd;
          totalIndent += container.contentsIndent - container.markIndent;
          line.indent = this.scan.lineIndentation(totalIndent, off);
          off = this.scan.scanEnd;
          totalIndent += line.indent;
          line.beg = off;
          // Some of the following whitespace still belongs to the mark.
          if (off >= size || isNewlineChar(text[off])) {
            container.contentsIndent += 1;
          } else if (line.indent <= CODE_INDENT) {
            container.contentsIndent += line.indent;
            line.indent = 0;
          } else {
            container.contentsIndent += 1;
            line.indent -= 1;
          }
          this.containers[nParents].markIndent = container.markIndent;
          this.containers[nParents].contentsIndent = container.contentsIndent;
          nBrothers += 1;
          continue;
        }
      }

      // Indented code (which cannot interrupt a paragraph).
      if (line.indent >= CODE_INDENT && pivot.type !== LINE_TEXT) {
        line.type = LINE_INDENTEDCODE;
        line.indent -= CODE_INDENT;
        line.data = 0;
        break;
      }

      // A new container block.
      if (line.indent < CODE_INDENT && this.scan.isContainerMark(line.indent, off, container)) {
        const markEnd = this.scan.scanEnd;
        const interruptsParagraph = pivot.type === LINE_TEXT && nParents === this.containers.length;
        const emptyAfterMark = markEnd >= size || isNewlineChar(text[markEnd]);
        const noop = (interruptsParagraph && emptyAfterMark && container.ch !== GREATER)
          || (interruptsParagraph && (container.ch === 46 || container.ch === 41) && container.start !== 1);
        off = markEnd;
        if (!noop) {
          totalIndent += container.contentsIndent - container.markIndent;
          line.indent = this.scan.lineIndentation(totalIndent, off);
          off = this.scan.scanEnd;
          totalIndent += line.indent;
          line.beg = off;
          line.data = container.ch;
          // Some of the following whitespace still belongs to the mark.
          if (off >= size || isNewlineChar(text[off])) {
            container.contentsIndent += 1;
          } else if (line.indent <= CODE_INDENT) {
            container.contentsIndent += line.indent;
            line.indent = 0;
          } else {
            container.contentsIndent += 1;
            line.indent -= 1;
          }
          if (nBrothers + nChildren === 0) {
            pivot = BLANK_LINE;
          }
          if (nChildren === 0) {
            this.leaveChildContainers(nParents + nBrothers);
          }
          nChildren += 1;
          this.containers.push(container.copy());
          continue;
        }
      }

      // A row of the table being read.
      if (pivot.type === LINE_TABLE && nParents === this.containers.length) {
        line.type = LINE_TABLE;
        break;
      }

      // An ATX heading.
      if (line.indent < CODE_INDENT && off < size && text[off] === 35) {
        if (this.scan.isAtxHeaderLine(off)) {
          line.beg = this.scan.scanEnd;
          line.type = LINE_ATXHEADER;
          line.data = this.scan.scanLevel;
          break;
        }
      }

      // The opening fence of a code block.
      if (line.indent < CODE_INDENT && off < size && (text[off] === 96 || text[off] === 126)) {
        if (this.scan.isOpeningCodeFence(off)) {
          line.type = LINE_FENCEDCODE;
          line.data = 1;
          line.enforceNewBlock = true;
          break;
        }
      }

      // The start of an HTML block.
      if (off < size && text[off] === 60) {
        this.scan.htmlBlockType = this.scan.isHtmlBlockStartCondition(off);
        // Type 7 cannot interrupt a paragraph.
        if (this.scan.htmlBlockType === 7 && pivot.type === LINE_TEXT) {
          this.scan.htmlBlockType = 0;
        }
        if (this.scan.htmlBlockType > 0) {
          // The line itself may close the block at once.
          if (this.scan.isHtmlBlockEndCondition(off) === this.scan.htmlBlockType) {
            this.scan.htmlBlockType = 0;
          }
          off = this.scan.scanEnd;
          line.enforceNewBlock = true;
          line.type = LINE_HTML;
          break;
        }
      }

      // The underline of a table, under a one-line paragraph.
      if (pivot.type === LINE_TEXT && off < size && isAnyOfChar(text[off], '|-:')
        && nParents === this.containers.length) {
        if (this.current !== null && this.current.nLines === 1 && this.scan.isTableUnderline(off)) {
          off = this.scan.scanEnd;
          line.data = this.scan.scanLevel;
          line.type = LINE_TABLEUNDERLINE;
          break;
        }
      }

      // By default the line is ordinary text.
      line.type = LINE_TEXT;
      if (pivot.type === LINE_TEXT && nBrothers + nChildren === 0) {
        // A lazy continuation of the paragraph.
        nParents = this.containers.length;
      }

      // A task mark at the start of a new list item.
      if (nBrothers + nChildren > 0 && isAnyOfChar(this.containers[this.containers.length - 1].ch, '-+*.)')) {
        let tmp = off;
        while (tmp < size && tmp < off + 3 && isBlankChar(text[tmp])) {
          tmp += 1;
        }
        if (tmp + 2 < size && text[tmp] === 91 && isAnyOfChar(text[tmp + 1], 'xX ')
          && text[tmp + 2] === 93 && (tmp + 3 === size || isBlankChar(text[tmp + 3])
            || isNewlineChar(text[tmp + 3]))) {
          const taskContainer = nChildren > 0 ? this.containers[this.containers.length - 1] : container;
          taskContainer.isTask = true;
          taskContainer.taskMarkOff = tmp + 1;
          off = tmp + 3;
          while (off < size && isWhitespaceChar(text[off])) {
            off += 1;
          }
          line.beg = off;
        }
      }
      break;
    }

    // The end of the line.
    while (off < size && !isNewlineChar(text[off])) {
      off += 1;
    }
    line.end = off;

    // An ATX heading drops its optional closing mark.
    if (line.type === LINE_ATXHEADER) {
      let tmp = line.end;
      while (tmp > line.beg && isBlankChar(text[tmp - 1])) {
        tmp -= 1;
      }
      while (tmp > line.beg && text[tmp - 1] === 35) {
        tmp -= 1;
      }
      if (tmp === line.beg || isBlankChar(text[tmp - 1])) {
        line.end = tmp;
      }
    }

    if (line.type !== LINE_INDENTEDCODE && line.type !== LINE_FENCEDCODE && line.type !== LINE_HTML) {
      while (line.end > line.beg && isBlankChar(text[line.end - 1])) {
        line.end -= 1;
      }
    }

    // Eat the line break.
    if (off < size && text[off] === 13) {
      off += 1;
    }
    if (off < size && text[off] === 10) {
      off += 1;
    }
    this.scan.scanEnd = off;

    // A list still open after a blank line is loose.
    if (prevLineHasListLooseningEffect && line.type !== LINE_BLANK && nParents + nBrothers > 0) {
      const c = this.containers[nParents + nBrothers - 1];
      if (c.ch !== GREATER) {
        this.blocks[c.blockIndex].flags |= BLOCK_LOOSE_LIST;
      }
    }

    // Leave the containers this line is no longer part of.
    if (nChildren === 0 && nParents + nBrothers < this.containers.length) {
      this.leaveChildContainers(nParents + nBrothers);
    }

    // A brother closes the previous item and opens its own.
    if (nBrothers > 0) {
      const open = this.containers[nParents];
      this.pushContainerBytes(BLOCK_LI, open.taskMarkOff, open.isTask ? this.at(open.taskMarkOff) : 0,
        BLOCK_CLOSER);
      this.pushContainerBytes(BLOCK_LI, container.taskMarkOff,
        container.isTask ? this.at(container.taskMarkOff) : 0, BLOCK_OPENER);
      open.isTask = container.isTask;
      open.taskMarkOff = container.taskMarkOff;
    }

    if (nChildren > 0) {
      // `> [!NOTE]` alone on the first line makes the quote an admonition.
      const deepest = this.containers[this.containers.length - 1];
      const width = line.end - line.beg;
      if (deepest.ch === GREATER && line.type === LINE_TEXT && 3 < width && width < 16
        && text[line.beg] === 91 && text[line.beg + 1] === 33 && text[line.end - 1] === 93) {
        for (let index = 0; index < ADMONITION_TAGS.length; index += 1) {
          const tag = ADMONITION_TAGS[index];
          if (width === tag.length + 3 && asciiCaseEq(text, line.beg + 2, tag, width - 3)) {
            deepest.isAdmonition = true;
            deepest.admonitionType = index;
            line.type = LINE_BLANK;
            break;
          }
        }
      }
      this.enterChildContainers(nChildren);
    }
  }

}
