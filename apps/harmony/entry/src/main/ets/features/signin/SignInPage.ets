// Sign-in aligned with apps/mobile/app/sign-in.tsx (PR1 of the port plan): one capabilities-
// driven state machine (features/signin/sign-in-view.ets) — provider chooser with email
// choice, email form with typo suggestions, emailed-code step, in-app forgot-password via
// request-password-reset — plus provider sign-in through the in-app incognito web session
// (net/sso.ets). Passkey entries are an input held false for PR2.
import { appearance } from '../../uikit/theme';
import { typeScale } from '../../uikit/tokens.generated';
import { ActionButton, ErrorText, Field } from '../../uikit/controls';
import { t } from '../../i18n/i18n';
import { app } from '../../app/app-state';
import type { AppState } from '../../app/app-state';
import {
  authCapabilities,
  requestPasswordReset,
  sendSignInCode,
  signIn,
  signInWithCode,
  signUp,
} from '../../net/auth';
import { continueWithSso } from '../../net/sso';
import { credentialIssue, errorText, RpcError } from '../../net/errors';
import { currentApiBase } from '../../net/server-store';
import { displaySavedServer } from '../../net/endpoint';
import { openAuthSession, ssoStackOf } from './sso-session';
import { suggestEmailCorrection } from './email-typo';
import {
  CODE_LENGTH,
  defaultName,
  emailSuggestion,
  headline,
  primaryLabel,
  signInView,
  switchLabels,
} from './sign-in-view';
import type { SignInMode, SignInViewInput, SignInView } from './sign-in-view';
import { ProviderButton, ProviderTextLink, providerLabel } from './ProviderButtons';
import { hasSignedInBefore } from './returning-user';
import type { AuthCapabilitiesView, SignInProviderView } from '../../contract/decode';

/** Password fields cap at the server's limit (packages/core password-policy: 128). */
const MAX_PASSWORD_LENGTH = 128;

@ComponentV2
export struct SignInPage {
  @Param stack: NavPathStack = new NavPathStack();
  @Local appRef: AppState = app;
  @Local capabilities: AuthCapabilitiesView | null = null;
  @Local capsLoading: boolean = true;
  @Local capsError: boolean = false;
  @Local capsAttempt: number = 0;
  /** in | up | forgot; a returning user lands on sign-in, a first visit on sign-up. */
  @Local mode: string = 'up';
  @Local name: string = '';
  @Local email: string = '';
  @Local emailBlurred: boolean = false;
  @Local warnedEmail: string = '';
  @Local password: string = '';
  @Local code: string = '';
  @Local codeSent: boolean = false;
  @Local resetSent: boolean = false;
  @Local emailStep: boolean = false;
  /** PR2 turns passkeys on; every entry stays hidden while this is false. */
  @Local passkeys: boolean = false;
  @Local pending: boolean = false;
  @Local error: string = '';
  private capsGeneration: number = 0;

  @Computed
  get view(): SignInView {
    const input: SignInViewInput = {
      capabilities: this.capabilities,
      mode: this.mode as SignInMode,
      emailStep: this.emailStep,
      password: this.password,
      codeSent: this.codeSent,
      resetSent: this.resetSent,
      passkeys: this.passkeys,
    };
    return signInView(input);
  }

  aboutToAppear(): void {
    void hasSignedInBefore().then((returning: boolean): void => {
      this.mode = returning ? 'in' : 'up';
    });
    void this.loadCapabilities();
  }

  // Returning from ServerPage after a committed switch: drop every step the old server owns.
  @Monitor('appRef.serverBase')
  onServerChanged(): void {
    this.emailStep = false;
    this.codeSent = false;
    this.code = '';
    this.password = '';
    this.resetSent = false;
    this.error = '';
    void this.loadCapabilities();
  }

  @Monitor('capsAttempt')
  onCapsRetry(): void {
    void this.loadCapabilities();
  }

  private async loadCapabilities(): Promise<void> {
    const generation = ++this.capsGeneration;
    this.capsLoading = true;
    this.capsError = false;
    // A code belongs to the server that sent it.
    this.codeSent = false;
    this.code = '';
    try {
      const capabilities = await authCapabilities();
      if (generation !== this.capsGeneration) {
        return;
      }
      this.capabilities = capabilities;
    } catch (err) {
      if (generation !== this.capsGeneration) {
        return;
      }
      this.capsError = true;
    } finally {
      if (generation === this.capsGeneration) {
        this.capsLoading = false;
      }
    }
  }

  private suggestion(): string | null {
    return emailSuggestion(this.mode as SignInMode, suggestEmailCorrection(this.email));
  }

  private async submit(enteredCode: string = ''): Promise<void> {
    const capabilities = this.capabilities;
    const view = this.view;
    if (this.pending || capabilities === null) {
      return;
    }
    const email = this.email.trim();
    const issue = credentialIssue(email, view.usingCode || this.mode === 'forgot' ? null : this.password);
    if (issue !== null) {
      this.error = issue === 'email' ? t('Enter a valid email') : t('Enter a password');
      return;
    }
    // One warning per address: the first submit shows the suggestion, the next one goes through.
    const suggestion = this.suggestion();
    if (suggestion !== null && this.warnedEmail !== this.email) {
      this.warnedEmail = this.email;
      this.emailBlurred = true;
      return;
    }
    // An unfinished code would spend one of the code's three attempts.
    const typedCode = enteredCode !== '' ? enteredCode : this.code;
    if (view.codeStep && typedCode.length !== CODE_LENGTH) {
      return;
    }
    this.pending = true;
    this.error = '';
    try {
      if (this.mode === 'forgot') {
        const resetUrl = capabilities.resetUrl;
        if (!capabilities.passwordReset || resetUrl === null) {
          throw new Error(t('Password recovery is not configured for this server'));
        }
        await requestPasswordReset(email, resetUrl);
        this.resetSent = true;
      } else if (view.usingCode && !this.codeSent) {
        const sentFrom = currentApiBase();
        await sendSignInCode(email);
        // A switch mid-send leaves the code with the old server; the new one starts clean.
        if (currentApiBase() !== sentFrom) {
          return;
        }
        this.code = '';
        this.codeSent = true;
      } else if (view.usingCode) {
        try {
          // The name is only used when this creates the account.
          await signInWithCode(email, typedCode, this.mode === 'up' ? defaultName(this.name, email) : null);
        } catch (err) {
          // A wrong code never keeps its input (web parity).
          this.code = '';
          throw err as Error;
        }
      } else if (this.mode === 'up') {
        const result = await signUp(email, this.password, defaultName(this.name, email));
        if (result.verificationRequired) {
          this.resetSent = true;
        }
      } else {
        await signIn(email, this.password);
      }
    } catch (err) {
      const rpcError = err instanceof RpcError ? err as RpcError : null;
      this.error = rpcError !== null ? errorText(rpcError)
        : err instanceof Error ? (err as Error).message : t('Could not continue');
    } finally {
      this.pending = false;
    }
  }

  /** Provider sign-in: pending guards a second tap, the session listener owns the screen on
   *  success, errors carry the auth copy. */
  private async startProvider(provider: SignInProviderView): Promise<void> {
    if (this.pending) {
      return;
    }
    this.pending = true;
    this.error = '';
    try {
      await continueWithSso(provider.id, (url: string, stateCookie: string): Promise<string | null> =>
        openAuthSession(ssoStackOf(this.stack), url, stateCookie));
    } catch (err) {
      const rpcError = err instanceof RpcError ? err as RpcError : null;
      this.error = rpcError !== null ? errorText(rpcError)
        : err instanceof Error ? (err as Error).message : t('Could not continue');
    } finally {
      this.pending = false;
    }
  }

  private applyMode(mode: SignInMode): void {
    this.mode = mode;
    this.error = '';
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

  @Builder
  providerButtons() {
    ForEach(this.view.primary, (provider: SignInProviderView): void => {
      ProviderButton({
        label: providerLabel(provider.name),
        mark: provider.mark,
        outlined: provider.variant === 'outline',
        disabled: this.pending,
        onTap: (): void => {
          void this.startProvider(provider);
        },
      })
    }, (provider: SignInProviderView): string => provider.id)
    if (this.view.emailChoice) {
      ProviderButton({
        label: t('Continue with email'),
        mark: null,
        stroked: true,
        outlined: true,
        disabled: this.pending,
        onTap: (): void => {
          this.error = '';
          this.emailStep = true;
        },
      })
    }
    if (this.view.passkeyChoice) {
      ProviderButton({
        label: t('Continue with passkey'),
        mark: null,
        stroked: true,
        outlined: true,
        disabled: this.pending,
        onTap: (): void => {
        },
      })
    }
    ForEach(this.view.secondary, (provider: SignInProviderView): void => {
      ProviderTextLink({
        label: providerLabel(provider.name),
        disabled: this.pending,
        onTap: (): void => {
          void this.startProvider(provider);
        },
      })
    }, (provider: SignInProviderView): string => provider.id)
  }

  build() {
    Scroll() {
      Column({ space: 20 }) {
        if (this.view.presented && this.emailStep) {
          // Back to the chooser; the email keeps its value.
          Text(t('Back'))
            .fontSize(typeScale.secondary.fontSize)
            .fontWeight(FontWeight.Medium)
            .fontColor(appearance.tokens().mutedForeground)
            .alignSelf(ItemAlign.Start)
            .padding({ top: 8, bottom: 8, right: 16 })
            .onClick((): void => {
              this.error = '';
              this.emailStep = false;
            })
        }
        Text(headline(this.mode as SignInMode, this.view))
          .fontSize(typeScale.title.fontSize)
          .fontWeight(FontWeight.Bold)
          .fontColor(appearance.tokens().foreground)
          .alignSelf(ItemAlign.Start)
        if (this.view.chooserHeadline) {
          Text(t('Persistent AI teammates that do real work'))
            .fontSize(typeScale.secondary.fontSize)
            .fontColor(appearance.tokens().mutedForeground)
            .alignSelf(ItemAlign.Start)
        }
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
          ErrorText({ message: t('Could not load sign-in options') })
          ActionButton({
            label: t('Retry'),
            kind: 'secondary',
            onTap: (): void => {
              this.capsAttempt += 1;
            },
          })
        } else if (this.view.resetConfirmation) {
          Text(t('Check your email'))
            .fontSize(typeScale.secondary.fontSize)
            .fontColor(appearance.tokens().mutedForeground)
            .alignSelf(ItemAlign.Start)
          ActionButton({
            label: t('Back to sign in'),
            kind: 'secondary',
            onTap: (): void => {
              this.applyMode('in');
              this.resetSent = false;
              this.codeSent = false;
            },
          })
        } else if (this.view.codeField) {
          Field({
            label: t('Code'),
            placeholder: t('Code'),
            value: this.code,
            numeric: true,
            maxLength: CODE_LENGTH,
            disabled: this.pending,
            onChange: (value: string): void => {
              const digits = value.replace(/\D/g, '').slice(0, CODE_LENGTH);
              this.code = digits;
              // A complete code signs in at once.
              if (digits.length === CODE_LENGTH) {
                void this.submit(digits);
              }
            },
            onSubmit: (): void => {
              void this.submit();
            },
          })
          ErrorText({ message: this.error })
          ActionButton({
            label: this.pending ? t('Working…') : t('Continue'),
            busy: this.pending,
            disabled: this.code.length < CODE_LENGTH,
            onTap: (): void => {
              void this.submit();
            },
          })
          ActionButton({
            label: t('Back'),
            kind: 'secondary',
            disabled: this.pending,
            onTap: (): void => {
              // Back keeps the email; only the code step closes.
              this.codeSent = false;
              this.code = '';
              this.error = '';
            },
          })
        } else if (this.view.chooserCard) {
          this.providerButtons()
          ErrorText({ message: this.error })
        } else if (this.view.emailForm) {
          if (this.view.nameField) {
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
          Field({
            label: t('Email'),
            placeholder: t('Email'),
            value: this.email,
            email: true,
            disabled: this.pending,
            onChange: (value: string): void => {
              this.email = value;
              this.emailBlurred = false;
            },
            onSubmit: (): void => {
              void this.submit();
            },
            lostFocus: (): void => {
              this.emailBlurred = true;
            },
          })
          if (this.view.suggestionRow && this.emailBlurred && this.suggestion() !== null) {
            Text(t('Did you mean {email}?', this.suggestionValues()))
              .fontSize(typeScale.secondary.fontSize)
              .fontColor(appearance.tokens().warning)
              .width('100%')
              .onClick((): void => {
                this.email = this.suggestion() ?? '';
                this.emailBlurred = false;
              })
          }
          if (this.view.passwordField) {
            Field({
              label: t('Password'),
              placeholder: t('Password'),
              value: this.password,
              secure: true,
              maxLength: MAX_PASSWORD_LENGTH,
              disabled: this.pending,
              onChange: (value: string): void => {
                this.password = value;
              },
              onSubmit: (): void => {
                void this.submit();
              },
            })
          }
          ErrorText({ message: this.error })
          ActionButton({
            label: primaryLabel(this.view, this.mode as SignInMode, this.pending),
            busy: this.pending,
            onTap: (): void => {
              void this.submit();
            },
          })
          if (this.view.passkeyForm) {
            ActionButton({
              label: t('Sign in with passkey'),
              kind: 'secondary',
              disabled: this.pending,
              onTap: (): void => {
              },
            })
          }
          if (this.view.forgotRow) {
            Text(t('Forgot password?'))
              .fontSize(typeScale.secondary.fontSize)
              .fontWeight(FontWeight.Medium)
              .fontColor(appearance.tokens().foreground)
              .alignSelf(ItemAlign.Center)
              .padding(8)
              .onClick((): void => {
                this.applyMode('forgot');
              })
          }
          if (this.view.switchRow) {
            Row({ space: 5 }) {
              Text(switchLabels(this.mode as SignInMode).question)
                .fontSize(typeScale.secondary.fontSize)
                .fontColor(appearance.tokens().mutedForeground)
              Text(switchLabels(this.mode as SignInMode).action)
                .fontSize(typeScale.secondary.fontSize)
                .fontWeight(FontWeight.Medium)
                .fontColor(appearance.tokens().foreground)
                .onClick((): void => {
                  if (this.mode === 'forgot') {
                    this.applyMode('in');
                    return;
                  }
                  this.applyMode(this.mode === 'in' ? 'up' : 'in');
                })
            }
            .justifyContent(FlexAlign.Center)
            .width('100%')
          }
        } else if (this.view.providerOnly) {
          // SSO-only server: buttons alone, no form, no hint copy.
          this.providerButtons()
          ErrorText({ message: this.error })
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

  private suggestionValues(): Record<string, string> {
    const values: Record<string, string> = {};
    values['email'] = this.suggestion() ?? '';
    return values;
  }}
