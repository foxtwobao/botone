// VoicePage (M7, design §7.2): the voice settings. The provider picker names the device's own
// voice and the server's connections; a chosen connection shows its form (its server address and
// model ids when it is the self-hosted protocol, its key, the voice it speaks with) with
// Connect / Reconnect / Replace key and Disconnect, and the page plays the sample the settings
// offer. The device's own voice needs no setup, so it shows none of it. The store owns every
// read and write; the page renders it and expresses the taps.
import { appearance } from '../../uikit/theme';
import type { VoiceCatalogView, VoiceInfoView } from '../../contract/decode-voice';
import { typeScale } from '../../uikit/tokens.generated';
import { ActionButton, ErrorText, Field } from '../../uikit/controls';
import { t } from '../../i18n/i18n';
import { SELF_HOSTED_PROTOCOL } from '../../voice/voice-settings-model';
import { installConsentDialog } from '../chat/consent-dialog';
import { stopVoicePlayback } from '../../voice/speech';
import { VoiceSettingsStore } from '../../stores/voice-settings-store';

/** The picker's id for the device's own voice, never a catalog entry's. */
const DEVICE_CHOICE = 'this-device';

@ComponentV2
export struct VoicePage {
  @Param stack: NavPathStack = new NavPathStack();
  @Local store: VoiceSettingsStore = new VoiceSettingsStore();
  private offConsent: (() => void) | null = null;

  aboutToAppear(): void {
    this.offConsent = installConsentDialog();
    void this.store.load();
    void this.store.loadDeviceVoice();
  }

  aboutToDisappear(): void {
    this.offConsent?.();
    this.offConsent = null;
    // Leaving the page stops the sample; its bar is not the page's to keep.
    stopVoicePlayback();
  }

  @Builder
  providerMenu() {
    Menu() {
      MenuItem({ content: t('This device') })
        .selected(this.store.deviceVoice)
        .selectIcon(true)
        .contentFontColor(appearance.tokens().foreground)
        .enabled(this.store.pending === '')
        .onClick((): void => {
          if (!this.store.deviceVoice) {
            void this.store.toggleDeviceVoice();
          }
        })
      ForEach(this.store.catalog, (entry: VoiceCatalogView): void => {
        MenuItem({ content: entry.name })
          .selected(!this.store.deviceVoice && this.store.provider === entry.id)
          .selectIcon(true)
          .contentFontColor(appearance.tokens().foreground)
          .enabled(this.store.pending === '')
          .onClick((): void => {
            if (this.store.deviceVoice || this.store.provider !== entry.id) {
              void this.store.chooseProvider(entry.id);
            }
          })
      }, (entry: VoiceCatalogView): string => entry.id)
    }
  }

  @Builder
  voiceMenu() {
    Menu() {
      ForEach(this.store.voices, (voice: VoiceInfoView): void => {
        MenuItem({ content: voice.label })
          .selected(this.store.voiceId === voice.id)
          .selectIcon(true)
          .contentFontColor(appearance.tokens().foreground)
          .enabled(this.store.pending === '')
          .onClick((): void => {
            if (this.store.voiceId !== voice.id) {
              void this.store.chooseVoice(voice.id);
            }
          })
      }, (voice: VoiceInfoView): string => voice.id)
    }
  }

  /** The button's label: what connecting again means for this connection. */
  private connectLabel(): string {
    const entry = this.store.selected;
    const credential = this.store.credential;
    if (entry === undefined) {
      return t('Connect');
    }
    if (entry.id === SELF_HOSTED_PROTOCOL) {
      return credential !== undefined ? t('Reconnect') : t('Connect');
    }
    return credential !== undefined ? t('Replace key') : t('Connect');
  }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: 20 }) {
          Text(t('Voice'))
            .fontSize(typeScale.title.fontSize)
            .fontWeight(FontWeight.Bold)
            .fontColor(appearance.tokens().foreground)
            .alignSelf(ItemAlign.Start)

          if (this.store.loading && !this.store.loaded) {
            Row({ space: 10 }) {
              LoadingProgress().width(24).height(24).color(appearance.tokens().foreground)
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding(30)
          }

          ErrorText({ message: this.store.loadError || this.store.error })

          if (this.store.catalog.length > 0) {
            Row() {
              Text(t('Provider'))
                .fontSize(typeScale.secondary.fontSize)
                .fontColor(appearance.tokens().mutedForeground)
              Blank()
              Text(this.store.deviceVoice
                ? t('This device') : this.store.selected?.name ?? this.store.provider)
                .fontSize(typeScale.body.fontSize)
                .fontColor(appearance.tokens().link)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: '60%' })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .backgroundColor(appearance.tokens().card)
            .borderRadius(12)
            .bindMenu(this.providerMenu)
          }

          if (!this.store.deviceVoice) {
            Column({ space: 12 }) {
              if (this.store.selected?.id === SELF_HOSTED_PROTOCOL) {
                Field({
                  label: t('Server URL'),
                  placeholder: 'http://192.168.1.10:8880/v1',
                  value: this.store.baseUrl,
                  disabled: this.store.pending !== '',
                  onChange: (value: string): void => {
                    this.store.edit('baseUrl', value);
                  },
                })
                Field({
                  label: t('Speech model'),
                  placeholder: 'mlx-community/Kokoro-82M-bf16',
                  value: this.store.ttsModel,
                  disabled: this.store.pending !== '',
                  onChange: (value: string): void => {
                    this.store.edit('ttsModel', value);
                  },
                })
                Field({
                  label: t('Transcription model'),
                  placeholder: 'mlx-community/whisper-large-v3-turbo-asr-fp16',
                  value: this.store.sttModel,
                  disabled: this.store.pending !== '',
                  onChange: (value: string): void => {
                    this.store.edit('sttModel', value);
                  },
                })
              }
              if (this.store.selected?.keyless !== true && this.store.form?.linked !== true) {
                Field({
                  label: t('API key'),
                  placeholder: this.store.credential !== undefined
                    ? t('Paste a replacement key') : t('Paste your API key'),
                  value: this.store.apiKey,
                  secure: true,
                  disabled: this.store.pending !== '',
                  onChange: (value: string): void => {
                    this.store.edit('apiKey', value);
                  },
                })
              }
              ActionButton({
                label: this.connectLabel(),
                disabled: this.store.pending !== '' || this.store.form?.canConnect !== true,
                busy: this.store.pending === 'connect',
                onTap: (): void => {
                  void this.store.connect();
                },
              })
              if (this.store.credential !== undefined) {
                ActionButton({
                  label: t('Disconnect'),
                  kind: 'destructive',
                  disabled: this.store.pending !== '',
                  busy: this.store.pending === 'disconnect',
                  onTap: (): void => {
                    void this.store.disconnect();
                  },
                })
              }
              if (this.store.credential !== undefined && this.store.selected?.speechModel === true) {
                Field({
                  label: t('Speech model'),
                  placeholder: t('Optional'),
                  value: this.store.speechModel,
                  disabled: this.store.pending !== '',
                  onChange: (value: string): void => {
                    this.store.edit('speechModel', value);
                  },
                  onSubmit: (): void => {
                    void this.store.saveSpeechModel(this.store.speechModel);
                  },
                })
              }
              if (this.store.voices.length > 0) {
                Row() {
                  Text(t('Voice'))
                    .fontSize(typeScale.secondary.fontSize)
                    .fontColor(appearance.tokens().mutedForeground)
                  Blank()
                  Text(this.store.voices.find((voice: VoiceInfoView): boolean => voice.id === this.store.voiceId)?.label
                    ?? this.store.voiceId)
                    .fontSize(typeScale.body.fontSize)
                    .fontColor(appearance.tokens().link)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .constraintSize({ maxWidth: '60%' })
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .backgroundColor(appearance.tokens().card)
                .borderRadius(12)
                .bindMenu(this.voiceMenu)
              } else if (this.store.credential !== undefined && this.store.selected?.freeformVoice === true) {
                Field({
                  label: t('Voice'),
                  placeholder: t('Optional'),
                  value: this.store.voiceId,
                  disabled: this.store.pending !== '',
                  onChange: (value: string): void => {
                    this.store.edit('voiceId', value);
                  },
                  onSubmit: (): void => {
                    const next = this.store.voiceId.trim();
                    if (next && next !== this.store.credential?.voiceId) {
                      void this.store.chooseVoice(next);
                    }
                  },
                })
              }
            }
            .width('100%')
            .padding({ left: 16, right: 16 })
            .backgroundColor(appearance.tokens().card)
            .borderRadius(12)
          }

          if (this.store.deviceVoice || this.store.status?.ready) {
            ActionButton({
              label: t('Hear a sample'),
              kind: 'secondary',
              disabled: this.store.pending !== '',
              busy: this.store.pending === 'test',
              onTap: (): void => {
                void this.store.testVoice();
              },
            })
          }
        }
        .width('100%')
        .padding(20)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(appearance.tokens().background)
      .scrollBar(BarState.Off)
    }
    .hideTitleBar(true)
    .backgroundColor(appearance.tokens().background)
  }
}
