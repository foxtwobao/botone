// ModelsPage (M9, design §7.2): the account's models. Until the account can run one at all it
// leads with connecting a model; afterwards it lists the saved connections, marks the one that
// runs the main model, and offers adding another provider. The connection form itself is the
// next page. Copy reuses catalog msgids; a provider is named by the catalog's own name.
import { appearance } from '../../uikit/theme';
import { typeScale } from '../../uikit/tokens.generated';
import { ActionButton, ErrorText } from '../../uikit/controls';
import { t } from '../../i18n/i18n';
import { app } from '../../app/app-state';
import { modelConnectionsStore } from '../../stores/model-connections-store';
import type { ModelCredentialView } from '../../contract/decode-models';
import {
  firstModelConnection,
  isDefaultConnection,
  providerDisplayName,
} from './model-providers';
import type { ModelDefaults } from './model-providers';

@ComponentV2
export struct ModelsPage {
  @Param stack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    modelConnectionsStore.reset();
    void modelConnectionsStore.load();
  }

  private defaults(): ModelDefaults | null {
    const me = app.me;
    if (me === null) {
      return null;
    }
    const defaults: ModelDefaults = {
      defaultProvider: me.defaultProvider,
      defaultModel: me.defaultModel,
    };
    return defaults;
  }

  private leadingWithConnect(): boolean {
    return firstModelConnection(app.me, modelConnectionsStore.credentials);
  }

  /** A new connection takes the main model only when nothing runs one yet. */
  private openConnection(): void {
    const defaults = this.defaults();
    const makeDefault = defaults === null || defaults.defaultProvider === null
      || defaults.defaultModel === null;
    modelConnectionsStore.begin(makeDefault, defaults);
    this.stack.pushPathByName('modelConnection', null);
  }

  private connectionTitle(credential: ModelCredentialView): string {
    if (credential.label) {
      return credential.label;
    }
    for (const entry of modelConnectionsStore.catalog) {
      if (entry.provider === credential.provider) {
        return providerDisplayName(entry);
      }
    }
    return t('Provider');
  }

  private back(): void {
    this.stack.pop();
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
            Text(this.leadingWithConnect() ? t('Models') : t('Main model'))
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

          if (modelConnectionsStore.loaded) {
            if (this.leadingWithConnect()) {
              ActionButton({
                label: t('Connect a model'),
                onTap: (): void => {
                  this.openConnection();
                },
              })
            } else {
              // The saved connections; a row's Default tag is the account's own default, never
              // the connection's own isDefault field.
              if (modelConnectionsStore.credentials.length > 0) {
                Column() {
                  ForEach(modelConnectionsStore.credentials, (credential: ModelCredentialView): void => {
                    Row({ space: 12 }) {
                      Column({ space: 2 }) {
                        Text(this.connectionTitle(credential))
                          .fontSize(typeScale.body.fontSize)
                          .fontColor(appearance.tokens().foreground)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                        if (modelConnectionsStore.modelLabel(credential)) {
                          Text(modelConnectionsStore.modelLabel(credential))
                            .fontSize(typeScale.secondary.fontSize)
                            .fontColor(appearance.tokens().mutedForeground)
                            .maxLines(1)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                        }
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)
                      if (isDefaultConnection(this.defaults(), credential)) {
                        Text(t('Default'))
                          .fontSize(typeScale.secondary.fontSize)
                          .fontColor(appearance.tokens().mutedForeground)
                      }
                    }
                    .width('100%')
                    .padding({ top: 12, bottom: 12 })
                  }, (credential: ModelCredentialView): string => credential.id)
                }
                .width('100%')
                .padding({ left: 16, right: 16 })
                .backgroundColor(appearance.tokens().card)
                .borderRadius(12)
              }
              Row() {
                Text(t('Add provider'))
                  .fontSize(typeScale.body.fontSize)
                  .fontColor(appearance.tokens().link)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })
              .backgroundColor(appearance.tokens().card)
              .borderRadius(12)
              .onClick((): void => {
                this.openConnection();
              })
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