// The disk outbox against the fixture server (B3): the record round-trip and its validation,
// the account-scoped restore, the entry cap, the dropped-response recovery with the original
// nonce (the fixture deduplicates sends by clientNonce like the real server), the partial-upload
// replay, the failure classifications, the memory fallback when the disk refuses, the open-time
// replay of queued entries, and the sign-out wipe.
import { afterEach, beforeAll, beforeEach, describe, expect, it } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { app } from '../../../main/ets/app/app-state';
import { setConsentPrompt } from '../../../main/ets/net/consent';
import { clearArtifactCache } from '../../../main/ets/net/artifact-cache';
import { getJson, parseJsonObject, postJson } from '../../../main/ets/net/http';
import { rpc } from '../../../main/ets/net/rpc';
import { initServerStore, switchServer } from '../../../main/ets/net/server-store';
import { clearSessionToken, saveSessionToken, setSelectedSpace } from '../../../main/ets/net/session';
import { signOut } from '../../../main/ets/net/auth';
import { ThreadStore } from '../../../main/ets/stores/thread-store';
import { outbox } from '../../../main/ets/outbox/outbox';
import { hasAnyRecord, loadRecords, removeRecord, saveRecord, sweepOutbox } from '../../../main/ets/outbox/outbox-disk';
import { OutboxRecord } from '../../../main/ets/outbox/outbox-record';
import type { DraftAttachment } from '../../../main/ets/thread/attachment-files';
import { temporaryFileExists } from '../../../main/ets/thread/attachment-files';
import { decodeThreadSnapshot } from '../../../main/ets/thread/thread-decode';
import { recordOf } from './test-utils';

const BASE = 'http://10.0.2.2:8787';

function context(): Context {
  return abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext();
}

async function fixture(path: string, body: string): Promise<void> {
  const response = await postJson(`${BASE}/${path}`, {}, body, 8000, 65536);
  expect(response.status).assertEqual(200);
}

async function eventually(condition: () => boolean): Promise<void> {
  const until = Date.now() + 15_000;
  while (!condition()) {
    if (Date.now() > until) {
      throw new Error('Outbox operation did not settle');
    }
    await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 25); });
  }
}

function writeSample(path: string, value: string): void {
  try {
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY);
    try {
      fs.writeSync(file.fd, value);
    } finally {
      fs.closeSync(file);
    }
  } catch (err) {
    throw new Error('Could not create the outbox fixture');
  }
}

function draft(path: string, name: string, size: number): DraftAttachment {
  const item: DraftAttachment = { path: path, name: name, mimeType: 'text/plain', size: size };
  return item;
}

function makeRecord(nonce: string, apiBase: string, userId: string, spaceId: string): OutboxRecord {
  const record = new OutboxRecord();
  record.nonce = nonce;
  record.apiBase = apiBase;
  record.userId = userId;
  record.spaceId = spaceId;
  record.botId = 'bot-1';
  record.groupId = '';
  record.text = `unsent ${nonce}`;
  return record;
}

async function requests(): Promise<Record<string, Object>[]> {
  const log = parseJsonObject((await getJson(`${BASE}/__requests`, {}, 8000, 256 * 1024)).body);
  const all = log !== null && Array.isArray(log['requests']) ? log['requests'] as Object[] : [];
  const rows: Record<string, Object>[] = [];
  for (const item of all) {
    rows.push(item as Record<string, Object>);
  }
  return rows;
}

function withPath(rows: Record<string, Object>[], path: string): Record<string, Object>[] {
  const found: Record<string, Object>[] = [];
  for (const row of rows) {
    if (row['path'] === path) {
      found.push(row);
    }
  }
  return found;
}

async function userMessageCount(): Promise<number> {
  const snap = decodeThreadSnapshot(await rpc('threads/get', recordOf('{"botId":"bot-1"}')));
  let count = 0;
  if (snap !== null) {
    for (const message of snap.messages) {
      if (message.role === 'user') {
        count += 1;
      }
    }
  }
  return count;
}

async function storeForBot(): Promise<ThreadStore> {
  const store = new ThreadStore();
  store.open('bot-1', '', 'user-fake');
  await eventually((): boolean => store.snapshot !== null);
  return store;
}

export default function outboxTest() {
  describe('OutboxAgainstFixtureServer', () => {
    beforeAll(async () => {
      app.detach();
      await initServerStore(context());
      await switchServer(BASE, {});
      outbox.init(context());
    });
    beforeEach(async () => {
      await fixture('__reset', '{}');
      outbox.clearAll();
      await saveSessionToken('fake-token');
      setSelectedSpace('space-fake');
      setConsentPrompt(async (): Promise<boolean> => true);
    });
    afterEach(async () => {
      setConsentPrompt(null);
      clearArtifactCache(context());
      await clearSessionToken();
    });

    it('saves_a_record_and_round_trips_it', 0, async () => {
      const env = context();
      const path = `${env.cacheDir}/outbox-roundtrip.txt`;
      writeSample(path, 'one');
      const item = draft(path, 'one.txt', 3);
      const record = makeRecord('roundtrip-nonce-1', BASE, 'user-fake', 'space-fake');
      try {
        expect(outbox.park(record, [item])).assertTrue();
        const expected = `${env.filesDir}/outbox/roundtrip-nonce-1/0`;
        expect(item.path).assertEqual(expected);
        expect(temporaryFileExists(expected)).assertTrue();
        expect(temporaryFileExists(path)).assertFalse();
        const loaded = loadRecords(env);
        expect(loaded.length).assertEqual(1);
        const kept = loaded[0];
        expect(kept.nonce).assertEqual('roundtrip-nonce-1');
        expect(kept.apiBase).assertEqual(BASE);
        expect(kept.userId).assertEqual('user-fake');
        expect(kept.state).assertEqual('queued');
        expect(kept.attachments.length).assertEqual(1);
        expect(kept.attachments[0].path).assertEqual(expected);
        expect(kept.attachments[0].name).assertEqual('one.txt');
        expect(kept.attachments[0].size).assertEqual(3);
        expect(kept.artifactIds.length).assertEqual(1);
        expect(outbox.entriesFor('bot-1', '', '').length).assertEqual(1);
      } finally {
        removeRecord(env, record.nonce);
        removeTemporaryFileSafe(path);
      }
    });

    it('deletes_a_broken_file_and_keeps_the_rest', 0, async () => {
      const env = context();
      const good = makeRecord('good-nonce-1', BASE, 'user-fake', 'space-fake');
      saveRecord(env, good);
      writeSample(`${env.filesDir}/outbox/not-json.json`, 'this is not json');
      writeSample(`${env.filesDir}/outbox/bad-fields.json`, '{"v":1,"nonce":"x"}');
      const loaded = loadRecords(env);
      expect(loaded.length).assertEqual(1);
      expect(loaded[0].nonce).assertEqual('good-nonce-1');
      expect(temporaryFileExists(`${env.filesDir}/outbox/not-json.json`)).assertFalse();
      expect(temporaryFileExists(`${env.filesDir}/outbox/bad-fields.json`)).assertFalse();
    });

    it('sweeps_an_orphan_folder_without_its_record', 0, async () => {
      const env = context();
      // A crash between the attachment move and the record write leaves a folder no bubble can
      // ever use; the launch sweep deletes it and leaves a recorded nonce's folder alone.
      const orphan = `${env.filesDir}/outbox/orphan-nonce`;
      fs.mkdirSync(orphan, true);
      writeSample(`${orphan}/0`, 'half a park');
      saveRecord(env, makeRecord('kept-nonce-1', BASE, 'user-fake', 'space-fake'));
      sweepOutbox(env);
      expect(temporaryFileExists(orphan)).assertFalse();
      expect(loadRecords(env).length).assertEqual(1);
    });

    it('sweeps_a_leftover_tmp_file', 0, async () => {
      const env = context();
      fs.mkdirSync(`${env.filesDir}/outbox`, true);
      writeSample(`${env.filesDir}/outbox/leftover.json.tmp`, '{}');
      sweepOutbox(env);
      expect(temporaryFileExists(`${env.filesDir}/outbox/leftover.json.tmp`)).assertFalse();
    });

    it('drops_a_record_whose_attachment_files_are_gone', 0, async () => {
      const env = context();
      const path = `${env.cacheDir}/outbox-missing.txt`;
      writeSample(path, 'one');
      const item = draft(path, 'one.txt', 3);
      const record = makeRecord('missing-nonce-1', BASE, 'user-fake', 'space-fake');
      try {
        expect(outbox.park(record, [item])).assertTrue();
        const parked = `${env.filesDir}/outbox/missing-nonce-1/0`;
        expect(temporaryFileExists(parked)).assertTrue();
        fs.unlinkSync(parked);
        await outbox.restore(BASE, 'user-fake');
        // A bubble whose file is gone could never be retried: the restore leaves it out whole.
        expect(outbox.entriesFor('bot-1', '', '').length).assertEqual(0);
        expect(loadRecords(env).length).assertEqual(0);
        expect(temporaryFileExists(parked)).assertFalse();
        expect(temporaryFileExists(`${env.filesDir}/outbox/missing-nonce-1`)).assertFalse();
      } finally {
        removeTemporaryFileSafe(path);
      }
    });

    it('restore_filters_by_server_and_user_but_keeps_other_spaces', 0, async () => {
      const env = context();
      saveRecord(env, makeRecord('space-a-1', BASE, 'user-fake', 'space-a'));
      saveRecord(env, makeRecord('space-b-1', BASE, 'user-fake', 'space-b'));
      saveRecord(env, makeRecord('other-user-1', BASE, 'user-other', 'space-a'));
      saveRecord(env, makeRecord('other-server-1', 'http://10.0.2.2:9999', 'user-fake', 'space-a'));
      await outbox.restore(BASE, 'user-fake');
      const entries = outbox.entriesFor('bot-1', '', '');
      // Both of this account's Spaces survive; the other account's and the other server's wait
      // on disk for their own session.
      expect(entries.length).assertEqual(2);
      expect(entries[0].record.spaceId).assertEqual('space-a');
      expect(entries[1].record.spaceId).assertEqual('space-b');
      expect(loadRecords(env).length).assertEqual(4);
    });

    it('refuses_the_twenty_first_record', 0, async () => {
      const env = context();
      for (let index = 0; index < 20; index += 1) {
        saveRecord(env, makeRecord(`fill-nonce-${index}`, BASE, 'user-fake', 'space-fake'));
      }
      const path = `${env.cacheDir}/outbox-limit.txt`;
      writeSample(path, 'one');
      const item = draft(path, 'one.txt', 3);
      const record = makeRecord('limit-nonce-1', BASE, 'user-fake', 'space-fake');
      try {
        let threw = '';
        try {
          outbox.park(record, [item]);
        } catch (err) {
          threw = err instanceof Error ? (err as Error).message : '';
        }
        expect(threw).assertEqual('Too many unsent messages');
        // The cap is checked before anything moves: the draft never left the composer's cache.
        expect(item.path).assertEqual(path);
        expect(temporaryFileExists(path)).assertTrue();
      } finally {
        removeTemporaryFileSafe(path);
      }
    });

    it('recovers_a_send_whose_response_dropped_after_commit', 0, async () => {
      await fixture('__threadDropSendResponse', '{}');
      const store = await storeForBot();
      try {
        store.sendDraft('Dropped probe', [], '', '');
        await eventually((): boolean => !store.send.pending);
        expect(store.outboxRevision).assertEqual(1);
        expect(store.send.error).assertEqual('');
        const entries = outbox.entriesFor('bot-1', '', '');
        expect(entries.length).assertEqual(1);
        expect(entries[0].record.state).assertEqual('queued');
        expect(await userMessageCount()).assertEqual(2);
        await outbox.retry(entries[0].record.nonce);
        await eventually((): boolean => outbox.entriesFor('bot-1', '', '').length === 0);
        // The replay's nonce returned the committed receipt: one message, no duplicate.
        expect(await userMessageCount()).assertEqual(2);
        const sends = withPath(await requests(), '/rpc/threads/send');
        expect(sends.length).assertEqual(2);
        expect(sends[0]['body']).assertEqual(sends[1]['body']);
        expect(loadRecords(context()).length).assertEqual(0);
      } finally {
        store.close();
      }
    });

    it('replays_a_partial_upload_without_reuploading_and_with_the_same_body', 0, async () => {
      const env = context();
      const first = draft(`${env.cacheDir}/outbox-partial-1.txt`, 'first.txt', 3);
      const second = draft(`${env.cacheDir}/outbox-partial-2.txt`, 'second.txt', 3);
      writeSample(first.path, 'one');
      writeSample(second.path, 'two');
      await fixture('__threadDropSendResponse', '{}');
      const store = await storeForBot();
      try {
        store.sendDraft('Partial probe', [first, second], '', '');
        await eventually((): boolean => !store.send.pending);
        expect(outbox.entriesFor('bot-1', '', '').length).assertEqual(1);
        const nonce = outbox.entriesFor('bot-1', '', '')[0].record.nonce;
        let log = await requests();
        expect(withPath(log, '/rpc/artifacts/create').length).assertEqual(2);
        expect(withPath(log, '/rpc/threads/send').length).assertEqual(1);
        const firstSend = withPath(log, '/rpc/threads/send')[0]['body'];
        await outbox.retry(nonce);
        await eventually((): boolean => outbox.entriesFor('bot-1', '', '').length === 0);
        log = await requests();
        // The replay carried the uploaded artifact ids: no third upload, one identical send body.
        expect(withPath(log, '/rpc/artifacts/create').length).assertEqual(2);
        const sends = withPath(log, '/rpc/threads/send');
        expect(sends.length).assertEqual(2);
        expect(sends[0]['body']).assertEqual(firstSend);
        expect(sends[1]['body']).assertEqual(firstSend);
        expect(await userMessageCount()).assertEqual(2);
        expect(loadRecords(env).length).assertEqual(0);
      } finally {
        store.close();
        removeTemporaryFileSafe(first.path);
        removeTemporaryFileSafe(second.path);
      }
    });

    it('parks_a_rate_limited_send_as_queued', 0, async () => {
      await fixture('__outboxControl', '{"failNextSend":{"status":429,"code":"TOO_MANY","message":"Slow down"}}');
      const store = await storeForBot();
      try {
        store.sendDraft('Limited probe', [], '', '');
        await eventually((): boolean => !store.send.pending);
        const entries = outbox.entriesFor('bot-1', '', '');
        expect(entries.length).assertEqual(1);
        expect(entries[0].record.state).assertEqual('queued');
        expect(loadRecords(context()).length).assertEqual(1);
      } finally {
        store.close();
      }
    });

    it('refuses_a_forbidden_send_until_deleted', 0, async () => {
      await fixture('__outboxControl', '{"failNextSend":{"status":403,"code":"FORBIDDEN","message":"No"}}');
      const store = await storeForBot();
      try {
        store.sendDraft('Forbidden probe', [], '', '');
        await eventually((): boolean => !store.send.pending);
        const entries = outbox.entriesFor('bot-1', '', '');
        // A refusal is final (the bubble offers Delete, not Retry); the record stays on disk
        // until the user deletes it.
        expect(entries.length).assertEqual(1);
        expect(entries[0].record.state).assertEqual('refused');
        expect(loadRecords(context()).length).assertEqual(1);
        outbox.discard(entries[0].record.nonce);
        await eventually((): boolean => outbox.entriesFor('bot-1', '', '').length === 0);
        expect(loadRecords(context()).length).assertEqual(0);
      } finally {
        store.close();
      }
    });

    it('parks_a_server_fault_as_failed_and_retries_it', 0, async () => {
      await fixture('__outboxControl', '{"failNextSend":{"status":500,"code":"INTERNAL","message":"Fault"}}');
      const store = await storeForBot();
      try {
        store.sendDraft('Fault probe', [], '', '');
        await eventually((): boolean => !store.send.pending);
        const entries = outbox.entriesFor('bot-1', '', '');
        expect(entries.length).assertEqual(1);
        expect(entries[0].record.state).assertEqual('failed');
        await outbox.retry(entries[0].record.nonce);
        await eventually((): boolean => outbox.entriesFor('bot-1', '', '').length === 0);
        expect(await userMessageCount()).assertEqual(2);
      } finally {
        store.close();
      }
    });

    it('falls_back_to_the_composer_when_the_disk_refuses', 0, async () => {
      const env = context();
      // The outbox root as a plain file: every mkdir below it fails, like a full disk would.
      const blocker = `${env.filesDir}/outbox`;
      writeSample(blocker, 'not a directory');
      await fixture('__outboxControl', '{"failNextSend":{"status":500,"code":"INTERNAL","message":"Fault"}}');
      const store = await storeForBot();
      try {
        const path = `${env.cacheDir}/outbox-memory.txt`;
        writeSample(path, 'one');
        const item = draft(path, 'one.txt', 3);
        try {
          store.sendDraft('Memory probe', [item], '', '');
          await eventually((): boolean => !store.send.pending);
          // M6 semantics: the error row shows, the composer keeps its draft, nothing parked.
          expect(store.send.error === '').assertFalse();
          expect(store.sentRevision).assertEqual(0);
          expect(store.outboxRevision).assertEqual(0);
          expect(outbox.entriesFor('bot-1', '', '').length).assertEqual(0);
          expect(item.path).assertEqual(path);
          fs.unlinkSync(blocker);
          store.sendDraft('Memory probe', [item], '', '');
          await eventually((): boolean => !store.send.pending);
          expect(store.sentRevision).assertEqual(1);
          expect(await userMessageCount()).assertEqual(2);
          // The second attempt reused the first upload: the artifact went up once.
          expect(withPath(await requests(), '/rpc/artifacts/create').length).assertEqual(1);
        } finally {
          removeTemporaryFileSafe(path);
        }
      } finally {
        store.close();
        try {
          fs.unlinkSync(blocker);
        } catch (err) {
        }
      }
    });

    it('retries_queued_entries_once_when_the_chat_opens', 0, async () => {
      await fixture('__threadDropSendResponse', '{}');
      const first = await storeForBot();
      try {
        first.sendDraft('Open probe', [], '', '');
        await eventually((): boolean => !first.send.pending);
        expect(outbox.entriesFor('bot-1', '', '').length).assertEqual(1);
      } finally {
        first.close();
      }
      // Reopening the chat is the replay trigger: the queued bubble sends itself once.
      const second = new ThreadStore();
      second.open('bot-1', '', 'user-fake');
      try {
        await eventually((): boolean => outbox.entriesFor('bot-1', '', '').length === 0);
        expect(await userMessageCount()).assertEqual(2);
      } finally {
        second.close();
      }
    });

    it('clears_the_queue_when_the_user_signs_out', 0, async () => {
      const env = context();
      saveRecord(env, makeRecord('signout-nonce-1', BASE, 'user-fake', 'space-fake'));
      await outbox.restore(BASE, 'user-fake');
      expect(outbox.entries.length).assertEqual(1);
      await signOut();
      expect(outbox.entries.length).assertEqual(0);
      expect(hasAnyRecord(env)).assertFalse();
      await outbox.restore(BASE, 'user-fake');
      expect(outbox.entries.length).assertEqual(0);
    });
  });
}

function removeTemporaryFileSafe(path: string): void {
  try {
    fs.unlinkSync(path);
  } catch (err) {
  }
}
