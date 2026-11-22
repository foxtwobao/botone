// One transcript message: the user's plain-text bubble, the bot's markdown-lite blocks, the
// three-tier degradation (unknown kinds → one placeholder line), the live progress bubble, ask
// cards (approval actions + text answer), and read-only choice. Row-level rendering: a changed
// message re-renders alone (the store's row key carries content).
import { appearance } from '../../uikit/theme';
import { typeScale } from '../../uikit/tokens.generated';
import { ActionButton } from '../../uikit/controls';
import { t } from '../../i18n/i18n';
import { UNSUPPORTED_BLOCK } from '../../i18n/harmony-strings';
import type { LiveMessage } from '../../thread/thread-snapshot';
import { blockView, messageBlockViews } from '../../thread/block-view';
import type { AskActionView, AskView, BlockLine, BlockStep, BlockView, ChoiceOptionView, ChoiceView } from '../../thread/block-view';
import { parseMarkdownLite } from '../../thread/markdown-lite';
import type { InlineSpan, MarkdownSegment } from '../../thread/markdown-lite';
import { app } from '../../app/app-state';

/** Heading spans render bold. */
function boldSpans(spans: InlineSpan[]): InlineSpan[] {
  return spans.map((span: InlineSpan): InlineSpan => {
    const bold: InlineSpan = { text: span.text, bold: true, italic: span.italic, code: span.code, href: span.href };
    return bold;
  });
}

/** Inline spans as one Text with styled Spans (bold/italic/code/link). */
@ComponentV2
struct InlineText {
  @Param spans: InlineSpan[] = [];
  @Param color: string = '';
  @Param fontSize: number = 15;

  build() {
    Text() {
      ForEach(this.spans, (span: InlineSpan): void => {
        if (span.href) {
          Span(span.text)
            .fontColor(appearance.tokens().link)
            .fontSize(this.fontSize)
            .decoration({ type: TextDecorationType.Underline, color: appearance.tokens().link })
            .onClick((): void => {
              void app.openExternal(span.href);
            })
        } else if (span.code) {
          Span(span.text)
            .fontFamily('monospace')
            .fontSize(this.fontSize - 1)
            .fontColor(this.color)
            .backgroundColor(appearance.tokens().muted)
        } else {
          Span(span.text)
            .fontColor(this.color)
            .fontSize(this.fontSize)
            .fontWeight(span.bold ? FontWeight.Bold : FontWeight.Normal)
            .fontStyle(span.italic ? FontStyle.Italic : FontStyle.Normal)
        }
      }, (span: InlineSpan, index: number): string => `${index}:${span.text}`)
    }
  }
}

@ComponentV2
struct MarkdownText {
  @Param text: string = '';
  @Param color: string = '';

  build() {
    Column({ space: 6 }) {
      ForEach(parseMarkdownLite(this.text), (segment: MarkdownSegment): void => {
        if (segment.kind === 'code') {
          Text(segment.code)
            .fontFamily('monospace')
            .fontSize(typeScale.secondary.fontSize)
            .fontColor(this.color)
            .backgroundColor(appearance.tokens().muted)
            .borderRadius(8)
            .padding(10)
            .width('100%')
        } else if (segment.kind === 'heading') {
          InlineText({
            spans: boldSpans(segment.spans),
            color: this.color,
            fontSize: segment.marker === '1' ? typeScale.title.fontSize : typeScale.body.fontSize + 1,
          })
        } else if (segment.kind === 'list-item') {
          Row({ space: 6 }) {
            Text(segment.marker)
              .fontSize(typeScale.body.fontSize)
              .fontColor(appearance.tokens().mutedForeground)
            InlineText({ spans: segment.spans, color: this.color, fontSize: typeScale.body.fontSize })
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        } else if (segment.kind === 'quote') {
          Row() {
            Column()
              .width(3)
              .height('100%')
              .backgroundColor(appearance.tokens().border)
            InlineText({ spans: segment.spans, color: appearance.tokens().mutedForeground, fontSize: typeScale.body.fontSize })
              .layoutWeight(1)
              .padding({ left: 8 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        } else {
          InlineText({ spans: segment.spans, color: this.color, fontSize: typeScale.body.fontSize })
        }
      }, (segment: MarkdownSegment, index: number): string => `${index}:${segment.kind}:${segment.code}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

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
            TextInput({ text: this.draft, placeholder: t('Answer') })
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
            Text('✓')
              .fontSize(typeScale.secondary.fontSize)
              .fontColor(appearance.tokens().success)
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
    title: '', activity: false,
  };
  @Param botMessage: boolean = true;
  @Param busy: boolean = false;
  @Event onAnswer: (answer: string) => void = (_answer: string): void => {};

  build() {
    if (this.view.tier === 'placeholder') {
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



@ComponentV2
export struct MessageBubble {
  @Param message: LiveMessage | null = null;
  @Param busy: boolean = false;
  @Event onAnswer: (message: LiveMessage, answer: string) => void =
    (_message: LiveMessage, _answer: string): void => {};

  build() {
    if (this.message !== null) {
      if (this.message!.role === 'user') {
        Row() {
          Blank()
          Column({ space: 4 }) {
            ForEach(messageBlockViews(this.message!.blocks), (view: BlockView): void => {
              BlockContent({ view: view, botMessage: false, busy: this.busy, onAnswer: (_a: string): void => {} })
            }, (view: BlockView, index: number): string => `${index}:${view.kind}`)
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
          ForEach(messageBlockViews(this.message!.blocks), (view: BlockView): void => {
            BlockContent({
              view: view,
              botMessage: true,
              busy: this.busy,
              onAnswer: (answer: string): void => {
                this.onAnswer(this.message!, answer);
              },
            })
          }, (view: BlockView, index: number): string => `${index}:${view.kind}`)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 16, right: 48, top: 3, bottom: 3 })
      }
    }
  }
}
