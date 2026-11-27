// NewGroupPage (M8, design §7.2): the two steps mobile's new-group sheet walks — pick the bots,
// then name the group (a blank name takes the picked bots' default name). The create is a
// SaveController: the screen expresses the taps and renders state; the store layer owns the write.
// Copy reuses catalog msgids.
import { appearance } from '../../uikit/theme';
import { typeScale } from '../../uikit/tokens.generated';
import { ActionButton, ErrorText, Field } from '../../uikit/controls';
import { t } from '../../i18n/i18n';
import { rosterStore } from '../../stores/roster-store';
import { SaveController } from '../../query/save-controller';
import type { SaveSend } from '../../query/save-controller';
import { RpcError, errorText } from '../../net/errors';
import { decodeGroupWithMembers } from '../../contract/decode-groups';
import { BotChecklist } from './group-pickers';
import {
  defaultGroupName,
  GROUP_MEMBER_MAX,
  GROUP_MEMBER_MIN,
  GROUP_NAME_MAX_LENGTH,
} from './group-rules';

@ComponentV2
export struct NewGroupPage {
  @Param stack: NavPathStack = new NavPathStack();
  /** bots | name: the sheet's two steps. */
  @Local step: string = 'bots';
  @Local selected: string[] = [];
  @Local name: string = '';
  @Local error: string = '';
  @Local creating: SaveController = new SaveController({
    save: async (input: Record<string, Object>, send: SaveSend): Promise<void> => {
      const group = decodeGroupWithMembers(await send('groups/create', input));
      if (group === null) {
        throw new RpcError('Unexpected response from the server');
      }
    },
    stale: ['spaces/list'],
    onSaved: (): void => {
      // The inbox paints the new group on this read; the sheet's own screen is gone.
      void rosterStore.load();
      this.stack.pop();
    },
    onFailed: (error: RpcError): void => {
      this.error = errorText(error, t('Could not create group'));
    },
  });

  aboutToAppear(): void {
    // The picker lists the active bots; the inbox usually read them already.
    if (!rosterStore.loaded) {
      void rosterStore.load();
    }
  }

  private valid(): boolean {
    return this.selected.length >= GROUP_MEMBER_MIN && this.selected.length <= GROUP_MEMBER_MAX;
  }

  private toggle(botId: string): void {
    if (this.selected.includes(botId)) {
      this.selected = this.selected.filter((id: string): boolean => id !== botId);
      return;
    }
    if (this.selected.length < GROUP_MEMBER_MAX) {
      this.selected = [...this.selected, botId];
    }
  }

  private back(): void {
    if (this.creating.pending) {
      return;
    }
    if (this.step === 'name') {
      this.step = 'bots';
      return;
    }
    this.stack.pop();
  }

  private pickedNames(): string[] {
    const names: string[] = [];
    for (const id of this.selected) {
      for (const bot of rosterStore.bots) {
        if (bot.id === id) {
          names.push(bot.name);
        }
      }
    }
    return names;
  }

  private submit(): void {
    if (this.creating.pending || !this.valid()) {
      return;
    }
    const body: Record<string, Object> = {};
    body['name'] = this.name.trim() || defaultGroupName(this.pickedNames());
    body['botIds'] = this.selected;
    this.error = '';
    this.creating.run(body);
  }

  private memberCaption(): string {
    const values: Record<string, string | number> = {};
    values['count'] = this.selected.length;
    return t('Members ({count})', values);
  }

  @Builder
  headerRow() {
    Row({ space: 12 }) {
      Text('‹')
        .fontSize(28)
        .fontColor(appearance.tokens().foreground)
        .padding({ left: 8, right: 8 })
        .accessibilityText(t('Back'))
        .onClick((): void => {
          this.back();
        })
      Text(t('New group chat'))
        .fontSize(typeScale.title.fontSize)
        .fontWeight(FontWeight.Bold)
        .fontColor(appearance.tokens().foreground)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.step === 'bots') {
        Text(t('Next'))
          .fontSize(typeScale.secondary.fontSize)
          .fontColor(appearance.tokens().link)
          .padding(8)
          .opacity(this.valid() ? 1 : 0.4)
          .accessibilityText(t('Next'))
          .onClick((): void => {
            if (this.valid()) {
              this.step = 'name';
            }
          })
      }
    }
    .width('100%')
    .padding({ left: 8, right: 16, top: 12, bottom: 8 })
  }

  build() {
    NavDestination() {
      Column() {
        this.headerRow()
        if (this.step === 'bots') {
          Text(this.memberCaption())
            .fontSize(typeScale.secondary.fontSize)
            .fontColor(appearance.tokens().mutedForeground)
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 4 })
          Scroll() {
            Column() {
              BotChecklist({
                bots: rosterStore.bots,
                selected: this.selected,
                disabled: this.creating.pending,
                max: GROUP_MEMBER_MAX,
                onToggle: (botId: string): void => {
                  this.toggle(botId);
                },
              })
            }
            .width('100%')
            .padding({ left: 12, right: 12 })
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off)
          .align(Alignment.Top)
        } else {
          Scroll() {
            Column({ space: 16 }) {
              Field({
                label: t('Group name'),
                placeholder: t('Ex: Project Falcon'),
                value: this.name,
                maxLength: GROUP_NAME_MAX_LENGTH,
                disabled: this.creating.pending,
                onChange: (value: string): void => {
                  this.error = '';
                  this.name = value;
                },
                onSubmit: (): void => {
                  this.submit();
                },
              })
              ErrorText({ message: this.error })
              ActionButton({
                label: this.name.trim() ? t('Create') : t('Skip'),
                busy: this.creating.pending,
                disabled: !this.valid(),
                onTap: (): void => {
                  this.submit();
                },
              })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 16 })
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off)
          .align(Alignment.Top)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(appearance.tokens().background)
    }
    .hideTitleBar(true)
  }
}