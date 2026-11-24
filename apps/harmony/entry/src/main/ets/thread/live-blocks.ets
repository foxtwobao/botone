// Live-message block folding, ported from packages/core/src/messages/events.ts
// (reduceLiveMessageBlocks and its text/step helpers): a reset drops streamed text and keeps the
// steps, pending tools flush at a sentence boundary, otherwise the tail progress block grows.
// Blocks are raw JSON records; the render layer decodes them.

export function blockText(block: Record<string, Object>): string {
  const text = block['text'];
  return typeof text === 'string' ? text as string : '';
}

export function blockKind(block: Record<string, Object>): string {
  const kind = block['kind'];
  return typeof kind === 'string' ? kind as string : '';
}

// ---------------------------------------------------------------- live blocks (core events.ts)

function liveMessageText(blocks: Record<string, Object>[]): string {
  let text = '';
  for (const block of blocks) {
    if (blockKind(block) === 'text' || blockKind(block) === 'progress') {
      text += blockText(block);
    }
  }
  return text;
}

const SENTENCE_END = /[.!?]["'”’)\]]*\s*$/;

/** True once text ends at a sentence boundary (or is empty) — safe to flush mid-clause never. */
export function endsSentence(text: string): boolean {
  return text.trim() === '' || SENTENCE_END.test(text);
}

export function progressMessageText(payload: Record<string, Object>, previousText: string): string {
  const delta = payload['delta'];
  if (typeof delta === 'string') {
    return previousText + (delta as string);
  }
  const text = payload['text'];
  return text === null || text === undefined ? '' : String(text);
}

export function humanizeToolName(name: string): string {
  const spaced = name.replace(/_/g, ' ').trim();
  if (!spaced) {
    return name;
  }
  const lower = spaced.toLowerCase();
  return lower.charAt(0).toUpperCase() + lower.slice(1);
}

interface ToolStep {
  label: string;
  count: number;
}

function readSteps(block: Record<string, Object>): ToolStep[] {
  const raw = block['steps'];
  if (!Array.isArray(raw)) {
    return [];
  }
  const steps: ToolStep[] = [];
  for (const item of raw as Object[]) {
    const record = item as Record<string, Object>;
    const label = record['label'];
    const count = record['count'];
    if (typeof label === 'string' && typeof count === 'number') {
      const step: ToolStep = { label: label as string, count: count as number };
      steps.push(step);
    }
  }
  return steps;
}

function stepsBlock(steps: ToolStep[]): Record<string, Object> {
  const raw: Object[] = [];
  for (const step of steps) {
    const record: Record<string, Object> = {};
    record['label'] = step.label;
    record['count'] = step.count;
    raw.push(record);
  }
  const block: Record<string, Object> = {};
  block['kind'] = 'steps';
  block['steps'] = raw;
  return block;
}

function appendToolStep(steps: ToolStep[], toolName: string): ToolStep[] {
  const label = humanizeToolName(toolName);
  const last = steps.length > 0 ? steps[steps.length - 1] : null;
  if (last !== null && last.label === label) {
    const merged: ToolStep = { label: label, count: last.count + 1 };
    return [...steps.slice(0, -1), merged];
  }
  const first: ToolStep = { label: label, count: 1 };
  return [...steps, first];
}

function appendTextSegment(segments: Record<string, Object>[], text: string): Record<string, Object>[] {
  if (!text) {
    return [...segments];
  }
  const last = segments.length > 0 ? segments[segments.length - 1] : null;
  if (last !== null && blockKind(last) === 'text') {
    const merged: Record<string, Object> = {};
    merged['kind'] = 'text';
    merged['text'] = blockText(last) + text;
    return [...segments.slice(0, -1), merged];
  }
  const block: Record<string, Object> = {};
  block['kind'] = 'text';
  block['text'] = text;
  return [...segments, block];
}

function appendToolCallSegment(segments: Record<string, Object>[], toolName: string): Record<string, Object>[] {
  const last = segments.length > 0 ? segments[segments.length - 1] : null;
  const priorSteps = last !== null && blockKind(last) === 'steps' ? readSteps(last) : [];
  const steps = appendToolStep(priorSteps, toolName);
  if (last !== null && blockKind(last) === 'steps') {
    return [...segments.slice(0, -1), stepsBlock(steps)];
  }
  return [...segments, stepsBlock(steps)];
}

function pendingNames(block: Record<string, Object> | null): string[] {
  if (block === null || blockKind(block) !== 'progress') {
    return [];
  }
  const raw = block['pendingToolNames'];
  if (!Array.isArray(raw)) {
    return [];
  }
  const names: string[] = [];
  for (const item of raw as Object[]) {
    if (typeof item === 'string') {
      names.push(item as string);
    }
  }
  return names;
}

/**
 * Fold one progress delta or tool call into the live message's blocks (core
 * reduceLiveMessageBlocks): a reset drops streamed text and keeps the steps; pending tools flush
 * at a sentence boundary; otherwise the tail progress block grows.
 */
export function reduceLiveMessageBlocks(current: Record<string, Object>[],
  kind: 'progress' | 'tool', payload: Record<string, Object>, toolName: string): Record<string, Object>[] {
  let blocks = current;
  if (kind === 'progress' && payload['reset'] === true) {
    const waiting = blocks.length > 0 && blockKind(blocks[blocks.length - 1]) === 'progress'
      ? blocks[blocks.length - 1] : null;
    blocks = blocks.filter((block: Record<string, Object>): boolean =>
      blockKind(block) !== 'text' && blockKind(block) !== 'progress');
    for (const name of pendingNames(waiting)) {
      blocks = appendToolCallSegment(blocks, name);
    }
  }
  const tail = blocks.length > 0 ? blocks[blocks.length - 1] : null;
  const tailProgress: Record<string, Object> | null =
    tail !== null && blockKind(tail) === 'progress' ? tail : null;
  const segments = tailProgress !== null ? blocks.slice(0, -1) : blocks;
  const priorText = liveMessageText(blocks);
  const tailLength: number = tailProgress !== null ? blockText(tailProgress).length : 0;
  const flushedLength = tailProgress !== null ? priorText.length - tailLength : priorText.length;
  const tailText = kind === 'progress'
    ? progressMessageText(payload, priorText).slice(flushedLength)
    : tailProgress !== null ? blockText(tailProgress) : '';
  const pendingToolNames = [...pendingNames(tailProgress), ...(kind === 'tool' ? [toolName] : [])];
  const activity = kind === 'progress'
    ? payload['activity'] === true
    : tailProgress !== null && tailProgress['activity'] === true;
  const shown = kind === 'progress'
    ? payload['shown'] === true
    : tailProgress !== null && tailProgress['shown'] === true;

  if (pendingToolNames.length > 0 && endsSentence(tailText)) {
    let next = activity ? [...segments] : appendTextSegment(segments, tailText);
    for (const name of pendingToolNames) {
      next = appendToolCallSegment(next, name);
    }
    return next;
  }
  if (!tailText) {
    return [...segments];
  }
  const progress: Record<string, Object> = {};
  progress['kind'] = 'progress';
  progress['text'] = tailText;
  if (activity) {
    progress['activity'] = true;
  }
  if (shown) {
    progress['shown'] = true;
  }
  if (pendingToolNames.length > 0) {
    progress['pendingToolNames'] = pendingToolNames;
  }
  return [...segments, progress];
}
