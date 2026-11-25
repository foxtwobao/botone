// The microphone permission (M7): asked only when it is not allowed yet, as mobile asks it, so
// the plan's own answers come back without a prompt. The reason the prompt shows is a resource
// string the module's permission entry names (module.json5), never copy in code.
import { abilityAccessCtrl, bundleManager } from '@kit.AbilityKit';
import type { common, Permissions } from '@kit.AbilityKit';

const MICROPHONE: string = 'ohos.permission.MICROPHONE';

/** True when the microphone is allowed already. */
export function microphoneGranted(): boolean {
  try {
    const info = bundleManager.getBundleInfoForSelfSync(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION,
    );
    const manager = abilityAccessCtrl.createAtManager();
    return manager.checkAccessTokenSync(info.appInfo.accessTokenId, MICROPHONE as Permissions)
      === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
  } catch (err) {
    return false;
  }
}

/** Asks for the microphone when it is not allowed yet; the answer is whether dictation may listen. */
export async function requestMicrophone(context: common.UIAbilityContext): Promise<boolean> {
  if (microphoneGranted()) {
    return true;
  }
  try {
    const wanted: Array<Permissions> = [MICROPHONE as Permissions];
    const answer = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, wanted);
    return answer.authResults.length > 0 && answer.authResults[0] === 0;
  } catch (err) {
    return false;
  }
}
