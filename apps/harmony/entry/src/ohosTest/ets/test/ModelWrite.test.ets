// M9 hypium: the model connections store against the offline fixture server. Connecting a
// provider lands a connection the credentials read returns, a refused key's text never carries
// the key back, a compatible server's probe fills the model, and needsModel can be flipped by
// the fixture's script. Every provider, key, model and id on the server is a fake probe.
import { afterEach, beforeAll, beforeEach, describe, expect, it } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { app } from '../../../main/ets/app/app-state';
import { initServerStore, switchServer } from '../../../main/ets/net/server-store';
import { clearSessionToken, saveSessionToken, setSelectedSpace } from '../../../main/ets/net/session';
import { rpc } from '../../../main/ets/net/rpc';
import { getJson, parseJsonObject, postJson } from '../../../main/ets/net/http';
import { decodeMe } from '../../../main/ets/contract/decode';
import { decodeModelCredentials } from '../../../main/ets/contract/decode-models';
import { ModelConnectionsStore } from '../../../main/ets/stores/model-connections-store';
import { firstModelConnection } from '../../../main/ets/features/models/model-providers';
import type { ModelDefaults } from '../../../main/ets/features/models/model-providers';
import { queryCache } from '../../../main/ets/query/query-cache';

const BASE = 'http://10.0.2.2:8787';

function defaults(defaultProvider: string | null, defaultModel: string | null): ModelDefaults {
  const value: ModelDefaults = { defaultProvider: defaultProvider, defaultModel: defaultModel };
  return value;
}

/** The fixture's model script: {needsModel?, defaultProvider?, defaultModel?, credentials?}. */
async function script(body: Record<string, Object>): Promise<void> {
  const headers: Record<string, string> = {};
  headers['content-type'] = 'application/json';
  await postJson(`${BASE}/__modelScript`, headers, JSON.stringify(body), 8000, 64 * 1024);
}

async function modelState(): Promise<Record<string, Object>> {
  const response = await getJson(`${BASE}/__modelState`, {}, 8000, 256 * 1024);
  const body = parseJsonObject(response.body);
  if (body === null) {
    const empty: Record<string, Object> = {};
    return empty;
  }
  return body;
}

export default function modelWriteTest() {
  describe('ModelWriteAgainstFixtureServer', () => {
    beforeAll(async () => {
      app.detach();
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext();
      await initServerStore(context);
      await switchServer(BASE, {});
    });

    beforeEach(async () => {
      await getJson(`${BASE}/__reset`, {}, 8000, 64 * 1024);
      await saveSessionToken('fake-token');
      setSelectedSpace('space-fake');
      queryCache.clear();
    });

    afterEach(async () => {
      await clearSessionToken();
      setSelectedSpace('');
      queryCache.clear();
    });

    it('a_key_connect_lands_a_connection_and_the_main_model', 0, async () => {
      const store = new ModelConnectionsStore();
      await store.load();
      expect(store.loadError).assertEqual('');
      expect(store.loaded).assertTrue();
      store.begin(true, defaults(null, null));
      store.chooseProvider('fake-provider');
      // The provider's recommended model is preselected.
      expect(store.modelId).assertEqual('fake-model');
      store.edit('apiKey', 'fake-key-1234');
      expect(store.connectReady).assertTrue();
      expect(await store.connect()).assertTrue();
      expect(store.error).assertEqual('');
      expect(store.apiKey).assertEqual('');
      expect(store.credentials.length).assertEqual(1);
      expect(store.credentials[0].provider).assertEqual('fake-provider');
      expect(store.credentials[0].hasKey).assertTrue();
      expect(store.credentials[0].modelId).assertEqual('fake-model');
      // makeDefault landed the account's main model on the new connection.
      const me = (await modelState())['me'] as Record<string, Object>;
      expect(me['defaultProvider']).assertEqual('fake-provider');
      expect(me['defaultModel']).assertEqual('fake-model');
      expect(me['needsModel']).assertFalse();
    });

    it('sends_an_explicit_null_and_an_omitted_id_overwrites', 0, async () => {
      const store = new ModelConnectionsStore();
      await store.load();
      store.begin(true, defaults(null, null));
      store.chooseProvider('fake-provider');
      store.edit('apiKey', 'fake-key-1234');
      expect(await store.connect()).assertTrue();
      // Adding a connection always sends credentialId: null, and the fixture records it.
      const records = (await modelState())['connects'] as Object[];
      expect(records.length).assertEqual(1);
      expect((records[0] as Record<string, Object>)['credentialIdWasNull']).assertTrue();
      // The older contract still holds: omitting credentialId updates the provider's newest
      // connection instead of adding another one.
      const body: Record<string, Object> = {};
      body['provider'] = 'fake-provider';
      body['label'] = 'Fake Maker';
      body['apiKey'] = 'fake-key-5678';
      body['modelId'] = 'fake-model';
      body['makeDefault'] = false;
      body['scope'] = 'account';
      await rpc('models/connect', body);
      const after = await modelState();
      const credentials = after['credentials'] as Object[];
      expect(credentials.length).assertEqual(1);
      expect((credentials[0] as Record<string, Object>)['id']).assertEqual('cred-1');
      const next = after['connects'] as Object[];
      expect(next.length).assertEqual(2);
      expect((next[1] as Record<string, Object>)['credentialIdWasNull']).assertFalse();
    });

    it('a_refused_key_is_never_shown_back', 0, async () => {
      const store = new ModelConnectionsStore();
      await store.load();
      store.begin(true, defaults(null, null));
      store.chooseProvider('fake-provider');
      store.edit('apiKey', 'bad-key-1234');
      expect(store.connectReady).assertTrue();
      expect(await store.connect()).assertFalse();
      expect(store.pending).assertEqual('');
      expect(store.credentials.length).assertEqual(0);
      // The server echoed the key in its refusal; the screen's text masks it.
      expect(store.error.indexOf('bad-key-1234')).assertEqual(-1);
      expect(store.error.indexOf('•••') >= 0).assertTrue();
    });

    it('a_compatible_probe_fills_the_model_and_connects', 0, async () => {
      const store = new ModelConnectionsStore();
      await store.load();
      store.begin(true, defaults(null, null));
      store.chooseProvider('openai-compatible');
      expect(store.modelId).assertEqual('');
      store.edit('baseUrl', 'https://models.example');
      expect(store.probeReady).assertTrue();
      await store.probe();
      expect(store.error).assertEqual('');
      expect(store.probeModels.join(',')).assertEqual('found-a,found-b');
      // The first found model fills an empty one, as mobile's probe does.
      expect(store.modelId).assertEqual('found-a');
      expect(store.connectReady).assertTrue();
      expect(await store.connect()).assertTrue();
      expect(store.credentials.length).assertEqual(1);
      expect(store.credentials[0].provider).assertEqual('openai-compatible');
      expect(store.credentials[0].baseUrl).assertEqual('https://models.example');
      expect(store.credentials[0].modelId).assertEqual('found-a');
    });

    it('needs_model_flips_with_the_script', 0, async () => {
      const body: Record<string, Object> = {};
      const noCredentials: string[] = [];
      body['needsModel'] = true;
      body['credentials'] = noCredentials;
      await script(body);
      const me = decodeMe(await rpc('me', {}));
      expect(me !== null).assertTrue();
      expect(me!.needsModel).assertTrue();
      const credentials = decodeModelCredentials(await rpc('models/credentials', {}));
      expect(credentials !== null).assertTrue();
      expect(firstModelConnection(me, credentials!)).assertTrue();
      const off: Record<string, Object> = {};
      off['needsModel'] = false;
      await script(off);
      const next = decodeMe(await rpc('me', {}));
      expect(firstModelConnection(next, [])).assertFalse();
    });
  });
}