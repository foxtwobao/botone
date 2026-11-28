// The "Not sent" bubble (B3): a parked failed send the user can retry or delete, the HarmonyOS
// take on mobile's failed-send-bubble. The caption says what happened; the tap retries (or
// offers the image-confirmation choices as an alert, mobile's Android path); long-press opens
// the menu with Try again / Send as file / Delete. Copy reuses catalog msgids; attachment names
// are product data, not copy.
import { appearance } from '../../uikit/theme';
import { typeScale } from '../../uikit/tokens.generated';
import { t } from '../../i18n/i18n';
import { isModelRequiredSendErrorText } from '../../outbox/outbox-record';
import type { OutboxAttachment } from '../../outbox/outbox-record';
import type { OutboxEntry } from '../../outbox/outbox';

@ComponentV2
export struct FailedSendBubble {
  @Require @Param entry: OutboxEntry;
  /** The account still has no model: the caption names the cause instead of offering a retry. */
  @Param needsModel: boolean = false;
  @Param onRetry: () => void = (): void => {};
  @Param onSendAsFile: () => void = (): void => {};
  @Param onDelete: () => void = (): void => {};
  @Param onAddModel: () => void = (): void => {};

  private modelRequired(): boolean {
    return this.needsModel && isModelRequiredSendErrorText(this.entry.record.error);
  }

  private retryable(): boolean {
    return this.entry.record.state !== 'refused';
  }

  private caption(): string {
    if (this.entry.busy) {
      return t('Sending…');
    }
    if (this.entry.record.imageConfirmation) {
      return t('Not sent. Tap for options');
    }
    if (this.modelRequired()) {
      return t('Not sent. No model');
    }
    return this.retryable() ? t('Not sent. Tap to retry') : t('Not sent');
  }

  private summary(): string {
    const parts: string[] = [];
    if (this.entry.record.text) {
      parts.push(this.entry.record.text);
    }
    for (const attachment of this.entry.record.attachments) {
      parts.push(attachment.name);
    }
    return parts.join(', ');
  }

  @Builder
  private actions() {
    Menu() {
      if (this.modelRequired()) {
        MenuItem({ content: t('Add model') }).onClick((): void => {
          this.onAddModel();
        })
      }
      if (this.entry.record.imageConfirmation) {
        MenuItem({ content: t('Send as file') }).onClick((): void => {
          this.onSendAsFile();
        })
      }
      if (this.retryable() && !this.modelRequired() && !this.entry.record.imageConfirmation) {
        MenuItem({ content: t('Try again') }).onClick((): void => {
          this.onRetry();
        })
      }
      MenuItem({ content: t('Delete') }).onClick((): void => {
        this.onDelete();
      })
    }
  }

  /** The image-confirmation tap: the same choices as the menu, as a system alert (no builder
   *  can be invoked from onClick, and this is the one path that needs one). */
  private showChoices(): void {
    const buttons: AlertDialogButtonOptions[] = [
      {
        value: t('Send as file'),
        fontColor: appearance.tokens().foreground,
        action: (): void => {
          this.onSendAsFile();
        },
      },
      {
        value: t('Try again'),
        fontColor: appearance.tokens().foreground,
        action: (): void => {
          this.onRetry();
        },
      },
      {
        value: t('Delete'),
        fontColor: appearance.tokens().destructive,
        action: (): void => {
          this.onDelete();
        },
      },
    ];
    this.getUIContext().showAlertDialog({
      title: this.caption(),
      message: this.entry.record.error,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      buttons: buttons,
    });
  }

  build() {
    Column({ space: 4 }) {
      Column({ space: 8 }) {
        if (this.entry.record.replyQuote) {
          Text(this.entry.record.replyQuote)
            .fontSize(typeScale.caption.fontSize)
            .fontColor(appearance.tokens().chatUserForeground)
            .opacity(0.8)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        if (this.entry.record.text) {
          Text(this.entry.record.text)
            .fontSize(typeScale.body.fontSize)
            .fontColor(appearance.tokens().chatUserForeground)
            .width('100%')
        }
        ForEach(this.entry.record.attachments, (attachment: OutboxAttachment): void => {
          Text(attachment.name)
            .fontSize(typeScale.caption.fontSize)
            .fontColor(appearance.tokens().chatUserForeground)
            .opacity(0.8)
            .width('100%')
        }, (attachment: OutboxAttachment): string => attachment.path)
      }
      .alignItems(HorizontalAlign.Start)
      .constraintSize({ maxWidth: '90%' })
      .backgroundColor(appearance.tokens().chatUser)
      .opacity(0.8)
      .borderRadius(20)
      .padding({ left: 14, right: 14, top: 12, bottom: 12 })
      Row({ space: 4 }) {
        if (!this.entry.busy) {
          SymbolGlyph($r('sys.symbol.exclamationmark_circle_fill'))
            .fontSize('13vp')
            .fontColor([appearance.tokens().destructive])
        }
        Text(this.caption())
          .fontSize(typeScale.caption.fontSize)
          .fontColor(this.entry.busy
            ? appearance.tokens().mutedForeground : appearance.tokens().destructive)
      }
    }
    .alignItems(HorizontalAlign.End)
    .width('100%')
    .padding({ top: 12 })
    .opacity(this.entry.busy ? 0.6 : 1)
    .enabled(!this.entry.busy)
    .accessibilityText(this.entry.busy
      ? `${this.summary()}. ${this.caption()}`
      : `${this.summary()}. ${this.caption()}. ${t('Long press to delete')}`)
    .bindContextMenu(this.actions, ResponseType.LongPress)
    .onClick((): void => {
      if (this.entry.record.imageConfirmation) {
        // The choices are the point; a plain retry would repeat the refusal.
        this.showChoices();
        return;
      }
      if (this.retryable() && !this.modelRequired()) {
        this.onRetry();
      }
    })
  }
}
