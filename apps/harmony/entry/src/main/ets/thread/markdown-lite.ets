// markdown-lite (design §6.4, explicit Phase 1 scope): bot text renders paragraphs, headings,
// unordered/ordered lists, fenced code blocks, blockquotes, and inline bold / italic / inline
// code / links. Tables, images, mermaid and full commonmark are Phase 2+ — anything unrecognized
// renders as its literal text, never a crash. User bubbles stay plain text. The parser is pure
// (text → segments) so a fixture can pin it; the renderer maps segments to ArkUI Text/Span.

export interface InlineSpan {
  text: string;
  bold: boolean;
  italic: boolean;
  code: boolean;
  /** A link's href; empty for plain spans. */
  href: string;
}

export interface MarkdownSegment {
  /** paragraph | heading | list-item | code | quote */
  kind: string;
  /** heading level (1-6) or list marker ("•" / "1."); empty otherwise. */
  marker: string;
  spans: InlineSpan[];
  /** code block: the raw text, no inline parsing. */
  code: string;
}

function span(text: string, bold: boolean, italic: boolean, code: boolean, href: string): InlineSpan {
  const result: InlineSpan = { text: text, bold: bold, italic: italic, code: code, href: href };
  return result;
}

/** Parse inline bold/italic/code/links; unrecognized syntax stays literal. */
export function parseInline(text: string): InlineSpan[] {
  const spans: InlineSpan[] = [];
  let index = 0;
  let plain = '';
  const flush = (): void => {
    if (plain) {
      spans.push(span(plain, false, false, false, ''));
      plain = '';
    }
  };
  while (index < text.length) {
    const rest = text.slice(index);
    // [label](href) — a link; the label renders with the link color, tap opens the browser.
    const link = /^\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/.exec(rest);
    if (link !== null) {
      flush();
      spans.push(span(link[1], false, false, false, link[2]));
      index += link[0].length;
      continue;
    }
    // `code`
    if (rest.startsWith('`')) {
      const end = rest.indexOf('`', 1);
      if (end > 0) {
        flush();
        spans.push(span(rest.slice(1, end), false, false, true, ''));
        index += end + 1;
        continue;
      }
    }
    // **bold**
    if (rest.startsWith('**')) {
      const end = rest.indexOf('**', 2);
      if (end > 1) {
        flush();
        spans.push(span(rest.slice(2, end), true, false, false, ''));
        index += end + 2;
        continue;
      }
    }
    // *italic* (single star, not a list marker mid-line)
    if (rest.startsWith('*') && !rest.startsWith('**')) {
      const end = rest.indexOf('*', 1);
      if (end > 0) {
        flush();
        spans.push(span(rest.slice(1, end), false, true, false, ''));
        index += end + 1;
        continue;
      }
    }
    plain += text.charAt(index);
    index += 1;
  }
  flush();
  return spans;
}

function segment(kind: string, marker: string, text: string): MarkdownSegment {
  const result: MarkdownSegment = { kind: kind, marker: marker, spans: parseInline(text), code: '' };
  return result;
}

function codeSegment(code: string): MarkdownSegment {
  const result: MarkdownSegment = { kind: 'code', marker: '', spans: [], code: code };
  return result;
}

/** Split bot text into render segments; a fenced block consumes its lines verbatim. */
export function parseMarkdownLite(text: string): MarkdownSegment[] {
  const segments: MarkdownSegment[] = [];
  const lines = text.replace(/\r\n?/g, '\n').split('\n');
  let index = 0;
  let paragraph: string[] = [];
  const flushParagraph = (): void => {
    if (paragraph.length > 0) {
      segments.push(segment('paragraph', '', paragraph.join(' ')));
      paragraph = [];
    }
  };
  while (index < lines.length) {
    const line = lines[index];
    const trimmed = line.trim();
    if (trimmed.startsWith('```')) {
      flushParagraph();
      const code: string[] = [];
      index += 1;
      while (index < lines.length && !lines[index].trim().startsWith('```')) {
        code.push(lines[index]);
        index += 1;
      }
      index += 1; // closing fence (or EOF)
      segments.push(codeSegment(code.join('\n')));
      continue;
    }
    if (!trimmed) {
      flushParagraph();
      index += 1;
      continue;
    }
    const heading = /^(#{1,6})\s+(.*)$/.exec(trimmed);
    if (heading !== null) {
      flushParagraph();
      segments.push(segment('heading', `${heading[1].length}`, heading[2]));
      index += 1;
      continue;
    }
    const bullet = /^[-*•]\s+(.*)$/.exec(trimmed);
    if (bullet !== null) {
      flushParagraph();
      segments.push(segment('list-item', '•', bullet[1]));
      index += 1;
      continue;
    }
    const ordered = /^(\d+)[.)]\s+(.*)$/.exec(trimmed);
    if (ordered !== null) {
      flushParagraph();
      segments.push(segment('list-item', `${ordered[1]}.`, ordered[2]));
      index += 1;
      continue;
    }
    if (trimmed.startsWith('>')) {
      flushParagraph();
      segments.push(segment('quote', '', trimmed.replace(/^>\s?/, '')));
      index += 1;
      continue;
    }
    paragraph.push(trimmed);
    index += 1;
  }
  flushParagraph();
  return segments;
}

/** The plain text of a markdown-lite string (preview lines, accessibility). */
export function markdownPlainText(text: string): string {
  const segments = parseMarkdownLite(text);
  const parts: string[] = [];
  for (const segment of segments) {
    if (segment.kind === 'code') {
      parts.push(segment.code);
      continue;
    }
    let line = '';
    for (const span of segment.spans) {
      line += span.text;
    }
    parts.push(line);
  }
  return parts.join(' ').replace(/\s+/g, ' ').trim();
}
