// Plain text cut into text, links and page links (M5), ported from chat-ui's markdown module:
// user bubbles stay plain text except a page link, and bare http(s) addresses and e-mail
// addresses become links, as the web renderer's autolinks find them. The port follows linkify-it
// closely enough for message text (m5-notes records where it approximates).
export interface PlainTextPart {
  type: string;
  value: string;
  /** A link's href, or a page link's page id. */
  href: string;
}

const PLAIN_PAGE_LINK = /\[((?:\\[\\[\]]|[^\\\[\]\n]){0,400})\]\(page:([A-Za-z0-9_-]{1,64})\)/g;

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
  url: string;
}

/**
 * Bare http(s) URLs and e-mail addresses, as the web renderer's GFM autolinks find them: balanced
 * parentheses stay inside a URL; `(`, `)` and trailing punctuation not part of an address stay out.
 * Fuzzy domains stay text (a file name like setup.py must not link); ftp and protocol-relative
 * URLs stay text because sanitizeMarkdownUrl would not open them.
 */
export function explicitLinkMatches(text: string): UrlMatch[] {
  const out: UrlMatch[] = [];
  const length = text.length;
  let index = 0;
  while (index < length) {
    const at = linkStart(text, index);
    if (typeof at === 'number') {
      break;
    }
    const start = at[0];
    const kind = at[1];
    const end = linkEnd(text, start, kind);
    if (end <= start) {
      index = start + 1;
      continue;
    }
    out.push({ index: start, end: end, url: text.slice(start, end) });
    index = end;
  }
  return out;
}

/** Where the next explicit link starts: `-1`, or `[offset, kind]` (0 http(s), 1 e-mail). */
function linkStart(text: string, from: number): [number, number] | number {
  const length = text.length;
  for (let index = from; index < length; index += 1) {
    if (/^(?:https?):\/\//i.test(text.slice(index))) {
      return [index, 0];
    }
    if (mailtoAddressAt(text, index) > index) {
      return [index, 1];
    }
  }
  return -1;
}

/**
 * The e-mail address starting at `index`, if one does: `user@labels.tld`, its end offset (or the
 * offset itself when there is none). Mirrors linkify-it's mail rules closely enough for message
 * text: local part of letters, digits and `._%+-`, domain labels of letters, digits and hyphens.
 */
function mailtoAddressAt(text: string, index: number): number {
  const length = text.length;
  let end = index;
  while (end < length && /[A-Za-z0-9._%+-]/.test(text[end])) {
    end += 1;
  }
  if (end === index || end >= length || text[end] !== '@') {
    return index;
  }
  let domainEnd = end + 1;
  let labelEnd = domainEnd;
  while (domainEnd < length) {
    const ch = text[domainEnd];
    if (/[A-Za-z0-9-]/.test(ch)) {
      domainEnd += 1;
      labelEnd = domainEnd;
    } else if (ch === '.' && domainEnd > end + 1 && labelEnd > domainEnd - 1) {
      domainEnd += 1;
      labelEnd = domainEnd;
    } else {
      break;
    }
  }
  // A domain needs a dot and a label after it ("a@b" is prose, "x@y.co" is an address).
  const lastDot = text.lastIndexOf('.', labelEnd - 1);
  if (lastDot <= end || labelEnd - (lastDot + 1) < 2) {
    return index;
  }
  return labelEnd;
}

/** Where a link starting at `start` ends (0 when it is not one). */
function linkEnd(text: string, start: number, kind: number): number {
  const length = text.length;
  if (kind === 1) {
    return mailtoAddressAt(text, start);
  }
  const scheme = /^(?:https?):\/\//i.exec(text.slice(start))?.[0].length ?? 0;
  let index = start + scheme;
  let end = index;
  let depth = 0;
  while (index < length) {
    const ch = text[index];
    if (ch === '(') {
      depth += 1;
    } else if (ch === ')') {
      if (depth === 0) {
        break;
      }
      depth -= 1;
      // A balanced pair stays inside the address: keep both parens.
      end = index + 1;
      index += 1;
      continue;
    } else if (ch === ' ' || ch === '\t' || ch === '\r' || ch === '\n' || ch === '\u000b'
      || ch === '\u000c' || ch === '\u00a0' || ch === '\u3000' || ch === '>' || ch === '<') {
      // linkify-it ends a bare address at whitespace: full-width punctuation stays inside it,
      // so "x.com/a，then" links whole (the web renderer shows the same reach).
      break;
    }
    index += 1;
    if (depth === 0) {
      end = index;
    }
  }
  // Trailing punctuation not part of the address stays out; a `)` closes a `(` still inside the
  // address, so it stays too.
  let balance = 0;
  for (let i = start + scheme; i < end; i += 1) {
    if (text[i] === '(') {
      balance += 1;
    } else if (text[i] === ')') {
      balance -= 1;
    }
  }
  while (end > start) {
    const ch = text[end - 1];
    if (ch === ')' && balance < 0) {
      balance += 1;
      end -= 1;
      continue;
    }
    if (ch === '?' || ch === '!' || ch === ',' || ch === '.' || ch === ';' || ch === ':'
      || ch === '\u201d' || ch === '\u2019' || ch === '"' || ch === '\'' || ch === ']') {
      end -= 1;
    } else {
      break;
    }
  }
  if (end <= start + scheme) {
    return 0;
  }
  return end;
}

function urlLinkParts(text: string): PlainTextPart[] {
  const matches = explicitLinkMatches(text);
  if (matches.length === 0) {
    return [{ type: 'text', value: text, href: '' }];
  }
  const parts: PlainTextPart[] = [];
  let cursor = 0;
  for (const match of matches) {
    if (match.index < cursor || match.end <= match.index) {
      continue;
    }
    const value = text.slice(match.index, match.end);
    // An e-mail link opens its address: the scheme linkify-it adds for one.
    const href = match.url.includes('@') && !/^[a-z][a-z\d+.-]*:/i.test(match.url)
      ? `mailto:${match.url}`
      : sanitizeMarkdownUrl(match.url);
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
