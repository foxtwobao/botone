// B2 (M12): the camera capture's own contract, over a scripted picker — the capability gate that
// answers nothing, the cancel that leaves no capture file behind, and the success that hands the
// ordinary attachment import a JPEG source. The real system picker needs a camera the emulator
// does not have; its saveUri contract (the shot lands in the sandbox file, never the gallery) is
// the documented platform behavior and is walked through on a real device.
import { afterEach, describe, expect, it } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { cameraPicker } from '@kit.CameraKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { importAttachmentSources, removeTemporaryFile, temporaryFileExists } from
  '../../../main/ets/thread/attachment-files';
import type { AttachmentSource } from '../../../main/ets/thread/attachment-files';
import { ATTACHMENT_MAX_BYTES, ATTACHMENT_MAX_COUNT } from '../../../main/ets/thread/attachments';
import { capturePhoto, setCameraCapabilityForTest, setCameraPickerForTest } from
  '../../../main/ets/thread/camera-capture';
import type { CameraPick } from '../../../main/ets/thread/camera-capture';

/** A picker that records its call, optionally writes the shot into the saveUri file, and answers
 *  with the given result code (0 success, -1 cancel). */
function fakePick(resultCode: number, bytes: Uint8Array | null, calls: string[],
  seenUris: string[]): CameraPick {
  return (context: Context, mediaTypes: cameraPicker.PickerMediaType[],
    profile: cameraPicker.PickerProfile): Promise<cameraPicker.PickerResult> => {
    calls.push('pick');
    seenUris.push(profile.saveUri ?? '');
    if (bytes !== null) {
      const path = new fileUri.FileUri(profile.saveUri ?? '').path;
      const file = fs.openSync(path, fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, bytes.buffer as ArrayBuffer);
      } finally {
        fs.closeSync(file);
      }
    }
    const result: cameraPicker.PickerResult = {
      resultCode: resultCode, resultUri: profile.saveUri ?? '',
      mediaType: cameraPicker.PickerMediaType.PHOTO,
    };
    return Promise.resolve(result);
  };
}

export default function cameraCaptureTest() {
  describe('CameraCapture', () => {
    afterEach(() => {
      setCameraCapabilityForTest(null);
      setCameraPickerForTest(null);
    });

    it('answers_null_without_the_camera_and_without_calling_the_picker', 0, async () => {
      const calls: string[] = [];
      setCameraCapabilityForTest(false);
      setCameraPickerForTest(fakePick(0, null, calls, []));
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext();
      const source = await capturePhoto(context);
      expect(source === null).assertTrue();
      expect(calls.length).assertEqual(0);
    });

    it('a_picker_that_throws_lets_the_error_rise_and_still_cleans_up', 0, async () => {
      const calls: string[] = [];
      const seenUris: string[] = [];
      setCameraCapabilityForTest(true);
      setCameraPickerForTest((context: Context, mediaTypes: cameraPicker.PickerMediaType[],
        profile: cameraPicker.PickerProfile): Promise<cameraPicker.PickerResult> => {
        calls.push('pick');
        seenUris.push(profile.saveUri ?? '');
        return Promise.reject(new Error('picker wedge'));
      });
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext();
      let thrown: string = '';
      try {
        await capturePhoto(context);
      } catch (err) {
        thrown = (err as Error).message;
      }
      expect(thrown.length > 0).assertTrue();
      expect(calls.length).assertEqual(1);
      const capturePath = new fileUri.FileUri(seenUris[0]).path;
      expect(temporaryFileExists(capturePath)).assertFalse();
    });

    it('a_cancelled_shot_leaves_no_capture_file_behind', 0, async () => {
      const calls: string[] = [];
      const seenUris: string[] = [];
      setCameraCapabilityForTest(true);
      setCameraPickerForTest(fakePick(-1, null, calls, seenUris));
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext();
      const source = await capturePhoto(context);
      expect(source === null).assertTrue();
      expect(calls.length).assertEqual(1);
      expect(seenUris.length).assertEqual(1);
      const capturePath = new fileUri.FileUri(seenUris[0]).path;
      expect(seenUris[0].startsWith('file://')).assertTrue();
      expect(temporaryFileExists(capturePath)).assertFalse();
    });

    it('a_successful_shot_returns_a_jpeg_source_the_attachment_import_reads', 0, async () => {
      const bytes = new Uint8Array(72);
      for (let index = 0; index < bytes.length; index += 1) {
        bytes[index] = index * 3;
      }
      const calls: string[] = [];
      const seenUris: string[] = [];
      setCameraCapabilityForTest(true);
      setCameraPickerForTest(fakePick(0, bytes, calls, seenUris));
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext();
      const source = await capturePhoto(context);
      expect(source !== null).assertTrue();
      const photo = source as AttachmentSource;
      expect(photo.mimeType).assertEqual('image/jpeg');
      expect((photo.name ?? '').startsWith('photo-')).assertTrue();
      expect(photo.name?.endsWith('.jpg') ?? false).assertTrue();
      const capturePath = new fileUri.FileUri(photo.uri).path;
      expect(temporaryFileExists(capturePath)).assertTrue();
      expect(fs.statSync(capturePath).size).assertEqual(bytes.length);
      try {
        // The capture joins the composer through the ordinary import, like a library photo.
        const imported = await importAttachmentSources(context, [photo], true, 0, ATTACHMENT_MAX_BYTES,
          ATTACHMENT_MAX_COUNT);
        expect(imported.skipped.length).assertEqual(0);
        expect(imported.attachments.length).assertEqual(1);
        expect(imported.attachments[0].mimeType).assertEqual('image/jpeg');
        expect(imported.attachments[0].size).assertEqual(bytes.length);
        removeTemporaryFile(imported.attachments[0].path);
      } finally {
        removeTemporaryFile(capturePath);
      }
    });
  });
}