import { afterEach, beforeAll, beforeEach, describe, expect, it } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { app } from '../../../main/ets/app/app-state';
import { asRecord } from '../../../main/ets/contract/decode';
import { setConsentPrompt } from '../../../main/ets/net/consent';
import { clearArtifactCache, cachedArtifactPath } from '../../../main/ets/net/artifact-cache';
import { getJson, parseJsonObject, postJson } from '../../../main/ets/net/http';
import { RequestCancellation } from '../../../main/ets/net/request-cancellation';
import { rpc } from '../../../main/ets/net/rpc';
import { initServerStore, switchServer } from '../../../main/ets/net/server-store';
import { clearSessionToken, saveSessionToken, setSelectedSpace } from '../../../main/ets/net/session';
import { ThreadStore } from '../../../main/ets/stores/thread-store';
import {
  ATTACHMENT_IMAGE_MAX_EDGE, ATTACHMENT_IMAGE_QUALITY, ATTACHMENT_MAX_BYTES, ATTACHMENT_MAX_COUNT,
  artifactPreviewKind, artifactTypeLabel, attachmentExtensionForMimeType, attachmentMaxBytes, attachmentMaxCount,
  attachmentSkipReason, attachmentStoredName, fitImageSize, formatFileSize, inferAttachmentMimeType,
  isAttachmentAudioMimeType, isAttachmentImageMimeType, isInlineImageMimeType, isStaticPng,
} from '../../../main/ets/thread/attachments';
import type { UploadLimits } from '../../../main/ets/thread/attachments';
import { importAttachmentSources, readDraftBase64, removeTemporaryFile } from '../../../main/ets/thread/attachment-files';
import type { AttachmentSource, DraftAttachment } from '../../../main/ets/thread/attachment-files';
import { shareContent } from '../../../main/ets/thread/incoming-share';
import type { ShareRecord } from '../../../main/ets/thread/incoming-share';
import { decodeThreadSnapshot } from '../../../main/ets/thread/thread-decode';
import { threadSendBody } from '../../../main/ets/thread/thread-send';
import { fixtureAttachments } from './fixtures.generated';
import { recordOf, stableJson } from './test-utils';

const BASE = 'http://10.0.2.2:8787';

function context(): Context {
  return abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext();
}

function records(value: Object): Record<string, Object>[] {
  return value as Record<string, Object>[];
}

function writeSample(path: string, value: string | ArrayBuffer): void {
  try {
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY);
    try {
      fs.writeSync(file.fd, value);
    } finally {
      fs.closeSync(file);
    }
  } catch (err) {
    throw new Error('Could not create the attachment fixture');
  }
}

async function fixture(path: string, body: string): Promise<void> {
  const response = await postJson(`${BASE}/${path}`, {}, body, 8000, 65536);
  expect(response.status).assertEqual(200);
}

async function eventually(condition: () => boolean): Promise<void> {
  const until = Date.now() + 10_000;
  while (!condition()) {
    if (Date.now() > until) {
      throw new Error('Attachment operation did not settle');
    }
    await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 25); });
  }
}

/** A gradient PNG of the given size, as a photo library would hand over. */
async function writePhoto(path: string, width: number, height: number): Promise<void> {
  const pixels = new Uint8Array(width * height * 4);
  for (let index = 0; index < pixels.length; index += 4) {
    pixels[index] = (index / 4) % 256;
    pixels[index + 1] = 64;
    pixels[index + 2] = 128;
    pixels[index + 3] = 255;
  }
  const options: image.InitializationOptions = {
    size: { width: width, height: height }, pixelFormat: image.PixelMapFormat.RGBA_8888,
  };
  const map = await image.createPixelMap(pixels.buffer as ArrayBuffer, options);
  let file: fs.File | null = null;
  try {
    const packer = image.createImagePacker();
    file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY);
    await packer.packToFile(map, file.fd, { format: 'image/png', quality: 100 });
  } catch (err) {
    throw new Error('Could not write the photo sample');
  } finally {
    try {
      if (file !== null) {
        await fs.close(file);
      }
    } catch (err) {
      // The sample is temporary: a failed close changes nothing the test checks.
    }
  }
}

async function photoSize(path: string): Promise<image.Size> {
  const source = image.createImageSource(path);
  try {
    return (await source.getImageInfo()).size;
  } finally {
    await source.release();
  }
}

export default function attachmentsTest() {
  describe('AttachmentFixture', () => {
    it('replays_attachment_rules_from_mobile', 0, () => {
      const data = recordOf(fixtureAttachments);
      const constants = data['constants'] as Record<string, Object>;
      expect(ATTACHMENT_IMAGE_MAX_EDGE).assertEqual(constants['imageMaxEdge']);
      expect(ATTACHMENT_IMAGE_QUALITY).assertEqual(constants['imageQuality']);
      for (const row of records(data['limits'])) {
        const config = row['config'] as UploadLimits | null;
        expect(attachmentMaxBytes(config)).assertEqual(row['bytes']);
        expect(attachmentMaxCount(config)).assertEqual(row['count']);
      }
      for (const row of records(data['mime'])) {
        const mime = row['mimeType'] as string;
        expect(isAttachmentImageMimeType(mime)).assertEqual(row['image']);
        expect(isAttachmentAudioMimeType(mime)).assertEqual(row['audio']);
        expect(isInlineImageMimeType(mime)).assertEqual(row['inline']);
        expect(artifactPreviewKind(mime)).assertEqual(row['kind']);
        expect(artifactTypeLabel(mime)).assertEqual(row['label']);
        expect(attachmentExtensionForMimeType(mime)).assertEqual(row['extension']);
        expect(attachmentStoredName('probe.original', mime)).assertEqual(row['storedName']);
      }
      for (const row of records(data['inference'])) {
        const mime = inferAttachmentMimeType(row['name'] as string, row['reported'] as string);
        expect(mime).assertEqual(row['expected']);
      }
      for (const row of records(data['staticPng'])) {
        const bytes = new util.Base64Helper().decodeSync(row['bytes'] as string);
        expect(isStaticPng(bytes)).assertEqual(row['expected']);
      }
      for (const row of records(data['fileSize'])) {
        expect(formatFileSize(row['bytes'] as number, row['locale'] as string)).assertEqual(row['expected']);
      }
      for (const row of records(data['fit'])) {
        const size = row['size'] as Record<string, Object>;
        const fitted = fitImageSize(size['width'] as number, size['height'] as number, 270, 360);
        expect(stableJson(fitted)).assertEqual(stableJson(row['expected']));
      }
      for (const row of records(data['skip'])) {
        const reason = attachmentSkipReason(row['size'] as number, row['mimeType'] as string | null,
          row['existingCount'] as number, 0, ATTACHMENT_MAX_BYTES, ATTACHMENT_MAX_COUNT);
        expect(reason).assertEqual(row['expected']);
      }
    });

    it('replays_the_mobile_send_envelope_for_bot_and_group', 0, () => {
      const sends = records(recordOf(fixtureAttachments)['send']);
      for (const row of sends) {
        const calls = records(row['calls']);
        const wire = calls[calls.length - 1]['body'] as Record<string, Object>;
        const body = threadSendBody(wire['botId'] as string ?? '', wire['groupId'] as string ?? '',
          wire['text'] as string ?? '', records(row['blocks']).map((block: Record<string, Object>): string =>
            block['artifactId'] as string), wire['replyToMessageId'] as string ?? '',
          wire['clientNonce'] as string, wire['imageHandling'] === 'file', '');
        expect(stableJson(body)).assertEqual(stableJson(wire));
      }
    });

    it('share_preserves_text_and_imports_each_file_uri_once', 0, () => {
      const raw = JSON.parse('[{"content":" first "},{"uri":"file://sender/a.txt"},{"uri":"file://sender/a.txt"},{"uri":"https://example.test/a.txt"},{"uri":"file://sender/b.txt"},{"content":" https://example.test "}]') as ShareRecord[];
      const parsed = shareContent(raw);
      expect(parsed.text).assertEqual('first\nhttps://example.test');
      expect(parsed.files.length).assertEqual(2);
      expect(parsed.files[1].uri).assertEqual('file://sender/b.txt');
    });

    it('imports_and_encodes_across_chunk_boundaries', 0, async () => {
      const env = context();
      const bytes = new Uint8Array(768 * 1024 + 11);
      for (let index = 0; index < bytes.length; index += 1) {
        bytes[index] = index % 251;
      }
      const path = `${env.cacheDir}/attachment-chunks.txt`;
      writeSample(path, bytes.buffer as ArrayBuffer);
      try {
        const source: AttachmentSource = { uri: path, name: 'attachment-chunks.txt' };
        const rejected = await importAttachmentSources(env, [source], false, 0, bytes.length - 1, 1);
        expect(rejected.attachments.length).assertEqual(0);
        expect(rejected.skipped.length).assertEqual(1);
        const accepted = await importAttachmentSources(env, [source], false, 0, bytes.length, 1);
        expect(accepted.skipped.length).assertEqual(0);
        expect(accepted.attachments.length).assertEqual(1);
        try {
          const encoded = await readDraftBase64(accepted.attachments[0], new RequestCancellation());
          expect(encoded === new util.Base64Helper().encodeToStringSync(bytes)).assertTrue();
        } finally {
          removeTemporaryFile(accepted.attachments[0].path);
        }
      } finally {
        removeTemporaryFile(path);
      }
    });

    it('shrinks_a_large_photo_and_copies_a_small_one_unchanged', 0, async () => {
      const env = context();
      const large = `${env.cacheDir}/photo-large.png`;
      const small = `${env.cacheDir}/photo-small.png`;
      await writePhoto(large, 2000, 1000);
      await writePhoto(small, 300, 200);
      const sources: AttachmentSource[] = [
        { uri: large, name: 'photo-large.png' }, { uri: small, name: 'photo-small.png' },
      ];
      try {
        const imported = await importAttachmentSources(env, sources, true, 0, ATTACHMENT_MAX_BYTES,
          ATTACHMENT_MAX_COUNT);
        expect(imported.skipped.length).assertEqual(0);
        expect(imported.attachments.length).assertEqual(2);
        try {
          const shrunk = imported.attachments[0];
          expect(shrunk.mimeType).assertEqual('image/png');
          expect(shrunk.name).assertEqual('photo-large.png');
          const size = await photoSize(shrunk.path);
          expect(size.width).assertEqual(ATTACHMENT_IMAGE_MAX_EDGE);
          expect(size.height).assertEqual(800);
          const kept = imported.attachments[1];
          expect(kept.size).assertEqual(fs.statSync(small).size);
          const keptSize = await photoSize(kept.path);
          expect(keptSize.width).assertEqual(300);
          expect(keptSize.height).assertEqual(200);
        } finally {
          for (const item of imported.attachments) {
            removeTemporaryFile(item.path);
          }
        }
      } finally {
        removeTemporaryFile(large);
        removeTemporaryFile(small);
      }
    });
  });

  describe('AttachmentRpc', () => {
    beforeAll(async () => {
      app.detach();
      await initServerStore(context());
      await switchServer(BASE, {});
    });
    beforeEach(async () => {
      await fixture('__reset', '{}');
      await saveSessionToken('fake-token');
      setSelectedSpace('space-fake');
      setConsentPrompt(async (): Promise<boolean> => true);
    });
    afterEach(async () => {
      setConsentPrompt(null);
      clearArtifactCache(context());
      await clearSessionToken();
    });

    it('retries_a_partial_upload_and_reloads_an_attachment_reply', 0, async () => {
      const env = context();
      const first: DraftAttachment = { path: `${env.cacheDir}/attach-first.txt`, name: 'first.txt', mimeType: 'text/plain', size: 3 };
      const second: DraftAttachment = { path: `${env.cacheDir}/attach-second.txt`, name: 'second.txt', mimeType: 'text/plain', size: 3 };
      writeSample(first.path, 'one');
      writeSample(second.path, 'two');
      const store = new ThreadStore();
      store.open('bot-1', '', 'user-fake');
      try {
        await eventually((): boolean => store.snapshot !== null);
        const parent = store.snapshot!.messages[0];
        await fixture('__artifactControl', '{"failName":"second.txt"}');
        store.sendDraft('', [first, second], parent.id, '');
        await eventually((): boolean => !store.send.pending);
        expect(store.send.error.length > 0).assertTrue();
        await fixture('__artifactControl', '{}');
        store.sendDraft('', [first, second], parent.id, '');
        await eventually((): boolean => !store.send.pending);
        expect(store.sentRevision).assertEqual(1);
        const snap = decodeThreadSnapshot(await rpc('threads/get', recordOf('{"botId":"bot-1"}')));
        const echo = snap!.messages[snap!.messages.length - 1];
        expect(echo.replyToMessageId).assertEqual(parent.id);
        expect(echo.replyPreview?.['text']).assertEqual('hello');
        expect(echo.blocks.length).assertEqual(2);
        const path = await cachedArtifactPath(env, { artifactId: echo.blocks[0]['artifactId'] as string,
          botId: 'bot-1', groupId: '', mimeType: 'text/plain' });
        expect(path.length > 0).assertTrue();
        const log = parseJsonObject((await getJson(`${BASE}/__requests`, {}, 8000, 256 * 1024)).body);
        const uploads = records(log!['requests']).filter((r: Record<string, Object>): boolean => r['path'] === '/rpc/artifacts/create');
        expect(uploads.length).assertEqual(3);
        expect(uploads[1]['body']).assertEqual(uploads[2]['body']);
        // The logged bodies replace the bytes with their length and digest: the replayed upload
        // carried byte-identical content, not just matching metadata.
        const replay = parseJsonObject(uploads[2]['body'] as string);
        const carried = replay !== null ? replay['json'] as Record<string, Object> : null;
        expect(carried !== null && carried!['contentSha256'] !== undefined
          && (carried!['contentSha256'] as string).length > 0).assertTrue();
        expect(carried!['contentBytes']).assertEqual(3);
      } finally {
        store.close();
        removeTemporaryFile(first.path);
        removeTemporaryFile(second.path);
      }
    });

    it('cancels_during_upload_without_sending_and_allows_a_retry', 0, async () => {
      // A multi-megabyte body: the fixture pauses between its chunks, so the transfer is still
      // being written when the composer's cancel arrives (the transport-level cancellation).
      const bytes = new Uint8Array(3 * 768 * 1024 + 5);
      for (let index = 0; index < bytes.length; index += 1) {
        bytes[index] = index % 251;
      }
      const env = context();
      const item: DraftAttachment = { path: `${env.cacheDir}/attach-cancel.txt`, name: 'cancel.txt', mimeType: 'text/plain', size: bytes.length };
      writeSample(item.path, bytes.buffer as ArrayBuffer);
      const store = new ThreadStore();
      store.open('bot-1', '', 'user-fake');
      try {
        await fixture('__artifactControl', '{"slowBody":true}');
        store.sendDraft('Cancel probe', [item], '', '');
        await new Promise<void>((resolve: () => void): void => {
          setTimeout(resolve, 700);
        });
        store.cancelUpload();
        await eventually((): boolean => !store.send.pending);
        expect(store.send.error).assertEqual('');
        expect(store.sentRevision).assertEqual(0);
        const log = await getJson(`${BASE}/__requests`, {}, 8000, 256 * 1024);
        expect(log.body.includes('/rpc/threads/send')).assertFalse();
        await fixture('__artifactControl', '{}');
        store.sendDraft('Cancel probe', [item], '', '');
        await eventually((): boolean => !store.send.pending);
        expect(store.sentRevision).assertEqual(1);
      } finally {
        store.close();
        removeTemporaryFile(item.path);
      }
    });
  });
}
