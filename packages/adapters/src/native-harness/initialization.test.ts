import { execFile } from "node:child_process";
import {
  chmod,
  lstat,
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import type { SandboxProvider } from "@rakazo/adapter-kit";
import type { PrismaClient } from "@rakazo/db";
import { afterEach, describe, expect, it, vi } from "vitest";
import { withComputerModelInitialization } from "./computer-initialization.js";
import {
  computerInitializationGrant,
  readComputerInitializationGrant,
} from "./initialization-auth.js";
import { computerInitializationProgram } from "./initialization-program.js";

const execute = promisify(execFile);
const scope = { userId: "user-fixture", spaceId: "space-fixture", homeKey: "home-fixture" };
const grant = {
  ...scope,
  credentialId: "fixture-credential",
  credentialCreatedAt: "2026-01-01T00:00:00.000Z",
};
const key = "fake-signing-key";
const cleanups: Array<() => Promise<unknown>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0)) await cleanup();
});

async function fixture() {
  const home = await mkdtemp(path.join(tmpdir(), "computer-init-"));
  cleanups.push(() => rm(home, { recursive: true, force: true }));
  let status = 200,
    currentKey = "fake-key-one",
    calls = 0;
  const server = createServer((req, res) => {
    calls++;
    expect(req.headers.authorization).toBe("Bearer fake-computer-grant");
    res.writeHead(status, { "content-type": "application/json" });
    res.end(
      JSON.stringify({
        baseUrl: "https://models.example.test/v1",
        apiKey: currentKey,
        defaults: {
          responses: "model-r",
          "anthropic-messages": "model-a",
          "chat-completions": "model-c",
        },
        modelIds: ["model-r", "model-a", "model-c"],
      }),
    );
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  cleanups.unshift(() => new Promise<void>((resolve) => server.close(() => resolve())));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("test-server");
  const binaries = path.join(home, "binaries");
  await mkdir(binaries);
  for (const engine of ["codex", "claude", "dsh"]) {
    await writeFile(
      path.join(binaries, engine),
      `#!${process.execPath}\nconst fs=require('fs');
console.log(JSON.stringify({args:process.argv.slice(2),key:process.env.OPENAI_API_KEY??process.env.ANTHROPIC_AUTH_TOKEN,
base:process.env.ANTHROPIC_BASE_URL,model:process.env.ANTHROPIC_MODEL,
controlEnvironment:['COMPUTER_MODEL_INITIALIZATION','COMPUTER_MODEL_PROGRAM','COMPUTER_MODEL_LAUNCH'].some(key=>key in process.env),
patch:process.argv.includes('--patch')?JSON.parse(fs.readFileSync(process.argv[process.argv.indexOf('--patch')+1],'utf8')):null}));`,
    );
    await chmod(path.join(binaries, engine), 0o700);
  }
  // Substitute the fixed image executable directory only; exercise the shipped initializer and runner.
  const program = computerInitializationProgram.replaceAll(
    "'/usr/local/bin/'",
    JSON.stringify(`${binaries}/`),
  );
  const env = { HOME: home, PATH: process.env.PATH };
  const install = () =>
    execute(process.execPath, ["--input-type=module", "--eval", program], {
      env: {
        ...env,
        COMPUTER_MODEL_INITIALIZATION: JSON.stringify({
          url: `http://127.0.0.1:${address.port}`,
          token: "fake-computer-grant",
        }),
        COMPUTER_MODEL_PROGRAM: program,
      },
    });
  const root = path.join(home, ".local/share/computer-model-connection");
  return {
    home,
    root,
    install,
    setKey: (value: string) => {
      currentKey = value;
    },
    setStatus: (value: number) => {
      status = value;
    },
    calls: () => calls,
    managedRun: (engine: string, args: string[] = []) =>
      execute(process.execPath, ["--input-type=module", "--eval", program, engine, ...args], {
        env: {
          ...env,
          COMPUTER_MODEL_LAUNCH: "1",
          COMPUTER_MODEL_INITIALIZATION: JSON.stringify({
            url: `http://127.0.0.1:${address.port}`,
            token: "fake-computer-grant",
          }),
          COMPUTER_MODEL_PROGRAM: program,
        },
      }),
    run: (engine: string, args: string[] = []) =>
      execute(process.execPath, [path.join(root, "run.mjs"), engine, ...args], { env }),
  };
}

describe("computer model initialization", () => {
  it("authenticates only the exact computer grant and rejects tampering", () => {
    const token = computerInitializationGrant(key, grant);
    expect(readComputerInitializationGrant(key, token)).toEqual(grant);
    expect(readComputerInitializationGrant("different-key", token)).toBeNull();
    expect(readComputerInitializationGrant(key, `${token}x`)).toBeNull();
    expect(readComputerInitializationGrant(key, `${token}.extra`)).toBeNull();
  });

  it("installs offline, preserves native settings, and uses a fresh connection for each CLI", async () => {
    const f = await fixture();
    await mkdir(path.join(f.home, ".codex"));
    await writeFile(path.join(f.home, ".codex/config.toml"), 'model_provider="user-choice"');
    await f.install();
    const initial = await lstat(path.join(f.root, "grant.json"));
    await f.install();
    expect((await lstat(path.join(f.root, "grant.json"))).ino).toBe(initial.ino);
    expect(f.calls()).toBe(0);
    expect((await lstat(path.join(f.root, "grant.json"))).mode & 0o777).toBe(0o600);
    const codex = JSON.parse((await f.run("codex", ["app-server"])).stdout);
    expect(codex.key).toBe("fake-key-one");
    expect(codex.args).toContain('model_provider="managed"');
    expect(codex.args.at(-1)).toBe("app-server");
    f.setKey("fake-key-two");
    const claude = JSON.parse((await f.run("claude", ["-p", "hello"])).stdout);
    expect(claude).toMatchObject({
      key: "fake-key-two",
      base: "https://models.example.test",
      model: "model-a",
    });
    const dsh = JSON.parse((await f.run("dsh", ["--profile", "acp"])).stdout);
    expect(dsh.key).toBe("fake-key-two");
    expect(dsh.patch[0].config.providers.granted).toMatchObject({
      baseURL: "https://models.example.test/v1",
      api: "openai-completions",
    });
    expect(dsh.patch[1].config).toEqual({ provider: "granted", model: "model-c" });
    expect((await readdir(f.root)).some((file) => file.startsWith("overlay-"))).toBe(false);
    expect(await readFile(path.join(f.home, ".codex/config.toml"), "utf8")).toBe(
      'model_provider="user-choice"',
    );
    for (const file of await readdir(f.root))
      expect(await readFile(path.join(f.root, file), "utf8")).not.toContain("fake-key-two");
  });

  it("initializes and launches a managed protocol directly while preserving custom user launchers", async () => {
    const f = await fixture();
    await mkdir(path.join(f.home, ".local/bin"), { recursive: true });
    await writeFile(path.join(f.home, ".local/bin/codex"), "custom-launcher");
    const result = JSON.parse((await f.managedRun("codex", ["app-server"])).stdout);
    expect(result.key).toBe("fake-key-one");
    expect(result.controlEnvironment).toBe(false);
    expect(result.args.at(-1)).toBe("app-server");
    expect(await readFile(path.join(f.home, ".local/bin/codex"), "utf8")).toBe("custom-launcher");
    f.setKey("fake-key-next");
    expect(JSON.parse((await f.managedRun("claude", ["-p", "test"])).stdout).key).toBe(
      "fake-key-next",
    );
    for (const file of await readdir(f.root))
      expect(await readFile(path.join(f.root, file), "utf8")).not.toContain("fake-key-next");
  });

  it("does not launch or replay a CLI after authentication failure, while local help works", async () => {
    const f = await fixture();
    await f.install();
    f.setStatus(401);
    await expect(f.run("codex", ["app-server"])).rejects.toMatchObject({
      stderr: "Model connection initialization failed.\n",
    });
    expect(f.calls()).toBe(1);
    await f.run("codex", ["--version"]);
    await f.run("codex", ["login"]);
    expect(f.calls()).toBe(1);
  });

  it("preserves custom launchers and refuses a symlinked managed directory", async () => {
    const f = await fixture();
    await mkdir(path.join(f.home, ".local/bin"), { recursive: true });
    await writeFile(path.join(f.home, ".local/bin/codex"), "custom-launcher");
    await f.install();
    expect(await readFile(path.join(f.home, ".local/bin/codex"), "utf8")).toBe("custom-launcher");
    expect(await readFile(path.join(f.home, ".local/bin/claude"), "utf8")).toContain(
      "managed-computer",
    );
    await rm(f.root, { recursive: true });
    await symlink(path.join(f.home, "binaries"), f.root);
    await expect(f.install()).rejects.toMatchObject({ code: 1 });
  });

  it("never installs a personal grant into a shared home or another owner's computer", async () => {
    const prepare = vi.fn(async () => {}),
      execute = vi.fn();
    const prisma = { computer: { findFirst: vi.fn(async () => null) } };
    const sandbox = withComputerModelInitialization(
      { prepare, execute } as unknown as SandboxProvider,
      prisma as unknown as PrismaClient,
      { url: "https://app.example.test", signingKey: key },
    );
    await sandbox.prepare(
      { id: "fixture-container", kind: "docker", botId: grant.homeKey, providerRef: "fake" },
      { ...grant, operationId: "test", traceId: "test", signal: new AbortController().signal },
    );
    expect(prepare).toHaveBeenCalledOnce();
    expect(execute).not.toHaveBeenCalled();
    expect(prisma.computer.findFirst).toHaveBeenCalledWith({
      where: expect.objectContaining({
        ...scope,
        scope: { in: ["team", "dedicated"] },
        space: expect.objectContaining({
          memberships: { some: { userId: scope.userId }, none: { userId: { not: scope.userId } } },
        }),
      }),
    });
  });
});
