// The outbox on disk (B3): one JSON per nonce under <filesDir>/outbox/, each send's attachments
// beside it as <nonce>/<index>. cacheDir is swept at launch, so drafts move here before the
// upload starts: a crash mid-send leaves the message recoverable. Records are written through a
// .tmp + rename so a kill never leaves a half record; a file that fails validation is deleted
// alone and the rest survive. Limits come from mobile (outbox-record.ets pins the source).
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { OutboxAttachment, OUTBOX_MAX_BYTES, OUTBOX_MAX_ENTRIES, parseOutboxRecord } from './outbox-record';
import type { OutboxRecord } from './outbox-record';
import type { DraftAttachment } from '../thread/attachment-files';

function root(context: Context): string {
  return `${context.filesDir}/outbox`;
}

function recordFile(context: Context, nonce: string): string {
  return `${root(context)}/${nonce}.json`;
}

function nonceFolder(context: Context, nonce: string): string {
  return `${root(context)}/${nonce}`;
}

function attachmentFile(context: Context, nonce: string, index: number): string {
  return `${nonceFolder(context, nonce)}/${index}`;
}

function exists(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch (err) {
    return false;
  }
}

function drop(path: string): void {
  // A leftover a later load retries must not block the outbox (mobile deleteLeftover).
  try {
    fs.unlinkSync(path);
  } catch (err) {
  }
}

function ensureDir(path: string): void {
  try {
    if (!exists(path)) {
      fs.mkdirSync(path, true);
    }
  } catch (err) {
    // The caller's next write fails with the real error; this only reports the mkdir.
    throw new Error('Could not create the outbox folder');
  }
}

/** The names in a directory, or none when the directory is unreadable. */
function names(dir: string): string[] {
  try {
    return fs.listFileSync(dir);
  } catch (err) {
    return [];
  }
}

/** Every byte the outbox holds, except a .tmp a concurrent save still owns. */
function diskBytes(context: Context): number {
  const dir = root(context);
  if (!exists(dir)) {
    return 0;
  }
  let total = 0;
  for (const name of names(dir)) {
    if (name.endsWith('.tmp')) {
      continue;
    }
    const path = `${dir}/${name}`;
    try {
      const stat = fs.statSync(path);
      total += stat.isDirectory() ? diskBytesIn(path) : stat.size;
    } catch (err) {
      // A file removed between the list and the stat counts as gone.
    }
  }
  return total;
}

function diskBytesIn(dir: string): number {
  let total = 0;
  for (const name of names(dir)) {
    try {
      total += fs.statSync(`${dir}/${name}`).size;
    } catch (err) {
    }
  }
  return total;
}

/** Throws 'Too many unsent messages' when one more record would pass the entry cap. Run it
 *  before any draft file moves: a refused park must leave the composer untouched. */
export function ensureAdmitted(context: Context, nonce: string): void {
  const dir = root(context);
  if (!exists(dir)) {
    return;
  }
  let entries = 0;
  for (const name of names(dir)) {
    if (name.endsWith('.json') && name !== `${nonce}.json`) {
      entries += 1;
    }
  }
  if (entries + 1 > OUTBOX_MAX_ENTRIES) {
    throw new Error('Too many unsent messages');
  }
}

/**
 * Writes the record atomically (.tmp + rename), refusing the save when the queue is over its
 * entry or byte budget. Throws 'Too many unsent messages' past 20 entries; other throws mean
 * the disk refused and the caller falls back to the in-memory path. Call it after
 * moveAttachments: the budget counts the whole outbox tree, attachments included.
 */
export function saveRecord(context: Context, record: OutboxRecord): void {
  const dir = root(context);
  const text = JSON.stringify(record);
  let entries = 0;
  let previousBytes = 0;
  for (const name of names(dir)) {
    if (!name.endsWith('.json')) {
      continue;
    }
    if (name === `${record.nonce}.json`) {
      try {
        previousBytes = fs.statSync(`${dir}/${name}`).size;
      } catch (err) {
      }
      continue;
    }
    entries += 1;
  }
  if (entries + 1 > OUTBOX_MAX_ENTRIES) {
    throw new Error('Too many unsent messages');
  }
  if (diskBytes(context) - previousBytes + text.length > OUTBOX_MAX_BYTES) {
    throw new Error('Outbox full');
  }
  ensureDir(dir);
  const tmp = `${recordFile(context, record.nonce)}.tmp`;
  const final = recordFile(context, record.nonce);
  try {
    const file = fs.openSync(tmp, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY);
    try {
      fs.writeSync(file.fd, text);
    } finally {
      fs.closeSync(file);
    }
    fs.renameSync(tmp, final);
  } catch (err) {
    drop(tmp);
    throw new Error('Could not write the unsent message');
  }
}

/** The committed records; a file that fails validation is deleted alone, and so is a record
 *  whose attachment files are gone — it could never be retried, only hang as a dead bubble. */
export function loadRecords(context: Context): OutboxRecord[] {
  const dir = root(context);
  const records: OutboxRecord[] = [];
  const jsons: string[] = [];
  for (const name of names(dir)) {
    if (name.endsWith('.json')) {
      jsons.push(name);
    }
  }
  jsons.sort();
  for (const name of jsons) {
    const path = `${dir}/${name}`;
    let parsed: OutboxRecord | null = null;
    try {
      parsed = parseOutboxRecord(JSON.parse(fs.readTextSync(path)) as Object);
    } catch (err) {
      parsed = null;
    }
    if (parsed === null) {
      hilog.warn(0, 'Outbox', 'Dropping an unreadable unsent message');
      drop(path);
      continue;
    }
    if (!attachmentsIntact(parsed)) {
      hilog.warn(0, 'Outbox', 'Dropping an unsent message whose attachments are gone');
      removeRecord(context, parsed.nonce);
      continue;
    }
    records.push(parsed);
  }
  return records.slice(0, OUTBOX_MAX_ENTRIES);
}

/** True when every attachment file a record points at is still on disk. */
function attachmentsIntact(record: OutboxRecord): boolean {
  for (const attachment of record.attachments) {
    if (!exists(attachment.path)) {
      return false;
    }
  }
  return true;
}

/** The launch sweep (bootstrap, before any restore): a nonce folder whose record never landed
 *  (a crash between the attachment move and the record write) and a .tmp a killed save left
 *  behind can never be retried — delete them so they cannot pile up. Records with missing
 *  attachment files are dropped by loadRecords instead: a readable record deserves its warning. */
export function sweepOutbox(context: Context): void {
  const dir = root(context);
  if (!exists(dir)) {
    return;
  }
  for (const name of names(dir)) {
    const path = `${dir}/${name}`;
    if (name.endsWith('.tmp')) {
      drop(path);
      continue;
    }
    try {
      if (fs.statSync(path).isDirectory() && !exists(recordFile(context, name))) {
        fs.rmdirSync(path);
      }
    } catch (err) {
      // A folder that cannot go yet is left for the next launch.
    }
  }
}

/** Removes one record and its attachments; a folder that cannot go yet is left to clearAll. */
export function removeRecord(context: Context, nonce: string): void {
  drop(recordFile(context, nonce));
  try {
    if (exists(nonceFolder(context, nonce))) {
      fs.rmdirSync(nonceFolder(context, nonce));
    }
  } catch (err) {
    hilog.warn(0, 'Outbox', 'Could not remove the unsent attachments folder');
  }
}

/**
 * Moves the composer's draft files into the record's folder and points both the record and the
 * live drafts at the new paths, so the running upload reads them from the outbox. A throw after
 * some files moved leaves those drafts pointing at their new homes — the upload still reads them.
 */
export function moveAttachments(context: Context, record: OutboxRecord,
  drafts: DraftAttachment[]): void {
  ensureDir(root(context));
  ensureDir(nonceFolder(context, record.nonce));
  const attachments: OutboxAttachment[] = [];
  for (let index = 0; index < drafts.length; index += 1) {
    const draft = drafts[index];
    const target = attachmentFile(context, record.nonce, index);
    try {
      fs.moveFileSync(draft.path, target);
    } catch (err) {
      throw new Error('Could not move an attachment into the outbox');
    }
    draft.path = target;
    const attachment = new OutboxAttachment();
    attachment.path = target;
    attachment.name = draft.name;
    attachment.mimeType = draft.mimeType;
    attachment.size = draft.size;
    attachments.push(attachment);
  }
  record.attachments = attachments;
  const ids: string[] = [];
  for (let index = 0; index < drafts.length; index += 1) {
    ids.push('');
  }
  record.artifactIds = ids;
}

/** A cancelled attempt gives the drafts back: files return to the composer's paths, the record
 *  goes. A file already gone (a failed undo) leaves the rest to the launch sweep. */
export function unparkAttachments(context: Context, record: OutboxRecord,
  drafts: DraftAttachment[], originalPaths: string[]): void {
  for (let index = 0; index < drafts.length && index < originalPaths.length; index += 1) {
    const draft = drafts[index];
    if (draft.path !== originalPaths[index] && exists(draft.path)) {
      try {
        fs.moveFileSync(draft.path, originalPaths[index]);
      } catch (err) {
        hilog.warn(0, 'Outbox', 'Could not return an attachment to the composer');
      }
    }
    draft.path = originalPaths[index];
  }
  removeRecord(context, record.nonce);
}

/** Everything the outbox holds, disk and memory paths both gone. */
export function clearAll(context: Context): void {
  try {
    if (exists(root(context))) {
      fs.rmdirSync(root(context));
    }
  } catch (err) {
    hilog.warn(0, 'Outbox', 'Could not clear the outbox');
  }
}

/** True while any record file exists — the sign-out prompt reads this, not the memory queue. */
export function hasAnyRecord(context: Context): boolean {
  const dir = root(context);
  if (!exists(dir)) {
    return false;
  }
  let found = false;
  for (const name of names(dir)) {
    if (name.endsWith('.json')) {
      found = true;
    }
  }
  return found;
}
