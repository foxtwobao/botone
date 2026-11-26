// Voice settings rules (M7): the two pure decisions of mobile's voice settings screen
// (app/(settings)/voice.tsx) and of the connection form (packages/contracts voice-connection-ui):
// which connection the screen shows, and what its form offers. The layer-2 voice fixture runs the
// real rules and this port replays them. The settings screen that uses them is
// stores/voice-settings-store.ets.
import type {
  VoiceCatalogView,
  VoiceCredentialView,
  VoiceModelConnectionView,
  VoiceStatusView,
} from '../contract/decode-voice';

/** The protocol whose connection names its own server (contracts model-connections). */
export const SELF_HOSTED_PROTOCOL = 'openai-compatible';

/** The connection to show: the one asked for, the one in use, else the catalog's first. */
export function pickProvider(catalog: VoiceCatalogView[], status: VoiceStatusView, preferred?: string): string {
  const asked = preferred !== undefined && catalog.some((entry: VoiceCatalogView): boolean => entry.id === preferred)
    ? preferred : '';
  const inUse = status.provider !== null
    && catalog.some((entry: VoiceCatalogView): boolean => entry.id === status.provider) ? status.provider : '';
  const chosen = asked !== '' ? asked : inUse;
  if (chosen !== '') {
    return chosen;
  }
  return catalog.length > 0 ? catalog[0]!.id : '';
}

export interface VoiceConnectionInput {
  /** The catalog entry of the chosen connection; undefined until the catalog has loaded. */
  entry: VoiceCatalogView | undefined;
  credential: VoiceCredentialView | undefined;
  apiKey: string;
  baseUrl: string;
}

export interface VoiceConnectionForm {
  /** Connected through one of the account's model connections: there is no key to show or
   *  replace. */
  linked: boolean;
  /** The key form can be sent. */
  canConnect: boolean;
  /**
   * The account's model connections to the connection, less the one already serving voice.
   * shortcut: the page renders neither them nor the sign-in yet, until the Models work (M11)
   * ports the chooser.
   */
  modelConnections: VoiceModelConnectionView[];
  /** The connection's sign-in, offered only while the account holds no model connection to it. */
  modelSignIn?: string;
}

/**
 * What the form offers for a connection. The key form needs a key: nothing stands in for one. The
 * account's model connections to the connection are offered for the caller to choose from, and
 * a sign-in where it has none yet; once linked there is no key to show or replace. As the rule is
 * written, with no connection chosen a key alone reads as enough (the screen never connects
 * without one).
 */
export function voiceConnectionForm(input: VoiceConnectionInput): VoiceConnectionForm {
  const entry = input.entry;
  const credential = input.credential;
  const typedKey = input.apiKey.trim();
  let canConnect = entry !== undefined && entry.keyless === true;
  if (!canConnect) {
    canConnect = entry?.id === SELF_HOSTED_PROTOCOL ? input.baseUrl.trim().length > 0 : typedKey.length >= 8;
  }
  const choices = entry?.modelConnections ?? [];
  const bound = credential?.modelCredentialId;
  const linked = credential !== undefined && credential.hasKey === false
    && (bound
      ? choices.some((choice: VoiceModelConnectionView): boolean => choice.id === bound)
      : choices.length > 0);
  let modelConnections = choices;
  if (linked && bound) {
    modelConnections = choices.filter((choice: VoiceModelConnectionView): boolean => choice.id !== bound);
  }
  // A legacy link uses the preferred connection, so offer explicit choices if there are several.
  if (linked && !bound && choices.length === 1) {
    modelConnections = [];
  }
  const form: VoiceConnectionForm = {
    linked: linked, canConnect: canConnect, modelConnections: modelConnections,
  };
  const modelSignIn = entry?.modelSignIn;
  if (choices.length === 0 && modelSignIn !== undefined) {
    form.modelSignIn = modelSignIn;
  }
  return form;
}
