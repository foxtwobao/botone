// Derived from OpenMausBot server/drivers/acp/host.ts; see NOTICE.md in this directory.
import type { HarnessProcess } from "./driver.js";
import { record } from "./driver.js";

export class HarnessProtocolError extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}

/** One process, one session. Responses and server requests occupy separate ID spaces. */
export class HarnessRpc {
  private nextId = 0;
  private closed = false;
  private readonly pending = new Map<
    number,
    { resolve(value: unknown): void; reject(error: Error): void; timer?: NodeJS.Timeout }
  >();

  constructor(
    readonly process: HarnessProcess,
    receive: (message: Record<string, unknown>) => void | Promise<void>,
    failed: (error: Error) => void,
  ) {
    process.onExit(() => {
      this.close();
      failed(new HarnessProtocolError("process_lost"));
    });
    process.onLine((line) => {
      try {
        const message = record(JSON.parse(line));
        if (!Object.keys(message).length) throw new HarnessProtocolError("invalid_frame");
        if (typeof message.id === "number" && !message.method) {
          const waiter = this.pending.get(message.id);
          if (!waiter) return;
          this.pending.delete(message.id);
          clearTimeout(waiter.timer);
          if (message.error !== undefined) waiter.reject(new HarnessProtocolError("rpc_rejected"));
          else if (Object.hasOwn(message, "result")) waiter.resolve(message.result);
          else waiter.reject(new HarnessProtocolError("invalid_response"));
          return;
        }
        void Promise.resolve(receive(message)).catch((error) => {
          this.close();
          failed(error instanceof Error ? error : new HarnessProtocolError("protocol_failed"));
        });
      } catch {
        this.close();
        failed(new HarnessProtocolError("invalid_frame"));
      }
    });
  }

  async request(method: string, params: unknown, timeoutMs = 30_000): Promise<unknown> {
    if (this.closed) throw new HarnessProtocolError("process_lost");
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      const timer = timeoutMs
        ? setTimeout(() => {
            this.pending.delete(id);
            reject(new HarnessProtocolError("rpc_timeout"));
          }, timeoutMs)
        : undefined;
      timer?.unref();
      this.pending.set(id, { resolve, reject, timer });
      void this.process.write({ jsonrpc: "2.0", id, method, params }).catch(() => {
        this.pending.delete(id);
        clearTimeout(timer);
        reject(new HarnessProtocolError("write_failed"));
      });
    });
  }

  notify(method: string, params?: unknown) {
    return this.process.write({
      jsonrpc: "2.0",
      method,
      ...(params === undefined ? {} : { params }),
    });
  }

  reply(id: string | number, result: unknown) {
    return this.process.write({ jsonrpc: "2.0", id, result });
  }

  reject(id: string | number) {
    return this.process.write({
      jsonrpc: "2.0",
      id,
      error: { code: -32601, message: "Unsupported request" },
    });
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    for (const waiter of this.pending.values()) {
      clearTimeout(waiter.timer);
      waiter.reject(new HarnessProtocolError("process_lost"));
    }
    this.pending.clear();
  }
}
