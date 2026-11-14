// Adapted from OpenMausBot's codex.ts and codex-questions.ts. See NOTICE.md.
import type { NativeExecutionEvent } from "@rakazo/adapter-kit";
import { bridgeInputSchemas } from "./bridge-tools.js";
import type { HarnessDriverFactory } from "./driver.js";
import { initialPrompt, record, text } from "./driver.js";
import {
  assertHostConfiguration,
  assertLabeledHostConfiguration,
  assertRemoteHostConfiguration,
} from "./host-policy.js";
import { HarnessInteractions, permissionActions } from "./interactions.js";
import { HarnessProtocolError, HarnessRpc } from "./rpc.js";

export const createCodexDriver: HarnessDriverFactory = (process, version, emit) =>
  codexDriver(process, version, emit, false);

/** Host execution always requests the native sandbox; it never trusts external isolation. */
export const createHostCodexDriver: HarnessDriverFactory = (process, version, emit) =>
  codexDriver(process, version, emit, true);

function codexDriver(
  process: Parameters<HarnessDriverFactory>[0],
  version: string,
  emit: Parameters<HarnessDriverFactory>[2],
  host: boolean,
): ReturnType<HarnessDriverFactory> {
  const remote = host ? process.externalTools : undefined;
  const label = host ? process.hostPermissions : undefined;
  const permissions = label?.id ?? remote?.permissions;
  // An unsandboxed approval retry would discard the process owner's inherited label.
  const approvalPolicy = host && !remote && !label ? "on-request" : "never";
  let threadId = "";
  let turnId = "";
  let settled = false;
  let starting = false;
  const early: Record<string, unknown>[] = [];
  const preview = (value: string, limit: number) =>
    host && value.length > limit ? `${value.slice(0, limit - 1)}…` : value;
  const interactions = new HarnessInteractions((event) => {
    if (event.type !== "interaction") return emit(event);
    emit({
      ...event,
      request: {
        ...event.request,
        title: preview(event.request.title, 2000),
        ...(event.request.detail ? { detail: preview(event.request.detail, 16_000) } : {}),
      },
    });
  });
  const finish = (event: NativeExecutionEvent) => {
    if (settled) return;
    settled = true;
    interactions.close();
    emit(event);
  };
  let cancelling = false;
  const failed = () => {
    if (!cancelling) finish({ type: "failed", code: "engine_protocol_failed" });
  };

  const receive = async (message: Record<string, unknown>) => {
    const params = record(message.params);
    const method = text(message.method);
    const isRequest = typeof message.id === "string" || typeof message.id === "number";
    if (starting) {
      if (early.length >= 1024) throw new HarnessProtocolError("event_overflow");
      early.push(message);
      return;
    }
    if (isRequest) {
      const id = message.id as string | number;
      if (
        settled ||
        cancelling ||
        !threadId ||
        (params.threadId && params.threadId !== threadId) ||
        (params.turnId && turnId && params.turnId !== turnId)
      ) {
        await rpc.reject(id);
        return;
      }
      if (method === "mcpServer/elicitation/request") {
        const metadata = record(params._meta);
        const schema = record(params.requestedSchema);
        const tool = text(metadata.tool_name);
        const input = bridgeInputSchemas[tool as keyof typeof bridgeInputSchemas];
        if (
          params.serverName === "platform" &&
          params.mode === "form" &&
          metadata.codex_approval_kind === "mcp_tool_call" &&
          schema.type === "object" &&
          Object.keys(record(schema.properties)).length === 0 &&
          (!Array.isArray(schema.required) || schema.required.length === 0) &&
          input?.safeParse(metadata.tool_params).success
        ) {
          interactions.open(
            {
              kind: "permission",
              title: `Run ${tool}?`,
              detail: JSON.stringify(metadata.tool_params),
              actions: permissionActions,
            },
            (answer) =>
              rpc.reply(id, {
                action: answer === "allow" ? "accept" : "decline",
                ...(answer === "allow" ? { content: {} } : {}),
              }),
          );
          return;
        }
        // Credential forms and URL flows require a separate UI contract. Never auto-accept.
        await rpc.reply(id, { action: "decline" });
        return;
      }
      if (method === "item/tool/requestUserInput") {
        const questions = Array.isArray(params.questions) ? params.questions.map(record) : [];
        if (questions.length !== 1 || questions.some((q) => !text(q.id) || !text(q.question))) {
          await rpc.reject(id);
          return;
        }
        interactions.open(
          {
            kind: "question",
            title: questions.map((q) => text(q.question)).join("\n"),
            detail: questions.map((q) => `${text(q.id)}: ${text(q.question)}`).join("\n"),
            actions:
              questions.length === 1 && Array.isArray(questions[0]?.options)
                ? questions[0].options
                    .map(record)
                    .flatMap((o) =>
                      text(o.label) ? [{ id: text(o.label), label: text(o.label) }] : [],
                    )
                : [],
          },
          async (answer) => {
            await rpc.reply(id, { answers: { [text(questions[0]!.id)]: { answers: [answer] } } });
          },
        );
        return;
      }
      if (method === "item/tool/call" && remote) {
        const name = text(params.tool);
        const spec = remote.specs.find((tool) => tool.name === name);
        if (!spec || params.namespace || !text(params.callId)) {
          await rpc.reject(id);
          return;
        }
        const invoke = async (allowed: boolean) => {
          if (settled || cancelling) return;
          emit({
            type: "operation",
            id: text(params.callId),
            name: spec.label ?? name,
            status: "running",
          });
          let result = JSON.stringify({ error: "Permission denied" });
          if (allowed) {
            try {
              result = await remote.invoke(text(params.callId), name, params.arguments);
            } catch {
              result = JSON.stringify({
                error: "Computer operation interrupted; inspect its state before retrying",
              });
            }
          }
          if (settled || cancelling) return;
          emit({
            type: "operation",
            id: text(params.callId),
            name: spec.label ?? name,
            status: allowed ? "completed" : "failed",
          });
          await rpc.reply(id, {
            contentItems: [{ type: "inputText", text: result }],
            success: allowed,
          });
        };
        if (spec.requiresApproval)
          interactions.open(
            {
              kind: "permission",
              title: `${spec.label ?? name}?`,
              detail: JSON.stringify(params.arguments),
              actions: permissionActions,
            },
            (answer) => invoke(answer === "allow"),
          );
        else await invoke(true);
        return;
      }
      const legacy = method === "execCommandApproval" || method === "applyPatchApproval";
      const permission =
        legacy ||
        ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"].includes(
          method,
        );
      if ((remote || label) && permission) {
        await rpc.reply(id, { decision: legacy ? "denied" : "decline" });
        return;
      }
      if (!permission) {
        // Additional permission profiles cannot be represented by a command/file approval.
        if (method === "item/permissions/requestApproval")
          await rpc.reply(id, { permissions: {}, scope: "turn" });
        else await rpc.reject(id);
        return;
      }
      interactions.open(
        {
          kind: "permission",
          title: text(params.command) || text(params.reason) || "Review operation",
          detail: JSON.stringify(params),
          actions: permissionActions,
        },
        (answer) =>
          rpc.reply(id, {
            decision:
              answer === "allow" ? (legacy ? "approved" : "accept") : legacy ? "denied" : "decline",
          }),
      );
      return;
    }
    if (settled || !threadId || params.threadId !== threadId) return;
    if (params.turnId && params.turnId !== turnId) return;
    if (method === "thread/tokenUsage/updated") {
      const usage = record(record(params.tokenUsage).total);
      const count = (value: unknown) =>
        typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : null;
      emit({
        type: "usage",
        scope: "session",
        inputTokens: count(usage.inputTokens),
        outputTokens: count(usage.outputTokens),
        costUsd: null,
      });
    } else if (method === "item/agentMessage/delta")
      emit({ type: "text", text: text(params.delta) });
    else if (method === "item/started" || method === "item/completed") {
      const item = record(params.item);
      if (["commandExecution", "fileChange", "mcpToolCall"].includes(text(item.type)))
        emit({
          type: "operation",
          id: text(item.id),
          name: text(item.type),
          status:
            method === "item/started"
              ? "running"
              : item.status === "failed"
                ? "failed"
                : "completed",
          detail: text(item.command) || undefined,
        });
    } else if (method === "turn/completed") {
      const turn = record(params.turn);
      if (turn.id !== turnId) return;
      finish(
        turn.status === "completed"
          ? { type: "completed" }
          : turn.status === "interrupted"
            ? { type: "cancelled" }
            : { type: "failed", code: "engine_turn_failed" },
      );
    } else if (method === "error" && params.willRetry !== true) failed();
  };
  const rpc = new HarnessRpc(process, receive, failed);

  return {
    capabilities: {
      images: false,
      resume: true,
      steer: true,
      permissions: true,
      questions: true,
      tools: false,
    },
    async start(request) {
      await rpc.request("initialize", {
        clientInfo: { name: "rakazo", version: "1" },
        capabilities: { experimentalApi: true },
      });
      await rpc.notify("initialized", {});
      if (host) {
        const effective = record(
          await rpc.request("config/read", { cwd: process.workspace, includeLayers: false }),
        );
        if (remote) assertRemoteHostConfiguration(effective.config, remote.permissions, label);
        else if (label) assertLabeledHostConfiguration(effective.config, label, false);
        else assertHostConfiguration(effective.config);
      }
      const params = {
        developerInstructions: request.instructions,
        cwd: process.workspace,
        approvalPolicy,
        ...(permissions ? { permissions, environments: [] } : {}),
        ...(remote
          ? {
              ...(!request.session
                ? {
                    dynamicTools: remote.specs.map(
                      ({ requiresApproval: _approval, label: _label, ...tool }) => ({
                        type: "function",
                        ...tool,
                      }),
                    ),
                  }
                : {}),
            }
          : permissions
            ? {}
            : { sandbox: "workspace-write" }),
        ...(host
          ? {
              approvalsReviewer: "user",
              config: {
                sandbox_workspace_write: {
                  writable_roots: [process.workspace],
                  network_access: false,
                  exclude_tmpdir_env_var: true,
                  exclude_slash_tmp: true,
                },
              },
            }
          : {}),
        ...(request.model ? { model: request.model } : {}),
      };
      const result = record(
        await rpc.request(request.session ? "thread/resume" : "thread/start", {
          ...params,
          ...(request.session ? { threadId: request.session.id } : { ephemeral: false }),
        }),
      );
      threadId = text(record(result.thread).id);
      if (!threadId) throw new HarnessProtocolError("missing_session");
      if (host) {
        const sandbox = record(result.sandbox);
        if (permissions) {
          if (
            result.cwd !== process.workspace ||
            result.approvalPolicy !== "never" ||
            result.approvalsReviewer !== "user" ||
            record(result.activePermissionProfile).id !== permissions ||
            sandbox.networkAccess !== false ||
            sandbox.type !== "readOnly"
          )
            throw new HarnessProtocolError(
              remote ? "host_remote_boundary_not_confirmed" : "host_sandbox_not_confirmed",
            );
        } else {
          if (
            result.cwd !== process.workspace ||
            result.approvalPolicy !== "on-request" ||
            result.approvalsReviewer !== "user" ||
            sandbox.type !== "workspaceWrite" ||
            sandbox.networkAccess !== false ||
            sandbox.excludeTmpdirEnvVar !== true ||
            sandbox.excludeSlashTmp !== true ||
            !Array.isArray(sandbox.writableRoots) ||
            sandbox.writableRoots.some((root) => root !== process.workspace)
          )
            throw new HarnessProtocolError("host_sandbox_not_confirmed");
        }
      }
      if (request.session && threadId !== request.session.id)
        throw new HarnessProtocolError("session_mismatch");
      emit({ type: "session", session: { id: threadId, engineVersion: version } });
      starting = true;
      const started = record(
        await rpc.request("turn/start", {
          threadId,
          // Reapply on every turn, including sessions created with an older approval policy.
          approvalPolicy,
          ...(host ? { approvalsReviewer: "user" } : {}),
          ...(permissions
            ? { permissions, environments: [] }
            : {
                sandboxPolicy: host
                  ? {
                      type: "workspaceWrite",
                      writableRoots: [process.workspace],
                      networkAccess: false,
                      excludeTmpdirEnvVar: true,
                      excludeSlashTmp: true,
                    }
                  : {
                      // The selected computer already isolates filesystem, processes, and network.
                      type: "externalSandbox",
                      networkAccess: "enabled",
                    },
              }),
          input: [{ type: "text", text: initialPrompt({ ...request, instructions: "" }) }],
        }),
      );
      turnId = text(record(started.turn).id);
      if (!turnId) throw new HarnessProtocolError("missing_turn");
      starting = false;
      for (const message of early.splice(0)) await receive(message);
    },
    respond: (id, answer) => interactions.respond(id, answer),
    async cancel() {
      cancelling = true;
      if (!settled && threadId && turnId) {
        await rpc.request("turn/interrupt", { threadId, turnId }, 5_000).catch(() => undefined);
      }
      await process.stop();
      finish({ type: "cancelled" });
    },
    async steer(value) {
      if (settled || !turnId) return false;
      await rpc.request(
        "turn/steer",
        { threadId, expectedTurnId: turnId, input: [{ type: "text", text: value }] },
        10_000,
      );
      return true;
    },
  };
}
