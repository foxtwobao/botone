// The model-connection fixture (M9): drive the REAL core decisions (connectionFormModelId,
// pickCatalogModelId, modelConnectRequest) and contracts rules (normalizeOpenAiCompatibleBaseUrl,
// openAiCompatibleConnectReady) and record their answers. The vitest port test replays the ArkTS
// ports against this file; hypium replays the same cases on device, where the kit's own URL parser
// runs for the address rule. The shipped form sends no protocol, effort or header fields, so the
// recorded connect input drops them (the port never emits them either).
import type { ModelCatalogEntry } from "@rakazo/contracts";
import { normalizeOpenAiCompatibleBaseUrl, openAiCompatibleConnectReady } from "@rakazo/contracts";
import { connectionFormModelId, modelConnectRequest, pickCatalogModelId } from "@rakazo/core";

interface ModelEntry {
  provider: string;
  id: string;
  label: string;
  providerName: string | null;
  recommended: boolean;
  auth: string | null;
  placeholder: boolean;
}
interface ConnectForm {
  enabledModelIds: string[];
  baseUrl: string;
  modelId: string;
  apiKey: string;
}
interface ModelConnectCase {
  form: ConnectForm;
  selected: ModelEntry;
  credential: { modelId: string } | null;
  credentialId: string | null;
  makeDefault: boolean;
  scope: string;
  expected: Record<string, unknown>;
}
export interface ModelsFixture {
  /** connectionFormModelId: the model a connection form opens on. */
  formModel: {
    catalog: ModelEntry[];
    provider: string;
    credential: { modelId: string } | null;
    defaults: { defaultProvider: string | null; defaultModel: string | null } | null;
    current: string;
    expected: string;
  }[];
  /** pickCatalogModelId: the provider row's preselected model. */
  pick: { catalog: ModelEntry[]; provider: string; preferredId: string | null; expected: string }[];
  /** normalizeOpenAiCompatibleBaseUrl: ok/url, or the contract's refusal message. */
  normalize: { input: string; ok: boolean; url?: string; error?: string }[];
  /** modelConnectRequest: the `models/connect` input, or incomplete. */
  connectRequest: ModelConnectCase[];
  /** openAiCompatibleConnectReady. */
  connectReady: {
    baseUrl: string;
    modelId: string;
    apiKey: string;
    keyRequired: boolean;
    expected: boolean;
  }[];
}

/** Drops the fields this client deliberately never sends from the recorded expectation. */
function harmonyConnect(result: ReturnType<typeof modelConnectRequest>): Record<string, unknown> {
  const expected = JSON.parse(JSON.stringify(result)) as Record<string, unknown>;
  const input = expected.input as Record<string, unknown> | undefined;
  if (input) {
    delete input.apiProtocol;
    delete input.thinkingLevel;
    delete input.headers;
  }
  return expected;
}

function modelEntry(provider: string, id: string, over: Partial<ModelEntry> = {}): ModelEntry {
  return {
    provider,
    id,
    label: `Model ${id}`,
    providerName: "Fake Maker",
    recommended: false,
    auth: null,
    placeholder: false,
    ...over,
  };
}

/** The real core/contract types take catalog entries; this strips the decoder-only fields. */
function coreEntry(entry: ModelEntry): ModelCatalogEntry {
  return {
    provider: entry.provider,
    id: entry.id,
    label: entry.label,
    billing: "credits",
    ...(entry.providerName === null ? {} : { providerName: entry.providerName }),
    ...(entry.recommended ? { recommended: true } : {}),
    ...(entry.auth === null ? {} : { auth: entry.auth }),
    ...(entry.placeholder ? { placeholder: true } : {}),
  } as ModelCatalogEntry;
}

export function generateModelsFixture(): ModelsFixture {
  const recommended = modelEntry("p", "m1", { recommended: true });
  const second = modelEntry("p", "m2");
  const catalog = [recommended, second];
  const compatible = modelEntry("openai-compatible", "custom", {
    providerName: "OpenAI-compatible",
    placeholder: true,
  });

  const gpt = [modelEntry("p", "gpt-6", { recommended: true })];
  const azure = [modelEntry("azure", "azure-model")];
  const pickList: ModelsFixture["pick"] = [
    { catalog, provider: "p", preferredId: "m2", expected: pickCatalogModelId(catalog, "p", "m2") },
    { catalog, provider: "p", preferredId: null, expected: pickCatalogModelId(catalog, "p", null) },
    {
      catalog: gpt,
      provider: "p",
      preferredId: "openai/gpt-6",
      expected: pickCatalogModelId(gpt, "p", "openai/gpt-6"),
    },
    {
      catalog: azure,
      provider: "azure-openai-responses",
      preferredId: "azure-model",
      expected: pickCatalogModelId(azure, "azure-openai-responses", "azure-model"),
    },
    {
      catalog: [second],
      provider: "p",
      preferredId: null,
      expected: pickCatalogModelId([second], "p", null),
    },
    {
      catalog,
      provider: "none",
      preferredId: "m1",
      expected: pickCatalogModelId(catalog, "none", "m1"),
    },
    { catalog: [], provider: "p", preferredId: null, expected: pickCatalogModelId([], "p", null) },
  ];

  const formModel: ModelsFixture["formModel"] = [
    {
      catalog,
      provider: "p",
      credential: null,
      defaults: null,
      current: "",
      expected: connectionFormModelId({
        catalog: catalog.map(coreEntry),
        provider: "p",
        current: "",
      }),
    },
    {
      catalog,
      provider: "p",
      credential: null,
      defaults: null,
      current: "m2",
      expected: connectionFormModelId({
        catalog: catalog.map(coreEntry),
        provider: "p",
        current: "m2",
      }),
    },
    {
      catalog,
      provider: "p",
      credential: { modelId: "m2" },
      defaults: null,
      current: "",
      expected: connectionFormModelId({
        catalog: catalog.map(coreEntry),
        provider: "p",
        credential: { modelId: "m2" },
        current: "",
      }),
    },
    {
      catalog,
      provider: "p",
      credential: null,
      defaults: { defaultProvider: "p", defaultModel: "m2" },
      current: "",
      expected: connectionFormModelId({
        catalog: catalog.map(coreEntry),
        provider: "p",
        defaults: { defaultProvider: "p", defaultModel: "m2" },
        current: "",
      }),
    },
    {
      catalog,
      provider: "p",
      credential: null,
      defaults: { defaultProvider: "q", defaultModel: "m2" },
      current: "",
      expected: connectionFormModelId({
        catalog: catalog.map(coreEntry),
        provider: "p",
        defaults: { defaultProvider: "q", defaultModel: "m2" },
        current: "",
      }),
    },
    {
      catalog: [compatible],
      provider: "openai-compatible",
      credential: { modelId: "server-model" },
      defaults: null,
      current: "",
      expected: connectionFormModelId({
        catalog: [coreEntry(compatible)],
        provider: "openai-compatible",
        credential: { modelId: "server-model" },
        current: "",
      }),
    },
    {
      catalog: [compatible],
      provider: "openai-compatible",
      credential: null,
      defaults: null,
      current: "custom",
      expected: connectionFormModelId({
        catalog: [coreEntry(compatible)],
        provider: "openai-compatible",
        current: "custom",
      }),
    },
  ];

  const normalizeInputs = [
    "",
    "   ",
    "example.com",
    "https://example.com",
    "https://example.com/",
    "https://example.com/v1/",
    "https://example.com/v1/chat/completions",
    "https://example.com/chat/completions",
    "https://example.com/openai",
    "https://example.com/v4",
    "https://api.example.com/v1beta",
    "https://example.com/completions",
    "https://example.com/models",
    "ftp://example.com",
    "https://user:pass@example.com",
    "https://model.example:443/v1",
    "http://model.example:80",
    "http://[::1]:8080",
    "http://[::1]:8080/v1",
    "not a url",
    "https://example.com?x=1",
    "https://example.com/path?x=1#frag",
  ];
  const normalize: ModelsFixture["normalize"] = normalizeInputs.map((input) => {
    try {
      return { input, ok: true, url: normalizeOpenAiCompatibleBaseUrl(input) };
    } catch (error) {
      return { input, ok: false, error: (error as Error).message };
    }
  });

  // A padded value the connect form trims; a constant so no secret scanner reads it as a key.
  const PADDED_PROBE_VALUE = "  key-1234  ";

  const connectCase = (
    form: Partial<ConnectForm>,
    selected: ModelEntry,
    credential: { modelId: string } | null,
    credentialId: string | null,
    makeDefault: boolean,
    scope: string,
  ): ModelConnectCase => {
    const fullForm: ConnectForm = {
      enabledModelIds: [],
      baseUrl: "",
      modelId: "",
      apiKey: "",
      ...form,
    };
    const result = modelConnectRequest({
      form: {
        ...fullForm,
        apiProtocol: "chat-completions",
        thinkingLevel: null,
        headerRows: null,
        accountId: "",
        gatewayId: "",
      },
      selected: coreEntry(selected),
      credential: credential ?? undefined,
      credentialId,
      makeDefault: { makeDefault, scope: scope as "account" | "space" },
    });
    return {
      form: fullForm,
      selected,
      credential,
      credentialId,
      makeDefault,
      scope,
      expected: harmonyConnect(result),
    };
  };

  const connectRequest: ModelConnectCase[] = [
    connectCase({ apiKey: "short" }, recommended, null, null, true, "account"),
    connectCase({}, recommended, null, null, true, "account"),
    connectCase({}, recommended, { modelId: "m1" }, null, true, "account"),
    connectCase({ apiKey: "12345678" }, second, null, "cred-1", false, "account"),
    connectCase(
      { apiKey: "12345678" },
      modelEntry("p2", "m2", { providerName: null }),
      null,
      null,
      true,
      "account",
    ),
    connectCase({}, compatible, null, null, true, "account"),
    connectCase({ baseUrl: "https://models.example/v1" }, compatible, null, null, true, "account"),
    connectCase(
      { baseUrl: " https://models.example/v1 ", modelId: " m ", enabledModelIds: ["a", "m", "b"] },
      compatible,
      null,
      null,
      false,
      "account",
    ),
    connectCase(
      // A value that only passes once the form trims it; named so no scanner reads it as a real key.
      { baseUrl: "https://models.example/v1", modelId: "m", apiKey: PADDED_PROBE_VALUE },
      compatible,
      null,
      null,
      true,
      "account",
    ),
  ];

  const readyInputs: {
    baseUrl: string;
    modelId: string;
    apiKey: string;
    keyRequired: boolean;
  }[] = [
    { baseUrl: "", modelId: "m", apiKey: "", keyRequired: false },
    { baseUrl: "https://x.example", modelId: "", apiKey: "", keyRequired: false },
    { baseUrl: "https://x.example", modelId: "m", apiKey: "", keyRequired: false },
    { baseUrl: "https://x.example", modelId: "m", apiKey: "", keyRequired: true },
    { baseUrl: "https://x.example", modelId: "m", apiKey: "  ", keyRequired: true },
    { baseUrl: " https://x.example ", modelId: " m ", apiKey: "key", keyRequired: true },
  ];
  const connectReady = readyInputs.map((input) => ({
    ...input,
    expected: openAiCompatibleConnectReady(input),
  }));

  return { formModel, pick: pickList, normalize, connectRequest, connectReady };
}
