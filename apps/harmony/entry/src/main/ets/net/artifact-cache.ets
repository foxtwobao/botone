import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { asRecord } from '../contract/decode';
import { currentScope, requestScope } from '../query/query-cache';
import { cleanAttachmentDirectory, removeTemporaryFile, temporaryFileExists } from '../thread/attachment-files';
import { attachmentExtensionForMimeType } from '../thread/attachments';
import { newClientNonce, sendTarget } from '../thread/thread-send';
import { rpc, captureContext } from './rpc';
import { RpcError } from './errors';

const DOWNLOAD_TIMEOUT_MS = 120_000;
const CACHE_BUDGET = 64 * 1024 * 1024;
let namespace = newClientNonce();

export interface ArtifactRef {
  botId: string;
  groupId: string;
  artifactId: string;
  mimeType: string;
}

interface CacheFile {
  path: string;
  size: number;
}

const cache = new Map<string, CacheFile>();
const inflight = new Map<string, Promise<string>>();
let cacheBytes = 0;

function cacheDirectory(context: Context): string {
  return `${context.cacheDir}/artifact-previews`;
}

/** Clears old bytes at launch and on every session or Space change. */
export function clearArtifactCache(context: Context): void {
  namespace = newClientNonce();
  cache.clear();
  inflight.clear();
  cacheBytes = 0;
  cleanAttachmentDirectory(cacheDirectory(context));
}

function rememberFile(key: string, path: string, size: number): void {
  cache.set(key, { path: path, size: size });
  cacheBytes += size;
  for (const entry of cache) {
    const oldest = entry[0];
    const file = entry[1];
    if (cacheBytes <= CACHE_BUDGET || oldest === key) {
      break;
    }
    cache.delete(oldest);
    cacheBytes -= file.size;
    removeTemporaryFile(file.path);
  }
}

async function download(context: Context, ref: ArtifactRef, scope: string, epoch: string,
  key: string): Promise<string> {
  const pinned = await captureContext();
  if (requestScope(pinned) !== scope || currentScope() !== scope || epoch !== namespace
    || !pinned.headers['authorization'] || (!ref.groupId && !ref.botId)) {
    throw new RpcError('ARTIFACT_SESSION_CHANGED');
  }
  const input = sendTarget(ref.botId, ref.groupId);
  input['artifactId'] = ref.artifactId;
  const record = asRecord(await rpc('artifacts/get', input, { context: pinned, timeoutMs: DOWNLOAD_TIMEOUT_MS }));
  const content = record?.['contentBase64'];
  const size = record?.['size'];
  if (record?.['id'] !== ref.artifactId || typeof content !== 'string' || !content || typeof size !== 'number'
    || content.length !== Math.ceil((size as number) / 3) * 4) {
    throw new RpcError('Unexpected response from the server');
  }
  const bytes = await new util.Base64Helper().decode(content as string);
  if (epoch !== namespace || currentScope() !== scope || bytes.byteLength !== size) {
    throw new RpcError('Unexpected response from the server');
  }
  const root = `${cacheDirectory(context)}/${epoch}`;
  const extension = attachmentExtensionForMimeType(ref.mimeType.split(';')[0].trim().toLowerCase());
  const path = `${root}/${newClientNonce()}${extension}`;
  try {
    if (!fs.accessSync(root)) {
      fs.mkdirSync(root, true);
    }
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
    try {
      if (fs.writeSync(file.fd, bytes.buffer as ArrayBuffer, { length: bytes.byteLength }) !== size) {
        throw new RpcError('Incomplete attachment download');
      }
    } finally {
      fs.closeSync(file);
    }
  } catch (err) {
    removeTemporaryFile(path);
    throw err as Error;
  }
  // Only a complete write joins the in-memory index. A process restart sweeps partial files.
  rememberFile(key, path, size as number);
  return path;
}

/** Equal scoped reads share a file and an in-flight request, without holding bytes in UI state. */
export async function cachedArtifactPath(context: Context, ref: ArtifactRef): Promise<string> {
  const scope = currentScope();
  const epoch = namespace;
  const key = JSON.stringify([scope, ref.botId, ref.groupId, ref.artifactId, ref.mimeType]);
  const cached = cache.get(key);
  if (cached !== undefined) {
    cache.delete(key);
    if (temporaryFileExists(cached.path)) {
      cache.set(key, cached);
      return cached.path;
    }
    cacheBytes -= cached.size;
  }
  const existing = inflight.get(key);
  if (existing !== undefined) {
    return existing;
  }
  const request = download(context, ref, scope, epoch, key);
  inflight.set(key, request);
  try {
    return await request;
  } finally {
    if (inflight.get(key) === request) {
      inflight.delete(key);
    }
  }
}
