// M9 hypium: the model-connection ports replay the layer-2 models fixture on device — the same
// fixture the vitest port tests replay against core/contracts — so the kit's own URL parser (the
// WHATWG origin rules are the risk the fixture measures) and the pure decisions are half of the
// differential. decodeModelCredentials, the probe output and the list markers are checked here.
import { describe, expect, it } from '@ohos/hypium';
import { fixtureModels } from './fixtures.generated';
import { boolField, stableJson, stringField } from './test-utils';
import { decodeMe, decodeModelCatalog } from '../../../main/ets/contract/decode';
import type { MeView, ModelCatalogEntryView } from '../../../main/ets/contract/decode';
import { decodeModelCredential, decodeModelCredentials, decodeProbeModels }
  from '../../../main/ets/contract/decode-models';
import type { ModelCredentialView } from '../../../main/ets/contract/decode-models';
import {
  connectionFormModelId,
  connectableProviders,
  firstModelConnection,
  isDefaultConnection,
  pickCatalogModelId,
} from '../../../main/ets/features/models/model-providers';
import type { ModelDefaults, ModelCredentialRef } from '../../../main/ets/features/models/model-providers';
import {
  modelConnectRequest,
  openAiCompatibleConnectReady,
} from '../../../main/ets/features/models/model-connect-request';
import type { ConnectionFormDraft } from '../../../main/ets/features/models/model-connect-request';
import { normalizeOpenAiCompatibleBaseUrl }
  from '../../../main/ets/features/models/compatible-url';

const fixture: Record<string, Object> = JSON.parse(fixtureModels) as Record<string, Object>;

function record(value: Object): Record<string, Object> {
  return value as Record<string, Object>;
}

/** A JSON array value's items. */
function itemsOf(value: Object): Object[] {
  return value as Object[];
}

function entriesOf(value: Object): ModelCatalogEntryView[] {
  const entries: ModelCatalogEntryView[] = [];
  for (const item of value as Object[]) {
    const row = record(item);
    const entry: ModelCatalogEntryView = {
      provider: stringField(row, 'provider'),
      id: stringField(row, 'id'),
      label: stringField(row, 'label'),
      providerName: row['providerName'] === null ? null : stringField(row, 'providerName'),
      recommended: boolField(row, 'recommended'),
      auth: row['auth'] === null ? null : stringField(row, 'auth'),
      placeholder: boolField(row, 'placeholder'),
    };
    entries.push(entry);
  }
  return entries;
}

function stringsOf(value: Object): string[] {
  const values: string[] = [];
  for (const item of value as Object[]) {
    values.push(item as string);
  }
  return values;
}

function optionalString(value: Object | null | undefined): string | null {
  return value === null || value === undefined ? null : value as string;
}

function credentialOf(row: Record<string, Object>): ModelCredentialRef | null {
  const value = row['credential'];
  if (value === null || value === undefined) {
    return null;
  }
  const credential: ModelCredentialRef = {
    modelId: optionalString(record(value)['modelId']),
  };
  return credential;
}

function defaultsOf(value: Object | null | undefined): ModelDefaults | null {
  if (value === null || value === undefined) {
    return null;
  }
  const row = record(value);
  const defaults: ModelDefaults = {
    defaultProvider: optionalString(row['defaultProvider']),
    defaultModel: optionalString(row['defaultModel']),
  };
  return defaults;
}

export default function modelConnectTest() {
  describe('ModelConnectPorts', () => {
    it('picks_the_same_catalog_model_as_core', 0, () => {
      for (const item of itemsOf(fixture['pick'])) {
        const row = record(item);
        const preferred = optionalString(row['preferredId']);
        expect(pickCatalogModelId(entriesOf(row['catalog'] as Object),
          stringField(row, 'provider'), preferred)).assertEqual(stringField(row, 'expected'));
      }
    });

    it('opens_the_form_on_the_same_model_as_core', 0, () => {
      for (const item of itemsOf(fixture['formModel'])) {
        const row = record(item);
        const modelId = connectionFormModelId({
          catalog: entriesOf(row['catalog'] as Object),
          provider: stringField(row, 'provider'),
          credential: credentialOf(row),
          defaults: defaultsOf(row['defaults']),
          current: stringField(row, 'current'),
        });
        expect(modelId).assertEqual(stringField(row, 'expected'));
      }
    });

    it('sends_the_same_connect_input_as_core', 0, () => {
      for (const item of itemsOf(fixture['connectRequest'])) {
        const row = record(item);
        const formRow = record(row['form']);
        const form: ConnectionFormDraft = {
          enabledModelIds: stringsOf(formRow['enabledModelIds']),
          baseUrl: stringField(formRow, 'baseUrl'),
          modelId: stringField(formRow, 'modelId'),
          apiKey: stringField(formRow, 'apiKey'),
        };
        const selected = entriesOf([row['selected']])[0];
        const result = modelConnectRequest({
          form: form,
          selected: selected,
          credential: credentialOf(row),
          credentialId: optionalString(row['credentialId']),
          makeDefault: boolField(row, 'makeDefault'),
          scope: stringField(row, 'scope'),
        });
        // The fixture's expected input is a JSON value: compare canonical JSON, key order free.
        expect(stableJson(JSON.parse(JSON.stringify(result))))
          .assertEqual(stableJson(row['expected']));
      }
    });

    it('normalizes_the_base_url_like_the_contract', 0, () => {
      for (const item of itemsOf(fixture['normalize'])) {
        const row = record(item);
        const input = stringField(row, 'input');
        const result = normalizeOpenAiCompatibleBaseUrl(input);
        if (boolField(row, 'ok')) {
          expect(result.ok).assertTrue();
          expect(result.url).assertEqual(stringField(row, 'url'));
        } else {
          expect(result.ok).assertFalse();
          expect(result.error).assertEqual(stringField(row, 'error'));
        }
      }
    });

    it('matches_the_contract_on_compatible_readiness', 0, () => {
      for (const item of itemsOf(fixture['connectReady'])) {
        const row = record(item);
        expect(openAiCompatibleConnectReady(stringField(row, 'baseUrl'),
          stringField(row, 'modelId'), stringField(row, 'apiKey'),
          boolField(row, 'keyRequired'))).assertEqual(boolField(row, 'expected'));
      }
    });

    it('decodes_saved_connections_and_rejects_bad_rows', 0, () => {
      const list = decodeModelCredentials(JSON.parse('['
        + '{"id":"c1","provider":"p","label":"Fake","hasKey":true,'
        + '"modelId":"m1","baseUrl":"https://models.example","isDefault":true},'
        + '{"id":"c2","provider":"p","label":"Fake","hasKey":false,"modelId":null},'
        + '{"id":"bad"},{"provider":"p","label":"L","hasKey":1}]'));
      expect(list !== null).assertTrue();
      expect(list!.length).assertEqual(2);
      expect(list![0].modelId).assertEqual('m1');
      expect(list![0].baseUrl).assertEqual('https://models.example');
      expect(list![1].modelId).assertNull();
      expect(list![1].baseUrl).assertNull();
      expect(decodeModelCredentials(JSON.parse('{}'))).assertNull();
      expect(decodeModelCredentials(null)).assertNull();
      const single: ModelCredentialView | null = decodeModelCredential(JSON.parse(
        '{"id":"c1","provider":"p","label":"","hasKey":true}'));
      expect(single !== null).assertTrue();
      expect(single!.label).assertEqual('');
      expect(single!.modelId).assertNull();
    });

    it('decodes_probed_models_and_drops_other_entries', 0, () => {
      // A repeated id keeps its first place: the picker's list keys on the id.
      const models = decodeProbeModels(JSON.parse('{"models":["a",7,"b","a"]}'));
      expect(models !== null).assertTrue();
      expect(models!.join(',')).assertEqual('a,b');
      expect(decodeProbeModels(JSON.parse('{"models":["a","a"]}'))!.join(',')).assertEqual('a');
      expect(decodeProbeModels(JSON.parse('{"models":[]}'))!.length).assertEqual(0);
      expect(decodeProbeModels(JSON.parse('{"models":"a"}'))).assertNull();
      expect(decodeProbeModels(JSON.parse('{}'))).assertNull();
    });

    it('marks_the_account_default_and_the_first_connection', 0, () => {
      const me: MeView | null = decodeMe(JSON.parse('{"userId":"u","email":"a@b.c","name":"A",'
        + '"spaceId":"s","needsModel":true,"defaultProvider":null,"defaultModel":null}'));
      expect(firstModelConnection(me, [])).assertTrue();
      const credential = decodeModelCredential(JSON.parse(
        '{"id":"c","provider":"openai-compatible","label":"L","hasKey":true,"modelId":"m"}'))!;
      expect(firstModelConnection(me, [credential])).assertFalse();
      expect(firstModelConnection(null, [])).assertFalse();
      const defaults: ModelDefaults = { defaultProvider: 'openai-compatible', defaultModel: 'm' };
      expect(isDefaultConnection(defaults, credential)).assertTrue();
      const other: ModelDefaults = { defaultProvider: 'openai-compatible', defaultModel: 'x' };
      expect(isDefaultConnection(other, credential)).assertFalse();
      expect(isDefaultConnection(null, credential)).assertFalse();
    });

    it('offers_only_providers_with_a_key_path', 0, () => {
      const catalog = decodeModelCatalog(JSON.parse('['
        + '{"provider":"keyed","id":"m1","label":"Keyed","auth":"api-key"},'
        + '{"provider":"both","id":"m2","label":"Both","auth":"both"},'
        + '{"provider":"signed","id":"m3","label":"Signed","auth":"oauth"},'
        + '{"provider":"keyed","id":"m4","label":"Keyed 2","providerName":"Keyed Maker"}]'))!;
      const providers = connectableProviders(catalog);
      expect(providers.length).assertEqual(2);
      expect(providers[0].id).assertEqual('keyed');
      expect(providers[0].name).assertEqual('keyed');
      expect(providers[1].id).assertEqual('both');
    });
  });
}