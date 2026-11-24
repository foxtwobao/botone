// The three-tier block degradation (design §6.4), decided per block from its raw JSON record:
// T1 renders fully (text, progress, supported ask, meta, card, steps summary, routine_event),
// T2 extracts text (handoff, channel_message, bot_message_*, voice_call, computer, subagent,
// image/file name cards), T3 is one localized placeholder for everything else — including any
// unknown kind, so a new upstream block never crashes the transcript. A delivery block hides its
// whole message (it is the wake prompt, not chat content). Decode is per-block: a bad block is a
// placeholder, never a broken message.

/** The render tier a block falls into. */
export const TIER_FULL = 'full';
export const TIER_TEXT = 'text';
export const TIER_PLACEHOLDER = 'placeholder';

export interface BlockView {
  tier: string;
  kind: string;
  /** T1/T2 text content (markdown-lite for bot text; plain for extracted lines). */
  text: string;
  /** card lines (k/v). */
  lines: BlockLine[];
  /** steps summary labels with counts. */
  steps: BlockStep[];
  /** ask: the question text, its actions, and whether it is still answerable. */
  ask: AskView | null;
  /** choice: read-only question + options, answerId highlighted. */
  choice: ChoiceView | null;
  /** subagent/cloud/attachment name for the T2 card title. */
  title: string;
  /** progress: provider activity line vs assistant narration. */
  activity: boolean;
}

export interface BlockLine {
  k: string;
  v: string;
}

export interface BlockStep {
  label: string;
  count: number;
}

export interface AskActionView {
  id: string;
  label: string;
}

export interface AskView {
  text: string;
  detail: string;
  actions: AskActionView[];
  /** pending + supported variant: the card shows its controls. */
  answerable: boolean;
  /** A pure-text question (input absent or "text", no protected fields). */
  textInput: boolean;
  answered: boolean;
  answer: string;
}

export interface ChoiceOptionView {
  id: string;
  letter: string;
  label: string;
}

export interface ChoiceView {
  question: string;
  subtitle: string;
  options: ChoiceOptionView[];
  answerId: string;
}

function str(record: Record<string, Object>, key: string): string {
  const value = record[key];
  return typeof value === 'string' ? value as string : '';
}

/** A delivery block anywhere in the message hides the whole message (contract comment). */
export function isDeliveryMessage(blocks: Record<string, Object>[]): boolean {
  return blocks.some((block: Record<string, Object>): boolean => block['kind'] === 'delivery');
}

/** The ask variants Phase 1 answers: approval actions and pure-text questions. Secret/login/
 * oneTimeCode/receipt/settingsUpdate/instructionUpdate cards stay T3 (vault is Phase 2). */
function askView(block: Record<string, Object>): AskView | null {
  const input = str(block, 'input');
  const protectedCard = input === 'secret' || block['credential'] !== undefined
    || block['oneTimeCode'] !== undefined || block['loginFields'] !== undefined
    || block['receipt'] !== undefined || block['settingsUpdate'] !== undefined
    || block['instructionUpdate'] !== undefined || block['replaces'] !== undefined;
  const status = str(block, 'status');
  const answered = status === 'answered' || block['dismissed'] === true || block['expired'] === true;
  const actionsRaw = block['actions'];
  const actions: AskActionView[] = [];
  if (Array.isArray(actionsRaw)) {
    for (const item of actionsRaw as Object[]) {
      if (item !== null && typeof item === 'object' && !Array.isArray(item)) {
        const action = item as Record<string, Object>;
        const id = str(action, 'id');
        if (id) {
          const view: AskActionView = { id: id, label: str(action, 'label') || id };
          actions.push(view);
        }
      }
    }
  }
  const textInput = !protectedCard && (input === '' || input === 'text') && actions.length === 0;
  const answerable = !answered && !protectedCard && (actions.length > 0 || textInput);
  const view: AskView = {
    text: str(block, 'text'),
    detail: str(block, 'detail'),
    actions: actions,
    answerable: answerable,
    textInput: textInput,
    answered: answered,
    answer: str(block, 'answer'),
  };
  return view;
}

function choiceView(block: Record<string, Object>): ChoiceView {
  const options: ChoiceOptionView[] = [];
  const raw = block['options'];
  if (Array.isArray(raw)) {
    for (const item of raw as Object[]) {
      if (item !== null && typeof item === 'object' && !Array.isArray(item)) {
        const option = item as Record<string, Object>;
        const view: ChoiceOptionView = {
          id: str(option, 'id'), letter: str(option, 'letter'), label: str(option, 'label'),
        };
        options.push(view);
      }
    }
  }
  const view: ChoiceView = {
    question: str(block, 'question'),
    subtitle: str(block, 'subtitle'),
    options: options,
    answerId: str(block, 'answerId'),
  };
  return view;
}

function emptyView(kind: string, tier: string): BlockView {
  const view: BlockView = {
    tier: tier, kind: kind, text: '', lines: [], steps: [], ask: null, choice: null,
    title: '', activity: false,
  };
  return view;
}

/** Classify one raw block into its render view; an unknown kind is always a T3 placeholder. */
export function blockView(block: Record<string, Object>): BlockView {
  const kind = str(block, 'kind');
  if (kind === 'text' || kind === 'meta') {
    const view = emptyView(kind, TIER_FULL);
    view.text = str(block, 'text');
    return view;
  }
  if (kind === 'progress') {
    const view = emptyView(kind, TIER_FULL);
    view.text = str(block, 'text');
    view.activity = block['activity'] === true;
    return view;
  }
  if (kind === 'card') {
    const view = emptyView(kind, TIER_FULL);
    const raw = block['lines'];
    if (Array.isArray(raw)) {
      for (const item of raw as Object[]) {
        if (item !== null && typeof item === 'object' && !Array.isArray(item)) {
          const line = item as Record<string, Object>;
          const row: BlockLine = { k: str(line, 'k'), v: str(line, 'v') };
          view.lines.push(row);
        }
      }
    }
    return view;
  }
  if (kind === 'steps') {
    const view = emptyView(kind, TIER_FULL);
    const raw = block['steps'];
    if (Array.isArray(raw)) {
      for (const item of raw as Object[]) {
        if (item !== null && typeof item === 'object' && !Array.isArray(item)) {
          const step = item as Record<string, Object>;
          const count = step['count'];
          const row: BlockStep = {
            label: str(step, 'label'),
            count: typeof count === 'number' ? count as number : 1,
          };
          view.steps.push(row);
        }
      }
    }
    return view;
  }
  if (kind === 'routine_event') {
    const view = emptyView(kind, TIER_FULL);
    view.title = str(block, 'name');
    view.text = str(block, 'change');
    return view;
  }
  if (kind === 'ask') {
    const ask = askView(block);
    if (ask !== null && (ask.answerable || ask.answered)) {
      const view = emptyView(kind, TIER_FULL);
      view.ask = ask;
      view.text = ask.text;
      return view;
    }
    return emptyView(kind, TIER_PLACEHOLDER);
  }
  if (kind === 'choice') {
    const view = emptyView(kind, TIER_FULL);
    view.choice = choiceView(block);
    return view;
  }
  if (kind === 'handoff' || kind === 'channel_message' || kind === 'computer') {
    const view = emptyView(kind, TIER_TEXT);
    view.text = str(block, 'text');
    if (kind === 'channel_message') {
      view.title = str(block, 'fromLabel');
    }
    return view;
  }
  if (kind === 'bot_message_sent') {
    const view = emptyView(kind, TIER_TEXT);
    view.title = str(block, 'toBotName');
    view.text = str(block, 'text');
    return view;
  }
  if (kind === 'bot_message_received') {
    const view = emptyView(kind, TIER_TEXT);
    view.title = str(block, 'fromBotName');
    view.text = str(block, 'text');
    return view;
  }
  if (kind === 'voice_call') {
    const view = emptyView(kind, TIER_TEXT);
    view.title = str(block, 'title');
    view.text = str(block, 'farewell');
    return view;
  }
  if (kind === 'subagent') {
    const view = emptyView(kind, TIER_TEXT);
    view.title = str(block, 'name');
    const result = str(block, 'result');
    const progress = str(block, 'progress');
    view.text = str(block, 'task');
    if (result || progress) {
      view.text = `${view.text}\n${result || progress}`;
    }
    return view;
  }
  if (kind === 'image' || kind === 'file') {
    const view = emptyView(kind, TIER_TEXT);
    view.title = str(block, 'name');
    return view;
  }
  // Everything else — chart, app, page, mcp_approval, import_setup, skill_draft, cloud_agent,
  // tool_question, call_request, child_bot, connect, app_connect, delivery, and any UNKNOWN kind.
  return emptyView(kind || 'unknown', TIER_PLACEHOLDER);
}

/** The message's visible blocks (delivery messages are hidden whole by the caller). */
export function messageBlockViews(blocks: Record<string, Object>[]): BlockView[] {
  const views: BlockView[] = [];
  for (const block of blocks) {
    views.push(blockView(block));
  }
  return views;
}
