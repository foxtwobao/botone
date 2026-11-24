// Theme (design §6.1): the generated mobile palette, resolved against the system color mode.
// M1 follows the system; a manual preference arrives with the M4 settings screen.
import { ConfigurationConstant } from '@kit.AbilityKit';
import { darkTokens, lightTokens } from './tokens.generated';
import type { ColorTokens } from './tokens.generated';

@ObservedV2
export class AppearanceStore {
  @Trace dark: boolean = false;

  tokens(): ColorTokens {
    return this.dark ? darkTokens : lightTokens;
  }

  update(colorMode: ConfigurationConstant.ColorMode | undefined): void {
    this.dark = colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }
}

export const appearance: AppearanceStore = new AppearanceStore();
