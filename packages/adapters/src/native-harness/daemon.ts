import { mkdir, readFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { deepseekModelLabel } from "./acp-config.js";
import { nativeHarnessDriver } from "./catalog.js";
import { launchComputerHarness } from "./computer-process.js";
import { resolveComputerTarget } from "./computer-target.js";
import { engineVersions, readDaemonConfiguration } from "./configuration.js";
import type { ExecutionServiceProfile } from "./http-client.js";
import { startNativeExecutionServer } from "./http-server.js";
import { inspectComputerHarness, verifyComputerIsolation } from "./inspection.js";
import type { ComputerProfile, ExecutionOwner } from "./managed-profiles.js";
import {
  certifiedRuntime,
  ExecutionEnvironmentError,
  managedComputerProfiles,
  unavailableManagedProfiles,
} from "./managed-profiles.js";
import type { ExecutionProfileAdmission } from "./service.js";
import { NativeHarnessExecutionService } from "./service.js";
import { verificationBinding, verificationChecks } from "./verification.js";
import { readNativeWorkspaceFile } from "./workspace-file.js";

export async function startExecutionDaemon(configurationFile: string) {
  const configuration = await readDaemonConfiguration(configurationFile);
  await mkdir(configuration.root, { recursive: true, mode: 0o700 });
  async function inspectProfiles(profiles: ComputerProfile[], managed = false) {
    const admissions: ExecutionProfileAdmission[] = [];
    const descriptions = await Promise.all(
      profiles.map(async (profile) => {
        const request = {
          runId: "inspection",
          scope: {
            spaceId: profile.spaceId,
            userId: profile.userIds[0]!,
            botId: "inspection",
            threadId: "inspection",
            computerId: profile.computerId,
            profileId: profile.id,
            revision: profile.revision,
          },
          fence: 0,
          leaseExpiresAt: new Date(Date.now() + 60_000).toISOString(),
          prompt: "inspection",
          instructions: "",
        };
        let status:
          | "missing"
          | "unsupported"
          | "unauthenticated"
          | "unverified"
          | "stopped"
          | "unavailable"
          | "ready" = "missing";
        const expected = engineVersions[profile.engine];
        try {
          const inspect = (mode: "version" | "authentication") =>
            inspectComputerHarness(
              profile,
              request,
              configuration.root,
              mode,
              managed ? 3000 : 15_000,
            );
          if (managed && profile.availability === "stopped") {
            status = "stopped";
            throw new Error("computer_stopped");
          }
          if (managed && (!profile.defaultModel || !profile.models?.length)) {
            status = "unavailable";
            throw new Error("model_unavailable");
          }
          const version = await inspect("version");
          if (version.code === 0) {
            status = "unsupported";
            if (version.output.split(/\s+/).includes(expected)) {
              status = "unauthenticated";
              const authentication =
                profile.engine === "deepseek" || profile.modelConnection || profile.initialization
                  ? null
                  : await inspect("authentication");
              if (
                profile.engine === "deepseek" ||
                profile.modelConnection ||
                profile.initialization ||
                authentication?.code === 0
              ) {
                status = "unverified";
                // A verification receipt is written only by the opt-in real CLI suite in this private directory.
                const receipt = (await readFile(
                  path.join(configuration.root, `verified-${profile.id}.json`),
                  "utf8",
                ).then(JSON.parse, () => null)) as null | {
                  version: string;
                  revision: number;
                  checks: string[];
                  binding: string;
                };
                if (managed && (await certifiedRuntime(configuration, profile.engine))) {
                  await verifyComputerIsolation(profile, request, configuration.root, 3000);
                  status = "ready";
                }
                if (
                  !managed &&
                  receipt?.version === expected &&
                  receipt.revision === profile.revision &&
                  receipt.binding === verificationBinding(profile) &&
                  verificationChecks.every((check) => receipt.checks.includes(check))
                )
                  status = "ready";
              }
            }
          }
        } catch {
          /* Only sanitized readiness leaves the private execution boundary. */
        }
        const description: ExecutionServiceProfile = {
          id: profile.id,
          revision: profile.revision,
          label: profile.label,
          spaceId: profile.spaceId,
          userIds: profile.userIds,
          computerId: profile.computerId,
          engineVersion: expected,
          defaultModel: profile.defaultModel ?? profile.modelConnection?.model,
          models: (
            profile.models ??
            (profile.modelConnection
              ? [{ id: profile.modelConnection.model, label: profile.modelConnection.model }]
              : [])
          ).map(({ id, label }) => ({
            id,
            label: profile.engine === "deepseek" && label === id ? deepseekModelLabel(id) : label,
          })),
          status,
        };
        if (status === "ready")
          admissions.push({
            ...profile,
            engineVersion: expected,
            driver: await nativeHarnessDriver(profile.engine),
            launch: (request) => launchComputerHarness(profile, request, configuration.root),
            readWorkspaceFile: async (file) => {
              const account = await resolveComputerTarget(profile.computer, request.scope);
              return readNativeWorkspaceFile(account.workspace, file, account.source);
            },
          });
        return description;
      }),
    );
    return { admissions, descriptions };
  }
  const initial = await inspectProfiles(configuration.profiles);
  const service = new NativeHarnessExecutionService(configuration.root, initial.admissions);
  const discover = async (owner: ExecutionOwner) => {
    try {
      const result = await inspectProfiles(
        await managedComputerProfiles(configuration, owner),
        true,
      );
      service.replaceComputerProfiles(owner.computerId, result.admissions);
      return result.descriptions;
    } catch (error) {
      service.replaceComputerProfiles(owner.computerId, []);
      if (error instanceof ExecutionEnvironmentError && [401, 403].includes(error.status))
        return unavailableManagedProfiles(owner);
      throw error;
    }
  };
  const server = await startNativeExecutionServer({
    ...configuration,
    profiles: initial.descriptions,
    ...(configuration.managed
      ? {
          describe: async (owner?: ExecutionOwner) =>
            owner ? discover(owner) : initial.descriptions,
          beforeStart: async (request: Parameters<typeof service.start>[0]) => {
            if (request.scope.profileId.startsWith("managed-")) await discover(request.scope);
          },
        }
      : {}),
    provider: service,
  });
  return {
    ...server,
    async close() {
      await server.close();
      await service.close();
    },
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const daemon = await startExecutionDaemon(process.argv[2] ?? "");
  for (const signal of ["SIGTERM", "SIGINT"] as const)
    process.once(signal, () => {
      void daemon.close().then(() => process.exit(0));
    });
}
