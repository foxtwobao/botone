// ModelConnectionsStore (M9, design §7.2): the state behind the Models list and the connection
// form — the catalog, the account's saved connections, the provider and model being connected,
// the model list a compatible server probes, and the connect write. Reads go through the
// QueryCache (paint first, scope-guarded); the connect invalidates its reads. The pure decisions
// (provider rows, form model, request) are ports the layer-2 fixture replays.
import { rpc } from '../net/rpc';
import type { RpcContext } from '../net/rpc';
import { RpcError, errorText } from '../net/errors';
import { decodeModelCatalog } from '../contract/decode';
import type { ModelCatalogEntryView } from '../contract/decode';
import { decodeModelCredential, decodeModelCredentials, decodeProbeModels } from '../contract/decode-models';
import type { ModelCredentialView } from '../contract/decode-models';
import { queryCache } from '../query/query-cache';
import {
  connectionFormModelId,
  connectableProviders,
  modelLabelFor,
  OPENAI_COMPATIBLE_PROVIDER_ID,
} from '../features/models/model-providers';
import type { ModelDefaults, ProviderChoice } from '../features/models/model-providers';
import { hideKnownKey, MODEL_CONNECT_TIMEOUT_MS, modelConnectRequest } from '../features/models/model-connect-request';
import type { ConnectionFormDraft, ModelConnectInput, ModelConnectRequest } from '../features/models/model-connect-request';
import { normalizeOpenAiCompatibleBaseUrl } from '../features/models/compatible-url';
import { t } from '../i18n/i18n';

const EMPTY: Record<string, Object> = {};

@ObservedV2
export class ModelConnectionsStore {
  @Trace catalog: ModelCatalogEntryView[] = [];
  @Trace credentials: ModelCredentialView[] = [];
  @Trace loading: boolean = false;
  @Trace loaded: boolean = false;
  @Trace loadError: string = '';
  /** The provider the connection form shows; '' until one is chosen. */
  @Trace provider: string = '';
  @Trace apiKey: string = '';
  @Trace baseUrl: string = '';
  @Trace modelId: string = '';
  @Trace probeModels: string[] = [];
  /** probe | connect, '' while none runs. */
  @Trace pending: string = '';
  @Trace error: string = '';
  private makeDefault: boolean = false;
  private defaults: ModelDefaults | null = null;
  private revision: number = 0;
  /** The form's session: begin and reset open a new one, and an answer to an older one is dropped. */
  private session: number = 0;

  /** The providers a key connection can be made to, in catalog order. */
  get providers(): ProviderChoice[] {
    return connectableProviders(this.catalog);
  }

  get isCompatible(): boolean {
    return this.provider === OPENAI_COMPATIBLE_PROVIDER_ID;
  }

  /** The catalog row that names the provider (a compatible placeholder stands in for it). */
  get providerEntry(): ModelCatalogEntryView | undefined {
    for (const entry of this.catalog) {
      if (entry.provider === this.provider) {
        return entry;
      }
    }
    return undefined;
  }

  /** A catalog provider's selectable models: placeholders are not real models. */
  get providerModels(): ModelCatalogEntryView[] {
    const models: ModelCatalogEntryView[] = [];
    for (const entry of this.catalog) {
      if (entry.provider === this.provider && !entry.placeholder) {
        models.push(entry);
      }
    }
    return models;
  }

  /** The catalog model the form picked, or the provider's first when nothing is picked. */
  get selectedModel(): ModelCatalogEntryView | undefined {
    const models = this.providerModels;
    for (const entry of models) {
      if (entry.id === this.modelId) {
        return entry;
      }
    }
    return models.length > 0 ? models[0] : undefined;
  }

  get form(): ConnectionFormDraft {
    const form: ConnectionFormDraft = {
      enabledModelIds: [],
      baseUrl: this.baseUrl,
      modelId: this.modelId,
      apiKey: this.apiKey,
    };
    return form;
  }

  /** The connect the form would send, or incomplete. */
  get request(): ModelConnectRequest {
    const selected = this.isCompatible ? this.providerEntry : this.selectedModel;
    if (selected === undefined) {
      const incomplete: ModelConnectRequest = { status: 'incomplete' };
      return incomplete;
    }
    return modelConnectRequest({
      form: this.form,
      selected: selected,
      credential: null,
      credentialId: null,
      makeDefault: this.makeDefault,
      scope: 'account',
    });
  }

  get connectReady(): boolean {
    return this.request.status === 'ready';
  }

  /** The address is complete enough to probe. */
  get probeReady(): boolean {
    return this.isCompatible && this.pending === ''
      && normalizeOpenAiCompatibleBaseUrl(this.baseUrl).ok;
  }

  /** Forgets the previous open's reads and form: another session's rows never paint. */
  reset(): void {
    this.revision += 1;
    this.session += 1;
    this.catalog = [];
    this.credentials = [];
    this.loading = false;
    this.loaded = false;
    this.loadError = '';
    this.provider = '';
    this.apiKey = '';
    this.baseUrl = '';
    this.modelId = '';
    this.probeModels = [];
    this.pending = '';
    this.error = '';
    this.makeDefault = false;
    this.defaults = null;
  }

  /** Opens the form for a new connection: makeDefault comes from the caller's account state. */
  begin(makeDefault: boolean, defaults: ModelDefaults | null): void {
    this.session += 1;
    this.makeDefault = makeDefault;
    this.defaults = defaults;
    this.provider = '';
    this.apiKey = '';
    this.baseUrl = '';
    this.modelId = '';
    this.probeModels = [];
    this.pending = '';
    this.error = '';
  }

  /** Reads the catalog and the saved connections; the form keeps what it holds. */
  async load(): Promise<void> {
    const revision = ++this.revision;
    this.loading = true;
    this.loadError = '';
    try {
      const catalog = await this.read('models/list', EMPTY, decodeModelCatalog,
        [] as ModelCatalogEntryView[]);
      const credentials = await this.read('models/credentials', EMPTY, decodeModelCredentials,
        [] as ModelCredentialView[]);
      if (revision !== this.revision) {
        return;
      }
      this.catalog = catalog;
      this.credentials = credentials;
      this.loaded = true;
    } catch (err) {
      if (revision === this.revision) {
        this.loadError = errorText(rpcError(err), t('Could not load model settings'));
      }
    } finally {
      if (revision === this.revision) {
        this.loading = false;
      }
    }
  }

  /** Picks the provider the form connects; a different provider starts its own form. */
  chooseProvider(id: string): void {
    if (this.pending !== '' || this.provider === id) {
      return;
    }
    this.provider = id;
    this.apiKey = '';
    this.baseUrl = '';
    this.probeModels = [];
    this.error = '';
    this.modelId = connectionFormModelId({
      catalog: this.catalog,
      provider: id,
      credential: null,
      defaults: this.defaults,
      current: '',
    });
  }

  /** A field was typed into. */
  edit(field: string, value: string): void {
    this.error = '';
    if (field === 'apiKey') {
      this.apiKey = value;
    } else if (field === 'baseUrl') {
      this.baseUrl = value;
      // The found models belong to the address they were probed on.
      this.probeModels = [];
    } else if (field === 'modelId') {
      this.modelId = value;
    }
  }

  /** A catalog provider's model came from its menu. */
  chooseModel(id: string): void {
    this.error = '';
    this.modelId = id;
  }

  /** Asks a compatible server for its models; the first one fills an empty model id. */
  async probe(): Promise<void> {
    if (!this.probeReady) {
      return;
    }
    const address = normalizeOpenAiCompatibleBaseUrl(this.baseUrl);
    if (!address.ok) {
      return;
    }
    const session = this.session;
    this.pending = 'probe';
    this.error = '';
    this.probeModels = [];
    try {
      const models = decodeProbeModels(await rpc('models/probeOpenAiCompatible',
        probeInput(address.url, this.apiKey), { timeoutMs: MODEL_CONNECT_TIMEOUT_MS }));
      if (models === null) {
        throw new RpcError('Unexpected response from the server');
      }
      // The form was reopened while the probe waited: the models belong to the old address,
      // not to this form (nor to the first model id it would fill).
      if (session !== this.session) {
        return;
      }
      this.probeModels = models;
      if (!this.modelId.trim() && models.length > 0) {
        this.modelId = models[0];
      }
    } catch (err) {
      if (session === this.session) {
        this.error = hideKnownKey(errorText(rpcError(err), t('Could not reach this model server')),
          this.apiKey);
      }
    } finally {
      if (session === this.session) {
        this.pending = '';
      }
    }
  }

  /** Saves the connection; true when it landed, so the page can return to the list. */
  async connect(): Promise<boolean> {
    const request = this.request;
    if (request.status !== 'ready' || request.input === undefined || this.pending !== '') {
      return false;
    }
    const session = this.session;
    const body = connectBody(request.input);
    this.pending = 'connect';
    this.error = '';
    try {
      const saved = decodeModelCredential(await rpc('models/connect', body,
        { timeoutMs: MODEL_CONNECT_TIMEOUT_MS }));
      if (saved === null) {
        throw new RpcError('Unexpected response from the server');
      }
      // The form was reopened while the write waited: the connection landed, but its answer
      // must not land in the new form.
      if (session === this.session) {
        this.mergeCredential(saved);
        this.apiKey = '';
        this.probeModels = [];
      }
      queryCache.invalidate('models/credentials');
      queryCache.invalidate('models/list');
      await this.load();
      return true;
    } catch (err) {
      if (session === this.session) {
        this.error = hideKnownKey(errorText(rpcError(err), t('Could not connect this provider')),
          this.apiKey);
      }
      return false;
    } finally {
      if (session === this.session) {
        this.pending = '';
      }
    }
  }

  /** The list's row detail: the model's catalog label ('' when the catalog does not list it). */
  modelLabel(credential: ModelCredentialView): string {
    return credential.modelId !== null
      ? modelLabelFor(this.catalog, credential.provider, credential.modelId) : '';
  }

  private mergeCredential(saved: ModelCredentialView): void {
    const next: ModelCredentialView[] = [];
    let merged = false;
    for (const entry of this.credentials) {
      if (entry.id === saved.id) {
        next.push(saved);
        merged = true;
      } else {
        next.push(entry);
      }
    }
    if (!merged) {
      next.push(saved);
    }
    this.credentials = next;
  }

  private async read<T>(proc: string, input: Record<string, Object>,
    decode: (json: Object | null) => T | null, fallback: T): Promise<T> {
    const value = await queryCache.read(proc, input,
      (context: RpcContext): Promise<Object> => rpc(proc, input, { context: context }));
    if (value === null) {
      return fallback;
    }
    const decoded = decode(value);
    if (decoded === null) {
      throw new RpcError('Unexpected response from the server');
    }
    return decoded;
  }
}

function rpcError(err: Object): RpcError | null {
  return err instanceof RpcError ? err as RpcError : null;
}

/** The probe body: the stored address, plus the key only when one was typed. */
function probeInput(baseUrl: string, apiKey: string): Record<string, Object> {
  const body: Record<string, Object> = {};
  body['baseUrl'] = baseUrl;
  const key = apiKey.trim();
  if (key) {
    body['apiKey'] = key;
  }
  return body;
}

/** A Record value cannot hold null in ArkTS, and the contract needs credentialId: null to add a
 * connection rather than update the provider's newest one (ThreadStream.test's same trick). */
function connectBody(input: ModelConnectInput): Record<string, Object> {
  const body: Record<string, Object> = {};
  body['provider'] = input.provider;
  body['label'] = input.label;
  body['makeDefault'] = input.makeDefault;
  body['scope'] = input.scope;
  if (input.apiKey !== undefined) {
    body['apiKey'] = input.apiKey;
  }
  if (input.baseUrl !== undefined) {
    body['baseUrl'] = input.baseUrl;
  }
  if (input.modelId !== undefined) {
    body['modelId'] = input.modelId;
  }
  if (input.enabledModelIds !== undefined) {
    body['enabledModelIds'] = input.enabledModelIds;
  }
  if (input.credentialId === null) {
    const nulls: Record<string, Object> = JSON.parse('{"credentialId":null}') as Record<string, Object>;
    body['credentialId'] = nulls['credentialId'];
  } else {
    body['credentialId'] = input.credentialId;
  }
  return body;
}

export const modelConnectionsStore: ModelConnectionsStore = new ModelConnectionsStore();