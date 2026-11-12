// Adapted from OpenMausBot's codex.ts and codex-questions.ts. See NOTICE.md.
import type { NativeExecutionEvent } from "@rakazo/adapter-kit";
import { bridgeInputSchemas } from "./bridge-tools.js";
import type { HarnessDriverFactory } from "./driver.js";
import { initialPrompt, record, text } from "./driver.js";
import { HarnessInteractions, permissionActions } from "./interactions.js";
import { HarnessProtocolError, HarnessRpc } from "./rpc.js";

export const createCodexDriver: HarnessDriverFactory = (process, version, emit) => {
  let threadId = "";
  let turnId = "";
  let settled = false;
  let starting = false;
  const early: Record<string, unknown>[] = [];
  const interactions = new HarnessInteractions(emit);
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
      const legacy = method === "execCommandApproval" || method === "applyPatchApproval";
      const permission =
        legacy ||
        ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"].includes(
          method,
        );
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
      const params = {
        developerInstructions: request.instructions,
        cwd: process.workspace,
        approvalPolicy: "never",
        sandbox: "workspace-write",
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
      if (request.session && threadId !== request.session.id)
        throw new HarnessProtocolError("session_mismatch");
      emit({ type: "session", session: { id: threadId, engineVersion: version } });
      starting = true;
      const started = record(
        await rpc.request("turn/start", {
          threadId,
          // Reapply on every turn, including sessions created with an older approval policy.
          approvalPolicy: "never",
          sandboxPolicy: {
            // The selected computer already isolates filesystem, processes, and network.
            type: "externalSandbox",
            networkAccess: "enabled",
          },
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
};
