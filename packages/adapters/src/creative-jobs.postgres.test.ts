import { randomUUID } from "node:crypto";
import type { AdapterContext, ArtifactStore } from "@rakazo/adapter-kit";
import { createDb, createThreadEvents, runAsSystem, runAsTenant } from "@rakazo/db";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { capabilities, creativeFixture, identityA, musicInput } from "./creative.test-support.js";
import { CreativeAppConnector } from "./creative-connector.js";
import type { CreativeJob } from "./creative-contracts.js";
import type { CreativeProvider } from "./creative-provider.js";
import { CreativeServiceError } from "./creative-provider.js";

const postgres =
  process.env.VERIFY_DATABASE === "1" && process.env.DATABASE_URL ? describe : describe.skip;
postgres("creative jobs with real persistence", () => {
  const { prisma, pool } = createDb(process.env.DATABASE_URL ?? "");
  const id = `creative-${randomUUID()}`;
  const owner = { spaceId: `${id}-space`, userId: `${id}-user` };
  const system = <T>(fn: () => Promise<T>) => runAsSystem("synthetic creative test fixture", fn);
  let context: AdapterContext;
  let connectionId: string;
  let connector: CreativeAppConnector;
  let remoteJob: CreativeJob;
  let failSubmit = false;
  const provider: CreativeProvider = {
    capabilities: async () => structuredClone(capabilities),
    uploadReference: vi.fn(async (_identity, bytes) => ({
      id: randomUUID(),
      mimeType: "image/png",
      bytes: bytes.byteLength,
      width: 1,
      height: 1,
    })),
    submit: vi.fn(async (_identity, operationId) => {
      if (failSubmit) throw new Error("Synthetic timeout");
      remoteJob = { operationId, status: "queued", outputs: [] };
      return structuredClone(remoteJob);
    }),
    job: vi.fn(async (_identity, operationId) => {
      if (remoteJob?.operationId !== operationId) throw new CreativeServiceError("not_found", 404);
      return structuredClone(remoteJob);
    }),
    output: vi.fn(
      async () =>
        new Response(new Uint8Array([1, 2, 3]), { headers: { "content-type": "audio/mpeg" } }),
    ),
  };
  const blobs: ArtifactStore = {
    describe: () => ({
      id: "synthetic",
      contractVersion: "1",
      adapterVersion: "1",
      capabilities: { stream: false },
    }),
    put: vi.fn(async () => ({ id: randomUUID(), hash: "synthetic" })),
    get: async () => new Uint8Array(),
    remove: vi.fn(async () => undefined),
  };
  beforeAll(async () =>
    system(async () => {
      await prisma.user.create({
        data: { id: owner.userId, name: "Demo", email: `${id}@example.test` },
      });
      const organizationId = `${id}-org`;
      await prisma.organization.create({
        data: { id: organizationId, name: "Demo", slug: id, createdAt: new Date() },
      });
      await prisma.space.create({ data: { id: owner.spaceId, organizationId, name: "Demo" } });
      await prisma.member.create({
        data: {
          id: `${id}-member`,
          organizationId,
          userId: owner.userId,
          role: "owner",
          createdAt: new Date(),
        },
      });
      await prisma.spaceMember.create({
        data: {
          id: `${id}-space-member`,
          ...owner,
          organizationId,
          role: "owner",
          createdAt: new Date(),
        },
      });
      const bot = await prisma.bot.create({
        data: { ...owner, name: "Demo", color: "ink", thread: { create: owner } },
        include: { thread: true },
      });
      const threadId = bot.thread!.id;
      const source = await prisma.message.create({
        data: {
          threadId,
          seq: 0,
          role: "user",
          blocks: [{ kind: "text", text: "Offline example" }],
        },
      });
      await prisma.thread.update({ where: { id: threadId }, data: { nextMessageSeq: 1 } });
      const task = await prisma.task.create({
        data: { ...owner, botId: bot.id, threadId, prompt: "Offline example", status: "running" },
      });
      const run = await prisma.run.create({
        data: {
          ...owner,
          threadId,
          botId: bot.id,
          taskId: task.id,
          status: "running",
          trigger: "user",
          sourceMessageId: source.id,
        },
      });
      context = {
        ...owner,
        botId: bot.id,
        runId: run.id,
        operationId: id,
        traceId: id,
        signal: new AbortController().signal,
      };
      const connection = await prisma.connection.create({
        data: {
          ...owner,
          connectorId: "creative",
          provider: "creative",
          displayName: "Demo",
          status: "pending",
        },
      });
      connectionId = connection.id;
      const config = { ...creativeFixture().config, spaceIds: [owner.spaceId] };
      connector = new CreativeAppConnector(
        config,
        provider,
        { prisma, artifacts: blobs, events: createThreadEvents(prisma) },
        async () => identityA,
        (context) => `test:${context.spaceId}:${context.userId}`,
      );
      const auth = await connector.begin(
        { provider: "creative", redirectUrl: "https://app.example.test" },
        context,
      );
      await prisma.connection.update({
        where: { id: connectionId },
        data: { providerRef: auth.state, status: "connected" },
      });
    }),
  );
  it("claims one automatic connection across concurrent requests and keeps explicit revocation", async () =>
    system(async () => {
      const space = await prisma.space.findUniqueOrThrow({ where: { id: owner.spaceId } });
      const spaceId = `${id}-automatic-space`;
      await prisma.space.create({
        data: { id: spaceId, organizationId: space.organizationId, name: "Automatic fixture" },
      });
      await prisma.spaceMember.create({
        data: {
          id: `${id}-automatic-member`,
          spaceId,
          userId: owner.userId,
          organizationId: space.organizationId,
          role: "owner",
          createdAt: new Date(),
        },
      });
      const automatic = new CreativeAppConnector(
        { ...creativeFixture().config, spaceIds: undefined },
        provider,
        { prisma, artifacts: blobs, events: createThreadEvents(prisma) },
        async () => identityA,
        (context) => `test:${context.spaceId}:${context.userId}`,
      );
      const actor = { ...owner, spaceId };
      const request = { ...context, ...actor };
      await runAsTenant(actor, async () => {
        await Promise.all(Array.from({ length: 4 }, () => automatic.ensureConnection(request)));
        const rows = await prisma.connection.findMany({ where: actor });
        expect(rows).toHaveLength(1);
        expect(rows[0]!.status).toBe("connected");
        await prisma.connection.update({ where: { id: rows[0]!.id }, data: { status: "revoked" } });
        await automatic.ensureConnection(request);
        expect(await prisma.connection.findMany({ where: actor })).toEqual([
          expect.objectContaining({
            id: rows[0]!.id,
            providerRef: rows[0]!.providerRef,
            status: "revoked",
          }),
        ]);
      });
    }));
  afterAll(async () => {
    await prisma.$disconnect();
    await pool.end();
  });

  it("deduplicates concurrent submit/recovery and delivers audio after the chat run completes", async () =>
    runAsTenant(owner, async () => {
      const ref = (await prisma.connection.findUniqueOrThrow({ where: { id: connectionId } }))
        .providerRef!;
      const submit = () =>
        connector.creativeJobs.submit(context, "execution-a", connectionId, ref, musicInput);
      const [first, second] = await Promise.all([submit(), submit()]);
      expect(first.operationId).toBe(second.operationId);
      expect(provider.submit).toHaveBeenCalledTimes(1);
      remoteJob = {
        operationId: first.operationId,
        status: "succeeded",
        outputs: [
          { id: "audio-a", mimeType: "audio/mpeg", name: "Offline example.mp3" },
          { id: "audio-b", mimeType: "audio/mpeg", name: "Second offline example.mp3" },
        ],
      };
      await prisma.run.update({ where: { id: context.runId }, data: { status: "completed" } });
      await Promise.all([
        connector.creativeJobs.poll(first.operationId),
        connector.creativeJobs.poll(first.operationId),
      ]);
      await connector.creativeJobs.poll(first.operationId);
      expect(await prisma.artifact.count({ where: { runId: context.runId } })).toBe(2);
      expect(await prisma.message.count({ where: { runId: context.runId, role: "bot" } })).toBe(2);
      expect(await connector.creativeJobs.result(context, first.operationId, ref)).toMatchObject({
        status: "succeeded",
      });
      expect(provider.submit).toHaveBeenCalledTimes(1);
    }));
  it("recovers a committed attachment after the message transaction fails without downloading again", async () =>
    runAsTenant(owner, async () => {
      await prisma.run.update({ where: { id: context.runId! }, data: { status: "running" } });
      const ref = (await prisma.connection.findUniqueOrThrow({ where: { id: connectionId } }))
        .providerRef!;
      const submitted = await connector.creativeJobs.submit(
        context,
        "execution-save",
        connectionId,
        ref,
        musicInput,
      );
      remoteJob = {
        operationId: submitted.operationId,
        status: "succeeded",
        outputs: [{ id: "__proto__", mimeType: "audio/mpeg", name: "Offline recovery.mp3" }],
      };
      const run = await prisma.run.findUniqueOrThrow({ where: { id: context.runId! } });
      const thread = await prisma.thread.findUniqueOrThrow({ where: { id: run.threadId } });
      // A sequence collision fails the real message transaction after the attachment commits.
      const collision = await prisma.message.create({
        data: {
          threadId: thread.id,
          seq: thread.nextMessageSeq,
          role: "user",
          blocks: [{ kind: "text", text: "Synthetic collision" }],
        },
      });
      await connector.creativeJobs.poll(submitted.operationId);
      const artifactWhere = {
        runId: context.runId,
        clientNonce: { startsWith: `creative:${submitted.operationId}:` },
      };
      expect(await prisma.artifact.count({ where: artifactWhere })).toBe(1);
      expect(
        await prisma.message.count({
          where: { clientNonce: `creative:${submitted.operationId}:__proto__` },
        }),
      ).toBe(0);
      await prisma.message.delete({ where: { id: collision.id } });
      const download = vi
        .spyOn(provider, "output")
        .mockRejectedValue(new CreativeServiceError("unavailable", 503));
      const calls = download.mock.calls.length;
      try {
        await connector.creativeJobs.poll(submitted.operationId);
        expect(download).toHaveBeenCalledTimes(calls);
        expect(await prisma.artifact.count({ where: artifactWhere })).toBe(1);
        expect(
          await prisma.message.count({
            where: { clientNonce: `creative:${submitted.operationId}:__proto__` },
          }),
        ).toBe(1);
        expect(
          await connector.creativeJobs.result(context, submitted.operationId, ref),
        ).toMatchObject({ status: "succeeded" });
      } finally {
        download.mockRestore();
      }
    }));
  it("retains parameter choices through JSONB storage and key-order changes without a second submit", async () =>
    runAsTenant(owner, async () => {
      const ref = (await prisma.connection.findUniqueOrThrow({ where: { id: connectionId } }))
        .providerRef!;
      const directory = vi.spyOn(provider, "capabilities").mockResolvedValueOnce({
        ...capabilities,
        submission: { presetOnly: false, referenceMedia: false },
      });
      const input = {
        kind: "video" as const,
        model: "demo-video",
        preset: "demo-video-default",
        prompt: "Offline parameter example",
        parameters: { resolution: "1080P", seconds: 10, watermark: false, seed: 0 },
      };
      try {
        const calls = vi.mocked(provider.submit).mock.calls.length;
        const first = await connector.creativeJobs.submit(
          context,
          "execution-parameters",
          connectionId,
          ref,
          input,
        );
        const persisted = await prisma.externalEffect.findUniqueOrThrow({
          where: { id: first.operationId },
        });
        expect(persisted.request).toMatchObject({ input });
        const second = await connector.creativeJobs.submit(
          context,
          "execution-parameters",
          connectionId,
          ref,
          { ...input, parameters: { seed: 0, watermark: false, seconds: 10, resolution: "1080P" } },
        );
        expect(second.operationId).toBe(first.operationId);
        expect(vi.mocked(provider.submit).mock.calls.length).toBe(calls + 1);
        expect(directory).toHaveBeenCalledOnce();
      } finally {
        directory.mockRestore();
      }
    }));
  it("commits uploaded reference IDs before submission and restores them without uploading again", async () =>
    runAsTenant(owner, async () => {
      const ref = (await prisma.connection.findUniqueOrThrow({ where: { id: connectionId } }))
        .providerRef!;
      const bytes = new Uint8Array([137, 80, 78, 71]);
      const source = await prisma.artifact.create({
        data: {
          ...owner,
          botId: context.botId!,
          name: "Synthetic reference.png",
          mimeType: "image/png",
          size: bytes.byteLength,
          hash: String(bytes.byteLength),
          storageKey: "synthetic-reference-source",
        },
      });
      const directory = vi.spyOn(provider, "capabilities").mockResolvedValueOnce({
        ...capabilities,
        models: capabilities.models.map((model) => ({
          ...model,
          inputs: { referenceImages: model.kind === "image" },
        })),
        submission: {
          presetOnly: false,
          referenceMedia: true,
          referenceKinds: ["image"],
          maxReferenceImageBytes: 100,
        },
      });
      const read = vi.spyOn(blobs, "get").mockResolvedValue(bytes);
      const uploads = vi.mocked(provider.uploadReference).mock.calls.length;
      try {
        failSubmit = true;
        const first = await connector.creativeJobs.submit(
          context,
          "execution-reference",
          connectionId,
          ref,
          {
            kind: "image",
            model: "demo-image",
            preset: "demo-image-default",
            prompt: "Offline reference example",
            referenceArtifactIds: [source.id],
          },
        );
        const stored = await prisma.externalEffect.findUniqueOrThrow({
          where: { id: first.operationId },
        });
        expect(stored.kind).toBe("creative_media_reference_job");
        const state = stored.result as { submission: { references: string[] } };
        expect(state.submission.references).toHaveLength(1);
        expect(state.submission).not.toHaveProperty("referenceArtifactIds");
        await prisma.artifact.delete({ where: { id: source.id } });
        failSubmit = false;
        await connector.creativeJobs.poll(first.operationId);
        const restored = await prisma.externalEffect.findUniqueOrThrow({
          where: { id: first.operationId },
        });
        expect(restored.result).toMatchObject({ submission: state.submission, accepted: true });
        expect(provider.uploadReference).toHaveBeenCalledTimes(uploads + 1);
        expect(read).toHaveBeenCalledOnce();
        expect(directory).toHaveBeenCalledOnce();
      } finally {
        failSubmit = false;
        read.mockRestore();
        directory.mockRestore();
      }
    }));
  it("persists mixed media kinds, durations and reference order before retrying the original submission", async () =>
    runAsTenant(owner, async () => {
      const ref = (await prisma.connection.findUniqueOrThrow({ where: { id: connectionId } }))
        .providerRef!;
      const sources = await Promise.all(
        ["video", "audio"].map((kind) =>
          prisma.artifact.create({
            data: {
              ...owner,
              botId: context.botId!,
              name: `Synthetic ${kind}`,
              mimeType: kind === "video" ? "video/mp4" : "audio/wav",
              size: 4,
              hash: "4",
              storageKey: `synthetic-${kind}`,
            },
          }),
        ),
      );
      const directory = vi.spyOn(provider, "capabilities").mockResolvedValueOnce({
        ...capabilities,
        models: capabilities.models.map((model) => ({
          ...model,
          inputs: {
            referenceImages: true,
            referenceVideos: model.kind === "video",
            referenceAudios: model.kind === "video",
          },
          constraints:
            model.kind === "video"
              ? { ...model.constraints, referenceSeconds: 1, audioOnly: true }
              : model.constraints,
        })),
        submission: {
          presetOnly: false,
          referenceMedia: true,
          referenceKinds: ["image", "video", "audio"],
          maxReferenceImageBytes: 100,
          maxReferenceMediaBytes: 100,
        },
      });
      const read = vi
        .spyOn(blobs, "get")
        .mockImplementation(
          async (key) => new Uint8Array([key.endsWith("video") ? 0 : 1, 2, 3, 4]),
        );
      const upload = vi
        .spyOn(provider, "uploadReference")
        .mockImplementation(async (_identity, bytes) => {
          const kind = bytes[0] === 0 ? "video" : "audio";
          return {
            id: randomUUID(),
            kind,
            mimeType: kind === "video" ? "video/mp4" : "audio/wav",
            bytes: bytes.byteLength,
            durationMs: 1_000,
          };
        });
      const uploadCalls = upload.mock.calls.length;
      try {
        failSubmit = true;
        const result = await connector.creativeJobs.submit(
          context,
          "execution-mixed-media",
          connectionId,
          ref,
          {
            kind: "video",
            model: "demo-video",
            preset: "demo-video-default",
            prompt: "Offline mixed reference example",
            parameters: { mode: "reference" },
            referenceArtifactIds: sources.map((source) => source.id),
          },
        );
        const saved = await prisma.externalEffect.findUniqueOrThrow({
          where: { id: result.operationId },
        });
        const state = saved.result as {
          referenceTransfers: Record<string, { kind: string; durationMs: number }>;
          submission: { references: string[] };
        };
        expect(
          Object.values(state.referenceTransfers)
            .map((item) => item.kind)
            .sort(),
        ).toEqual(["audio", "video"]);
        expect(Object.values(state.referenceTransfers).map((item) => item.durationMs)).toEqual([
          1_000, 1_000,
        ]);
        expect(state.submission.references).toHaveLength(2);
        failSubmit = false;
        await connector.creativeJobs.poll(result.operationId);
        const restored = await prisma.externalEffect.findUniqueOrThrow({
          where: { id: result.operationId },
        });
        expect(restored.result).toMatchObject({ accepted: true, submission: state.submission });
        expect(upload).toHaveBeenCalledTimes(uploadCalls + 2);
        expect(read).toHaveBeenCalledTimes(2);
        expect(directory).toHaveBeenCalledOnce();
      } finally {
        failSubmit = false;
        upload.mockRestore();
        read.mockRestore();
        directory.mockRestore();
      }
    }));
  it("restores an omitted preset from JSONB without consulting a changed default", async () =>
    runAsTenant(owner, async () => {
      await prisma.run.update({ where: { id: context.runId! }, data: { status: "running" } });
      const ref = (await prisma.connection.findUniqueOrThrow({ where: { id: connectionId } }))
        .providerRef!;
      const { preset: _preset, ...input } = musicInput;
      const directory = vi.spyOn(provider, "capabilities");
      failSubmit = true;
      try {
        const created = await connector.creativeJobs.submit(
          context,
          "omitted-preset",
          connectionId,
          ref,
          input,
        );
        const saved = await prisma.externalEffect.findUniqueOrThrow({
          where: { id: created.operationId },
        });
        const snapshot = (saved.result as { submission: object }).submission;
        expect(saved.request).toMatchObject({ input: musicInput, toolInput: input });
        expect((saved.request as { toolInput: object }).toolInput).not.toHaveProperty("preset");
        directory.mockResolvedValue({
          ...capabilities,
          models: capabilities.models.map((model) =>
            model.kind === "music"
              ? {
                  ...model,
                  presets: [{ id: "changed-default", parameters: {} }],
                  defaultPreset: "changed-default",
                }
              : model,
          ),
        });
        failSubmit = false;
        expect(
          await connector.creativeJobs.submit(context, "omitted-preset", connectionId, ref, input),
        ).toMatchObject({ operationId: created.operationId, status: "queued" });
        const restored = await prisma.externalEffect.findUniqueOrThrow({
          where: { id: created.operationId },
        });
        expect((restored.result as { submission: object }).submission).toEqual(snapshot);
        expect(directory).toHaveBeenCalledOnce();
        const calls = vi
          .mocked(provider.submit)
          .mock.calls.filter((call) => call[1] === created.operationId);
        expect(calls).toHaveLength(2);
        expect(calls.map((call) => call[2])).toEqual([snapshot, snapshot]);
      } finally {
        failSubmit = false;
        directory.mockRestore();
      }
    }));
  it("repairs a stale claim with the persisted operation and stops after disconnect", async () =>
    runAsTenant(owner, async () => {
      failSubmit = true;
      await prisma.run.update({ where: { id: context.runId! }, data: { status: "running" } });
      const ref = (await prisma.connection.findUniqueOrThrow({ where: { id: connectionId } }))
        .providerRef!;
      const created = await connector.creativeJobs.submit(
        context,
        "execution-b",
        connectionId,
        ref,
        musicInput,
      );
      await prisma.externalEffect.update({
        where: { id: created.operationId },
        data: { status: "creative_polling", updatedAt: new Date(Date.now() - 120_000) },
      });
      await connector.creativeJobs.reconcile();
      expect(
        (await prisma.externalEffect.findUniqueOrThrow({ where: { id: created.operationId } }))
          .status,
      ).toBe("creative_pending");
      await prisma.connection.update({ where: { id: connectionId }, data: { status: "revoked" } });
      await expect(connector.creativeJobs.poll(created.operationId)).rejects.toMatchObject({
        code: "forbidden",
      });
      expect(
        (await prisma.externalEffect.findUniqueOrThrow({ where: { id: created.operationId } }))
          .status,
      ).toBe("creative_failed");
    }));
});
