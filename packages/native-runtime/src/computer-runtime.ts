import { createHash, randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import type { ComputerExecutionProvider, NativeExecutionStart } from "@rakazo/adapter-kit";
import { z } from "zod";
import { nativeHarnessDriver } from "./catalog.js";
import { engineVersions } from "./configuration.js";
import type { ComputerExec } from "./docker-process.js";
import { launchDockerProcess } from "./docker-process.js";
import type { HarnessProcess } from "./driver.js";
import { computerInitializationProgram } from "./initialization-program.js";
import { nativeLaunchArguments } from "./launch-arguments.js";
import { executionOwnerSchema } from "./managed-configuration.js";
import type { ExecutionProfileAdmission } from "./service.js";
import { NativeHarnessExecutionService } from "./service.js";
import {
  executionAttachSchema,
  executionControlSchema,
  executionResponseSchema,
  executionStartSchema,
  executionSteerSchema,
  executionStopSchema,
  executionToolResultSchema,
} from "./wire.js";
import { workspaceFileProgram } from "./workspace-file.js";

type ExecutionServiceProfile = Awaited<
  ReturnType<ComputerExecutionProvider["describe"]>
>["profiles"][number];

export interface ExecutionComputer {
  container: ComputerExec;
  env: Record<string, string>;
  user: string;
  workspace: string;
  revision: string;
  running: boolean;
}

const engines = [
  { engine: "codex", label: "Codex", protocol: "responses" },
  { engine: "claude", label: "Claude Code", protocol: "anthropic-messages" },
  { engine: "deepseek", label: "DSH", protocol: "chat-completions" },
] as const;
const initializationSchema = z.object({ url: z.string().url(), token: z.string().min(1) }).strict();
const accountSchema = z
  .object({
    initialization: initializationSchema,
    baseUrl: z.string().url(),
    defaults: z.record(z.string(), z.string()),
    modelIds: z.array(z.string()).max(500),
  })
  .strict();

// Run the preflight inside the computer: a user-writable grant must never cause host-side fetches.
const accountProbe = `
import fs from 'node:fs/promises';import path from 'node:path';
const owner=JSON.parse(process.argv[1]);
const grant=JSON.parse(await fs.readFile(path.join(process.env.HOME,'.local/share/computer-model-connection/grant.json'),'utf8'));
const scope=JSON.parse(Buffer.from(grant.token.split('.')[0],'base64url').toString());
if(scope.userId!==owner.userId||scope.spaceId!==owner.spaceId||scope.homeKey!==owner.homeKey)throw Error('grant_scope');
const url=new URL(grant.url);if(url.protocol!=='https:'||url.username||url.password||url.hash||url.search)throw Error('grant_endpoint');
const response=await fetch(url,{method:'POST',headers:{authorization:'Bearer '+grant.token,'content-type':'application/json'},
 body:JSON.stringify({checkOnly:true}),redirect:'error',signal:AbortSignal.timeout(10000)});
if(!response.ok)throw Error('authorization_required');
const text=await response.text();if(text.length>256*1024)throw Error('response_limit');
const value=JSON.parse(text);
console.log(JSON.stringify({initialization:grant,baseUrl:value.baseUrl,defaults:value.defaults,modelIds:value.modelIds}));
`;

async function output(process: HarnessProcess, limit = 256 * 1024) {
  let result = "";
  process.onLine((line) => {
    if (result.length <= limit) result += `${line}\n`;
  });
  let timer: NodeJS.Timeout | undefined;
  try {
    const code = await Promise.race([
      new Promise<number | null | undefined>((resolve) => process.onExit(resolve)),
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error("inspection_timeout")), 15000);
      }),
    ]);
    if (code !== 0) throw new Error("inspection_failed");
    if (Buffer.byteLength(result) > limit) throw new Error("output_limit");
    return result.trim();
  } finally {
    clearTimeout(timer);
    await process.stop();
  }
}

/** Composed into the existing supervisor. This module opens no port and reads no deployment env. */
export function createComputerExecutionRuntime(options: {
  root: string;
  resolve(computerId: string, homeKey: string, spaceId: string): Promise<ExecutionComputer>;
}) {
  mkdirSync(options.root, { recursive: true, mode: 0o700 });
  const identityFile = path.join(options.root, "identity");
  try {
    writeFileSync(identityFile, randomUUID(), { mode: 0o600, flag: "wx" });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
  }
  const identity = readFileSync(identityFile, "utf8").trim();
  const service = new NativeHarnessExecutionService(options.root, []);
  async function discover(owner: z.infer<typeof executionOwnerSchema>, homeKey: string) {
    const computer = await options.resolve(owner.computerId, homeKey, owner.spaceId);
    const admissions: ExecutionProfileAdmission[] = [];
    let account: z.infer<typeof accountSchema> | undefined;
    if (computer.running) {
      try {
        account = accountSchema.parse(
          JSON.parse(
            await output(
              await launchDockerProcess(computer.container, {
                ...computer,
                command: () => [
                  "/usr/local/bin/node",
                  "--input-type=module",
                  "--eval",
                  accountProbe,
                  JSON.stringify({ ...owner, homeKey }),
                ],
              }),
            ),
          ),
        );
      } catch {
        /* Return only sanitized readiness. No CLI stderr or grants reach clients. */
      }
    }
    const profiles = await Promise.all(
      engines.map(async ({ engine, label, protocol }) => {
        const configuredModel = account?.defaults[protocol];
        const model =
          configuredModel && account?.modelIds.includes(configuredModel)
            ? configuredModel
            : undefined;
        const modelId = engine === "deepseek" && model ? `granted/${model}` : model;
        const generation = createHash("sha256")
          .update(
            JSON.stringify([
              owner,
              homeKey,
              computer.revision,
              engine,
              account?.initialization,
              account?.baseUrl,
            ]),
          )
          .digest("hex")
          .slice(0, 48);
        const profile: ExecutionServiceProfile = {
          ...owner,
          userIds: [owner.userId],
          id: `managed-${generation}`,
          revision: 1,
          label,
          engineVersion: engineVersions[engine],
          defaultModel: modelId,
          models: (account?.modelIds ?? []).map((id) => ({
            id: engine === "deepseek" ? `granted/${id}` : id,
            label: id,
          })),
          status: !computer.running
            ? "stopped"
            : !account
              ? "unauthenticated"
              : !account.modelIds.length
                ? "unavailable"
                : "missing",
        };
        if (account && profile.models?.length && computer.running) {
          try {
            const version = await output(
              await launchDockerProcess(computer.container, {
                ...computer,
                command: () => [
                  `/usr/local/bin/${engine === "deepseek" ? "dsh" : engine}`,
                  "--version",
                ],
              }),
            );
            profile.status = version.split(/\s+/).includes(engineVersions[engine])
              ? "ready"
              : "unsupported";
            if (profile.status === "ready") {
              const initialization = account.initialization;
              admissions.push({
                ...profile,
                driver: await nativeHarnessDriver(engine),
                launch: (request) =>
                  launchDockerProcess(computer.container, {
                    ...computer,
                    runKey: createHash("sha256")
                      .update(
                        JSON.stringify([owner.spaceId, owner.computerId, request.scope.botId]),
                      )
                      .digest("hex"),
                    env: {
                      ...computer.env,
                      COMPUTER_MODEL_INITIALIZATION: JSON.stringify(initialization),
                      COMPUTER_MODEL_LAUNCH: "1",
                      COMPUTER_MODEL_SELECTION:
                        engine === "deepseek"
                          ? (request.model ?? profile.defaultModel ?? "").replace(/^granted\//, "")
                          : (request.model ?? profile.defaultModel ?? ""),
                    },
                    command: (socket) => [
                      "/usr/local/bin/node",
                      "--input-type=module",
                      "--eval",
                      computerInitializationProgram,
                      engine === "deepseek" ? "dsh" : engine,
                      ...nativeLaunchArguments(engine, request, socket).slice(1),
                    ],
                  }),
                readWorkspaceFile: async (file) =>
                  JSON.parse(
                    await output(
                      await launchDockerProcess(computer.container, {
                        ...computer,
                        command: () => [
                          "/usr/bin/python3",
                          "-c",
                          workspaceFileProgram,
                          computer.workspace,
                          computer.env.HOME!,
                          file,
                        ],
                      }),
                      2 * 1024 * 1024,
                    ),
                  ),
              });
            }
          } catch {
            /* Missing or unstartable engines remain unavailable. */
          }
        }
        return profile;
      }),
    );
    service.replaceComputerProfiles(owner.computerId, admissions);
    return profiles;
  }
  let closing = false;
  const pending = new Set<Promise<unknown>>();
  const runtime = {
    async close() {
      closing = true;
      await Promise.allSettled([...pending]);
      await service.close();
    },
    async dispatch(
      route: string,
      input: unknown,
      owner: unknown,
      homeKey: string,
      serviceId?: string,
    ) {
      if (closing) throw new Error("execution_service_stopped");
      const scope = executionOwnerSchema.parse(owner);
      if (route === "describe") return { id: identity, profiles: await discover(scope, homeKey) };
      if (serviceId !== identity) throw new Error("execution_identity_changed");
      const scoped = z.object({ scope: executionOwnerSchema.passthrough() }).parse(input).scope;
      if (
        scoped.spaceId !== scope.spaceId ||
        scoped.userId !== scope.userId ||
        scoped.computerId !== scope.computerId
      )
        throw new Error("execution_scope_mismatch");
      switch (route) {
        case "start": {
          const request: NativeExecutionStart = executionStartSchema.parse(input);
          await discover(scope, homeKey);
          if (closing) throw new Error("execution_service_stopped");
          return service.start(request);
        }
        case "attach":
          return service.attach(executionAttachSchema.parse(input));
        case "respond":
          return service.respond(executionResponseSchema.parse(input));
        case "tool-result":
          return service.toolResult(executionToolResultSchema.parse(input));
        case "steer":
          return service.steer(executionSteerSchema.parse(input));
        case "stop":
          await service.stop(executionStopSchema.parse(input));
          return { stopped: true };
        case "cancel":
          await service.cancel(executionControlSchema.parse(input));
          return { stopped: true };
        default:
          throw new Error("unsupported_execution_request");
      }
    },
  };
  return {
    close: () => runtime.close(),
    handle(...args: Parameters<typeof runtime.dispatch>) {
      const operation = runtime.dispatch(...args);
      pending.add(operation);
      void operation.then(
        () => pending.delete(operation),
        () => pending.delete(operation),
      );
      return operation;
    },
  };
}
