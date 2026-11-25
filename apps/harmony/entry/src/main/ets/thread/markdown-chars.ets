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
// Character classification for the markdown parser port (M5), transcribed from the md4c sources
// the mobile renderer's parser is built from. The parser works on UTF-8 bytes exactly as md4c
// does, so every test here reads one byte or decodes one code point the way its macro does. The
// Unicode tables are generated from the same sources (markdown-tables.generated.ets). Pure: no
// ArkUI, no kits, so the fixture can replay it anywhere.
import type { FoldInfo } from './markdown-types';
import {
  MD_ENTITY_TABLE,
  MD_FOLD_MAP_1,
  MD_FOLD_MAP_1_DATA,
  MD_FOLD_MAP_2,
  MD_FOLD_MAP_2_DATA,
  MD_FOLD_MAP_3,
  MD_FOLD_MAP_3_DATA,
  MD_PUNCT_MAP,
  MD_WHITESPACE_MAP,
} from './markdown-tables.generated';

const TAB = 9;
const LINE_FEED = 10;
const CARRIAGE_RETURN = 13;
const SPACE = 32;
const REPLACEMENT = 0xfffd;

export function isBlankChar(ch: number): boolean {
  return ch === SPACE || ch === TAB;
}

export function isNewlineChar(ch: number): boolean {
  return ch === CARRIAGE_RETURN || ch === LINE_FEED;
}

/** Blank, vertical tab or form feed. */
export function isWhitespaceChar(ch: number): boolean {
  return isBlankChar(ch) || ch === 11 || ch === 12;
}

export function isControlChar(ch: number): boolean {
  return ch <= 31 || ch === 127;
}

/** ASCII punctuation: everything printable that is not a letter, digit or space. */
export function isPunctChar(ch: number): boolean {
  return (ch >= 33 && ch <= 47) || (ch >= 58 && ch <= 64) || (ch >= 91 && ch <= 96)
    || (ch >= 123 && ch <= 126);
}

export function isUpperChar(ch: number): boolean {
  return ch >= 65 && ch <= 90;
}

export function isLowerChar(ch: number): boolean {
  return ch >= 97 && ch <= 122;
}

export function isAlphaChar(ch: number): boolean {
  return isUpperChar(ch) || isLowerChar(ch);
}

export function isDigitChar(ch: number): boolean {
  return ch >= 48 && ch <= 57;
}

export function isHexDigitChar(ch: number): boolean {
  return isDigitChar(ch) || (ch >= 65 && ch <= 70) || (ch >= 97 && ch <= 102);
}

export function isAlnumChar(ch: number): boolean {
  return isAlphaChar(ch) || isDigitChar(ch);
}

/** ISANYOF: a byte in the palette (a NUL never matches, as the C string ends there). */
export function isAnyOfChar(ch: number, palette: string): boolean {
  return ch !== 0 && palette.indexOf(String.fromCharCode(ch)) >= 0;
}

/** The `count` bytes at `off` spell the ASCII `word`. */
export function asciiEq(text: Uint8Array, off: number, word: string, count: number): boolean {
  if (off < 0 || off + count > text.length) {
    return false;
  }
  for (let index = 0; index < count; index += 1) {
    if (text[off + index] !== word.charCodeAt(index)) {
      return false;
    }
  }
  return true;
}

/** The `count` bytes at `off` spell the ASCII `word`, either letter case. */
export function asciiCaseEq(text: Uint8Array, off: number, word: string, count: number): boolean {
  if (off < 0 || off + count > text.length) {
    return false;
  }
  for (let index = 0; index < count; index += 1) {
    let left = text[off + index];
    let right = word.charCodeAt(index);
    if (isLowerChar(left)) {
      left -= 32;
    }
    if (isLowerChar(right)) {
      right -= 32;
    }
    if (left !== right) {
      return false;
    }
  }
  return true;
}

/** Binary search over md4c's encoded code point map: a range end flag marks 0x80000000. */
function unicodeBsearch(codepoint: number, map: number[], mapSize: number): number {
  let beg = 0;
  let end = mapSize - 1;
  while (beg <= end) {
    const pivotBeg = Math.floor((beg + end) / 2);
    let pivotEnd = pivotBeg;
    if ((map[pivotEnd] & 0x40000000) !== 0) {
      pivotEnd += 1;
    }
    const first = pivotBeg - ((map[pivotBeg] & 0x80000000) !== 0 ? 1 : 0);
    if (codepoint < (map[first] & 0x00ffffff)) {
      end = first - 1;
    } else if (codepoint > (map[pivotEnd] & 0x00ffffff)) {
      beg = pivotEnd + 1;
    } else {
      return first;
    }
  }
  return -1;
}

/** Unicode "Zs", plus the ASCII whitespace md4c counts in the same test. */
export function isUnicodeWhitespace(codepoint: number): boolean {
  if (codepoint <= 0x7f) {
    return isWhitespaceChar(codepoint);
  }
  return unicodeBsearch(codepoint, MD_WHITESPACE_MAP, MD_WHITESPACE_MAP.length) >= 0;
}

/** Unicode punctuation and symbols (general categories P and S). */
export function isUnicodePunct(codepoint: number): boolean {
  if (codepoint <= 0x7f) {
    return isPunctChar(codepoint);
  }
  return unicodeBsearch(codepoint, MD_PUNCT_MAP, MD_PUNCT_MAP.length) >= 0;
}

function isUtf8Tail(byte: number): boolean {
  return (byte & 0xc0) === 0x80;
}

/** The code point starting at `off`; a byte that opens no valid sequence is itself. */
export function decodeUtf8(text: Uint8Array, off: number, size: number): number {
  const lead = text[off];
  if (lead <= 0x7f) {
    return lead;
  }
  if ((lead & 0xe0) === 0xc0) {
    if (1 < size && isUtf8Tail(text[off + 1])) {
      return ((lead & 0x1f) << 6) | (text[off + 1] & 0x3f);
    }
  } else if ((lead & 0xf0) === 0xe0) {
    if (2 < size && isUtf8Tail(text[off + 1]) && isUtf8Tail(text[off + 2])) {
      return ((lead & 0x0f) << 12) | ((text[off + 1] & 0x3f) << 6) | (text[off + 2] & 0x3f);
    }
  } else if ((lead & 0xf8) === 0xf0) {
    if (3 < size && isUtf8Tail(text[off + 1]) && isUtf8Tail(text[off + 2]) && isUtf8Tail(text[off + 3])) {
      return ((lead & 0x07) << 18) | ((text[off + 1] & 0x3f) << 12) | ((text[off + 2] & 0x3f) << 6)
        | (text[off + 3] & 0x3f);
    }
  }
  return lead;
}

/** How many bytes the code point at `off` takes (one when the sequence is not valid). */
export function utf8CharSize(text: Uint8Array, off: number, size: number): number {
  const lead = text[off];
  if ((lead & 0xf8) === 0xf0 && 3 < size && isUtf8Tail(text[off + 1]) && isUtf8Tail(text[off + 2])
    && isUtf8Tail(text[off + 3])) {
    return 4;
  }
  if ((lead & 0xf0) === 0xe0 && 2 < size && isUtf8Tail(text[off + 1]) && isUtf8Tail(text[off + 2])) {
    return 3;
  }
  if ((lead & 0xe0) === 0xc0 && 1 < size && isUtf8Tail(text[off + 1])) {
    return 2;
  }
  return 1;
}

/** The code point ending at `off`. */
export function decodeUtf8Before(text: Uint8Array, off: number): number {
  const last = text[off - 1];
  if (last <= 0x7f) {
    return last;
  }
  const third = text[off - 3];
  const second = text[off - 2];
  const first = text[off - 4];
  if (off > 1 && (second & 0xe0) === 0xc0 && isUtf8Tail(last)) {
    return ((second & 0x1f) << 6) | (last & 0x3f);
  }
  if (off > 2 && (third & 0xf0) === 0xe0 && isUtf8Tail(second) && isUtf8Tail(last)) {
    return ((third & 0x0f) << 12) | ((second & 0x3f) << 6) | (last & 0x3f);
  }
  if (off > 3 && (first & 0xf8) === 0xf0 && isUtf8Tail(third) && isUtf8Tail(second) && isUtf8Tail(last)) {
    return ((first & 0x07) << 18) | ((third & 0x3f) << 12) | ((second & 0x3f) << 6) | (last & 0x3f);
  }
  return last;
}

export function isUnicodeWhitespaceAt(text: Uint8Array, off: number): boolean {
  return isUnicodeWhitespace(decodeUtf8(text, off, text.length - off));
}

export function isUnicodeWhitespaceBefore(text: Uint8Array, off: number): boolean {
  return isUnicodeWhitespace(decodeUtf8Before(text, off));
}

export function isUnicodePunctAt(text: Uint8Array, off: number): boolean {
  return isUnicodePunct(decodeUtf8(text, off, text.length - off));
}

export function isUnicodePunctBefore(text: Uint8Array, off: number): boolean {
  return isUnicodePunct(decodeUtf8Before(text, off));
}

/** How many bytes the code point needs in UTF-8. */
export function utf8Size(codepoint: number): number {
  if (codepoint < 0x80) {
    return 1;
  }
  if (codepoint < 0x800) {
    return 2;
  }
  if (codepoint < 0x10000) {
    return 3;
  }
  return 4;
}

/** A code point that is no character (zero, out of range, a surrogate) reads as U+FFFD. */
export function printable(codepoint: number): number {
  if (codepoint === 0 || codepoint > 0x10ffff || (codepoint >= 0xd800 && codepoint <= 0xdfff)) {
    return REPLACEMENT;
  }
  return codepoint;
}

/** The UTF-8 bytes of `text`. A lone surrogate becomes U+FFFD, as a standards encoder does. */
export function utf8Encode(text: string): Uint8Array {
  const out = new Uint8Array(text.length * 4);
  let size = 0;
  for (let index = 0; index < text.length; index += 1) {
    let codepoint = text.charCodeAt(index);
    if (codepoint >= 0xd800 && codepoint <= 0xdbff && index + 1 < text.length) {
      const next = text.charCodeAt(index + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        codepoint = 0x10000 + ((codepoint - 0xd800) << 10) + (next - 0xdc00);
        index += 1;
      }
    }
    codepoint = printable(codepoint);
    if (codepoint < 0x80) {
      out[size] = codepoint;
      size += 1;
    } else if (codepoint < 0x800) {
      out[size] = 0xc0 | (codepoint >> 6);
      out[size + 1] = 0x80 | (codepoint & 0x3f);
      size += 2;
    } else if (codepoint < 0x10000) {
      out[size] = 0xe0 | (codepoint >> 12);
      out[size + 1] = 0x80 | ((codepoint >> 6) & 0x3f);
      out[size + 2] = 0x80 | (codepoint & 0x3f);
      size += 3;
    } else {
      out[size] = 0xf0 | (codepoint >> 18);
      out[size + 1] = 0x80 | ((codepoint >> 12) & 0x3f);
      out[size + 2] = 0x80 | ((codepoint >> 6) & 0x3f);
      out[size + 3] = 0x80 | (codepoint & 0x3f);
      size += 4;
    }
  }
  return out.subarray(0, size);
}

function appendCodepoint(out: string[], codepoint: number): void {
  const value = printable(codepoint);
  if (value < 0x10000) {
    out.push(String.fromCharCode(value));
    return;
  }
  const high = 0xd800 + ((value - 0x10000) >> 10);
  const low = 0xdc00 + ((value - 0x10000) & 0x3ff);
  out.push(String.fromCharCode(high, low));
}

/** The bytes from `beg` to `end` as text. */
export function utf8Slice(text: Uint8Array, beg: number, end: number): string {
  const out: string[] = [];
  let off = beg;
  while (off < end) {
    const size = utf8CharSize(text, off, end - off);
    if (size === 1) {
      // A run of plain ASCII needs one string, not one per byte.
      let run = off;
      while (run < end && text[run] < 0x80) {
        run += 1;
      }
      out.push(asciiSlice(text, off, run));
      off = run;
      continue;
    }
    appendCodepoint(out, decodeUtf8(text, off, end - off));
    off += size;
  }
  return out.join('');
}

function asciiSlice(text: Uint8Array, beg: number, end: number): string {
  const out: string[] = [];
  // In pieces: one call per piece keeps the argument list small on very long runs.
  for (let off = beg; off < end; off += 4096) {
    const codes: number[] = [];
    const stop = Math.min(end, off + 4096);
    for (let at = off; at < stop; at += 1) {
      codes.push(text[at]);
    }
    out.push(String.fromCharCode(...codes));
  }
  return out.join('');
}

/** md4c's case folding of one code point, for comparing link labels. */
export function foldInfo(codepoint: number, info: FoldInfo): void {
  info.n = 1;
  info.codepoints[0] = codepoint;
  if (codepoint <= 0x7f) {
    if (isUpperChar(codepoint)) {
      info.codepoints[0] = codepoint + 32;
    }
    return;
  }
  const maps: number[][] = [MD_FOLD_MAP_1, MD_FOLD_MAP_2, MD_FOLD_MAP_3];
  const datas: number[][] = [MD_FOLD_MAP_1_DATA, MD_FOLD_MAP_2_DATA, MD_FOLD_MAP_3_DATA];
  for (let which = 0; which < 3; which += 1) {
    const map = maps[which];
    const index = unicodeBsearch(codepoint, map, map.length);
    if (index < 0) {
      continue;
    }
    const count = which + 1;
    for (let slot = 0; slot < count; slot += 1) {
      info.codepoints[slot] = datas[which][index * count + slot];
    }
    info.n = count;
    if (map[index] !== codepoint) {
      // The entry maps a whole range: offset the folded value the same way.
      if ((map[index] & 0x00ffffff) + 1 === info.codepoints[0]) {
        info.codepoints[0] = codepoint + ((codepoint & 0x1) === (map[index] & 0x1) ? 1 : 0);
      } else {
        info.codepoints[0] += codepoint - (map[index] & 0x00ffffff);
      }
    }
    return;
  }
}

let entityMap: Map<string, number[]> | null = null;

function entities(): Map<string, number[]> {
  if (entityMap === null) {
    const table = new Map<string, number[]>();
    for (const line of MD_ENTITY_TABLE.split('\n')) {
      const comma = line.indexOf(',');
      const points: number[] = [];
      for (const value of line.slice(0, comma).split(' ')) {
        points.push(Number.parseInt(value, 10));
      }
      table.set(line.slice(comma + 1), points);
    }
    entityMap = table;
  }
  return entityMap;
}

/** The end of the character reference starting at `beg` ("&…;"), or -1 when it is none. */
export function entityEnd(text: Uint8Array, beg: number, maxEnd: number): number {
  let off = beg + 1;
  let isContents = false;
  if (off + 2 < maxEnd && text[off] === 35 && (text[off + 1] === 120 || text[off + 1] === 88)) {
    const start = off + 2;
    off = start;
    while (off < maxEnd && isHexDigitChar(text[off]) && off - start <= 8) {
      off += 1;
    }
    isContents = off - start >= 1 && off - start <= 6;
  } else if (off + 1 < maxEnd && text[off] === 35) {
    const start = off + 1;
    off = start;
    while (off < maxEnd && isDigitChar(text[off]) && off - start <= 8) {
      off += 1;
    }
    isContents = off - start >= 1 && off - start <= 7;
  } else {
    const start = off;
    if (off < maxEnd && isAlphaChar(text[off])) {
      off += 1;
      while (off < maxEnd && isAlnumChar(text[off]) && off - start <= 48) {
        off += 1;
      }
      isContents = off - start >= 2 && off - start <= 48;
    }
  }
  if (isContents && off < maxEnd && text[off] === 59) {
    return off + 1;
  }
  return -1;
}

/**
 * Appends what the character reference from `beg` to `end` means; false (and nothing appended)
 * when those bytes are not one. A numeric reference out of range reads as U+FFFD, as in the
 * reference parser; a named one it does not know stays literal text.
 */
export function decodeEntity(text: Uint8Array, beg: number, end: number, out: number[]): boolean {
  const entityEndAt = entityEnd(text, beg, end);
  if (entityEndAt !== end) {
    return false;
  }
  if (text[beg + 1] !== 35) {
    const found = entities().get(asciiSlice(text, beg, end));
    if (found === undefined) {
      return false;
    }
    for (const codepoint of found) {
      out.push(printable(codepoint));
    }
    return true;
  }
  const hex = text[beg + 2] === 120 || text[beg + 2] === 88;
  let codepoint = 0;
  for (let off = beg + (hex ? 3 : 2); off < end - 1; off += 1) {
    const byte = text[off];
    let digit = -1;
    if (byte >= 48 && byte <= 57) {
      digit = byte - 48;
    } else if (hex && byte >= 97 && byte <= 102) {
      digit = byte - 97 + 10;
    } else if (hex && byte >= 65 && byte <= 70) {
      digit = byte - 65 + 10;
    }
    if (digit < 0) {
      codepoint = 0;
      break;
    }
    codepoint = codepoint * (hex ? 16 : 10) + digit;
  }
  out.push(printable(codepoint));
  return true;
}
