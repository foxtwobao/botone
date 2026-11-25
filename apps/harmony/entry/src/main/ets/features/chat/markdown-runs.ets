// A markdown node's inline content as flat styled runs (M5). ArkTS's Span takes no children, so
// nested emphasis (bold inside italic, a link inside bold) cannot nest components: the tree is
// flattened here, each run carrying the styles it inherits. Pure: no ArkUI, so the hypium render
// test replays it.
import { sanitizeMarkdownUrl } from '../../thread/message-links';
import type { MdNode } from '../../thread/markdown-types';

/** One piece of text with the styles every enclosing node gives it. */
export interface TextRun {
  text: string;
  bold: boolean;
  italic: boolean;
  strike: boolean;
  code: boolean;
  /** Where a tap opens: the destination of a link the app may follow, else empty (plain text). */
  href: string;
}

/** The styles enclosing the node being flattened. */
interface RunStyle {
  bold: boolean;
  italic: boolean;
  strike: boolean;
  code: boolean;
  href: string;
}

function wordsOf(node: MdNode): string {
  if (node.type === 'text' || node.type === 'code') {
    return node.text;
  }
  const parts: string[] = [];
  for (const child of node.children) {
    parts.push(wordsOf(child));
  }
  return parts.join('');
}

function pushRun(runs: TextRun[], text: string, style: RunStyle): void {
  if (text === '') {
    return;
  }
  const previous = runs[runs.length - 1];
  // Neighbouring runs with the same styles read as one: fewer spans to draw.
  if (previous !== undefined && previous.bold === style.bold && previous.italic === style.italic
    && previous.strike === style.strike && previous.code === style.code && previous.href === style.href) {
    previous.text += text;
    return;
  }
  const run: TextRun = {
    text: text, bold: style.bold, italic: style.italic, strike: style.strike, code: style.code, href: style.href,
  };
  runs.push(run);
}

function flattenInto(node: MdNode, style: RunStyle, runs: TextRun[]): void {
  if (node.type === 'text') {
    pushRun(runs, node.text, style);
    return;
  }
  if (node.type === 'br' || node.type === 'softbr') {
    // A soft break (a single newline in the source) reads as a space, as mobile shows it; two
    // trailing spaces or a backslash make a hard one.
    pushRun(runs, node.type === 'br' ? '\n' : ' ', style);
    return;
  }
  if (node.type === 'code') {
    const codeStyle: RunStyle = {
      bold: style.bold, italic: style.italic, strike: style.strike, code: true, href: style.href,
    };
    pushRun(runs, node.text, codeStyle);
    return;
  }
  if (node.type === 'img') {
    // No image surface in M5: the alternative text stands in for it.
    pushRun(runs, wordsOf(node), style);
    return;
  }
  if (node.type === 'a' || node.type === 'video') {
    // Only a link the app can open reads as one. The others stay the words they wrap: a page or a
    // bot profile has no screen to open yet, and a scheme the app may not follow opens nothing.
    const linkStyle: RunStyle = {
      bold: style.bold, italic: style.italic, strike: style.strike, code: style.code,
      href: sanitizeMarkdownUrl(node.href) ?? '',
    };
    for (const child of node.children) {
      flattenInto(child, linkStyle, runs);
    }
    return;
  }
  const next: RunStyle = {
    bold: style.bold || node.type === 'strong',
    italic: style.italic || node.type === 'em',
    strike: style.strike || node.type === 'del',
    code: style.code,
    href: style.href,
  };
  for (const child of node.children) {
    flattenInto(child, next, runs);
  }
}

/** The inline content of `node` (a paragraph, heading, cell…) as styled runs, in order. */
export function inlineRuns(node: MdNode): TextRun[] {
  const runs: TextRun[] = [];
  const root: RunStyle = { bold: false, italic: false, strike: false, code: false, href: '' };
  for (const child of node.children) {
    flattenInto(child, root, runs);
  }
  return runs;
}
