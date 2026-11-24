// The account screen (M1, pushed from the inbox in M2): the account and its default Space by
// name — no raw ids — plus the server entry and sign-out. The inbox is the signed-in home now.
import { appearance } from '../../uikit/theme';
import { typeScale } from '../../uikit/tokens.generated';
import { ActionButton, ErrorText } from '../../uikit/controls';
import { t } from '../../i18n/i18n';
import { app } from '../../app/app-state';
import { signOut } from '../../net/auth';
import { errorText, RpcError } from '../../net/errors';
import { currentApiBase } from '../../net/server-store';
import { displaySavedServer } from '../../net/endpoint';

@ComponentV2
export struct MePage {
  @Param stack: NavPathStack = new NavPathStack();
  @Local signingOut: boolean = false;
  @Local error: string = '';

  private async doSignOut(): Promise<void> {
    if (this.signingOut) {
      return;
    }
    this.signingOut = true;
    this.error = '';
    try {
      await signOut();
    } catch (err) {
      const rpcError = err instanceof RpcError ? err as RpcError : null;
      this.error = rpcError !== null ? errorText(rpcError)
        : err instanceof Error ? (err as Error).message : t('Could not continue');
    } finally {
      this.signingOut = false;
    }
  }

  @Builder
  row(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(typeScale.secondary.fontSize)
        .fontColor(appearance.tokens().mutedForeground)
      Blank()
      Text(value)
        .fontSize(typeScale.body.fontSize)
        .fontColor(appearance.tokens().foreground)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: '60%' })
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
  }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: 20 }) {
          Text(t('Account'))
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

            Column() {
              if (app.spaceName) {
                this.row(t('Space'), app.spaceName)
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
            }
            .width('100%')
            .padding({ left: 16, right: 16 })
            .backgroundColor(appearance.tokens().card)
            .borderRadius(12)

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
