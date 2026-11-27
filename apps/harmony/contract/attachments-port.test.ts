import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { decodeAttachmentBase64 } from "@rakazo/core";
import { sharePreview as mobileSharePreview } from "@rakazo/mobile/lib/composer/share-preview.js";
import { afterAll, expect, it } from "vitest";
import type * as attachments from "../entry/src/main/ets/thread/attachments.ets";
import type * as incomingShare from "../entry/src/main/ets/thread/incoming-share.ets";
import type * as send from "../entry/src/main/ets/thread/thread-send.ets";
import { generateAttachmentsFixture } from "../scripts/gen-attachments-fixtures.ts";

const directory = mkdtempSync(path.join(tmpdir(), "harmony-attachments-"));
afterAll(() => rmSync(directory, { force: true, recursive: true }));

async function load(file: string) {
  const source = readFileSync(
    new URL(`../entry/src/main/ets/thread/${file}.ets`, import.meta.url),
    "utf8",
  );
  const destination = path.join(directory, `${file}.ts`);
  writeFileSync(destination, source.replace("from '../contract/decode'", "from './decode.ts'"));
  return import(pathToFileURL(destination).href);
}

writeFileSync(
  path.join(directory, "decode.ts"),
  "export const asRecord = (value: unknown) => value;\n",
);
const port: typeof attachments = await load("attachments");
const sender: typeof send = await load("thread-send");
const sharing: typeof incomingShare = await load("incoming-share");

it("matches the live mobile and core attachment rules", async () => {
  const fixture = await generateAttachmentsFixture();
  for (const { config, bytes, count } of fixture.limits) {
    expect(port.attachmentMaxBytes(config)).toBe(bytes);
    expect(port.attachmentMaxCount(config)).toBe(count);
  }
  for (const { name, reported, expected } of fixture.inference) {
    expect(port.inferAttachmentMimeType(name, reported), name).toBe(expected);
  }
  for (const entry of fixture.mime) {
    const mime = entry.mimeType;
    expect(
      {
        image: port.isAttachmentImageMimeType(mime),
        audio: port.isAttachmentAudioMimeType(mime),
        inline: port.isInlineImageMimeType(mime),
        kind: port.artifactPreviewKind(mime),
        label: port.artifactTypeLabel(mime),
        extension: port.attachmentExtensionForMimeType(mime),
        storedName: port.attachmentStoredName("probe.original", mime),
      },
      mime,
    ).toEqual({
      image: entry.image,
      audio: entry.audio,
      inline: entry.inline,
      kind: entry.kind,
      label: entry.label,
      extension: entry.extension,
      storedName: entry.storedName,
    });
  }
  for (const { bytes, expected } of fixture.staticPng) {
    expect(port.isStaticPng(Buffer.from(bytes, "base64"))).toBe(expected);
  }
  for (const { bytes, locale, expected } of fixture.fileSize) {
    expect(port.formatFileSize(bytes, locale)).toBe(expected);
  }
  for (const { size, expected } of fixture.fit) {
    expect(port.fitImageSize(size.width, size.height, 270, 360)).toEqual(expected);
  }
  for (const { size, mimeType, existingCount, expected } of fixture.skip) {
    expect(
      port.attachmentSkipReason(
        size,
        mimeType,
        existingCount,
        0,
        port.ATTACHMENT_MAX_BYTES,
        port.ATTACHMENT_MAX_COUNT,
      ),
    ).toBe(expected);
  }
});

it("matches the two mobile send bodies and their server-side attachment blocks", async () => {
  const fixture = await generateAttachmentsFixture();
  const first = fixture.send[0];
  const second = fixture.send[1];
  expect(
    sender.threadSendBody(
      "bot-probe",
      "",
      " Caption ",
      first!.blocks.map((block) => block.artifactId),
      "",
      "nonce-probe",
      false,
    ),
  ).toEqual(first!.calls.at(-1)?.body);
  expect(
    sender.threadSendBody(
      "",
      "group-probe",
      "",
      second!.blocks.map((block) => block.artifactId),
      "message-probe",
      "nonce-probe",
      true,
    ),
  ).toEqual(second!.calls.at(-1)?.body);
});

it("encodes chunk boundaries as one valid base64 payload", () => {
  const source = Buffer.alloc(768 * 1024 + 11);
  for (let index = 0; index < source.length; index += 1) source[index] = index % 251;
  const parts: string[] = [];
  for (let offset = 0; offset < source.length; ) {
    const size = port.uploadChunkSize(source.length - offset);
    parts.push(source.subarray(offset, offset + size).toString("base64"));
    offset += size;
  }
  expect(decodeAttachmentBase64(parts.join(""))).toEqual(new Uint8Array(source));
});

it("keeps ordered share text and distinct file URIs", () => {
  expect(
    sharing.shareContent([
      { content: " first " },
      { content: " " },
      { uri: "file://sender/one.png", name: "one.png" },
      { uri: "file://sender/one.png", name: "alias.png" },
      { uri: "https://example.test/file" },
      { uri: "file://sender/two.txt", name: "two.txt" },
      { content: " https://example.test " },
    ]),
  ).toEqual({
    text: "first\nhttps://example.test",
    files: [
      { uri: "file://sender/one.png", name: "one.png" },
      { uri: "file://sender/two.txt", name: "two.txt" },
    ],
  });
});

it("previews a share like the mobile target picker", () => {
  const share = sharing.shareContent([
    { content: " note " },
    { uri: "file://sender/one.png", name: "one.png", mimeType: "image/png" },
    { uri: "file://sender/two.jpg?x=1", mimeType: "application/octet-stream" },
    { uri: "file://sender/three.heic", name: "three.heic" },
    { uri: "file://sender/four.webp" },
    { uri: "file://sender/my%20five.png" },
    { uri: "file://sender/notes.pdf", name: "notes.pdf", mimeType: "application/pdf" },
  ]);
  expect(share.files.map((file) => file.name)).toEqual([
    "one.png",
    "two.jpg",
    "three.heic",
    "four.webp",
    "my five.png",
    "notes.pdf",
  ]);
  expect(sharing.sharePreview(share)).toEqual(mobileSharePreview(share));
  const several = sharing.shareContent([
    { uri: "file://sender/notes.pdf", name: "notes.pdf" },
    { uri: "file://sender/a.zip", name: "a.zip" },
  ]);
  expect(sharing.sharePreview(several)).toEqual(mobileSharePreview(several));
});
