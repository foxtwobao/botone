// Links and images of the markdown parser port (M5): md4c's bracket pairing and link resolution
// (md_analyze_bracket, md_resolve_bracket_link, md_is_link_reference, md_is_inline_link_spec and
// the destination and title scanners), transcribed from the sources the mobile renderer's parser is
// built from. A `[…]` is a link by an inline spec `(destination "title")`, by a full reference
// `[label][name]`, or by a collapsed or shortcut reference. Pure: no ArkUI, no kits.
import type { MdInlineState } from './markdown-inline-marks';
import {
  BRACKET_CAN_BE_IMAGE,
  BRACKET_HAS_NESTED,
  BRACKET_OPEN,
  BRACKET_STACK,
  CLOSER,
  DUMMY,
  OPENER,
  POTENTIAL_OPENER,
  RESOLVED,
  LinkAttr,
  lookupLine,
} from './markdown-inline-marks';
import { mergeLines } from './markdown-refdefs';
import type { MdLine } from './markdown-line-scanners';
import {
  isAnyOfChar,
  isControlChar,
  isNewlineChar,
  isPunctChar,
  isWhitespaceChar,
} from './markdown-chars';

const BACKSLASH = 92;
const BANG = 33;
const LESS = 60;
const GREATER = 62;
const SPACE = 32;

/** Resolves the bracket pairs of one block as links and images. */
export class MdLinkResolver {
  private readonly state: MdInlineState;
  /** Analyzes the contents of a link that was just resolved (emphasis, entities, bare addresses). */
  onLinkContents: (lines: MdLine[], markBeg: number, markEnd: number) => void =
    (_lines: MdLine[], _markBeg: number, _markEnd: number): void => {};

  constructor(state: MdInlineState) {
    this.state = state;
  }

  /** Builds the list of `[` `]` pairs, ordered by the closer. */
analyzeBracket(markIndex: number): void {
    const mark = this.state.marks[markIndex];
    if ((mark.flags & POTENTIAL_OPENER) !== 0) {
      if (this.state.tops[BRACKET_STACK] >= 0) {
        this.state.marks[this.state.tops[BRACKET_STACK]].flags |= BRACKET_HAS_NESTED;
      }
      this.state.stackPush(BRACKET_STACK, markIndex);
      return;
    }
    const openerIndex = this.state.stackPop(BRACKET_STACK);
    if (openerIndex >= 0) {
      const opener = this.state.marks[openerIndex];
      opener.next = markIndex;
      mark.prev = openerIndex;
      // The opener's `prev` chains the unresolved pairs, as its `next` points at its closer.
      if (this.state.unresolvedLinkTail >= 0) {
        this.state.marks[this.state.unresolvedLinkTail].prev = openerIndex;
      } else {
        this.state.unresolvedLinkHead = openerIndex;
      }
      this.state.unresolvedLinkTail = openerIndex;
      opener.prev = -1;
    }
  }

  /** Whether the `[label]` from `beg` to `end` names a reference definition. */
isLinkReference(lines: MdLine[], beg: number, end: number, attr: LinkAttr): boolean {
    const text = this.state.text;
    beg += text[beg] === BANG ? 2 : 1;
    end -= 1;
    const begLine = lookupLine(beg, lines);
    const label = end > lines[begLine].end
      ? mergeLines(text, beg, end, lines, begLine, SPACE)
      : text.subarray(beg, end);
    const def = this.state.refs.lookupRefDef(label);
    if (def === null) {
      return false;
    }
    attr.destBeg = def.destBeg;
    attr.destEnd = def.destEnd;
    attr.title = def.title;
    return true;
  }

  /** The `(destination "title")` of an inline link, starting at `beg`. */
isInlineLinkSpec(lines: MdLine[], beg: number, attr: LinkAttr): number {
    const text = this.state.text;
    const size = this.state.size;
    const nLines = lines.length;
    const title: number[] = [0, 0, 0, 0, 0];
    let lineIndex = lookupLine(beg, lines);
    let off = beg + 1;
    // Optional whitespace with at most one line break.
    while (off < lines[lineIndex].end && isWhitespaceChar(text[off])) {
      off += 1;
    }
    if (off >= lines[lineIndex].end && (off >= size || isNewlineChar(text[off]))) {
      lineIndex += 1;
      if (lineIndex >= nLines) {
        return -1;
      }
      off = lines[lineIndex].beg;
    }
    // The destination may be left out, but then there is no title either.
    if (off < size && text[off] === 41) {
      attr.destBeg = off;
      attr.destEnd = off;
      attr.title = null;
      return off + 1;
    }
    const dest: number[] = [0, 0, 0];
    if (!this.isLinkDestination(off, lines[lineIndex].end, dest)) {
      return -1;
    }
    off = dest[0];
    attr.destBeg = dest[1];
    attr.destEnd = dest[2];
    let titleIsMultiline = false;
    let titleBeg = off;
    let titleEnd = off;
    let titleBegLine = 0;
    if (this.isLinkTitle(lines, lineIndex, nLines, off, title)) {
      titleIsMultiline = title[4] !== title[3];
      titleBegLine = title[3];
      lineIndex = title[4];
      off = title[0];
      titleBeg = title[1];
      titleEnd = title[2];
    }
    // Optional whitespace, then the closing parenthesis.
    while (off < lines[lineIndex].end && isWhitespaceChar(text[off])) {
      off += 1;
    }
    if (off >= lines[lineIndex].end) {
      lineIndex += 1;
      if (lineIndex >= nLines) {
        return -1;
      }
      off = lines[lineIndex].beg;
    }
    if (text[off] !== 41) {
      return -1;
    }
    off += 1;
    attr.title = titleBeg >= titleEnd ? null : titleIsMultiline
      ? mergeLines(text, titleBeg, titleEnd, lines, titleBegLine, 10)
      : text.subarray(titleBeg, titleEnd);
    return off;
  }

  /** A link destination in `<…>` or bare; `result` carries [end, contentsBeg, contentsEnd]. */
isLinkDestination(beg: number, maxEnd: number, result: number[]): boolean {
    const text = this.state.text;
    let off = beg;
    if (text[beg] === LESS) {
      off += 1;
      while (off < maxEnd) {
        if (text[off] === BACKSLASH && off + 1 < maxEnd && isPunctChar(text[off + 1])) {
          off += 2;
          continue;
        }
        if (isNewlineChar(text[off]) || text[off] === LESS) {
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
      if (text[off] === BACKSLASH && off + 1 < maxEnd && isPunctChar(text[off + 1])) {
        off += 2;
        continue;
      }
      if (isWhitespaceChar(text[off]) || isControlChar(text[off])) {
        break;
      }
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
   * A link title after a blank (and at most one line break); `result` carries
   * [end, contentsBeg, contentsEnd, begLine, endLine], the lines counted from the block's first.
   */
  isLinkTitle(lines: MdLine[], from: number, nLines: number, beg: number,
    result: number[]): boolean {
    const text = this.state.text;
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
        if (text[off] === BACKSLASH && off + 1 < this.state.size && (isPunctChar(text[off + 1])
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
          return false;
        }
        off += 1;
      }
      lineIndex += 1;
    }
    return false;
  }

resolveBracketLink(openerIndex: number, closerIndex: number, lines: MdLine[]): void {
    const text = this.state.text;
    const marks = this.state.marks;
    const opener = marks[openerIndex];
    const closer = marks[closerIndex];
    const nextOpener = this.state.nextIndex >= 0 ? marks[this.state.nextIndex] : null;
    const nextCloser = nextOpener !== null ? marks[nextOpener.next] : null;
    const attr = new LinkAttr();
    let isLink = false;

    if (nextOpener !== null && nextOpener.beg === closer.end) {
      if (nextCloser !== null && nextCloser.beg > closer.end + 1) {
        // A full reference link, `[label][name]`.
        if ((nextOpener.flags & BRACKET_HAS_NESTED) === 0) {
          isLink = this.isLinkReference(lines, nextOpener.beg, nextCloser.end, attr);
        }
      } else {
        // A shortcut reference link, `[label]`.
        if ((opener.flags & BRACKET_HAS_NESTED) === 0) {
          isLink = this.isLinkReference(lines, opener.beg, closer.end, attr);
        }
      }
      if (isLink) {
        // Eat the second pair of brackets, and do not read its label as a link of its own.
        closer.end = nextCloser!.end;
        this.state.nextIndex = marks[this.state.nextIndex].prev;
      }
    } else {
      if (closer.end < this.state.size && text[closer.end] === 40) {
        // An inline link, `[label](destination "title")`.
        const inlineLinkEnd = this.isInlineLinkSpec(lines, closer.end, attr);
        isLink = inlineLinkEnd >= 0;
        const followingMarkIndex = closerIndex + 1;
        if (isLink) {
          // The closing parenthesis must not sit inside an already resolved span (a code span).
          let scan = followingMarkIndex;
          while (scan < marks.length) {
            const mark = marks[scan];
            if (mark.beg >= inlineLinkEnd) {
              break;
            }
            if ((mark.flags & (OPENER | RESOLVED)) === (OPENER | RESOLVED)) {
              if (marks[mark.next].beg >= inlineLinkEnd) {
                isLink = false;
                break;
              }
              scan = mark.next + 1;
            } else {
              scan += 1;
            }
          }
          if (isLink) {
            closer.end = inlineLinkEnd;
            this.state.disableMarks(followingMarkIndex, scan);
          }
        }
      }
      if (!isLink) {
        // A collapsed reference link, `[label][]`.
        if ((opener.flags & BRACKET_HAS_NESTED) === 0) {
          isLink = this.isLinkReference(lines, opener.beg, closer.end, attr);
        }
      }
    }

    if (!isLink) {
      return;
    }
    opener.flags |= OPENER | RESOLVED;
    closer.flags |= CLOSER | RESOLVED;
    // The two dummies after the opener hold the destination and the title.
    marks[openerIndex + 1].beg = attr.destBeg;
    marks[openerIndex + 1].end = attr.destEnd;
    marks[openerIndex + 2].title = attr.title;
    this.onLinkContents(lines, openerIndex + 1, closerIndex);

    // A label that is nothing but a bare address is not linked twice.
    let firstNested = openerIndex + 1;
    while (firstNested < closerIndex && marks[firstNested].ch === DUMMY) {
      firstNested += 1;
    }
    let lastNested = closerIndex - 1;
    while (marks[firstNested].ch === DUMMY && lastNested > openerIndex) {
      lastNested -= 1;
    }
    const first = marks[firstNested];
    const last = marks[lastNested];
    if ((first.flags & RESOLVED) !== 0 && first.beg === opener.end && isAnyOfChar(first.ch, '@:.')
      && first.next === lastNested && last.end === closer.beg) {
      first.ch = DUMMY;
      first.flags &= ~RESOLVED;
      last.ch = DUMMY;
      last.flags &= ~RESOLVED;
    }
    if (opener.ch === BRACKET_OPEN) {
      this.state.lastLinkBeg = opener.beg;
      this.state.lastLinkEnd = closer.end;
    } else {
      this.state.lastImageBeg = opener.beg;
      this.state.lastImageEnd = closer.end;
    }
  }

  /** Resolves the bracket pairs as links and images, from the inside out. */
resolveBrackets(lines: MdLine[]): void {
    const marks = this.state.marks;
    this.state.lastLinkBeg = 0;
    this.state.lastLinkEnd = 0;
    this.state.lastImageBeg = 0;
    this.state.lastImageEnd = 0;
    let openerIndex = this.state.unresolvedLinkHead;
    while (openerIndex >= 0) {
      const opener = marks[openerIndex];
      const closer = marks[opener.next];
      this.state.nextIndex = opener.prev;
      // Disabled in an earlier iteration: there is nothing left to do.
      if (opener.ch === DUMMY) {
        openerIndex = this.state.nextIndex;
        continue;
      }
      // It may turn out to be an image, `![…]`: the mark grows to the left.
      if ((opener.flags & BRACKET_CAN_BE_IMAGE) !== 0) {
        opener.ch = BANG;
        opener.beg -= 1;
      }
      // When pairs nest, the outer one must not end inside the inner one's `(…)`, and cannot be
      // a link when the inner one is (that does not hold for images).
      const aroundLink = opener.beg < this.state.lastLinkBeg && closer.end < this.state.lastLinkEnd;
      const aroundImage = opener.beg < this.state.lastImageBeg && closer.end < this.state.lastImageEnd;
      const afterInnerLink = opener.beg < this.state.lastLinkEnd && opener.ch !== BANG;
      if (!aroundLink && !aroundImage && !afterInnerLink) {
        this.resolveBracketLink(openerIndex, opener.next, lines);
      }
      openerIndex = this.state.nextIndex;
    }
  }
}
