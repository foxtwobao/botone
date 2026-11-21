// A screen's hold on the one roster stream (design §5.4 "open while any screen holds it, foreground
// only"). A page starts it in aboutToAppear and stops it in aboutToDisappear; while the page is
// shown the hold follows the foreground, so going to background releases the stream and returning
// reopens it (which catches up via the opening roster signal). Holder counting lives in holdRoster.
import { foreground } from './foreground';
import { holdRoster } from './roster';

export class RosterHolder {
  private release: (() => void) | null = null;
  private offForeground: (() => void) | null = null;

  start(): void {
    if (this.offForeground !== null) {
      return;
    }
    this.offForeground = foreground.subscribe((isForeground: boolean): void => {
      this.sync(isForeground);
    });
    this.sync(foreground.foreground);
  }

  stop(): void {
    this.offForeground?.();
    this.offForeground = null;
    this.release?.();
    this.release = null;
  }

  private sync(isForeground: boolean): void {
    if (isForeground && this.release === null) {
      this.release = holdRoster();
    } else if (!isForeground && this.release !== null) {
      this.release();
      this.release = null;
    }
  }
}
