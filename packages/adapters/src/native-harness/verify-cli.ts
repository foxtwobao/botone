import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdtemp, readFile, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { pathToFileURL } from "node:url";
import type {
  NativeExecutionControl,
  NativeExecutionStart,
  NativeSessionRef,
} from "@rakazo/adapter-kit";
import { nativeHarnessDriver } from "./catalog.js";
import { launchComputerHarness } from "./computer-process.js";
import { resolveComputerTarget } from "./computer-target.js";
import { engineVersions, readDaemonConfiguration } from "./configuration.js";
import { verifyComputerIsolation } from "./inspection.js";
import { managedComputerProfiles } from "./managed-profiles.js";
import { NativeHarnessExecutionService } from "./service.js";
import { verificationBinding, verificationChecks } from "./verification.js";

/** Opt-in real account verification. Assertions concern effects and protocol, never prose quality. */
export async function verifyNativeCli(file: string, profileId: string) {
  const configuration = await readDaemonConfiguration(file);
  const managed = configuration.managed?.verification;
  const profile = managed
    ? (await managedComputerProfiles(configuration, managed)).find(
        (profile) => profile.engine === profileId,
      )
    : configuration.profiles.find((profile) => profile.id === profileId);
  if (!profile) throw new Error("unknown_profile");
  const version = engineVersions[profile.engine];
  const nonce = randomUUID();
  const root = await mkdtemp(path.join(configuration.root, "v-"));
  const request = (prompt: string, session?: NativeSessionRef): NativeExecutionStart => ({
    runId: randomUUID(),
    fence: 1,
    leaseExpiresAt: new Date(Date.now() + 240_000).toISOString(),
    scope: {
      spaceId: profile.spaceId,
      userId: profile.userIds[0]!,
      botId: `verification-${nonce}`,
      threadId: `verification-${nonce}`,
      computerId: profile.computerId,
      profileId: profile.id,
      revision: profile.revision,
    },
    prompt,
    instructions:
      "This is an explicit opt-in execution verification. Use only the specified verification files. Do not access accounts or other files.",
    session,
    model: profile.defaultModel ?? profile.modelConnection?.model,
  });
  const computer = await resolveComputerTarget(profile.computer, request("inspection").scope);
  const workspace = computer.workspace;
  const home = computer.source;
  await verifyComputerIsolation(profile, request("isolation"), root);
  const service = new NativeHarnessExecutionService(root, [
    {
      ...profile,
      engineVersion: version,
      driver: await nativeHarnessDriver(profile.engine),
      launch: (input) => launchComputerHarness(profile, input, root),
    },
  ]);
  let session: NativeSessionRef | undefined;
  const turn = async (
    prompt: string,
    policy: "allow" | "deny",
    stopWhen?: () => Promise<boolean>,
  ) => {
    const input = request(prompt, session);
    let snapshot = await service.start(input);
    const control: NativeExecutionControl = { ...input, generation: snapshot.generation };
    let sequence = 0,
      permissions = 0;
    let confirmedSession = false;
    const deadline = Date.now() + 180_000;
    while (Date.now() < deadline) {
      for (const frame of snapshot.frames) {
        sequence = frame.sequence;
        const event = frame.event;
        if (event.type === "session") {
          confirmedSession = true;
          if (session) assert.equal(event.session.id, session.id);
          session = event.session;
        } else if (event.type === "interaction") {
          assert.equal(
            event.request.kind,
            "permission",
            "verification_requires_only_permission_requests",
          );
          permissions++;
          await service.respond({ ...control, requestId: event.request.id, answer: policy });
        } else if (event.type === "failed" || event.type === "cancelled")
          throw new Error("verification_turn_failed");
        else if (event.type === "completed") {
          assert(confirmedSession, "native_session_not_confirmed");
          return { permissions };
        }
      }
      if (stopWhen && (await stopWhen())) {
        assert(confirmedSession, "native_session_not_confirmed");
        await service.stop(control);
        const stopped = await service.attach({
          ...control,
          after: sequence,
          leaseExpiresAt: input.leaseExpiresAt,
        });
        assert.equal(stopped.frames.at(-1)?.event.type, "cancelled");
        return { permissions };
      }
      await delay(100);
      snapshot = await service.attach({
        ...control,
        after: sequence,
        leaseExpiresAt: new Date(Date.now() + 240_000).toISOString(),
      });
    }
    await service.stop(control);
    throw new Error("verification_timeout");
  };
  const created = `execution-${nonce}.txt`,
    resumed = `resumed-${nonce}.txt`,
    denied = `denied-${nonce}.txt`,
    counter = `counter-${nonce}.txt`;
  try {
    const creation = await turn(
      `Create /workspace/${created} containing exactly ${nonce}. Perform the write now.`,
      "allow",
    );
    if (profile.engine === "codex") assert.equal(creation.permissions, 0);
    assert.equal((await readFile(path.join(workspace, created), "utf8")).trim(), nonce);
    assert(session);
    const continuation = await turn(
      `Continue this native session. Copy /workspace/${created} to /workspace/${resumed}.`,
      "allow",
    );
    if (profile.engine === "codex") assert.equal(continuation.permissions, 0);
    assert.equal((await readFile(path.join(workspace, resumed), "utf8")).trim(), nonce);
    const deniedPath = profile.engine === "codex" ? `/etc/${denied}` : `${computer.home}/${denied}`;
    const refusal = await turn(
      profile.engine === "deepseek"
        ? `Use the bash tool to execute: printf '%s' '${nonce}' > '${deniedPath}'. This is outside the workspace: set sandbox_permissions to danger-full-access and justification to "Verify denial of a test file write". If permission is refused, stop immediately; do not try another tool or method.`
        : `Create ${deniedPath} containing exactly ${nonce}. Perform the write now. If a tool permission is refused, stop immediately; do not try another tool or method.`,
      "deny",
    );
    if (profile.engine === "codex") assert.equal(refusal.permissions, 0);
    else assert(refusal.permissions > 0, "engine_did_not_request_permission");
    assert.equal(
      await stat(
        profile.engine === "codex"
          ? path.join(`/proc/${computer.pid}/root`, "etc", denied)
          : path.join(home, denied),
      ).then(
        () => true,
        () => false,
      ),
      false,
    );
    let began = false;
    await turn(
      `Run a foreground shell loop that updates /workspace/${counter} with a new timestamp every 0.1 seconds for 90 seconds. Start it now and wait for it.`,
      "allow",
      async () => {
        began = await stat(path.join(workspace, counter)).then(
          () => true,
          () => false,
        );
        return began;
      },
    );
    assert(began, "cancellation_effect_not_observed");
    const before = await readFile(path.join(workspace, counter), "utf8");
    await delay(500);
    assert.equal(await readFile(path.join(workspace, counter), "utf8"), before);
    if (managed && configuration.managed)
      await writeFile(
        path.join(configuration.root, `runtime-${profile.engine}.json`),
        JSON.stringify({
          runtimeRevision: configuration.managed.runtimeRevision,
          version,
          managed: true,
          checks: verificationChecks,
        }),
        { mode: 0o600 },
      );
    await writeFile(
      path.join(configuration.root, `verified-${profile.id}.json`),
      JSON.stringify({
        version,
        revision: profile.revision,
        binding: verificationBinding(profile),
        checks: verificationChecks,
      }),
      { mode: 0o600 },
    );
  } finally {
    await service.close();
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (process.argv[4] !== "--allow-workspace-test")
    throw new Error(
      "Explicit --allow-workspace-test is required; real account calls may be billed",
    );
  await verifyNativeCli(process.argv[2] ?? "", process.argv[3] ?? "");
  process.stdout.write(
    "Execution verification passed. Managed environments refresh automatically.\n",
  );
}
