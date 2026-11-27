// The quote sheet (B1): the message's quotable text, each segment read-only and selectable.
// Quote hands the selected excerpt to the composer, which sends it with the reply. The text comes
// from message-quote's sender-side conversion, not the select sheet's preview text: the excerpt
// must stay findable in the parent message on the server, or the reply silently loses its quote.
import { appearance } from '../../uikit/theme';
import { typeScale } from '../../uikit/tokens.generated';
import { t } from '../../i18n/i18n';
import type { LiveMessage } from '../../thread/thread-snapshot';
import { quotableMessageSegments, truncateReplyQuote } from '../../thread/message-quote';

@ComponentV2
export struct QuoteSheet {
  @Param message: LiveMessage | null = null;
  @Event onCancel: () => void = (): void => {};
  @Event onQuote: (excerpt: string) => void = (_excerpt: string): void => {};
  /** The last non-collapsed selection; a tap or caret move keeps it armed, as mobile does. */
  @Local selectionSegment: number = -1;
  @Local selectionStart: number = 0;
  @Local selectionEnd: number = 0;

  /** A selectable TextArea raises a soft keyboard on long-press; the sheet only reads text, so
   *  an empty custom keyboard takes its place. */
  @Builder
  noKeyboard() {
    Column()
      .width(0)
      .height(0)
  }

  @Computed
  get segments(): string[] {
    const message = this.message;
    return message === null ? [] : quotableMessageSegments(message.role, message.blocks);
  }

  private excerpt(): string {
    const segment = this.segments[this.selectionSegment];
    if (this.selectionSegment < 0 || segment === undefined) {
      return '';
    }
    const start = Math.min(this.selectionStart, this.selectionEnd);
    const end = Math.max(this.selectionStart, this.selectionEnd);
    return truncateReplyQuote(segment.slice(start, end).trim());
  }

  build() {
    Column() {
      Row() {
        Button(t('Cancel'))
          .height(36)
          .backgroundColor(appearance.tokens().card)
          .fontColor(appearance.tokens().link)
          .onClick((): void => {
            this.onCancel();
          })
        Blank()
        Button(t('Quote'))
          .height(36)
          .backgroundColor(appearance.tokens().card)
          .fontColor(appearance.tokens().link)
          .enabled(this.excerpt() !== '')
          .opacity(this.excerpt() !== '' ? 1 : 0.5)
          .onClick((): void => {
            const excerpt = this.excerpt();
            if (excerpt !== '') {
              this.onQuote(excerpt);
            }
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 6 })

      Scroll() {
        Column() {
          ForEach(this.segments, (segment: string, index: number): void => {
            TextArea({ text: segment })
              .width('100%')
              .fontSize(typeScale.body.fontSize)
              .fontColor(appearance.tokens().foreground)
              .backgroundColor(Color.Transparent)
              .padding({ left: 16, right: 16 })
              .margin({ top: index === 0 ? 0 : 12 })
              .enableKeyboardOnFocus(false)
              .customKeyboard(this.noKeyboard())
              .onWillInsert((): boolean => false)
              .onWillDelete((): boolean => false)
              .onTextSelectionChange((start: number, end: number): void => {
                if (start === end) {
                  return;
                }
                this.selectionSegment = index;
                this.selectionStart = start;
                this.selectionEnd = end;
              })
          }, (segment: string, index: number): string => `${index}:${segment.length}:${segment.slice(0, 16)}`)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .align(Alignment.Start)
      .width('100%')
    }
    .width('100%')
    .height('70%')
    .backgroundColor(appearance.tokens().background)
    .accessibilityText(t('Quote selection'))
  }
}