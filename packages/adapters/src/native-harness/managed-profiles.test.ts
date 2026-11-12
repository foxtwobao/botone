import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, expect, it } from "vitest";
import { daemonConfigurationSchema } from "./configuration.js";
import { configuredExecutionConnection } from "./managed-configuration.js";
import { certifiedRuntime, managedComputerProfiles } from "./managed-profiles.js";
import { verificationChecks } from "./verification.js";

const cleanups: Array<() => Promise<unknown>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

it("discovers a scoped environment, validates the live catalog and fences reauthorization without persisting model keys", async () => {
  const owner = {
    spaceId: "fixture-space",
    userId: "fixture-user",
    computerId: "fixture-computer",
  };
  let state = "running",
    createdAt = "2026-01-01T00:00:00.000Z",
    valid = true,
    catalog = ["model-r", "model-a", "model-c"];
  const bodies: unknown[] = [];
  const server = createServer(async (request, response) => {
    const chunks: Buffer[] = [];
    for await (const chunk of request) chunks.push(chunk);
    const body = JSON.parse(Buffer.concat(chunks).toString());
    bodies.push(body);
    if (request.url === "/api/model-account/environment") {
      expect(request.headers.authorization).toBe(`Bearer ${"a".repeat(64)}`);
      expect(body).toEqual(owner);
      response.end(
        JSON.stringify({
          ...owner,
          ...(valid ? {} : { userId: "other-user" }),
          homeKey: "fixture-home",
          state,
          credentialId: "fixture-credential",
          credentialCreatedAt: createdAt,
          connectionRevision: "c".repeat(64),
          models: catalog,
          defaults: {
            responses: "model-r",
            "anthropic-messages": "model-a",
            "chat-completions": "model-c",
          },
          initialization: { url: `${url}/computer`, token: "fake-computer-grant" },
        }),
      );
    } else {
      expect(request.url).toBe("/computer");
      expect(request.headers.authorization).toBe("Bearer fake-computer-grant");
      expect(body).toEqual({ checkOnly: true });
      response.end(JSON.stringify({ modelIds: catalog }));
    }
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  cleanups.push(() => new Promise<void>((resolve) => server.close(() => resolve())));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("test_server");
  const url = `http://127.0.0.1:${address.port}`;
  const configuration = daemonConfigurationSchema.parse({
    root: "/unused",
    port: 9081,
    token: "a".repeat(64),
    managed: { apiUrl: url, runtimeRevision: "b".repeat(40) },
  });
  const profiles = await managedComputerProfiles(configuration, owner);
  expect(profiles.map((profile) => profile.label)).toEqual(["Codex", "Claude Code", "DSH"]);
  expect(profiles.map((profile) => profile.defaultModel)).toEqual([
    "model-r",
    "model-a",
    "granted/model-c",
  ]);
  expect(
    profiles.every(
      (profile) => profile.userIds.length === 1 && profile.userIds[0] === owner.userId,
    ),
  ).toBe(true);
  expect(JSON.stringify(profiles)).not.toContain("apiKey");
  expect(
    (await managedComputerProfiles(configuration, owner)).map((profile) => profile.id),
  ).toEqual(profiles.map((profile) => profile.id));
  createdAt = "2026-01-02T00:00:00.000Z";
  const replaced = await managedComputerProfiles(configuration, owner);
  expect(replaced.every((profile, index) => profile.id !== profiles[index]!.id)).toBe(true);
  catalog = ["model-r"];
  expect(
    (await managedComputerProfiles(configuration, owner)).map((profile) => profile.models?.length),
  ).toEqual([1, 0, 0]);
  state = "stopped";
  const before = bodies.length;
  expect(
    (await managedComputerProfiles(configuration, owner)).every(
      (profile) => profile.availability === "stopped",
    ),
  ).toBe(true);
  expect(bodies.length).toBe(before + 1);
  valid = false;
  await expect(managedComputerProfiles(configuration, owner)).rejects.toThrow(
    "execution_environment_mismatch",
  );
  expect(bodies.at(-1)).toEqual(owner);
});

it("requires a successful managed CLI receipt for this exact runtime release and engine version", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "runtime-receipt-"));
  cleanups.push(() => rm(root, { recursive: true, force: true }));
  const configuration = daemonConfigurationSchema.parse({
    root,
    port: 9081,
    token: "a".repeat(64),
    managed: { apiUrl: "https://app.example.test", runtimeRevision: "b".repeat(40) },
  });
  expect(await certifiedRuntime(configuration, "codex")).toBe(false);
  const write = (changes: object) =>
    writeFile(
      path.join(root, "runtime-codex.json"),
      JSON.stringify({
        managed: true,
        version: "0.167.0",
        runtimeRevision: "b".repeat(40),
        checks: verificationChecks,
        ...changes,
      }),
      { mode: 0o600 },
    );
  await write({});
  expect(await certifiedRuntime(configuration, "codex")).toBe(true);
  for (const changes of [
    { runtimeRevision: "c".repeat(40) },
    { version: "other" },
    { managed: false },
    { checks: ["file"] },
  ]) {
    await write(changes);
    expect(await certifiedRuntime(configuration, "codex")).toBe(false);
  }
});

it("accepts only explicit deployment connections and keeps managed discovery separate from static grants", () => {
  expect(configuredExecutionConnection()).toBeUndefined();
  for (const url of [
    "http://execution.example.test",
    "https://user:password@execution.example.test",
    "https://execution.example.test/path",
    "https://execution.example.test?token=oops",
  ]) {
    expect(() =>
      configuredExecutionConnection(JSON.stringify({ url, token: "a".repeat(64) })),
    ).toThrow("Invalid EXECUTION_CONNECTION");
  }
  expect(
    configuredExecutionConnection(
      JSON.stringify({
        url: "http://127.0.0.1:9081",
        token: "a".repeat(64),
        allowPrivateEndpoint: true,
      }),
    ),
  ).toMatchObject({ allowPrivateEndpoint: true });
});
