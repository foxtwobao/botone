// Adapted from OpenMausBot's ACP core, host and turn-state. See NOTICE.md.
import type { NativeExecutionEvent } from "@rakazo/adapter-kit";
import { acpModelOption } from "./acp-config.js";
import { platformMcpServer } from "./bridge-tools.js";
import type { HarnessDriverFactory } from "./driver.js";
import { initialPrompt, record, text } from "./driver.js";
import { HarnessInteractions, permissionActions } from "./interactions.js";
import { HarnessProtocolError, HarnessRpc } from "./rpc.js";

export function acpDriver(options: {
  resumeMethod: "session/load" | "session/resume";
  modelValue(model: string): string;
}): HarnessDriverFactory {
  return (process, version, emit) => {
    let sessionId = "";
    let prompting = false;
    let settled = false;
    let cancelling = false;
    const interactions = new HarnessInteractions(emit);
    const finish = (event: NativeExecutionEvent) => {
      if (settled) return;
      settled = true;
      interactions.close();
      emit(event);
    };
    const rpc = new HarnessRpc(
      process,
      async (message) => {
        const params = record(message.params);
        const isRequest = typeof message.id === "string" || typeof message.id === "number";
        if (isRequest) {
          const id = message.id as string | number;
          if (message.method !== "session/request_permission") return rpc.reject(id);
          const cancelled = { outcome: { outcome: "cancelled" } };
          if (!prompting || settled || params.sessionId !== sessionId)
            return rpc.reply(id, cancelled);
          const options = Array.isArray(params.options) ? params.options.map(record) : [];
          // Never substitute allow_always for a once-only approval.
          const allow = options.find((o) => o.kind === "allow_once" && text(o.optionId));
          const deny = options.find((o) => o.kind === "reject_once" && text(o.optionId));
          if (!allow) return rpc.reply(id, cancelled);
          const tool = record(params.toolCall);
          interactions.open(
            {
              kind: "permission",
              title: text(tool.title) || "Review operation",
              detail: JSON.stringify(tool),
              actions: permissionActions,
            },
            (answer) => {
              const selected = answer === "allow" ? allow : deny;
              return rpc.reply(
                id,
                selected
                  ? { outcome: { outcome: "selected", optionId: selected.optionId } }
                  : cancelled,
              );
            },
          );
          return;
        }
        // session/load and session/resume can replay old updates before returning.
        if (
          !prompting ||
          settled ||
          params.sessionId !== sessionId ||
          message.method !== "session/update"
        )
          return;
        const update = record(params.update);
        if (update.sessionUpdate === "agent_message_chunk") {
          const content = record(update.content);
          if (content.type === "text") emit({ type: "text", text: text(content.text) });
        } else if (
          update.sessionUpdate === "tool_call" ||
          update.sessionUpdate === "tool_call_update"
        ) {
          const status = text(update.status) || "pending";
          emit({
            type: "operation",
            id: text(update.toolCallId),
            name: text(update.title) || "operation",
            status:
              status === "completed" ? "completed" : status === "failed" ? "failed" : "running",
          });
        }
      },
      () => {
        if (!cancelling) finish({ type: "failed", code: "engine_protocol_failed" });
      },
    );

    return {
      capabilities: {
        images: false,
        resume: true,
        steer: false,
        permissions: true,
        questions: false,
        tools: false,
      },
      async start(request) {
        const initialized = record(
          await rpc.request("initialize", {
            protocolVersion: 1,
            clientCapabilities: {
              fs: { readTextFile: false, writeTextFile: false },
              terminal: false,
            },
            clientInfo: { name: "rakazo", version: "1" },
          }),
        );
        if (initialized.protocolVersion !== 1)
          throw new HarnessProtocolError("unsupported_protocol");
        // Native credentials are preinstalled in this isolated profile. No implicit login flow.
        if (Array.isArray(initialized.authMethods) && initialized.authMethods.length)
          throw new HarnessProtocolError("authentication_required");
        const result = record(
          await rpc.request(
            request.session ? options.resumeMethod : "session/new",
            {
              cwd: "/workspace",
              mcpServers: [platformMcpServer],
              ...(request.session ? { sessionId: request.session.id } : {}),
            },
            60_000,
          ),
        );
        sessionId = text(result.sessionId) || request.session?.id || "";
        if (!sessionId) throw new HarnessProtocolError("missing_session");
        if (request.session && sessionId !== request.session.id)
          throw new HarnessProtocolError("session_mismatch");
        if (request.model) {
          const model = options.modelValue(request.model);
          const selection = acpModelOption(result);
          if (!selection?.values.has(model)) throw new HarnessProtocolError("model_unavailable");
          const selected = await rpc.request("session/set_config_option", {
            sessionId,
            configId: selection.id,
            value: model,
          });
          if (acpModelOption(selected)?.current !== model)
            throw new HarnessProtocolError("model_not_confirmed");
        }
        emit({ type: "session", session: { id: sessionId, engineVersion: version } });
        prompting = true;
        // Only the response completes a turn; a tool/text update never does.
        void rpc
          .request(
            "session/prompt",
            { sessionId, prompt: [{ type: "text", text: initialPrompt(request) }] },
            0,
          )
          .then(
            (raw) => {
              const result = record(raw);
              if (cancelling || result.stopReason === "cancelled") finish({ type: "cancelled" });
              else if (result.stopReason === "end_turn") finish({ type: "completed" });
              else finish({ type: "failed", code: "engine_turn_incomplete" });
            },
            () => {
              if (!cancelling) finish({ type: "failed", code: "engine_turn_failed" });
            },
          );
      },
      respond: (id, answer) => interactions.respond(id, answer),
      async cancel() {
        cancelling = true;
        interactions.close();
        if (sessionId) await rpc.notify("session/cancel", { sessionId }).catch(() => undefined);
        await process.stop();
        finish({ type: "cancelled" });
      },
      async steer() {
        return false;
      },
    };
  };
}
