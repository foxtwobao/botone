// The bot multi-select the two group screens share (M8): one row per active bot, its identity
// color on the shared avatar and a check on the picked ones. The screens own the rule (how many
// may be picked), and the row of a bot a full selection cannot take reads dimmed and does not
// answer a tap; this only reports the taps it takes.
import { appearance } from '../../uikit/theme';
import { typeScale } from '../../uikit/tokens.generated';
import { ChatAvatar } from '../../uikit/avatar';
import { t } from '../../i18n/i18n';
import type { BotView } from '../../contract/decode';

@ComponentV2
export struct BotChecklist {
  @Param bots: BotView[] = [];
  @Param selected: string[] = [];
  @Param disabled: boolean = false;
  @Require @Param max: number;
  @Event onToggle: (botId: string) => void = (_botId: string): void => {};

  /** A member the max leaves out: the row shows it, the tap is not taken. */
  private atCapacity(bot: BotView): boolean {
    return !this.selected.includes(bot.id) && this.selected.length >= this.max;
  }

  build() {
    Column() {
      ForEach(this.bots, (bot: BotView): void => {
        Row({ space: 12 }) {
          ChatAvatar({ kind: 'bot', name: bot.name, color: bot.color, working: false, diameter: 36 })
          Text(bot.name)
            .fontSize(typeScale.body.fontSize)
            .fontColor(appearance.tokens().foreground)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.selected.includes(bot.id)) {
            Text('✓')
              .fontSize(18)
              .fontColor(appearance.tokens().primary)
          }
        }
        .width('100%')
        .padding({ left: 4, right: 4, top: 10, bottom: 10 })
        .opacity(this.atCapacity(bot) ? 0.4 : 1)
        .accessibilityText(this.selected.includes(bot.id) ? `${bot.name}, ${t('Selected')}` : bot.name)
        .onClick((): void => {
          if (!this.disabled && !this.atCapacity(bot)) {
            this.onToggle(bot.id);
          }
        })
      }, (bot: BotView): string => bot.id)
    }
    .width('100%')
  }
}