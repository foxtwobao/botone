// Foreground source (design §5.4): EntryAbility's onForeground/onBackground drive this observable.
// The roster stream opens only in the foreground, and returning to the foreground is a catch-up
// entry point (reopen the stream + re-read). No timer lives here — the system reports the transitions.
export type ForegroundListener = (foreground: boolean) => void;

@ObservedV2
export class ForegroundStore {
  @Trace foreground: boolean = true;
  private listeners: Set<ForegroundListener> = new Set();

  set(foreground: boolean): void {
    if (this.foreground === foreground) {
      return;
    }
    this.foreground = foreground;
    for (const listener of this.listeners) {
      listener(foreground);
    }
  }

  subscribe(listener: ForegroundListener): () => void {
    this.listeners.add(listener);
    return (): void => {
      this.listeners.delete(listener);
    };
  }
}

export const foreground: ForegroundStore = new ForegroundStore();
