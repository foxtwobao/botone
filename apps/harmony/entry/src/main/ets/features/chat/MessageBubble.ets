// One transcript message (M5): the bot's markdown tree rendered as the mobile bubble renders it
// (headings, lists, quotes, fenced code with copy, links, spoilers as plain text), the user's
// plain-text bubble with @Name mentions and links, the reply line above both, the long-press menu
// (select text, copy, copy code), and the select-text sheet. Row-level
// rendering: a changed message re-renders alone (the store's row key carries content).
import { pasteboard } from '@kit.BasicServicesKit';
import { appearance } from '../../uikit/theme';
import { typeScale } from '../../uikit/tokens.generated';
import { ActionButton } from '../../uikit/controls';
import { t } from '../../i18n/i18n';
import { UNSUPPORTED_BLOCK } from '../../i18n/harmony-strings';
import type { LiveMessage, ThreadMember } from '../../thread/thread-snapshot';
import { messageBlockViews } from '../../thread/block-view';
import type { AskActionView, AskView, BlockLine, BlockStep, BlockView, ChoiceOptionView, ChoiceView } from '../../thread/block-view';
import { parseMarkdown } from '../../thread/markdown-lite';
import { inlineRuns } from './markdown-runs';
import type { TextRun } from './markdown-runs';
import type { MdNode } from '../../thread/markdown-types';
import {
  isPageOriginReply,
  messageMenu,
  otherAuthor,
  previewMessageText,
  replyLabel,
} from '../../thread/message-text';
import type { MessageLike, MessageMenu, PreviewLabels, ReplyAttachment, ReplyPreview } from '../../thread/message-text';
import { userMentionTargets, userTextRuns } from '../../thread/message-mentions';
import type { MemberLike, UserMentionTarget, UserTextRun } from '../../thread/message-mentions';
import { sanitizeMarkdownUrl } from '../../thread/message-links';
import { app } from '../../app/app-state';
import { speechFromBlocks } from '../../voice/speech-text';
import { AttachmentBlock } from './media-attachments';
import { QuoteSheet } from './quote-sheet';

/** Where a link opens, or empty when it opens nothing: only the schemes the app may follow. */
function openableHref(href: string): string {
  return sanitizeMarkdownUrl(href) ?? '';
}

/** Puts text on the clipboard and says whether it did: a system that refuses has nothing to show
 *  for it, and its rejection must not surface as an unhandled one. */
async function putClipboard(text: string): Promise<boolean> {
  try {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    await pasteboard.getSystemPasteboard().setData(data);
    return true;
  } catch (err) {
    // The message stays on screen to copy again.
    return false;
  }
}

/* ------------------------------- markdown tree rendering ------------------------------- */

/** One node's inline children as a Text of styled Spans (flat runs: Span takes no children). */
@ComponentV2
struct InlineRuns {
  @Param node: MdNode | null = null;
  @Param color: string = '';
  @Param fontSize: number = 15;
  /** The weight unmarked runs take (headings draw bold or semibold). */
  @Param weight: FontWeight = FontWeight.Normal;

  build() {
    Text() {
      ForEach(this.node === null ? [] : inlineRuns(this.node), (run: TextRun): void => {
        Span(run.text)
          .fontColor(run.href !== '' ? appearance.tokens().link : this.color)
          .fontSize(run.code ? this.fontSize - 1 : this.fontSize)
          .fontWeight(run.bold ? FontWeight.Bold : this.weight)
          .fontStyle(run.italic ? FontStyle.Italic : FontStyle.Normal)
          .decoration(run.strike
            ? { type: TextDecorationType.LineThrough, color: this.color }
            : { type: run.href !== '' ? TextDecorationType.Underline : TextDecorationType.None, color: appearance.tokens().link })
          .fontFamily(run.code ? 'monospace' : undefined)
          .onClick((): void => {
            this.open(run);
          })
      }, (run: TextRun, index: number): string => `${index}:${run.text}:${run.href}`)
    }
    .onClick((): void => {
      // The Text itself swallows taps that reach no span.
    })
  }

  /** Opens the address a link run names, outside the app, as the mobile bubble does. */
  private open(run: TextRun): void {
    if (run.href !== '') {
      void app.openExternal(run.href);
    }
  }
}

/**
 * A fenced or indented code block: monospace, the full width to scroll in, and a copy button
 * that turns to "Copied" for a moment once the code is on the clipboard. Mobile overlays an icon
 * button on the block's corner; a labelled button above the code covers none of it.
 */
@ComponentV2
struct CodeBlock {
  /** The code as the block shows it, tabs expanded. */
  @Param code: string = '';
  /** The code as its author wrote it, tabs kept: what the copy button puts on the clipboard. */
  @Param copyCode: string = '';
  @Local copied: boolean = false;
  private restoreTimer: number = -1;
  /** False once the block is gone: the clipboard may still answer a copy started before. */
  private mounted: boolean = true;

  aboutToDisappear(): void {
    this.mounted = false;
    if (this.restoreTimer >= 0) {
      clearTimeout(this.restoreTimer);
    }
  }

  private copy(): void {
    void putClipboard(this.copyCode).then((copied: boolean): void => {
      if (!copied || !this.mounted) {
        return;
      }
      this.copied = true;
      if (this.restoreTimer >= 0) {
        clearTimeout(this.restoreTimer);
      }
      this.restoreTimer = setTimeout((): void => {
        this.copied = false;
      }, 2000);
    });
  }

  build() {
    Column({ space: 4 }) {
      Row() {
        Blank()
        Button(this.copied ? t('Copied') : t('Copy code'))
          .height(28)
          .fontSize(typeScale.caption.fontSize)
          .backgroundColor(appearance.tokens().card)
          .fontColor(appearance.tokens().link)
          .onClick((): void => {
            this.copy();
          })
      }
      .width('100%')
      Scroll() {
        Text(this.code)
          .fontFamily('monospace')
          .fontSize(typeScale.secondary.fontSize)
          .fontColor(appearance.tokens().foreground)
      }
      .scrollable(ScrollDirection.Horizontal)
      .width('100%')
      .align(Alignment.Start)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(10)
    .backgroundColor(appearance.tokens().secondary)
    .borderRadius(10)
  }
}

/** One markdown block node: the mobile renderer's subset, degraded where ArkTS cannot draw it. */
@ComponentV2
struct MarkdownNode {
  @Param node: MdNode | null = null;
  @Param color: string = '';
  @Param depth: number = 0;

  @Builder
  nodeBody(node: MdNode, marker: string, ordered: boolean) {
    if (node.type === 'doc') {
      // The document and other containers hand each child its own node.
      ForEach(node.children, (child: MdNode, index: number): void => {
        MarkdownNode({ node: child, color: this.color, depth: this.depth + 1 })
      }, (child: MdNode, index: number): string => `${index}:${child.type}:${child.text.slice(0, 40)}`)
    } else if (node.type === 'p') {
      InlineRuns({ node: node, color: this.color, fontSize: typeScale.body.fontSize })
    } else if (node.type === 'h') {
      InlineRuns({
        node: node,
        color: this.color,
        fontSize: node.level <= 1 ? typeScale.title.fontSize
          : node.level === 2 ? typeScale.headline.fontSize
          : node.level === 3 ? typeScale.body.fontSize : typeScale.secondary.fontSize,
        weight: FontWeight.Bold,
      })
    } else if (node.type === 'codeblock') {
      CodeBlock({ code: node.text, copyCode: node.copyText })
    } else if (node.type === 'blockquote' || node.type === 'quote' || node.type === 'admonition') {
      // The bar is the quote's own left border, so it is as tall as the quote whatever that is
      // (a separate bar would need a share of a height the quote itself defines).
      Column({ space: 4 }) {
        ForEach(node.children, (child: MdNode): void => {
          MarkdownNode({ node: child, color: appearance.tokens().mutedForeground, depth: this.depth + 1 })
        }, (child: MdNode, index: number): string => `${index}:${child.type}:${child.text}`)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 8 })
      .border({ width: { left: 3 }, color: { left: appearance.tokens().faintForeground } })
    } else if (node.type === 'ul' || node.type === 'ol') {
      Column({ space: 2 }) {
        ForEach(node.children, (item: MdNode, index: number): void => {
          Row({ space: 6 }) {
            if (item.task !== '') {
              // A task item shows whether it is done where a bullet would be. It reports the bot's
              // list and does not edit it: the box itself ignores touches, a long-press still
              // reaches the bubble.
              Checkbox()
                .select(item.task === 'x')
                .width(18)
                .height(18)
                .margin({ top: 2 })
                .hitTestBehavior(HitTestMode.None)
            } else {
              Text(ordered ? `${index + node.start}.` : marker)
                .fontSize(typeScale.body.fontSize)
                .fontColor(appearance.tokens().mutedForeground)
            }
            Column({ space: 2 }) {
              ForEach(item.children, (child: MdNode): void => {
                MarkdownNode({ node: child, color: this.color, depth: this.depth + 1 })
              }, (child: MdNode, childIndex: number): string => `${childIndex}:${child.type}:${child.text}`)
            }
            .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }, (item: MdNode, index: number): string => `${index}:${item.type}:${item.task}`)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    } else if (node.type === 'li') {
      // Reached only outside a list (the parser wraps items): read as its children.
      Column({ space: 2 }) {
        ForEach(node.children, (child: MdNode): void => {
          MarkdownNode({ node: child, color: this.color, depth: this.depth + 1 })
        }, (child: MdNode, index: number): string => `${index}:${child.type}`)
      }
    } else if (node.type === 'table') {
      Column({ space: 2 }) {
        ForEach(node.children, (section: MdNode): void => {
          ForEach(section.children, (row: MdNode): void => {
            Row({ space: 6 }) {
              ForEach(row.children, (cell: MdNode): void => {
                InlineRuns({
                  node: cell,
                  color: this.color,
                  fontSize: typeScale.secondary.fontSize,
                  weight: cell.type === 'th' ? FontWeight.Bold : FontWeight.Normal,
                })
                  .layoutWeight(1)
              }, (cell: MdNode, cellIndex: number): string => `${cellIndex}:${cell.text}`)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          }, (row: MdNode, rowIndex: number): string => `${rowIndex}`)
        }, (section: MdNode, sectionIndex: number): string => `${sectionIndex}:${section.type}`)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    } else if (node.type === 'hr') {
      Divider()
        .color(appearance.tokens().border)
        .width('100%')
    } else if (node.type === 'video') {
      // No video surface yet: the address it names reads as a link and opens outside.
      Text(node.href)
        .fontSize(typeScale.body.fontSize)
        .fontColor(appearance.tokens().link)
        .onClick((): void => {
          const href = openableHref(node.href);
          if (href !== '') {
            void app.openExternal(href);
          }
        })
    } else {
      InlineRuns({ node: node, color: this.color, fontSize: typeScale.body.fontSize })
    }
  }

  build() {
    if (this.node !== null) {
      Column({ space: 6 }) {
        this.nodeBody(this.node!, this.node!.type === 'ul' ? '•' : '', this.node!.type === 'ol')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }
}

/** A bot text block: its markdown tree. */
@ComponentV2
struct MarkdownText {
  @Param text: string = '';
  @Param color: string = '';
  @Local tree: MdNode | null = null;

  aboutToAppear(): void {
    this.rebuild(this.text);
  }

  @Monitor('text')
  onTextChange(): void {
    this.rebuild(this.text);
  }

  private rebuild(text: string): void {
    this.tree = parseMarkdown(text);
  }

  build() {
    Column({ space: 6 }) {
      MarkdownNode({ node: this.tree, color: this.color })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/* ------------------------------- user bubble: mentions and links ------------------------------- */

/**
 * The user's plain text as the mobile bubble draws it: a link keeps the bubble's text colour and
 * is underlined (link blue is too faint on the user bubble), a mentioned name is medium weight.
 * Mobile draws a small bot avatar before a mentioned name; with no inline avatar here the name
 * keeps its `@`.
 */
@ComponentV2
struct UserText {
  @Param text: string = '';
  @Param targets: UserMentionTarget[] = [];
  @Param fontSize: number = 15;
  @Param color: string = '';
  @Local runs: UserTextRun[] = [];

  aboutToAppear(): void {
    this.rebuild(this.text, this.targets);
  }

  @Monitor('text', 'targets')
  onInputsChange(): void {
    this.rebuild(this.text, this.targets);
  }

  private rebuild(text: string, targets: UserMentionTarget[]): void {
    this.runs = userTextRuns(text, targets);
  }

  build() {
    Text() {
      ForEach(this.runs, (run: UserTextRun): void => {
        Span(run.text)
          .fontColor(this.color)
          .fontSize(this.fontSize)
          .fontWeight(run.target !== null ? FontWeight.Medium : FontWeight.Normal)
          .decoration(run.href === ''
            ? { type: TextDecorationType.None }
            : { type: TextDecorationType.Underline, color: this.color })
          .onClick((): void => {
            if (run.href !== '') {
              void app.openExternal(run.href);
            }
          })
      }, (run: UserTextRun, index: number): string => `${index}:${run.text}:${run.href}`)
    }
    .onClick((): void => {
      // The Text itself swallows taps that reach no span.
    })
  }
}

/* ------------------------------- cards (M3, unchanged rules) ------------------------------- */

/** The ask card: approval actions send action.id; a text question answers from its own field. */
@ComponentV2
struct AskCard {
  @Param ask: AskView = {
    text: '', detail: '', actions: [], answerable: false, textInput: false, answered: false, answer: '',
  };
  @Param busy: boolean = false;
  @Event onAnswer: (answer: string) => void = (_answer: string): void => {};
  @Local draft: string = '';

  build() {
    Column({ space: 8 }) {
      Text(this.ask.text)
        .fontSize(typeScale.body.fontSize)
        .fontColor(appearance.tokens().foreground)
        .width('100%')
      if (this.ask.detail) {
        Text(this.ask.detail)
          .fontSize(typeScale.secondary.fontSize)
          .fontColor(appearance.tokens().mutedForeground)
          .width('100%')
      }
      if (this.ask.answered) {
        Text(this.ask.answer ? this.ask.answer : t('Answer'))
          .fontSize(typeScale.secondary.fontSize)
          .fontColor(appearance.tokens().mutedForeground)
      } else if (this.ask.answerable) {
        if (this.ask.actions.length > 0) {
          ForEach(this.ask.actions, (action: AskActionView): void => {
            ActionButton({
              label: action.label,
              kind: action.id === 'allow' || action.id === 'always' ? 'primary' : 'secondary',
              busy: this.busy,
              onTap: (): void => {
                this.onAnswer(action.id);
              },
            })
          }, (action: AskActionView): string => action.id)
        } else if (this.ask.textInput) {
          Row({ space: 8 }) {
            TextInput({ text: $$this.draft, placeholder: t('Answer') })
              .layoutWeight(1)
              .height(42)
              .fontSize(typeScale.body.fontSize)
              .backgroundColor(appearance.tokens().card)
              .borderRadius(10)
              .onChange((value: string): void => {
                this.draft = value;
              })
            Button(t('Submit'))
              .height(42)
              .fontSize(typeScale.secondary.fontSize)
              .enabled(this.draft.trim().length > 0 && !this.busy)
              .onClick((): void => {
                this.onAnswer(this.draft.trim());
                this.draft = '';
              })
          }
          .width('100%')
        }
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(appearance.tokens().card)
    .borderRadius(12)
    .borderWidth(1)
    .borderColor(appearance.tokens().border)
  }
}

/** Read-only choice: the question, its options, the picked one highlighted. */
@ComponentV2
struct ChoiceCard {
  @Param choice: ChoiceView = { question: '', subtitle: '', options: [], answerId: '' };

  build() {
    Column({ space: 6 }) {
      Text(this.choice.question)
        .fontSize(typeScale.body.fontSize)
        .fontColor(appearance.tokens().foreground)
        .width('100%')
      if (this.choice.subtitle) {
        Text(this.choice.subtitle)
          .fontSize(typeScale.secondary.fontSize)
          .fontColor(appearance.tokens().mutedForeground)
      }
      ForEach(this.choice.options, (option: ChoiceOptionView): void => {
        Row({ space: 8 }) {
          Text(option.letter)
            .fontSize(typeScale.secondary.fontSize)
            .fontColor(appearance.tokens().mutedForeground)
          Text(option.label)
            .fontSize(typeScale.body.fontSize)
            .fontColor(option.id === this.choice.answerId
              ? appearance.tokens().foreground : appearance.tokens().mutedForeground)
            .fontWeight(option.id === this.choice.answerId ? FontWeight.Bold : FontWeight.Normal)
            .layoutWeight(1)
          if (option.id === this.choice.answerId) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(typeScale.secondary.fontSize + 'vp')
              .fontColor([appearance.tokens().success])
          }
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })
      }, (option: ChoiceOptionView): string => option.id)
    }
    .width('100%')
    .padding(12)
    .backgroundColor(appearance.tokens().card)
    .borderRadius(12)
  }
}

@ComponentV2
struct BlockContent {
  @Param view: BlockView = {
    tier: 'placeholder', kind: '', text: '', lines: [], steps: [], ask: null, choice: null,
    title: '', activity: false, attachment: null,
  };
  @Param botMessage: boolean = true;
  @Param busy: boolean = false;
  @Param botId: string = '';
  @Param groupId: string = '';
  @Event onAnswer: (answer: string) => void = (_answer: string): void => {};

  build() {
    if (this.view.tier === 'attachment' && this.view.attachment !== null) {
      AttachmentBlock({
        view: this.view.attachment,
        botId: this.botId,
        groupId: this.groupId,
      })
    } else if (this.view.tier === 'placeholder') {
      Text(UNSUPPORTED_BLOCK)
        .fontSize(typeScale.secondary.fontSize)
        .fontColor(appearance.tokens().faintForeground)
        .width('100%')
    } else if (this.view.kind === 'ask' && this.view.ask !== null) {
      AskCard({ ask: this.view.ask!, busy: this.busy, onAnswer: this.onAnswer })
    } else if (this.view.kind === 'choice' && this.view.choice !== null) {
      ChoiceCard({ choice: this.view.choice! })
    } else if (this.view.kind === 'card') {
      Column({ space: 4 }) {
        ForEach(this.view.lines, (line: BlockLine): void => {
          Row({ space: 8 }) {
            Text(line.k)
              .fontSize(typeScale.secondary.fontSize)
              .fontColor(appearance.tokens().mutedForeground)
            Text(line.v)
              .fontSize(typeScale.secondary.fontSize)
              .fontColor(appearance.tokens().foreground)
              .layoutWeight(1)
          }
          .width('100%')
        }, (line: BlockLine): string => `${line.k}:${line.v}`)
      }
      .width('100%')
    } else if (this.view.kind === 'steps') {
      Column({ space: 2 }) {
        ForEach(this.view.steps, (step: BlockStep): void => {
          Text(step.count > 1 ? `${step.label} ×${step.count}` : step.label)
            .fontSize(typeScale.secondary.fontSize)
            .fontColor(appearance.tokens().mutedForeground)
        }, (step: BlockStep): string => `${step.label}:${step.count}`)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    } else if (this.view.kind === 'routine_event') {
      Text(`${this.view.text}: ${this.view.title}`)
        .fontSize(typeScale.secondary.fontSize)
        .fontColor(appearance.tokens().mutedForeground)
    } else if (this.view.kind === 'progress') {
      if (this.view.activity) {
        Text(this.view.text)
          .fontSize(typeScale.secondary.fontSize)
          .fontColor(appearance.tokens().mutedForeground)
          .fontStyle(FontStyle.Italic)
      } else if (this.botMessage) {
        MarkdownText({ text: this.view.text, color: appearance.tokens().foreground })
      } else {
        Text(this.view.text)
          .fontSize(typeScale.body.fontSize)
          .fontColor(appearance.tokens().foreground)
      }
    } else if (this.view.tier === 'text' && this.view.title) {
      Column({ space: 2 }) {
        Text(this.view.title)
          .fontSize(typeScale.secondary.fontSize)
          .fontWeight(FontWeight.Medium)
          .fontColor(appearance.tokens().mutedForeground)
        if (this.view.text) {
          Text(this.view.text)
            .fontSize(typeScale.secondary.fontSize)
            .fontColor(appearance.tokens().foreground)
            .maxLines(4)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    } else if (this.view.kind === 'meta') {
      Text(this.view.text)
        .fontSize(typeScale.secondary.fontSize)
        .fontColor(appearance.tokens().mutedForeground)
    } else if (this.botMessage) {
      MarkdownText({ text: this.view.text, color: appearance.tokens().foreground })
    } else {
      Text(this.view.text)
        .fontSize(typeScale.body.fontSize)
        .fontColor(appearance.tokens().chatUserForeground)
    }
  }
}

/* ------------------------------- the bubble ------------------------------- */

/**
 * The reply line above a message: who and what it answers. A parent the transcript has not loaded
 * names nobody and cannot be jumped to. Mobile draws the parent's attachment before it; no
 * artifact surface here yet.
 */
@ComponentV2
struct ReplyLine {
  @Param author: string = '';
  @Param text: string = '';
  @Param unavailable: boolean = false;
  /** A reply under the person's own message hugs the right edge, as the message does. */
  @Param alignEnd: boolean = false;
  @Event onJump: () => void = (): void => {};

  build() {
    Row({ space: 4 }) {
      if (!this.unavailable) {
        SymbolGlyph($r('sys.symbol.arrowshape_turn_up_left'))
          .fontSize('12vp')
          .fontColor([appearance.tokens().mutedForeground])
          .accessibilityLevel('no')
      }
      Text(this.unavailable ? t('Original message unavailable') : `${this.author}: ${this.text}`)
        .fontSize(typeScale.caption.fontSize)
        .fontColor(appearance.tokens().mutedForeground)
        .maxLines(1)
        .textAlign(this.alignEnd ? TextAlign.End : TextAlign.Start)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(this.alignEnd ? 0 : 1)
        .constraintSize({ maxWidth: this.alignEnd ? '78%' : '100%' })
    }
    .width('100%')
    .padding(this.alignEnd ? { left: 16, right: 16 } : { left: 16, right: 48 })
    .alignItems(VerticalAlign.Center)
    .justifyContent(this.alignEnd ? FlexAlign.End : FlexAlign.Start)
    .margin({ bottom: 6 })
    .onClick((): void => {
      if (!this.unavailable) {
        this.onJump();
      }
    })
  }
}

/** The select-text sheet: the message's text, selectable, with a Done row to close. */
@ComponentV2
struct SelectTextSheet {
  @Param text: string = '';
  @Event onClose: () => void = (): void => {};

  build() {
    Column() {
      Row() {
        Blank()
        Button(t('Done'))
          .height(36)
          .backgroundColor(appearance.tokens().card)
          .fontColor(appearance.tokens().link)
          .onClick((): void => {
            this.onClose();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 6 })
      Scroll() {
        Text(this.text)
          .fontSize(typeScale.body.fontSize)
          .fontColor(appearance.tokens().foreground)
          .copyOption(CopyOptions.LocalDevice)
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 24 })
      }
      .layoutWeight(1)
      .align(Alignment.Start)
    }
    .width('100%')
    .height('70%')
    .backgroundColor(appearance.tokens().background)
  }
}

/** What the reply line shows of a message's parent. */
interface ReplyParts {
  author: string;
  text: string;
  unavailable: boolean;
}

@ComponentV2
export struct MessageBubble {
  @Param message: LiveMessage | null = null;
  @Param busy: boolean = false;
  @Param members: ThreadMember[] = [];
  @Param meId: string = '';
  @Param fallbackAuthor: string = '';
  /** The thread's own target, so attachment downloads carry the authorized botId/groupId. */
  @Param botId: string = '';
  @Param groupId: string = '';
  @Param canReply: boolean = false;
  /** The message this one answers, when the transcript holds it: its text stands in until the
   *  server's preview arrives, and it names an author the preview leaves out. */
  @Param parent: LiveMessage | null = null;
  @Event onAnswer: (message: LiveMessage, answer: string) => void =
    (_message: LiveMessage, _answer: string): void => {};
  @Event onJumpTo: (messageId: string) => void = (_messageId: string): void => {};
  /** M6: the Reply menu entry hands the message to the composer's reply flow. */
  @Event onReply: (message: LiveMessage) => void = (_message: LiveMessage): void => {};
  /** M7: the Speak menu entry reads the chat aloud from this message on. */
  @Event onSpeak: (message: LiveMessage) => void = (_message: LiveMessage): void => {};
  /** B1: the Quote sheet's confirmed excerpt, for the composer's reply line. */
  @Event onQuote: (message: LiveMessage, excerpt: string) => void =
    (_message: LiveMessage, _excerpt: string): void => {};
  /** Which sheet the long-press menu opened: ArkUI's bindSheet is one slot per node, so one
   *  sheet holds either panel and its kind picks the content. */
  @Local sheetKind: string = 'none';
  /** The menu of the message shown, found once per change of that message: finding it parses. */
  @Computed
  get menu(): MessageMenu {
    const message = this.message;
    if (message === null) {
      return { select: false, copyCode: false, copyText: '', selectText: '', quote: false, code: '' };
    }
    const like: MessageLike = { id: message.id, role: message.role, blocks: message.blocks };
    return messageMenu(like);
  }

  /** The wire's reply metadata narrowed to the shape the rules read. */
  private previewOf(message: LiveMessage): ReplyPreview | null {
    const raw = message.replyPreview;
    if (raw === undefined || raw === null) {
      return null;
    }
    const out: ReplyPreview = { page: raw['page'] === true };
    if (typeof raw['text'] === 'string') {
      out.text = raw['text'] as string;
    }
    if (typeof raw['role'] === 'string') {
      out.role = raw['role'] as string;
    }
    if (typeof raw['botId'] === 'string') {
      out.botId = raw['botId'] as string;
    }
    if (raw['author'] !== null && typeof raw['author'] === 'object' && !Array.isArray(raw['author'] as Object)) {
      out.author = raw['author'] as Record<string, Object>;
    }
    const attachment = raw['attachment'];
    if (attachment !== null && typeof attachment === 'object' && !Array.isArray(attachment as Object)) {
      const record = attachment as Record<string, Object>;
      const view: ReplyAttachment = {
        kind: typeof record['kind'] === 'string' ? record['kind'] as string : '',
        name: '',
      };
      if (typeof record['name'] === 'string') {
        view.name = record['name'] as string;
      }
      if (typeof record['artifactId'] === 'string') {
        view.artifactId = record['artifactId'] as string;
      }
      if (typeof record['mimeType'] === 'string') {
        view.mimeType = record['mimeType'] as string;
      }
      out.attachment = view;
    }
    return out;
  }

  /** The reply line's words, found once per change of what they depend on: the build reads them
   *  more than once, and a parent's preview parses the parent. */
  @Computed
  get reply(): ReplyParts | null {
    const message = this.message;
    return message === null ? null : this.replyParts(message);
  }

  private replyParts(message: LiveMessage): ReplyParts | null {
    if (!message.replyToMessageId && message.replyQuote === undefined) {
      return null;
    }
    const preview = this.previewOf(message);
    if (isPageOriginReply({ replyQuote: message.replyQuote, replyPreview: preview })) {
      return null;
    }
    const unavailable = preview === null || !message.replyToMessageId;
    const previewText = preview !== null && typeof preview.text === 'string' ? preview.text : '';
    const parent = this.parent;
    const parentText = parent === null ? undefined
      : previewMessageText({ id: parent.id, role: parent.role, blocks: parent.blocks },
        { photo: t('Photo'), attachment: t('Attachment'), message: t('Message') });
    const text = replyLabel(message.replyQuote,
      previewText || (preview?.attachment ? undefined : parentText),
      preview?.attachment ?? null,
      { photo: t('Photo'), attachment: t('Attachment') });
    return { author: this.replyAuthor(preview), text: text, unavailable: unavailable };
  }

  /** Who the parent speaks for: its preview says, else the parent itself. */
  private replyAuthor(preview: ReplyPreview | null): string {
    const parent = this.parent;
    const role = preview?.role ?? (parent !== null ? parent.role : undefined);
    if (role === 'user') {
      const author = preview?.author ?? (parent !== null ? parent.author : null);
      const other = otherAuthor(author, this.meId === '' ? undefined : this.meId);
      return other !== undefined && typeof other['name'] === 'string' ? other['name'] as string : t('You');
    }
    const botId = preview?.botId ?? (parent !== null ? parent.botId : undefined);
    const member = this.members.find((candidate: ThreadMember): boolean => candidate.botId === botId);
    if (member !== undefined && member.name.trim() !== '') {
      return member.name;
    }
    return this.fallbackAuthor !== '' ? this.fallbackAuthor : t('Bot');
  }

  private targetsOf(text: string): UserMentionTarget[] {
    if (this.members.length === 0) {
      return [];
    }
    const likes: MemberLike[] = this.members.map((member: ThreadMember): MemberLike => {
      const like: MemberLike = { botId: member.botId, name: member.name, color: member.color };
      return like;
    });
    return userMentionTargets(likes, text);
  }

  @Builder
  bodyOf(message: LiveMessage) {
    if (message.role === 'user') {
      Row() {
        Blank()
        Column({ space: 4 }) {
          ForEach(messageBlockViews(message.blocks), (view: BlockView): void => {
            if (view.kind === 'text' || view.kind === 'progress') {
              UserText({
                text: view.text,
                targets: this.targetsOf(view.text),
                fontSize: typeScale.body.fontSize,
                color: appearance.tokens().chatUserForeground,
              })
            } else {
              BlockContent({
                view: view,
                botMessage: false,
                busy: this.busy,
                botId: this.botId,
                groupId: this.groupId,
                onAnswer: (_a: string): void => {},
              })
            }
          }, (view: BlockView, index: number): string => `${index}:${view.kind}:${view.text}`)
        }
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
        .backgroundColor(appearance.tokens().chatUser)
        .borderRadius(16)
        .constraintSize({ maxWidth: '82%' })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 3, bottom: 3 })
    } else {
      Column({ space: 4 }) {
        ForEach(messageBlockViews(message.blocks), (view: BlockView): void => {
          BlockContent({
            view: view,
            botMessage: true,
            busy: this.busy,
            botId: this.botId,
            groupId: this.groupId,
            onAnswer: (answer: string): void => {
              this.onAnswer(message, answer);
            },
          })
        }, (view: BlockView, index: number): string => `${index}:${view.kind}:${view.text}`)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 48, top: 3, bottom: 3 })
    }
  }

  build() {
    if (this.message !== null) {
      Column() {
        // The line's parts are read here, not passed through a builder: a builder keeps the
        // values it was first built with, and these change (a parent loads, the language changes).
        if (this.reply !== null) {
          ReplyLine({
            author: this.reply!.author,
            text: this.reply!.text,
            unavailable: this.reply!.unavailable,
            alignEnd: this.message!.role === 'user',
            onJump: (): void => {
              const parentId = this.message?.replyToMessageId;
              if (parentId !== undefined) {
                this.onJumpTo(parentId);
              }
            },
          })
        }
        this.bodyOf(this.message!)
      }
      .bindContextMenu(this.menuBuilder(), ResponseType.LongPress)
      .bindSheet(this.sheetKind !== 'none', this.messageSheet(), {
        height: SheetSize.MEDIUM,
        showClose: false,
        onWillDismiss: (action: DismissSheetAction): void => {
          this.sheetKind = 'none';
          action.dismiss();
        },
      })
    }
  }

  @Builder
  messageSheet() {
    if (this.sheetKind === 'quote') {
      QuoteSheet({
        message: this.message,
        onCancel: (): void => {
          this.sheetKind = 'none';
        },
        onQuote: (excerpt: string): void => {
          this.sheetKind = 'none';
          if (this.message !== null) {
            this.onQuote(this.message, excerpt);
          }
        },
      })
    } else {
      SelectTextSheet({
        text: this.menu.selectText,
        onClose: (): void => {
          this.sheetKind = 'none';
        },
      })
    }
  }

  /** The mobile menu's subset, in its order. */
  @Builder
  menuBuilder() {
    Menu() {
      if (this.canReply && this.message?.seq !== undefined) {
        MenuItem({ content: t('Reply') })
          .onClick((): void => {
            if (this.message !== null) {
              this.onReply(this.message);
            }
          })
        if (this.menu.quote) {
          MenuItem({ content: t('Quote') })
            .onClick((): void => {
              this.sheetKind = 'quote';
            })
        }
      }
      if (this.message !== null && this.message.role === 'bot'
        && speechFromBlocks(this.message.blocks)) {
        MenuItem({ content: t('Speak message') })
          .onClick((): void => {
            if (this.message !== null) {
              this.onSpeak(this.message);
            }
          })
      }
      if (this.menu.select) {
        MenuItem({ content: t('Select text') })
          .onClick((): void => {
            this.sheetKind = 'select';
          })
      }
      MenuItem({ content: t('Copy') })
        .onClick((): void => {
          if (this.menu.copyText !== '') {
            void putClipboard(this.menu.copyText);
          }
        })
      if (this.menu.copyCode) {
        MenuItem({ content: t('Copy code') })
          .onClick((): void => {
            void putClipboard(this.menu.code);
          })
      }
    }
  }
}
