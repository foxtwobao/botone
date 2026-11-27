// Differential check for the quote surface (B1): the quote sheet's selectable text against the
// real mobile conversion, the reply-quote cap against contracts, the send body against the
// mobile sender's own, and — the guarantee the sheet exists for — every segment the port offers
// found again in its parent message by the REAL server rule (deriveMessageQuote). A miss here
// means a quote selection would silently send a plain reply.
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import type { MessageBlock } from "@rakazo/contracts";
import { REPLY_QUOTE_MAX_LENGTH } from "@rakazo/contracts";
import { deriveMessageQuote, MAX_QUOTABLE_SOURCE_LENGTH } from "@rakazo/core/message-quote";
import { afterAll, expect, it } from "vitest";
import type * as quote from "../entry/src/main/ets/thread/message-quote.ets";
import type * as send from "../entry/src/main/ets/thread/thread-send.ets";
import { generateQuoteFixture } from "../scripts/gen-quote-fixtures.ts";

const directory = mkdtempSync(path.join(tmpdir(), "harmony-quote-"));
afterAll(() => rmSync(directory, { force: true, recursive: true }));

function copy(file: string): string {
  const source = readFileSync(
    new URL(`../entry/src/main/ets/thread/${file}.ets`, import.meta.url),
    "utf8",
  );
  const destination = path.join(directory, `${file}.ts`);
  writeFileSync(destination, source.replace(/from '\.\/([a-z.-]+?)'/g, "from './$1.ts'"));
  return pathToFileURL(destination).href;
}

const quoteFile = copy("message-quote");
copy("markdown-plain");
const port: typeof quote = await import(quoteFile);
const sendFile = path.join(directory, "thread-send.ts");
writeFileSync(
  sendFile,
  readFileSync(
    new URL("../entry/src/main/ets/thread/thread-send.ets", import.meta.url),
    "utf8",
  ).replace("from '../contract/decode'", "from './decode.ts'"),
);
writeFileSync(
  path.join(directory, "decode.ts"),
  "export const asRecord = (value: unknown) => value;\n",
);
const sender: typeof send = await import(pathToFileURL(sendFile).href);

function blocksOf(value: unknown): MessageBlock[] {
  return value as MessageBlock[];
}

it("replays the mobile conversion the sheet shows, word for word", async () => {
  const fixture = await generateQuoteFixture();
  expect(port.REPLY_QUOTE_MAX_LENGTH).toBe(REPLY_QUOTE_MAX_LENGTH);
  expect(port.REPLY_QUOTE_MAX_LENGTH).toBe(fixture.constants.replyQuoteMaxLength);
  expect(port.MAX_QUOTABLE_SOURCE_LENGTH).toBe(MAX_QUOTABLE_SOURCE_LENGTH);
  expect(port.MAX_QUOTABLE_SOURCE_LENGTH).toBe(fixture.constants.maxQuotableSourceLength);
  for (const entry of fixture.segments) {
    expect(port.quotableMessageSegments(entry.role, blocksOf(entry.blocks)), entry.name).toEqual(
      entry.expected,
    );
  }
});

it("caps a quote exactly as the contract does", async () => {
  const fixture = await generateQuoteFixture();
  for (const entry of fixture.truncate) {
    expect(port.truncateReplyQuote(entry.value), `${entry.value.length} chars`).toBe(
      entry.expected,
    );
  }
});

it("offers a quote only when the sheet would have text", async () => {
  const fixture = await generateQuoteFixture();
  for (const entry of fixture.hasQuotable) {
    expect(port.hasQuotableText(entry.role, blocksOf(entry.blocks)), entry.name).toBe(
      entry.expected,
    );
  }
});

it("sends the quoted excerpt in the mobile sender's body", async () => {
  const fixture = await generateQuoteFixture();
  for (const entry of fixture.send) {
    expect(
      sender.threadSendBody(
        entry.botId,
        entry.groupId,
        entry.text,
        [],
        entry.replyToMessageId,
        entry.clientNonce,
        entry.imagesAsFiles,
        entry.replyQuote,
      ),
      entry.name,
    ).toEqual(entry.body);
  }
});

it("offers only selections the server can find in the quoted message", async () => {
  const fixture = await generateQuoteFixture();
  for (const entry of fixture.quotes) {
    const role = entry.role;
    const blocks = blocksOf(entry.blocks);
    const segments = port.quotableMessageSegments(role, blocks);
    // The fixture's own list is the reference behavior (real mobile conversion + real server
    // rule); the port may render a segment differently but must keep every one locatable.
    expect(segments.length, entry.name).toBe(entry.expected.length);
    for (let index = 0; index < segments.length; index += 1) {
      const segment = segments[index] ?? "";
      expect(segment.trim(), `${entry.name} segment ${index}`).not.toBe("");
      const derived = deriveMessageQuote(
        blocks,
        segment,
        role === "user" ? "plain-text" : "markdown",
      );
      expect(derived, `${entry.name} segment ${index}: ${JSON.stringify(segment)}`).toBeTruthy();
    }
  }
});
