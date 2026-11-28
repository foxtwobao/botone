// The outbox port's differential check (B3): the pure record module (record shape, validation,
// failure classification, limits) against the layer-2 fixture the generator records from the
// replicated mobile logic (mobile thread-feedback.ts:434-447). The device-side replay runs under
// hypium in Outbox.test.ets.
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { afterAll, expect, it } from "vitest";
import type * as record from "../entry/src/main/ets/outbox/outbox-record.ets";
import { generateOutboxFixture } from "../scripts/gen-outbox-fixtures.ts";

const directory = mkdtempSync(path.join(tmpdir(), "harmony-outbox-"));
afterAll(() => rmSync(directory, { force: true, recursive: true }));

async function load(file: string) {
  const source = readFileSync(
    new URL(`../entry/src/main/ets/outbox/${file}.ets`, import.meta.url),
    "utf8",
  );
  const destination = path.join(directory, `${file}.ts`);
  writeFileSync(destination, source);
  return import(pathToFileURL(destination).href);
}

const port: typeof record = await load("outbox-record");

it("matches the mobile limits the fixture pins", async () => {
  const fixture = await generateOutboxFixture();
  expect(port.OUTBOX_MAX_ENTRIES).toBe(fixture.constants.maxEntries);
  expect(port.OUTBOX_MAX_BYTES).toBe(fixture.constants.maxBytes);
  expect(fixture.constants.maxEntries).toBe(20);
  expect(fixture.constants.maxBytes).toBe(50 * 1024 * 1024);
});

it("classifies send failures exactly as the mobile fixture recorded", async () => {
  const fixture = await generateOutboxFixture();
  expect(fixture.classify.length).toBeGreaterThan(10);
  for (const row of fixture.classify) {
    expect(
      port.classifySendFailure(row.status, row.transport, row.timedOut, row.message),
      row.name,
    ).toBe(row.expected);
  }
  // The sentinels the port's RpcError carries behave like mobile's: no status at all is
  // retryable, never refused.
  expect(port.classifySendFailure(0, false, false, "")).toBe("failed");
  expect(port.classifySendFailure(0, false, false, "Connect a model to start a run.")).toBe(
    "failed",
  );
});

it("parses a record field by field and rejects a broken one whole", () => {
  const base = {
    v: 1,
    nonce: "nonce-probe_1",
    apiBase: "http://server.test",
    userId: "user-fake",
    spaceId: "space-fake",
    botId: "bot-1",
    groupId: "",
    text: "hello",
    replyToMessageId: "",
    replyQuote: "",
    imageHandling: "confirm",
    artifactIds: ["artifact-1", ""],
    attachments: [
      { path: "/data/outbox/nonce-probe_1/0", name: "a.png", mimeType: "image/png", size: 3 },
    ],
    state: "queued",
    error: "",
    imageConfirmation: false,
  };
  const parsed = port.parseOutboxRecord(base);
  expect(parsed).not.toBeNull();
  expect(parsed?.nonce).toBe("nonce-probe_1");
  expect(parsed?.artifactIds).toEqual(["artifact-1", ""]);
  expect(parsed?.attachments.length).toBe(1);
  expect(parsed?.attachments[0]?.size).toBe(3);
  // The fields a record cannot survive without; the descriptive ones (text, quote, botId…)
  // default to "" by design, and spaceId/botId/groupId may be empty strings.
  for (const key of [
    "v",
    "nonce",
    "apiBase",
    "userId",
    "state",
    "imageHandling",
    "artifactIds",
    "attachments",
    "imageConfirmation",
  ] as const) {
    const broken: Record<string, unknown> = { ...base };
    broken[key] = key === "v" ? 2 : Array.isArray(base[key]) ? "x" : null;
    expect(port.parseOutboxRecord(broken as object), key).toBeNull();
  }
  // The nonce is the only filename on disk: bounded to safe characters, like mobile's load.
  const named: Record<string, unknown> = { ...base, nonce: "../escape" };
  expect(port.parseOutboxRecord(named)).toBeNull();
});
