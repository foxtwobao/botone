import type {
  NativeEngineCapabilities,
  NativeExecutionEvent,
  NativeExecutionStart,
} from "@rakazo/adapter-kit";

export interface HarnessProcess {
  workspace: string;
  /** A native tool-sandbox label used by a platform's descendant owner. */
  hostPermissions?: { id: string; directory: string; allow: string; deny: string };
  /** A host-owned tool boundary. Engines translate it; they never receive server credentials. */
  externalTools?: {
    permissions: string;
    specs: {
      name: string;
      label?: string;
      description: string;
      inputSchema: unknown;
      requiresApproval: boolean;
    }[];
    invoke(id: string, name: string, input: unknown): Promise<string>;
  };
  /** Omitted for a host process until an authorized platform tool bridge is mounted. */
  mcpServer?: { name: string; type: string; command: string; args: string[]; env: string[] };
  onTool?(
    listener: (request: { name: string; input: Record<string, unknown> }) => Promise<unknown>,
  ): void;
  /** UTF-8 decoded incrementally by the transport. */
  onLine(listener: (line: string) => void): void;
  onExit(listener: (code?: number | null) => void): void;
  /** A per-process permission broker, mounted only into this process's execution boundary. */
  onPermission?(
    listener: (request: {
      id: string;
      tool: string;
      input: Record<string, unknown>;
    }) => Promise<unknown>,
  ): void;
  write(frame: unknown): Promise<void>;
  /** Resolves only after the process and its descendants have exited. */
  stop(): Promise<void>;
}

export interface HarnessDriver {
  capabilities: NativeEngineCapabilities;
  start(request: NativeExecutionStart): Promise<void>;
  respond(id: string, answer: string): Promise<boolean>;
  cancel(): Promise<void>;
  steer(text: string): Promise<boolean>;
}

export type HarnessDriverFactory = (
  process: HarnessProcess,
  version: string,
  emit: (event: NativeExecutionEvent) => void,
) => HarnessDriver;

export const record = (value: unknown): Record<string, unknown> =>
  value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};

export const text = (value: unknown): string => (typeof value === "string" ? value : "");

export function initialPrompt(request: NativeExecutionStart) {
  return [
    request.session ? "" : request.instructions,
    request.context?.map((message) => `${message.role}: ${message.content}`).join("\n\n"),
    request.prompt,
  ]
    .filter(Boolean)
    .join("\n\n");
}
