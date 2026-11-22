// Theme (design §6.1): the generated mobile palette, resolved against the appearance preference
// (system / light / dark) and the system color mode. The preference persists in preferences (a
// non-secret choice); System hands the window back to the OS via setColorMode(NOT_SET), a manual
// choice overrides it so native dialogs/pickers follow too — mobile's applyNativeColorScheme +
// mobileTokens double mechanism. The system mode arrives through onConfigurationUpdate.
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { darkTokens, lightTokens } from './tokens.generated';
import type { ColorTokens } from './tokens.generated';

const PREFS_NAME = 'rakazo.appearance';
const PREF_KEY = 'rakazo.uiAppearance';

/** system | light | dark — the same three choices mobile's appearance preference offers. */
export function isAppearancePreference(value: string): boolean {
  return value === 'system' || value === 'light' || value === 'dark';
}

@ObservedV2
export class AppearanceStore {
  @Trace dark: boolean = false;
  @Trace preference: string = 'system';
  private systemDark: boolean = false;
  private appContext: common.ApplicationContext | null = null;
  private store: preferences.Preferences | null = null;

  tokens(): ColorTokens {
    return this.dark ? darkTokens : lightTokens;
  }

  /** Loads the saved preference and remembers the application context for setColorMode/persist. */
  async init(context: common.Context): Promise<void> {
    this.appContext = context.getApplicationContext();
    try {
      this.store = await preferences.getPreferences(context, PREFS_NAME);
      const stored = await this.store.get(PREF_KEY, 'system');
      if (typeof stored === 'string' && isAppearancePreference(stored as string)) {
        this.preference = stored as string;
      }
    } catch (err) {
      // Without a readable store the in-memory preference (system) still applies.
    }
    this.applyColorMode();
    this.resolve();
  }

  /** The system color mode changed (bootstrap + onConfigurationUpdate). */
  update(colorMode: ConfigurationConstant.ColorMode | undefined): void {
    this.systemDark = colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.resolve();
  }

  /** A manual choice from the settings screen: persist, apply to the window, re-resolve. */
  async setPreference(preference: string): Promise<void> {
    if (!isAppearancePreference(preference)) {
      return;
    }
    this.preference = preference;
    this.applyColorMode();
    this.resolve();
    if (this.store !== null) {
      try {
        await this.store.put(PREF_KEY, preference);
        await this.store.flush();
      } catch (err) {
        // The in-memory preference still applies when the write fails.
      }
    }
  }

  /** System hands the window back to the OS; a manual choice overrides the native surfaces too. */
  private applyColorMode(): void {
    if (this.appContext === null) {
      return;
    }
    const mode = this.preference === 'system'
      ? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET
      : this.preference === 'dark'
        ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
        : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    try {
      this.appContext.setColorMode(mode);
    } catch (err) {
      // setColorMode needs a loaded window; the palette still resolves from the preference.
    }
  }

  private resolve(): void {
    this.dark = this.preference === 'system' ? this.systemDark : this.preference === 'dark';
  }
}

export const appearance: AppearanceStore = new AppearanceStore();
