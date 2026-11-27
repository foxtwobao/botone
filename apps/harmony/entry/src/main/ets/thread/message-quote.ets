// Quote text for the reply-quote sheet (B1), ported from mobile's quotableMessageSegments
// (message-presentation) and the reply-quote cap (contracts thread). A selected excerpt must be
// text the server can find again in the quoted message: deriveMessageQuote renders a bot message's
// Markdown with remark and searches the selection there, silently sending a plain reply otherwise.
// The selectable-text preview keeps bullets, table pipes and raw checkboxes, so a selection made in
// it fails that search. quoteSourceText renders the block shapes the server renders instead —
// list markers, task boxes, table cells, footnotes, HTML blocks, headings and code — as plain
// text; inline formatting goes through the preview's conversion, which already matches the server
// for emphasis, links, escapes and entities.
import { findInlineCodeClose, plainTextFromMarkdown } from './markdown-plain';

/** Cap of a reply quote (contracts REPLY_QUOTE_MAX_LENGTH). */
export const REPLY_QUOTE_MAX_LENGTH = 2000;
/** The most source text one message can contribute before it is not quotable (core). */
export const MAX_QUOTABLE_SOURCE_LENGTH = 100000;

/** Cap an excerpt at the quote limit without splitting a surrogate pair (contracts). */
export function truncateReplyQuote(value: string): string {
  const truncated = value.slice(0, REPLY_QUOTE_MAX_LENGTH);
  const last = truncated.charCodeAt(truncated.length - 1);
  return last >= 0xd800 && last <= 0xdbff ? truncated.slice(0, -1) : truncated;
}

const FENCE_OPEN = /^ {0,3}(`{3,}|~{3,})(.*)$/;
const FENCE_CLOSE = /^ {0,3}(`{3,}|~{3,})[ \t]*$/;
const HEADING = /^ {0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*$/;
const BULLET = /^(\s*)[-*+][ \t]+(.*)$/;
const NUMBERED = /^(\s*)\d{1,9}[.)][ \t]+(.*)$/;
const TASK_BOX = /^\[[ xX]\](?:[ \t]+|$)/;
const SETEXT = /^ {0,3}(?:=+|-+)[ \t]*$/;
const RULE = /^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/;
const INDENTED = /^(?: {4}|\t)/;
const QUOTE_PREFIX = /^ {0,3}> ?/;
const DELIMITER_CELL = /^:?-+:?$/;
const FOOTNOTE_DEF = /^ {0,3}\[\^([^\]\s]+)\]:[ \t]*(.*)$/;
const FOOTNOTE_REF = /\[\^([^\]\s]+)\]/g;
const LINK_DEF = /^ {0,3}\[([^\]^][^\]]*)\]:[ \t]*\S/;
const BR_TAG = /<br\s*\/?>/gi;
/** Named entities beyond the preview's six that the renderer decodes in plain text. */
const QUOTED_ENTITIES: Record<string, string> = {
  'copy': '©',
  'divide': '÷',
  'hellip': '…',
  'laquo': '«',
  'mdash': '—',
  'ndash': '–',
  'raquo': '»',
  'reg': '®',
  'times': '×',
  'trade': '™',
};
const HTML_COMMENT = /^ {0,3}<!--/;
const HTML_CDATA = /^ {0,3}<!\[CDATA\[/;
const HTML_DECLARATION = /^ {0,3}<![A-Za-z]/;
const HTML_PROCESSING = /^ {0,3}<\?/;
const HTML_RAW = /^ {0,3}<(script|pre|style|textarea)(?:[\s>]|$)/i;
const HTML_RAW_END = /<\/(?:script|pre|style|textarea)>/i;
const HTML_BLOCK_TAG = /^ {0,3}<\/?(?:address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h[1-6]|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|search|section|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul)(?:[\s/>]|$)/i;
const HTML_COMPLETE_TAG =
  /^ {0,3}(?:<[A-Za-z][A-Za-z0-9-]*(?:[ \t][^>]*)?>|<\/[A-Za-z][A-Za-z0-9-]*>)[ \t]*$/;

/** A table row's cells and whether pipes wrapped it. */
interface TableRowCells {
  cells: string[];
  wrapped: boolean;
}

/** Blocks the scanner emits, each with the break the renderer puts around it (toText's counts). */
class QuoteBuilder {
  private out: string[] = [];
  private lastAfter: number = 0;
  private pending: number = 0;

  /** A text block; before/after are newline counts the renderer puts around this block. */
  add(text: string, before: number, after: number): void {
    if (text === '') {
      this.pending = Math.max(this.pending, before, after);
      return;
    }
    if (this.out.length > 0) {
      this.out.push('\n'.repeat(Math.max(this.lastAfter, this.pending, before)));
    }
    this.out.push(text);
    this.lastAfter = after;
    this.pending = 0;
  }

  text(): string {
    return this.out.join('');
  }
}

/** What a single quoteSourceText scan carries: footnote definitions, their reference order,
 *  and the labels a reference link may resolve to. */
class QuoteContext {
  definitions: Map<string, string> = new Map<string, string>();
  used: string[] = [];
  owned: boolean[] = [];
  links: Map<string, boolean> = new Map<string, boolean>();
}

/** Footnote and link definitions by label, and the lines they own, skipping fenced code. */
interface FootnoteScan {
  definitions: Map<string, string>;
  owned: boolean[];
  links: Map<string, boolean>;
}

/** A reference label as CommonMark matches it: case-folded, whitespace collapsed. */
function linkLabelKey(label: string): string {
  return label.trim().replace(/\s+/g, ' ').toLowerCase();
}

function collectFootnoteDefinitions(lines: string[]): FootnoteScan {
  const definitions: Map<string, string> = new Map<string, string>();
  const owned: boolean[] = new Array<boolean>(lines.length).fill(false);
  const links: Map<string, boolean> = new Map<string, boolean>();
  let fence: string[] | null = null;
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i] ?? '';
    if (fence !== null) {
      const close = FENCE_CLOSE.exec(line);
      if (close !== null && (close[1] ?? '')[0] === fence[0] && (close[1] ?? '').length >= fence.length) {
        fence = null;
      }
      continue;
    }
    const open = FENCE_OPEN.exec(line);
    const marker = open?.[1];
    if (marker !== undefined && marker !== null && !(marker[0] === '`' && (open?.[2] ?? '').includes('`'))) {
      fence = [marker[0] ?? '`', String(marker.length)];
      continue;
    }
    const link = LINK_DEF.exec(line);
    if (link !== null) {
      links.set(linkLabelKey(link[1] ?? ''), true);
      continue;
    }
    const definition = FOOTNOTE_DEF.exec(line);
    if (definition === null) {
      continue;
    }
    // A definition's content continues on indented lines; both feed the footnote section.
    const body: string[] = [definition[2] ?? ''];
    owned[i] = true;
    for (let next = i + 1; next < lines.length; next += 1) {
      const carried = lines[next] ?? '';
      if (carried.trim() !== '' && !/^ {2,}\S/.test(carried)) {
        break;
      }
      owned[next] = true;
      body.push(carried.replace(/^ {1,4}/, ''));
      i = next;
      if (carried.trim() === '' && !/^ {2,}\S/.test(lines[next + 1] ?? '')) {
        break;
      }
    }
    definitions.set(definition[1] ?? '', body.join('\n').trim());
  }
  return { definitions: definitions, owned: owned, links: links };
}

/** A footnote reference becomes the number the renderer gives it, glued to its neighbours. */
function replaceFootnoteRefs(source: string, context: QuoteContext): string {
  return source.replace(FOOTNOTE_REF, (whole: string, label: string): string => {
    if (!context.definitions.has(label)) {
      return whole;
    }
    let number = context.used.indexOf(label);
    if (number < 0) {
      context.used.push(label);
      number = context.used.length - 1;
    }
    return String(number + 1);
  });
}

/** Index of the bracket closing the `[` at open, honoring nesting and backslash escapes. */
function closeBracketAt(source: string, open: number): number {
  let depth = 0;
  for (let i = open; i < source.length; i += 1) {
    const ch = source[i] ?? '';
    if (ch === '\\') {
      i += 1;
    } else if (ch === '[') {
      depth += 1;
    } else if (ch === ']') {
      depth -= 1;
      if (depth === 0) {
        return i;
      }
    }
  }
  return -1;
}

/** Index of the paren closing the `(` at open, honoring nesting and backslash escapes. */
function closeParenAt(source: string, open: number): number {
  let depth = 0;
  for (let i = open; i < source.length; i += 1) {
    const ch = source[i] ?? '';
    if (ch === '\\') {
      i += 1;
    } else if (ch === '(') {
      depth += 1;
    } else if (ch === ')') {
      depth -= 1;
      if (depth === 0) {
        return i;
      }
    }
  }
  return -1;
}

/** Drops image syntax whole, its label brackets and destination parens balanced. */
function stripImages(source: string): string {
  let out = '';
  let i = 0;
  while (i < source.length) {
    if (source.startsWith('![', i)) {
      const labelEnd = closeBracketAt(source, i + 1);
      if (labelEnd >= 0) {
        const next = source[labelEnd + 1] ?? '';
        const destEnd = next === '(' ? closeParenAt(source, labelEnd + 1) : -1;
        const refEnd = next === '[' ? closeBracketAt(source, labelEnd + 1) : -1;
        if (destEnd >= 0 || refEnd >= 0) {
          i = (destEnd >= 0 ? destEnd : refEnd) + 1;
          continue;
        }
      }
    }
    out += source[i] ?? '';
    i += 1;
  }
  return out;
}

/** The named entities the renderer decodes that the preview conversion leaves as source. */
function decodeQuotedEntities(value: string): string {
  return value.replace(/&([A-Za-z]+);/g, (whole: string, name: string): string =>
    QUOTED_ENTITIES[name.toLowerCase()] ?? whole);
}

/** A reference link the message defines becomes its label, as the renderer shows it. */
function replaceReferenceLinks(source: string, links: Map<string, boolean>): string {
  let out = '';
  let i = 0;
  while (i < source.length) {
    if (source[i] !== '[') {
      out += source[i] ?? '';
      i += 1;
      continue;
    }
    const labelEnd = closeBracketAt(source, i);
    if (labelEnd < 0) {
      out += source[i] ?? '';
      i += 1;
      continue;
    }
    const text = source.slice(i + 1, labelEnd);
    const next = source[labelEnd + 1] ?? '';
    if (next === '(') {
      const destEnd = closeParenAt(source, labelEnd + 1);
      const end = destEnd < 0 ? labelEnd + 1 : destEnd + 1;
      out += source.slice(i, end);
      i = end;
      continue;
    }
    if (next === '[') {
      const refEnd = closeBracketAt(source, labelEnd + 1);
      if (refEnd >= 0) {
        const ref = source.slice(labelEnd + 2, refEnd);
        const label = ref === '' ? text : ref;
        out += links.has(linkLabelKey(label)) ? text : source.slice(i, refEnd + 1);
        i = refEnd + 1;
        continue;
      }
    }
    if (next !== ':' && links.has(linkLabelKey(text))) {
      out += text;
      i = labelEnd + 1;
      continue;
    }
    out += source.slice(i, labelEnd + 1);
    i = labelEnd + 1;
  }
  return out;
}

/** Applies a conversion to the source outside its inline code spans, which stay literal. */
function mapOutsideCode(source: string, outside: (part: string) => string): string {
  let out = '';
  let from = 0;
  let i = 0;
  while (i < source.length) {
    if (source[i] !== '`') {
      i += 1;
      continue;
    }
    let run = 1;
    while (source[i + run] === '`') {
      run += 1;
    }
    const close = findInlineCodeClose(source, i + run, run);
    if (close === -1) {
      i += run;
      continue;
    }
    out += outside(source.slice(from, i)) + source.slice(i, close + run);
    i = close + run;
    from = i;
  }
  return out + outside(source.slice(from));
}

/**
 * Inline Markdown as the renderer shows it. Code spans stay literal through every step: images
 * drop whole (the server draws no alt text), a defined reference link becomes its label, `<br>`
 * vanishes in block text (a table cell salvages it as a space), the renderer's named entities
 * decode, and every pipe stays a pipe: the server's quote text flattens no table of its own.
 */
function inlineText(source: string, context: QuoteContext, block: boolean = true): string {
  const prepared = mapOutsideCode(source, (part: string): string => {
    let value = replaceReferenceLinks(replaceFootnoteRefs(stripImages(part), context), context.links);
    value = decodeQuotedEntities(value);
    if (block) {
      value = value.replace(BR_TAG, '');
    }
    return value.replace(/\\?\|/g, '\\|');
  });
  // shortcut: the preview conversion keeps the first 4096 chars of a paragraph, far past a quote;
  // lift it if a paragraph that long ever needs its tail quoted.
  return plainTextFromMarkdown(prepared);
}

/**
 * Table cells, split on pipes that are not escaped. GFM splits a row before it parses inline
 * content, so a bare pipe ends a cell even inside a code span; escaping it keeps it in the cell.
 */
function tableRowCells(line: string): TableRowCells | null {
  const trimmed = line.trim();
  if (trimmed.length < 2 || !trimmed.includes('|')) {
    return null;
  }
  const leadingPipe = trimmed.startsWith('|');
  const cells: string[] = [];
  let cell = '';
  for (let i = leadingPipe ? 1 : 0; i < trimmed.length; i += 1) {
    const ch = trimmed[i] ?? '';
    if (ch === '\\' && i + 1 < trimmed.length) {
      cell += ch + trimmed[++i];
    } else if (ch === '|') {
      cells.push(cell);
      cell = '';
    } else {
      cell += ch;
    }
  }
  if (cells.length === 0 && !leadingPipe) {
    return null;
  }
  const trailingPipe = cell === '' && cells.length > 0;
  if (!trailingPipe) {
    cells.push(cell);
  }
  const row: TableRowCells = { cells: cells, wrapped: leadingPipe && trailingPipe && trimmed.length > 2 };
  return row;
}

function isDelimiterRow(cells: string[]): boolean {
  return cells.every((cell: string): boolean => DELIMITER_CELL.test(cell.trim()));
}

function isTableRowLine(line: string): boolean {
  return tableRowCells(line) !== null;
}

/** One table row as its first `columns` cells, tab-joined after the escaping a cell's own pipe
 *  takes. The renderer drops cells past the header's count, so the port does too. */
function tableRowText(line: string, context: QuoteContext, columns: number): string {
  const row = tableRowCells(line);
  const cells = row === null ? [line.trim()] : row.cells.slice(0, columns);
  const parts: string[] = [];
  for (const cell of cells) {
    parts.push(inlineText(cell.trim().split('\\|').join('|'), context, false));
  }
  return parts.join('\t');
}

/** The HTML block a line opens, with the marker that ends it ('' = at the next blank line). */
function htmlBlockEnd(line: string): string | null {
  if (HTML_COMMENT.test(line)) {
    return '-->';
  }
  if (HTML_CDATA.test(line)) {
    return ']]>';
  }
  if (HTML_DECLARATION.test(line)) {
    return '>';
  }
  if (HTML_PROCESSING.test(line)) {
    return '?>';
  }
  if (HTML_RAW.test(line)) {
    return '</';
  }
  if (HTML_BLOCK_TAG.test(line) || HTML_COMPLETE_TAG.test(line)) {
    return '';
  }
  return null;
}

/** Whether a raw-HTML block is closed by this line (`</` matches any raw end tag). */
function htmlBlockClosed(line: string, end: string): boolean {
  return end === '</' ? HTML_RAW_END.test(line) : line.includes(end);
}

/** A line without its hard-break backslash: an odd trailing run marks a break, not a literal. */
function stripHardBreak(line: string): string {
  let run = 0;
  while (run < line.length && line[line.length - 1 - run] === '\\') {
    run += 1;
  }
  return run % 2 === 1 ? line.slice(0, -1) : line;
}

/** A line with up to `depth` blockquote markers removed (a fence body inside a quote). */
function stripQuotePrefix(line: string, depth: number): string {
  let value = line;
  for (let n = 0; n < depth && QUOTE_PREFIX.test(value); n += 1) {
    value = value.replace(QUOTE_PREFIX, '');
  }
  return value;
}

/**
 * A bot message's Markdown as the text the server's quote search sees (visibleTextFromMarkdown's
 * block shapes, without its parser): list items lose their markers and task boxes, table cells
 * join with tabs, headings lose their hashes, HTML blocks drop whole, code keeps its lines, and a
 * footnote becomes the number the renderer draws plus its text under "Footnotes".
 */
export function quoteSourceText(markdown: string): string {
  const lines = markdown.replace(/\r\n?/g, '\n').split('\n');
  const context = new QuoteContext();
  const scan = collectFootnoteDefinitions(lines);
  context.definitions = scan.definitions;
  context.owned = scan.owned;
  context.links = scan.links;
  const builder = new QuoteBuilder();
  let paragraph: string[] = [];
  let paragraphBreaks: number = 2;
  const flushParagraph = (breaks: number): void => {
    if (paragraph.length === 0) {
      return;
    }
    builder.add(inlineText(paragraph.map(stripHardBreak).join(' '), context), breaks, breaks);
    paragraph = [];
  };
  const stripped = (index: number): string => {
    let value = lines[index] ?? '';
    while (QUOTE_PREFIX.test(value)) {
      value = value.replace(QUOTE_PREFIX, '');
    }
    return value;
  };
  let fenceChar = '';
  let fenceLength = 0;
  let fenceQuoteDepth = 0;
  let fenceBody: string[] = [];
  let htmlEnd: string | null = null;
  let inTable = false;
  let tableColumns = 0;
  let inList = false;
  let previousBlank = true;
  let previousCode = false;

  for (let i = 0; i < lines.length; i += 1) {
    if (context.owned[i]) {
      flushParagraph(paragraphBreaks);
      previousBlank = true;
      continue;
    }
    let line = lines[i] ?? '';

    if (fenceChar !== '') {
      // A fence inside a blockquote keeps its markers on every body line; the renderer reads the
      // code without them, so the close marker is matched and the body kept the same way.
      const bodyLine = stripQuotePrefix(line, fenceQuoteDepth);
      const close = FENCE_CLOSE.exec(bodyLine);
      if (close !== null && (close[1] ?? '')[0] === fenceChar && (close[1] ?? '').length >= fenceLength) {
        builder.add(fenceBody.length > 0 ? `${fenceBody.join('\n')}\n` : '', 1, 1);
        fenceChar = '';
        fenceBody = [];
        previousCode = true;
        previousBlank = false;
        continue;
      }
      fenceBody.push(bodyLine);
      continue;
    }

    if (htmlEnd !== null) {
      if (htmlEnd === '') {
        if (line.trim() === '') {
          htmlEnd = null;
          previousBlank = true;
          inTable = false;
        }
      } else if (htmlBlockClosed(line, htmlEnd)) {
        htmlEnd = null;
        previousBlank = false;
      }
      continue;
    }

    // Blockquote markers stack; a second marker is a nested quote, which starts its own block.
    let quoteDepth = 0;
    while (QUOTE_PREFIX.test(line)) {
      line = line.replace(QUOTE_PREFIX, '');
      quoteDepth += 1;
    }
    if (quoteDepth > 1) {
      flushParagraph(paragraphBreaks);
      inTable = false;
    }

    if (line.trim() === '') {
      flushParagraph(paragraphBreaks);
      previousBlank = true;
      previousCode = false;
      inTable = false;
      continue;
    }

    const fenceOpen = FENCE_OPEN.exec(line);
    const fenceMarker = fenceOpen?.[1];
    if (fenceMarker !== undefined && fenceMarker !== null
      && !(fenceMarker[0] === '`' && (fenceOpen?.[2] ?? '').includes('`'))) {
      flushParagraph(paragraphBreaks);
      fenceChar = fenceMarker[0] ?? '`';
      fenceLength = fenceMarker.length;
      fenceQuoteDepth = quoteDepth;
      fenceBody = [];
      inTable = false;
      continue;
    }

    const html = htmlBlockEnd(line);
    if (html !== null) {
      flushParagraph(paragraphBreaks);
      htmlEnd = htmlBlockClosed(line, html) ? null : html;
      if (htmlEnd === null && html === '') {
        // A type-6/7 block runs to its own blank line even when the line carries the whole tag.
        htmlEnd = '';
      }
      continue;
    }

    if (LINK_DEF.test(line)) {
      flushParagraph(paragraphBreaks);
      continue;
    }

    if (INDENTED.test(line) && !inList && (previousBlank || previousCode)) {
      flushParagraph(paragraphBreaks);
      const body: string[] = [];
      while (i < lines.length) {
        const codeLine = lines[i] ?? '';
        if (INDENTED.test(codeLine)) {
          body.push(codeLine.replace(INDENTED, ''));
          i += 1;
          continue;
        }
        if (codeLine.trim() === '' && i + 1 < lines.length && INDENTED.test(lines[i + 1] ?? '')) {
          body.push('');
          i += 1;
          continue;
        }
        break;
      }
      i -= 1;
      builder.add(`${body.join('\n')}\n`, 1, 1);
      previousCode = true;
      previousBlank = false;
      continue;
    }
    previousCode = false;

    if (SETEXT.test(line)) {
      flushParagraph(1);
      previousBlank = false;
      continue;
    }
    if (RULE.test(line)) {
      flushParagraph(paragraphBreaks);
      builder.add('', 1, 1);
      previousBlank = true;
      continue;
    }

    const heading = HEADING.exec(line);
    if (heading !== null && (heading[1] ?? '').length > 0) {
      flushParagraph(paragraphBreaks);
      // A closing hash run (`## Title ##`) is not part of the heading's words.
      const title = (heading[2] ?? '').replace(/[ \t]+#+[ \t]*$/, '');
      builder.add(inlineText(title, context), 1, 1);
      previousBlank = false;
      continue;
    }

    const bullet = BULLET.exec(line);
    const numbered = bullet === null ? NUMBERED.exec(line) : null;
    if (bullet !== null || numbered !== null) {
      flushParagraph(paragraphBreaks);
      inList = true;
      inTable = false;
      const content = (bullet !== null ? bullet[2] : numbered?.[2]) ?? '';
      const item = content.replace(TASK_BOX, '');
      const itemFence = FENCE_OPEN.exec(item);
      const itemMarker = itemFence?.[1];
      if (itemMarker !== undefined && itemMarker !== null
        && !(itemMarker[0] === '`' && (itemFence?.[2] ?? '').includes('`'))) {
        fenceChar = itemMarker[0] ?? '`';
        fenceLength = itemMarker.length;
        fenceQuoteDepth = quoteDepth;
        fenceBody = [];
        previousBlank = false;
        continue;
      }
      paragraph = [item];
      paragraphBreaks = 1;
      previousBlank = false;
      continue;
    }

    const row = tableRowCells(line);
    if (row !== null && !inTable && i + 1 < lines.length) {
      const next = tableRowCells(stripped(i + 1));
      if (next !== null && next.cells.length === row.cells.length && isDelimiterRow(next.cells)) {
        flushParagraph(paragraphBreaks);
        tableColumns = row.cells.length;
        builder.add(tableRowText(line, context, tableColumns), 1, 1);
        inTable = true;
        previousBlank = false;
        i += 1;
        continue;
      }
    }
    if (inTable) {
      builder.add(tableRowText(line, context, tableColumns), 1, 1);
      previousBlank = false;
      continue;
    }

    if (line.startsWith('<')) {
      // Inline HTML at a line start (a span, an autolink) stays paragraph text.
      if (paragraph.length === 0) {
        paragraphBreaks = 2;
      }
      paragraph.push(line);
      previousBlank = false;
      continue;
    }

    if (/^\s/.test(line) && !inList) {
      inList = false;
    }
    if (paragraph.length === 0) {
      paragraphBreaks = 2;
    }
    paragraph.push(line);
    previousBlank = false;
  }
  flushParagraph(paragraphBreaks);

  if (context.used.length > 0) {
    builder.add('Footnotes', 2, 2);
    for (const label of context.used) {
      const definition = context.definitions.get(label) ?? '';
      builder.add(`${inlineText(definition, context)} ↩`, 2, 2);
    }
  }
  return builder.text();
}

/** A message's text blocks: the segments the quote sheet offers, empty when none is offerable. */
export function quotableMessageSegments(role: string, blocks: Record<string, Object>[]): string[] {
  const segments: string[] = [];
  let sourceLength = 0;
  for (const block of blocks) {
    if (block['kind'] !== 'text') {
      continue;
    }
    const text = block['text'];
    if (typeof text !== 'string' || (text as string) === '') {
      continue;
    }
    sourceLength += (text as string).length;
    if (sourceLength > MAX_QUOTABLE_SOURCE_LENGTH) {
      segments.length = 0;
      break;
    }
    const visible = role === 'user' ? text as string : quoteSourceText(text as string);
    if (visible.trim()) {
      segments.push(visible);
    }
  }
  return segments;
}

/** Whether the quote sheet would offer any text, as quotableMessageSegments decides it. */
export function hasQuotableText(role: string, blocks: Record<string, Object>[]): boolean {
  return quotableMessageSegments(role, blocks).length > 0;
}