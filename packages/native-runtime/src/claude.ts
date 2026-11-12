// Adapted from OpenMausBot claude.ts, claude-elicitation.ts and permission-proxy.ts. See NOTICE.md.
import type { NativeExecutionEvent } from "@rakazo/adapter-kit";
import type { HarnessDriverFactory } from "./driver.js";
import { initialPrompt, record, text } from "./driver.js";
import { HarnessInteractions, permissionActions } from "./interactions.js";
import { HarnessProtocolError } from "./rpc.js";

export const createClaudeDriver: HarnessDriverFactory = (process, version, emit) => {
  let settled = false;
  let cancelling = false;
  let sessionId = "";
  let sessionAnnounced = false;
  let streamed = false;
  const interactions = new HarnessInteractions(emit);
  const finish = (event: NativeExecutionEvent) => {
    if (settled) return;
    settled = true;
    interactions.close();
    emit(event);
  };
  const controlReply = (id: string, response: unknown) =>
    process.write({
      type: "control_response",
      response: { subtype: "success", request_id: id, response },
    });
  process.onExit(() => {
    if (!cancelling) finish({ type: "failed", code: "engine_process_lost" });
  });
  process.onPermission?.(
    (request) =>
      new Promise((resolve) => {
        if (settled || cancelling) return resolve({ behavior: "deny", message: "Request expired" });
        const questions =
          request.tool === "AskUserQuestion" && Array.isArray(request.input.questions)
            ? request.input.questions.map(record)
            : [];
        const question = questions.length > 0;
        if (
          request.tool === "AskUserQuestion" &&
          (questions.length !== 1 || !text(questions[0]?.question))
        )
          return resolve({
            behavior: "deny",
            message: "Only single-question prompts are supported",
          });
        interactions.open(
          {
            kind: question ? "question" : "permission",
            title: question ? questions.map((q) => text(q.question)).join("\n") : request.tool,
            detail: JSON.stringify(request.input),
            actions: question ? [] : permissionActions,
          },
          async (answer) => {
            if (question) {
              const answers = { [text(questions[0]!.question)]: answer };
              resolve({ behavior: "allow", updatedInput: { ...request.input, answers } });
            } else {
              resolve(
                answer === "allow"
                  ? { behavior: "allow", updatedInput: request.input }
                  : { behavior: "deny", message: "Denied by the user" },
              );
            }
          },
          request.id,
        );
      }),
  );
  process.onLine((line) => {
    void (async () => {
      const message = record(JSON.parse(line));
      if (settled) return;
      const id = text(message.request_id);
      if (message.type === "control_cancel_request") {
        interactions.expire(`elicitation:${id}`);
        return;
      }
      if (message.type === "control_request") {
        const request = record(message.request);
        if (!id) throw new HarnessProtocolError("invalid_control_request");
        if (request.subtype !== "elicitation") {
          await process.write({
            type: "control_response",
            response: { subtype: "error", request_id: id, error: "Unsupported request" },
          });
          return;
        }
        const schema = record(request.requested_schema);
        if (
          request.mode === "url" ||
          Object.keys(record(schema.properties)).length ||
          (Array.isArray(schema.required) && schema.required.length)
        ) {
          await controlReply(id, { action: "decline" });
          return;
        }
        interactions.open(
          {
            kind: "permission",
            title: text(request.message) || "Continue?",
            actions: permissionActions,
          },
          (answer) =>
            controlReply(
              id,
              answer === "allow" ? { action: "accept", content: {} } : { action: "decline" },
            ),
          `elicitation:${id}`,
        );
        return;
      }
      const nativeSession = text(message.session_id);
      if (nativeSession) {
        if (sessionId && nativeSession !== sessionId)
          throw new HarnessProtocolError("session_changed");
        sessionId = nativeSession;
        if (!sessionAnnounced) {
          sessionAnnounced = true;
          emit({ type: "session", session: { id: sessionId, engineVersion: version } });
        }
      }
      if (message.type === "stream_event") {
        const event = record(message.event);
        if (event.type === "content_block_delta") {
          const delta = record(event.delta);
          if (delta.type === "text_delta") {
            streamed = true;
            emit({ type: "text", text: text(delta.text) });
          }
        } else if (event.type === "content_block_start") {
          const block = record(event.content_block);
          if (block.type === "tool_use")
            emit({
              type: "operation",
              id: text(block.id),
              name: text(block.name),
              status: "running",
            });
        }
      } else if (message.type === "assistant" && !streamed) {
        const content = record(message.message).content;
        if (Array.isArray(content))
          for (const block of content.map(record)) {
            if (block.type === "text") emit({ type: "text", text: text(block.text) });
          }
      } else if (message.type === "result") {
        const usage = record(message.usage);
        emit({
          type: "usage",
          inputTokens: typeof usage.input_tokens === "number" ? usage.input_tokens : null,
          outputTokens: typeof usage.output_tokens === "number" ? usage.output_tokens : null,
          // A zero CLI estimate does not establish that an external account call was free.
          costUsd:
            typeof message.total_cost_usd === "number" && message.total_cost_usd > 0
              ? message.total_cost_usd
              : null,
        });
        finish(
          message.is_error === true || message.subtype !== "success"
            ? { type: "failed", code: "engine_turn_failed" }
            : { type: "completed" },
        );
      }
    })().catch(() => finish({ type: "failed", code: "engine_protocol_failed" }));
  });

  return {
    capabilities: {
      images: false,
      resume: true,
      steer: false,
      permissions: true,
      questions: true,
      tools: false,
    },
    async start(request) {
      if (!process.onPermission) throw new HarnessProtocolError("permission_broker_required");
      sessionId = request.session?.id ?? "";
      await process.write({
        type: "user",
        message: { role: "user", content: initialPrompt(request) },
        ...(sessionId ? { session_id: sessionId } : {}),
      });
    },
    respond: (id, answer) => interactions.respond(id, answer),
    async cancel() {
      cancelling = true;
      interactions.close();
      await process
        .write({ type: "control_request", request_id: "stop", request: { subtype: "interrupt" } })
        .catch(() => undefined);
      await process.stop();
      finish({ type: "cancelled" });
    },
    async steer() {
      return false;
    },
  };
};
