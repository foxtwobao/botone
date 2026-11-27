import { appearance } from '../../uikit/theme';
import { typeScale } from '../../uikit/tokens.generated';
import { t } from '../../i18n/i18n';
import { isAttachmentImageMimeType } from '../../thread/attachments';
import type { DraftAttachment } from '../../thread/attachment-files';
import type { LiveMessage, ThreadMember } from '../../thread/thread-snapshot';
import { channelMessageSender, otherAuthor, previewMessageText, replyAttachment, replyLabel } from '../../thread/message-text';
import type { MessageLike, PreviewLabels, ReplyAttachment, ReplyLabels } from '../../thread/message-text';
import { ArtifactImage, localImageUri } from './media-attachments';

/** One draft attachment. A component of its own: a ForEach item never re-reads state it uses directly. */
@ComponentV2
struct AttachmentChip {
  @Param item: DraftAttachment = { path: '', name: '', mimeType: '', size: 0 };
  @Param busy: boolean = false;
  @Event onRemove: (path: string) => void = (_path: string): void => {};

  build() {
    Row({ space: 6 }) {
      if (isAttachmentImageMimeType(this.item.mimeType)) {
        Image(localImageUri(this.item.path))
          .width(32).height(32).objectFit(ImageFit.Cover).borderRadius(6).clip(true)
          .accessibilityLevel('no')
      }
      Text(this.item.name)
        .fontSize(typeScale.caption.fontSize)
        .fontColor(appearance.tokens().foreground)
        .constraintSize({ maxWidth: 110 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (!this.busy) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize('16vp')
            .fontColor([appearance.tokens().foreground])
        }
          .width(44).height(44)
          .backgroundColor(appearance.tokens().card)
          .accessibilityText(this.removeLabel())
          .onClick((): void => { this.onRemove(this.item.path); })
      }
    }
    .padding({ left: 8, right: this.busy ? 10 : 0 })
    .backgroundColor(appearance.tokens().card)
    .borderRadius(10)
  }

  private removeLabel(): string {
    const values: Record<string, string | number> = {};
    values['name'] = this.item.name;
    return t('Remove {name}', values);
  }
}

@ComponentV2
export struct ComposerAttachments {
  @Param attachments: DraftAttachment[] = [];
  @Param busy: boolean = false;
  @Event onRemove: (path: string) => void = (_path: string): void => {};

  build() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.attachments, (item: DraftAttachment): void => {
          AttachmentChip({
            item: item, busy: this.busy,
            onRemove: (path: string): void => { this.onRemove(path); },
          })
        }, (item: DraftAttachment): string => item.path)
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .align(Alignment.Start)
    .width('100%')
  }
}

@ComponentV2
export struct ComposerReplyPreview {
  @Param message: LiveMessage | null = null;
  /** B1: the excerpt the quote sheet confirmed; non-empty shows it instead of the parent preview. */
  @Param quote: string = '';
  @Param members: ThreadMember[] = [];
  @Param meId: string = '';
  @Param title: string = '';
  @Param botId: string = '';
  @Param groupId: string = '';
  @Param busy: boolean = false;
  @Event onClose: () => void = (): void => {};

  @Computed
  get attachment(): ReplyAttachment | null {
    return this.message === null ? null : replyAttachment(this.message.blocks);
  }

  @Computed
  get author(): string {
    const message = this.message;
    if (message?.role === 'user') {
      const other = otherAuthor(message.author, this.meId || undefined);
      const name = other?.['name'];
      return typeof name === 'string' && name ? name as string : channelMessageSender(message.blocks) ?? t('You');
    }
    const member = this.members.find((candidate: ThreadMember): boolean => candidate.botId === message?.botId);
    return member?.name.trim() || this.title || t('Bot');
  }

  @Computed
  get summary(): string {
    const message = this.message;
    const labels: PreviewLabels = { photo: t('Photo'), attachment: t('Attachment'), message: t('Message') };
    const like: MessageLike | null = message === null ? null : {
      id: message.id, role: message.role, blocks: message.blocks,
    };
    const text = like === null ? '' : previewMessageText(like, labels);
    const replyLabels: ReplyLabels = { photo: labels.photo, attachment: labels.attachment };
    return replyLabel(this.quote, text, this.attachment, replyLabels);
  }

  build() {
    Row({ space: 8 }) {
      if (this.attachment?.kind === 'image' && this.attachment?.artifactId && this.attachment?.mimeType) {
        ArtifactImage({
          reference: {
            botId: this.botId, groupId: this.groupId,
            artifactId: this.attachment!.artifactId!, mimeType: this.attachment!.mimeType!,
          },
          thumbnail: true,
        })
      }
      Column({ space: 3 }) {
        Text(this.author).fontSize(typeScale.caption.fontSize).fontColor(appearance.tokens().mutedForeground)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.summary).fontSize(typeScale.secondary.fontSize).fontColor(appearance.tokens().foreground)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (!this.busy) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize('16vp')
            .fontColor([appearance.tokens().foreground])
        }.width(44).height(44)
          .backgroundColor(appearance.tokens().card)
          .accessibilityText(t('Cancel reply'))
          .onClick((): void => { this.onClose(); })
      }
    }
    .width('100%')
    .padding({ left: 10, right: this.busy ? 10 : 0 })
    .borderRadius(10)
    .backgroundColor(appearance.tokens().card)
  }
}
