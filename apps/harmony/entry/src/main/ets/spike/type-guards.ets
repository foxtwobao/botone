// S1 probe: discriminated-union narrowing and typeof guards — the style the Phase 1
// message-block decoders use to narrow an untrusted record to a known block.

export interface TextBlockProbe {
  kind: 'text';
  text: string;
}

export interface AskBlockProbe {
  kind: 'ask';
  question: string;
}

export type BlockProbe = TextBlockProbe | AskBlockProbe;

export function blockLabel(block: BlockProbe): string {
  if (block.kind === 'text') {
    return block.text;
  }
  return block.question;
}

export function getBlockProbe(value: Object): BlockProbe | null {
  const record = value as Record<string, Object>;
  const kind: Object | undefined = record['kind'];
  if (typeof kind !== 'string') {
    return null;
  }
  if (kind === 'text') {
    const text: Object | undefined = record['text'];
    if (typeof text === 'string') {
      const block: TextBlockProbe = { kind: 'text', text: text };
      return block;
    }
    return null;
  }
  if (kind === 'ask') {
    const question: Object | undefined = record['question'];
    if (typeof question === 'string') {
      const block: AskBlockProbe = { kind: 'ask', question: question };
      return block;
    }
  }
  return null;
}
