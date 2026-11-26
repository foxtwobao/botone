// A stop the caller owns (M7): the one cancellation a dictation hangs on. The composer cancels
// once; the recognizer session, the recording and the transcription request each end when it
// does, and a cancel that lands after a newer dictation started must not stop that one — so a
// session compares identities rather than sharing the flag.
export class StopSignal {
  private stopped: boolean = false;
  private listeners: Set<() => void> = new Set();

  /** True once cancel() ran; nothing that checks it may still act for the cancelled work. */
  isStopped(): boolean {
    return this.stopped;
  }

  cancel(): void {
    if (this.stopped) {
      return;
    }
    this.stopped = true;
    for (const listener of this.listeners) {
      listener();
    }
    this.listeners.clear();
  }

  /** Runs `listener` now when already cancelled, else when cancel() first runs; the returned
   *  function takes it back, so a waiter that ended another way does not linger. */
  onCancel(listener: () => void): () => void {
    if (this.stopped) {
      listener();
      return (): void => undefined;
    }
    this.listeners.add(listener);
    return (): void => {
      this.listeners.delete(listener);
    };
  }
}
