// Differential check for the model-connection ports (M9): the ArkTS decisions against the layer-2
// models fixture, which scripts/gen-fixtures.ts records by driving the REAL core functions
// (connectionFormModelId, pickCatalogModelId, modelConnectRequest) and the REAL contracts rules
// (normalizeOpenAiCompatibleBaseUrl, openAiCompatibleConnectReady). The ports are the .ets sources
// loaded as erasable TypeScript, the trick the other harmony port tests use. The recorded connect
// expectation drops the fields this client deliberately never sends (protocol, effort, headers).
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { afterAll, describe, expect, it } from "vitest";
import type * as connectPort from "../entry/src/main/ets/features/models/model-connect-request.ets";
import type * as providersPort from "../entry/src/main/ets/features/models/model-providers.ets";

const appRoot = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const modelsDir = path.join(appRoot, "entry/src/main/ets/features/models");
const outDir = mkdtempSync(path.join(tmpdir(), "harmony-model-port-"));
afterAll(() => rmSync(outDir, { force: true, recursive: true }));
writeFileSync(
  path.join(outDir, "model-providers.ts"),
  readFileSync(path.join(modelsDir, "model-providers.ets"), "utf8"),
);
writeFileSync(
  path.join(outDir, "model-connect-request.ts"),
  readFileSync(path.join(modelsDir, "model-connect-request.ets"), "utf8").replace(
    "from './model-providers'",
    "from './model-providers.ts'",
  ),
);
const providers = (await import(
  pathToFileURL(path.join(outDir, "model-providers.ts")).href
)) as typeof providersPort;
const connect = (await import(
  pathToFileURL(path.join(outDir, "model-connect-request.ts")).href
)) as typeof connectPort;

interface ModelEntry {
  provider: string;
  id: string;
  label: string;
  providerName: string | null;
  recommended: boolean;
  auth: string | null;
  placeholder: boolean;
}
interface ModelsFixture {
  formModel: {
    catalog: ModelEntry[];
    provider: string;
    credential: { modelId: string } | null;
    defaults: { defaultProvider: string | null; defaultModel: string | null } | null;
    current: string;
    expected: string;
  }[];
  pick: { catalog: ModelEntry[]; provider: string; preferredId: string | null; expected: string }[];
  connectRequest: {
    form: { enabledModelIds: string[]; baseUrl: string; modelId: string; apiKey: string };
    selected: ModelEntry;
    credential: { modelId: string } | null;
    credentialId: string | null;
    makeDefault: boolean;
    scope: string;
    expected: Record<string, unknown>;
  }[];
  connectReady: {
    baseUrl: string;
    modelId: string;
    apiKey: string;
    keyRequired: boolean;
    expected: boolean;
  }[];
}
const fixture = JSON.parse(
  readFileSync(path.join(appRoot, "contract/fixtures/models.json"), "utf8"),
) as ModelsFixture;

describe("model provider port", () => {
  it("picks the same catalog model on every recorded case", () => {
    for (const entry of fixture.pick) {
      expect(
        providers.pickCatalogModelId(entry.catalog, entry.provider, entry.preferredId),
        JSON.stringify([entry.provider, entry.preferredId]),
      ).toBe(entry.expected);
    }
  });

  it("opens the form on the same model on every recorded case", () => {
    for (const entry of fixture.formModel) {
      expect(
        providers.connectionFormModelId({
          catalog: entry.catalog,
          provider: entry.provider,
          credential: entry.credential,
          defaults: entry.defaults,
          current: entry.current,
        }),
        JSON.stringify([entry.provider, entry.current, entry.credential, entry.defaults]),
      ).toBe(entry.expected);
    }
  });

  it("keeps the port's own conventions on unrecorded edges", () => {
    const entries: ModelEntry[] = [
      {
        provider: "p",
        id: "m1",
        label: "M1",
        providerName: null,
        recommended: false,
        auth: null,
        placeholder: false,
      },
    ];
    expect(providers.canonicalPiProviderId("azure-openai-responses")).toBe("azure");
    expect(providers.canonicalPiProviderId("azure")).toBe("azure");
    expect(providers.canonicalPiProviderId("openai")).toBe("openai");
    expect(providers.pickCatalogModelId(entries, "p", "")).toBe("m1");
    expect(providers.pickCatalogModelId(entries, "p", null)).toBe("m1");
    expect(
      providers.connectionFormModelId({
        catalog: entries,
        provider: "p",
        credential: null,
        defaults: null,
        current: "missing",
      }),
    ).toBe("m1");
  });
});

describe("model connect request port", () => {
  it("sends the same connect input on every recorded case", () => {
    for (const entry of fixture.connectRequest) {
      const result = connect.modelConnectRequest({
        form: entry.form,
        selected: entry.selected,
        credential: entry.credential,
        credentialId: entry.credentialId,
        makeDefault: entry.makeDefault,
        scope: entry.scope,
      });
      expect(JSON.parse(JSON.stringify(result)), JSON.stringify(entry.form)).toEqual(
        entry.expected,
      );
    }
  });

  it("never sends the protocol, effort or header fields", () => {
    // Recorded case 7 is a ready compatible connect (address and model only).
    const entry = fixture.connectRequest[7];
    const result = connect.modelConnectRequest({
      form: entry.form,
      selected: entry.selected,
      credential: entry.credential,
      credentialId: entry.credentialId,
      makeDefault: entry.makeDefault,
      scope: entry.scope,
    });
    const input = result.input as Record<string, unknown>;
    expect("apiProtocol" in input).toBe(false);
    expect("thinkingLevel" in input).toBe(false);
    expect("headers" in input).toBe(false);
  });

  it("carries the compatible key only when one was typed", () => {
    // Recorded case 7 has no key; case 8 carries one with surrounding spaces.
    const empty = fixture.connectRequest[7];
    const withKey = fixture.connectRequest[8];
    const send = (entry: (typeof fixture.connectRequest)[number]) =>
      connect.modelConnectRequest({
        form: entry.form,
        selected: entry.selected,
        credential: entry.credential,
        credentialId: entry.credentialId,
        makeDefault: entry.makeDefault,
        scope: entry.scope,
      }).input as Record<string, unknown>;
    expect("apiKey" in send(empty)).toBe(false);
    expect(send(withKey).apiKey).toBe("key-1234");
  });

  it("matches the real contract's compatible readiness on every recorded case", () => {
    for (const entry of fixture.connectReady) {
      expect(
        connect.openAiCompatibleConnectReady(
          entry.baseUrl,
          entry.modelId,
          entry.apiKey,
          entry.keyRequired,
        ),
        JSON.stringify(entry),
      ).toBe(entry.expected);
    }
  });
});
