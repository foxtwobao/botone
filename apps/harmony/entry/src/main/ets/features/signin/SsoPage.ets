// The in-app auth session (A1): an incognito Web inside the nav stack. The page completes the
// flow exactly once on the rakazo://sign-in main-frame redirect (every candidate load event
// is wired; real hardware fires one), cancels on SSL or main-frame load errors and on the
// person closing the page, and clears the incognito jar on the way out. No JS bridge is
// registered; the callback URL, which carries the session cookie, is never logged.
import { webview } from '@kit.ArkWeb';
import { url } from '@kit.ArkTS';
import { completeAuthSession, takeSsoRoute } from './sso-session';
import type { SsoRoute } from './sso-session';

@ComponentV2
export struct SsoPage {
  @Param stack: NavPathStack = new NavPathStack();
  @Local started: boolean = false;
  @Local target: string = '';
  private route: SsoRoute | null = null;
  private controller: webview.WebviewController = new webview.WebviewController();
  /** The redirect may report through several load events; the first one owns the answer. */
  private completed: boolean = false;

  build() {
    NavDestination() {
      if (this.started) {
        Web({ src: this.target, controller: this.controller, incognitoMode: true })
          .onLoadIntercept((event: OnLoadInterceptEvent): boolean => {
            return this.intercept(event.data.getRequestUrl(), event.data.isMainFrame());
          })
          .onOverrideUrlLoading((webResourceRequest: WebResourceRequest): boolean => {
            return this.intercept(webResourceRequest.getRequestUrl(),
              webResourceRequest.isMainFrame());
          })
          .onErrorReceive((event: OnErrorReceiveEvent): void => {
            // A failed load ends the flow like a closed page would; only the main frame counts.
            if (event.request.isMainFrame() && this.cancel()) {
              this.popQuiet();
            }
          })
          .onSslErrorEventReceive((event: OnSslErrorEventReceiveEvent): void => {
            // An untrusted certificate is never this server: cancel, do not proceed.
            event.handler.handleCancel();
            if (this.cancel()) {
              this.popQuiet();
            }
          })
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .width('100%')
          .height('100%')
      }
    }
    .hideTitleBar(true)
    .onReady((context: NavDestinationContext): void => {
      const routeParam: Object | null | undefined = context.pathInfo.param as Object;
      this.route = takeSsoRoute(routeParam);
      if (this.route === null) {
        this.cancel();
        return;
      }
      this.target = this.route.url;
      this.started = true;
    })
    .onWillDisappear((): void => {
      this.cancel();
    })
  }

  /** Every rakazo://sign-in navigation is blocked (a duplicate never navigates); only the
   *  first main-frame event settles the flow. Subframes are ignored (blocked, never completed). */
  private intercept(target: string, mainFrame: boolean): boolean {
    if (!this.isCallback(target)) {
      return false;
    }
    if (!mainFrame || this.completed) {
      return true;
    }
    this.completed = true;
    completeAuthSession(target);
    this.popQuiet();
    this.clearIncognitoJar();
    return true;
  }

  private isCallback(target: string): boolean {
    let parsed: url.URL;
    try {
      parsed = url.URL.parseURL(target);
    } catch (err) {
      return false;
    }
    return parsed.protocol.toLowerCase() === 'rakazo:' && parsed.host === 'sign-in';
  }

  /** The person closed the page (back gesture, dismiss, a failed load): not an error. Returns
   *  true only when this call settled the flow, so the caller knows the page is still up. */
  private cancel(): boolean {
    if (this.completed) {
      return false;
    }
    this.completed = true;
    completeAuthSession(null);
    this.clearIncognitoJar();
    return true;
  }

  private popQuiet(): void {
    if (this.stack.size() > 0) {
      this.stack.pop();
    }
  }

  private clearIncognitoJar(): void {
    try {
      webview.WebCookieManager.clearAllCookiesSync(true);
    } catch (err) {
      // Nothing to clear (or the store is gone); the jar dies with the incognito session.
    }
  }

  aboutToDisappear(): void {
    this.cancel();
  }
}
