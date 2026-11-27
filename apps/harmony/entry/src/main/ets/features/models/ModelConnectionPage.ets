// ModelConnectionPage (M9, design §7.2): one provider connection by API key. Pick the provider,
// paste its key, pick its model (for a compatible server: its address, a probe that lists the
// server's models, and a model id), then connect. A new connection takes the main model only when
// the account has none. The store owns the reads, the probe and the write; the page renders it.
import { appearance } from '../../uikit/theme';
import { typeScale } from '../../uikit/tokens.generated';
import { ActionButton, ErrorText, Field } from '../../uikit/controls';
import { t } from '../../i18n/i18n';
import { app } from '../../app/app-state';
import { modelConnectionsStore } from '../../stores/model-connections-store';
import { settingsStore } from '../../stores/settings-store';
import type { ModelCatalogEntryView } from '../../contract/decode';
import {
  providerDisplayName,
} from './model-providers';
import type { ProviderChoice } from './model-providers';

@ComponentV2
export struct ModelConnectionPage {
  @Param stack: NavPathStack = new NavPathStack();
  private active: boolean = false;

  aboutToAppear(): void {
    this.active = true;
    void modelConnectionsStore.load();
  }

  aboutToDisappear(): void {
    this.active = false;
  }

  private providerValue(): string {
    const entry = modelConnectionsStore.providerEntry;
    return entry !== undefined ? providerDisplayName(entry) : t('Choose a provider');
  }

  private headerTitle(): string {
    const entry = modelConnectionsStore.providerEntry;
    return entry !== undefined ? providerDisplayName(entry) : t('Add provider');
  }

  /** A provider that signs people in also takes a key here; that is what the label says. */
  private keyLabel(): string {
    const entry = modelConnectionsStore.providerEntry;
    return entry !== undefined && entry.auth === 'both' ? t('Or connect an API key') : t('API key');
  }

  private probeIncludes(id: string): boolean {
    for (const model of modelConnectionsStore.probeModels) {
      if (model === id) {
        return true;
      }
    }
    return false;
  }

  private foundModelValue(): string {
    if (modelConnectionsStore.probeModels.length === 0) {
      return t('Other model…');
    }
    return this.probeIncludes(modelConnectionsStore.modelId) ? modelConnectionsStore.modelId
      : t('Other model…');
  }

  private showModelField(): boolean {
    return modelConnectionsStore.probeModels.length === 0
      || !this.probeIncludes(modelConnectionsStore.modelId);
  }

  private catalogModelValue(): string {
    const entry = modelConnectionsStore.selectedModel;
    return entry !== undefined ? entry.label : t('Choose a model');
  }

  private back(): void {
    if (modelConnectionsStore.pending === '') {
      this.stack.pop();
    }
  }

  private async submit(): Promise<void> {
    if (await modelConnectionsStore.connect()) {
      // The connection is saved; the list and the settings row catch up while this page leaves.
      void app.loadMe();
      void settingsStore.load();
      // Backed out while the connect was in flight: this page is gone, and the pop would take
      // the list under it too.
      if (!this.active) {
        return;
      }
      this.stack.pop();
    }
  }

  @Builder
  providerMenu() {
    Menu() {
      ForEach(modelConnectionsStore.providers, (provider: ProviderChoice): void => {
        MenuItem({ content: provider.name })
          .selected(modelConnectionsStore.provider === provider.id)
          .selectIcon(true)
          .contentFontColor(appearance.tokens().foreground)
          .enabled(modelConnectionsStore.pending === '')
          .onClick((): void => {
            modelConnectionsStore.chooseProvider(provider.id);
          })
      }, (provider: ProviderChoice): string => provider.id)
    }
  }

  @Builder
  catalogModelMenu() {
    Menu() {
      ForEach(modelConnectionsStore.providerModels, (entry: ModelCatalogEntryView): void => {
        MenuItem({ content: entry.label })
          .selected(modelConnectionsStore.modelId === entry.id)
          .selectIcon(true)
          .contentFontColor(appearance.tokens().foreground)
          .enabled(modelConnectionsStore.pending === '')
          .onClick((): void => {
            modelConnectionsStore.chooseModel(entry.id);
          })
      }, (entry: ModelCatalogEntryView): string => entry.id)
    }
  }

  @Builder
  foundModelMenu() {
    Menu() {
      ForEach(modelConnectionsStore.probeModels, (model: string): void => {
        MenuItem({ content: model })
          .selected(modelConnectionsStore.modelId === model)
          .selectIcon(true)
          .contentFontColor(appearance.tokens().foreground)
          .enabled(modelConnectionsStore.pending === '')
          .onClick((): void => {
            modelConnectionsStore.chooseModel(model);
          })
      }, (model: string): string => model)
      MenuItem({ content: t('Other model…') })
        .selected(!this.probeIncludes(modelConnectionsStore.modelId))
        .selectIcon(true)
        .contentFontColor(appearance.tokens().foreground)
        .enabled(modelConnectionsStore.pending === '')
        .onClick((): void => {
          modelConnectionsStore.chooseModel('');
        })
    }
  }

  @Builder
  providerRow() {
    Row() {
      Text(t('Provider'))
        .fontSize(typeScale.secondary.fontSize)
        .fontColor(appearance.tokens().mutedForeground)
      Blank()
      Text(this.providerValue())
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

  @Builder
  compatibleForm() {
    Column({ space: 12 }) {
      Field({
        label: t('Base URL'),
        placeholder: 'https://example.com/v1',
        value: modelConnectionsStore.baseUrl,
        disabled: modelConnectionsStore.pending !== '',
        onChange: (value: string): void => {
          modelConnectionsStore.edit('baseUrl', value);
        },
      })
      Field({
        label: t('API key'),
        placeholder: t('Optional'),
        value: modelConnectionsStore.apiKey,
        secure: true,
        disabled: modelConnectionsStore.pending !== '',
        onChange: (value: string): void => {
          modelConnectionsStore.edit('apiKey', value);
        },
      })
      ActionButton({
        label: t('Test connection'),
        kind: 'secondary',
        busy: modelConnectionsStore.pending === 'probe',
        disabled: !modelConnectionsStore.probeReady,
        onTap: (): void => {
          void modelConnectionsStore.probe();
        },
      })
      if (modelConnectionsStore.probeModels.length > 0) {
        Row() {
          Text(t('Model'))
            .fontSize(typeScale.secondary.fontSize)
            .fontColor(appearance.tokens().mutedForeground)
          Blank()
          Text(this.foundModelValue())
            .fontSize(typeScale.body.fontSize)
            .fontColor(appearance.tokens().link)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '60%' })
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })
        .bindMenu(this.foundModelMenu)
      }
      if (this.showModelField()) {
        Field({
          label: t('Model id'),
          value: modelConnectionsStore.modelId,
          disabled: modelConnectionsStore.pending !== '',
          onChange: (value: string): void => {
            modelConnectionsStore.edit('modelId', value);
          },
        })
      }
      ActionButton({
        label: t('Connect'),
        busy: modelConnectionsStore.pending === 'connect',
        disabled: !modelConnectionsStore.connectReady,
        onTap: (): void => {
          void this.submit();
        },
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor(appearance.tokens().card)
    .borderRadius(12)
  }

  @Builder
  catalogForm() {
    Column({ space: 12 }) {
      Field({
        label: this.keyLabel(),
        placeholder: t('Paste your API key'),
        value: modelConnectionsStore.apiKey,
        secure: true,
        disabled: modelConnectionsStore.pending !== '',
        onChange: (value: string): void => {
          modelConnectionsStore.edit('apiKey', value);
        },
      })
      if (modelConnectionsStore.providerModels.length > 0) {
        Row() {
          Text(t('Model'))
            .fontSize(typeScale.secondary.fontSize)
            .fontColor(appearance.tokens().mutedForeground)
          Blank()
          Text(this.catalogModelValue())
            .fontSize(typeScale.body.fontSize)
            .fontColor(appearance.tokens().link)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '60%' })
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })
        .bindMenu(this.catalogModelMenu)
      }
      ActionButton({
        label: t('Connect API key'),
        busy: modelConnectionsStore.pending === 'connect',
        disabled: !modelConnectionsStore.connectReady,
        onTap: (): void => {
          void this.submit();
        },
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor(appearance.tokens().card)
    .borderRadius(12)
  }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: 20 }) {
          Row({ space: 12 }) {
            Text('‹')
              .fontSize(28)
              .fontColor(appearance.tokens().foreground)
              .padding({ left: 8, right: 8 })
              .accessibilityText(t('Back'))
              .onClick((): void => {
                this.back();
              })
            Text(this.headerTitle())
              .fontSize(typeScale.title.fontSize)
              .fontWeight(FontWeight.Bold)
              .fontColor(appearance.tokens().foreground)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')

          if (modelConnectionsStore.loading && !modelConnectionsStore.loaded) {
            Row({ space: 10 }) {
              LoadingProgress().width(24).height(24).color(appearance.tokens().foreground)
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding(30)
          }

          ErrorText({ message: modelConnectionsStore.loadError })
          if (modelConnectionsStore.loadError) {
            ActionButton({
              label: t('Retry'),
              kind: 'secondary',
              onTap: (): void => {
                void modelConnectionsStore.load();
              },
            })
          }

          if (modelConnectionsStore.loaded && modelConnectionsStore.providers.length > 0) {
            this.providerRow()
            if (modelConnectionsStore.provider !== '') {
              if (modelConnectionsStore.isCompatible) {
                this.compatibleForm()
              } else {
                this.catalogForm()
              }
              ErrorText({ message: modelConnectionsStore.error })
            }
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