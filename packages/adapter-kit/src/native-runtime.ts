import type { AdapterContext, ComputerRef } from "./types.js";

/** Optional capability using the computer provider's existing trusted connection. */
export interface ComputerExecutionCapability {
  execution(
    computer: ComputerRef,
    context: AdapterContext,
    identity?: string,
  ): Promise<ComputerExecutionProvider | undefined>;
}

export function supportsComputerExecution(
  provider: unknown,
): provider is ComputerExecutionCapability {
  return (
    typeof provider === "object" &&
    provider !== null &&
    "execution" in provider &&
    typeof provider.execution === "function"
  );
}

/** An execution service owns processes; the application owns authorization and durable runs. */
export interface NativeExecutionScope {
  spaceId: string;
  userId: string;
  botId: string;
  threadId: string;
  computerId: string;
  profileId: string;
  revision: number;
}

export interface NativeEngineCapabilities {
  images: boolean;
  resume: boolean;
  steer: boolean;
  permissions: boolean;
  questions: boolean;
  tools: boolean;
}

export interface NativeSessionRef {
  id: string;
  engineVersion: string;
}

export type NativeInteraction = {
  id: string;
  kind: "permission" | "question";
  title: string;
  detail?: string;
  actions: Array<{ id: string; label: string }>;
};

export type NativeExecutionEvent =
  | { type: "text"; text: string }
  | { type: "session"; session: NativeSessionRef }
  | {
      type: "operation";
      id: string;
      name: string;
      status: "running" | "completed" | "failed";
      detail?: string;
    }
  | { type: "interaction"; request: NativeInteraction }
  | { type: "interaction_closed"; id: string; status: "delivered" | "expired" }
  | { type: "tool_requested"; id: string; name: string; input: Record<string, unknown> }
  | { type: "file"; name: string; content: string }
  | {
      type: "usage";
      scope?: "run" | "session";
      inputTokens: number | null;
      outputTokens: number | null;
      costUsd: number | null;
    }
  | { type: "completed" }
  | { type: "cancelled" }
  | { type: "failed"; code: string };

export interface NativeExecutionFrame {
  sequence: number;
  event: NativeExecutionEvent;
}

export interface NativeExecutionStart {
  runId: string;
  scope: NativeExecutionScope;
  fence: number;
  leaseExpiresAt: string;
  prompt: string;
  instructions: string;
  /** Visible context not yet included in the bound native session. */
  context?: Array<{ role: "user" | "assistant" | "system"; content: string }>;
  session?: NativeSessionRef;
  model?: string;
}

export interface NativeExecutionSnapshot {
  generation: string;
  state: "running" | "completed" | "cancelled" | "failed";
  capabilities: NativeEngineCapabilities;
  frames: NativeExecutionFrame[];
  nextSequence: number;
}

export interface NativeExecutionControl {
  runId: string;
  scope: NativeExecutionScope;
  fence: number;
  generation: string;
}

/** No executable paths, credentials, or engine names cross this boundary. */
export interface NativeExecutionProvider {
  stop?(
    request: { runId: string; scope: NativeExecutionScope; fence: number },
    signal?: AbortSignal,
  ): Promise<void>;
  toolResult?(
    request: NativeExecutionControl & { requestId: string; result: string },
    signal?: AbortSignal,
  ): Promise<"delivered" | "expired">;
  start(request: NativeExecutionStart, signal?: AbortSignal): Promise<NativeExecutionSnapshot>;
  attach(
    request: NativeExecutionControl & { after: number; leaseExpiresAt: string },
    signal?: AbortSignal,
  ): Promise<NativeExecutionSnapshot>;
  respond(
    request: NativeExecutionControl & { requestId: string; answer: string },
    signal?: AbortSignal,
  ): Promise<"delivered" | "expired">;
  cancel(request: NativeExecutionControl, signal?: AbortSignal): Promise<void>;
  steer(
    request: NativeExecutionControl & { id: string; text: string },
    signal?: AbortSignal,
  ): Promise<"accepted" | "unsupported">;
}

/** A computer provider owns the trusted connection; no service credentials leave the adapter. */
export interface ComputerExecutionProvider extends NativeExecutionProvider {
  stop: NonNullable<NativeExecutionProvider["stop"]>;
  toolResult: NonNullable<NativeExecutionProvider["toolResult"]>;
  describe(signal?: AbortSignal): Promise<{
    id: string;
    profiles: Array<{
      id: string;
      revision: number;
      label: string;
      spaceId: string;
      userIds: string[];
      computerId: string;
      engineVersion: string;
      defaultModel?: string;
      models?: Array<{ id: string; label: string }>;
      status:
        | "missing"
        | "unsupported"
        | "unauthenticated"
        | "unverified"
        | "unavailable"
        | "stopped"
        | "ready";
    }>;
  }>;
}
