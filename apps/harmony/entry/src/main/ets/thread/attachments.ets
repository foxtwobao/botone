// Attachment rules ported from the real reference modules (layer-2 fixture-aligned):
// packages/contracts/src/threads/attachments.ts (limits, mime tables, artifactPreviewKind),
// packages/core/src/messages/attachments.ts (inferAttachmentMimeType aliases, extension maps,
// stored name, static-PNG sniff), packages/core/src/primitives/format-file-size.ts. The port keeps
// the reference's decisions value-for-value; fixtures/attachments.json pins both sides.

export const ATTACHMENT_MAX_BYTES = 10 * 1024 * 1024;
export const ATTACHMENT_MAX_COUNT = 4;
export const ATTACHMENT_COUNT_CEILING = 100;
export const ARTIFACT_NAME_MAX_LENGTH = 255;
export const ATTACHMENT_IMAGE_MAX_EDGE = 1600;
export const ATTACHMENT_IMAGE_QUALITY = 0.7;
/** Base64 expands 4/3; cap the payload before any decode work. */
export const ATTACHMENT_MAX_BASE64_LENGTH = Math.ceil(ATTACHMENT_MAX_BYTES / 3) * 4;
/** Local read size: align non-final chunks to a 3-byte group before encoding their Base64. */
export function uploadChunkSize(remainingBytes: number): number {
  const maximum = 768 * 1024;
  return remainingBytes <= maximum ? remainingBytes : Math.floor(maximum / 3) * 3;
}

const IMAGE_MIME_TYPES: string[] = ['image/jpeg', 'image/png', 'image/webp', 'image/gif'];
const AUDIO_MIME_TYPES: string[] = [
  'audio/mpeg', 'audio/wav', 'audio/ogg', 'audio/mp4',
];
const ARCHIVE_MIME_TYPES: string[] = [
  'application/zip', 'application/vnd.rar', 'application/x-7z-compressed',
];
const FILE_MIME_TYPES: string[] = [
  ...AUDIO_MIME_TYPES,
  'video/mp4', 'video/quicktime', 'video/3gpp',
  'image/heic', 'image/heif',
  'application/pdf', 'text/plain', 'text/markdown', 'text/csv',
  'application/vnd.ms-excel',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'text/html', 'application/json',
  ...ARCHIVE_MIME_TYPES,
];
const ALLOWED_MIME_TYPES: string[] = [...IMAGE_MIME_TYPES, ...FILE_MIME_TYPES];

const TEXT_APPLICATION_MIME_TYPES: Set<string> = new Set<string>([
  'application/json', 'application/xml', 'application/yaml', 'application/x-yaml',
  'application/javascript', 'application/x-sh', 'application/sql',
]);

function inList(list: string[], value: string): boolean {
  for (const item of list) {
    if (item === value) {
      return true;
    }
  }
  return false;
}

export function isAttachmentImageMimeType(mimeType: string): boolean {
  return inList(IMAGE_MIME_TYPES, mimeType);
}

export function isAttachmentAudioMimeType(mimeType: string): boolean {
  return inList(AUDIO_MIME_TYPES, mimeType);
}

export function isAllowedAttachmentMimeType(mimeType: string): boolean {
  return inList(ALLOWED_MIME_TYPES, mimeType);
}

/** How a saved file previews, on every client the same way (contracts artifactPreviewKind). */
export function artifactPreviewKind(mimeType: string): string {
  const type = mimeType.split(';')[0]?.trim().toLowerCase() ?? '';
  if (type === 'text/html') {
    return 'html';
  }
  if (type === 'text/markdown') {
    return 'markdown';
  }
  if (type === 'application/pdf') {
    return 'pdf';
  }
  if (isAttachmentImageMimeType(type)) {
    return 'image';
  }
  if (type === 'video/mp4') {
    return 'video';
  }
  if (type.startsWith('text/') || TEXT_APPLICATION_MIME_TYPES.has(type)) {
    return 'text';
  }
  return 'none';
}

/** Effective per-file/per-message limits from me (older servers keep the defaults). */
export interface UploadLimits {
  maxUploadSizeBytes?: number;
  maxAttachmentsPerMessage?: number;
}

export function attachmentMaxBytes(config?: UploadLimits | null): number {
  return config?.maxUploadSizeBytes ?? ATTACHMENT_MAX_BYTES;
}

export function attachmentMaxCount(config?: UploadLimits | null): number {
  return Math.min(config?.maxAttachmentsPerMessage ?? ATTACHMENT_MAX_COUNT, ATTACHMENT_COUNT_CEILING);
}

export function attachmentSizeLabel(maxBytes: number): string {
  return `${maxBytes / (1024 * 1024)} MiB`;
}

export interface ImageSize {
  width: number;
  height: number;
}

export function fitImageSize(width: number, height: number, maxWidth: number, maxHeight: number): ImageSize {
  const naturalWidth = Math.max(1, width);
  const naturalHeight = Math.max(1, height);
  const scale = Math.min(1, maxWidth / naturalWidth, maxHeight / naturalHeight);
  return { width: Math.max(1, Math.round(naturalWidth * scale)), height: Math.max(1, Math.round(naturalHeight * scale)) };
}

export function isInlineImageMimeType(mimeType: string): boolean {
  const type = mimeType.split(';')[0].trim().toLowerCase();
  return type.startsWith('image/') && type !== 'image/svg+xml';
}

const EXTENSION_MIME_TYPES: Record<string, string> = {
  '.mp3': 'audio/mpeg', '.wav': 'audio/wav', '.ogg': 'audio/ogg', '.m4a': 'audio/mp4',
  '.mp4': 'video/mp4', '.mov': 'video/quicktime', '.3gp': 'video/3gpp',
  '.heic': 'image/heic', '.heif': 'image/heif',
  '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png',
  '.webp': 'image/webp', '.gif': 'image/gif',
  '.pdf': 'application/pdf', '.txt': 'text/plain', '.md': 'text/markdown',
  '.markdown': 'text/markdown', '.csv': 'text/csv',
  '.xls': 'application/vnd.ms-excel',
  '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  '.html': 'text/html', '.htm': 'text/html', '.json': 'application/json',
  '.zip': 'application/zip', '.rar': 'application/vnd.rar', '.7z': 'application/x-7z-compressed',
};

const MIME_TYPE_EXTENSIONS: Record<string, string> = {};
for (const extension of Object.keys(EXTENSION_MIME_TYPES)) {
  const mimeType = EXTENSION_MIME_TYPES[extension];
  if (MIME_TYPE_EXTENSIONS[mimeType] === undefined) {
    MIME_TYPE_EXTENSIONS[mimeType] = extension;
  }
}

/** Short file-type badge, as a file's extension reads ("TXT", "MD", "PDF"). */
export function artifactTypeLabel(mimeType: string): string {
  const extension = attachmentExtensionForMimeType(mimeType);
  if (extension !== '') {
    return extension.slice(1).toUpperCase();
  }
  const slash = mimeType.indexOf('/');
  return (slash === -1 ? mimeType : mimeType.slice(slash + 1)).toUpperCase().slice(0, 6);
}

/** The server-side extension map for allowed mimes; "" when the type is not allowed. */
export function attachmentExtensionForMimeType(mimeType: string): string {
  return isAllowedAttachmentMimeType(mimeType) ? MIME_TYPE_EXTENSIONS[mimeType] ?? '' : '';
}

const ARCHIVE_ALIASES: Record<string, string> = {
  'application/x-zip-compressed': 'application/zip',
  'application/x-zip': 'application/zip',
  'multipart/x-zip': 'application/zip',
  'application/x-rar-compressed': 'application/vnd.rar',
  'application/x-rar': 'application/vnd.rar',
  'application/rar': 'application/vnd.rar',
  'application/x-7z': 'application/x-7z-compressed',
};

const AUDIO_ALIASES: Record<string, string> = {
  'audio/mp3': 'audio/mpeg',
  'audio/x-wav': 'audio/wav',
  'audio/wave': 'audio/wav',
  'audio/vnd.wave': 'audio/wav',
  'audio/x-m4a': 'audio/mp4',
};

/** The mime a name/reported pair settles on (core inferAttachmentMimeType); null when none. */
export function inferAttachmentMimeType(name: string, reportedType?: string): string | null {
  if (reportedType && Object.keys(ARCHIVE_ALIASES).includes(reportedType)) {
    return ARCHIVE_ALIASES[reportedType];
  }
  if (reportedType && Object.keys(AUDIO_ALIASES).includes(reportedType)) {
    return AUDIO_ALIASES[reportedType];
  }
  const dot = name.lastIndexOf('.');
  const extensionType = dot < 0 ? undefined : EXTENSION_MIME_TYPES[name.slice(dot).toLowerCase()];
  if (extensionType === 'text/markdown' && (!reportedType || reportedType === 'text/plain')) {
    return extensionType;
  }
  if (extensionType === 'text/csv' && reportedType === 'application/vnd.ms-excel') {
    return extensionType;
  }
  if (reportedType !== undefined && isAllowedAttachmentMimeType(reportedType)) {
    return reportedType;
  }
  return extensionType ?? null;
}

const OFFICE_MIME_TYPES: Set<string> = new Set<string>([
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation',
]);

/** An Office file is stored under its type's own extension (core attachmentStoredName). */
export function attachmentStoredName(name: string, mimeType: string): string {
  if (!OFFICE_MIME_TYPES.has(mimeType)) {
    return name;
  }
  const extension = attachmentExtensionForMimeType(mimeType);
  if (name.toLowerCase().endsWith(extension)) {
    return name;
  }
  const dot = name.lastIndexOf('.');
  const stem = dot > 0 ? name.slice(0, dot) : name;
  return `${stem}${extension}`;
}

/** Only re-encode a PNG whose header confirms it is static (core isStaticPng). */
export const PNG_ANIMATION_HEADER_BYTES = 64 * 1024;

export function isStaticPng(bytes: Uint8Array): boolean {
  if (bytes.length < 33) {
    return false;
  }
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  for (let index = 0; index < signature.length; index += 1) {
    if (bytes[index] !== signature[index]) {
      return false;
    }
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const typeAt = (offset: number): string => String.fromCharCode(
    bytes[offset + 4], bytes[offset + 5], bytes[offset + 6], bytes[offset + 7]);
  if (view.getUint32(8) !== 13 || typeAt(8) !== 'IHDR') {
    return false;
  }
  const end = Math.min(bytes.length, PNG_ANIMATION_HEADER_BYTES);
  let offset = 33;
  while (offset + 8 <= end) {
    const type = typeAt(offset);
    if (type === 'acTL' || type === 'IEND') {
      return false;
    }
    if (type === 'IDAT') {
      return true;
    }
    const next = offset + 12 + view.getUint32(offset);
    if (next > end) {
      return false;
    }
    offset = next;
  }
  return false;
}

const FILE_SIZE_UNITS: string[] = ['B', 'KB', 'MB', 'GB', 'TB'];

/** Core formatFileSize/fileSizeParts: the amount and unit of a file size, localised decimal. */
export function formatFileSize(bytes: number, locale: string = 'en'): string {
  if (!Number.isFinite(bytes) || bytes < 0) {
    return '';
  }
  let value = bytes;
  let unit = 0;
  while (unit < FILE_SIZE_UNITS.length - 1 && value >= 1024) {
    value /= 1024;
    unit += 1;
  }
  if (unit === 0) {
    return `${Math.round(value)} B`;
  }
  let rounded = Math.round(value * 10) / 10;
  if (rounded >= 1024 && unit < FILE_SIZE_UNITS.length - 1) {
    rounded = Math.round((rounded / 1024) * 10) / 10;
    unit += 1;
  }
  const options: Intl.NumberFormatOptions = { maximumFractionDigits: 1, useGrouping: false };
  return `${new Intl.NumberFormat(locale, options).format(rounded)} ${FILE_SIZE_UNITS[unit]}`;
}

/** Why a candidate cannot become an attachment, or '' when it can (mobile filter). */
export function attachmentSkipReason(size: number, mimeType: string | null,
  existingCount: number, acceptedCount: number, maxBytes: number, maxCount: number): string {
  if (existingCount + acceptedCount >= maxCount) {
    return `max ${maxCount} attachments`;
  }
  if (size > maxBytes) {
    return `over ${attachmentSizeLabel(maxBytes)}`;
  }
  if (mimeType === null) {
    return 'unsupported type';
  }
  return '';
}
