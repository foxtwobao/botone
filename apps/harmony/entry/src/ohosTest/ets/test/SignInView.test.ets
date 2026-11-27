// The sign-in state machine's pure derivations, PR1: the same branches mobile's render-time
// flags take, pinned case by case (chooser/card/form/code step/forgot/SSO-only), the provider
// grouping, the switch labels, and the default name. Pure input → output; no page, no device.
// Every case reads the page through the single screen flags the page's if-chain selects.
import { describe, expect, it } from '@ohos/hypium';
import { decodeAuthCapabilities } from '../../../main/ets/contract/decode';
import {
  defaultName,
  headline,
  providerGroups,
  sendStillCurrent,
  signInView,
  switchLabels,
} from '../../../main/ets/features/signin/sign-in-view';
import type { SignInMode, SignInViewInput } from '../../../main/ets/features/signin/sign-in-view';

/** Capabilities for the case at hand, decoded like the wire shape (also proves the decoder). */
function caps(json: string): SignInViewInput {
  const input: SignInViewInput = {
    capabilities: decodeAuthCapabilities(JSON.parse(json)),
    mode: 'up' as SignInMode,
    emailStep: false,
    password: '',
    codeSent: false,
    resetSent: false,
    passkeys: false,
  };
  return input;
}

const PASSWORD_ONLY = '{"passwordAuth":true,"passwordReset":true,"resetUrl":"https://example.com/reset",'
  + '"emailCode":false,"sso":null,"providers":[]}';
const PASSWORD_CODE = '{"passwordAuth":true,"passwordReset":true,"resetUrl":"https://example.com/reset",'
  + '"emailCode":true,"sso":null,"providers":[]}';
const PASSWORD_PROVIDERS = '{"passwordAuth":true,"passwordReset":true,"resetUrl":"https://example.com/reset",'
  + '"emailCode":true,"sso":null,"providers":['
  + '{"id":"google","name":"Google"},'
  + '{"id":"oidc","name":"Org SSO"}]}';
const SSO_ONLY_ONE = '{"passwordAuth":false,"passwordReset":false,"resetUrl":null,"emailCode":false,'
  + '"sso":null,"providers":[{"id":"oidc","name":"Org SSO"}]}';
const SSO_ONLY_PERSONAL = '{"passwordAuth":false,"passwordReset":false,"resetUrl":null,"emailCode":false,'
  + '"sso":null,"providers":[{"id":"google","name":"Google"},{"id":"oidc","name":"Org SSO"}]}';
const NOTHING = '{"passwordAuth":false,"passwordReset":false,"resetUrl":null,"emailCode":false,'
  + '"sso":null,"providers":[]}';

export default function signInViewTest() {
  describe('SignInView', () => {
    it('password_only_shows_the_form_and_switch_row', 0, () => {
      const view = signInView(caps(PASSWORD_ONLY));
      expect(view.emailForm).assertTrue();
      expect(view.nameField).assertTrue(); // initial mode is up
      expect(view.passwordField).assertTrue();
      expect(view.switchRow).assertTrue();
      expect(view.chooserCard).assertFalse();
      expect(view.codeField).assertFalse();
      expect(view.providerOnly).assertFalse();
    });

    it('password_and_code_starts_on_continue_and_reaches_the_code_step', 0, () => {
      const blank = signInView(caps(PASSWORD_CODE));
      // A blank password asks for the code: the button is Continue and there is no toggle.
      expect(blank.usingCode).assertTrue();
      expect(blank.emailForm).assertTrue();
      expect(blank.passwordField).assertTrue();
      // The password typed: back to the plain form until the code is sent.
      const withPassword = caps(PASSWORD_CODE);
      withPassword.password = 'secret';
      const typed = signInView(withPassword);
      expect(typed.usingCode).assertFalse();
      // The code sent: the code step owns the screen — it is the page the page's if-chain
      // selects, not the reset-sent confirmation, and the headline still reads Check your email.
      const sent = caps(PASSWORD_CODE);
      sent.codeSent = true;
      sent.emailStep = false;
      const step = signInView(sent);
      expect(step.codeField).assertTrue();
      expect(step.resetConfirmation).assertFalse();
      expect(step.emailForm).assertFalse();
      expect(step.chooserCard).assertFalse();
      expect(headline('up' as SignInMode, step)).assertEqual('Check your email');
    });

    it('password_and_providers_shows_the_chooser_without_a_switch_row', 0, () => {
      const view = signInView(caps(PASSWORD_PROVIDERS));
      expect(view.chooserCard).assertTrue();
      expect(view.emailChoice).assertTrue();
      expect(view.presented).assertTrue();
      expect(view.switchRow).assertFalse();
      expect(view.emailForm).assertFalse();
      // The email step opens the form with a back affordance and the switch row.
      const step = caps(PASSWORD_PROVIDERS);
      step.emailStep = true;
      const form = signInView(step);
      expect(form.emailForm).assertTrue();
      expect(form.chooserCard).assertFalse();
      // Sign-in mode on the chooser: still the chooser, still no switch row.
      const signin = caps(PASSWORD_PROVIDERS);
      signin.mode = 'in' as SignInMode;
      const chooser = signInView(signin);
      expect(chooser.chooserCard).assertTrue();
      expect(chooser.switchRow).assertFalse();
    });

    it('forgot_mode_shows_email_only_with_the_back_link', 0, () => {
      const input = caps(PASSWORD_CODE);
      input.mode = 'forgot' as SignInMode;
      const view = signInView(input);
      expect(view.emailForm).assertTrue();
      expect(view.passwordField).assertFalse();
      expect(view.nameField).assertFalse();
      // The switch row stays: forgot mode renders its action as "Back to sign in".
      expect(view.switchRow).assertTrue();
      expect(switchLabels('forgot' as SignInMode).action).assertEqual('Back to sign in');
      expect(view.codeFlow).assertFalse();
      expect(view.providerOnly).assertFalse();
    });

    it('sso_only_servers_show_buttons_without_any_form', 0, () => {
      const one = signInView(caps(SSO_ONLY_ONE));
      expect(one.providerOnly).assertTrue();
      expect(one.emailForm).assertFalse();
      expect(one.chooserCard).assertFalse();
      // Two providers, one personal one organization: personal is primary, org is the link.
      const both = signInView(caps(SSO_ONLY_PERSONAL));
      expect(both.providerOnly).assertTrue();
    });

    it('a_server_with_nothing_configured_shows_no_branch', 0, () => {
      const view = signInView(caps(NOTHING));
      expect(view.emailForm).assertFalse();
      // Nothing to sign in with: the provider screen needs at least one provider.
      expect(view.providerOnly).assertFalse();
      expect(view.chooserCard).assertFalse();
      expect(view.codeField).assertFalse();
    });

    it('reset_sent_shows_the_confirmation_everywhere', 0, () => {
      const input = caps(PASSWORD_PROVIDERS);
      input.resetSent = true;
      const view = signInView(input);
      expect(view.resetConfirmation).assertTrue();
      expect(view.emailForm).assertFalse();
      expect(view.chooserCard).assertFalse();
      expect(view.codeField).assertFalse();
    });

    it('provider_groups_put_organization_sso_second_only_beside_personal', 0, () => {
      const one = decodeAuthCapabilities(JSON.parse(SSO_ONLY_ONE))!.providers;
      expect(providerGroups(one).primary.length).assertEqual(1);
      expect(providerGroups(one).secondary.length).assertEqual(0);
      const both = decodeAuthCapabilities(JSON.parse(SSO_ONLY_PERSONAL))!.providers;
      expect(providerGroups(both).primary[0].id).assertEqual('google');
      expect(providerGroups(both).secondary[0].id).assertEqual('oidc');
    });

    it('a_closed_registration_hides_the_sign_up_switch', 0, () => {
      const closed = '{"passwordAuth":true,"passwordReset":true,"resetUrl":null,"emailCode":false,'
        + '"sso":null,"providers":[],"registrationOpen":false}';
      // On sign-in the page hides the switch row: no account can be created here.
      const signin = caps(closed);
      signin.mode = 'in' as SignInMode;
      const view = signInView(signin);
      expect(view.emailForm).assertTrue();
      expect(view.switchRow).assertFalse();
      // An open registration (or an older server without the field) keeps the switch row.
      const open = caps(PASSWORD_ONLY);
      open.mode = 'in' as SignInMode;
      expect(signInView(open).switchRow).assertTrue();
    });

    it('switch_labels_match_the_mode', 0, () => {
      expect(switchLabels('in' as SignInMode).question).assertEqual('Don’t have an account?');
      expect(switchLabels('in' as SignInMode).action).assertEqual('Sign up');
      expect(switchLabels('up' as SignInMode).question).assertEqual('Already have an account?');
      expect(switchLabels('up' as SignInMode).action).assertEqual('Sign in');
      expect(switchLabels('forgot' as SignInMode).question).assertEqual('');
      expect(switchLabels('forgot' as SignInMode).action).assertEqual('Back to sign in');
    });

    it('default_name_falls_back_to_the_email_local_part_then_User', 0, () => {
      expect(defaultName('  Ada  ', 'x@y.z')).assertEqual('Ada');
      expect(defaultName('', 'ada@example.com')).assertEqual('ada');
      expect(defaultName('', '@example.com')).assertEqual('User');
      expect(defaultName('', '')).assertEqual('User');
    });

    it('send_still_current_requires_the_same_address_and_generation', 0, () => {
      // The page guard's verdict: only a send started on this address and session generation
      // may write. A switch away and back keeps the address but moves the generation.
      expect(sendStillCurrent('http://a:1', 3, 'http://a:1', 3)).assertTrue();
      expect(sendStillCurrent('http://a:1', 3, 'http://a:1', 4)).assertFalse();
      expect(sendStillCurrent('http://a:1', 3, 'http://b:2', 3)).assertFalse();
    });
  });
}
