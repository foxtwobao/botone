// InboxPage (design §6/§7.2 M2): the signed-in home. Bots and groups mixed in server order
// (pinned first), each row showing its identity color, unread dot, preview, time and working dot.
// The list reads once and refreshes only on a roster signal or foreground (RosterStore); a failed
// read keeps the last rows painted under an offline banner. Archiving is a long-press context menu
// (the native pattern M1 uses for removal); opening a chat arrives with M3. The title names the
// selected Space and, with more than one Space, opens the switcher (A2). Copy reuses catalog
// msgids; the account and server entries stay reachable from the header.
import { appearance } from '../../uikit/theme';
import { typeScale } from '../../uikit/tokens.generated';
import { ChatAvatar, UnreadDot, previewSnippet } from '../../uikit/avatar';
import { formatRowTime } from '../../i18n/dates';
import { ListSource } from '../../uikit/list-source';
import { ActionButton, ErrorText } from '../../uikit/controls';
import { t } from '../../i18n/i18n';
import { app } from '../../app/app-state';
import { selectedSpaceId } from '../../net/session';
import { spaceStore } from '../../stores/space-store';
import { spaceSwitcher } from '../spaces/space-switch-controller';
import type { SpaceSwitchController } from '../spaces/space-switch-controller';
import type { SpaceSummaryView } from '../../contract/decode';
import { rosterStore } from '../../stores/roster-store';
import type { RosterStore } from '../../stores/roster-store';
import { rowKey } from '../../stores/roster-projection';
import type { InboxRow } from '../../stores/roster-projection';
import { RosterHolder } from '../../realtime/roster-holder';
import type { ThreadRoute } from '../chat/thread-route';

/** A list entry: the optional Pinned heading, or a chat row. */
export class DisplayItem {
  type: string = 'row';
  row: InboxRow | null = null;
}

/** The list projection: the heading when any row is pinned, then every row in server order.
 * Pure — no translation is baked into the items (a hot locale switch must not leave the old
 * language on screen); the heading renders t('Pinned') inside build(), which i18n re-traces. */
export function inboxDisplayItems(rows: InboxRow[]): DisplayItem[] {
  const items: DisplayItem[] = [];
  if (rows.some((row: InboxRow): boolean => row.pinned)) {
    const heading = new DisplayItem();
    heading.type = 'heading';
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

/** The LazyForEach key: locale-independent, so a locale switch re-renders the heading in place. */
export function inboxItemKey(item: DisplayItem): string {
  return item.type === 'heading' ? 'heading' : rowKey(item.row!);
}

@ComponentV2
export struct InboxPage {
  @Param stack: NavPathStack = new NavPathStack();
  @Param store: RosterStore = rosterStore;
  @Local source: ListSource<DisplayItem> = new ListSource<DisplayItem>([]);
  @Local switcher: SpaceSwitchController = spaceSwitcher;
  private holder: RosterHolder = new RosterHolder();
  private offChanges: (() => void) | null = null;

  /** The Space the person is in; the neutral title until the first read names it. */
  @Computed
  get spaceTitle(): string {
    return spaceStore.currentName || t('Chats');
  }

  @Computed
  get switchable(): boolean {
    return spaceStore.spaces.length > 1;
  }

  aboutToAppear(): void {
    this.source.reload(inboxDisplayItems(this.store.rows));
    this.offChanges = this.store.subscribeChanges((): void => {
      this.source.reload(inboxDisplayItems(this.store.rows));
    });
    this.holder.start();
    void this.store.load();
  }

  aboutToDisappear(): void {
    this.offChanges?.();
    this.offChanges = null;
    this.holder.stop();
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
      Text(t('Pinned'))
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
    .onClick((): void => {
      const route: ThreadRoute = {
        botId: row.kind === 'bot' ? row.id : '',
        groupId: row.kind === 'group' ? row.id : '',
        title: row.name,
        spaceId: selectedSpaceId(),
      };
      this.stack.pushPathByName('chat', route);
    })
  }

  @Builder
  spaceMenu() {
    Menu() {
      ForEach(spaceStore.spaces, (space: SpaceSummaryView): void => {
        MenuItem({ content: space.name })
          .selected(space.id === selectedSpaceId())
          .selectIcon(true)
          .contentFontColor(appearance.tokens().foreground)
          .onClick((): void => {
            void this.switchToSpace(space.id);
          })
      }, (space: SpaceSummaryView): string => space.id)
    }
  }

  /** The switcher's one outcome the page owns: a completed switch leaves no old chat in front. */
  private async switchToSpace(id: string): Promise<void> {
    if (await this.switcher.switchTo(id)) {
      this.stack.clear();
    }
  }

  private async retrySwitch(): Promise<void> {
    if (await this.switcher.retry()) {
      this.stack.clear();
    }
  }

  @Builder
  switchFailure() {
    Row({ space: 8 }) {
      ErrorText({ message: this.switcher.error })
        .layoutWeight(1)
      if (this.switcher.state.reason === 'unreachable') {
        Text(t('Try again.'))
          .fontSize(typeScale.secondary.fontSize)
          .fontColor(appearance.tokens().link)
          .padding(4)
          .onClick((): void => {
            void this.retrySwitch();
          })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8 })
  }

  @Builder
  newGroupMenu() {
    Menu() {
      MenuItem({ content: t('New group chat') })
        .contentFontColor(appearance.tokens().foreground)
        .onClick((): void => {
          this.stack.pushPathByName('newGroup', null);
        })
    }
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
        if (this.switchable) {
          Row({ space: 4 }) {
            Text(this.spaceTitle)
              .fontSize(typeScale.title.fontSize)
              .fontWeight(FontWeight.Bold)
              .fontColor(appearance.tokens().foreground)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            SymbolGlyph($r('sys.symbol.chevron_down'))
              .fontSize(typeScale.body.fontSize + 'vp')
              .fontColor([appearance.tokens().mutedForeground])
              .accessibilityLevel('no')
          }
          .bindMenu(this.spaceMenu)
        } else {
          Text(this.spaceTitle)
            .fontSize(typeScale.title.fontSize)
            .fontWeight(FontWeight.Bold)
            .fontColor(appearance.tokens().foreground)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Blank()
        Text('+')
          .fontSize(24)
          .fontColor(appearance.tokens().foreground)
          .padding({ left: 8, right: 8 })
          .accessibilityText(t('New group chat'))
          .bindMenu(this.newGroupMenu)
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
        .accessibilityText(t('Settings'))
        .onClick((): void => {
          this.stack.pushPathByName('settings', null);
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
        if (this.switcher.error) {
          this.switchFailure()
        } else if (this.store.offline) {
          // One row per failure: a switch that failed because the server was unreachable already
          // says so and carries its own retry, so the offline banner would only repeat it.
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
          }, (item: DisplayItem): string => inboxItemKey(item))
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
