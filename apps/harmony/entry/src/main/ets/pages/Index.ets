// Navigation root (design §6.2): one Navigation + NavPathStack. The session phase picks the
// root screen; ServerPage is a pushed destination. System back is Navigation's own.
import { app } from '../app/app-state';
import { appearance } from '../uikit/theme';
import { SignInPage } from '../features/signin/SignInPage';
import { MePage } from '../features/me/MePage';
import { ServerPage } from '../features/server/ServerPage';

@Entry
@ComponentV2
struct Index {
  private stack: NavPathStack = new NavPathStack();

  @Builder
  destinations(name: string) {
    if (name === 'server') {
      ServerPage({ stack: this.stack })
    }
  }

  build() {
    Navigation(this.stack) {
      if (app.phase === 'signIn') {
        SignInPage({ stack: this.stack })
      } else if (app.phase === 'me') {
        MePage({ stack: this.stack })
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
  }
}
