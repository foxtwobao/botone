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
// markdown-lite (design §6.4, M5): the markdown the bot bubble renders, parsed exactly as the
// mobile app's native renderer parses it (md4c, GitHub flavor; see markdown-blocks.ets for where
// the port comes from). This module walks the block list into the tree the renderer reads and
// defines the tree's shape; the passes live in markdown-blocks, markdown-inline and their
// neighbours. Anything the renderer cannot draw still parses (an image, a spoiler, a video) and is
// degraded there, never dropped here. Pure: no ArkUI, no kits, so the fixture can replay it.
import type { MdSink } from './markdown-types';
import { MdNode } from './markdown-types';
import { isWhitespaceChar, utf8Encode, utf8Slice } from './markdown-chars';
import { MdBlockParser } from './markdown-blocks';
import {
  ADMONITION_TAGS,
  BLOCK_ADMONITION,
  BLOCK_CLOSER,
  BLOCK_CODE,
  BLOCK_H,
  BLOCK_HTML,
  BLOCK_LI,
  BLOCK_LOOSE_LIST,
  BLOCK_OL,
  BLOCK_OPENER,
  BLOCK_P,
  BLOCK_QUOTE,
  BLOCK_TABLE,
  BLOCK_UL,
} from './markdown-line-scanners';
import type { MdBlock } from './markdown-line-scanners';
import { MdLine } from './markdown-line-scanners';
import { MdInlineParser } from './markdown-inline';
import { codeBlockAsWritten } from './markdown-code';

const ALIGNMENTS: string[] = ['default', 'left', 'right', 'center'];
/**
 * Past this depth a node's children attach to that ancestor instead. The reference recurses over
 * the tree and cannot draw such depth either (a line of thousands of emphasis marks).
 */
const MAX_TREE_DEPTH = 100;
const BLANK_ONLY = /^[ \t\n\r]*$/;

/** Node types that are blocks; everything else the parser reports is an inline. */
const BLOCK_TYPES: string[] = [
  'doc', 'p', 'h', 'quote', 'admonition', 'ul', 'ol', 'li', 'codeblock', 'hr', 'table', 'thead',
  'tbody', 'tr', 'th', 'td', 'video',
];

function nodeOf(type: string): MdNode {
  const node = new MdNode();
  node.type = type;
  return node;
}

/** What the text children of a node say, joined. */
function leafTextOf(node: MdNode): string {
  const parts: string[] = [];
  for (const child of node.children) {
    if (child.type === 'text') {
      parts.push(child.text);
    }
  }
  return parts.join('');
}

function isBlockNode(node: MdNode): boolean {
  return BLOCK_TYPES.indexOf(node.type) >= 0;
}

/** A line break, or text made of nothing but ASCII blanks (other whitespace is content). */
function isSeparatorNode(node: MdNode): boolean {
  if (node.type === 'br' || node.type === 'softbr') {
    return true;
  }
  return node.type === 'text' && BLANK_ONLY.test(node.text);
}

/** Rebuilds the tree from what the parser reports, in document order. */
class TreeBuilder implements MdSink {
  readonly root: MdNode = nodeOf('doc');
  private stack: MdNode[] = [this.root];
  private pending: string = '';

  private flushText(): void {
    if (this.pending !== '' && this.stack.length > 0) {
      const top = this.stack[this.stack.length - 1];
      const text = nodeOf('text');
      text.text = this.pending;
      top.children.push(text);
    }
    this.pending = '';
  }

  private pushNode(node: MdNode): void {
    this.flushText();
    const top = this.stack[this.stack.length - 1];
    top.children.push(node);
    this.stack.push(this.stack.length >= MAX_TREE_DEPTH ? top : node);
  }

  private popNode(): MdNode | null {
    this.flushText();
    if (this.stack.length <= 1) {
      return null;
    }
    const top = this.stack[this.stack.length - 1];
    this.stack.pop();
    return top;
  }

  enterBlock(_type: string, node: MdNode): void {
    // An HTML block reports no node: its content is kept aside for a video it may hold.
    if (_type === BLOCK_HTML) {
      return;
    }
    this.pushNode(node);
  }

  leaveBlock(type: string): void {
    if (type === BLOCK_HTML) {
      return;
    }
    this.popNode();
  }

  enterSpan(_type: string, node: MdNode): void {
    this.pushNode(node);
  }

  leaveSpan(type: string): void {
    const node = this.popNode();
    if (type === 'code' && node !== null && node.type === 'code') {
      // A code span also carries its text.
      node.text = leafTextOf(node);
    }
  }

  text(value: string): void {
    this.pending += value;
  }

  lineBreak(kind: string): void {
    this.flushText();
    const top = this.stack[this.stack.length - 1];
    top.children.push(nodeOf(kind));
  }

  /** Adds a node to the one being built, without becoming the current one. */
  addChild(node: MdNode): void {
    this.flushText();
    const top = this.stack[this.stack.length - 1];
    top.children.push(node);
  }

  /**
   * Adds a node ahead of the text still waiting, which is what the reference does for a video:
   * in a tight list item the words before it are not written into a node until later.
   */
  addChildBeforeText(node: MdNode): void {
    const top = this.stack[this.stack.length - 1];
    top.children.push(node);
  }
}

/** The column alignments of a table's underline row. */
function tableAlignment(text: Uint8Array, beg: number, end: number, count: number): string[] {
  const out: string[] = [];
  let off = beg;
  for (let column = 0; column < count; column += 1) {
    let index = 0;
    while (off < end && text[off] !== 45) {
      off += 1;
    }
    if (off > beg && text[off - 1] === 58) {
      index |= 1;
    }
    while (off < end && text[off] === 45) {
      off += 1;
    }
    if (off < end && text[off] === 58) {
      index |= 2;
    }
    out.push(ALIGNMENTS[index]);
  }
  return out;
}

/** Whether a string is blank in the C sense (space, tab, line break, vertical tab, form feed). */
function isSpaceChar(ch: string): boolean {
  return ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r' || ch === '\v' || ch === '\f';
}

/**
 * The video an HTML block holds (`<video src="…">`), or null. The reference keeps only that one
 * tag out of an HTML block; everything else in it is dropped.
 */
function videoFromHtml(html: string): MdNode | null {
  const length = html.length;
  let pos = 0;
  while (pos < length && isSpaceChar(html.charAt(pos))) {
    pos += 1;
  }
  if (pos >= length || html.charAt(pos) !== '<') {
    return null;
  }
  pos += 1;
  // A closing tag names no element.
  if (pos < length && html.charAt(pos) === '/') {
    return null;
  }
  while (pos < length && isSpaceChar(html.charAt(pos))) {
    pos += 1;
  }
  const nameStart = pos;
  while (pos < length && !isSpaceChar(html.charAt(pos)) && html.charAt(pos) !== '>' && html.charAt(pos) !== '/') {
    pos += 1;
  }
  if (pos === nameStart) {
    return null;
  }
  const name = html.slice(nameStart, pos).toLowerCase();
  let src = '';
  while (pos < length) {
    while (pos < length && isSpaceChar(html.charAt(pos))) {
      pos += 1;
    }
    if (pos >= length || html.charAt(pos) === '>' || html.charAt(pos) === '/') {
      break;
    }
    const attrStart = pos;
    while (pos < length && html.charAt(pos) !== '=' && !isSpaceChar(html.charAt(pos))
      && html.charAt(pos) !== '>' && html.charAt(pos) !== '/') {
      pos += 1;
    }
    if (pos === attrStart) {
      pos += 1;
      continue;
    }
    const attrName = html.slice(attrStart, pos).toLowerCase();
    while (pos < length && isSpaceChar(html.charAt(pos))) {
      pos += 1;
    }
    if (pos < length && html.charAt(pos) === '=') {
      pos += 1;
      while (pos < length && isSpaceChar(html.charAt(pos))) {
        pos += 1;
      }
      let value = '';
      const quote = html.charAt(pos);
      if (quote === '"' || quote === "'") {
        pos += 1;
        const valueStart = pos;
        while (pos < length && html.charAt(pos) !== quote) {
          pos += 1;
        }
        value = html.slice(valueStart, pos);
        if (pos < length) {
          pos += 1;
        }
      } else {
        const valueStart = pos;
        while (pos < length && !isSpaceChar(html.charAt(pos)) && html.charAt(pos) !== '>'
          && html.charAt(pos) !== '/') {
          pos += 1;
        }
        value = html.slice(valueStart, pos);
      }
      if (attrName === 'src') {
        src = value;
      }
    }
  }
  if (name !== 'video' || src === '') {
    return null;
  }
  const video = nodeOf('video');
  video.href = src;
  return video;
}

/** md4c leaves the inline content of a tight list item unwrapped; wrap each run in a paragraph. */
function wrapListItemInlineRuns(node: MdNode): void {
  for (const child of node.children) {
    wrapListItemInlineRuns(child);
  }
  if (node.type !== BLOCK_LI) {
    return;
  }
  let hasInlineChild = false;
  for (const child of node.children) {
    if (!isBlockNode(child)) {
      hasInlineChild = true;
      break;
    }
  }
  if (!hasInlineChild) {
    return;
  }
  const next: MdNode[] = [];
  const run: MdNode[] = [];
  const flushRun = (): void => {
    if (run.length === 0) {
      return;
    }
    let hasContent = false;
    for (const item of run) {
      if (!isSeparatorNode(item)) {
        hasContent = true;
        break;
      }
    }
    if (hasContent) {
      const paragraph = nodeOf('p');
      paragraph.tight = true;
      paragraph.children = run.slice();
      next.push(paragraph);
    } else {
      // Only blanks between two blocks: a paragraph around them would add spacing.
      for (const item of run) {
        next.push(item);
      }
    }
    run.length = 0;
  };
  for (const child of node.children) {
    if (isBlockNode(child)) {
      flushRun();
      next.push(child);
    } else {
      run.push(child);
    }
  }
  flushRun();
  node.children = next;
}

function isVideoOnlyItem(node: MdNode): boolean {
  return node.type === BLOCK_LI && node.children.length === 1 && node.children[0].type === 'video';
}

/** A list item that is only a video becomes a block of its own, splitting its list around it. */
function promoteVideosFromListItems(node: MdNode): void {
  for (const child of node.children) {
    if (child.type === BLOCK_QUOTE || child.type === BLOCK_ADMONITION) {
      promoteVideosFromListItems(child);
    }
  }
  let index = 0;
  while (index < node.children.length) {
    const list = node.children[index];
    if (list.type !== BLOCK_UL && list.type !== BLOCK_OL) {
      index += 1;
      continue;
    }
    let hasVideoItem = false;
    for (const item of list.children) {
      if (isVideoOnlyItem(item)) {
        hasVideoItem = true;
        break;
      }
    }
    if (!hasVideoItem) {
      index += 1;
      continue;
    }
    const replacement: MdNode[] = [];
    const current: MdNode[] = [];
    const closeList = (): void => {
      if (current.length > 0) {
        const sublist = nodeOf(list.type);
        sublist.children = current.slice();
        replacement.push(sublist);
        current.length = 0;
      }
    };
    for (const item of list.children) {
      if (isVideoOnlyItem(item)) {
        closeList();
        replacement.push(item.children[0]);
      } else {
        current.push(item);
      }
    }
    closeList();
    const at = node.children.indexOf(list);
    node.children.splice(at, 1, ...replacement);
    index += replacement.length;
  }
}

/** One document, from its text to its tree. */
class MdDocumentParser {
  private readonly text: Uint8Array;
  private readonly blocks: MdBlockParser;
  private readonly inline: MdInlineParser;
  private readonly builder: TreeBuilder = new TreeBuilder();

  constructor(source: string) {
    this.text = utf8Encode(source);
    this.blocks = new MdBlockParser(this.text);
    this.inline = new MdInlineParser(this.text, this.blocks.refs);
  }

  parse(): MdNode {
    this.blocks.parse();
    this.processBlocks();
    wrapListItemInlineRuns(this.builder.root);
    promoteVideosFromListItems(this.builder.root);
    return this.builder.root;
  }

  /** md_process_all_blocks: walk the flat block list, tracking which lists are loose. */
  private processBlocks(): void {
    // For each open list or quote: whether its paragraphs are loose (quotes always are).
    const loose: boolean[] = [];
    for (const block of this.blocks.blocks) {
      if ((block.flags & (BLOCK_OPENER | BLOCK_CLOSER)) !== 0) {
        const isList = block.type === BLOCK_UL || block.type === BLOCK_OL;
        const isQuote = block.type === BLOCK_QUOTE || block.type === BLOCK_ADMONITION;
        if ((block.flags & BLOCK_CLOSER) !== 0) {
          this.builder.leaveBlock(block.type);
          if (isList || isQuote) {
            loose.pop();
          }
        }
        if ((block.flags & BLOCK_OPENER) !== 0) {
          this.builder.enterBlock(block.type, this.blockNode(block));
          if (isList) {
            loose.push((block.flags & BLOCK_LOOSE_LIST) !== 0);
          } else if (isQuote) {
            // Even inside a tight list, a quote's text sits in paragraphs.
            loose.push(true);
          }
        }
      } else {
        const inTightList = loose.length > 0 && !loose[loose.length - 1];
        this.processLeaf(block, inTightList);
      }
    }
  }

  /** The tree node a container opener stands for. */
  private blockNode(block: MdBlock): MdNode {
    const node = nodeOf(block.type);
    const text = this.text;
    if (block.type === BLOCK_H) {
      node.level = Math.min(6, Math.max(1, block.data));
    } else if (block.type === BLOCK_OL) {
      node.start = block.nLines;
    } else if (block.type === BLOCK_LI && block.data !== 0) {
      // The task mark: a space for an open item, x or X for a done one.
      node.task = block.data === 32 ? ' ' : 'x';
    } else if (block.type === BLOCK_ADMONITION) {
      node.kind = ADMONITION_TAGS[block.data] ?? '';
    } else if (block.type === BLOCK_CODE && block.data !== 0) {
      const fence = block.vlines[0];
      node.fence = String.fromCharCode(text[fence.beg]);
      node.lang = this.fenceLanguage(fence.beg, fence.end);
    } else if (block.type === BLOCK_TABLE) {
      node.cols = block.data;
      node.heads = 1;
      node.bodies = block.nLines - 2;
    }
    return node;
  }

  /** The language a fence names: the first word of its info string, entities and escapes resolved. */
  private fenceLanguage(fenceBeg: number, fenceEnd: number): string {
    const text = this.text;
    const size = text.length;
    const fenceChar = text[fenceBeg];
    let beg = fenceBeg;
    let end = fenceEnd;
    while (beg < size && text[beg] === fenceChar) {
      beg += 1;
    }
    while (beg < size && text[beg] === 32) {
      beg += 1;
    }
    while (end > beg && text[end - 1] === 32) {
      end -= 1;
    }
    let langEnd = beg;
    while (langEnd < end && !isWhitespaceChar(text[langEnd])) {
      langEnd += 1;
    }
    return this.inline.attribute(beg, langEnd, false);
  }

  /** A code or HTML block's text: its lines with their indentation restored, a NUL dropped. */
  private codeText(block: MdBlock, isFenced: boolean): string {
    const text = this.text;
    const parts: string[] = [];
    const lines = block.vlines;
    let first = 0;
    let count = lines.length;
    if (isFenced) {
      // Fenced: the first line is the fence itself.
      first = 1;
      count -= 1;
    } else {
      // Indented: blank lines at either end are not part of the code.
      while (count > 0 && lines[first].beg === lines[first].end) {
        first += 1;
        count -= 1;
      }
      while (count > 0 && lines[first + count - 1].beg === lines[first + count - 1].end) {
        count -= 1;
      }
    }
    for (let index = first; index < first + count; index += 1) {
      const line = lines[index];
      parts.push(' '.repeat(line.indent));
      const bytes: number[] = [];
      for (let off = line.beg; off < line.end; off += 1) {
        if (text[off] !== 0) {
          bytes.push(text[off]);
        }
      }
      parts.push(utf8Slice(Uint8Array.from(bytes), 0, bytes.length));
      parts.push('\n');
    }
    return parts.join('');
  }

  /** md_process_leaf_block: a table too sparse to be one reads as a paragraph. */
  private suppressSparseTable(block: MdBlock): void {
    if (block.type !== BLOCK_TABLE) {
      return;
    }
    const cols = block.data;
    const rows = block.lines.length;
    if (cols <= 32 || rows <= Math.floor(4096 / cols)) {
      return;
    }
    let inputSize = rows;
    for (const line of block.lines) {
      inputSize += line.end - line.beg;
    }
    if (Math.floor(inputSize / cols) < Math.floor(rows / 4)) {
      block.type = BLOCK_P;
    }
  }

  private processLeaf(block: MdBlock, inTightList: boolean): void {
    this.suppressSparseTable(block);
    if (block.type === BLOCK_HTML) {
      const video = videoFromHtml(this.codeText(block, false));
      if (video !== null) {
        this.builder.addChildBeforeText(video);
      }
      return;
    }
    const isParagraph = block.type === BLOCK_P;
    // In a tight list item the paragraph's content sits directly in the item.
    const wrapped = !inTightList || !isParagraph;
    if (wrapped) {
      const node = this.blockNode(block);
      if (block.type === BLOCK_CODE) {
        node.text = this.codeText(block, block.data !== 0);
        node.copyText = codeBlockAsWritten(this.text, block.vlines, block.data !== 0);
        this.builder.enterBlock(block.type, node);
        if (node.text !== '') {
          // The reference reports the code as one text child as well.
          const text = nodeOf('text');
          text.text = node.text;
          this.builder.addChild(text);
        }
      } else {
        this.builder.enterBlock(block.type, node);
      }
    }
    if (block.type === BLOCK_TABLE) {
      this.processTable(block);
    } else if (block.type !== BLOCK_CODE && block.type !== 'hr' && block.lines.length > 0) {
      this.inline.process(block.lines, this.builder);
    }
    if (wrapped) {
      this.builder.leaveBlock(block.type);
    }
  }

  private processTable(block: MdBlock): void {
    const lines = block.lines;
    const cols = block.data;
    const alignment = tableAlignment(this.text, lines[1].beg, lines[1].end, cols);
    this.builder.enterBlock('thead', nodeOf('thead'));
    this.processRow('th', lines[0], alignment, cols);
    this.builder.leaveBlock('thead');
    if (lines.length > 2) {
      this.builder.enterBlock('tbody', nodeOf('tbody'));
      for (let index = 2; index < lines.length; index += 1) {
        this.processRow('td', lines[index], alignment, cols);
      }
      this.builder.leaveBlock('tbody');
    }
  }

  /** One row, split into cells at the pipes that are not escaped or inside a code span. */
  private processRow(kind: string, line: MdLine, alignment: string[], cols: number): void {
    const boundaries = this.inline.cellBoundaries(line);
    const cellBegins: number[] = [];
    // The first cell may or may not start with a pipe.
    if (boundaries.length === 0 || boundaries[0] > line.beg) {
      cellBegins.push(line.beg);
    }
    let lastEnd = -1;
    for (let index = 0; index < boundaries.length; index += 2) {
      const beg = boundaries[index];
      const end = boundaries[index + 1];
      for (let offset = 0; offset < end - beg; offset += 1) {
        cellBegins.push(beg + offset + 1);
      }
      lastEnd = end;
    }
    if (lastEnd < line.end) {
      cellBegins.push(line.end + 1);
    }
    this.builder.enterBlock('tr', nodeOf('tr'));
    let index = 0;
    for (; index < cellBegins.length - 1 && index < cols; index += 1) {
      this.processCell(kind, alignment[index], cellBegins[index], cellBegins[index + 1] - 1);
    }
    // A row with too few cells gets empty ones.
    for (; index < cols; index += 1) {
      this.processCell(kind, alignment[index], 0, 0);
    }
    this.builder.leaveBlock('tr');
  }

  private processCell(kind: string, alignment: string, beg: number, end: number): void {
    const text = this.text;
    while (beg < end && isWhitespaceChar(text[beg])) {
      beg += 1;
    }
    while (end > beg && isWhitespaceChar(text[end - 1])) {
      end -= 1;
    }
    const cell = nodeOf(kind);
    cell.kind = alignment;
    this.builder.enterBlock(kind, cell);
    const line = new MdLine();
    line.beg = beg;
    line.end = end;
    this.inline.process([line], this.builder);
    this.builder.leaveBlock(kind);
  }
}

/** Parses bot Markdown into the tree the bubble renders (the mobile renderer's parse). */
export function parseMarkdown(text: string): MdNode {
  if (text.length === 0) {
    return nodeOf('doc');
  }
  return new MdDocumentParser(text).parse();
}

function compactInto(node: MdNode, parts: string[]): void {
  parts.push('{"type":', JSON.stringify(node.type));
  const text = (key: string, value: string): void => {
    if (value !== '') {
      parts.push(`,"${key}":`, JSON.stringify(value));
    }
  };
  text('text', node.text);
  text('href', node.href);
  text('title', node.title);
  if (node.level !== 0) {
    parts.push(`,"level":${node.level}`);
  }
  text('lang', node.lang);
  text('fence', node.fence);
  if (node.start !== 1) {
    parts.push(`,"start":${node.start}`);
  }
  if (node.tight) {
    parts.push(',"tight":true');
  }
  text('task', node.task);
  text('kind', node.kind);
  if (node.cols !== 0) {
    parts.push(`,"cols":${node.cols}`);
  }
  if (node.heads !== 0) {
    parts.push(`,"heads":${node.heads}`);
  }
  if (node.bodies !== 0) {
    parts.push(`,"bodies":${node.bodies}`);
  }
  if (node.children.length > 0) {
    parts.push(',"children":[');
    for (let index = 0; index < node.children.length; index += 1) {
      if (index > 0) {
        parts.push(',');
      }
      compactInto(node.children[index], parts);
    }
    parts.push(']');
  }
  parts.push('}');
}

/**
 * A tree as one JSON string with only what is not the default, in a fixed key order. The layer-2
 * fixture writes the reference parser's tree in this same form, so the two compare as strings.
 */
export function mdCompact(node: MdNode): string {
  const parts: string[] = [];
  compactInto(node, parts);
  return parts.join('');
}

function collectPlainText(node: MdNode, parts: string[]): void {
  if (node.type === 'text' || node.type === 'code' || node.type === 'codeblock') {
    parts.push(node.text);
    return;
  }
  if (node.type === 'br' || node.type === 'softbr') {
    parts.push(' ');
    return;
  }
  for (const child of node.children) {
    if (isBlockNode(child)) {
      parts.push(' ');
    }
    collectPlainText(child, parts);
  }
}

/** The words of a markdown string on one line, for previews and accessibility labels. */
export function markdownPlainText(text: string): string {
  const parts: string[] = [];
  collectPlainText(parseMarkdown(text), parts);
  return parts.join('').replace(/\s+/g, ' ').trim();
}
