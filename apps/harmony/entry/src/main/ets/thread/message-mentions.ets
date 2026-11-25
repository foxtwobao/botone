// Which @Name runs a message highlights (M5), ported from the shared packages: where a text
// names one of several names with `@` (core group-mentions, the sent-message rules), the targets
// a group message can name (mobile userMentionTargets), and a sent message cut into the runs the
// user bubble draws. A link (the plain-text link parts in message-links) is never searched for
// names.
import { displayName } from './message-text';
import { explicitLinkMatches, plainTextLinkParts } from './message-links';

export interface UserMentionTarget {
  kind: string;
  id: string;
  name: string;
  color: string;
}

export interface MentionTextPart {
  text: string;
  target: UserMentionTarget | null;
}

/** One run of a user's message as the bubble draws it. */
export interface UserTextRun {
  text: string;
  /** Where a tap opens: an address the app may follow. Empty for plain text, a mention, and a
 *  page link, which has no page to open yet and so reads as plain text. */
  href: string;
  /** The bot, or everyone, a mention names. */
  target: UserMentionTarget | null;
}

/** A group member as the mention rules read it. */
export interface MemberLike {
  botId: string;
  name: string;
  color: string;
}

/* ------------------------------- @Name mentions (core group-mentions) ------------------------------- */

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** CJK scripts, whose text runs straight on from a name, with the long-vowel mark. */
const CJK_CHAR = '[\\p{Script=Han}\\p{Script=Hiragana}\\p{Script=Katakana}\\p{Script=Hangul}\\u30fc\\uff70]';
const NAME_CHAR = `(?!${CJK_CHAR})[\\p{L}\\p{N}_-]`;
const WORD_CHAR = '[\\p{L}\\p{N}_-]';
const ENDS_IN_CJK = new RegExp(`${CJK_CHAR}$`, 'u');
const JOINS_BEFORE = new RegExp(`${NAME_CHAR}$`, 'u');
const JOINS_AFTER = new RegExp(`^${NAME_CHAR}`, 'u');
const JOINS_AFTER_CJK = new RegExp(`^${WORD_CHAR}`, 'u');

/** Whether a mention from `start` to `end` stands apart from the text around it. */
export function mentionStandsAlone(text: string, start: number, end: number): boolean {
  const tail = text.slice(end, end + 2);
  const joinsAfter = ENDS_IN_CJK.test(text.slice(Math.max(start, end - 2), end)) ? JOINS_AFTER_CJK : JOINS_AFTER;
  return !JOINS_BEFORE.test(text.slice(Math.max(0, start - 2), start)) && !joinsAfter.test(tail);
}

/** What may not follow `name` for a mention of it to end there. */
function nameEnd(name: string, runsOn: boolean): string {
  return !runsOn && ENDS_IN_CJK.test(name) ? WORD_CHAR : NAME_CHAR;
}

export interface MentionSpan {
  start: number;
  end: number;
  name: string;
}

/**
 * Where text names one of `names` with `@`. Each mention takes its longest name. A name in
 * `runsOn`, a word for everyone, may run straight into CJK text even when it ends in CJK.
 */
export function mentionSpans(text: string, names: string[], runsOn: string[] = []): MentionSpan[] {
  const unique: string[] = [];
  for (const raw of names) {
    const name = raw.trim();
    if (name !== '' && !unique.includes(name)) {
      unique.push(name);
    }
  }
  unique.sort((a: string, b: string): number => b.length - a.length);
  if (unique.length === 0) {
    return [];
  }
  const free: string[] = runsOn.map((name: string): string => name.trim().toLowerCase());
  const alternatives = unique
    .map((name: string): string => `${escapeRegExp(name)}(?!${nameEnd(name, free.includes(name.toLowerCase()))})`)
    .join('|');
  const pattern = new RegExp(`(?<!${NAME_CHAR})@(${alternatives})`, 'giu');
  const out: MentionSpan[] = [];
  let found = pattern.exec(text);
  while (found !== null) {
    const start = found.index;
    out.push({ start: start, end: start + found[0].length, name: found[1] ?? '' });
    found = pattern.exec(text);
  }
  return out;
}

/** Words that name every member. A member called "all" or "所有人" is named by that word instead. */
export function everyoneWords(memberNames: string[]): string[] {
  const taken = memberNames.map((name: string): string => name.trim().toLowerCase());
  const out = ['everyone'];
  for (const word of ['all', '所有人']) {
    if (!taken.includes(word)) {
      out.push(word);
    }
  }
  return out;
}

/** The names a group message mentions, as written, each read once with its longest name. */
export function groupMentionNames(text: string, memberNames: string[]): string[] {
  const words = everyoneWords(memberNames);
  return mentionSpans(text, [...words, ...memberNames], words)
    .filter((span: MentionSpan): boolean => {
      const word = span.name.toLowerCase();
      if (word === 'everyone' || !words.includes(word)) {
        return true;
      }
      const before = text[span.start - 1] ?? '';
      if (/[/\\.@+]/.test(before)) {
        return false;
      }
      if (/^[./\\][\p{L}\p{N}_-]/u.test(text.slice(span.end, span.end + 3))) {
        return false;
      }
      return !insideRanges(quotedRanges(text), span.start);
    })
    .map((span: MentionSpan): string => span.name);
}

/**
 * The targets a sent message can name (mobile userMentionTargets): the group's members, plus
 * everyone with two or more. A name two members share, or a bot named everyone, stays plain text.
 */
export function userMentionTargets(members: MemberLike[], text: string): UserMentionTarget[] {
  const names = members.map((member: MemberLike): string => displayName(member.name, 'Bot'));
  const written = groupMentionNames(text, names).map((name: string): string => name.toLowerCase());
  const everyone = members.length >= 2
    ? everyoneWords(names).filter((word: string): boolean => word === 'everyone' || written.includes(word))
    : [];
  const counts = new Map<string, number>();
  for (const word of everyone) {
    counts.set(word, 1);
  }
  for (const name of names) {
    const key = name.toLowerCase();
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  const targets: UserMentionTarget[] = [];
  for (const word of everyone) {
    targets.push({ kind: 'everyone', id: 'everyone', name: word, color: '' });
  }
  members.forEach((member: MemberLike, index: number): void => {
    if (counts.get(names[index].toLowerCase()) === 1) {
      targets.push({ kind: 'bot', id: member.botId, name: names[index], color: member.color });
    }
  });
  return targets;
}

/**
 * A sent message as the user bubble draws it, the way mobile's MessageCaption lays its linkified
 * text over splitMentionText: plain runs, the `@Name` runs that name a known target, and links.
 */
export function userTextRuns(text: string, targets: UserMentionTarget[]): UserTextRun[] {
  const runs: UserTextRun[] = [];
  for (const piece of plainTextLinkParts(text)) {
    if (piece.type === 'text') {
      for (const part of splitMentionText(piece.value, targets)) {
        const run: UserTextRun = { text: part.text, href: '', target: part.target };
        runs.push(run);
      }
    } else {
      // A page link is plain text until pages can open (it would draw as a link that does nothing).
      runs.push({ text: piece.value, href: piece.type === 'link' ? piece.href : '', target: null });
    }
  }
  return runs;
}

/** Text cut into plain runs and the `@Name` runs that name a known target. */
export function splitMentionText(text: string, targets: UserMentionTarget[]): MentionTextPart[] {
  const spans = mentionSpans(text, targets.map((target: UserMentionTarget): string => target.name),
    targets.filter((target: UserMentionTarget): boolean => target.kind === 'everyone')
      .map((target: UserMentionTarget): string => target.name))
    .map((span: MentionSpan): MentionSpan => {
      return { start: span.start, end: span.end, name: span.name.toLowerCase() };
    });
  if (spans.length === 0) {
    return [{ text: text, target: null }];
  }
  const parts: MentionTextPart[] = [];
  let index = 0;
  for (const span of spans) {
    const target = targets.find((candidate: UserMentionTarget): boolean =>
      candidate.name.trim().toLowerCase() === span.name);
    if (target === undefined) {
      continue;
    }
    if (span.start > index) {
      parts.push({ text: text.slice(index, span.start), target: null });
    }
    parts.push({ text: text.slice(span.start, span.end), target: target });
    index = span.end;
  }
  if (index < text.length) {
    parts.push({ text: text.slice(index), target: null });
  }
  return parts;
}

/* ------------------------------- quoted ranges for "all"/"所有人" ------------------------------- */

function insideRanges(ranges: [number, number][], position: number): boolean {
  let low = 0;
  let high = ranges.length - 1;
  while (low <= high) {
    const middle = (low + high) >> 1;
    const range = ranges[middle];
    if (position < range[0]) {
      high = middle - 1;
    } else if (position >= range[1]) {
      low = middle + 1;
    } else {
      return true;
    }
  }
  return false;
}

/** The code and link ranges in `text`, merged and in order. */
function quotedRanges(text: string): [number, number][] {
  const found: [number, number][] = [];
  collectCodeRanges(text, found);
  collectUrlRanges(text, found);
  collectLabeledLinkRanges(text, found);
  found.sort((a: [number, number], b: [number, number]): number => a[0] - b[0]);
  const merged: [number, number][] = [];
  for (const range of found) {
    const last = merged[merged.length - 1];
    if (last !== undefined && range[0] <= last[1]) {
      last[1] = Math.max(last[1], range[1]);
    } else {
      merged.push([range[0], range[1]]);
    }
  }
  return merged;
}

/**
 * A fence (``` or ~~~) that opens a line runs to a fence that opens a later line, or to the end;
 * mid-sentence, only a closed pair of ``` is code; a run of backticks closes the same run. Indented
 * lines are code only after a blank line and when they don't begin a nested list item.
 */
function collectCodeRanges(text: string, out: [number, number][]): void {
  const length = text.length;
  let index = 0;
  while (index < length) {
    const lineStart = index;
    const lineEnd = text.indexOf('\n', index);
    const stop = lineEnd === -1 ? length : lineEnd;
    const line = text.slice(lineStart, stop);
    const indent = line.match(/^[ \t]*/)?.[0].length ?? 0;
    if (indent <= 3) {
      const fence = /^(`{3,}|~{3,})/.exec(line.slice(indent));
      if (fence !== null) {
        // To a closing fence on a later line, or the end of the text.
        let scan = lineEnd === -1 ? length : lineEnd + 1;
        while (scan < length) {
          const nextEnd = text.indexOf('\n', scan);
          const nextStop = nextEnd === -1 ? length : nextEnd;
          const nextLine = text.slice(scan, nextStop);
          const nextIndent = nextLine.match(/^[ \t]*/)?.[0].length ?? 0;
          const close = nextIndent <= 3 ? /^(`{3,}|~{3,})[ \t]*$/.exec(nextLine.slice(nextIndent)) : null;
          if (close !== null && close[1]?.[0] === fence[1]?.[0] && (close[1]?.length ?? 0) >= (fence[1]?.length ?? 0)) {
            out.push([lineStart, nextStop]);
            index = nextEnd === -1 ? length : nextEnd + 1;
            break;
          }
          scan = nextEnd === -1 ? length : nextEnd + 1;
        }
        if (scan >= length) {
          out.push([lineStart, length]);
          index = length;
        }
        continue;
      }
    }
    // Mid-line inline code and indented code.
    collectInlineCode(line, lineStart, out);
    index = lineEnd === -1 ? length : lineEnd + 1;
  }
}

function collectInlineCode(line: string, base: number, out: [number, number][]): void {
  let index = 0;
  while (index < line.length) {
    if (line[index] !== '`') {
      index += 1;
      continue;
    }
    let open = index;
    while (open < line.length && line[open] === '`') {
      open += 1;
    }
    const run = open - index;
    let close = open;
    while (close < line.length) {
      if (line[close] === '`') {
        let end = close;
        while (end < line.length && line[end] === '`') {
          end += 1;
        }
        if (end - close === run) {
          out.push([base + index, base + end]);
          index = end;
          break;
        }
        close = end;
      } else {
        close += 1;
      }
    }
    if (close >= line.length) {
      index = open;
    }
  }
}

/** A mention's quoted URL runs to whitespace or closing full-width punctuation (the reference LINK). */
const LINK_REACH = /[^\s\u3000-\u303f\uff00-\uff65)\]>"']/;

function collectUrlRanges(text: string, out: [number, number][]): void {
  for (const match of explicitLinkMatches(text)) {
    // The reference's reach for mentions is its own: from the link's start, stop at whitespace or
    // closing full-width punctuation, so "x.com/a，@all" keeps the mention outside the URL.
    let end = match.index;
    while (end < text.length && LINK_REACH.test(text[end])) {
      end += 1;
    }
    out.push([match.index, end]);
  }
}

const LABELED_LINK = /(?<!\\)\[(?:\\.|[^\\\[\]\n])*\]\([^\s()]+\)/g;

function collectLabeledLinkRanges(text: string, out: [number, number][]): void {
  LABELED_LINK.lastIndex = 0;
  let match = LABELED_LINK.exec(text);
  while (match !== null) {
    out.push([match.index, match.index + match[0].length]);
    match = LABELED_LINK.exec(text);
  }
}
