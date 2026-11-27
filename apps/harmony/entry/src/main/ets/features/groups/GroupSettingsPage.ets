// GroupSettingsPage (M8, design §7.2): the group's name, its members and the delete action. The
// roster (spaces/list) is the one read: it carries every active bot and each group's members. A
// membership save sends the baseline the server checks against; when another client changed the
// group meanwhile the server answers the precondition refusal, the roster is re-read and the
// visit's unsaved edits are merged over the new members (rebaseGroupEdit) — the user saves again.
// The delete leaves the whole stack (the chat under it holds a group that no longer exists).
import { appearance } from '../../uikit/theme';
import { typeScale } from '../../uikit/tokens.generated';
import { ActionButton, ErrorText, Field } from '../../uikit/controls';
import { t } from '../../i18n/i18n';
import { rosterStore } from '../../stores/roster-store';
import { SaveController } from '../../query/save-controller';
import type { SaveSend } from '../../query/save-controller';
import { RpcError, errorText } from '../../net/errors';
import { decodeOk } from '../../contract/decode';
import { decodeGroupWithMembers } from '../../contract/decode-groups';
import type { GroupView } from '../../contract/decode';
import { BotChecklist } from './group-pickers';
import {
  activeMemberIds,
  groupUpdateInput,
  isGroupChangedError,
  rebaseGroupEdit,
  GROUP_MEMBER_MAX,
  GROUP_MEMBER_MIN,
  GROUP_NAME_MAX_LENGTH,
} from './group-rules';
import type { GroupEdit } from './group-rules';

@ComponentV2
export struct GroupSettingsPage {
  @Param stack: NavPathStack = new NavPathStack();
  @Param groupId: string = '';
  @Local name: string = '';
  @Local selected: string[] = [];
  @Local loaded: boolean = false;
  /** What the screen shows instead of the form: the roster's own failure or "not found". */
  @Local missing: string = '';
  @Local saveError: string = '';
  @Local removeError: string = '';
  /** The membership this visit last read; expectedBotIds carries it, never a fresher read. */
  private baseline: string[] = [];
  private baselineName: string = '';
  private loadedGroupId: string = '';
  /** The members this visit took off; a refresh keeps them off. */
  private deselected: Set<string> = new Set<string>();
  private active: boolean = false;
  @Local saving: SaveController = new SaveController({
    save: async (input: Record<string, Object>, send: SaveSend): Promise<void> => {
      if (decodeGroupWithMembers(await send('groups/update', input)) === null) {
        throw new RpcError('Unexpected response from the server');
      }
    },
    stale: ['spaces/list'],
    onSaved: (): void => {
      // Backed out while the save was in flight: the page is gone, and the pop would take the
      // chat under it too.
      if (!this.active) {
        return;
      }
      void rosterStore.load();
      this.stack.pop();
    },
    onFailed: (error: RpcError): void => {
      if (isGroupChangedError(error)) {
        void this.rebaseAfterConflict();
      } else {
        this.saveError = errorText(error, t('Could not save group'));
      }
    },
  });
  @Local removal: SaveController = new SaveController({
    save: async (input: Record<string, Object>, send: SaveSend): Promise<void> => {
      if (!decodeOk(await send('groups/remove', input))) {
        throw new RpcError('Unexpected response from the server');
      }
    },
    stale: ['spaces/list'],
    onSaved: (): void => {
      void rosterStore.load();
      this.stack.clear();
    },
    onFailed: (error: RpcError): void => {
      this.removeError = errorText(error, t('Could not delete group'));
    },
  });

  aboutToAppear(): void {
    this.active = true;
    const group = this.findGroup();
    if (group !== null) {
      this.initFromGroup(group);
      return;
    }
    if (rosterStore.loaded) {
      this.missing = t('Group not found');
      return;
    }
    void rosterStore.load().then((): void => {
      if (!this.active) {
        return;
      }
      // Offline is not "not found": the store's own failure text is what the user needs.
      if (rosterStore.error !== '') {
        this.missing = rosterStore.error;
        return;
      }
      const next = this.findGroup();
      if (next !== null) {
        this.initFromGroup(next);
      } else {
        this.missing = t('Group not found');
      }
    });
  }

  aboutToDisappear(): void {
    this.active = false;
  }

  private findGroup(): GroupView | null {
    for (const group of rosterStore.groups) {
      if (group.id === this.groupId) {
        return group;
      }
    }
    return null;
  }

  private activeBotIds(): string[] {
    const ids: string[] = [];
    for (const bot of rosterStore.bots) {
      ids.push(bot.id);
    }
    return ids;
  }

  /** The group as this visit reads it: its active members are the baseline the server checks. */
  private initFromGroup(group: GroupView): void {
    this.loadedGroupId = group.id;
    this.baselineName = group.name;
    this.name = group.name;
    this.baseline = activeMemberIds(group, this.activeBotIds());
    this.selected = [...this.baseline];
    this.deselected.clear();
    this.loaded = true;
    this.missing = '';
    this.saveError = '';
  }

  /** After the server's membership refusal: re-read, then merge this visit's edits over it. */
  private async rebaseAfterConflict(): Promise<void> {
    await rosterStore.load();
    if (!this.active) {
      return;
    }
    const next = this.findGroup();
    if (next === null) {
      this.missing = t('Group not found');
      return;
    }
    const activeBots = this.activeBotIds();
    const nextMembers = activeMemberIds(next, activeBots);
    const previous: GroupEdit = { groupId: this.loadedGroupId, members: this.baseline };
    const incoming: GroupEdit = { groupId: next.id, members: nextMembers };
    this.selected = rebaseGroupEdit(previous, incoming, activeBots, this.selected, this.deselected);
    this.baseline = nextMembers;
    this.loadedGroupId = next.id;
    // A name the user did not touch takes the re-read one; an edit stays.
    if (this.name === this.baselineName) {
      this.name = next.name;
    }
    this.baselineName = next.name;
    this.missing = '';
    this.saveError = '';
  }

  private valid(): boolean {
    return this.name.trim().length > 0
      && this.selected.length >= GROUP_MEMBER_MIN
      && this.selected.length <= GROUP_MEMBER_MAX;
  }

  private toggle(botId: string): void {
    if (this.saving.pending || this.removal.pending) {
      return;
    }
    if (this.selected.includes(botId)) {
      this.selected = this.selected.filter((id: string): boolean => id !== botId);
      this.deselected.add(botId);
    } else {
      if (this.selected.length >= GROUP_MEMBER_MAX) {
        return;
      }
      this.selected = [...this.selected, botId];
      this.deselected.delete(botId);
    }
    this.saveError = '';
  }

  private commit(): void {
    if (!this.active || this.saving.pending || this.removal.pending) {
      return;
    }
    if (this.findGroup() === null) {
      this.missing = t('Group not found');
      return;
    }
    const body = groupUpdateInput(this.loadedGroupId, this.baselineName, this.name, this.baseline,
      this.selected);
    if (body === null) {
      // Nothing changed: no request, the screen closes as a saved one does.
      this.stack.pop();
      return;
    }
    this.saveError = '';
    this.saving.run(body);
  }

  private confirmDelete(group: GroupView): void {
    if (this.removal.pending) {
      return;
    }
    const values: Record<string, string | number> = {};
    values['name'] = group.name;
    const input: Record<string, Object> = {};
    input['groupId'] = group.id;
    const buttons: AlertDialogButtonOptions[] = [
      {
        value: t('Cancel'),
        fontColor: appearance.tokens().mutedForeground,
        action: (): void => {},
      },
      {
        value: t('Delete'),
        fontColor: appearance.tokens().destructive,
        action: (): void => {
          this.removeError = '';
          this.removal.run(input);
        },
      },
    ];
    this.getUIContext().showAlertDialog({
      title: t('Delete {name}?', values),
      message: t('Bots and their own chats stay.'),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      buttons: buttons,
      cancel: (): void => {},
    });
  }

  private memberCaption(): string {
    const values: Record<string, string | number> = {};
    values['count'] = this.selected.length;
    return t('Members ({count})', values);
  }

  @Builder
  headerRow() {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize('24vp')
        .fontColor([appearance.tokens().foreground])
        .padding({ left: 8, right: 8 })
        .accessibilityText(t('Back'))
        .onClick((): void => {
          this.stack.pop();
        })
      Text(t('Group settings'))
        .fontSize(typeScale.title.fontSize)
        .fontWeight(FontWeight.Bold)
        .fontColor(appearance.tokens().foreground)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 8, right: 16, top: 12, bottom: 8 })
  }

  @Builder
  form() {
    Scroll() {
      Column({ space: 16 }) {
        Field({
          label: t('Group name'),
          placeholder: t('Ex: Project Falcon'),
          value: this.name,
          maxLength: GROUP_NAME_MAX_LENGTH,
          disabled: this.saving.pending || this.removal.pending,
          onChange: (value: string): void => {
            this.saveError = '';
            this.name = value;
          },
          onSubmit: (): void => {
            this.commit();
          },
        })
        Text(this.memberCaption())
          .fontSize(typeScale.secondary.fontSize)
          .fontColor(appearance.tokens().mutedForeground)
          .width('100%')
        BotChecklist({
          bots: rosterStore.bots,
          selected: this.selected,
          disabled: this.saving.pending || this.removal.pending,
          max: GROUP_MEMBER_MAX,
          onToggle: (botId: string): void => {
            this.toggle(botId);
          },
        })
        ErrorText({ message: this.saveError })
        ActionButton({
          label: t('Save'),
          busy: this.saving.pending,
          disabled: !this.valid() || this.removal.pending,
          onTap: (): void => {
            this.commit();
          },
        })
        ErrorText({ message: this.removeError })
        ActionButton({
          label: t('Delete group'),
          kind: 'destructive',
          busy: this.removal.pending,
          disabled: this.saving.pending,
          onTap: (): void => {
            const group = this.findGroup();
            if (group !== null) {
              this.confirmDelete(group);
            }
          },
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 24 })
    }
    .layoutWeight(1)
    .width('100%')
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
  }

  build() {
    NavDestination() {
      Column() {
        this.headerRow()
        if (this.missing !== '') {
          ErrorText({ message: this.missing })
            .padding({ left: 16, right: 16, top: 8 })
        } else if (!this.loaded) {
          Row() {
            LoadingProgress()
              .width(28)
              .height(28)
              .color(appearance.tokens().foreground)
          }
          .width('100%')
          .padding(30)
          .justifyContent(FlexAlign.Center)
        } else {
          this.form()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(appearance.tokens().background)
    }
    .hideTitleBar(true)
  }
}