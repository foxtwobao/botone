import type { ProductEvent } from "@rakazo/contracts";
import { MessageBlock } from "@rakazo/contracts";
import { truncatedPlainText } from "@rakazo/core";
import * as z from "zod";

const blocksSchema = z.array(MessageBlock);

export async function* peripheralStream(
  events: AsyncIterable<ProductEvent>,
  runId: string,
  summary?: { minChars: number; run: (text: string) => Promise<string | null> },
  steeringMessageSeq?: number,
) {
  let spoken = "";
  let buffered = "";
  for await (const { runId: eventRunId, type, payload } of events) {
    if (eventRunId !== runId) continue;
    if (steeringMessageSeq !== undefined) {
      if (
        type === "run.steering.claimed" &&
        typeof payload.nextMessageSeq === "number" &&
        payload.nextMessageSeq > steeringMessageSeq
      )
        steeringMessageSeq = undefined;
      else if (
        type !== "run.completed" &&
        type !== "run.failed" &&
        type !== "run.cancelled" &&
        type !== "run.waiting_input" &&
        type !== "computer.takeover.requested"
      )
        continue;
    }
    if (type === "agent.tool.called" && typeof payload.name === "string") {
      yield { event: "tool_activity", data: { name: payload.name, label: payload.name } };
    }
    if (type === "thread.progress" && payload.streaming === true && !payload.activity) {
      const chunk = payload.delta ?? payload.text;
      if (typeof chunk === "string") {
        if (typeof payload.text === "string") {
          spoken = "";
          buffered = "";
        }
        if (summary) buffered += chunk;
        else {
          spoken += chunk;
          yield { event: "text_delta", data: { text: chunk } };
        }
      }
    }
    if (type === "thread.message.created" && payload.role === "bot") {
      const blocks = blocksSchema.safeParse(payload.blocks);
      if (blocks.success) {
        if (
          blocks.data.some((block) => block.kind === "tool_question" && block.status === "pending")
        ) {
          yield { event: "done", data: { status: "run.waiting_input" } };
          return;
        }
        const reply = blocks.data
          .flatMap((block) => (block.kind === "text" ? [block.text] : []))
          .join("\n");
        if (reply && summary) {
          const text = truncatedPlainText(reply, 8_000);
          const short = text.length > summary.minChars ? await summary.run(text) : null;
          yield { event: "text_delta", data: { text: short ?? truncatedPlainText(text, 720) } };
          buffered = "";
        } else if (reply) {
          const prefix = spoken.trimStart();
          const unsent = prefix
            ? reply.startsWith(prefix)
              ? reply.slice(prefix.length)
              : ""
            : reply;
          if (unsent) yield { event: "text_delta", data: { text: unsent } };
          spoken = "";
        }
      }
    }
    if (type === "thread.call.ended" && typeof payload.callId === "string") {
      yield {
        event: "call_ended",
        data: {
          callId: payload.callId,
          farewell: typeof payload.farewell === "string" ? payload.farewell : "",
        },
      };
    }
    switch (type) {
      case "run.completed":
      case "run.cancelled":
      case "run.waiting_input":
      case "computer.takeover.requested":
        if (buffered && type !== "run.cancelled") {
          yield { event: "text_delta", data: { text: truncatedPlainText(buffered, 720) } };
        }
        yield { event: "done", data: { status: type } };
        return;
      case "run.failed": {
        const error =
          typeof payload.error === "string" &&
          /insufficient_quota|quota_exhausted|quota exceeded|insufficient balance/i.test(
            payload.error,
          )
            ? "quota_exhausted"
            : "run_failed";
        yield { event: "error", data: { error } };
        return;
      }
    }
  }
}
