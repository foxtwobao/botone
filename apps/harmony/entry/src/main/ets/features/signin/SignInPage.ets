// Sign-in (design §7.2 M1), capabilities-driven like apps/mobile/app/sign-in.tsx: password
// and email-OTP when the server offers them, sign-up with a name, OTP auto-registration, and
// forgot-password through the server's resetUrl in the system browser. SSO/passkey are Phase 2.
import { appearance } from '../../uikit/theme';
import { typeScale } from '../../uikit/tokens.generated';
import { ActionButton, ErrorText, Field } from '../../uikit/controls';
import { t } from '../../i18n/i18n';
import { SSO_ONLY_SERVER } from '../../i18n/harmony-strings';
import { app } from '../../app/app-state';
import type { AppState } from '../../app/app-state';
import { authCapabilities, sendSignInCode, signIn, signInWithCode, signUp } from '../../net/auth';
import { credentialIssue, errorText, RpcError } from '../../net/errors';
import { currentApiBase } from '../../net/server-store';
import { displaySavedServer } from '../../net/endpoint';
import type { AuthCapabilitiesView } from '../../contract/decode';

const CODE_LENGTH = 6;

@ComponentV2
export struct SignInPage {
  @Param stack: NavPathStack = new NavPathStack();
  @Local appRef: AppState = app;
  @Local capabilities: AuthCapabilitiesView | null = null;
  @Local capsLoading: boolean = true;
  @Local capsError: string = '';
  /** in | up */
  @Local mode: string = 'in';
  @Local email: string = '';
  @Local password: string = '';
  @Local name: string = '';
  @Local code: string = '';
  @Local usingCode: boolean = false;
  @Local codeSent: boolean = false;
  @Local verificationSent: boolean = false;
  @Local pending: boolean = false;
  @Local error: string = '';

  aboutToAppear(): void {
    void this.loadCapabilities();
  }

  // Returning from ServerPage after a committed switch: re-read the new server's capabilities.
  @Monitor('appRef.serverBase')
  onServerChanged(): void {
    this.codeSent = false;
    this.usingCode = false;
    this.error = '';
    void this.loadCapabilities();
  }

  private async loadCapabilities(): Promise<void> {
    this.capsLoading = true;
    this.capsError = '';
    try {
      const capabilities = await authCapabilities();
      this.capabilities = capabilities;
      // A server without password auth signs in by code only.
      this.usingCode = !capabilities.passwordAuth && capabilities.emailCode;
    } catch (err) {
      this.capsError = err instanceof Error ? (err as Error).message : t('Could not load sign-in options');
    } finally {
      this.capsLoading = false;
    }
  }

  private defaultName(email: string): string {
    return this.name.trim() || email.split('@')[0] || 'User';
  }

  private async submit(): Promise<void> {
    const capabilities = this.capabilities;
    if (this.pending || capabilities === null) {
      return;
    }
    const email = this.email.trim();
    const needsPassword = !this.usingCode && capabilities.passwordAuth;
    const issue = credentialIssue(email, needsPassword ? this.password : null);
    if (issue !== null) {
      this.error = issue === 'email' ? t('Enter a valid email') : t('Enter a password');
      return;
    }
    // An unfinished code would spend one of the code's three attempts.
    if (this.usingCode && this.codeSent && this.code.trim().length !== CODE_LENGTH) {
      return;
    }
    this.pending = true;
    this.error = '';
    try {
      if (this.usingCode) {
        if (!this.codeSent) {
          await sendSignInCode(email);
          this.codeSent = true;
          this.code = '';
        } else {
          // The name is only used when this creates the account.
          await signInWithCode(email, this.code.trim(), this.mode === 'up' ? this.defaultName(email) : null);
          await app.loadMe();
        }
      } else if (this.mode === 'up') {
        const result = await signUp(email, this.password, this.defaultName(email));
        if (result.verificationRequired) {
          this.verificationSent = true;
        } else {
          await app.loadMe();
        }
      } else {
        await signIn(email, this.password);
        await app.loadMe();
      }
    } catch (err) {
      const rpcError = err instanceof RpcError ? err as RpcError : null;
      this.error = rpcError !== null ? errorText(rpcError)
        : err instanceof Error ? (err as Error).message : t('Could not continue');
    } finally {
      this.pending = false;
    }
  }

  private primaryLabel(): string {
    if (this.usingCode) {
      return t('Continue');
    }
    return this.mode === 'up' ? t('Sign up') : t('Sign in');
  }

  private primaryDisabled(): boolean {
    if (this.usingCode && this.codeSent) {
      return this.code.trim().length !== CODE_LENGTH;
    }
    return false;
  }

  @Builder
  serverRow() {
    Row({ space: 8 }) {
      Text(displaySavedServer(this.appRef.serverBase || currentApiBase()))
        .fontSize(typeScale.caption.fontSize)
        .fontColor(appearance.tokens().mutedForeground)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(t('Change server'))
        .fontSize(typeScale.caption.fontSize)
        .fontColor(appearance.tokens().link)
        .onClick((): void => {
          this.stack.pushPathByName('server', null);
        })
    }
    .width('100%')
  }

  build() {
    Scroll() {
      Column({ space: 20 }) {
        Text(this.mode === 'up' ? t('Create your account') : t('Welcome back'))
          .fontSize(typeScale.title.fontSize)
          .fontWeight(FontWeight.Bold)
          .fontColor(appearance.tokens().foreground)
          .alignSelf(ItemAlign.Start)
        this.serverRow()

        if (this.capsLoading) {
          Row({ space: 10 }) {
            LoadingProgress().width(24).height(24).color(appearance.tokens().foreground)
            Text(t('Loading…'))
              .fontSize(typeScale.secondary.fontSize)
              .fontColor(appearance.tokens().mutedForeground)
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding(30)
        } else if (this.capsError) {
          ErrorText({ message: this.capsError })
          ActionButton({
            label: t('Retry'),
            kind: 'secondary',
            onTap: (): void => {
              void this.loadCapabilities();
            },
          })
        } else if (this.capabilities !== null) {
          if (this.verificationSent) {
            Text(t('Check your email'))
              .fontSize(typeScale.body.fontSize)
              .fontColor(appearance.tokens().foreground)
            ActionButton({
              label: t('Back to sign in'),
              kind: 'secondary',
              onTap: (): void => {
                this.verificationSent = false;
                this.mode = 'in';
              },
            })
          } else if (!this.capabilities.passwordAuth && !this.capabilities.emailCode) {
            // SSO-only server: Phase 1 has no provider sign-in; say so instead of a dead form.
            ErrorText({ message: SSO_ONLY_SERVER })
          } else {
            if (this.capabilities.passwordAuth) {
              Row({ space: 8 }) {
                Button(t('Sign in'))
                  .fontSize(typeScale.secondary.fontSize)
                  .height(36)
                  .layoutWeight(1)
                  .backgroundColor(this.mode === 'in' ? appearance.tokens().primary : appearance.tokens().muted)
                  .fontColor(this.mode === 'in' ? appearance.tokens().primaryForeground : appearance.tokens().foreground)
                  .enabled(!this.pending)
                  .onClick((): void => {
                    this.mode = 'in';
                    this.error = '';
                  })
                Button(t('Sign up'))
                  .fontSize(typeScale.secondary.fontSize)
                  .height(36)
                  .layoutWeight(1)
                  .backgroundColor(this.mode === 'up' ? appearance.tokens().primary : appearance.tokens().muted)
                  .fontColor(this.mode === 'up' ? appearance.tokens().primaryForeground : appearance.tokens().foreground)
                  .enabled(!this.pending)
                  .onClick((): void => {
                    this.mode = 'up';
                    this.error = '';
                  })
              }
              .width('100%')
            }

            Field({
              label: t('Email'),
              placeholder: t('Email'),
              value: this.email,
              email: true,
              disabled: this.pending || (this.usingCode && this.codeSent),
              onChange: (value: string): void => {
                this.email = value;
              },
            })

            if (this.usingCode && this.codeSent) {
              Text(t('Check your email'))
                .fontSize(typeScale.secondary.fontSize)
                .fontColor(appearance.tokens().mutedForeground)
                .alignSelf(ItemAlign.Start)
              Field({
                label: t('Code'),
                placeholder: t('Code'),
                value: this.code,
                disabled: this.pending,
                onChange: (value: string): void => {
                  this.code = value;
                },
              })
            } else if (!this.usingCode && this.capabilities.passwordAuth) {
              Field({
                label: t('Password'),
                placeholder: t('Password'),
                value: this.password,
                secure: true,
                disabled: this.pending,
                onChange: (value: string): void => {
                  this.password = value;
                },
              })
            }

            if (this.mode === 'up' && (!this.usingCode || this.codeSent)) {
              Field({
                label: t('Name'),
                placeholder: t('Name'),
                value: this.name,
                disabled: this.pending,
                onChange: (value: string): void => {
                  this.name = value;
                },
              })
            }

            ErrorText({ message: this.error })

            ActionButton({
              label: this.primaryLabel(),
              busy: this.pending,
              disabled: this.primaryDisabled(),
              onTap: (): void => {
                void this.submit();
              },
            })

            if (this.capabilities.emailCode && !this.usingCode) {
              ActionButton({
                label: t('Continue with email'),
                kind: 'secondary',
                disabled: this.pending,
                onTap: (): void => {
                  this.usingCode = true;
                  this.codeSent = false;
                  this.error = '';
                },
              })
            }
            if (this.usingCode && this.codeSent) {
              ActionButton({
                label: t('Back'),
                kind: 'secondary',
                disabled: this.pending,
                onTap: (): void => {
                  this.codeSent = false;
                  this.code = '';
                  this.error = '';
                },
              })
            }
            if (this.mode === 'in' && !this.usingCode && this.capabilities.passwordAuth
              && this.capabilities.passwordReset && this.capabilities.resetUrl !== null) {
              Text(t('Forgot password?'))
                .fontSize(typeScale.secondary.fontSize)
                .fontColor(appearance.tokens().link)
                .onClick((): void => {
                  const resetUrl = this.capabilities?.resetUrl;
                  if (resetUrl) {
                    void app.openExternal(resetUrl);
                  }
                })
            }
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
}
