// VoicePlayerBar (M7): Pause / Resume / Stop for a reply that is being spoken, ported from
// mobile's components/calls/voice-player-bar.tsx. Rendered only while something is speaking or
// paused, as a normal block of the app's root column so it never covers the message list or the
// composer, and it follows the user across screens because playback state, including who is
// speaking, lives in the voice module.
import { appearance } from '../../uikit/theme';
import { typeScale } from '../../uikit/tokens.generated';
import { t } from '../../i18n/i18n';
import {
  getVoicePlaybackState,
  pauseVoicePlayback,
  resumeVoicePlayback,
  stopVoicePlayback,
  subscribeVoicePlayback,
} from '../../voice/speech';

@ComponentV2
export struct VoicePlayerBar {
  /** idle | playing | paused */
  @Local status: string = 'idle';
  @Local name: string = '';
  @Local color: string = '';
  @Local canPause: boolean = false;
  private off: (() => void) | null = null;

  aboutToAppear(): void {
    this.read();
    this.off = subscribeVoicePlayback((): void => {
      this.read();
    });
  }

  aboutToDisappear(): void {
    this.off?.();
    this.off = null;
  }

  private read(): void {
    const state = getVoicePlaybackState();
    this.status = state.status;
    this.name = state.speaker?.name ?? t('Bot');
    this.color = state.speaker?.color ?? appearance.tokens().foreground;
    this.canPause = state.canPause;
  }

  build() {
    if (this.status !== 'idle') {
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.waveform'))
          .fontSize(typeScale.body.fontSize + 'vp')
          .fontColor([this.color])
          .accessibilityLevel('no')
        Text(this.name)
          .fontSize(typeScale.body.fontSize)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.color)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.status === 'paused') {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.play_fill'))
              .fontSize('16vp')
              .fontColor([appearance.tokens().foreground])
          }
            .width(36)
            .height(36)
            .backgroundColor(appearance.tokens().muted)
            .accessibilityText(t('Play'))
            .onClick((): void => {
              resumeVoicePlayback();
            })
        } else if (this.canPause) {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.pause_fill'))
              .fontSize('16vp')
              .fontColor([appearance.tokens().foreground])
          }
            .width(36)
            .height(36)
            .backgroundColor(appearance.tokens().muted)
            .accessibilityText(t('Pause'))
            .onClick((): void => {
              pauseVoicePlayback();
            })
        }
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.square_fill'))
            .fontSize('14vp')
            .fontColor([appearance.tokens().foreground])
        }
          .width(36)
          .height(36)
          .backgroundColor(appearance.tokens().muted)
          .accessibilityText(t('Stop'))
          .onClick((): void => {
            stopVoicePlayback();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 6, bottom: 6 })
      .backgroundColor(appearance.tokens().card)
    }
  }
}
