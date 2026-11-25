// A bot reply as plain text that keeps its paragraphs, list items and code lines (M5), ported
// from mobile's selectable-text, so the selection sheet can show and copy it across paragraphs.
import { plainTextFromMarkdown } from './markdown-plain';

/** A table row's cells and whether pipes wrapped it. */
interface TableRowCells {
  cells: string[];
  wrapped: boolean;
}

/** The fence a selectable-text line scanner is inside. */
interface OpenFence {
  char: string;
  length: number;
}

const LINE_LIMIT = 100000;
const SELECT_FENCE = /^ {0,3}(`{3,}|~{3,})(.*)$/;
const BULLET_LINE = /^(\s*)[-*+]\s+(.*)$/;
const NUMBERED_LINE = /^(\s*\d+[.)])\s+(.*)$/;
const RULE_LINE = /^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/;
const DELIMITER_CELL = /^:?-+:?$/;
const INDENTED_LINE = /^(?: {4}|\t)/;

interface SelectLine {
  text: string;
  code: boolean;
}

/** Table cells, split on pipes that are neither escaped nor inside an inline code span. */
function tableRowCells(line: string): TableRowCells | null {
  const trimmed = line.trim();
  if (trimmed.length < 2 || !trimmed.includes('|')) {
    return null;
  }
  const leadingPipe = trimmed.startsWith('|');
  const cells: string[] = [];
  let cell = '';
  let fence = 0;
  for (let i = leadingPipe ? 1 : 0; i < trimmed.length; i += 1) {
    const ch = trimmed[i] ?? '';
    if (ch === '\\' && i + 1 < trimmed.length) {
      cell += ch + trimmed[++i];
    } else if (ch === '`') {
      let run = 1;
      while (trimmed[i + run] === '`') {
        run += 1;
      }
      cell += '`'.repeat(run);
      i += run - 1;
      fence = fence === 0 ? run : fence === run ? 0 : fence;
    } else if (ch === '|' && fence === 0) {
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

function convertTableCell(cell: string): string {
  const text = cell.trim();
  // A dash-only cell can look like a horizontal rule to the preview helper.
  return DELIMITER_CELL.test(text) ? text : convertPreviewLine(text);
}

function convertPreviewLine(line: string): string {
  return line.length > LINE_LIMIT ? line : plainTextFromMarkdown(line);
}

/**
 * A bot reply as plain text that keeps its paragraphs, list items and code lines, so it can be
 * shown as one block and selected across paragraphs (mobile selectableTextFromMarkdown).
 */
export function selectableTextFromMarkdown(markdown: string): string {
  const source = markdown.replace(/\r\n/g, '\n').split('\n');
  const lines: SelectLine[] = [];
  let fence: OpenFence | null = null;
  let inList = false;
  let previousBlank = true;
  let previousCode = false;
  let tableDelimiterAt = -1;
  let inTable = false;

  for (let i = 0; i < source.length; i += 1) {
    const line = source[i] ?? '';

    if (fence !== null) {
      const close = /^ {0,3}(`{3,}|~{3,})[ \t]*$/.exec(line)?.[1];
      if (close !== undefined && close !== null && close !== '' && close[0] === fence.char
        && close.length >= fence.length) {
        fence = null;
      } else {
        lines.push({ text: line, code: true });
      }
      previousBlank = false;
      previousCode = true;
      continue;
    }

    const open = SELECT_FENCE.exec(line);
    const marker = open?.[1];
    if (marker !== undefined && marker !== null
      && !(marker[0] === '`' && (open?.[2] ?? '').includes('`'))) {
      const opened: OpenFence = { char: marker[0] ?? '`', length: marker.length };
      fence = opened;
      inTable = false;
      previousBlank = false;
      previousCode = true;
      continue;
    }

    const blank = line.trim() === '';
    if (blank) {
      lines.push({ text: '', code: previousCode && INDENTED_LINE.test(source[i + 1] ?? '') });
      previousBlank = true;
      inTable = false;
      continue;
    }

    if (INDENTED_LINE.test(line) && !inList && (previousBlank || previousCode)) {
      lines.push({ text: line.replace(INDENTED_LINE, ''), code: true });
      inTable = false;
      previousBlank = false;
      previousCode = true;
      continue;
    }
    previousCode = false;
    if (i === tableDelimiterAt) {
      continue;
    }

    const bullet = BULLET_LINE.exec(line);
    const numbered = bullet !== null ? null : NUMBERED_LINE.exec(line);
    if (bullet !== null || numbered !== null) {
      inList = true;
    } else if (!/^\s/.test(line)) {
      inList = false;
    }

    if (RULE_LINE.test(line)) {
      lines.push({ text: '', code: false });
      previousBlank = true;
      inTable = false;
      continue;
    }
    const startsBlock = bullet !== null || numbered !== null || /^ {0,3}(?:>|#{1,6}(?:\s|$))/.test(line);
    if (startsBlock) {
      inTable = false;
    }
    const row = startsBlock ? null : tableRowCells(line);
    // A table can have a body row without pipes, so only a new block ends it.
    if (row !== null && !inTable) {
      const next = tableRowCells(source[i + 1] ?? '');
      if (next !== null && next.cells.length === row.cells.length && isDelimiterRow(next.cells)) {
        tableDelimiterAt = i + 1;
        inTable = true;
      }
    }

    previousBlank = false;
    if (bullet !== null) {
      lines.push({ text: `${bullet[1] ?? ''}• ${convertPreviewLine(bullet[2] ?? '')}`, code: false });
    } else if (numbered !== null) {
      lines.push({ text: `${numbered[1] ?? ''} ${convertPreviewLine(numbered[2] ?? '')}`, code: false });
    } else {
      const cells = row !== null && (inTable || row.wrapped || isDelimiterRow(row.cells)) ? row.cells : null;
      lines.push({
        text: cells !== null
          ? cells.map((cell: string): string => convertTableCell(cell)).join(' | ')
          : convertPreviewLine(line),
        code: false,
      });
    }
  }

  // Collapse runs of blank lines outside code; blank lines in code are content.
  const out: SelectLine[] = [];
  for (const line of lines) {
    const previous = out[out.length - 1];
    if (!line.code && line.text === '' && previous !== undefined && !previous.code
      && previous.text === '') {
      continue;
    }
    out.push(line);
  }
  while (out.length > 0 && !out[0].code && out[0].text === '') {
    out.shift();
  }
  while (out.length > 0 && !out[out.length - 1].code && out[out.length - 1].text === '') {
    out.pop();
  }
  return out.map((line: SelectLine): string => line.text).join('\n');
}
