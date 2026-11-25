// The message-text rules the thread renders with (M5), ported from the shared packages so the
// bubble, the reply line and the long-press menu decide exactly as the mobile app does: which
// text a message carries (core message-text), how a reply line labels its parent (core
// message-replies), and how a name shows when it is not a readable one (core display-name).
// Labels the caller owns: every user-visible word arrives as a parameter, so this module stays
// pure and the tests can replay it anywhere.
//
// The other rules the bubble renders with sit beside it, one port per file: @Name mentions
// (message-mentions), plain-text links (message-links), the one-line preview of bot Markdown
// (markdown-plain) and its selectable text (selectable-text).
import { codeBlocksAsWritten, markdownPlainText } from './markdown-lite';
import { selectableTextFromMarkdown } from './selectable-text';

/** Every code block needs a fence, four spaces or a tab; most messages hold none, so they skip the parse. */
const MAY_HOLD_CODE = /```|~~~| {4}|\t/;

/** A message's blocks as the store keeps them: raw JSON records. */
export type Blocks = Record<string, Object>[];

export interface ReplyAttachment {
  kind: string;
  name: string;
  artifactId?: string;
  mimeType?: string;
}

export interface ReplyPreview {
  text?: string;
  attachment?: ReplyAttachment | null;
  role?: string;
  botId?: string;
  page?: boolean;
  author?: Record<string, Object> | null;
}

/** A page-origin reply check's inputs. */
export interface PageOriginReplyLike {
  replyQuote?: string;
  replyPreview?: ReplyPreview | null;
}

/** A message as the text rules read it. */
export interface MessageLike {
  id: string;
  role: string;
  blocks: Blocks;
}

/** A reply's parent text as the transcript supplies it. */
export interface ReplyLabels {
  photo: string;
  attachment: string;
}

/** The preview labels with the fallback word for a message with no text. */
export interface PreviewLabels {
  photo: string;
  attachment: string;
  message: string;
}

function str(record: Record<string, Object>, key: string): string {
  const value = record[key];
  return typeof value === 'string' ? value as string : '';
}

function optStr(record: Record<string, Object>, key: string): string | undefined {
  const value = record[key];
  return typeof value === 'string' ? value as string : undefined;
}

function optNumber(record: Record<string, Object>, key: string): number | undefined {
  const value = record[key];
  return typeof value === 'number' ? value as number : undefined;
}

/** A relayed chat-app message with who sent it and over what (core channelMessageLine). */
export function channelMessageLine(block: Record<string, Object>): string {
  return `${str(block, 'fromLabel')} (${messagingProviderLabel(str(block, 'provider'), optStr(block, 'transport'))}): ${str(block, 'text')}`;
}

const PROVIDER_NAMES: Record<string, string> = {
  'sendblue': 'iMessage',
  'slack': 'Slack',
  'whatsapp': 'WhatsApp',
  'telegram': 'Telegram',
  'lark': 'Feishu',
  'photon': 'iMessage (Photon)',
  'teams': 'Microsoft Teams',
};

/** User-facing name of a messaging provider (falls back to the raw id). */
export function messagingProviderName(provider: string): string {
  const telegram = /^telegram-(.+)$/.exec(provider);
  if (telegram !== null) {
    return `Telegram (${telegram[1]})`;
  }
  const photon = /^photon-(.+)$/.exec(provider);
  if (photon !== null) {
    return `iMessage (${photon[1]})`;
  }
  return PROVIDER_NAMES[provider] ?? provider;
}

export function messagingProviderLabel(provider: string, transport?: string): string {
  if (provider === 'sendblue' && ['iMessage', 'SMS', 'RCS'].includes(transport ?? '')) {
    return transport ?? '';
  }
  return messagingProviderName(provider);
}

/** The message's text exactly as written (text, ask and progress, no chrome), for selection. */
export function selectableMessageText(message: MessageLike): string {
  const parts: string[] = [];
  for (const block of message.blocks) {
    const kind = str(block, 'kind');
    if (kind === 'channel_message') {
      parts.push(channelMessageLine(block));
    } else if (kind === 'text' || kind === 'progress' || kind === 'ask') {
      parts.push(str(block, 'text'));
    }
  }
  return parts.filter((part: string): boolean => part !== '').join('\n');
}

/** Plain message text for clipboard copy. */
export function copyableMessageText(message: MessageLike): string {
  return selectableMessageText(message).trim();
}

/**
 * The message's whole text as one string, the way the mobile bubble reads it for markdown and
 * speech (mobile blockText): every block's contribution, blank ones dropped, joined by lines.
 */
export function blockText(message: MessageLike): string {
  const parts: string[] = [];
  for (const block of message.blocks) {
    const kind = str(block, 'kind');
    let part = '';
    if (kind === 'channel_message') {
      part = channelMessageLine(block);
    } else if (kind === 'cloud_agent') {
      const pr = str(block, 'prUrl');
      part = `${str(block, 'title')}: ${str(block, 'status')}${pr ? ` ${pr}` : ''}`;
    } else if (kind === 'subagent') {
      const name = str(block, 'name') || 'subagent';
      const body = str(block, 'result') || str(block, 'progress') || str(block, 'task');
      part = `${name}: ${body}`;
    } else if (kind === 'child_bot') {
      const status = str(block, 'status');
      const label = status === 'archived' ? 'Archived' : status === 'deleted' ? 'Deleted' : 'Bot';
      part = `${label} ${str(block, 'name')}`;
    } else if (kind === 'chart') {
      part = `[chart: ${str(block, 'name') || 'chart'}]`;
    } else if (kind === 'app') {
      part = `[app: ${str(block, 'server')}]`;
    } else if (kind === 'tool_question') {
      const source = block['question'];
      const empty: Record<string, Object> = {};
      const question = source !== null && typeof source === 'object'
        && !Array.isArray(source as Object) ? source as Record<string, Object> : empty;
      part = `[question: ${str(question, 'source')}]`;
    } else if (kind === 'page') {
      part = `[page: ${str(block, 'title')}]`;
    } else if (kind === 'image') {
      part = `[image: ${str(block, 'name') || 'attachment'}]`;
    } else if (kind === 'file') {
      const size = optNumber(block, 'size');
      part = `[file: ${str(block, 'name') || 'attachment'}${size ? ` (${size} bytes)` : ''}]`;
    } else if (kind === 'steps') {
      const labels: string[] = [];
      const raw = block['steps'];
      if (Array.isArray(raw)) {
        for (const item of raw as Object[]) {
          if (item !== null && typeof item === 'object' && !Array.isArray(item)) {
            const step = item as Record<string, Object>;
            const count = optNumber(step, 'count') ?? 1;
            labels.push(`${str(step, 'label')}${count > 1 ? ` ×${count}` : ''}`);
          }
        }
      }
      part = labels.join(', ');
    } else {
      const text = str(block, 'text');
      part = text !== '' ? text : str(block, 'state');
    }
    if (part !== '') {
      parts.push(part);
    }
  }
  return parts.join('\n');
}

/* ------------------------------- reply lines (core message-replies) ------------------------------- */

/** The first nonblank reply line, capped without splitting a surrogate pair. */
export function compactReplyExcerpt(text: string): string {
  let first = '';
  for (const line of text.split(/\r\n?|\n/u)) {
    const trimmed = line.trim();
    if (trimmed !== '') {
      first = trimmed;
      break;
    }
  }
  const excerpt = first.slice(0, 280);
  return /[\uD800-\uDBFF]$/u.test(excerpt) ? excerpt.slice(0, -1) : excerpt;
}

export function replyLineText(quote?: string, preview?: string, fallback?: string): string {
  if (quote) {
    return quote.replace(/\s+/gu, ' ');
  }
  return ((preview || fallback || '').split(/\r\n?|\n/u)[0] ?? '') || '';
}

/** Metadata from validated parent blocks, preferring a photo over a file. */
export function replyAttachment(blocks: Blocks): ReplyAttachment | null {
  let found: Record<string, Object> | null = null;
  for (const block of blocks) {
    if (str(block, 'kind') === 'image') {
      found = block;
      break;
    }
  }
  if (found === null) {
    for (const block of blocks) {
      if (str(block, 'kind') === 'file') {
        found = block;
        break;
      }
    }
  }
  if (found === null) {
    return null;
  }
  const out: ReplyAttachment = { kind: str(found, 'kind'), name: str(found, 'name') };
  const artifactId = optStr(found, 'artifactId');
  const mimeType = optStr(found, 'mimeType');
  if (artifactId !== undefined) {
    out.artifactId = artifactId;
  }
  if (mimeType !== undefined) {
    out.mimeType = mimeType;
  }
  return out;
}

/** The reply line's quote of its parent (core replyLabel; labels from the caller). */
export function replyLabel(quote: string | undefined, text: string | undefined,
  attachment: ReplyAttachment | null, labels: ReplyLabels): string {
  const legacyImageQuote = attachment?.kind === 'image' && !text
    && (quote === attachment.name || quote === `[image: ${attachment.name}]`);
  return replyLineText(legacyImageQuote ? undefined : quote, text,
    attachment?.kind === 'image' ? labels.photo : attachment?.name || labels.attachment);
}

/** Who wrote a message relayed from an outside channel (core channelMessageSender). */
export function channelMessageSender(blocks: Blocks): string | undefined {
  for (const block of blocks) {
    if (str(block, 'kind') === 'channel_message') {
      return displayName(str(block, 'fromLabel'), '') || undefined;
    }
  }
  return undefined;
}

/** A message's text for a reply line before the server's preview arrives (core previewMessageText). */
export function previewMessageText(message: MessageLike, labels: PreviewLabels): string {
  if (isDeliveryMessage(message.blocks)) {
    return labels.message;
  }
  const parts: string[] = [];
  for (const block of message.blocks) {
    const kind = str(block, 'kind');
    if (kind === 'channel_message') {
      parts.push(str(block, 'text'));
    } else if (kind === 'text') {
      parts.push(message.role === 'bot' ? markdownPlainText(str(block, 'text')) : str(block, 'text'));
    }
  }
  const text = parts.filter((part: string): boolean => part !== '').join(' ').trim();
  if (text) {
    return text;
  }
  for (const block of message.blocks) {
    if (str(block, 'kind') === 'ask') {
      const excerpt = compactReplyExcerpt(str(block, 'text').slice(0, 100000));
      if (excerpt !== '') {
        return excerpt;
      }
    }
  }
  const attachment = replyAttachment(message.blocks);
  if (attachment !== null) {
    return attachment.kind === 'image' ? labels.photo : attachment.name || labels.attachment;
  }
  return labels.message;
}

/** A message sent from an open page replies to the page's card but shows no quote of it. */
export function isPageOriginReply(message: PageOriginReplyLike): boolean {
  return message.replyPreview?.page === true && !message.replyQuote;
}

/** Someone else in a shared space; my own messages and unknown senders stay unnamed. */
export function otherAuthor(author: Record<string, Object> | null | undefined,
  meId: string | undefined): Record<string, Object> | undefined {
  if (author === null || author === undefined || meId === undefined) {
    return undefined;
  }
  return str(author, 'id') !== meId ? author : undefined;
}

/** A delivery block anywhere in the message hides the whole message. */
export function isDeliveryMessage(blocks: Blocks): boolean {
  for (const block of blocks) {
    if (str(block, 'kind') === 'delivery') {
      return true;
    }
  }
  return false;
}

/* ------------------------------- names (core display-name) ------------------------------- */

/** Deliberately narrow: complete tokens only, never substrings of prose or short handles. */
export function isOpaqueName(name: string): boolean {
  return /^__[A-Za-z0-9_-]+__$/.test(name)
    || /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(name)
    || (/^c[a-z0-9]{24}$/.test(name) && /[0-9]/.test(name))
    || (/^[a-z][a-z0-9]{23}$/.test(name) && /[0-9]/.test(name))
    || (/^[A-Za-z0-9_-]{20,}$/.test(name) && /[a-z]/.test(name) && /[A-Z]/.test(name)
      && /[0-9]/.test(name) && !/^[A-Za-z_-]+[0-9]+$/.test(name)
      && !/^[A-Za-z][a-z]*(?:[A-Z][a-z]+|[0-9]|[_-][A-Za-z][a-z]+)*$/.test(name));
}

export function displayName(name: string | null | undefined, fallback: string): string {
  const trimmed = name?.trim() ?? '';
  return trimmed !== '' && /[\p{L}\p{N}]/u.test(trimmed) && !isOpaqueName(trimmed) ? trimmed : fallback;
}

/* ------------------------------- the menu (mobile message-row) ------------------------------- */

export interface MessageMenu {
  select: boolean;
  /** Exactly one code block: the mobile menu then offers to copy just it. */
  copyCode: boolean;
  /** What "Copy" puts on the clipboard (already trimmed). */
  copyText: string;
  /** What "Select text" shows (bot markdown converted to selectable plain text). */
  selectText: string;
  /** The one code block's code, when `copyCode` is set. */
  code: string;
}

/**
 * What the long-press menu acts on (mobile's subset; reply, quote, react, speak and mark-unread
 * are later). Its words are the caller's: the menu draws them translated.
 */
export function messageMenu(message: MessageLike): MessageMenu {
  const messageText = selectableMessageText(message);
  const includeSelect = messageText.trim().length > 0;
  const codeBlocks = message.role === 'user' ? [] : markdownCodeBlocks(blockText(message));
  return {
    select: includeSelect,
    copyCode: codeBlocks.length === 1,
    copyText: copyableMessageText(message),
    selectText: message.role === 'user' ? messageText : selectableTextFromMarkdown(messageText),
    code: codeBlocks[0] ?? '',
  };
}

/** The code of each fenced or indented block in a message (chat-ui markdownCodeBlocks). */
export function markdownCodeBlocks(markdown: string): string[] {
  if (!MAY_HOLD_CODE.test(markdown)) {
    return [];
  }
  return codeBlocksAsWritten(markdown);
}
