// Server address management (design §7.2 M1): normalize → probe → switch with rollback,
// recent servers (≤5) with their saved headers, and the default server. Copy reuses the
// mobile catalog msgids; errors arrive as msgids from the net layer and translate here.
import { appearance } from '../../uikit/theme';
import { typeScale } from '../../uikit/tokens.generated';
import { ActionButton, ErrorText, Field } from '../../uikit/controls';
import { t } from '../../i18n/i18n';
import { currentApiBase, switchServer } from '../../net/server-store';
import { defaultApiBase, displaySavedServer } from '../../net/endpoint';
import { removeSavedServer, savedServers } from '../../net/saved-servers';
import type { SavedServer } from '../../net/saved-servers';
import { serverHeaders } from '../../net/server-headers';
import { app } from '../../app/app-state';

@ComponentV2
export struct ServerPage {
  @Param stack: NavPathStack = new NavPathStack();
  @Local url: string = '';
  @Local busy: boolean = false;
  @Local error: string = '';
  @Local servers: SavedServer[] = [];

  aboutToAppear(): void {
    this.servers = savedServers();
  }

  private async save(target: string): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.error = '';
    // A saved server keeps the headers it was configured with; a new one starts with none.
    const existing = this.servers.find((entry): boolean => entry.apiBase === target);
    const headers = existing !== undefined ? existing.headers : serverHeaders(target);
    const result = await switchServer(target, headers);
    this.busy = false;
    if (result.ok) {
      this.servers = savedServers();
      app.noteServerChanged();
      this.stack.pop();
    } else {
      this.error = t(result.error);
    }
  }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: 20 }) {
          Text(t('Server'))
            .fontSize(typeScale.title.fontSize)
            .fontWeight(FontWeight.Bold)
            .fontColor(appearance.tokens().foreground)
            .alignSelf(ItemAlign.Start)

          Column({ space: 6 }) {
            Text(displaySavedServer(currentApiBase()))
              .fontSize(typeScale.body.fontSize)
              .fontColor(appearance.tokens().foreground)
            if (app.updateRequired) {
              Text(t('Update required'))
                .fontSize(typeScale.caption.fontSize)
                .fontColor(appearance.tokens().warning)
            }
          }
          .width('100%')
          .padding(14)
          .backgroundColor(appearance.tokens().card)
          .borderRadius(12)
          .alignItems(HorizontalAlign.Start)

          Field({
            label: t('Add server URL'),
            placeholder: t('Enter a server URL'),
            value: this.url,
            disabled: this.busy,
            onChange: (value: string): void => {
              this.url = value;
            },
          })
          ErrorText({ message: this.error })
          ActionButton({
            label: this.busy ? t('Checking…') : t('Save'),
            busy: this.busy,
            disabled: !this.url.trim(),
            onTap: (): void => {
              void this.save(this.url.trim());
            },
          })
          ActionButton({
            label: t('Use default server'),
            kind: 'secondary',
            disabled: this.busy || currentApiBase() === defaultApiBase(),
            onTap: (): void => {
              void this.save(defaultApiBase());
            },
          })

          if (this.servers.length > 0) {
            Text(t('Recent servers'))
              .fontSize(typeScale.secondary.fontSize)
              .fontColor(appearance.tokens().mutedForeground)
              .alignSelf(ItemAlign.Start)
            Column({ space: 8 }) {
              ForEach(this.servers, (entry: SavedServer): void => {
                Row({ space: 10 }) {
                  Text(displaySavedServer(entry.apiBase))
                    .fontSize(typeScale.body.fontSize)
                    .fontColor(appearance.tokens().foreground)
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Button(t('Remove'))
                    .fontSize(typeScale.caption.fontSize)
                    .fontColor(appearance.tokens().destructive)
                    .backgroundColor(appearance.tokens().background)
                    .height(32)
                    .enabled(!this.busy)
                    .onClick((): void => {
                      void removeSavedServer(entry.apiBase).then((): void => {
                        this.servers = savedServers();
                      });
                    })
                }
                .width('100%')
                .padding(12)
                .backgroundColor(appearance.tokens().card)
                .borderRadius(12)
                .onClick((): void => {
                  void this.save(entry.apiBase);
                })
              }, (entry: SavedServer): string => entry.apiBase)
            }
            .width('100%')
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
