import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { Duplex } from "node:stream";
import { afterEach, expect, it } from "vitest";
import { createComputerExecutionRuntime } from "./computer-runtime.js";
import { engineVersions } from "./configuration.js";
import type { ComputerExec } from "./docker-process.js";
import { scope, startRequest } from "./protocol.test-support.js";

const cleanup: Array<() => Promise<void>> = [];
afterEach(async () => {
  for (const close of cleanup.splice(0).reverse()) await close();
});
const owner = { spaceId: scope.spaceId, userId: scope.userId, computerId: scope.computerId };
async function fixture(
  options: {
    running?: boolean;
    authorized?: boolean;
    supported?: boolean;
    defaults?: Record<string, string>;
    modelIds?: string[];
  } = {},
) {
  const root = await mkdtemp(path.join(tmpdir(), "computer-runtime-"));
  cleanup.push(() => rm(root, { recursive: true, force: true }));
  const commands: string[][] = [];
  const container: ComputerExec = {
    async exec() {
      return {
        async start() {
          const stream = new Duplex({
            read() {},
            write(data, _encoding, done) {
              const config = JSON.parse(String(data));
              if (!config.command) {
                done();
                return;
              }
              const command: string[] = config.command;
              commands.push(command);
              let line: string;
              let code = 0;
              if (command.includes("--version")) {
                const name = path.basename(command[0]!);
                const engine = name === "dsh" ? "deepseek" : (name as "codex" | "claude");
                line = `${name} ${options.supported === false ? "unsupported" : engineVersions[engine]}`;
              } else {
                expect(command[0]).toBe("/usr/local/bin/node");
                expect(command.join(" ")).toContain("checkOnly:true");
                code = options.authorized === false ? 1 : 0;
                line = JSON.stringify({
                  initialization: {
                    url: "https://app.example.test/api/model-account/computer",
                    token: "fixture-grant",
                  },
                  baseUrl: "https://models.example.test/v1",
                  defaults: options.defaults ?? {
                    responses: "response-model",
                    "chat-completions": "chat-model",
                  },
                  modelIds: options.modelIds ?? ["response-model", "chat-model"],
                });
              }
              for (const message of [
                { type: "ready" },
                { type: "line", line },
                { type: "exit", code, clean: true },
              ]) {
                const body = Buffer.from(`${JSON.stringify(message)}\n`);
                const header = Buffer.alloc(8);
                header[0] = 1;
                header.writeUInt32BE(body.length, 4);
                stream.push(Buffer.concat([header, body]));
              }
              stream.push(null);
              done();
            },
          });
          return stream;
        },
      };
    },
  };
  const runtime = createComputerExecutionRuntime({
    root,
    resolve: async () => ({
      container,
      user: "1000:1000",
      env: { HOME: "/home/computer", PATH: "/usr/local/bin:/usr/bin:/bin" },
      workspace: "/home/computer/shared",
      revision: "fixture-image",
      running: options.running !== false,
    }),
  });
  cleanup.push(() => runtime.close());
  return { runtime, commands };
}

it("discovers installed protocol engines and exposes authorized models independently of protocol defaults", async () => {
  const { runtime, commands } = await fixture();
  const result = await runtime.handle("describe", undefined, owner, "home");
  expect(result).toMatchObject({
    profiles: expect.arrayContaining([
      expect.objectContaining({ label: "Codex", status: "ready", defaultModel: "response-model" }),
      expect.objectContaining({
        label: "DSH",
        status: "ready",
        defaultModel: "granted/chat-model",
      }),
      expect.objectContaining({
        label: "Claude Code",
        status: "ready",
        models: [
          { id: "response-model", label: "response-model" },
          { id: "chat-model", label: "chat-model" },
        ],
      }),
    ]),
  });
  expect(commands).toHaveLength(4);
  const repeated = await runtime.handle("describe", undefined, owner, "home");
  expect(repeated).toEqual(result);
});

it.each([
  [{ running: false }, "stopped", 0],
  [{ authorized: false }, "unauthenticated", 1],
  [{ supported: false }, "unsupported", 4],
] as const)("reports live readiness for %o", async (options, status, probes) => {
  const { runtime, commands } = await fixture(options);
  const result = await runtime.handle("describe", undefined, owner, "home");
  expect(JSON.stringify(result)).toContain(`"status":"${status}"`);
  expect(commands).toHaveLength(probes);
  expect(JSON.stringify(result)).not.toContain("fixture-grant");
});

it("rejects a changed service identity and foreign owner before launching a protocol", async () => {
  const { runtime, commands } = await fixture();
  const description = (await runtime.handle("describe", undefined, owner, "home")) as {
    id: string;
  };
  const count = commands.length;
  await expect(runtime.handle("start", startRequest(), owner, "home", "foreign")).rejects.toThrow(
    "execution_identity_changed",
  );
  await expect(
    runtime.handle(
      "start",
      startRequest({ scope: { ...scope, userId: "foreign" } }),
      owner,
      "home",
      description.id,
    ),
  ).rejects.toThrow("execution_scope_mismatch");
  expect(commands).toHaveLength(count);
});

it("rejects discovery and dispatch after closing", async () => {
  const { runtime, commands } = await fixture();
  await runtime.close();
  await expect(runtime.handle("describe", undefined, owner, "home")).rejects.toThrow(
    "execution_service_stopped",
  );
  await expect(runtime.handle("start", startRequest(), owner, "home")).rejects.toThrow(
    "execution_service_stopped",
  );
  expect(commands).toHaveLength(0);
});

it.each<Record<string, string>>([{}, { responses: "removed-model" }])(
  "keeps model selection available with defaults %o",
  async (defaults) => {
    const { runtime } = await fixture({ defaults });
    const result = (await runtime.handle("describe", undefined, owner, "home")) as {
      profiles: Array<{ status: string; defaultModel?: string; models: Array<{ id: string }> }>;
    };
    expect(result.profiles).toHaveLength(3);
    for (const profile of result.profiles) {
      expect(profile.status).toBe("ready");
      expect(profile.defaultModel).toBeUndefined();
      expect(profile.models).toHaveLength(2);
    }
  },
);
it("keeps an empty authorized catalog unavailable", async () => {
  const { runtime } = await fixture({ modelIds: [] });
  const result = (await runtime.handle("describe", undefined, owner, "home")) as {
    profiles: Array<{ status: string; models: unknown[] }>;
  };
  for (const profile of result.profiles)
    expect(profile).toMatchObject({ status: "unavailable", models: [] });
});
