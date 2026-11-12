import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import path from "node:path";
import type { z } from "zod";
import { readBodyCapped } from "../web-ssrf.js";
import type { daemonConfigurationSchema } from "./configuration.js";
import { engineVersions } from "./configuration.js";
import type { ExecutionServiceProfile } from "./http-client.js";
import { managedEnvironmentSchema } from "./managed-configuration.js";
import { verificationChecks } from "./verification.js";

type Configuration = z.infer<typeof daemonConfigurationSchema>;
export type ComputerProfile = Configuration["profiles"][number];
export type ExecutionOwner = { spaceId: string; userId: string; computerId: string };
const engines = [
  { engine: "codex", label: "Codex", protocol: "responses" },
  { engine: "claude", label: "Claude Code", protocol: "anthropic-messages" },
  { engine: "deepseek", label: "DSH", protocol: "chat-completions" },
] as const;

export class ExecutionEnvironmentError extends Error {
  constructor(readonly status: number) {
    super("execution_environment_unavailable");
  }
}

async function post(url: URL | string, token: string, body: unknown) {
  const signal = AbortSignal.timeout(5000);
  const response = await fetch(url, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify(body),
    redirect: "error",
    signal,
  });
  if (!response.ok) {
    await response.body?.cancel();
    throw new ExecutionEnvironmentError(response.status);
  }
  return JSON.parse(
    Buffer.from(await readBodyCapped(response, 256 * 1024, signal)).toString("utf8"),
  );
}

export async function managedComputerProfiles(
  configuration: Configuration,
  scope: ExecutionOwner,
): Promise<ComputerProfile[]> {
  const owner = { spaceId: scope.spaceId, userId: scope.userId, computerId: scope.computerId };
  if (!configuration.managed) return [];
  const environment = managedEnvironmentSchema.parse(
    await post(
      new URL("/api/model-account/environment", configuration.managed.apiUrl),
      configuration.token,
      owner,
    ),
  );
  if (
    environment.spaceId !== owner.spaceId ||
    environment.userId !== owner.userId ||
    environment.computerId !== owner.computerId
  )
    throw new Error("execution_environment_mismatch");
  // Catalog validation/recovery checks the current authorization without returning the key to this service.
  const current =
    environment.state === "stopped"
      ? { modelIds: environment.models }
      : await post(environment.initialization.url, environment.initialization.token, {
          checkOnly: true,
        });
  const modelIds = managedEnvironmentSchema.shape.models.parse(current.modelIds);
  return engines.flatMap(({ engine, label, protocol }) => {
    const model = environment.defaults[protocol];
    const generation = createHash("sha256")
      .update(
        JSON.stringify([
          owner,
          environment.credentialId,
          environment.credentialCreatedAt,
          environment.connectionRevision,
          environment.homeKey,
          engine,
          model,
          configuration.managed!.runtimeRevision,
        ]),
      )
      .digest("hex")
      .slice(0, 48);
    const modelId = engine === "deepseek" && model ? `granted/${model}` : model;
    return [
      {
        id: `managed-${generation}`,
        revision: 1,
        label,
        spaceId: owner.spaceId,
        computerId: owner.computerId,
        userIds: [owner.userId],
        engine,
        computer: { homeKey: environment.homeKey, workspace: "/home/rakazo/shared" },
        initialization: environment.initialization,
        ...(environment.state === "stopped" ? { availability: "stopped" as const } : {}),
        defaultModel: modelId,
        models: model && modelId && modelIds.includes(model) ? [{ id: modelId, label: model }] : [],
      },
    ];
  });
}

export function unavailableManagedProfiles(owner: ExecutionOwner): ExecutionServiceProfile[] {
  return engines.map(({ engine, label }) => ({
    spaceId: owner.spaceId,
    computerId: owner.computerId,
    userIds: [owner.userId],
    id: `unavailable-${engine}`,
    revision: 1,
    label,
    engineVersion: engineVersions[engine],
    status: "unauthenticated",
  }));
}

/** Local operator receipts certify this release, not an individual user's credentials. */
export async function certifiedRuntime(
  configuration: Configuration,
  engine: ComputerProfile["engine"],
) {
  if (!configuration.managed) return false;
  const receipt = await readFile(
    path.join(configuration.root, `runtime-${engine}.json`),
    "utf8",
  ).then(JSON.parse, () => null);
  return (
    receipt?.runtimeRevision === configuration.managed.runtimeRevision &&
    receipt.version === engineVersions[engine] &&
    receipt.managed === true &&
    Array.isArray(receipt.checks) &&
    verificationChecks.every((check) => receipt.checks.includes(check))
  );
}
