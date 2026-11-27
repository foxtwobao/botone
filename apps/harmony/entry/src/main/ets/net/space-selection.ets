// The selected Space on disk (A1): the Space the person last chose, kept beside the token in
// asset storage so a restart opens it again. A corrupt or empty value reads as no choice — the
// first me read then falls back to the server's default. Clearing is best effort: a session that
// ends must not fail because the store could not be wiped, and the first read after a restart
// heals a stale value through the 401 recovery.
import { hilog } from '@kit.PerformanceAnalysisKit';
import { assetGetString, assetPutString, assetRemoveString } from './asset-store';

const SPACE_KEY = 'rakazo.space_id';

/** The stored Space id, or '' when none was saved (or the value cannot be read). */
export async function loadSelectedSpace(): Promise<string> {
  try {
    return (await assetGetString(SPACE_KEY)) ?? '';
  } catch (err) {
    return '';
  }
}

/** Saves the selection; the caller owns a failure (a switch rolls back on it). */
export async function saveSelectedSpace(id: string): Promise<void> {
  await assetPutString(SPACE_KEY, id);
}

/** Forgets the selection; a failure is only reported, never surfaced to the caller. */
export async function clearSelectedSpace(): Promise<void> {
  try {
    await assetRemoveString(SPACE_KEY);
  } catch (err) {
    hilog.warn(0, 'SpaceSelection', 'Could not clear the stored Space');
  }
}