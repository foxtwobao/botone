// threads/send receipt decode + client nonce (design §6.5: no optimistic bubble — send returns
// only after the message and run are durable; the receipt gives the queued run state at once and
// the user message arrives over the open stream). The nonce is the core newClientId UUID shape.
import { asRecord } from '../contract/decode';
import type { SendReceipt } from './thread-snapshot';

export const THREAD_MESSAGE_TEXT_MAX_LENGTH = 100_000;

export function sendTarget(botId: string, groupId: string): Record<string, Object> {
  const body: Record<string, Object> = {};
  if (groupId) {
    body['groupId'] = groupId;
  } else {
    body['botId'] = botId;
  }
  return body;
}

/** Wire shape of the mobile composer's regular send. The server assembles the blocks. */
export function threadSendBody(botId: string, groupId: string, text: string, artifactIds: string[],
  replyToMessageId: string, nonce: string, imagesAsFiles: boolean): Record<string, Object> {
  const body = sendTarget(botId, groupId);
  body['clientNonce'] = nonce;
  body['imageHandling'] = imagesAsFiles ? 'file' : 'confirm';
  if (text.trim()) {
    body['text'] = text.trim();
  }
  if (artifactIds.length) {
    body['artifactIds'] = artifactIds;
  }
  if (replyToMessageId) {
    body['replyToMessageId'] = replyToMessageId;
  }
  return body;
}

export interface SendOutput {
  taskId: string;
  runId: string;
  seq: number;
}

export function decodeSendOutput(json: Object | null): SendOutput | null {
  const record = asRecord(json);
  if (record === null) {
    return null;
  }
  const taskId = record['taskId'];
  const runId = record['runId'];
  const seq = record['seq'];
  if (typeof taskId !== 'string' || !(taskId as string) || typeof runId !== 'string'
    || !(runId as string) || typeof seq !== 'number') {
    return null;
  }
  const output: SendOutput = { taskId: taskId as string, runId: runId as string, seq: seq as number };
  return output;
}

/** The receipt applyThreadSendReceipt takes, built from the send answer and the tapped bot. */
export function sendReceipt(botId: string, output: SendOutput): SendReceipt {
  const receipt: SendReceipt = { botId: botId, runId: output.runId, taskId: output.taskId };
  return receipt;
}

function hex(bytes: Uint8Array): string {
  let text = '';
  for (const byte of bytes) {
    text += byte.toString(16).padStart(2, '0');
  }
  return text;
}

/** A client nonce in the core newClientId UUID v4 shape (bounded to the contract's 200 chars). */
export function newClientNonce(): string {
  const bytes = new Uint8Array(16);
  for (let index = 0; index < 16; index += 1) {
    bytes[index] = Math.floor(Math.random() * 256);
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const value = hex(bytes);
  return `${value.slice(0, 8)}-${value.slice(8, 12)}-${value.slice(12, 16)}-${value.slice(16, 20)}-${value.slice(20)}`;
}
