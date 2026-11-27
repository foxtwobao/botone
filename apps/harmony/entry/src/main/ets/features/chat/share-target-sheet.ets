import { appearance } from '../../uikit/theme';
import { typeScale } from '../../uikit/tokens.generated';
import { t } from '../../i18n/i18n';
import { selectedSpaceId } from '../../net/session';
import { RosterHolder } from '../../realtime/roster-holder';
import { rosterStore } from '../../stores/roster-store';
import { incomingShare } from '../../stores/incoming-share-store';
import { sharePreview } from '../../thread/incoming-share';
import type { SharePreview, SharedFile } from '../../thread/incoming-share';
import type { InboxRow } from '../../stores/roster-projection';
import type { ThreadRoute } from './thread-route';

@ComponentV2
export struct ShareTargetSheet {
  @Param stack: NavPathStack = new NavPathStack();
  private holder: RosterHolder = new RosterHolder();

  aboutToAppear(): void {
    this.holder.start();
    void rosterStore.load();
  }

  aboutToDisappear(): void {
    this.holder.stop();
  }

  @Computed
  get preview(): SharePreview | null {
    const share = incomingShare.pending;
    return share === null ? null : sharePreview(share);
  }

  private open(row: InboxRow): void {
    const share = incomingShare.take();
    if (share === null) {
      return;
    }
    const route: ThreadRoute = {
      botId: row.kind === 'bot' ? row.id : '',
      groupId: row.kind === 'group' ? row.id : '',
      title: row.name,
      spaceId: selectedSpaceId(),
      share: share,
    };
    // A share starts fresh (mobile resets to home + chat): back leaves the chat for the inbox.
    this.stack.clear();
    this.stack.pushPathByName('chat', route);
  }

  private fileLabel(count: number): string {
    const values: Record<string, string | number> = {};
    values['count'] = count;
    return t('{count} files', values);
  }

  build() {
    Column({ space: 10 }) {
      Row() {
        Text(t('Share to'))
          .fontSize(typeScale.headline.fontSize)
          .fontWeight(FontWeight.Medium)
          .fontColor(appearance.tokens().foreground)
          .layoutWeight(1)
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize('16vp')
            .fontColor([appearance.tokens().foreground])
        }.width(44).height(44)
          .backgroundColor(appearance.tokens().card)
          .accessibilityText(t('Close'))
          .onClick((): void => { incomingShare.cancel(); })
      }
      if (this.preview !== null) {
        Column({ space: 8 }) {
          if (this.preview.text) {
            Text(this.preview.text)
              .fontSize(typeScale.secondary.fontSize)
              .fontColor(appearance.tokens().mutedForeground)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          if (this.preview.images.length) {
            Row({ space: 8 }) {
              ForEach(this.preview.images, (file: SharedFile): void => {
                // Built inline: a builder's by-value argument keeps its first value.
                Image(file.uri)
                  .width(48).height(48).objectFit(ImageFit.Cover).borderRadius(8).clip(true)
                  .backgroundColor(appearance.tokens().muted)
                  .accessibilityLevel('no')
              }, (file: SharedFile): string => file.uri)
              if (this.preview.extraImages) {
                Text(`+${this.preview.extraImages}`)
                  .fontSize(typeScale.secondary.fontSize)
                  .fontColor(appearance.tokens().mutedForeground)
              }
            }
          }
          if (this.preview.fileCount) {
            Text(this.preview.fileName || this.fileLabel(this.preview.fileCount))
              .fontSize(typeScale.secondary.fontSize)
              .fontColor(appearance.tokens().mutedForeground)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      if (rosterStore.loading && rosterStore.rows.length === 0) {
        LoadingProgress().width(28).height(28).color(appearance.tokens().foreground)
      } else if (rosterStore.rows.length === 0) {
        Text(rosterStore.error || t('No bots'))
          .fontSize(typeScale.secondary.fontSize).fontColor(appearance.tokens().mutedForeground)
      }
      List() {
        ForEach(rosterStore.rows, (row: InboxRow): void => {
          ListItem() {
            Row({ space: 12 }) {
              Text(row.name).fontSize(typeScale.body.fontSize).fontColor(appearance.tokens().foreground)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
            }
            .width('100%')
            .padding(12)
            .onClick((): void => { this.open(row); })
          }
        }, (row: InboxRow): string => `${row.kind}:${row.id}`)
      }
      .layoutWeight(1)
      .width('100%')
    }
    .padding(16)
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(appearance.tokens().background)
  }
}
