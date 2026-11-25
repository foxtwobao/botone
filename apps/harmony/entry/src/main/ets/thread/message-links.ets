// Plain text cut into text, links and page links (M5), ported from chat-ui's markdown module:
// user bubbles stay plain text except a page link, and bare http(s) addresses and e-mail
// addresses become links, as the web renderer's autolinks find them. chat-ui finds them with
// linkify-it; this port runs that library's patterns (link-patterns.generated.ets) through its
// scan, so the two agree on where an address starts and ends.
import {
  LINK_EMAIL,
  LINK_EMAIL_FLAGS,
  LINK_HTTP_TAIL,
  LINK_HTTP_TAIL_FLAGS,
  LINK_MAILTO_TAIL,
  LINK_MAILTO_TAIL_FLAGS,
  LINK_SCHEMA_SEARCH,
  LINK_SCHEMA_SEARCH_FLAGS,
} from './link-patterns.generated';

export interface PlainTextPart {
  type: string;
  value: string;
  /** A link's href, or a page link's page id. */
  href: string;
}

const PLAIN_PAGE_LINK = /\[((?:\\[\\[\]]|[^\\\[\]\n]){0,400})\]\(page:([A-Za-z0-9_-]{1,64})\)/g;
const SCHEMA_SEARCH = new RegExp(LINK_SCHEMA_SEARCH, LINK_SCHEMA_SEARCH_FLAGS);
/** What may follow each scheme the linkifier keeps (it drops `ftp:` and `//`). */
const TAILS: Record<string, RegExp> = {
  'http:': new RegExp(LINK_HTTP_TAIL, LINK_HTTP_TAIL_FLAGS),
  'https:': new RegExp(LINK_HTTP_TAIL, LINK_HTTP_TAIL_FLAGS),
  'mailto:': new RegExp(LINK_MAILTO_TAIL, LINK_MAILTO_TAIL_FLAGS),
};
const EMAIL = new RegExp(LINK_EMAIL, LINK_EMAIL_FLAGS);

/**
 * User bubbles stay plain text: markdown remains characters, except a page link, which opens the
 * page as it does in bot messages. Bare http(s) and mailto runs become links.
 */
export function plainTextLinkParts(text: string): PlainTextPart[] {
  const parts: PlainTextPart[] = [];
  let cursor = 0;
  PLAIN_PAGE_LINK.lastIndex = 0;
  let match = PLAIN_PAGE_LINK.exec(text);
  while (match !== null) {
    if (match.index > cursor) {
      appendUrlParts(parts, text.slice(cursor, match.index));
    }
    parts.push({ type: 'page', value: (match[1] ?? '').replace(/\\([\\[\]])/g, '$1'), href: match[2] ?? '' });
    cursor = match.index + match[0].length;
    match = PLAIN_PAGE_LINK.exec(text);
  }
  if (cursor === 0) {
    return urlLinkParts(text);
  }
  if (cursor < text.length) {
    appendUrlParts(parts, text.slice(cursor));
  }
  return parts;
}

function appendPlainText(parts: PlainTextPart[], value: string): void {
  if (value === '') {
    return;
  }
  const previous = parts[parts.length - 1];
  if (previous !== undefined && previous.type === 'text') {
    previous.value += value;
    return;
  }
  parts.push({ type: 'text', value: value, href: '' });
}

function appendUrlParts(parts: PlainTextPart[], text: string): void {
  for (const part of urlLinkParts(text)) {
    if (part.type === 'text') {
      appendPlainText(parts, part.value);
    } else {
      parts.push(part);
    }
  }
}

export interface UrlMatch {
  index: number;
  end: number;
  /** The address as written. */
  url: string;
  /** The scheme it opens with (`http:`, `https:` or `mailto:`), as the linkifier names it. */
  schema: string;
  /** Where it opens: the address with its scheme added, as the linkifier normalizes it. */
  href: string;
}

/**
 * Bare http(s) URLs and e-mail addresses, where the web renderer's GFM autolinks find them: the
 * two scans linkify-it runs, each one pass over the text, and its choice between what they find
 * (the earliest start; the longer one when two start at the same place). Which characters belong
 * to an address is the patterns' decision (a balanced parenthesis stays inside a URL; `(`, `)`
 * and punctuation that are not part of one stay out). Fuzzy domains stay text (a file name like
 * setup.py must not link); ftp and protocol-relative URLs stay text because sanitizeMarkdownUrl
 * would not open them.
 */
export function explicitLinkMatches(text: string): UrlMatch[] {
  const schemed: UrlMatch[] = [];
  const emails: UrlMatch[] = [];
  // Nothing the patterns read crosses a blank or control character, so for one candidate it is
  // enough to read to the next one: a window ending there answers for the whole text. A run with
  // no blank at all is read in windows of TAIL_WINDOW characters, settled by `runHoldsNoCloser`
  // when it can be, and by the whole run when it cannot.
  let closerOrBlank: Int32Array | null = null;
  const runHoldsNoCloser = (from: number): boolean => {
    if (closerOrBlank === null) {
      const table = new Int32Array(text.length);
      let next = -1;
      for (let off = text.length - 1; off >= 0; off -= 1) {
        table[off] = next;
        const ch = text.charCodeAt(off);
        if (isCloserChar(ch) || isBlankChar(ch)) {
          next = off;
        }
      }
      closerOrBlank = table;
    }
    const at = closerOrBlank[from];
    return at < 0 || isBlankChar(text.charCodeAt(at));
  };
  const tailEndOf = (pos: number, tail: RegExp): number => tailEnd(text, pos, tail, runHoldsNoCloser);
  // Addresses with a scheme. One may only start after the beginning, a separator or a blank;
  // what follows is then checked once per candidate, from where the scheme ends. A candidate
  // starting inside an address already found is dropped when the two scans are merged below, so
  // its tail is never checked: on a wall of repeated addresses, one long match stands for all.
  let covered = 0;
  SCHEMA_SEARCH.lastIndex = 0;
  let found = SCHEMA_SEARCH.exec(text);
  while (found !== null) {
    const schema = (found[2] ?? '').toLowerCase();
    const tail = TAILS[schema];
    const start = found.index + found[1].length;
    if (tail !== undefined && start >= covered) {
      const end = tailEndOf(found.index + found[0].length, tail);
      if (end > 0) {
        schemed.push(address(text, start, end, schema));
        covered = end;
      }
    }
    found = SCHEMA_SEARCH.exec(text);
  }
  // Addresses written without `mailto:`; group 1 is the character before the address.
  EMAIL.lastIndex = 0;
  found = EMAIL.exec(text);
  while (found !== null) {
    emails.push(address(text, found.index + found[1].length, found.index + found[0].length, 'mailto:'));
    found = EMAIL.exec(text);
  }
  return earliestFirst(schemed, emails);
}

/**
 * Where the address whose scheme ends at `pos` ends, or -1 when there is none. The tail is matched
 * on a window of the text; a window that ends at a blank (or at the end of the text) is the whole
 * answer, because nothing the pattern reads crosses one. A window cut short of a blank is the
 * answer only when the rest of the run holds no closing character at all, so no bracketed group
 * the pattern tried could have closed beyond the window; otherwise the whole run settles it.
 */
function tailEnd(text: string, pos: number, tail: RegExp,
  runHoldsNoCloser: (from: number) => boolean): number {
  const size = text.length;
  const cap = Math.min(size, pos + TAIL_WINDOW);
  let windowEnd = pos;
  while (windowEnd < cap && !isBlankChar(text.charCodeAt(windowEnd))) {
    windowEnd += 1;
  }
  const window = text.slice(pos, windowEnd);
  tail.lastIndex = 0;
  const matched = tail.exec(window) !== null;
  // `windowEnd < cap` says the window ended at a blank; `cap === size` says it ended with the text.
  if (windowEnd < cap || cap === size) {
    return matched ? pos + tail.lastIndex : -1;
  }
  // A window cut short of a blank answers for the run when nothing in it can close a bracketed
  // group (each such group then fails on the whole run as it did here) and the match ends away
  // from the cut, where the pattern's greed cannot have stopped only because the window did.
  if (runHoldsNoCloser(pos) && (!matched || tail.lastIndex + TAIL_EDGE < window.length)) {
    return matched ? pos + tail.lastIndex : -1;
  }
  tail.lastIndex = pos;
  return tail.exec(text) !== null ? tail.lastIndex : -1;
}

/** A blank or control character (the `Cc` and `Z` classes the patterns blank at). */
function isBlankChar(ch: number): boolean {
  return ch <= 0x1f || (ch >= 0x7f && ch <= 0x9f) || ch === 0x20 || ch === 0xa0 || ch === 0x1680
    || (ch >= 0x2000 && ch <= 0x200a) || ch === 0x2028 || ch === 0x2029 || ch === 0x202f
    || ch === 0x205f || ch === 0x3000;
}

/** A character that closes a bracketed group in a path: `)`, `]`, `}`, `"` or `'`. */
function isCloserChar(ch: number): boolean {
  return ch === 41 || ch === 93 || ch === 125 || ch === 34 || ch === 39;
}

/** How far a tail is read before its answer must be settled by the whole run. */
const TAIL_WINDOW = 1024;

/** How far from the cut a match must end for the window to stand without checking the run. */
const TAIL_EDGE = 8;

/** An address and where it opens: the linkifier adds the scheme of one written without it. */
function address(text: string, index: number, end: number, schema: string): UrlMatch {
  const url = text.slice(index, end);
  return {
    index: index,
    end: end,
    url: url,
    schema: schema,
    href: schema === 'mailto:' && !/^mailto:/i.test(url) ? `mailto:${url}` : url,
  };
}

/**
 * linkify-it's choice between the two scans: both lists are in text order, and of the two
 * candidates at their heads the one that starts earlier is taken, the longer one when they start
 * at the same place. A candidate inside the one taken before it is dropped.
 */
function earliestFirst(schemed: UrlMatch[], emails: UrlMatch[]): UrlMatch[] {
  const out: UrlMatch[] = [];
  let next = 0;
  let nextEmail = 0;
  let lastEnd = 0;
  while (next < schemed.length || nextEmail < emails.length) {
    const url = schemed[next];
    const mail = emails[nextEmail];
    const takeMail = mail !== undefined && (url === undefined || mail.index < url.index
      || (mail.index === url.index && mail.end >= url.end));
    const taken = takeMail ? mail : url;
    if (takeMail) {
      nextEmail += 1;
    } else {
      next += 1;
    }
    if (taken.end <= taken.index || taken.index < lastEnd) {
      continue;
    }
    out.push(taken);
    lastEnd = taken.end;
  }
  return out;
}

function urlLinkParts(text: string): PlainTextPart[] {
  const matches = explicitLinkMatches(text);
  if (matches.length === 0) {
    return [{ type: 'text', value: text, href: '' }];
  }
  const parts: PlainTextPart[] = [];
  let cursor = 0;
  for (const match of matches) {
    const value = match.url;
    const href = sanitizeMarkdownUrl(match.href);
    appendPlainText(parts, text.slice(cursor, match.index));
    if (href === undefined) {
      appendPlainText(parts, value);
      cursor = match.end;
      continue;
    }
    parts.push({ type: 'link', value: value, href: href });
    cursor = match.end;
  }
  appendPlainText(parts, text.slice(cursor));
  return parts.length > 0 ? parts : [{ type: 'text', value: text, href: '' }];
}

const PROTOCOL_PATTERN = /^([a-z][a-z\d+.-]*):/i;
const SAFE_PROTOCOLS: string[] = ['http', 'https', 'mailto', 'tel'];

export function sanitizeMarkdownUrl(url: string, allowRelative = false): string | undefined {
  const value = url.trim();
  const protocol = PROTOCOL_PATTERN.exec(value)?.[1]?.toLowerCase();
  if (protocol) {
    return SAFE_PROTOCOLS.includes(protocol) ? value : undefined;
  }
  if (allowRelative && (value.startsWith('/') || value.startsWith('./')
    || value.startsWith('../') || value.startsWith('#'))) {
    return value;
  }
  return undefined;
}
