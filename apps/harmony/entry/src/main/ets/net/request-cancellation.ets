import { RpcError } from './errors';

export class RequestCancelled extends RpcError {
  constructor() {
    super('REQUEST_CANCELLED');
  }
}

/** One active transfer per send attempt; cancellation also fences work between transfers. */
export class RequestCancellation {
  private cancelled: boolean = false;
  private abort: (() => void) | null = null;

  check(): void {
    if (this.cancelled) {
      throw new RequestCancelled();
    }
  }

  listen(abort: (() => void) | null): void {
    this.abort = abort;
  }

  cancel(): void {
    this.cancelled = true;
    this.abort?.();
  }
}
