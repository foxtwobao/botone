// InboxPage (design §6/§7.2 M2): the signed-in home. Bots and groups mixed in server order
// (pinned first), each row showing its identity color, unread dot, preview, time and working dot.
// The list reads once and refreshes only on a roster signal or foreground (RosterStore); a failed
// read keeps the last rows painted under an offline banner. Archiving is a long-press context menu
// (the native pattern M1 uses for removal); opening a chat arrives with M3. Copy reuses catalog
// msgids; the account and server entries stay reachable from the header.
import { appearance } from '../../uikit/theme';
import { typeScale } from '../../uikit/tokens.generated';
import { ChatAvatar, UnreadDot, formatRowTime, previewSnippet } from '../../uikit/avatar';
import { ListSource } from '../../uikit/list-source';
import { ActionButton, ErrorText } from '../../uikit/controls';
import { t } from '../../i18n/i18n';
import { app } from '../../app/app-state';
import { rosterStore } from '../../stores/roster-store';
import type { RosterStore } from '../../stores/roster-store';
import { rowKey } from '../../stores/roster-projection';
import type { InboxRow } from '../../stores/roster-projection';
import { RosterHolder } from '../../realtime/roster-holder';

/** A list entry: the optional Pinned heading, or a chat row. */
class DisplayItem {
  type: string = 'row';
  title: string = '';
  row: InboxRow | null = null;
}

@ComponentV2
export struct InboxPage {
  @Param stack: NavPathStack = new NavPathStack();
  @Param store: RosterStore = rosterStore;
  @Local source: ListSource<DisplayItem> = new ListSource<DisplayItem>([]);
  private holder: RosterHolder = new RosterHolder();
  private offChanges: (() => void) | null = null;

  aboutToAppear(): void {
    this.source.reload(this.items());
    this.offChanges = this.store.subscribeChanges((): void => {
      this.source.reload(this.items());
    });
    this.holder.start();
    void this.store.load();
  }

  aboutToDisappear(): void {
    this.offChanges?.();
    this.offChanges = null;
    this.holder.stop();
  }

  private items(): DisplayItem[] {
    const rows = this.store.rows;
    const items: DisplayItem[] = [];
    if (rows.some((row: InboxRow): boolean => row.pinned)) {
      const heading = new DisplayItem();
      heading.type = 'heading';
      heading.title = t('Pinned');
      items.push(heading);
    }
    for (const row of rows) {
      const item = new DisplayItem();
      item.type = 'row';
      item.row = row;
      items.push(item);
    }
    return items;
  }

  private archiveTarget(row: InboxRow): Record<string, Object> {
    const input: Record<string, Object> = {};
    input['kind'] = row.kind;
    input['id'] = row.id;
    return input;
  }

  @Builder
  archiveMenu(row: InboxRow) {
    Menu() {
      MenuItem({ content: t('Archive') })
        .contentFontColor(appearance.tokens().foreground)
        .enabled(!this.store.archive.pending)
        .onClick((): void => {
          this.store.archive.run(this.archiveTarget(row));
        })
    }
  }

  @Builder
  entry(item: DisplayItem) {
    if (item.type === 'heading') {
      Text(item.title)
        .fontSize(typeScale.secondary.fontSize)
        .fontColor(appearance.tokens().mutedForeground)
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 4 })
    } else {
      this.chatRow(item.row!)
    }
  }

  @Builder
  chatRow(row: InboxRow) {
    Row({ space: 12 }) {
      ChatAvatar({ kind: row.kind, name: row.name, color: row.color, working: row.working, diameter: 48 })
      Column({ space: 3 }) {
        Row({ space: 6 }) {
          Text(row.name)
            .fontSize(typeScale.body.fontSize)
            .fontWeight(row.unread ? FontWeight.Bold : FontWeight.Medium)
            .fontColor(appearance.tokens().foreground)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (row.unread) {
            UnreadDot({ diameter: 8 })
          }
          Text(formatRowTime(row.updatedAt, Date.now()))
            .fontSize(typeScale.caption.fontSize)
            .fontColor(appearance.tokens().mutedForeground)
        }
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
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .accessibilityText(`${row.name}${row.working ? `, ${t('Working…')}` : ''}${row.unread ? `, ${t('unread')}` : ''}`)
    .bindContextMenu(this.archiveMenu(row), ResponseType.LongPress)
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
    Column() {
      Row({ space: 12 }) {
        Text(t('Chats'))
          .fontSize(typeScale.title.fontSize)
          .fontWeight(FontWeight.Bold)
          .fontColor(appearance.tokens().foreground)
        Blank()
        Text(t('Archived'))
          .fontSize(typeScale.secondary.fontSize)
          .fontColor(appearance.tokens().link)
          .padding(8)
          .onClick((): void => {
            this.stack.pushPathByName('archived', null);
          })
        Stack() {
          Circle()
            .width(32)
            .height(32)
            .fill(appearance.tokens().muted)
          Text((app.me?.name || app.me?.email || '?').trim().charAt(0).toUpperCase())
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(appearance.tokens().mutedForeground)
        }
        .width(32)
        .height(32)
        .accessibilityText(t('Account'))
        .onClick((): void => {
          this.stack.pushPathByName('account', null);
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      if (app.updateRequired) {
        Text(t('Update required'))
          .fontSize(typeScale.caption.fontSize)
          .fontColor(appearance.tokens().warning)
          .padding({ left: 16, right: 16, bottom: 4 })
      }

      if (app.me === null && app.meError) {
        Column({ space: 16 }) {
          ErrorText({ message: app.meError })
          ActionButton({
            label: t('Retry'),
            kind: 'secondary',
            onTap: (): void => {
              void app.loadMe();
            },
          })
        }
        .width('100%')
        .padding(20)
      } else {
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
        if (this.store.archive.error) {
          ErrorText({ message: this.store.archive.error })
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
          LazyForEach(this.source, (item: DisplayItem): void => {
            ListItem() {
              this.entry(item)
            }
          }, (item: DisplayItem): string =>
            item.type === 'heading' ? `heading-${item.title}` : rowKey(item.row!))
        }
        .layoutWeight(1)
        .width('100%')
        .cachedCount(8)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(appearance.tokens().background)
  }
}
