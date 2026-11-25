// VoiceSettingsStore (M7, design §7.2): the state behind the Voice settings page, the model of
// mobile's app/(settings)/voice.tsx for this app's part of it: the provider the page shows (the
// device's own voice, or one of the server's connections), its saved credentials, the voices it
// offers, and the writes that connect, disconnect, pick a voice, pick a speech model and play a
// sample. Fields typed into since the last load are kept when a refresh lands. Reads go through
// the QueryCache (paint first, scope-guarded); writes invalidate their reads and re-read. The
// pure decisions (pickProvider, voiceConnectionForm) are ports the layer-2 voice fixture replays.
import { rpc } from '../net/rpc';
import type { RpcContext } from '../net/rpc';
import { RpcError, errorText } from '../net/errors';
import { decodeVoiceCatalog, decodeVoiceCredential, decodeVoiceCredentials, decodeVoiceStatus, decodeVoiceVoices } from '../contract/decode-voice';
import type { VoiceCatalogView, VoiceCredentialView, VoiceInfoView, VoiceStatusView } from '../contract/decode-voice';
import { queryCache } from '../query/query-cache';
import { pickProvider, voiceConnectionForm, SELF_HOSTED_PROTOCOL } from '../voice/voice-settings-model';
import type { VoiceConnectionForm } from '../voice/voice-settings-model';
import { loadDeviceVoiceEnabled, saveDeviceVoiceEnabled } from '../voice/device-voice';
import { speakText } from '../voice/speech';
import { t } from '../i18n/i18n';

const EMPTY: Record<string, Object> = {};

@ObservedV2
export class VoiceSettingsStore {
  @Trace catalog: VoiceCatalogView[] = [];
  @Trace credentials: VoiceCredentialView[] = [];
  @Trace status: VoiceStatusView | null = null;
  @Trace voices: VoiceInfoView[] = [];
  @Trace provider: string = '';
  @Trace apiKey: string = '';
  @Trace voiceId: string = '';
  @Trace speechModel: string = '';
  @Trace baseUrl: string = '';
  @Trace ttsModel: string = '';
  @Trace sttModel: string = '';
  @Trace deviceVoice: boolean = false;
  @Trace deviceVoiceLoaded: boolean = false;
  @Trace loading: boolean = false;
  @Trace loaded: boolean = false;
  /** connect | disconnect | voice | speech | test | device-voice, '' while none runs. */
  @Trace pending: string = '';
  @Trace error: string = '';
  @Trace loadError: string = '';
  private revision: number = 0;
  private edited: Set<string> = new Set<string>();

  /** The connection the page shows, when the catalog is loaded. */
  get selected(): VoiceCatalogView | undefined {
    for (const entry of this.catalog) {
      if (entry.id === this.provider) {
        return entry;
      }
    }
    return undefined;
  }

  get credential(): VoiceCredentialView | undefined {
    for (const entry of this.credentials) {
      if (entry.provider === this.provider) {
        return entry;
      }
    }
    return undefined;
  }

  /** The connection's form: what it offers, and whether it can be connected. */
  get form(): VoiceConnectionForm | null {
    const entry = this.selected;
    if (entry === undefined) {
      return null;
    }
    return voiceConnectionForm({
      entry: entry, credential: this.credential, apiKey: this.apiKey, baseUrl: this.baseUrl,
    });
  }

  /** Reads the catalog, the credentials, the status and the connection's voices. */
  async load(preferred?: string): Promise<void> {
    const revision = ++this.revision;
    this.loading = true;
    this.loadError = '';
    try {
      const catalog = await this.read('voice/catalog', EMPTY, decodeVoiceCatalog, [] as VoiceCatalogView[]);
      const credentials = await this.read('voice/credentials', EMPTY, decodeVoiceCredentials,
        [] as VoiceCredentialView[]);
      const status = await this.read('voice/status', EMPTY, decodeVoiceStatus, null);
      if (revision !== this.revision) {
        return;
      }
      this.catalog = catalog;
      this.credentials = credentials;
      this.status = status;
      this.provider = pickProvider(catalog, status ?? noStatus(), preferred);
      this.applyCredential();
      if (this.credential !== undefined) {
        const input: Record<string, Object> = {};
        input['provider'] = this.provider;
        this.voices = await this.read('voice/voices', input, decodeVoiceVoices, [] as VoiceInfoView[]);
      } else {
        this.voices = [];
      }
      this.loaded = true;
    } catch (err) {
      if (revision === this.revision) {
        this.loadError = errorText(rpcError(err), t('Could not load voice settings'));
      }
    } finally {
      if (revision === this.revision) {
        this.loading = false;
      }
    }
  }

  /** The stored choice of the device's own voice, read once per open. */
  async loadDeviceVoice(): Promise<void> {
    try {
      this.deviceVoice = await loadDeviceVoiceEnabled();
      this.deviceVoiceLoaded = true;
    } catch (err) {
      this.deviceVoiceLoaded = true;
      this.error = t('Could not load voice settings');
    }
  }

  /** Picks the provider to show: the device's own voice, or one of the server's connections. */
  async chooseProvider(nextProvider: string): Promise<void> {
    if (this.pending !== '' || !this.deviceVoiceLoaded) {
      return;
    }
    const wasDeviceVoice = this.deviceVoice;
    const previous = this.provider;
    this.pending = 'voice';
    this.error = '';
    this.revision += 1;
    try {
      if (this.deviceVoice && !(await this.saveDeviceVoice(false))) {
        this.pending = '';
        return;
      }
      this.provider = nextProvider;
      this.apiKey = '';
      this.voices = [];
      this.edited.clear();
      this.applyCredential();
      await this.load(nextProvider);
    } catch (err) {
      this.provider = previous;
      this.voices = [];
      if (wasDeviceVoice) {
        await this.saveDeviceVoice(true);
      }
      this.error = t('Could not load voice settings');
    } finally {
      this.pending = '';
    }
  }

  /** Turns the device's own voice on or off; a failed save rolls the switch back. */
  async toggleDeviceVoice(): Promise<void> {
    if (this.pending !== '' || !this.deviceVoiceLoaded) {
      return;
    }
    this.pending = 'device-voice';
    this.error = '';
    await this.saveDeviceVoice(!this.deviceVoice);
    this.pending = '';
  }

  private async saveDeviceVoice(on: boolean): Promise<boolean> {
    const was = this.deviceVoice;
    this.deviceVoice = on;
    try {
      await saveDeviceVoiceEnabled(on);
      return true;
    } catch (err) {
      this.deviceVoice = was;
      this.error = t('Could not save that preference');
      return false;
    }
  }

  /** Connects the provider with whatever the form holds; the saved connection answers back. */
  async connect(): Promise<void> {
    const entry = this.selected;
    const form = this.form;
    if (entry === undefined || form === null || !form.canConnect) {
      return;
    }
    this.pending = 'connect';
    this.error = '';
    try {
      const body: Record<string, Object> = {};
      body['provider'] = entry.id;
      body['apiKey'] = this.apiKey.trim();
      if (this.voiceId) {
        body['voiceId'] = this.voiceId;
      }
      if (entry.speechModel === true) {
        body['speechModel'] = this.speechModel.trim();
      }
      if (entry.id === SELF_HOSTED_PROTOCOL) {
        body['baseUrl'] = this.baseUrl.trim();
        if (this.ttsModel.trim()) {
          body['ttsModel'] = this.ttsModel.trim();
        }
        if (this.sttModel.trim()) {
          body['sttModel'] = this.sttModel.trim();
        }
      }
      const connected = decodeVoiceCredential(await rpc('voice/connect', body));
      if (connected === null) {
        throw new RpcError('Unexpected response from the server');
      }
      this.revision += 1;
      this.mergeCredential(connected);
      this.voices = [];
      this.apiKey = '';
      this.edited.clear();
      this.applyCredential();
      queryCache.invalidate('voice/credentials');
      queryCache.invalidate('voice/status');
      queryCache.invalidate('voice/voices');
      await this.load(entry.id);
    } catch (err) {
      this.error = errorText(rpcError(err), t('Could not connect'));
    } finally {
      this.pending = '';
    }
  }

  /** Drops the provider's connection; a later reconnect asks for its key again. */
  async disconnect(): Promise<void> {
    const credential = this.credential;
    if (credential === undefined) {
      return;
    }
    this.pending = 'disconnect';
    this.error = '';
    try {
      const body: Record<string, Object> = {};
      body['provider'] = credential.provider;
      await rpc('voice/disconnect', body);
      this.revision += 1;
      const next: VoiceCredentialView[] = this.credentials.filter((entry: VoiceCredentialView): boolean =>
        entry.provider !== credential.provider);
      this.credentials = next;
      if (this.provider === credential.provider) {
        this.voices = [];
        this.voiceId = '';
      }
      this.apiKey = '';
      this.edited.clear();
      queryCache.invalidate('voice/credentials');
      queryCache.invalidate('voice/status');
      await this.load();
    } catch (err) {
      this.error = errorText(rpcError(err), t('Could not disconnect'));
    } finally {
      this.pending = '';
    }
  }

  /** Picks the voice the provider speaks with. */
  async chooseVoice(nextVoiceId: string): Promise<void> {
    if (this.pending !== '') {
      return;
    }
    this.revision += 1;
    this.voiceId = nextVoiceId;
    this.pending = 'voice';
    this.error = '';
    try {
      const body: Record<string, Object> = {};
      body['voiceId'] = nextVoiceId;
      if (this.provider) {
        body['provider'] = this.provider;
      }
      const saved = decodeVoiceStatus(await rpc('voice/setVoice', body));
      if (saved === null) {
        throw new RpcError('Unexpected response from the server');
      }
      this.status = saved;
      this.edited.delete('voiceId');
      this.mergeCredentialVoice(saved.voiceId);
      queryCache.invalidate('voice/credentials');
      queryCache.invalidate('voice/status');
      await this.load(this.provider);
    } catch (err) {
      this.error = errorText(rpcError(err), t('Could not save that voice'));
    } finally {
      this.pending = '';
    }
  }

  /** Picks the speech model the connection speaks with. */
  async saveSpeechModel(value: string): Promise<void> {
    const entry = this.selected;
    const credential = this.credential;
    if (entry === undefined || entry.speechModel !== true || credential === undefined
      || this.pending !== '') {
      return;
    }
    const next = value.trim();
    if (next === (credential.speechModel ?? '') || this.speechModel === next) {
      return;
    }
    this.revision += 1;
    this.pending = 'speech';
    this.error = '';
    try {
      const body: Record<string, Object> = {};
      body['provider'] = entry.id;
      body['speechModel'] = next;
      const saved = decodeVoiceCredential(await rpc('voice/setSpeechModel', body));
      if (saved === null) {
        throw new RpcError('Unexpected response from the server');
      }
      this.mergeCredential(saved);
      this.edited.delete('speechModel');
      if (!this.edited.has('voiceId')) {
        this.voiceId = saved.voiceId;
      }
      queryCache.invalidate('voice/credentials');
      await this.load(entry.id);
    } catch (err) {
      this.error = errorText(rpcError(err), t('Could not save that speech model'));
    } finally {
      this.pending = '';
    }
  }

  /** Plays the sample the settings page offers, through the same speech path a reply takes. */
  async testVoice(): Promise<void> {
    this.pending = 'test';
    this.error = '';
    try {
      const ready = await speakText(
        t("Hi, this is how I'll sound when I read replies out loud."),
        { scope: 'account' },
      );
      if (!ready) {
        throw new Error(t('Connect a voice provider first.'));
      }
    } catch (err) {
      this.error = err instanceof Error ? (err as Error).message : t('Could not play a sample');
    } finally {
      this.pending = '';
    }
  }

  /** A field was typed into: a refresh landing keeps it. */
  edit(field: string, value: string): void {
    this.edited.add(field);
    this.write(field, value);
  }

  private write(field: string, value: string): void {
    if (field === 'voiceId') {
      this.voiceId = value;
    } else if (field === 'speechModel') {
      this.speechModel = value;
    } else if (field === 'baseUrl') {
      this.baseUrl = value;
    } else if (field === 'apiKey') {
      this.apiKey = value;
    } else if (field === 'ttsModel') {
      this.ttsModel = value;
    } else if (field === 'sttModel') {
      this.sttModel = value;
    }
  }

  private applyCredential(): void {
    const credential = this.credential;
    const fields: Record<string, string> = {};
    fields['voiceId'] = credential?.voiceId ?? '';
    fields['speechModel'] = credential?.speechModel ?? '';
    fields['baseUrl'] = credential?.endpoint ?? '';
    fields['apiKey'] = '';
    fields['ttsModel'] = credential?.ttsModel ?? '';
    fields['sttModel'] = credential?.sttModel ?? '';
    for (const field of Object.keys(fields)) {
      if (!this.edited.has(field)) {
        this.write(field, fields[field] ?? '');
      }
    }
  }

  private mergeCredential(saved: VoiceCredentialView): void {
    const next: VoiceCredentialView[] = [];
    let merged = false;
    for (const entry of this.credentials) {
      if (entry.provider === saved.provider) {
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

  private mergeCredentialVoice(voiceId: string): void {
    const next: VoiceCredentialView[] = [];
    for (const entry of this.credentials) {
      if (entry.provider === this.provider) {
        const saved: VoiceCredentialView = {
          id: entry.id, provider: entry.provider, hasKey: entry.hasKey, voiceId: voiceId,
          speechModel: entry.speechModel, transcribe: entry.transcribe, endpoint: entry.endpoint,
          ttsModel: entry.ttsModel, sttModel: entry.sttModel,
        };
        next.push(saved);
      } else {
        next.push(entry);
      }
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

function noStatus(): VoiceStatusView {
  const status: VoiceStatusView = {
    configured: false, ready: false, transcribe: false, provider: null, voiceId: '',
  };
  return status;
}
