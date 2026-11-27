// The camera entry (M12 B2): one photograph through the system camera picker, straight into a
// sandbox draft file. The picker's UI is the system's own, so no camera permission is asked (the
// CameraPicker guide names none); saveUri keeps the photo out of the user's media library —
// without it the shot would land in the gallery. Mobile's takePhoto is the reference: one photo,
// no video, a cancel answers nothing. The photo then joins the composer through the ordinary
// attachment import (attachment-files), which shrinks and bounds it like any photo from the
// library.
import { camera, cameraPicker } from '@kit.CameraKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { t } from '../i18n/i18n';
import { newClientNonce } from './thread-send';
import { draftDirectory, removeTemporaryFile } from './attachment-files';
import type { AttachmentSource } from './attachment-files';

/** cameraPicker.pick behind a test seam; the real one has exactly this signature. */
export type CameraPick = (context: Context, mediaTypes: cameraPicker.PickerMediaType[],
  profile: cameraPicker.PickerProfile) => Promise<cameraPicker.PickerResult>;

let pickForTest: CameraPick | null = null;
let capableForTest: boolean | null = null;

/** A test photographs through this pick; null restores the system picker. */
export function setCameraPickerForTest(pick: CameraPick | null): void {
  pickForTest = pick;
}

/** A test answers the camera capability here; null reads the device again. */
export function setCameraCapabilityForTest(capable: boolean | null): void {
  capableForTest = capable;
}

/** Whether this device can photograph at all: the composer hides the Camera entry without it. */
export function cameraCaptureAvailable(): boolean {
  return capableForTest ?? canIUse('SystemCapability.Multimedia.Camera.Core');
}

/** Photographs one photo into a sandbox draft through the system camera picker. Null is a device
 *  without the camera or a cancel; a throw is a failure the composer reports as its attach error.
 *  The captured file stays behind for the attachment import, and the caller removes it
 *  (removeTemporaryFile) once the import has read it. */
export async function capturePhoto(context: Context): Promise<AttachmentSource | null> {
  if (!cameraCaptureAvailable()) {
    return null;
  }
  const dir = draftDirectory(context);
  const path = `${dir}/${newClientNonce()}.jpg`;
  try {
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY);
    fs.closeSync(file);
    const profile: cameraPicker.PickerProfile = {
      cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK,
      saveUri: fileUri.getUriFromPath(path),
    };
    const pick: CameraPick = pickForTest ?? cameraPicker.pick;
    const result = await pick(context, [cameraPicker.PickerMediaType.PHOTO], profile);
    if (result.resultCode !== 0) {
      removeTemporaryFile(path);
      return null;
    }
    const source: AttachmentSource = { uri: path, name: `photo-${Date.now()}.jpg`, mimeType: 'image/jpeg' };
    return source;
  } catch (err) {
    removeTemporaryFile(path);
    throw new Error(t('Could not attach files'));
  }
}