// What a voice reads (M7): a port of core's calls/speech-text.ts. speakable turns Markdown into one
// line a voice can read (the prose, named artifacts, no syntax), splitSentences and toUtterances
// cut it into the pieces a synthesizer starts on, and speechFromBlocks picks a message's own
// words, never its tool activity. Pure; the layer-2 voice fixture is generated from the real core
// module and replayed under hypium. narrateTool, sentenceKey and spokenDecision serve calls and
// are not ported.
import type { Blocks } from '../thread/message-text';

/** A fenced block becomes a mention of itself, with its language if known (core describeCodeBlock). */
const SPOKEN_LANGUAGES: Record<string, string> = {};
SPOKEN_LANGUAGES['ts'] = 'TypeScript';
SPOKEN_LANGUAGES['tsx'] = 'TypeScript';
SPOKEN_LANGUAGES['js'] = 'JavaScript';
SPOKEN_LANGUAGES['jsx'] = 'JavaScript';
SPOKEN_LANGUAGES['py'] = 'Python';
SPOKEN_LANGUAGES['sh'] = 'shell';
SPOKEN_LANGUAGES['bash'] = 'shell';
SPOKEN_LANGUAGES['zsh'] = 'shell';
SPOKEN_LANGUAGES['json'] = 'JSON';
SPOKEN_LANGUAGES['yml'] = 'YAML';
SPOKEN_LANGUAGES['yaml'] = 'YAML';
SPOKEN_LANGUAGES['sql'] = 'SQL';
SPOKEN_LANGUAGES['rs'] = 'Rust';
SPOKEN_LANGUAGES['go'] = 'Go';
SPOKEN_LANGUAGES['swift'] = 'Swift';
SPOKEN_LANGUAGES['diff'] = 'diff';

function describeCodeBlock(fence: string): string {
  const first = fence.trim().split(/\s+/)[0] ?? '';
  const lang = first.replace(/[^a-z0-9+#]/gi, '').toLowerCase();
  const name = SPOKEN_LANGUAGES[lang];
  return name !== undefined ? `. (a ${name} code block) ` : '. (a code block) ';
}

const PATH_LIKE = /[\w.@/-]+/g;
const FILE_PATH = /(?:[\w.@-]+\/)+([\w.-]+\.\w{1,6})\b/g;
/** Short enough that FILE_PATH's backtracking stays cheap; a longer run keeps only a file name. */
const MAX_PATH_LENGTH = 512;
const FILE_NAME = /^[\w.-]+\.\w{1,6}$/;

/** `a/b/c/file.ts` → `file.ts`. A path's directories are for the eye. */
function shortenPaths(text: string): string {
  return text.replace(PATH_LIKE, (run: string): string => {
    if (run.length <= MAX_PATH_LENGTH) {
      return run.replace(FILE_PATH, '$1');
    }
    const name = run.slice(run.lastIndexOf('/') + 1);
    return name !== run && FILE_NAME.test(name) ? name : run;
  });
}

const ENDS_SENTENCE = /[.!?:;]\s*$/;

const WORD_CHAR = /[\p{L}\p{N}]/u;
const SPACE = /\s/u;
const LINE_END = /[\n\r\u2028\u2029]/;

/**
 * `*word*` and `_word_` → `word`, leaving `snake_case` and `2*3` alone. A marker opens when it
 * follows no letter or digit and precedes a non-space; it closes at the nearest same marker on
 * that line that follows a non-space and precedes no letter or digit. The nearest closer is
 * precomputed for each position so the scan stays linear in the input.
 */
function stripSingleEmphasis(text: string): string {
  const chars = Array.from(text);
  const n = chars.length;
  const isWordChar = (k: number): boolean => k >= 0 && k < n && WORD_CHAR.test(chars[k] ?? '');
  const isCloser = (char: string, marker: string, k: number, before: string): boolean =>
    char === marker && k > 0 && !SPACE.test(before) && before !== marker && !isWordChar(k + 1);
  const nextStar = new Int32Array(n + 1).fill(-1);
  const nextUnder = new Int32Array(n + 1).fill(-1);
  for (let k = n - 1; k >= 0; k--) {
    const char = chars[k] ?? '';
    const before = k > 0 ? chars[k - 1] ?? ' ' : ' ';
    // A closer is sought on the opener's own line: a line end leaves nothing to find before it.
    nextStar[k] = LINE_END.test(char) ? -1 : isCloser(char, '*', k, before) ? k : nextStar[k + 1];
    nextUnder[k] = LINE_END.test(char) ? -1 : isCloser(char, '_', k, before) ? k : nextUnder[k + 1];
  }
  let out = '';
  let i = 0;
  while (i < n) {
    const char = chars[i] ?? '';
    const next = char === '*' ? nextStar : char === '_' ? nextUnder : null;
    const ahead = chars[i + 1] ?? '';
    if (next !== null && !isWordChar(i - 1) && i + 1 < n && !SPACE.test(ahead) && ahead !== char) {
      const close = next[i + 1];
      if (close !== -1) {
        out += chars.slice(i + 1, close).join('');
        i = close + 1;
        continue;
      }
    }
    out += char;
    i += 1;
  }
  return out;
}

/** Markdown (or any agent output) as one line a voice can read. */
export function speakable(input: string): string {
  if (!input) {
    return '';
  }
  let text = input;
  text = text.replace(/```([^\n]*)\n[\s\S]*?(?:```|$)/g, (_whole: string, fence: string): string =>
    describeCodeBlock(fence));
  text = text.replace(/~~~([^\n]*)\n[\s\S]*?(?:~~~|$)/g, (_whole: string, fence: string): string =>
    describeCodeBlock(fence));
  text = text.replace(/!\[([^\]]*)\]\([^)]*\)/g, (_whole: string, alt: string): string =>
    alt ? `. (image: ${alt}) ` : '. (an image) ');
  text = text.replace(/\[([^\]]+)\]\([^)]*\)/g, '$1');
  text = text.replace(/<https?:\/\/[^>\s]+>/g, ' a link ');
  text = text.replace(/\bhttps?:\/\/\S+/g, ' a link ');
  text = text.replace(/^\s*\|?[\s:-]*\|[\s|:-]*$/gm, '');
  text = text.replace(/^\s*\|(.+)\|\s*$/gm, (_whole: string, row: string): string =>
    row.split('|').map((cell: string): string => cell.trim()).filter(Boolean).join(', '));
  text = text.replace(/`([^`\n]+)`/g, (_whole: string, code: string): string =>
    code.length <= 40 ? code : ' that snippet ');
  text = text.replace(/^\s{0,3}#{1,6}\s+(.*)$/gm, (_whole: string, head: string): string =>
    ENDS_SENTENCE.test(head) ? head : `${head.trim()}.`);
  text = text.replace(/^\s*(?:[-*_]\s*){3,}$/gm, '');
  text = text.replace(/^\s*[-*+]\s+/gm, '');
  text = text.replace(/^\s*\d+[.)]\s+/gm, '');
  text = text.replace(/^\s*>\s?/gm, '');
  text = text.replace(/(\*\*|__)(?=\S)(.*?\S)\1/g, '$2');
  text = stripSingleEmphasis(text);
  text = text.replace(/~~(.*?)~~/g, '$1');
  text = text.replace(/\[[ xX]\]\s*/g, '');
  text = shortenPaths(text);
  text = text.replace(
    /[\u{1F000}-\u{1FAFF}]|[\u{2600}-\u{27BF}]|[\u{FE00}-\u{FE0F}]|[\u{2190}-\u{21FF}\u{2B00}-\u{2BFF}]/gu,
    '',
  );
  text = text.replace(/\n{2,}/g, '. ');
  text = text.replace(/\n/g, '. ');
  text = text.replace(/\s+/g, ' ');
  text = text.replace(/\s+([.,!?;:])/g, '$1');
  text = text.replace(/(?:\.\s*){2,}/g, '. ');
  text = text.replace(/,\s*\./g, '.');
  text = text.trim();
  return /[\p{L}\p{N}]/u.test(text) ? text : '';
}

const BOUNDARY =
  /(?<!\b(?:e\.g|i\.e|etc|vs|Dr|Mr|Mrs|Ms|No|approx))(?<![.\d])([.!?])(["')\]]*)\s+/g;
// CJK sentences end with full-width marks and no following space. A full-width period after a
// digit is a decimal point in a number, not a sentence end.
const CJK_BOUNDARY = /((?:[。！？｡]|(?<!\p{N})．|…)+)(["'”’」』）】)\]]*)/gu;
const SENTENCE_MARK = '\u0000';

/** Markdown as the sentences a voice reads, one per item; a short sentence keeps its own identity. */
export function splitSentences(input: string): string[] {
  const marked = speakable(input)
    .replace(BOUNDARY, `$1$2${SENTENCE_MARK}`)
    .replace(CJK_BOUNDARY, `$1$2${SENTENCE_MARK}`);
  const out: string[] = [];
  for (const piece of marked.split(SENTENCE_MARK)) {
    if (piece.trim()) {
      out.push(piece.trim());
    }
  }
  return out;
}

/** A piece that starts or ends in a script written without spaces is glued with no space. */
const UNSPACED_EDGE =
  /^[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Thai}]|[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Thai}。！？｡．…」』）】”’]$/u;

/**
 * Speakable text as utterances a synthesizer can start on. Short fragments are glued onto their
 * neighbour so the voice keeps context. maxChars bounds UTF-16 code units.
 */
export function toUtterances(input: string, minChars: number = 12, maxChars: number = 320): string[] {
  if (!Number.isInteger(maxChars) || maxChars < 2) {
    throw new RangeError('maxChars must be an integer of at least 2');
  }
  const rough = splitSentences(input);
  const out: string[] = [];
  for (const piece of rough) {
    const parts = piece.length <= maxChars ? [piece] : splitLong(piece, maxChars);
    for (let index = 0; index < parts.length; index += 1) {
      const part = parts[index] ?? '';
      const prev = out.length > 0 ? out[out.length - 1] : undefined;
      if (index === 0 && prev !== undefined && (prev.length < minChars || part.length < minChars)
        && prev.length + 1 + part.length <= maxChars) {
        // Either unspaced edge joins without a blank.
        out[out.length - 1] =
          `${prev}${UNSPACED_EDGE.test(prev) || UNSPACED_EDGE.test(part) ? '' : ' '}${part}`;
      } else {
        out.push(part);
      }
    }
  }
  return out;
}

function splitLong(text: string, maxChars: number): string[] {
  const out: string[] = [];
  let rest = text;
  while (rest.length > maxChars) {
    const window = rest.slice(0, maxChars);
    const at = Math.max(window.lastIndexOf(', '), window.lastIndexOf('; '), window.lastIndexOf(' — '));
    let cut = at > maxChars / 2 ? at + 1 : window.lastIndexOf(' ');
    if (cut <= 0) {
      // shortcut: no grapheme splitting, only surrogate-pair safety. The ArkTS standard library
      // declares no Intl.Segmenter, so this is core's own fallback for such runtimes; a combining
      // cluster that straddles the budget can be cut. Upgrade if a voice misreads such a cut.
      cut = maxChars;
      const last = rest.charCodeAt(cut - 1);
      if (last >= 0xd800 && last <= 0xdbff) {
        cut -= 1;
      }
    }
    out.push(rest.slice(0, cut).trim());
    rest = rest.slice(cut).trim();
  }
  if (rest) {
    out.push(rest);
  }
  return out;
}

function isToolActivityBlock(block: Record<string, Object>): boolean {
  return block['kind'] === 'steps' || (block['kind'] === 'progress' && block['activity'] === true);
}

function text(block: Record<string, Object>, key: string): string {
  const value = block[key];
  return typeof value === 'string' ? value as string : '';
}

/** What a voice reads from a message: the bot's own words, never its tool activity. */
export function speechFromBlocks(blocks: Blocks): string {
  const parts: string[] = [];
  for (const block of blocks) {
    const kind = text(block, 'kind');
    if (isToolActivityBlock(block)) {
      continue;
    }
    if (kind === 'text' || kind === 'progress' || kind === 'meta' || kind === 'ask' || kind === 'computer') {
      parts.push(text(block, 'text'));
    } else if (kind === 'cloud_agent') {
      const prUrl = text(block, 'prUrl');
      parts.push(`${text(block, 'title')}: ${text(block, 'status')}${prUrl ? ` ${prUrl}` : ''}`);
    } else if (kind === 'subagent') {
      const name = text(block, 'name');
      const status = text(block, 'status');
      if (status === 'running') {
        parts.push(`${name} is working on ${text(block, 'task')}`);
      } else if (status === 'failed') {
        parts.push(`${name} failed`);
      } else {
        const result = text(block, 'result');
        parts.push(result || `${name} finished`);
      }
    } else if (kind === 'card') {
      const lines: string[] = [];
      const raw = block['lines'];
      if (Array.isArray(raw)) {
        for (const item of raw as Object[]) {
          const line = item !== null && typeof item === 'object' ? item as Record<string, Object> : null;
          if (line !== null) {
            lines.push(`${text(line, 'k')}: ${text(line, 'v')}`);
          }
        }
      }
      parts.push(lines.join('. '));
    }
  }
  const kept: string[] = [];
  for (const part of parts) {
    if (part) {
      kept.push(part);
    }
  }
  return kept.join('\n');
}
