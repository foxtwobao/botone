// Navigation root (design §6.2): one Navigation + NavPathStack. The session phase picks the
// root screen — sign-in, or the inbox once signed in. Account, archived and server are pushed
// destinations; system back is Navigation's own.
import { app } from '../app/app-state';
import { appearance } from '../uikit/theme';
import { SignInPage } from '../features/signin/SignInPage';
import { InboxPage } from '../features/inbox/InboxPage';
import { SettingsPage } from '../features/settings/SettingsPage';
import { ArchivedPage } from '../features/archived/ArchivedPage';
import { ServerPage } from '../features/server/ServerPage';
import { VoicePage } from '../features/settings/VoicePage';
import { VoicePlayerBar } from '../features/chat/voice-player-bar';
import { ThreadPage } from '../features/chat/ThreadPage';
import type { ThreadRoute } from '../features/chat/thread-route';
import { ShareTargetSheet } from '../features/chat/share-target-sheet';
import { incomingShare } from '../stores/incoming-share-store';

@Entry
@ComponentV2
struct Index {
  private stack: NavPathStack = new NavPathStack();

  @Builder
  shareTarget() {
    ShareTargetSheet({ stack: this.stack })
  }

  @Builder
  destinations(name: string, route: ThreadRoute) {
    if (name === 'server') {
      ServerPage({ stack: this.stack })
    } else if (name === 'archived') {
      ArchivedPage({ stack: this.stack })
    } else if (name === 'settings') {
      SettingsPage({ stack: this.stack })
    } else if (name === 'voice') {
      VoicePage({ stack: this.stack })
    } else if (name === 'chat') {
      ThreadPage({
        stack: this.stack,
        botId: route.botId,
        groupId: route.groupId,
        title: route.title,
        route: route,
      })
    }
  }

  build() {
    Column() {
    Navigation(this.stack) {
      if (app.phase === 'signIn') {
        SignInPage({ stack: this.stack })
      } else if (app.phase === 'me') {
        InboxPage({ stack: this.stack })
      } else {
        Column() {
          LoadingProgress()
            .width(40)
            .height(40)
            .color(appearance.tokens().foreground)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }
    }
    .navDestination(this.destinations)
    .hideTitleBar(true)
    .mode(NavigationMode.Stack)
    .backgroundColor(appearance.tokens().background)
    .layoutWeight(1)
    VoicePlayerBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(appearance.tokens().background)
    .bindSheet(app.phase === 'me' && app.me !== null && incomingShare.pending !== null, this.shareTarget(), {
      height: SheetSize.MEDIUM,
      showClose: false,
      onWillDismiss: (action: DismissSheetAction): void => { incomingShare.cancel(); action.dismiss(); },
    })
  }
}
