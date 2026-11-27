// Markdown source as one plain line (M5), ported from core's markdown-plain: what a reply line
// shows of its parent and what a preview says before the server's arrives.
/** The preview source window. */
interface PreviewWindow {
  text: string;
  truncated: boolean;
}

/**
 * Markdown source to one plain line for previews and notifications (core plainTextFromMarkdown):
 * fixed one-char tokens are stashed first so they never collide, fenced and inline code is kept
 * literal, autolinks, escapes, HTML tags and emphasis are resolved, table rows flatten to their
 * cells, and entities decode last.
 */
const PAYLOAD_MARK = '\uE000';
const MAX_PREVIEW_SOURCE = 4096;

const NAMED_ENTITIES: Record<string, string> = {
  'amp': '&',
  'apos': "'",
  'gt': '>',
  'lt': '<',
  'nbsp': ' ',
  'quot': '"',
};

/** The six named entities and numeric references, as the preview's last step decodes them. */
function decodeHtmlEntities(value: string): string {
  const entity = /&(#(?:x[\da-f]+|\d+)|amp|apos|gt|lt|nbsp|quot);/gi;
  return value.replace(entity, (whole: string, code: string): string => {
    if (code.length > 0 && code[0] !== '#') {
      return NAMED_ENTITIES[code.toLowerCase()] ?? whole;
    }
    const hex = code.length > 1 && code[1].toLowerCase() === 'x';
    const point = Number.parseInt(code.slice(hex ? 2 : 1), hex ? 16 : 10);
    return Number.isInteger(point) && point > 0 && point <= 0x10ffff
      ? String.fromCodePoint(point)
      : whole;
  });
}

/** A shorter nonempty prefix, never splitting a surrogate pair (core textBoundary). */
function textBoundary(text: string, offset: number): number {
  const before = text.charCodeAt(offset - 1);
  const after = text.charCodeAt(offset);
  return before >= 0xd800 && before <= 0xdbff && after >= 0xdc00 && after <= 0xdfff
    ? offset - 1
    : offset;
}

function truncatePlainText(text: string, maxChars: number): string {
  if (text.length <= maxChars) {
    return text;
  }
  return text.slice(0, textBoundary(text, maxChars));
}

/** The preview window: a fitting message whole, a past-cap one trimmed after leading blanks. */
function boundedPreviewSource(markdown: string, maxSource: number): PreviewWindow {
  const normalized = markdown.replace(/\r\n?/g, '\n');
  if (normalized.length <= maxSource) {
    return { text: normalized, truncated: false };
  }
  const body = normalized.replace(/^\s+/, '');
  if (body.length <= maxSource) {
    return { text: body, truncated: false };
  }
  return { text: truncatePlainText(body, maxSource), truncated: true };
}

/**
 * The preview conversion (core plainTextFromMarkdown). Stashed payloads hold literal text so mark
 * characters from the input cannot form tokens: each is a slice of the input, restored once.
 */
export function plainTextFromMarkdown(markdown: string): string {
  const payloads: string[] = [PAYLOAD_MARK];
  const markToken = `${PAYLOAD_MARK}0${PAYLOAD_MARK}`;
  const restore = (text: string): string => {
    const token = new RegExp(`${PAYLOAD_MARK}(\\d+)${PAYLOAD_MARK}`, 'g');
    return text.replace(token, (whole: string, digits: string): string => {
      const payload = payloads[Number(digits)] ?? '';
      return payload === '' ? whole : restore(payload);
    });
  };
  // A payload's text never carries a raw mark: one could sit next to digits and impersonate a token.
  const stash = (payload: string): string => {
    payloads.push(payload.split(PAYLOAD_MARK).join(markToken));
    return `${PAYLOAD_MARK}${payloads.length - 1}${PAYLOAD_MARK}`;
  };

  const source = boundedPreviewSource(markdown, MAX_PREVIEW_SOURCE);
  let text = source.text.split(PAYLOAD_MARK).join(markToken);
  text = takeFencedCode(text, stash, source.truncated);
  // The closing heading marker is recognized before inline formatting changes the line.
  text = stripClosingHeadingMarks(text, source.truncated);
  text = takeInlineCode(text, stash);
  text = takeEscapes(text, stash);
  // Autolinks may hold stashed escapes; flatten only those literal payloads.
  text = takeLinks(text)
    .replace(/<([A-Za-z][A-Za-z0-9+.-]{1,31}:[^<>\s]*)>/g, (_whole: string, url: string): string => stash(restore(url)))
    .replace(/<([^<>\s]+@[^<>\s]+\.[^<>\s]+)>/g, (_whole: string, email: string): string => stash(restore(email)));
  text = stripUnderscoreEmphasis(stripHtmlTags(text));
  text = flattenTableRows(text)
    .replace(/^\s*(?:\*\*[ \t]*\*\*|\*[ \t]+\*)\s*$/, '')
    .replace(/(\*\*)(?=\S)(.*?\S)\1/g, '$2')
    .replace(/(\*)(?=\S)([^*\n]*[^*\s])\1/g, '$2')
    .replace(/~~(.*?)~~/g, '$1');
  // Entities decode last, outside stashed code, so `&amp;` in code stays literal.
  text = text.replace(new RegExp(`[^${PAYLOAD_MARK}]+`, 'g'),
    (part: string): string => decodeHtmlEntities(part).split(PAYLOAD_MARK).join(markToken));
  return restore(text).replace(/\s+/g, ' ').trim();
}

/** `# heading ###` keeps the words and one trailing blank. */
function stripClosingHeadingMarks(text: string, truncated: boolean): string {
  const marker = /(^|\n)( {0,3}#{1,6}(?=[ \t])[^\n]*?)[ \t]#+[ \t]*(?=\n|$)/g;
  return text.replace(marker, (whole: string, lineStart: string, heading: string): string =>
    truncated && text.endsWith(whole) ? whole : `${lineStart}${heading} `);
}

const OPEN_FENCE_LINE = /^ {0,3}(`{3,}|~{3,})(.*)$/;

/** Fenced code becomes one stashed payload; an unclosed fence under truncation keeps its body. */
function takeFencedCode(text: string, stash: (payload: string) => string, truncated: boolean): string {
  const lines = text.split('\n');
  const out: string[] = [];
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i] ?? '';
    const open = OPEN_FENCE_LINE.exec(line);
    const marker = open?.[1];
    if (marker === undefined || marker === null) {
      out.push(line);
      continue;
    }
    const fenceChar = marker[0];
    if (fenceChar === '`' && (open?.[2] ?? '').includes('`')) {
      out.push(line);
      continue;
    }
    const body: string[] = [];
    let closed = false;
    // Blank-info fence lines are the only closers.
    let sawCloser = false;
    let j = i + 1;
    for (; j < lines.length; j += 1) {
      const close = OPEN_FENCE_LINE.exec(lines[j] ?? '');
      const closeMarker = close?.[1];
      if (closeMarker !== undefined && closeMarker !== null && (close?.[2] ?? '').trim() === '') {
        sawCloser = true;
        if (closeMarker[0] === fenceChar && closeMarker.length >= marker.length) {
          closed = true;
          break;
        }
      }
      body.push(lines[j] ?? '');
    }
    if (!closed) {
      if (truncated && j === lines.length) {
        out.push(stash(body.join('\n')));
        break;
      }
      out.push(line);
      if (!sawCloser) {
        for (let k = i + 1; k < lines.length; k += 1) {
          out.push(lines[k] ?? '');
        }
        break;
      }
      continue;
    }
    out.push(stash(body.join('\n')));
    i = j;
  }
  return out.join('\n');
}

function takeInlineCode(text: string, stash: (payload: string) => string): string {
  let out = '';
  let i = 0;
  while (i < text.length) {
    if (text[i] !== '`') {
      out += text[i];
      i += 1;
      continue;
    }
    let n = 0;
    while (text[i + n] === '`') {
      n += 1;
    }
    const close = findInlineCodeClose(text, i + n, n);
    if (close === -1) {
      out += text.slice(i, i + n);
      i += n;
      continue;
    }
    out += stash(text.slice(i + n, close));
    i = close + n;
  }
  return out;
}

export function findInlineCodeClose(text: string, from: number, n: number): number {
  for (let i = from; i < text.length; i += 1) {
    if (text[i] !== '`') {
      continue;
    }
    let m = 0;
    while (text[i + m] === '`') {
      m += 1;
    }
    if (m === n) {
      return i;
    }
    i += m - 1;
  }
  return -1;
}

function takeEscapes(text: string, stash: (payload: string) => string): string {
  return text.replace(/\\([!"#$%&'()*+,\-./:;<=>?@[\\\]^_`{|}~])/g,
    (_whole: string, ch: string): string => stash(ch));
}

function takeLinks(text: string): string {
  const closeBracket = closerAt(text, '[', ']');
  const closeParen = closerAt(text, '(', ')');
  let out = '';
  let i = 0;
  while (i < text.length) {
    const image = text.startsWith('![', i);
    if (image || text[i] === '[') {
      const open = image ? i + 1 : i;
      const labelEnd = closeBracket[open];
      if (labelEnd !== undefined && text[labelEnd + 1] === '(') {
        const destEnd = closeParen[labelEnd + 1];
        if (destEnd !== undefined) {
          out += text.slice(open + 1, labelEnd);
          i = destEnd + 1;
          continue;
        }
      }
    }
    out += text[i];
    i += 1;
  }
  return out;
}

function closerAt(text: string, open: string, close: string): (number | undefined)[] {
  const closeAt: (number | undefined)[] = new Array<number | undefined>(text.length).fill(undefined);
  const stack: number[] = [];
  for (let i = 0; i < text.length; i += 1) {
    if (text[i] === '\\') {
      i += 1;
      continue;
    }
    if (text[i] === open) {
      stack.push(i);
    } else if (text[i] === close) {
      const start = stack.pop();
      if (start !== undefined) {
        closeAt[start] = i;
      }
    }
  }
  return closeAt;
}

/** Matching `>` for a tag at `<`, ignoring `>` inside quoted attributes. */
function htmlTagClose(text: string, open: number): number {
  if (text.startsWith('<!--', open)) {
    const close = text.indexOf('-->', open + 4);
    return close === -1 ? text.length - 1 : close + 2;
  }
  let quote = '';
  let gtInOpenQuote = -1;
  for (let i = open + 1; i < text.length; i += 1) {
    const ch = text[i];
    if (quote !== '') {
      if (ch === quote) {
        quote = '';
        gtInOpenQuote = -1;
        continue;
      }
      if (ch === '>' && gtInOpenQuote === -1) {
        gtInOpenQuote = i;
      }
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      continue;
    }
    if (ch === '>') {
      return i;
    }
  }
  if (gtInOpenQuote !== -1) {
    return gtInOpenQuote;
  }
  return quote !== '' && text.length > open + 1 ? text.length - 1 : -1;
}

const HTML_TAG_START =
  /(?:[!?]|\/?[A-Za-z][A-Za-z0-9-]*(?:[/>]|\s+(?:[/>]|[A-Za-z_:@][^\s"'<>/=&]*(?:[\s=/>]|$))))/y;

function isHtmlTagStart(text: string, at: number): boolean {
  HTML_TAG_START.lastIndex = at + 1;
  return HTML_TAG_START.test(text);
}

function stripHtmlTags(text: string): string {
  let out = '';
  let i = 0;
  while (i < text.length) {
    if (text[i] === '<' && isHtmlTagStart(text, i)) {
      const close = htmlTagClose(text, i);
      if (close !== -1) {
        out += ' ';
        i = close + 1;
        continue;
      }
    }
    out += text[i];
    i += 1;
  }
  return out;
}

/** Pair `_` delimiter runs once, with CommonMark flanking. */
function stripUnderscoreEmphasis(text: string): string {
  interface Delimiter {
    start: number;
    end: number;
    removed: number;
  }
  const delimiters: Delimiter[] = [];
  const openers: Delimiter[] = [];
  let previousEnd = 0;
  const runs = /_+/g;
  let match = runs.exec(text);
  while (match !== null) {
    const start = match.index;
    const end = start + match[0].length;
    if (text.slice(previousEnd, start).includes('\n')) {
      openers.length = 0;
    }
    previousEnd = end;
    const delimiter: Delimiter = { start: start, end: end, removed: 0 };
    delimiters.push(delimiter);
    // Two UTF-16 units preserve astral letters when checking each adjacent code point.
    const before = text.slice(Math.max(0, start - 2), start);
    const after = text.slice(end, end + 2);
    const canClose = !/^[\p{L}\p{N}\p{M}]/u.test(after) && /\S$/u.test(before);
    let remaining = end - start;
    while (canClose && remaining > 0 && openers.length > 0) {
      const opener = openers[openers.length - 1];
      if (opener === undefined) {
        break;
      }
      const available = opener.end - opener.start - opener.removed;
      const paired = Math.min(available, remaining);
      opener.removed += paired;
      delimiter.removed += paired;
      remaining -= paired;
      if (paired === available) {
        openers.pop();
      }
    }
    if (remaining > 0 && !/[\p{L}\p{N}\p{M}]$/u.test(before) && /^\S/u.test(after)) {
      openers.push(delimiter);
    }
    match = runs.exec(text);
  }
  const parts: string[] = [];
  let from = 0;
  for (const delimiter of delimiters) {
    if (delimiter.removed === 0) {
      continue;
    }
    parts.push(text.slice(from, delimiter.start));
    parts.push('_'.repeat(delimiter.end - delimiter.start - delimiter.removed));
    from = delimiter.end;
  }
  parts.push(text.slice(from));
  return parts.join('');
}

const TABLE_ROW = /^\s*\|(.+)\|\s*$/;

/** Every GFM delimiter cell needs at least one hyphen. */
function isTableSeparator(line: string): boolean {
  const trimmed = line.trim();
  if (!trimmed.includes('-')) {
    return false;
  }
  return trimmed.replace(/^\|/, '').replace(/\|$/, '').split('|')
    .every((cell: string): boolean => /^:?-+:?$/.test(cell.trim()));
}

/** Heading, quote, list and break markers; the line's own text survives. */
function stripLineMarker(line: string): string {
  const stripped = line
    .replace(/^\s{0,3}#{1,6}\s+/, '')
    .replace(/^\s*>\s?/, '')
    .replace(/^\s*[-*+]\s+(?:\[[ xX]\](?:\s+|$))?/, '')
    .replace(/^\s*\d+[.)]\s+(?:\[[ xX]\](?:\s+|$))?/, '');
  return /^\s*[-*_]{3,}\s*$/.test(stripped) ? '' : stripped;
}

/** Row text to "a, b"; edge pipes only produce empty ends, which drop out. */
function tableCellsOf(line: string): string {
  return line.split('|').map((cell: string): string => cell.trim())
    .filter((cell: string): boolean => cell !== '').join(', ');
}

/** One line per table row; a marked line ends the table, a pipe-wrapped row still flattens. */
function flattenTableRows(text: string): string {
  const out: string[] = [];
  let inTable = false;
  let prevHadPipe = false;
  let prevFlattened = false;
  for (const rawLine of text.split('\n')) {
    const line = stripLineMarker(rawLine);
    if (line !== rawLine) {
      inTable = false;
      prevHadPipe = false;
      prevFlattened = false;
      if (!isTableSeparator(line)) {
        out.push(TABLE_ROW.test(line) ? tableCellsOf(line) : line);
      }
      continue;
    }
    if (!line.includes('|')) {
      inTable = false;
      prevHadPipe = false;
      prevFlattened = false;
      out.push(line);
      continue;
    }
    if (inTable) {
      out.push(tableCellsOf(line));
      prevHadPipe = true;
      prevFlattened = true;
      continue;
    }
    if (isTableSeparator(line)) {
      if (prevHadPipe) {
        inTable = true;
        if (!prevFlattened) {
          out[out.length - 1] = tableCellsOf(out[out.length - 1] ?? '');
        }
      }
      continue;
    }
    if (TABLE_ROW.test(line)) {
      out.push(tableCellsOf(line));
      prevFlattened = true;
    } else {
      out.push(line);
      prevFlattened = false;
    }
    prevHadPipe = true;
  }
  return out.join('\n');
}
