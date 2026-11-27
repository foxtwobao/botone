// The sign-in page's state machine as testable pure functions, ported from the render-time
// derivations and JSX conditions in apps/mobile/app/sign-in.tsx (the same flags, the same
// order, the same branches). The page keeps only raw input in state; every screen branch
// reads from signInView's output.
import { t } from '../../i18n/i18n';
import type { AuthCapabilitiesView, SignInProviderView } from '../../contract/decode';

export const CODE_LENGTH = 6;

/** in | up | forgot, mobile AuthMode. */
export type SignInMode = 'in' | 'up' | 'forgot';

/** The buttons' grouping (contracts signInProviderGroups): organization SSO sits under the
 *  personal providers as a text link, unless it is the only provider. */
export interface ProviderGroupView {
  primary: SignInProviderView[];
  secondary: SignInProviderView[];
}

export function providerGroups(providers: SignInProviderView[]): ProviderGroupView {
  const alongsidePersonal = providers.some((provider): boolean => provider.id !== 'oidc');
  const group: ProviderGroupView = { primary: [], secondary: [] };
  for (const provider of providers) {
    if (alongsidePersonal && provider.id === 'oidc') {
      group.secondary.push(provider);
    } else {
      group.primary.push(provider);
    }
  }
  return group;
}

export interface SignInViewInput {
  capabilities: AuthCapabilitiesView | null;
  mode: SignInMode;
  emailStep: boolean;
  password: string;
  codeSent: boolean;
  resetSent: boolean;
  /** The passkey entries are an input so PR2 can turn them on without touching the derivation. */
  passkeys: boolean;
}

/** Which block the page renders, exactly one screen per combination, like mobile's JSX. */
export interface SignInView {
  providers: SignInProviderView[];
  primary: SignInProviderView[];
  secondary: SignInProviderView[];
  codeFlow: boolean;
  usingCode: boolean;
  codeStep: boolean;
  chooser: boolean;
  presented: boolean;
  /** The provider chooser card (headline + buttons). */
  chooserCard: boolean;
  /** The email/password form, including forgot mode's email-only form. */
  emailForm: boolean;
  /** Name field, sign-up only. */
  nameField: boolean;
  /** Password field, hidden in forgot mode. */
  passwordField: boolean;
  /** The typo suggestion row, sign-up only. */
  suggestionRow: boolean;
  /** The passkey button under the password field. */
  passkeyForm: boolean;
  /** The "Forgot password?" link under the password field. */
  forgotRow: boolean;
  /** The sign-in/sign-up switch row under the form. */
  switchRow: boolean;
  /** The emailed-code entry step. */
  codeField: boolean;
  /** "Continue with email" on the chooser. */
  emailChoice: boolean;
  /** The passkey button on the chooser. */
  passkeyChoice: boolean;
  /** The reset-sent / code-sent confirmation state. */
  resetConfirmation: boolean;
  /** Provider buttons without any form (SSO-only server). */
  providerOnly: boolean;
  /** The chooser's tagline. */
  chooserHeadline: boolean;
}

/** One screen derivation per render: the mobile sign-in page's booleans, exactly. */
export function signInView(input: SignInViewInput): SignInView {
  const reset = input.capabilities;
  const hasReset = reset !== null;
  const passwordAuth = hasReset && reset.passwordAuth;
  const providers = hasReset ? reset.providers : [];
  const codeFlow = passwordAuth && hasReset && reset.emailCode && input.mode !== 'forgot';
  // A blank password asks for an emailed code, so code-only accounts need no toggle.
  const usingCode = codeFlow && (input.codeSent || input.password === '');
  const codeStep = codeFlow && input.codeSent;
  // The reset-sent confirmation owns the screen; the code step renders beside the same
  // headline only when no confirmation was sent (mobile renders them as exclusive branches).
  const confirmation = input.resetSent && !codeStep;
  const chooser = passwordAuth && providers.length > 0 && !input.emailStep && input.mode !== 'forgot'
    && !codeStep && !input.resetSent;
  const presented = passwordAuth && providers.length > 0 && input.mode !== 'forgot' && !codeStep
    && !input.resetSent;
  // The form branch (mobile's `reset?.passwordAuth ?`): every mode but chooser, code step and
  // the sent confirmations. Forgot mode renders it too, minus password and switch labels.
  const emailForm = passwordAuth && !input.resetSent && !codeStep && !chooser;
  const groups = providerGroups(providers);
  return {
    providers: providers,
    primary: groups.primary,
    secondary: groups.secondary,
    codeFlow: codeFlow,
    usingCode: usingCode,
    codeStep: codeStep,
    chooser: chooser,
    presented: presented,
    chooserCard: chooser,
    emailForm: emailForm,
    nameField: emailForm && input.mode === 'up',
    passwordField: emailForm && input.mode !== 'forgot',
    suggestionRow: emailForm && input.mode === 'up',
    passkeyForm: emailForm && input.passkeys && input.mode === 'in' && !presented,
    forgotRow: emailForm && input.mode === 'in' && hasReset && reset.passwordReset
      && reset.resetUrl !== null,
    switchRow: emailForm && (input.mode !== 'in' || hasReset && reset.registrationOpen),
    codeField: codeStep,
    emailChoice: chooser,
    passkeyChoice: chooser && input.passkeys,
    resetConfirmation: confirmation,
    providerOnly: hasReset && !passwordAuth && providers.length > 0 && input.mode !== 'forgot',
    chooserHeadline: chooser,
  };
}

/** The name an account gets when sign-up leaves the field blank (mobile submit's default). */
export function defaultName(name: string, email: string): string {
  const trimmed = name.trim();
  if (trimmed) {
    return trimmed;
  }
  const local = email.split('@')[0] ?? '';
  return local || 'User';
}

/** The typo suggestion the form may show, only while registering (mobile emailSuggestion). */
export function emailSuggestion(mode: SignInMode, suggestion: string | null): string | null {
  return mode === 'up' ? suggestion : null;
}

/** The switch row's two labels: the question may be empty (forgot mode shows only the link). */
export interface SwitchRowLabels {
  question: string;
  action: string;
}

/** The switch row's label pair, mobile's ternaries word for word. */
export function switchLabels(mode: SignInMode): SwitchRowLabels {
  const labels: SwitchRowLabels = { question: '', action: '' };
  if (mode === 'in') {
    labels.question = t('Don’t have an account?');
    labels.action = t('Sign up');
  } else if (mode === 'up') {
    labels.question = t('Already have an account?');
    labels.action = t('Sign in');
  } else {
    labels.action = t('Back to sign in');
  }
  return labels;
}

/** Headline copy for the step in view, the mobile title ladder word for word. */
export function headline(mode: SignInMode, view: SignInView): string {
  if (view.resetConfirmation || view.codeStep) {
    return t('Check your email');
  }
  if (view.chooser) {
    return t('Welcome to Rakazo');
  }
  if (view.presented && mode === 'in') {
    return t('Welcome back');
  }
  if (view.presented && mode === 'up') {
    return t('Create your account');
  }
  if (mode === 'in') {
    return t('Sign in to Rakazo');
  }
  if (mode === 'up') {
    return t('Sign up for Rakazo');
  }
  return t('Reset your password');
}

/** The main button's label, the mobile ladder word for word. */
export function primaryLabel(view: SignInView, mode: SignInMode, pending: boolean): string {
  if (pending) {
    return t('Working…');
  }
  if (view.usingCode) {
    return t('Continue');
  }
  if (mode === 'in') {
    return t('Sign in');
  }
  if (mode === 'up') {
    return t('Sign up');
  }
  return t('Send reset link');
}
