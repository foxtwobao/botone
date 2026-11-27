// The model surface of the offline fixture server (M9): the catalog, the account's saved
// connections, the connect write and the OpenAI-compatible probe. Mounted from
// spike-sse-server.mjs, the server's one daemon; the account object it writes to is the
// server's own `me` answer, so a connect shows from the next me read. Every provider, key,
// model and credential here is a fake probe, never a real one.
import { bearer, json, rpcError } from "./fixture-http.mjs";

const SPACE = "space-fake";

function seedCatalog() {
  return [
    {
      provider: "fake-provider",
      id: "fake-model",
      label: "Fake Fast Model",
      providerName: "Fake Maker",
      recommended: true,
      auth: "api-key",
      billing: "credits",
    },
    {
      provider: "fake-provider",
      id: "fake-slow",
      label: "Fake Slow Model",
      providerName: "Fake Maker",
      auth: "api-key",
      billing: "credits",
    },
    {
      provider: "fake-both",
      id: "fake-both-model",
      label: "Fake Both Model",
      providerName: "Fake Both",
      auth: "both",
      billing: "credits",
    },
    {
      provider: "fake-oauth",
      id: "fake-oauth-model",
      label: "Fake Sign-in Model",
      providerName: "Fake Sign-in",
      auth: "oauth",
      billing: "subscription",
    },
    {
      provider: "openai-compatible",
      id: "compatible-model",
      label: "Custom model",
      providerName: "OpenAI-compatible",
      placeholder: true,
      billing: "free",
    },
  ];
}

let catalog = seedCatalog();
let credentials = [];
/** One record per connect write: whether the client sent credentialId as an explicit null. */
let connects = [];
let connectionCount = 0;

/** Restores the catalog and connections; the account's model fields go back to the seed too. */
export function resetModelsFixture(me) {
  catalog = seedCatalog();
  credentials = [];
  connects = [];
  connectionCount = 0;
  me.needsModel = false;
  me.defaultProvider = "fake-provider";
  me.defaultModel = "fake-model";
}

/** A saved connection as the wire carries it: the key is never included. */
function credentialWire(entry) {
  const wire = {
    id: entry.id,
    provider: entry.provider,
    label: entry.label,
    hasKey: entry.hasKey,
    isDefault: entry.isDefault === true,
  };
  if (entry.modelId) wire.modelId = entry.modelId;
  if (entry.baseUrl) wire.baseUrl = entry.baseUrl;
  if (entry.apiProtocol) wire.apiProtocol = entry.apiProtocol;
  return wire;
}

/** The models/* RPCs; true when this route answered. `me` is the account answer the server owns. */
export function handleModelsRpc(req, res, body, me) {
  if (!req.url.startsWith("/rpc/models/")) return false;
  if (bearer(req) !== "fake-token") {
    rpcError(res, 401, "UNAUTHORIZED", "Session expired");
    return true;
  }
  const input = JSON.parse(body || "{}").json ?? {};
  if (req.url === "/rpc/models/list") {
    json(res, 200, { json: catalog });
    return true;
  }
  if (req.url === "/rpc/models/credentials") {
    json(res, 200, { json: credentials.map(credentialWire) });
    return true;
  }
  if (req.url === "/rpc/models/probeOpenAiCompatible") {
    const baseUrl = String(input.baseUrl ?? "");
    if (!baseUrl.trim() || baseUrl.includes("unreachable")) {
      rpcError(res, 502, "BAD_GATEWAY", "Could not reach this model server");
      return true;
    }
    json(res, 200, { json: { models: ["found-a", "found-b"] } });
    return true;
  }
  if (req.url === "/rpc/models/connect") {
    const provider = String(input.provider ?? "");
    const modelId = String(input.modelId ?? "").trim();
    const key = String(input.apiKey ?? "").trim();
    const baseUrl = String(input.baseUrl ?? "").trim();
    // As the real contract: an explicit null adds a connection, an omitted id updates the
    // provider's newest one (older apps send no credentialId).
    const credentialId = input.credentialId;
    const target =
      credentialId === undefined
        ? credentials.filter((entry) => entry.provider === provider).slice(-1)[0]
        : credentials.find((entry) => entry.id === credentialId);
    if (!provider) {
      rpcError(res, 400, "BAD_REQUEST", "Choose a provider");
      return true;
    }
    if (provider === "openai-compatible") {
      if (!baseUrl || !modelId) {
        rpcError(res, 400, "BAD_REQUEST", "Base URL and model id are required");
        return true;
      }
    } else {
      // An existing connection saves other settings without a new key; a new one needs 8+ chars.
      if (!target && key.length < 8) {
        rpcError(res, 400, "BAD_REQUEST", "API key must contain at least 8 characters");
        return true;
      }
    }
    if (key.startsWith("bad-")) {
      // Echoing the key is exactly what the client's mask exists for.
      rpcError(res, 422, "BAD_REQUEST", `The provider rejected API key ${key}.`);
      return true;
    }
    const providerName =
      catalog.find((entry) => entry.provider === provider)?.providerName ?? provider;
    connectionCount += 1;
    connects.push({ provider, credentialIdWasNull: credentialId === null });
    const entry = {
      id: target ? target.id : `cred-${connectionCount}`,
      provider,
      label: String(input.label ?? "").trim() || providerName,
      hasKey: key.length > 0 || target?.hasKey === true,
      modelId:
        modelId || catalog.find((row) => row.provider === provider && row.recommended)?.id || "",
      ...(baseUrl ? { baseUrl } : {}),
      ...(input.apiProtocol ? { apiProtocol: input.apiProtocol } : {}),
      isDefault: false,
    };
    if (target) {
      credentials[credentials.indexOf(target)] = entry;
    } else {
      credentials.push(entry);
    }
    const makeDefault = input.makeDefault !== false;
    if (makeDefault) {
      me.defaultProvider = provider;
      me.defaultModel = entry.modelId;
      me.needsModel = false;
    }
    const wire = credentialWire(entry);
    wire.isDefault = makeDefault;
    json(res, 200, { json: wire });
    return true;
  }
  rpcError(res, 404, "NOT_FOUND", "Not found");
  return true;
}

/** The controls the suites drive: the legacy /__models, the M9 /__modelScript, and /__modelState. */
export function handleModelsControl(req, res, body, me) {
  if (req.url === "/__models") {
    // Legacy M4 control: move the default or replace the catalog.
    const input = body ? JSON.parse(body) : {};
    if ("defaultProvider" in input) me.defaultProvider = input.defaultProvider;
    if ("defaultModel" in input) me.defaultModel = input.defaultModel;
    if (Array.isArray(input.catalog)) catalog = input.catalog;
    json(res, 200, { ok: true });
    return true;
  }
  if (req.url === "/__modelScript") {
    // {needsModel?, defaultProvider?, defaultModel?, credentials?, catalog?}
    const input = body ? JSON.parse(body) : {};
    if (typeof input.needsModel === "boolean") me.needsModel = input.needsModel;
    if ("defaultProvider" in input) me.defaultProvider = input.defaultProvider;
    if ("defaultModel" in input) me.defaultModel = input.defaultModel;
    if (Array.isArray(input.credentials)) {
      credentials = input.credentials.map((entry, index) => ({
        id: entry.id ?? `script-${index + 1}`,
        provider: entry.provider,
        label: entry.label ?? entry.provider,
        hasKey: entry.hasKey !== false,
        modelId: entry.modelId ?? "",
        ...(entry.baseUrl ? { baseUrl: entry.baseUrl } : {}),
        isDefault: false,
      }));
    }
    if (Array.isArray(input.catalog)) catalog = input.catalog;
    json(res, 200, { ok: true });
    return true;
  }
  if (req.url === "/__modelState") {
    json(res, 200, {
      catalog,
      credentials: credentials.map(credentialWire),
      connects,
      me: {
        spaceId: SPACE,
        needsModel: me.needsModel,
        defaultProvider: me.defaultProvider,
        defaultModel: me.defaultModel,
      },
    });
    return true;
  }
  return false;
}
