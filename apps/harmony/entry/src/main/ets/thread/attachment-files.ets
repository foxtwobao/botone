import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import type { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import type { RequestCancellation } from '../net/request-cancellation';
import { RpcError } from '../net/errors';
import { currentScope } from '../query/query-cache';
import { t } from '../i18n/i18n';
import { newClientNonce } from './thread-send';
import {
  ARTIFACT_NAME_MAX_LENGTH, ATTACHMENT_IMAGE_MAX_EDGE, ATTACHMENT_IMAGE_QUALITY,
  attachmentExtensionForMimeType, attachmentSkipReason, inferAttachmentMimeType,
  isStaticPng, PNG_ANIMATION_HEADER_BYTES, uploadChunkSize,
} from './attachments';

export interface AttachmentSource {
  uri: string;
  name?: string;
  mimeType?: string;
}

export interface DraftAttachment {
  path: string;
  name: string;
  mimeType: string;
  size: number;
}

interface ImportResult {
  attachments: DraftAttachment[];
  skipped: string[];
}

export async function pickAttachmentSources(context: common.UIAbilityContext, photos: boolean,
  room: number): Promise<AttachmentSource[]> {
  let uris: string[] = [];
  try {
    if (photos) {
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = room;
      uris = (await new photoAccessHelper.PhotoViewPicker().select(options)).photoUris;
    } else {
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = room;
      uris = await new picker.DocumentViewPicker(context).select(options);
    }
  } catch (err) {
    throw new Error(t('Could not attach files'));
  }
  return uris.map((uri: string): AttachmentSource => ({ uri: uri }));
}

export function draftDirectory(context: Context): string {
  return `${context.cacheDir}/attachment-drafts`;
}

export function removeTemporaryFile(path: string): void {
  try {
    fs.unlinkSync(path);
  } catch (err) {
    // Cache eviction can race cleanup. The cold-start sweep also clears leftover files.
    hilog.debug(0, 'Attachments', 'Temporary attachment already gone or could not be removed');
  }
}

export function temporaryFileExists(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch (err) {
    return false;
  }
}

export function cleanAttachmentDirectory(path: string): void {
  try {
    if (fs.accessSync(path)) {
      fs.rmdirSync(path);
    }
  } catch (err) {
    hilog.warn(0, 'Attachments', 'Could not clear temporary attachments');
  }
}

function pickIssue(name: string, reason: string): string {
  const values: Record<string, string | number> = {};
  values['name'] = name;
  if (reason.startsWith('over ')) {
    values['limit'] = reason.slice(5);
    return t('{name} (over {limit})', values);
  }
  if (reason.startsWith('max ')) {
    values['count'] = Number(reason.split(' ')[1]);
    return t('{name} (max {count} attachments)', values);
  }
  return reason === 'unsupported type'
    ? t('{name} (unsupported type)', values) : t('{name} (could not read)', values);
}

/**
 * '' keeps the photo as it is; a MIME type is the converted file; null is a photo that had to be
 * converted (HEIC, HEIF, an unknown type) and could not be, which is reported as unsupported
 * rather than sent in a form most viewers cannot open (mobile prepareImage).
 */
async function preparePhoto(file: fs.File, output: string, mimeType: string): Promise<string | null> {
  if (mimeType === 'image/gif' || mimeType === 'image/webp') {
    return '';
  }
  let source: image.ImageSource | null = null;
  const convert = mimeType === 'image/heic' || mimeType === 'image/heif' || !mimeType;
  try {
    source = image.createImageSource(file.fd);
    const info = await source.getImageInfo();
    const longest = Math.max(info.size.width, info.size.height);
    if (longest <= ATTACHMENT_IMAGE_MAX_EDGE && !convert) {
      return '';
    }
    if (mimeType === 'image/png') {
      const header = new ArrayBuffer(PNG_ANIMATION_HEADER_BYTES);
      const size = await fs.read(file.fd, header, { offset: 0 });
      if (!isStaticPng(new Uint8Array(header, 0, size))) {
        return '';
      }
    }
    const scale = Math.min(1, ATTACHMENT_IMAGE_MAX_EDGE / longest);
    const desiredSize: image.Size = {
      width: Math.max(1, Math.round(info.size.width * scale)),
      height: Math.max(1, Math.round(info.size.height * scale)),
    };
    const encodedType = mimeType === 'image/png' ? 'image/png' : 'image/jpeg';
    const map = await source.createPixelMap({ desiredSize: desiredSize });
    try {
      const packer = image.createImagePacker();
      try {
        const dest = await fs.open(output, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY);
        try {
          await packer.packToFile(map, dest.fd, { format: encodedType, quality: ATTACHMENT_IMAGE_QUALITY * 100 });
        } finally {
          await closeFile(dest);
        }
      } finally {
        await packer.release();
      }
    } finally {
      await map.release();
    }
    return encodedType;
  } catch (err) {
    return convert ? null : '';
  } finally {
    await source?.release();
  }
}

/** Copies one bounded batch into the sandbox before the picker/share grant can expire. */
export async function importAttachmentSources(context: Context, sources: AttachmentSource[], photos: boolean,
  existingCount: number, maxBytes: number, maxCount: number): Promise<ImportResult> {
  const scope = currentScope();
  const attachments: DraftAttachment[] = [];
  const skipped: string[] = [];
  for (const item of sources) {
    if (scope !== currentScope()) {
      break;
    }
    let name = item.name?.trim() || t(photos ? 'Photo' : 'File');
    let output = '';
    let kept = false;
    try {
      name = (item.name || new fileUri.FileUri(item.uri).name || name).slice(0, ARTIFACT_NAME_MAX_LENGTH).trim() || name;
      if (existingCount + attachments.length >= maxCount) {
        skipped.push(pickIssue(name, attachmentSkipReason(0, null, existingCount, attachments.length,
          maxBytes, maxCount)));
        continue;
      }
      let mimeType = inferAttachmentMimeType(name, item.mimeType);
      const source = await fs.open(item.uri, fs.OpenMode.READ_ONLY);
      try {
        const stat = await fs.stat(source.fd);
        if (!stat.isFile() || !Number.isSafeInteger(stat.size) || stat.size <= 0) {
          skipped.push(pickIssue(name, 'could not read'));
          continue;
        }
        const dir = draftDirectory(context);
        if (!fs.accessSync(dir)) {
          fs.mkdirSync(dir, true);
        }
        output = `${dir}/${newClientNonce()}`;
        let size = stat.size;
        let converted = '';
        if (photos) {
          const prepared = await preparePhoto(source, output, mimeType ?? '');
          if (prepared === null) {
            skipped.push(pickIssue(name, 'unsupported type'));
            continue;
          }
          converted = prepared;
        }
        if (converted) {
          mimeType = converted;
          size = (await fs.stat(output)).size;
          const stem = name.replace(/\.[^./\\]+$/, '') || t('Photo');
          name = `${stem.slice(0, ARTIFACT_NAME_MAX_LENGTH - 4)}${attachmentExtensionForMimeType(converted)}`;
        }
        const issue = attachmentSkipReason(size, mimeType, existingCount, attachments.length, maxBytes, maxCount);
        if (issue || !mimeType || size <= 0) {
          skipped.push(pickIssue(name, issue || 'could not read'));
          continue;
        }
        if (!converted) {
          await copyDraft(source.fd, output, size);
        }
        if (scope === currentScope()) {
          attachments.push({ path: output, name: name, mimeType: mimeType, size: size });
          kept = true;
        }
      } finally {
        await closeFile(source);
      }
    } catch (err) {
      skipped.push(pickIssue(name, 'could not read'));
    } finally {
      if (output && !kept) {
        removeTemporaryFile(output);
      }
    }
  }
  if (scope !== currentScope()) {
    for (const item of attachments) {
      removeTemporaryFile(item.path);
    }
    return { attachments: [], skipped: [] };
  }
  return { attachments: attachments, skipped: skipped };
}

async function copyDraft(source: number, path: string, size: number): Promise<void> {
  let dest: fs.File | null = null;
  try {
    fs.lseek(source, 0, fs.WhenceType.SEEK_SET);
    dest = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY);
    const buffer = new ArrayBuffer(Math.min(size, 1024 * 1024));
    let copied = 0;
    while (copied < size) {
      const count = await fs.read(source, buffer, { length: Math.min(buffer.byteLength, size - copied) });
      if (count <= 0 || await fs.write(dest.fd, buffer, { length: count }) !== count) {
        throw new Error('Incomplete attachment copy');
      }
      copied += count;
    }
  } catch (err) {
    throw new Error('Incomplete attachment copy');
  } finally {
    await closeFile(dest);
  }
}

async function closeFile(file: fs.File | null): Promise<void> {
  try {
    if (file !== null) {
      await fs.close(file);
    }
  } catch (err) {
    hilog.warn(0, 'Attachments', 'Could not close an attachment file');
  }
}

/** Each non-final read is a multiple of three, so the RPC's one Base64 string has one final pad. */
export async function readDraftBase64(attachment: DraftAttachment, cancellation: RequestCancellation): Promise<string> {
  let file: fs.File | null = null;
  const encoder = new util.Base64Helper();
  const parts: string[] = [];
  try {
    file = await fs.open(attachment.path, fs.OpenMode.READ_ONLY);
    let remaining = attachment.size;
    while (remaining > 0) {
      cancellation.check();
      const buffer = new ArrayBuffer(uploadChunkSize(remaining));
      let filled = 0;
      while (filled < buffer.byteLength) {
        const read = new ArrayBuffer(buffer.byteLength - filled);
        const count = await fs.read(file.fd, read);
        if (count <= 0) {
          throw new RpcError(t('Could not attach files'));
        }
        new Uint8Array(buffer).set(new Uint8Array(read, 0, count), filled);
        filled += count;
      }
      parts.push(await encoder.encodeToString(new Uint8Array(buffer)));
      remaining -= filled;
    }
    cancellation.check();
    return parts.join('');
  } catch (err) {
    cancellation.check();
    throw new Error(t('Could not attach files'));
  } finally {
    await closeFile(file);
  }
}
