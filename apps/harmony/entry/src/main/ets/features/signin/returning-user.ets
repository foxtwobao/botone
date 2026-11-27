// Set once a session is seen, so a signed-out relaunch opens the sign-in form instead of
// sign-up (mobile lib/auth/returning-user.ts, written beside the token save in the session
// listener and read at bootstrap). The mark is not a secret; it lives in preferences.
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const PREFS_NAME = 'rakazo.signin';
const MARK_KEY = 'rakazo.signed-in-before';

let store: preferences.Preferences | null = null;

export function initReturningUser(context: common.Context): void {
  preferences.getPreferences(context, PREFS_NAME).then((found: preferences.Preferences): void => {
    store = found;
  }).catch((): void => {
    // Without a readable store the mark reads as unset; the flow falls back to sign-up.
  });
}

export async function hasSignedInBefore(): Promise<boolean> {
  if (store === null) {
    return false;
  }
  try {
    return (await store.get(MARK_KEY, '') as string) === '1';
  } catch (err) {
    return false;
  }
}

export async function rememberSignedIn(): Promise<void> {
  if (store === null) {
    return;
  }
  try {
    await store.put(MARK_KEY, '1');
    await store.flush();
  } catch (err) {
    // A failed write only loses the convenience; the next save tries again.
  }
}
