import type { ArtifactStore, ConnectorProvider } from "@rakazo/adapter-kit";
import type { Actor } from "@rakazo/contracts";
import type { PrismaClient, ThreadEvents } from "@rakazo/db";
import { runAsTenant } from "@rakazo/db";
import { getLogger } from "@rakazo/logging";
import { ApplicationProxyConnector, handleApplicationRequest } from "./application-proxy.js";

/** Server-only user credentials; tokens never enter tools or durable operation records. */
export interface UserAccessCredential {
  accountId: string;
  binding: string;
  /** Obtain a current decrypted token only when making an external request. */
  accessToken(): Promise<string>;
  /** Refresh through the existing user account flow, retaining the same verified binding. */
  refreshAccessToken?: () => Promise<string>;
}

export interface ApplicationServices {
  prisma: PrismaClient;
  artifacts: ArtifactStore;
  events: ThreadEvents;
  maxUploadSizeBytes?: number;
  env: Record<string, string | undefined>;
  /** Only the API host supplies credentials; workers forward calls without loading app code. */
  credentials?: (userId: string) => Promise<UserAccessCredential | null>;
  /** Reuse the host connection actions' lock scope without owning their implementation. */
  providerScopeKey?: (
    owner: Pick<Actor, "spaceId" | "userId">,
    connectorId: string,
    provider: string,
  ) => string;
}

export interface ConnectedApplication {
  connector: ConnectorProvider;
  start(): void;
  initialize?(actor: Actor): Promise<unknown>;
  stop(): Promise<void>;
}

export class ApplicationCredentialError extends Error {
  constructor(
    readonly code: "authentication_required" | "authentication_unavailable" | "account_changed",
    readonly status: number,
  ) {
    super(`Application credential: ${code}`);
  }
}

// Trusted, built-in adapters only. Configuration cannot name executable modules.
const adapters = {
  creative: () => import("./creative-application.js"),
};

/** Shared API/worker entry point; app-specific lifecycle and credentials stay in adapters. */
export async function loadConfiguredApps(
  services: ApplicationServices | Pick<ApplicationServices, "env">,
) {
  const host = "credentials" in services && services.credentials ? services : undefined;
  let config: Record<string, unknown>;
  try {
    const parsed: unknown = JSON.parse(services.env.APP_CONNECTIONS || "{}");
    if (
      !parsed ||
      typeof parsed !== "object" ||
      Array.isArray(parsed) ||
      Object.keys(parsed).some((id) => !Object.hasOwn(adapters, id))
    )
      throw new Error();
    config = parsed as Record<string, unknown>;
  } catch {
    throw new Error("Invalid APP_CONNECTIONS configuration");
  }
  const apps: ConnectedApplication[] = [];
  for (const [id, options] of Object.entries(config)) {
    if (!host) {
      const connector = new ApplicationProxyConnector(id, services.env);
      apps.push({
        connector,
        start() {},
        async stop() {
          connector.close();
        },
      });
      continue;
    }
    const adapter = await adapters[id as keyof typeof adapters]();
    try {
      apps.push(adapter.createApplication(options, host));
    } catch {
      throw new Error("Invalid APP_CONNECTIONS configuration");
    }
  }
  const pending = new Set<Promise<unknown>>();
  let stopping = false;
  return {
    connectors: apps.map((app) => app.connector),
    handle(request: Request, id: string) {
      return host
        ? handleApplicationRequest(host, apps, request, id)
        : new Response(null, { status: 404 });
    },
    start() {
      for (const app of apps) app.start();
    },
    initialize(actor: Actor) {
      if (stopping) return;
      for (const app of apps) {
        if (!app.initialize) continue;
        const task = runAsTenant(actor, () => app.initialize!(actor)).catch(() =>
          getLogger().warn("Personal app connection unavailable"),
        );
        pending.add(task);
        void task.then(() => pending.delete(task));
      }
    },
    async stop() {
      stopping = true;
      await Promise.allSettled(pending);
      await Promise.all(apps.map((app) => app.stop()));
    },
  };
}
