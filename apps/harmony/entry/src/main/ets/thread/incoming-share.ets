import { inferAttachmentMimeType } from './attachments';

export interface ShareRecord {
  uri?: string;
  content?: string;
  name?: string;
  mimeType?: string;
}

export interface SharedFile {
  uri: string;
  /** Always set, as on mobile: the sender's name, else the last path segment, else "file". */
  name: string;
  mimeType?: string;
}

export interface ShareContent {
  text: string;
  files: SharedFile[];
}

export interface SharePreview {
  text: string;
  images: SharedFile[];
  extraImages: number;
  fileCount: number;
  /** The name when there is exactly one file, else null. */
  fileName: string | null;
}

export const SHARE_MAX_AGE_MS = 5 * 60 * 1000;

function pathName(uri: string): string {
  const path = uri.split(/[?#]/, 1)[0] ?? '';
  const segment = path.slice(path.lastIndexOf('/') + 1);
  try {
    return decodeURIComponent(segment);
  } catch (err) {
    return segment;
  }
}

/** A source URI is imported once per share even if it appeared in several UTD records. */
export function shareContent(records: ShareRecord[]): ShareContent {
  const seen = new Set<string>();
  const files: SharedFile[] = [];
  const text: string[] = [];
  for (const record of records) {
    const uri = record.uri;
    if (uri) {
      if (uri.startsWith('file://') && !seen.has(uri)) {
        seen.add(uri);
        files.push({ uri: uri, name: record.name?.trim() || pathName(uri) || 'file', mimeType: record.mimeType });
      }
    } else if (record.content?.trim()) {
      text.push(record.content.trim());
    }
  }
  return { text: text.join('\n'), files: files };
}

/** What the target picker shows (mobile share-preview): source URIs, never a copied or read file. */
export function sharePreview(share: ShareContent): SharePreview {
  const images: SharedFile[] = [];
  const files: SharedFile[] = [];
  for (const file of share.files) {
    const mimeType = file.mimeType && file.mimeType !== 'application/octet-stream'
      ? file.mimeType
      : inferAttachmentMimeType(file.name)
        ?? inferAttachmentMimeType(file.uri.split(/[?#]/, 1)[0] ?? '');
    (mimeType?.startsWith('image/') ? images : files).push(file);
  }
  return {
    text: share.text,
    images: images.slice(0, 4),
    extraImages: Math.max(0, images.length - 4),
    fileCount: files.length,
    fileName: files.length === 1 ? files[0].name : null,
  };
}
