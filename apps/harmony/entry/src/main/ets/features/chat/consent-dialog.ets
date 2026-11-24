// The consent disclosure dialog (design §5.2, native-first): a system AlertDialog with the
// server's recipient name in the title, the server detail (or the local per-use summary) as the
// body, Not now / Allow buttons, and a Privacy policy button when the server offers a link
// (recipient's own, else the deployment's; none → no link, no hardcoded fallback). Back/outside
// dismiss resolves Not now. The dialog is installed as the gate's prompt while the chat screen
// is shown; the gate itself lives in net/consent and never imports UI.
import type { AiRecipient } from '../../net/consent';
import { consentBody } from '../../net/consent';
import { setConsentPrompt } from '../../net/consent';
import { t } from '../../i18n/i18n';
import { consentTitle } from '../../i18n/harmony-strings';
import { app } from '../../app/app-state';
import { appearance } from '../../uikit/theme';

/** One ask: resolves true only on an explicit Allow; every other exit is Not now. */
function askOnce(recipient: AiRecipient, privacyUrl: string | undefined): Promise<boolean> {
  return new Promise<boolean>((resolve: (allowed: boolean) => void): void => {
    let settled = false;
    const finish = (allowed: boolean): void => {
      if (settled) {
        return;
      }
      settled = true;
      resolve(allowed);
    };
    // One ink action (Allow) and one quiet way out; the policy stays a link. Three
    // same-colored text buttons read as three equal choices (ux-declutter M4).
    const buttons: AlertDialogButtonOptions[] = [
      {
        value: t('Not now'),
        fontColor: appearance.tokens().mutedForeground,
        action: (): void => {
          finish(false);
        },
      },
      {
        value: t('Allow'),
        fontColor: appearance.tokens().foreground,
        primary: true,
        action: (): void => {
          finish(true);
        },
      },
    ];
    if (privacyUrl !== undefined && privacyUrl.length > 0) {
      const link: AlertDialogButtonOptions = {
        value: t('Privacy policy'),
        fontColor: appearance.tokens().link,
        action: (): void => {
          // Opening the policy is not an answer; the dialog stays for the decision.
          void app.openExternal(privacyUrl);
        },
      };
      buttons.unshift(link);
    }
    AlertDialog.show({
      title: consentTitle(recipient.name),
      message: consentBody(recipient),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      buttons: buttons,
      cancel: (): void => {
        finish(false);
      },
    });
  });
}

/** Install the native dialog as the gate's prompt; the returned function removes it. */
export function installConsentDialog(): () => void {
  setConsentPrompt(askOnce);
  return (): void => {
    setConsentPrompt(null);
  };
}
