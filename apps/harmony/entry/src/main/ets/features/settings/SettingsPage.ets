// SettingsPage (design §7.2 M4): the signed-in account's settings. Read-first — the identity,
// Space, server and model are calm summary rows; the server row navigates to ServerPage (M1),
// appearance and language open native menus, the version is a plain row, and sign-out is the one
// destructive action at the bottom. The model row shows the server's label when
// me.defaultProvider/defaultModel matches models/list, else the translatable "Space default" —
// never a raw id — and opens the models page (M9) to connect one. Copy reuses catalog msgids; the
// locale names are product data (each language in its own name, the same in every locale).
import { bundleManager } from '@kit.AbilityKit';
import { appearance } from '../../uikit/theme';
import { typeScale } from '../../uikit/tokens.generated';
import { ActionButton, ErrorText } from '../../uikit/controls';
import { t } from '../../i18n/i18n';
import { localePreference, setLocalePreference, SHIPPED_LOCALES } from '../../i18n/i18n';
import { app } from '../../app/app-state';
import { signOut } from '../../net/auth';
import { errorText, RpcError } from '../../net/errors';
import { currentApiBase } from '../../net/server-store';
import { displaySavedServer } from '../../net/endpoint';
import { settingsStore } from '../../stores/settings-store';
import { spaceStore } from '../../stores/space-store';
import { defaultModelEntry } from '../../stores/model-display';
import { outbox } from '../../outbox/outbox';

/** Each shipped language named in itself (core APP_LOCALE_LABELS) — product data, not copy.
 * Built by key assignment: ArkTS rejects Record literals with entries (M1 constraint). */
const LOCALE_LABELS: Record<string, string> = {};
LOCALE_LABELS['en'] = 'English';
LOCALE_LABELS['zh-CN'] = '简体中文';
LOCALE_LABELS['zh-TW'] = '繁體中文';

/** A label/value row. A @ComponentV2 child, not a @Builder: builder params bind once on first
 * render, so a traced value (model label, appearance, locale) would never refresh (verified on
 * device); @Param re-syncs when the parent re-renders. */
@ComponentV2
struct ValueRow {
  @Param label: string = '';
  @Param value: string = '';

  build() {
    Row() {
      Text(this.label)
        .fontSize(typeScale.secondary.fontSize)
        .fontColor(appearance.tokens().mutedForeground)
      Blank()
      Text(this.value)
        .fontSize(typeScale.body.fontSize)
        .fontColor(appearance.tokens().foreground)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: '60%' })
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
  }
}

@ComponentV2
export struct SettingsPage {
  @Param stack: NavPathStack = new NavPathStack();
  @Local signingOut: boolean = false;
  @Local error: string = '';
  @Local version: string = '';

  aboutToAppear(): void {
    void settingsStore.load();
    void this.loadVersion();
  }

  private async loadVersion(): Promise<void> {
    try {
      const info = await bundleManager.getBundleInfoForSelf(0);
      this.version = info.versionName;
    } catch (err) {
      this.version = '';
    }
  }

  private async doSignOut(): Promise<void> {
    if (this.signingOut) {
      return;
    }
    if (outbox.hasUnsent()) {
      // Unsent messages die with the session; the one destructive surprise gets one confirm (B3).
      this.getUIContext().showAlertDialog({
        title: t('Unsent messages'),
        message: t('Signing out deletes unsent messages.'),
        autoCancel: true,
        alignment: DialogAlignment.Center,
        buttons: [
          {
            value: t('Cancel'),
            fontColor: appearance.tokens().mutedForeground,
            action: (): void => {},
          },
          {
            value: t('Sign out anyway'),
            fontColor: appearance.tokens().destructive,
            action: (): void => {
              void this.signOutNow();
            },
          },
        ],
      });
      return;
    }
    await this.signOutNow();
  }

  private async signOutNow(): Promise<void> {
    if (this.signingOut) {
      return;
    }
    this.signingOut = true;
    this.error = '';
    try {
      await signOut();
      // The session phase swap only replaces the root screen; this pushed destination must go or
      // it stays on top of the sign-in page (verified on device).
      this.stack.clear();
    } catch (err) {
      const rpcError = err instanceof RpcError ? err as RpcError : null;
      this.error = rpcError !== null ? errorText(rpcError)
        : err instanceof Error ? (err as Error).message : t('Could not continue');
    } finally {
      this.signingOut = false;
    }
  }

  /** The model row's value: the server's label, or the generic translatable fallback (Q6). */
  private modelLabel(): string {
    const entry = defaultModelEntry(app.me, settingsStore.catalog);
    return entry !== null ? entry.label : t('Space default');
  }

  private appearanceLabel(): string {
    const pref = appearance.preference;
    return pref === 'light' ? t('Light') : pref === 'dark' ? t('Dark') : t('System');
  }

  private languageLabel(): string {
    const pref = localePreference();
    return pref === 'system' ? t('System') : (LOCALE_LABELS[pref] ?? pref);
  }

  @Builder
  appearanceMenu() {
    Menu() {
      MenuItem({ content: t('System') })
        .selected(appearance.preference === 'system')
        .selectIcon(true)
        .contentFontColor(appearance.tokens().foreground)
        .onClick((): void => {
          void appearance.setPreference('system');
        })
      MenuItem({ content: t('Light') })
        .selected(appearance.preference === 'light')
        .selectIcon(true)
        .contentFontColor(appearance.tokens().foreground)
        .onClick((): void => {
          void appearance.setPreference('light');
        })
      MenuItem({ content: t('Dark') })
        .selected(appearance.preference === 'dark')
        .selectIcon(true)
        .contentFontColor(appearance.tokens().foreground)
        .onClick((): void => {
          void appearance.setPreference('dark');
        })
    }
  }

  @Builder
  languageMenu() {
    Menu() {
      MenuItem({ content: t('System') })
        .selected(localePreference() === 'system')
        .selectIcon(true)
        .contentFontColor(appearance.tokens().foreground)
        .onClick((): void => {
          void setLocalePreference('system');
        })
      ForEach(SHIPPED_LOCALES, (locale: string): void => {
        MenuItem({ content: LOCALE_LABELS[locale] ?? locale })
          .selected(localePreference() === locale)
          .selectIcon(true)
          .contentFontColor(appearance.tokens().foreground)
          .onClick((): void => {
            void setLocalePreference(locale);
          })
      }, (locale: string): string => locale)
    }
  }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: 20 }) {
          Text(t('Settings'))
            .fontSize(typeScale.title.fontSize)
            .fontWeight(FontWeight.Bold)
            .fontColor(appearance.tokens().foreground)
            .alignSelf(ItemAlign.Start)

          if (app.updateRequired) {
            Text(t('Update required'))
              .fontSize(typeScale.secondary.fontSize)
              .fontColor(appearance.tokens().warning)
              .alignSelf(ItemAlign.Start)
          }

          if (app.meLoading) {
            Row({ space: 10 }) {
              LoadingProgress().width(24).height(24).color(appearance.tokens().foreground)
              Text(t('Loading…'))
                .fontSize(typeScale.secondary.fontSize)
                .fontColor(appearance.tokens().mutedForeground)
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding(30)
          } else if (app.meError) {
            ErrorText({ message: app.meError })
            ActionButton({
              label: t('Retry'),
              kind: 'secondary',
              onTap: (): void => {
                void app.loadMe();
              },
            })
          } else if (app.me !== null) {
            // Identity: the account by name, no raw ids.
            Column({ space: 4 }) {
              Text(app.me.name || app.me.email)
                .fontSize(typeScale.headline.fontSize)
                .fontWeight(FontWeight.Medium)
                .fontColor(appearance.tokens().foreground)
              if (app.me.name) {
                Text(app.me.email)
                  .fontSize(typeScale.secondary.fontSize)
                  .fontColor(appearance.tokens().mutedForeground)
              }
            }
            .width('100%')
            .padding(16)
            .backgroundColor(appearance.tokens().card)
            .borderRadius(12)
            .alignItems(HorizontalAlign.Start)

            // Account facts: Space and model read-only; server navigates to its management page.
            Column() {
              if (spaceStore.currentName || app.spaceName) {
                ValueRow({ label: t('Space'), value: spaceStore.currentName || app.spaceName })
              }
              Row() {
                Text(t('Server'))
                  .fontSize(typeScale.secondary.fontSize)
                  .fontColor(appearance.tokens().mutedForeground)
                Blank()
                Text(displaySavedServer(app.serverBase || currentApiBase()))
                  .fontSize(typeScale.body.fontSize)
                  .fontColor(appearance.tokens().link)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .constraintSize({ maxWidth: '60%' })
              }
              .width('100%')
              .padding({ top: 12, bottom: 12 })
              .onClick((): void => {
                this.stack.pushPathByName('server', null);
              })
              Row() {
                Text(t('Model'))
                  .fontSize(typeScale.secondary.fontSize)
                  .fontColor(appearance.tokens().mutedForeground)
                Blank()
                Text(this.modelLabel())
                  .fontSize(typeScale.body.fontSize)
                  .fontColor(appearance.tokens().link)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .constraintSize({ maxWidth: '60%' })
              }
              .width('100%')
              .padding({ top: 12, bottom: 12 })
              .onClick((): void => {
                this.stack.pushPathByName('models', null);
              })
              Row() {
                Text(t('Voice'))
                  .fontSize(typeScale.secondary.fontSize)
                  .fontColor(appearance.tokens().mutedForeground)
                Blank()
                Text(t('Voice'))
                  .fontSize(typeScale.body.fontSize)
                  .fontColor(appearance.tokens().link)
              }
              .width('100%')
              .padding({ top: 12, bottom: 12 })
              .onClick((): void => {
                this.stack.pushPathByName('voice', null);
              })
            }
            .width('100%')
            .padding({ left: 16, right: 16 })
            .backgroundColor(appearance.tokens().card)
            .borderRadius(12)

            // Preferences: appearance and language, each a row opening a native menu (bindMenu on
            // the row itself — a CustomBuilder passed through a @Builder param never opens).
            Column() {
              ValueRow({ label: t('Appearance'), value: this.appearanceLabel() })
                .bindMenu(this.appearanceMenu)
              ValueRow({ label: t('Language'), value: this.languageLabel() })
                .bindMenu(this.languageMenu)
            }
            .width('100%')
            .padding({ left: 16, right: 16 })
            .backgroundColor(appearance.tokens().card)
            .borderRadius(12)

            if (this.version) {
              Column() {
                ValueRow({ label: t('Version'), value: this.version })
              }
              .width('100%')
              .padding({ left: 16, right: 16 })
              .backgroundColor(appearance.tokens().card)
              .borderRadius(12)
            }

            ErrorText({ message: this.error })
            ActionButton({
              label: t('Sign out'),
              kind: 'destructive',
              busy: this.signingOut,
              onTap: (): void => {
                void this.doSignOut();
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
