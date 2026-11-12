import { mkdir, readFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { deepseekModelLabel } from "./acp-config.js";
import { nativeHarnessDriver } from "./catalog.js";
import { launchComputerHarness } from "./computer-process.js";
import { resolveComputerTarget } from "./computer-target.js";
import { engineVersions, readDaemonConfiguration } from "./configuration.js";
import { startNativeExecutionServer } from "./http-server.js";
import type { ExecutionProfileAdmission } from "./service.js";
import { NativeHarnessExecutionService } from "./service.js";
import { verificationBinding, verificationChecks } from "./verification.js";
import { readNativeWorkspaceFile } from "./workspace-file.js";

export async function startExecutionDaemon(configurationFile: string) {
  const configuration = await readDaemonConfiguration(configurationFile);
  await mkdir(configuration.root, { recursive: true, mode: 0o700 });
  const admissions: ExecutionProfileAdmission[] = [];
  const descriptions = [];
  for (const profile of configuration.profiles) {
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
    let status: "missing" | "unsupported" | "unauthenticated" | "unverified" | "ready" = "missing";
    const expected = engineVersions[profile.engine];
    try {
      const inspect = async (mode: "version" | "authentication") => {
        const process = await launchComputerHarness(profile, request, configuration.root, mode);
        let output = "";
        process.onLine((line) => {
          if (output.length < 16_384) output += `${line}\n`;
        });
        const code = await new Promise<number | null | undefined>((resolve) => {
          const timeout = setTimeout(() => {
            void process.stop().finally(() => resolve(undefined));
          }, 15_000);
          process.onExit((code) => {
            clearTimeout(timeout);
            resolve(code);
          });
        });
        await process.stop();
        return { code, output };
      };
      const version = await inspect("version");
      if (version.code === 0) {
        status = "unsupported";
        if (version.output.split(/\s+/).includes(expected)) {
          status = "unauthenticated";
          const authentication =
            profile.engine === "deepseek" || profile.modelConnection
              ? null
              : await inspect("authentication");
          if (
            profile.engine === "deepseek" ||
            profile.modelConnection ||
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
            if (
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
    descriptions.push({
      id: profile.id,
      revision: profile.revision,
      label: profile.label,
      spaceId: profile.spaceId,
      userIds: profile.userIds,
      computerId: profile.computerId,
      engineVersion: expected,
      defaultModel: profile.modelConnection?.model,
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
    });
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
  }
  const service = new NativeHarnessExecutionService(configuration.root, admissions);
  const server = await startNativeExecutionServer({
    ...configuration,
    profiles: descriptions,
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
