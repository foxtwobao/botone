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
// The inline pass of the markdown parser port (M5): md4c's span analysis and inline rendering
// (md_analyze_emph, md_analyze_permissive_autolink, md_analyze_marks, md_process_inlines),
// transcribed from the sources the mobile renderer's parser is built from, with the flags the
// mobile call site uses: strikethrough, spoilers, permissive autolinks; no inline HTML, math or
// underline. It reads the UTF-8 bytes of one block's lines and reports spans and text to a sink.
// Mark collection lives in markdown-inline-marks.ets, link resolution in markdown-inline-links.ets.
// Pure: no ArkUI, no kits.
import type { MdSink } from './markdown-types';
import { MdNode } from './markdown-types';
import type { MdRefDefScanner } from './markdown-refdefs';
import type { MdLine } from './markdown-line-scanners';
import {
  AMPERSAND,
  AT,
  BACKSLASH,
  BACKTICK,
  BANG,
  BRACKET_CLOSE,
  BRACKET_OPEN,
  COLON,
  DUMMY,
  DOT,
  GREATER,
  LESS,
  PIPE,
  RESOLVED,
  SEMICOLON,
  SPACE,
  STACK_COUNT,
  STAR,
  TILDE,
  UNDERSCORE,
  AUTOLINK_MISSING_MAILTO,
  BRACKET_STACK,
  OPENER,
  CLOSER,
  EMPH_MOD3_0,
  EMPH_MOD3_1,
  EMPH_MOD3_2,
  EMPH_MOD3_MASK,
  EMPH_OC,
  POTENTIAL_CLOSER,
  POTENTIAL_OPENER,
  VALID_PERMISSIVE_AUTOLINK,
  BoundaryList,
  MdInlineState,
  MdMarkCollector,
} from './markdown-inline-marks';
import { MdLinkResolver } from './markdown-inline-links';
import {
  asciiEq,
  decodeEntity,
  entityEnd,
  isAlnumChar,
  isAnyOfChar,
  isBlankChar,
  isNewlineChar,
  isPunctChar,
  isUnicodeWhitespaceAt,
  isUnicodeWhitespaceBefore,
  isWhitespaceChar,
  utf8Slice,
} from './markdown-chars';

/** The inline pass over one document; one instance serves all of its blocks. */
export class MdInlineParser {
  private readonly state: MdInlineState;
  private readonly collector: MdMarkCollector;
  private readonly links: MdLinkResolver;

  /** Draws one block's lines: its spans and text go to the sink. */
  process(lines: MdLine[], sink: MdSink): void {
    this.analyzeInlines(lines, false);
    this.renderInlines(lines, sink);
  }

  /** Table mode: analyzes one row and returns its cell boundaries as [beg, end, beg, end, …]. */
  cellBoundaries(line: MdLine): number[] {
    this.analyzeInlines([line], true);
    const out: number[] = [];
    let index = this.state.boundaries.head;
    while (index >= 0) {
      const mark = this.state.marks[index];
      out.push(mark.beg, mark.end);
      index = mark.next;
    }
    return out;
  }

  constructor(text: Uint8Array, refs: MdRefDefScanner) {
    this.state = new MdInlineState(text, refs);
    this.collector = new MdMarkCollector(text);
    this.links = new MdLinkResolver(this.state);
    this.links.onLinkContents = (lines: MdLine[], markBeg: number, markEnd: number): void => {
      this.analyzeLinkContents(lines, markBeg, markEnd);
    };
  }

  /** Whether the `&` at `markIndex` starts an entity; if so, joins it to its `;`. */
  private analyzeEntity(markIndex: number): void {
    if (markIndex + 1 >= this.state.marks.length) {
      return;
    }
    const opener = this.state.marks[markIndex];
    const closer = this.state.marks[markIndex + 1];
    // The closer has to be the very next mark: anything between could not be part of the entity.
    if (closer.ch !== SEMICOLON) {
      return;
    }
    if (entityEnd(this.state.text, opener.beg, closer.end) === closer.end) {
      this.state.resolveRange(markIndex, markIndex + 1);
      opener.end = closer.end;
    }
  }

  private analyzeTableCellBoundary(markIndex: number): void {
    const mark = this.state.marks[markIndex];
    // A pair of pipes is kept for spoilers.
    if (mark.end - mark.beg === 2) {
      return;
    }
    mark.flags |= RESOLVED;
    mark.next = -1;
    if (this.state.boundaries.head < 0) {
      this.state.boundaries.head = markIndex;
    } else {
      this.state.marks[this.state.boundaries.tail].next = markIndex;
    }
    this.state.boundaries.tail = markIndex;
    this.state.boundaries.count += mark.end - mark.beg;
  }

  /** Splits a mark, giving its last `n` characters to a new one (the dummy that follows). */
  private splitEmphMark(markIndex: number, n: number): number {
    const mark = this.state.marks[markIndex];
    const newIndex = markIndex + (mark.end - mark.beg - n);
    const split = this.state.marks[newIndex];
    split.beg = mark.beg;
    split.end = mark.end;
    split.prev = mark.prev;
    split.next = mark.next;
    split.ch = mark.ch;
    split.flags = mark.flags;
    mark.end -= n;
    split.beg = mark.end;
    return newIndex;
  }

  private analyzeEmph(markIndex: number): void {
    const mark = this.state.marks[markIndex];
    // A possible closer looks for the opener before it.
    if ((mark.flags & POTENTIAL_CLOSER) !== 0) {
      const flags = mark.flags;
      const stacks: number[] = [];
      // "The rule of three": which opener stacks this closer may take from.
      stacks.push(this.state.emphStack(mark.ch, EMPH_MOD3_0 | EMPH_OC));
      if ((flags & EMPH_MOD3_MASK) !== EMPH_MOD3_2) {
        stacks.push(this.state.emphStack(mark.ch, EMPH_MOD3_1 | EMPH_OC));
      }
      if ((flags & EMPH_MOD3_MASK) !== EMPH_MOD3_1) {
        stacks.push(this.state.emphStack(mark.ch, EMPH_MOD3_2 | EMPH_OC));
      }
      stacks.push(this.state.emphStack(mark.ch, EMPH_MOD3_0));
      if ((flags & EMPH_OC) === 0 || (flags & EMPH_MOD3_MASK) !== EMPH_MOD3_2) {
        stacks.push(this.state.emphStack(mark.ch, EMPH_MOD3_1));
      }
      if ((flags & EMPH_OC) === 0 || (flags & EMPH_MOD3_MASK) !== EMPH_MOD3_1) {
        stacks.push(this.state.emphStack(mark.ch, EMPH_MOD3_2));
      }
      // The opener is the latest mark on any of them.
      let openerIndex = -1;
      for (const stack of stacks) {
        const top = this.state.tops[stack];
        if (top >= 0 && (openerIndex < 0 || this.state.marks[top].end > this.state.marks[openerIndex].end)) {
          openerIndex = top;
        }
      }
      if (openerIndex >= 0) {
        const opener = this.state.marks[openerIndex];
        const openerSize = opener.end - opener.beg;
        const closerSize = mark.end - mark.beg;
        const stack = this.state.openerStack(openerIndex);
        if (openerSize > closerSize) {
          // The opener keeps the rest of its run for a later closer.
          openerIndex = this.splitEmphMark(openerIndex, closerSize);
          this.state.stackPush(stack, openerIndex);
        } else if (openerSize < closerSize) {
          this.splitEmphMark(markIndex, closerSize - openerSize);
        }
        this.state.popOpeners(openerIndex);
        this.state.resolveRange(openerIndex, markIndex);
        return;
      }
    }
    // Not a closer here, so it may still open an emphasis.
    if ((mark.flags & POTENTIAL_OPENER) !== 0) {
      this.state.stackPush(this.state.emphStack(mark.ch, mark.flags), markIndex);
    }
  }

  /** Strikethrough and spoilers: a closer takes the latest opener of the same length. */
  private analyzeGeneric(markIndex: number): void {
    const mark = this.state.marks[markIndex];
    const stack = this.state.openerStack(markIndex);
    if ((mark.flags & POTENTIAL_CLOSER) !== 0 && this.state.tops[stack] >= 0) {
      const openerIndex = this.state.tops[stack];
      this.state.popOpeners(openerIndex);
      this.state.resolveRange(openerIndex, markIndex);
      return;
    }
    if ((mark.flags & POTENTIAL_OPENER) !== 0) {
      this.state.stackPush(stack, markIndex);
    }
  }

  /** The nearest resolved mark at or before `off`, searching left from the left cursor. */
  private scanLeftForResolvedMark(off: number): number {
    let index = this.state.leftCursor;
    for (; index >= 0; index -= 1) {
      const mark = this.state.marks[index];
      if (mark.ch === DUMMY || mark.beg > off) {
        continue;
      }
      if (mark.beg <= off && off < mark.end && (mark.flags & RESOLVED) !== 0) {
        this.state.leftCursor = index;
        return index;
      }
      if (mark.end <= off) {
        break;
      }
    }
    this.state.leftCursor = index;
    return -1;
  }

  /** The nearest resolved mark at or after `off`, searching right from the right cursor. */
  private scanRightForResolvedMark(off: number): number {
    let index = this.state.rightCursor;
    for (; index < this.state.marks.length; index += 1) {
      const mark = this.state.marks[index];
      if (mark.ch === DUMMY || mark.end <= off) {
        continue;
      }
      if (mark.beg <= off && off < mark.end && (mark.flags & RESOLVED) !== 0) {
        this.state.rightCursor = index;
        return index;
      }
      if (mark.beg > off) {
        break;
      }
    }
    this.state.rightCursor = index;
    return -1;
  }

  /**
   * Reads one segment of a bare address or e-mail from `off` to `end`; returns how many
   * components it has (-1 for unbalanced parentheses) and leaves where it ends in `segmentEnd`.
   */
  private autolinkSegment(off: number, end: number, scanBackwards: boolean, componentDelim: number,
    wordExtra: string, wordDelims: string): number {
    const text = this.state.text;
    let nComponents = 0;
    let nOpenBrackets = 0;
    let seenWordDelim = true;
    let seenComponentDelim = true;
    let componentBeg = off;

    while (off !== end) {
      if (scanBackwards) {
        off -= 1;
      }
      // Extra and delimiter characters count only outside a resolved mark.
      if (!isAlnumChar(text[off]) && !isWhitespaceChar(text[off])) {
        const inside = scanBackwards ? this.scanLeftForResolvedMark(off) : this.scanRightForResolvedMark(off);
        if (inside >= 0) {
          if (scanBackwards) {
            off += 1;
          }
          break;
        }
      }
      // An address may sit inside brackets, so its own pairs have to be balanced.
      if (!scanBackwards) {
        if (text[off] === 40) {
          nOpenBrackets += 1;
        } else if (text[off] === 41) {
          if (nOpenBrackets <= 0) {
            break;
          }
          nOpenBrackets -= 1;
        }
      }

      if (isAlnumChar(text[off]) || isAnyOfChar(text[off], wordExtra)) {
        seenWordDelim = false;
        seenComponentDelim = false;
      } else {
        if (seenWordDelim) {
          break;
        }
        if (isAnyOfChar(text[off], wordDelims)) {
          seenWordDelim = true;
        } else if (componentDelim !== 0 && text[off] === componentDelim) {
          if (seenComponentDelim) {
            break;
          }
          seenComponentDelim = true;
          componentBeg = off;
          nComponents += 1;
        } else {
          if (scanBackwards) {
            off += 1;
          }
          break;
        }
      }

      if (!scanBackwards) {
        off += 1;
      }
    }

    // Give back a delimiter that was read too many.
    if (seenWordDelim || seenComponentDelim) {
      off = scanBackwards ? off + 1 : off - 1;
    }
    if (off !== componentBeg) {
      nComponents += 1;
    }
    if (nOpenBrackets !== 0) {
      return -1;
    }
    this.state.segmentEnd = off;
    return nComponents;
  }

  /** Whether the mark at `markIndex` begins a bare address or e-mail, and how far it reaches. */
  private analyzePermissiveAutolink(markIndex: number): void {
    const text = this.state.text;
    const marks = this.state.marks;
    const opener = marks[markIndex];
    const closer = marks[markIndex + 1];
    // The dummy keeps the line the mark was found on.
    const lineBeg = closer.beg;
    const lineEnd = closer.end;
    let beg = opener.beg;
    let end = opener.end;
    this.state.leftCursor = markIndex;
    this.state.rightCursor = markIndex;

    // An address needs the name before the `@`, so that part is read backwards.
    if (opener.ch === AT) {
      if (this.autolinkSegment(beg, lineBeg, true, 0, '', '.-_+') < 1) {
        return;
      }
      beg = this.state.segmentEnd;
      // An optional "mailto:" or "xmpp:" before it is swallowed.
      if (beg >= 7 && asciiEq(text, beg - 7, 'mailto:', 7)) {
        beg -= 7;
      } else if (beg >= 5 && asciiEq(text, beg - 5, 'xmpp:', 5)) {
        beg -= 5;
      } else {
        opener.flags |= AUTOLINK_MISSING_MAILTO;
      }
    }

    // The link has to start at the line's edge, at whitespace, after an opening bracket, or
    // right after a resolved opener.
    if (beg > lineBeg && !isUnicodeWhitespaceBefore(text, beg) && !isAnyOfChar(text[beg - 1], '({[')) {
      const mark = this.scanLeftForResolvedMark(beg - 1);
      if (mark < 0 || (this.state.marks[mark].flags & OPENER) === 0) {
        return;
      }
    }

    // The host: at least two components separated by dots.
    if (this.autolinkSegment(end, lineEnd, false, DOT, '', '-_') < 2) {
      return;
    }
    end = this.state.segmentEnd;

    if (opener.ch !== AT) {
      // The path.
      if (end < lineEnd && text[end] === 47) {
        if (this.autolinkSegment(end + 1, lineEnd, false, 47, '.+-_~%', '') < 0) {
          return;
        }
        end = this.state.segmentEnd;
        // A path may end with another slash, for a directory.
        if (end < lineEnd && text[end] === 47) {
          end += 1;
        }
      }
      // The query.
      if (end < lineEnd && text[end] === 63) {
        if (this.autolinkSegment(end + 1, lineEnd, false, 38, '._=()', '+-') < 0) {
          return;
        }
        end = this.state.segmentEnd;
      }
      // The fragment.
      if (end < lineEnd && text[end] === 35) {
        if (this.autolinkSegment(end + 1, lineEnd, false, 0, '', '.-+_') < 0) {
          return;
        }
        end = this.state.segmentEnd;
      }
    }

    // The link has to end at the line's edge, at whitespace, before closing punctuation, or
    // right before a resolved closer.
    if (end < lineEnd && !isUnicodeWhitespaceAt(text, end) && !isAnyOfChar(text[end], ')}].!?,;')) {
      const mark = this.scanRightForResolvedMark(end);
      if (mark < 0 || (this.state.marks[mark].flags & CLOSER) === 0) {
        return;
      }
    }

    // It is a link: the opener and the dummy become its zero-width ends.
    opener.beg = beg;
    opener.end = beg;
    closer.beg = end;
    closer.end = end;
    closer.ch = opener.ch;
    this.state.resolveRange(markIndex, markIndex + 1);
  }

  private analyzeMarks(lines: MdLine[], markBeg: number, markEnd: number, markChars: string,
    noskip: string): void {
    const marks = this.state.marks;
    let index = markBeg;
    let lastEnd = lines[0].beg;
    while (index < markEnd) {
      const mark = marks[index];
      // Skip resolved spans.
      if ((mark.flags & RESOLVED) !== 0) {
        if ((mark.flags & OPENER) !== 0 && (noskip === '' || !isAnyOfChar(mark.ch, noskip))) {
          index = mark.next + 1;
        } else {
          index += 1;
        }
        continue;
      }
      if (!isAnyOfChar(mark.ch, markChars)) {
        index += 1;
        continue;
      }
      // An earlier step may have grown this mark.
      if (mark.beg < lastEnd) {
        index += 1;
        continue;
      }
      const ch = mark.ch;
      if (ch === BRACKET_OPEN || ch === BANG || ch === BRACKET_CLOSE) {
        this.links.analyzeBracket(index);
      } else if (ch === AMPERSAND) {
        this.analyzeEntity(index);
      } else if (ch === UNDERSCORE || ch === STAR) {
        this.analyzeEmph(index);
      } else if (ch === DOT || ch === COLON || ch === AT) {
        this.analyzePermissiveAutolink(index);
      } else {
        this.analyzeGeneric(index);
      }
      if ((mark.flags & RESOLVED) !== 0) {
        lastEnd = (mark.flags & OPENER) !== 0 ? marks[mark.next].end : mark.end;
      }
      index += 1;
    }
  }

  private analyzeLinkContents(lines: MdLine[], markBeg: number, markEnd: number): void {
    // Entities, emphasis, spoilers, strikethrough; then the bare addresses, which are greedy.
    const emphasis = '&*_|~';
    this.analyzeMarks(lines, markBeg, markEnd, emphasis, '');
    this.analyzeMarks(lines, markBeg, markEnd, '@:.', emphasis);
    for (let stack = 0; stack < STACK_COUNT; stack += 1) {
      this.state.tops[stack] = -1;
    }
  }

  private analyzeInlines(lines: MdLine[], tableMode: boolean): void {
    this.state.unresolvedLinkHead = -1;
    this.state.unresolvedLinkTail = -1;
    this.state.boundaries = new BoundaryList();
    this.state.marks = this.collector.collect(lines, tableMode);

    // (1) Links and images.
    this.analyzeMarks(lines, 0, this.state.marks.length, '[]!', '');
    this.links.resolveBrackets(lines);
    this.state.tops[BRACKET_STACK] = -1;
    this.state.unresolvedLinkHead = -1;
    this.state.unresolvedLinkTail = -1;

    if (tableMode) {
      // (2) The pipes that split the row into cells.
      for (let index = 0; index < this.state.marks.length; index += 1) {
        const mark = this.state.marks[index];
        if ((mark.flags & RESOLVED) === 0 && mark.ch === PIPE) {
          this.analyzeTableCellBoundary(index);
        }
      }
      return;
    }
    // (3) Everything that is not a link.
    this.analyzeLinkContents(lines, 0, this.state.marks.length);
  }

  private renderInlines(lines: MdLine[], sink: MdSink): void {
    const text = this.state.text;
    const size = this.state.size;
    const marks = this.state.marks;
    const nLines = lines.length;
    const end = lines[nLines - 1].end;
    let lineIndex = 0;
    let off = lines[0].beg;
    let enforceHardbreak = false;
    let inCode = false;

    // There is always a resolved mark: the dummy after the last line.
    let markIndex = 0;
    while ((marks[markIndex].flags & RESOLVED) === 0) {
      markIndex += 1;
    }

    while (true) {
      const mark = marks[markIndex];
      const line = lines[lineIndex];
      // The text up to the next mark or the end of the line.
      const stop = Math.min(line.end, mark.beg);
      if (stop > off) {
        sink.text(utf8Slice(text, off, stop));
        off = stop;
      }

      if (off >= mark.beg) {
        if (mark.ch === 127) {
          break;
        }
        switch (mark.ch) {
          case BACKSLASH:
            // An escape yields the escaped character; before a line break, it forces a hard break.
            if (isNewlineChar(text[mark.beg + 1])) {
              enforceHardbreak = true;
            } else {
              sink.text(utf8Slice(text, mark.beg + 1, mark.beg + 2));
            }
            break;
          case SPACE:
          case 9:
          case 11:
          case 12:
            // A run of whitespace other than one space reads as one space.
            sink.text(' ');
            break;
          case BACKTICK:
            if ((mark.flags & OPENER) !== 0) {
              sink.enterSpan('code', this.spanNode('code'));
              inCode = true;
            } else {
              sink.leaveSpan('code');
              inCode = false;
            }
            break;
          case UNDERSCORE:
          case STAR: {
            const run = mark.end - mark.beg;
            if ((mark.flags & OPENER) !== 0) {
              // A run of odd length opens emphasis first, then strong emphasis in pairs.
              if (run % 2 === 1) {
                sink.enterSpan('em', this.spanNode('em'));
                off += 1;
              }
              while (off + 1 < mark.end) {
                sink.enterSpan('strong', this.spanNode('strong'));
                off += 2;
              }
            } else {
              while (off + 1 < mark.end) {
                sink.leaveSpan('strong');
                off += 2;
              }
              if ((mark.end - off) % 2 === 1) {
                sink.leaveSpan('em');
                off += 1;
              }
            }
            break;
          }
          case TILDE:
            if ((mark.flags & OPENER) !== 0) {
              sink.enterSpan('del', this.spanNode('del'));
            } else {
              sink.leaveSpan('del');
            }
            break;
          case PIPE:
            if (mark.end - mark.beg === 2) {
              if ((mark.flags & OPENER) !== 0) {
                sink.enterSpan('spoiler', this.spanNode('spoiler'));
              } else {
                sink.leaveSpan('spoiler');
              }
            }
            break;
          case BRACKET_OPEN:
          case BANG:
          case BRACKET_CLOSE: {
            const openerIndex = mark.ch !== BRACKET_CLOSE ? markIndex : mark.prev;
            const opener = marks[openerIndex];
            const isImage = opener.ch === BANG;
            const isEnter = mark.ch !== BRACKET_CLOSE;
            if (isEnter) {
              const node = this.spanNode(isImage ? 'img' : 'a');
              const dest = marks[openerIndex + 1];
              node.href = this.attribute(dest.beg, dest.end, false);
              const title = marks[openerIndex + 2].title;
              node.title = title === null ? '' : this.attributeOf(title, false);
              sink.enterSpan(node.type, node);
            } else {
              sink.leaveSpan(isImage ? 'img' : 'a');
              // A link may span several lines.
              while (mark.end > lines[lineIndex].end) {
                lineIndex += 1;
              }
            }
            break;
          }
          case LESS:
          case GREATER:
          case AT:
          case COLON:
          case DOT: {
            const opener = (mark.flags & OPENER) !== 0 ? mark : marks[mark.prev];
            const closer = marks[opener.next];
            // The closer is drawn only when its opener was.
            if ((mark.flags & OPENER) !== 0) {
              closer.flags |= VALID_PERMISSIVE_AUTOLINK;
            }
            const missingScheme = opener.ch === DOT
              || ((opener.ch === AT || opener.ch === LESS) && (opener.flags & AUTOLINK_MISSING_MAILTO) !== 0);
            let dest = this.attribute(opener.end, closer.beg, true);
            if (missingScheme) {
              dest = (opener.ch === DOT ? 'http://' : 'mailto:') + dest;
            }
            if ((closer.flags & VALID_PERMISSIVE_AUTOLINK) !== 0) {
              if ((mark.flags & OPENER) !== 0) {
                const node = this.spanNode('a');
                node.href = dest;
                sink.enterSpan('a', node);
              } else {
                sink.leaveSpan('a');
              }
            }
            break;
          }
          case AMPERSAND: {
            // A character reference: what it means, or itself when it names nothing.
            const codepoints: number[] = [];
            if (decodeEntity(text, mark.beg, mark.end, codepoints)) {
              sink.text(codepointsOf(codepoints));
            } else {
              sink.text(utf8Slice(text, mark.beg, mark.end));
            }
            break;
          }
          case 0:
            break;
          default:
            break;
        }

        off = mark.end;
        // On to the next resolved mark.
        markIndex += 1;
        while ((marks[markIndex].flags & RESOLVED) === 0 || marks[markIndex].beg < off) {
          markIndex += 1;
        }
      }

      if (off >= lines[lineIndex].end) {
        if (off >= end) {
          break;
        }
        if (inCode) {
          // Inside a code span, trailing blanks are kept and each line break reads as one space.
          const from = off;
          while (off < size && isBlankChar(text[off])) {
            off += 1;
          }
          if (off > from) {
            sink.text(utf8Slice(text, from, off));
          }
          if (off < marks[markIndex].beg && isNewlineChar(text[off])) {
            sink.text(' ');
          }
        } else {
          // A soft or hard line break.
          let kind = 'softbr';
          if (enforceHardbreak) {
            kind = 'br';
          } else {
            while (off < size && isBlankChar(text[off])) {
              off += 1;
            }
            if (off >= line.end + 2 && text[off - 2] === SPACE && text[off - 1] === SPACE
              && isNewlineChar(text[off])) {
              kind = 'br';
            }
          }
          sink.lineBreak(kind);
        }
        lineIndex += 1;
        off = Math.max(off, lines[lineIndex].beg);
        enforceHardbreak = false;
      }
    }
  }

  private spanNode(type: string): MdNode {
    const node = new MdNode();
    node.type = type;
    return node;
  }

  /** A link destination or title as the reference builds it: entities and escapes resolved. */
  attribute(beg: number, end: number, noEscapes: boolean): string {
    return this.attributeOf(this.state.text.subarray(beg, end), noEscapes);
  }

  /**
   * md_build_attribute: a NUL is dropped, a character reference is decoded, and a backslash
   * before punctuation or a line break escapes it (unless `noEscapes`, for bare addresses). A
   * reference that names nothing stays as written.
   */
  attributeOf(raw: Uint8Array, noEscapes: boolean): string {
    const parts: string[] = [];
    const bytes: number[] = [];
    let rawOff = 0;
    while (rawOff < raw.length) {
      const byte = raw[rawOff];
      if (byte === 0) {
        rawOff += 1;
        continue;
      }
      if (byte === AMPERSAND) {
        const entityEndAt = entityEnd(raw, rawOff, raw.length);
        const codepoints: number[] = [];
        if (entityEndAt >= 0 && decodeEntity(raw, rawOff, entityEndAt, codepoints)) {
          parts.push(utf8Slice(Uint8Array.from(bytes), 0, bytes.length));
          bytes.length = 0;
          parts.push(codepointsOf(codepoints));
          rawOff = entityEndAt;
          continue;
        }
      }
      if (!noEscapes && byte === BACKSLASH && rawOff + 1 < raw.length
        && (isPunctChar(raw[rawOff + 1]) || isNewlineChar(raw[rawOff + 1]))) {
        rawOff += 1;
      }
      bytes.push(raw[rawOff]);
      rawOff += 1;
    }
    parts.push(utf8Slice(Uint8Array.from(bytes), 0, bytes.length));
    return parts.join('');
  }
}

function codepointsOf(codepoints: number[]): string {
  const out: string[] = [];
  for (const codepoint of codepoints) {
    if (codepoint < 0x10000) {
      out.push(String.fromCharCode(codepoint));
    } else {
      out.push(String.fromCharCode(0xd800 + ((codepoint - 0x10000) >> 10),
        0xdc00 + ((codepoint - 0x10000) & 0x3ff)));
    }
  }
  return out.join('');
}
