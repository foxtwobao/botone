import { abilityDelegatorRegistry, TestRunner } from '@kit.TestKit';
import { Hypium } from '@ohos/hypium';
import testsuite from '../test/List.test';

export default class OpenHarmonyTestRunner implements TestRunner {
  onPrepare(): void {
  }

  onRun(): void {
    // Read the delegator and its arguments here, not at module load: at load time the
    // framework has not injected them yet and getArguments() returns null (timeout 0ms).
    const delegator = abilityDelegatorRegistry.getAbilityDelegator();
    const delegatorArguments = abilityDelegatorRegistry.getArguments();
    Hypium.hypiumTest(delegator, delegatorArguments, testsuite);
  }
}
