// ArchivedPage (design §7.2 M2): archived bots and groups, each with a visible Restore action.
// The list reads through the QueryCache and refreshes on a roster signal or foreground; restore is
// a SaveController write that, on success, marks the roster and both archived lists stale and
// re-reads them. A failed read keeps the last rows under an offline banner. Copy reuses msgids.
import { appearance } from '../../uikit/theme';
import { typeScale } from '../../uikit/tokens.generated';
import { ChatAvatar, formatRowTime, previewSnippet } from '../../uikit/avatar';
import { ListSource } from '../../uikit/list-source';
import { ActionButton, ErrorText } from '../../uikit/controls';
import { t } from '../../i18n/i18n';
import { archivedStore } from '../../stores/archived-store';
import type { ArchivedStore } from '../../stores/archived-store';
import { rowKey } from '../../stores/roster-projection';
import type { InboxRow } from '../../stores/roster-projection';
import { RosterHolder } from '../../realtime/roster-holder';

@ComponentV2
export struct ArchivedPage {
  @Param stack: NavPathStack = new NavPathStack();
  @Param store: ArchivedStore = archivedStore;
  @Local source: ListSource<InboxRow> = new ListSource<InboxRow>([]);
  private holder: RosterHolder = new RosterHolder();
  private offChanges: (() => void) | null = null;

  aboutToAppear(): void {
    this.source.reload(this.store.rows);
    this.offChanges = this.store.subscribeChanges((): void => {
      this.source.reload(this.store.rows);
    });
    this.holder.start();
    void this.store.load();
  }

  aboutToDisappear(): void {
    this.offChanges?.();
    this.offChanges = null;
    this.holder.stop();
  }

  private restoreTarget(row: InboxRow): Record<string, Object> {
    const input: Record<string, Object> = {};
    input['kind'] = row.kind;
    input['id'] = row.id;
    return input;
  }

  private isRestoring(row: InboxRow): boolean {
    return this.store.restore.pending && this.store.restore.input !== null
      && this.store.restore.input['id'] === row.id;
  }

  @Builder
  archivedRow(row: InboxRow) {
    Row({ space: 12 }) {
      ChatAvatar({ kind: row.kind, name: row.name, color: row.color, working: false, diameter: 44 })
      Column({ space: 3 }) {
        Text(row.name)
          .fontSize(typeScale.body.fontSize)
          .fontWeight(FontWeight.Medium)
          .fontColor(appearance.tokens().foreground)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(previewSnippet(row.preview, 40) || t('No messages yet'))
          .fontSize(typeScale.secondary.fontSize)
          .fontColor(appearance.tokens().mutedForeground)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Button({ type: ButtonType.Capsule, stateEffect: true }) {
        if (this.isRestoring(row)) {
          LoadingProgress()
            .width(18)
            .height(18)
            .color(appearance.tokens().foreground)
        } else {
          Text(t('Restore'))
            .fontSize(typeScale.secondary.fontSize)
            .fontWeight(FontWeight.Medium)
            .fontColor(appearance.tokens().foreground)
        }
      }
      .height(34)
      .padding({ left: 14, right: 14 })
      .backgroundColor(appearance.tokens().muted)
      .enabled(!this.store.restore.pending)
      .onClick((): void => {
        this.store.restore.run(this.restoreTarget(row));
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .accessibilityText(row.name)
  }

  @Builder
  offlineBanner() {
    Row({ space: 8 }) {
      Text(t('Could not reach the server'))
        .fontSize(typeScale.secondary.fontSize)
        .fontColor(appearance.tokens().warning)
        .layoutWeight(1)
      Text(t('Retry'))
        .fontSize(typeScale.secondary.fontSize)
        .fontColor(appearance.tokens().link)
        .onClick((): void => {
          void this.store.load();
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .backgroundColor(appearance.tokens().card)
  }

  build() {
    NavDestination() {
      Column() {
        Row() {
          Text(t('Archived'))
            .fontSize(typeScale.title.fontSize)
            .fontWeight(FontWeight.Bold)
            .fontColor(appearance.tokens().foreground)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 8 })

        if (this.store.offline) {
          this.offlineBanner()
        }
        if (this.store.error && !this.store.offline) {
          Column({ space: 8 }) {
            ErrorText({ message: this.store.error })
            ActionButton({
              label: t('Retry'),
              kind: 'secondary',
              onTap: (): void => {
                void this.store.load();
              },
            })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8 })
        }
        if (this.store.restore.error) {
          ErrorText({ message: this.store.restore.error })
            .padding({ left: 16, right: 16, top: 8 })
        }
        if (this.store.loading && !this.store.loaded) {
          Row() {
            LoadingProgress()
              .width(28)
              .height(28)
              .color(appearance.tokens().foreground)
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding(30)
        }
        List() {
          LazyForEach(this.source, (row: InboxRow): void => {
            ListItem() {
              this.archivedRow(row)
            }
          }, (row: InboxRow): string => rowKey(row))
        }
        .layoutWeight(1)
        .width('100%')
        .cachedCount(8)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(appearance.tokens().background)
    }
    .hideTitleBar(true)
    .backgroundColor(appearance.tokens().background)
  }
}
