// SpaceStore (A1): the Space list a switcher names and the current Space's name. It never reads
// on its own — the navigation rides answers the app already reads (loadMe, the roster read), so
// opening a screen costs no extra request. A2 adds the switch that changes the selection.
import type { SpaceNavigationView, SpaceSummaryView } from '../contract/decode';

@ObservedV2
export class SpaceStore {
  @Trace spaces: SpaceSummaryView[] = [];
  @Trace currentName: string = '';
  @Trace loaded: boolean = false;

  /** Takes what the caller's navigation decode yielded; a null side is a decode failure there. */
  updateFromNavigation(navigation: SpaceNavigationView | null, spaces: SpaceSummaryView[] | null): void {
    if (navigation !== null) {
      this.currentName = navigation.currentName;
    }
    if (spaces !== null) {
      this.spaces = spaces;
    }
    if (navigation !== null && spaces !== null) {
      this.loaded = true;
    }
  }

  /** Names the Space a switch is heading to, from the list already read: the title follows a
   *  claim before the server's own answer names it again (A2). */
  noteSelection(id: string): void {
    for (const space of this.spaces) {
      if (space.id === id) {
        this.currentName = space.name;
        return;
      }
    }
  }

  reset(): void {
    this.spaces = [];
    this.currentName = '';
    this.loaded = false;
  }
}

export const spaceStore: SpaceStore = new SpaceStore();