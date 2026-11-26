// The server's voice (M7): the transport the speech engines and hosted dictation run on, ported
// from mobile lib/voice/voice.ts (renderUtterance, the voice consent) and voice-clip.ts
// (transcribeClip). Consent is asked first, then the text or the recording leaves under the
// pinned context. A failed answer carries the server's own message when it is human copy, a
// voice-account code's copy, else the local fallback.
import { util } from '@kit.ArkTS';
import { rpc } from '../net/rpc';
import type { RpcContext } from '../net/rpc';
import { postBytes, postJson, parseJsonObject } from '../net/http';
import type { HttpBytesResponse, HttpResponseView } from '../net/http';
import type { RequestCancellation } from '../net/request-cancellation';
import { RpcError, errorText } from '../net/errors';
import { AiConsentBlocked, ensureVoiceConsent } from '../net/consent';
import { decodeVoicePrepare, decodeVoiceStatus, decodeTranscription } from '../contract/decode-voice';
import type { VoicePrepareView } from '../contract/decode-voice';
import type { SpeechOptions } from './speech';
import type { VoiceStatusView } from './voice-plan';
import { t } from '../i18n/i18n';

/** How long a client waits for /api/voice/* to answer (core VOICE_RESPONSE_TIMEOUT_MS). */
export const VOICE_RESPONSE_TIMEOUT_MS = 70_000;
/** The most synthesized audio a server sends (core MAX_VOICE_AUDIO_BYTES). */
export const MAX_VOICE_AUDIO_BYTES = 16 * 1024 * 1024;
/** The most a transcription answer may be (core MAX_TRANSCRIPTION_RESPONSE_BYTES). */
export const MAX_TRANSCRIPTION_RESPONSE_BYTES = 64 * 1024;

function requestHeaders(context: RpcContext): Record<string, string> {
  const headers: Record<string, string> = {};
  headers['content-type'] = 'application/json';
  headers['origin'] = 'rakazo://';
  for (const key of Object.keys(context.headers)) {
    headers[key] = context.headers[key];
  }
  return headers;
}

/** Text for a code that says the voice account itself needs attention (i18n voiceAccountErrorText). */
function voiceAccountErrorText(code: string): string | null {
  if (code === 'VOICE_OUT_OF_CREDIT') {
    return t('Your voice provider is out of credit.');
  }
  if (code === 'VOICE_KEY_REJECTED') {
    return t('Your voice provider key was rejected.');
  }
  return null;
}

/** The message of a failed /api/voice body: an account code, the server's own, else `fallback`. */
function bodyError(text: string, fallback: string): Error {
  const body = parseJsonObject(text);
  const code = body !== null && typeof body['code'] === 'string' ? body['code'] as string : '';
  const account = voiceAccountErrorText(code);
  if (account !== null) {
    return new Error(account);
  }
  const message = body !== null && typeof body['error'] === 'string' ? body['error'] as string
    : body !== null && typeof body['message'] === 'string' ? body['message'] as string : '';
  return new Error(message || fallback);
}

/** Text for a transport failure: its own copy for a request that timed out, else errorText. */
function transportText(err: Object, fallback: string): string {
  const error = err instanceof RpcError ? err as RpcError : null;
  if (error !== null && error.timedOut) {
    return t('Voice request timed out.');
  }
  if (error !== null) {
    const generic = t('Something went wrong. Try again.');
    const text = errorText(error);
    return text === generic ? fallback : text;
  }
  return fallback;
}

/** voice/status: whether a voice is set up and whether it transcribes. */
export async function loadVoiceStatus(): Promise<VoiceStatusView> {
  const status = decodeVoiceStatus(await rpc('voice/status', {}));
  if (status === null) {
    throw new RpcError('Unexpected response from the server');
  }
  const view: VoiceStatusView = { ready: status.ready, transcribe: status.transcribe };
  return view;
}

/** The fields a speak or transcribe request names, as the server's own body shapes them. */
function speechTarget(text: string, options: SpeechOptions): Record<string, Object> {
  const body: Record<string, Object> = {};
  body['text'] = text;
  if (options.voiceId !== undefined && options.voiceId) {
    body['voiceId'] = options.voiceId;
  }
  if (options.botId !== undefined && options.botId) {
    body['botId'] = options.botId;
  }
  if (options.scope !== undefined) {
    body['scope'] = options.scope;
  }
  return body;
}

/**
 * voice/prepare behind the voice consent: the utterances to render, or null when no voice is set
 * up. The caller's pinned context rides along, so a speech never crosses a session.
 */
export async function prepareSpeech(text: string, options: SpeechOptions,
  context: RpcContext): Promise<string[] | null> {
  await ensureVoiceConsent(context, options.scope);
  const prepared: VoicePrepareView | null = decodeVoicePrepare(
    await rpc('voice/prepare', speechTarget(text, options), {
      context: context, timeoutMs: VOICE_RESPONSE_TIMEOUT_MS,
    }),
  );
  if (prepared === null) {
    throw new RpcError('Unexpected response from the server');
  }
  return prepared.ready ? prepared.utterances : null;
}

/** /api/voice/speak: one utterance's synthesized audio. */
export async function renderSpeech(utterance: string, options: SpeechOptions,
  context: RpcContext): Promise<Uint8Array> {
  const body = JSON.stringify(speechTarget(utterance, options));
  let response: HttpBytesResponse;
  try {
    response = await postBytes(`${context.apiBase}/api/voice/speak`, requestHeaders(context),
      new util.TextEncoder().encodeInto(body).buffer as ArrayBuffer, VOICE_RESPONSE_TIMEOUT_MS,
      MAX_VOICE_AUDIO_BYTES);
  } catch (err) {
    throw new Error(transportText(err as Object, t('Could not speak that.')));
  }
  if (response.status < 200 || response.status >= 300) {
    throw bodyError(new util.TextDecoder().decodeToString(response.bytes), t('Could not speak that.'));
  }
  return response.bytes;
}

/** A recorded clip on its way to the server: its audio as WAV bytes and the recognizer's locale. */
export interface VoiceRecording {
  audio: Uint8Array;
  language: string;
}

/** /api/voice/transcribe behind the voice consent: the words in a recorded clip. A `cancellation`
 *  ends the consent read and the transfer it is asked through, and keeps a recording whose turn
 *  was cancelled while either was pending from ever leaving the device. */
export async function transcribeRecording(recording: VoiceRecording,
  context: RpcContext, cancellation?: RequestCancellation): Promise<string> {
  await ensureVoiceConsent(context, undefined, cancellation);
  // The consent's asks may have outlived the dictation that asked for them: then its audio stays.
  cancellation?.check();
  const base64 = new util.Base64Helper().encodeToStringSync(recording.audio);
  const body: Record<string, Object> = {};
  body['audioBase64'] = base64;
  body['mimeType'] = 'audio/wav';
  body['language'] = recording.language;
  let response: HttpResponseView;
  try {
    response = await postJson(`${context.apiBase}/api/voice/transcribe`, requestHeaders(context),
      JSON.stringify(body), VOICE_RESPONSE_TIMEOUT_MS, MAX_TRANSCRIPTION_RESPONSE_BYTES, cancellation);
  } catch (err) {
    throw new Error(transportText(err as Object, t('Could not transcribe that.')));
  }
  if (response.status < 200 || response.status >= 300) {
    throw bodyError(response.body, t('Could not transcribe that.'));
  }
  let parsed: Object;
  try {
    parsed = JSON.parse(response.body);
  } catch (err) {
    return '';
  }
  return decodeTranscription(parsed);
}

/** Why a voice request never left the device: the user declined the consent disclosure. */
export function isConsentRefusal(err: Object): boolean {
  return err instanceof AiConsentBlocked;
}
