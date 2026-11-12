import { randomUUID } from "node:crypto";
import type { NativeExecutionEvent, NativeInteraction } from "@rakazo/adapter-kit";

export class HarnessInteractions {
  private readonly pending = new Map<
    string,
    { respond: (answer: string) => Promise<void>; choices?: Set<string> }
  >();
  private readonly delivered = new Map<string, string>();

  constructor(private readonly emit: (event: NativeExecutionEvent) => void) {}

  open(
    input: Omit<NativeInteraction, "id">,
    respond: (answer: string) => Promise<void>,
    id: string = randomUUID(),
  ) {
    if (this.pending.has(id) || this.delivered.has(id)) throw new Error("duplicate_request");
    this.pending.set(id, {
      respond,
      ...(input.kind === "permission" ? { choices: new Set(input.actions.map((a) => a.id)) } : {}),
    });
    this.emit({ type: "interaction", request: { ...input, id } });
    return id;
  }

  async respond(id: string, answer: string) {
    if (this.delivered.has(id)) return this.delivered.get(id) === answer;
    const pending = this.pending.get(id);
    if (!pending || (pending.choices && !pending.choices.has(answer))) return false;
    // Remove before awaiting: concurrent answers cannot authorize the same request twice.
    this.pending.delete(id);
    try {
      await pending.respond(answer);
      this.delivered.set(id, answer);
      this.emit({ type: "interaction_closed", id, status: "delivered" });
      return true;
    } catch (error) {
      this.emit({ type: "interaction_closed", id, status: "expired" });
      throw error;
    }
  }

  expire(id: string) {
    if (this.pending.delete(id)) this.emit({ type: "interaction_closed", id, status: "expired" });
  }

  close() {
    for (const id of this.pending.keys()) this.expire(id);
  }
}

export const permissionActions = [
  { id: "allow", label: "Allow once" },
  { id: "deny", label: "Deny" },
];
