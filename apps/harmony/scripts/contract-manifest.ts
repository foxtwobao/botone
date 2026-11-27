// The Phase 1 consumption whitelist (design §4.3.1), as far as M4 decodes it. Every RPC view
// projects its consumed fields from the REAL appContract procedure's output schema — never a
// hand-written copy — so both a type mutation and a procedure rebind go red in the layer-1
// snapshot. Fields outside a view are ignored on device, so upstream changes there must not
// produce snapshot noise (review Q8). Grow the views in the milestone that consumes more, in
// the same PR as the decoder change. This is dev-time codegen input, not shipped code.

import { getEventIteratorSchemaDetails } from "@orpc/contract";
import {
  AiConsentQuerySchema,
  AiConsentStatusSchema,
  AiDataUseSchema,
  appContract,
  authCapabilitiesSchema,
  GroupMemberSchema,
  MessageBlock,
  MessageRole,
  ProductEventType,
  RunSchema,
  RunStatus,
  SpaceChangeKind,
  ThreadMessagePageSchema,
  ThreadMessageSchema,
  ThreadSnapshotSchema,
} from "@rakazo/contracts";
import type { z } from "zod";
import { z as zod } from "zod";

/** The output schema a real procedure declares; a missing one is a wiring error, not a view. */
function procedureOutput<T>(procedure: { "~orpc": { outputSchema?: T } }): T {
  const schema = procedure["~orpc"].outputSchema;
  if (!schema) throw new Error("contract procedure declares no output schema");
  return schema;
}

/** The input schema a real procedure declares. */
function procedureInput<T>(procedure: { "~orpc": { inputSchema?: T } }): T {
  const schema = procedure["~orpc"].inputSchema;
  if (!schema) throw new Error("contract procedure declares no input schema");
  return schema;
}

/** The event schema an eventIterator procedure yields (its `returns` is the close value). */
function eventYields<T>(procedure: { "~orpc": { outputSchema?: unknown } }): T {
  const details = getEventIteratorSchemaDetails(procedureOutput(procedure));
  if (!details?.yields) throw new Error("contract procedure is not an event iterator");
  return details.yields as T;
}

/** Pick consumed fields from an input schema that carries a superRefine (threadTarget's
 * exactly-one-of, send's text-or-attachment, answer's answer-or-dismiss). zod forbids .pick()
 * on a refined object, so rebuild a plain object from the SAME field schemas — a field type
 * mutation or rebind still goes red; the refinement itself is a hand-written sender rule +
 * fixture (§4.3.2), which toJSONSchema cannot express anyway. An intersection (models.connect
 * is ModelConnectInputSchema.and({surface, appVersion})) is followed to its left member, which
 * holds every field this client sends. */
function pickRefined(schema: z.ZodType, keys: string[]): z.ZodObject {
  let inner: unknown = schema;
  for (;;) {
    while (inner && typeof (inner as { unwrap?: unknown }).unwrap === "function") {
      inner = (inner as { unwrap: () => unknown }).unwrap();
    }
    const shape = (inner as { shape?: Record<string, z.ZodType> }).shape;
    if (shape) {
      const picked: Record<string, z.ZodType> = {};
      for (const key of keys) {
        if (!shape[key]) throw new Error(`input schema has no field ${key}`);
        picked[key] = shape[key];
      }
      return zod.object(picked);
    }
    const def =
      (inner as { def?: { left?: unknown }; _def?: { left?: unknown } })._def ??
      (inner as { def?: { left?: unknown } }).def;
    if (!def?.left) throw new Error("input schema is not an object or an intersection");
    inner = def.left;
  }
}

const healthOutput = procedureOutput(appContract.health);
const meOutput = procedureOutput(appContract.me);
const spacesListOutput = procedureOutput(appContract.spaces.list);

/** health: consumed whole (server probe and version). */
export const healthView = healthOutput;

/** me: the account fields the sign-in flow and the me page read. */
export const meView = meOutput.pick({
  userId: true,
  email: true,
  name: true,
  spaceId: true,
  needsModel: true,
  defaultProvider: true,
  defaultModel: true,
  maxUploadSizeBytes: true,
  maxAttachmentsPerMessage: true,
});

// The roster row fields M2 reads. BotSchema/GroupSchema are the real element schemas the
// procedures declare; picking from them keeps every field bound to the contract (a rebind or a
// type mutation goes red). snoozedUntil is nullable-optional: a snoozed chat hides until it wakes.
const botSchema = procedureOutput(appContract.bots.list).element;
const groupSchema = procedureOutput(appContract.groups.list).element;

/** A bot row: identity color, unread, preview, run status, pinned order, snooze, auto-speak. */
export const botView = botSchema.pick({
  id: true,
  name: true,
  color: true,
  pinned: true,
  unread: true,
  preview: true,
  status: true,
  updatedAt: true,
  snoozedUntil: true,
  /** M7: whether the bot reads its finished replies aloud (the auto-speak gate). */
  autoSpeak: true,
});

/** A group member (M8): the identity the settings picker shows; avatar set and status are not
 *  read on this client yet, so they stay out of the view. */
export const groupMemberView = GroupMemberSchema.pick({
  botId: true,
  name: true,
  color: true,
});

/** A group row: no identity color (bots carry the only color), unread, preview, pinned, snooze,
 *  and the members the group settings screen edits (identity only, projected above). */
export const groupView = groupSchema
  .pick({
    id: true,
    name: true,
    pinned: true,
    unread: true,
    preview: true,
    updatedAt: true,
    snoozedUntil: true,
  })
  .extend({ members: zod.array(groupMemberView) });

/** spaces/list: the default Space's identity plus its inbox roster (bots + groups), and the
 *  Space list a switcher names (A1: id and name only, not the roster arrays each Space carries). */
export const spacesListView = spacesListOutput.pick({ current: true }).extend({
  current: spacesListOutput.shape.current.pick({ id: true, name: true }).extend({
    bots: zod.array(botView),
    groups: zod.array(groupView),
  }),
  spaces: zod.array(spacesListOutput.shape.spaces.element.pick({ id: true, name: true })),
});

/** bots/list and bots/listArchived: the same row shape, active and archived. */
export const botsListView = zod.array(botView);
export const botsListArchivedView = zod.array(botView);
/** groups/listArchived: archived group rows. */
export const groupsListArchivedView = zod.array(groupView);

/** archive/restore: a target id in, {ok:true} out. The write the SaveController pins. */
export const botArchiveInputView = procedureInput(appContract.bots.archive);
export const botArchiveOutputView = procedureOutput(appContract.bots.archive);
export const botRestoreInputView = procedureInput(appContract.bots.restore);
export const botRestoreOutputView = procedureOutput(appContract.bots.restore);
export const groupArchiveInputView = procedureInput(appContract.groups.archive);
export const groupArchiveOutputView = procedureOutput(appContract.groups.archive);
export const groupRestoreInputView = procedureInput(appContract.groups.restore);
export const groupRestoreOutputView = procedureOutput(appContract.groups.restore);

// M8: the group creation and membership writes the group screens send. Both are plain objects
// (the botIds refinement is nested), so the input views ARE the procedures' own schemas.
export const groupCreateInputView = procedureInput(appContract.groups.create);
export const groupCreateOutputView = procedureOutput(appContract.groups.create).pick({
  id: true,
  name: true,
  members: true,
});
export const groupUpdateInputView = procedureInput(appContract.groups.update);
export const groupUpdateOutputView = groupCreateOutputView;
export const groupRemoveInputView = procedureInput(appContract.groups.remove);
export const groupRemoveOutputView = procedureOutput(appContract.groups.remove);

/** notifications/subscribe: the signal type enum the roster stream dispatches on (alert ignored). */
export const notificationsSubscribeView = eventYields<z.ZodObject<{ type: z.ZodEnum }>>(
  appContract.notifications.subscribe,
).pick({ type: true });

/** The Space change kinds the stream forwards to readers; each is one signal frame. */
export const spaceChangeKindView = SpaceChangeKind;

/** GET /api/auth/capabilities: better-auth REST, not an RPC procedure; the schema is the source. */
export const capabilitiesView = authCapabilitiesSchema.pick({
  sso: true,
  providers: true,
  passwordAuth: true,
  passwordReset: true,
  resetUrl: true,
  emailCode: true,
  registrationOpen: true,
});

// ── M3: the chat surface (design §4.3.1 threads/* + aiConsent/*, §6.4 block whitelist) ──

/** A run as the thread reducer reads it (decodeRun): lifecycle, model, error, timing. */
export const runView = RunSchema.pick({
  id: true,
  userId: true,
  botId: true,
  threadId: true,
  taskId: true,
  status: true,
  trigger: true,
  routineId: true,
  routineName: true,
  modelProvider: true,
  modelId: true,
  error: true,
  startedAt: true,
  completedAt: true,
  createdAt: true,
});

/** A group member row the snapshot carries (decodeThreadSnapshot): identity + run status. */
export const threadMemberView = GroupMemberSchema.pick({
  botId: true,
  name: true,
  color: true,
  status: true,
});

/** A message row (decodeThreadMessage). blocks stays the FULL MessageBlock union: the render
 * layer decodes each block and degrades unknown kinds, so the whole kind list is consumed. */
export const threadMessageView = ThreadMessageSchema.pick({
  id: true,
  threadId: true,
  seq: true,
  role: true,
  blocks: true,
  botId: true,
  author: true,
  replyToMessageId: true,
  replyQuote: true,
  replyPreview: true,
  runId: true,
  callId: true,
  createdAt: true,
});

/** threads/get output (decodeThreadSnapshot): the snapshot the reducer reduces onto. computer
 * and groupName are not consumed in Phase 1 (computer is Phase 2; the title comes from the row). */
export const threadSnapshotView = ThreadSnapshotSchema.pick({
  threadId: true,
  cursor: true,
  messages: true,
  olderCursor: true,
  botId: true,
  groupId: true,
  members: true,
  run: true,
  activeRuns: true,
}).extend({
  messages: zod.array(threadMessageView),
  members: zod.array(threadMemberView).optional(),
  run: runView.nullable(),
  activeRuns: zod.array(runView).optional(),
});

/** threads/messages output (decodeThreadMessagePage): a backward history page. */
export const threadMessagePageView = ThreadMessagePageSchema.pick({
  threadId: true,
  messages: true,
  olderCursor: true,
}).extend({ messages: zod.array(threadMessageView) });

/** The thread target every threads/* input names: exactly one of botId/groupId (the superRefine
 * is a hand-written sender rule + fixture, §4.3.2 — toJSONSchema cannot express it). */
export const threadTargetView = procedureInput(appContract.threads.head);

/** threads/head output: the lightweight cursor for reconnect/resume. */
export const threadHeadOutputView = procedureOutput(appContract.threads.head);

/** threads/messages input: the target plus the backward page cursor (around/peer flags unused). */
export const threadMessagesInputView = pickRefined(procedureInput(appContract.threads.messages), [
  "botId",
  "groupId",
  "before",
]);

/** threads/subscribe input: the target plus the resume cursor. */
export const threadSubscribeInputView = pickRefined(procedureInput(appContract.threads.subscribe), [
  "botId",
  "groupId",
  "cursor",
]);

/** threads/subscribe yields: the product event the reducer dispatches on, consumed whole
 * (payload stays raw — the reducer reads only identity inside it; the type enum is pinned
 * whole below). The thread.meta activity superRefine is server-side; toJSONSchema drops it. */
export const threadEventView = eventYields(appContract.threads.subscribe);

/** threads/send input: the fields the composer sends (text, nonce, target, attachments
 * and replies). The text-or-attachment superRefine is a sender rule. */
export const threadSendInputView = pickRefined(procedureInput(appContract.threads.send), [
  "botId",
  "groupId",
  "text",
  "clientNonce",
  "artifactIds",
  "replyToMessageId",
  "replyQuote",
  "imageHandling",
]);

/** threads/send output (decodeSendOutput): the receipt that shows the queued run at once. */
export const threadSendOutputView = procedureOutput(appContract.threads.send).pick({
  taskId: true,
  runId: true,
  seq: true,
});

/** threads/answer input: the ask answer (answer carries action.id; login/secret/dismiss fields
 * are Phase 2 vault). The answer-or-dismiss superRefine is a sender rule + fixture. */
export const threadAnswerInputView = pickRefined(procedureInput(appContract.threads.answer), [
  "botId",
  "groupId",
  "runId",
  "messageId",
  "answer",
]);

/** threads/stop and threads/markRead inputs are the bare target; their outputs are consumed
 * whole (stop ignores ok; markRead's unreadAfterSeq is read by the roster, not the chat). */
export const threadStopInputView = procedureInput(appContract.threads.stop);
export const threadStopOutputView = procedureOutput(appContract.threads.stop);
export const threadMarkReadInputView = procedureInput(appContract.threads.markRead);
export const threadMarkReadOutputView = procedureOutput(appContract.threads.markRead);

/** aiConsent/status input (the gate's query): target + uses; routineId unused.
 * The schema's .default({}) is unwrapped — the gate always sends an explicit query. M7's voice
 * consent names the account's copy of the settings. */
export const aiConsentStatusInputView = pickRefined(AiConsentQuerySchema, [
  "botId",
  "groupId",
  "uses",
  "settingsScope",
]);

/** aiConsent/status + allow output (decodeAiConsentStatus): the disclosure the prompt renders. */
export const aiConsentStatusOutputView = AiConsentStatusSchema;

/** aiConsent/allow input: the gate saves one recipient key per Allow (keys 1–200 is the schema's
 * own bound; the gate always sends exactly one). settingsScope rides along with the voice
 * consent's query (M7). */
export const aiConsentAllowInputView = procedureInput(appContract.aiConsent.allow).pick({
  scope: true,
  version: true,
  keys: true,
  settingsScope: true,
});

/** The full enums the reducer/render dispatch on (unknown values degrade safely). */
export const productEventTypeView = ProductEventType;
export const runStatusView = RunStatus;
export const messageRoleView = MessageRole;
export const aiDataUseView = AiDataUseSchema;

/** The full MessageBlock kind list (design §4.3.1): a new kind goes red here even though the
 * render layer already degrades it to a placeholder. */
export const messageBlockKindsView = zod.enum(
  MessageBlock.options.map((option) => option.shape.kind.value) as [string, ...string[]],
);

/** The rendered blocks' field shapes (design §6.4 whitelist): T1 full + T2 text-extract + the
 * read-only choice. Each projects the real variant's consumed fields; T3 kinds carry only kind. */
const blockVariant = (kind: string): z.ZodObject => {
  const variant = MessageBlock.options.find((option) => option.shape.kind.value === kind);
  if (!variant) throw new Error(`MessageBlock has no variant ${kind}`);
  return variant;
};
export const blockTextView = blockVariant("text");
export const blockMetaView = blockVariant("meta");
export const blockProgressView = blockVariant("progress").pick({
  kind: true,
  text: true,
  activity: true,
});
export const blockCardView = blockVariant("card");
export const blockStepsView = blockVariant("steps")
  .pick({ kind: true, steps: true })
  .extend({
    steps: zod.array(blockVariant("steps").shape.steps.element.pick({ label: true, count: true })),
  });
export const blockRoutineEventView = blockVariant("routine_event");
export const blockAskView = blockVariant("ask")
  .pick({
    kind: true,
    text: true,
    detail: true,
    input: true,
    status: true,
    answer: true,
    dismissed: true,
    expired: true,
    actions: true,
    credential: true,
    oneTimeCode: true,
    loginFields: true,
    receipt: true,
    settingsUpdate: true,
    instructionUpdate: true,
    replaces: true,
  })
  .extend({
    actions: zod
      .array(blockVariant("ask").shape.actions.unwrap().element.pick({ id: true, label: true }))
      .optional(),
  });
export const blockChoiceView = blockVariant("choice");
export const blockHandoffView = blockVariant("handoff").pick({ kind: true, text: true });
export const blockChannelMessageView = blockVariant("channel_message").pick({
  kind: true,
  fromLabel: true,
  text: true,
});
export const blockBotMessageSentView = blockVariant("bot_message_sent").pick({
  kind: true,
  toBotName: true,
  text: true,
});
export const blockBotMessageReceivedView = blockVariant("bot_message_received").pick({
  kind: true,
  fromBotName: true,
  text: true,
});
export const blockVoiceCallView = blockVariant("voice_call").pick({
  kind: true,
  title: true,
  farewell: true,
});
export const blockComputerView = blockVariant("computer").pick({ kind: true, text: true });
export const blockSubagentView = blockVariant("subagent").pick({
  kind: true,
  name: true,
  task: true,
  progress: true,
  result: true,
});
export const blockImageView = blockVariant("image").pick({
  kind: true,
  artifactId: true,
  name: true,
  mimeType: true,
});
export const blockFileView = blockVariant("file").pick({
  kind: true,
  artifactId: true,
  name: true,
  mimeType: true,
  size: true,
});
export const blockDeliveryView = blockVariant("delivery");

// ── M4: the settings surface (design §4.3.1 models/list, §4.3.4/Q6 read-only model display) ──

/** models/list: the fields the model area reads — the display's provider/id/label/providerName,
 * and what the connect screens pick a provider and model by (recommended, auth, placeholder). */
export const modelCatalogEntryView = procedureOutput(appContract.models.list).element.pick({
  provider: true,
  id: true,
  label: true,
  providerName: true,
  recommended: true,
  auth: true,
  placeholder: true,
});
export const modelsListView = zod.array(modelCatalogEntryView);

// ── M9 (slice 2): the model connection surface ──

/** models/credentials: one saved connection as the list shows it — never the key. */
export const modelCredentialView = procedureOutput(appContract.models.credentials).element.pick({
  id: true,
  provider: true,
  label: true,
  hasKey: true,
  modelId: true,
  baseUrl: true,
});
export const modelCredentialsView = zod.array(modelCredentialView);

/** models/connect input. The procedure intersects ModelConnectInputSchema (itself refined) with
 * surface/appVersion; headers is a transformed record toJSONSchema cannot express and this
 * client sends none. The intersection's left member carries every picked field. */
export const modelConnectInputView = pickRefined(procedureInput(appContract.models.connect), [
  "provider",
  "apiKey",
  "baseUrl",
  "apiProtocol",
  "label",
  "credentialId",
  "modelId",
  "thinkingLevel",
  "makeDefault",
  "scope",
  "enabledModelIds",
]);
export const modelConnectOutputView = modelCredentialView;
/** models/probeOpenAiCompatible input (headers left out for the same reason) and output. */
export const modelProbeInputView = pickRefined(
  procedureInput(appContract.models.probeOpenAiCompatible),
  ["baseUrl", "credentialId", "apiKey", "apiProtocol"],
);
export const modelProbeOutputView = procedureOutput(appContract.models.probeOpenAiCompatible);

// ── M7: the voice surface (settings, read-aloud, dictation) ──

/** voice/catalog: what picks a connection and shapes its form. */
export const voiceCatalogEntryView = procedureOutput(appContract.voice.catalog).element.pick({
  id: true,
  name: true,
  transcribe: true,
  keyless: true,
  speechModel: true,
  modelConnections: true,
  modelSignIn: true,
  freeformVoice: true,
});
export const voiceCatalogView = zod.array(voiceCatalogEntryView);
/** A saved connection (voice/credentials, voice/connect, voice/setSpeechModel): never the key. */
export const voiceCredentialView = procedureOutput(appContract.voice.connect).pick({
  id: true,
  provider: true,
  hasKey: true,
  modelCredentialId: true,
  voiceId: true,
  speechModel: true,
  transcribe: true,
  endpoint: true,
  ttsModel: true,
  sttModel: true,
});
export const voiceCredentialsView = zod.array(voiceCredentialView);
/** voice/status, voice/setVoice: which voice reads replies and whether it transcribes. */
export const voiceStatusView = procedureOutput(appContract.voice.status);
/** voice/voices: the voices a connection offers. */
export const voiceVoicesView = procedureOutput(appContract.voice.voices);
/** voice/connect input (carries a superRefine: the self-hosted address is required). */
export const voiceConnectInputView = pickRefined(procedureInput(appContract.voice.connect), [
  "provider",
  "apiKey",
  "voiceId",
  "speechModel",
  "baseUrl",
  "sttBaseUrl",
  "sttApiKey",
  "ttsModel",
  "sttModel",
  "scope",
]);
export const voiceDisconnectInputView = procedureInput(appContract.voice.disconnect);
export const voiceSetVoiceInputView = procedureInput(appContract.voice.setVoice).pick({
  scope: true,
  voiceId: true,
  provider: true,
});
export const voiceSetSpeechModelInputView = procedureInput(appContract.voice.setSpeechModel).pick({
  scope: true,
  provider: true,
  speechModel: true,
});
/** voice/prepare: the text in, the utterances to render out. */
export const voicePrepareInputView = procedureInput(appContract.voice.prepare);
export const voicePrepareOutputView = procedureOutput(appContract.voice.prepare);

/** Every snapshot the layer-1 test pins, keyed by the file name under snapshots/. */
export const snapshotViews: Record<string, z.ZodType> = {
  health: healthView,
  me: meView,
  "spaces-list": spacesListView,
  "bots-list": botsListView,
  "bots-list-archived": botsListArchivedView,
  "groups-list-archived": groupsListArchivedView,
  "bot-archive-input": botArchiveInputView,
  "bot-archive-output": botArchiveOutputView,
  "bot-restore-input": botRestoreInputView,
  "bot-restore-output": botRestoreOutputView,
  "group-archive-input": groupArchiveInputView,
  "group-archive-output": groupArchiveOutputView,
  "group-restore-input": groupRestoreInputView,
  "group-restore-output": groupRestoreOutputView,
  "group-member": groupMemberView,
  "group-create-input": groupCreateInputView,
  "group-create-output": groupCreateOutputView,
  "group-update-input": groupUpdateInputView,
  "group-update-output": groupUpdateOutputView,
  "group-remove-input": groupRemoveInputView,
  "group-remove-output": groupRemoveOutputView,
  "notifications-subscribe": notificationsSubscribeView,
  "space-change-kind": spaceChangeKindView,
  "auth-capabilities": capabilitiesView,
  // M3 chat surface
  "thread-snapshot": threadSnapshotView,
  "thread-message-page": threadMessagePageView,
  "thread-message": threadMessageView,
  "thread-run": runView,
  "thread-member": threadMemberView,
  "thread-target": threadTargetView,
  "thread-head-output": threadHeadOutputView,
  "thread-messages-input": threadMessagesInputView,
  "thread-subscribe-input": threadSubscribeInputView,
  "thread-event": threadEventView,
  "thread-send-input": threadSendInputView,
  "thread-send-output": threadSendOutputView,
  "thread-answer-input": threadAnswerInputView,
  "thread-stop-input": threadStopInputView,
  "thread-stop-output": threadStopOutputView,
  "thread-markread-input": threadMarkReadInputView,
  "thread-markread-output": threadMarkReadOutputView,
  "ai-consent-status-input": aiConsentStatusInputView,
  "ai-consent-status-output": aiConsentStatusOutputView,
  "ai-consent-allow-input": aiConsentAllowInputView,
  "product-event-type": productEventTypeView,
  "run-status": runStatusView,
  "message-role": messageRoleView,
  "ai-data-use": aiDataUseView,
  "message-block-kinds": messageBlockKindsView,
  "block-text": blockTextView,
  "block-meta": blockMetaView,
  "block-progress": blockProgressView,
  "block-card": blockCardView,
  "block-steps": blockStepsView,
  "block-routine-event": blockRoutineEventView,
  "block-ask": blockAskView,
  "block-choice": blockChoiceView,
  "block-handoff": blockHandoffView,
  "block-channel-message": blockChannelMessageView,
  "block-bot-message-sent": blockBotMessageSentView,
  "block-bot-message-received": blockBotMessageReceivedView,
  "block-voice-call": blockVoiceCallView,
  "block-computer": blockComputerView,
  "block-subagent": blockSubagentView,
  "block-image": blockImageView,
  "block-file": blockFileView,
  "block-delivery": blockDeliveryView,
  // M6 attachment surface
  "artifact-create-input": procedureInput(appContract.artifacts.create),
  "artifact-create-output": procedureOutput(appContract.artifacts.create).pick({ id: true }),
  "artifact-get-input": procedureInput(appContract.artifacts.get),
  "artifact-get-output": procedureOutput(appContract.artifacts.get).pick({
    id: true,
    size: true,
    contentBase64: true,
  }),
  // M7 voice surface
  "voice-catalog": voiceCatalogView,
  "voice-catalog-entry": voiceCatalogEntryView,
  "voice-credentials": voiceCredentialsView,
  "voice-credential": voiceCredentialView,
  "voice-status": voiceStatusView,
  "voice-voices": voiceVoicesView,
  "voice-connect-input": voiceConnectInputView,
  "voice-disconnect-input": voiceDisconnectInputView,
  "voice-set-voice-input": voiceSetVoiceInputView,
  "voice-set-speech-model-input": voiceSetSpeechModelInputView,
  "voice-prepare-input": voicePrepareInputView,
  "voice-prepare-output": voicePrepareOutputView,
  // M4 settings surface
  "models-list": modelsListView,
  "model-catalog-entry": modelCatalogEntryView,
  "model-credential": modelCredentialView,
  "model-credentials": modelCredentialsView,
  "model-connect-input": modelConnectInputView,
  "model-connect-output": modelConnectOutputView,
  "model-probe-input": modelProbeInputView,
  "model-probe-output": modelProbeOutputView,
};
