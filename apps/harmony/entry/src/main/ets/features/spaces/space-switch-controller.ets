// The Space switch (A2): claim the new Space in memory (every store resets and the streams
// reopen off that claim — A1), persist it, then prove it with one spaces/list read. A failed
// disk write rolls both back; an unreachable server keeps the new Space and offers a retry; a
// Space the server no longer grants leaves the fallback to the existing 401 recovery.
import { hilog } from '@kit.PerformanceAnalysisKit';
import { app } from '../../app/app-state';
import { decodeSpaceNavigation, decodeSpaceSummaries } from '../../contract/decode';
import { t } from '../../i18n/i18n';
import { RpcError } from '../../net/errors';
import { rpc } from '../../net/rpc';
import { selectedSpaceId, setSelectedSpace } from '../../net/session';
import { saveSelectedSpace, clearSelectedSpace } from '../../net/space-selection';
import { spaceStore } from '../../stores/space-store';
import { idleSwitchState, spaceSwitchEvent, spaceSwitchStep } from './space-switch';
import type { SpaceSwitchEvent, SpaceSwitchState } from './space-switch';

const EMPTY_INPUT: Record<string, Object> = {};

@ObservedV2
export class SpaceSwitchController {
  @Trace state: SpaceSwitchState = idleSwitchState();
  /** The failure row's copy; empty while nothing failed. */
  @Trace error: string = '';

  /** Switches to another Space; resolves true only when the switch completed. */
  async switchTo(target: string): Promise<boolean> {
    if (this.state.phase === 'switching' || target === selectedSpaceId()) {
      return false;
    }
    return await this.run(spaceSwitchEvent('select', selectedSpaceId(), target));
  }

  /** Re-runs a switch the network refused; the selection and its stored copy are already it. */
  async retry(): Promise<boolean> {
    if (this.state.phase !== 'failed') {
      return false;
    }
    return await this.run(spaceSwitchEvent('retry', this.state.from, this.state.target));
  }

  private async run(event: SpaceSwitchEvent): Promise<boolean> {
    const next = spaceSwitchStep(this.state, event);
    if (next === this.state) {
      return false;
    }
    const from = next.from;
    const target = next.target;
    this.state = next;
    this.error = '';
    // The claim only moves when it is a different Space: a retry already holds it, and claiming
    // it again would reopen every stream for nothing.
    if (target !== selectedSpaceId()) {
      setSelectedSpace(target);
    }
    spaceStore.noteSelection(target);
    try {
      await saveSelectedSpace(target);
    } catch (err) {
      setSelectedSpace(from);
      spaceStore.noteSelection(from);
      try {
        await saveSelectedSpace(from);
      } catch (rollbackErr) {
        hilog.warn(0, 'SpaceSwitch', 'Could not restore the previous Space on disk');
      }
      this.state = spaceSwitchStep(this.state, spaceSwitchEvent('disk_fail', from, target));
      this.error = t('Could not switch spaces');
      return false;
    }
    return await this.verify(target);
  }

  /** One read under the new Space proves the server grants it and fills the Space screens. */
  private async verify(target: string): Promise<boolean> {
    try {
      const value = await rpc('spaces/list', EMPTY_INPUT);
      const navigation = decodeSpaceNavigation(value);
      if (navigation === null || navigation.currentId !== target) {
        // The server answered, but not for the Space that was asked: nothing refuses the claim
        // here, so the switch takes the rollback itself before reading the account again.
        this.gone(true);
        return false;
      }
      spaceStore.updateFromNavigation(navigation, decodeSpaceSummaries(value));
      this.state = spaceSwitchStep(this.state, spaceSwitchEvent('ok', '', target));
      return true;
    } catch (err) {
      const error = err instanceof RpcError ? err as RpcError : null;
      if (error !== null && error.status === 401) {
        this.gone(false);
        return false;
      }
      this.state = spaceSwitchStep(this.state, spaceSwitchEvent('net_fail', '', target));
      this.error = t('Could not switch spaces');
      return false;
    }
  }

  /** The target is gone. A 401 has already had the rpc layer's recovery clear the selection and
   *  its stored copy, so only the account read is left; an answer for another Space needs that
   *  clearing first. */
  private async gone(clearHere: boolean): Promise<void> {
    if (clearHere) {
      try {
        await clearSelectedSpace();
      } catch (err) {
        hilog.warn(0, 'SpaceSwitch', 'Could not clear the refused Space on disk');
      }
      setSelectedSpace('');
    }
    this.state = spaceSwitchStep(this.state, spaceSwitchEvent('target_gone', '', ''));
    void app.loadMe();
  }
}

export const spaceSwitcher: SpaceSwitchController = new SpaceSwitchController();