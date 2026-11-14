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
    tool: authed.executions.host.tool.handler(({ context, input }) =>
      hostCall(() => executeHostComputerTool(deps, context, input)),
    ),
    start: authed.executions.host.start.handler(({ context, input }) =>
      hostCall(() => startHostExecution(deps, context, input)),
    ),
    sync: authed.executions.host.sync.handler(({ context, input }) =>
      hostCall(() => syncHostExecution(deps, context, input)),
    ),
    answer: authed.executions.host.answer.handler(({ context, input }) =>
      hostCall(() => answerHostExecution(deps, context, input)),
    ),
  };
}
