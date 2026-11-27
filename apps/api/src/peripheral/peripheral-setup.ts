import type { Hono } from "hono";
import { createSpeechSummarizer } from "../calls/speech-summary.js";
import { answerComputerRequest } from "../computers/computer-control.js";
import type { RouterDeps } from "../router.js";
import { mountPeripheralRoutes } from "./peripheral-routes.js";

type BridgeOptions = Pick<Parameters<typeof mountPeripheralRoutes>[2], "issuer" | "connection"> &
  Omit<Parameters<typeof createSpeechSummarizer>[0], "prisma">;

export function loadPeripheralBridge(source: NodeJS.ProcessEnv) {
  const bridgeSecret = source.PERIPHERAL_BRIDGE_SECRET?.trim();
  if (!bridgeSecret) return undefined;
  if (bridgeSecret.length < 32)
    throw new Error("PERIPHERAL_BRIDGE_SECRET must be at least 32 characters");

  return {
    mount(
      app: Hono,
      deps: RouterDeps,
      { issuer, connection, runtime, resolveModel }: BridgeOptions,
    ) {
      mountPeripheralRoutes(
        app,
        {
          prisma: deps.prisma,
          auth: deps.auth,
          events: deps.events,
          jobs: deps.jobs,
          sandbox: deps.sandbox,
          secrets: deps.secrets,
          notifications: deps.notifications,
          answerTakeover: (actor, botId, reason, runId) =>
            answerComputerRequest(deps, actor, botId, reason, runId),
        },
        {
          bridgeSecret,
          issuer,
          connection,
          speechSummary: deps.speechSummary ?? {
            minChars: 240,
            summarize: createSpeechSummarizer({ prisma: deps.prisma, runtime, resolveModel }),
          },
        },
      );
    },
  };
}
