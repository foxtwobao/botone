import { ORPCError } from "@orpc/server";
import { executeHostComputerTool } from "@rakazo/adapters/host-computer";
import {
  answerHostExecution,
  HostExecutionError,
  startHostExecution,
  syncHostExecution,
} from "@rakazo/adapters/host-execution";
import type { RouterContext } from "./context.js";

async function hostCall<T>(call: () => Promise<T>): Promise<T> {
  try {
    return await call();
  } catch (error) {
    if (error instanceof HostExecutionError)
      throw new ORPCError(error.code, { message: error.message });
    throw error;
  }
}

export function hostExecutionRoutes({ deps, authed }: RouterContext) {
  return {
    hostExecutions: {
      tool: authed.hostExecutions.tool.handler(({ context, input }) =>
        hostCall(() => executeHostComputerTool(deps, context, input)),
      ),
      start: authed.hostExecutions.start.handler(({ context, input }) =>
        hostCall(() => startHostExecution(deps, context, input)),
      ),
      sync: authed.hostExecutions.sync.handler(({ context, input }) =>
        hostCall(() => syncHostExecution(deps, context, input)),
      ),
      answer: authed.hostExecutions.answer.handler(({ context, input }) =>
        hostCall(() => answerHostExecution(deps, context, input)),
      ),
    },
  };
}
