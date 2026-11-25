// Layer-2 consent drift detection at the REAL transport boundary (design §4.3.3 ⇩v3): drive the
// real mobile rpc() with a stubbed fetch that records every request reaching the transport, and
// pin the dispatch sequence for each consent scenario — including the three session-generation
// insertion points. The committed fixture is what the ArkTS gate replays under hypium; an upstream
// change to the gate semantics (order, coalescing, the generation re-check) goes red here even
// when no schema moved. Update path: HARMONY_UPDATE_FIXTURES=1 vitest, port, commit both.
vi.mock("@rakazo/mobile/lib/settings/ai-consent.js", () => ({ promptAiConsent: vi.fn() }));
vi.mock("react-native", () => ({ Platform: { OS: "ios" } }));
vi.mock("expo-secure-store", () => ({
  getItemAsync: vi.fn(async () => ""),
  setItemAsync: vi.fn(async () => undefined),
  deleteItemAsync: vi.fn(async () => undefined),
}));
vi.mock("@rakazo/mobile/lib/notifications/live-notifications.js", () => ({
  resumeLiveNotifications: vi.fn(async () => undefined),
  stopLiveNotifications: vi.fn(async () => undefined),
}));
vi.mock("@rakazo/mobile/lib/api/network-cache.js", () => ({ clearNetworkCache: vi.fn() }));

import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { rpc, setCachedApiBase } from "@rakazo/mobile/lib/api/api.js";
import { saveApiBase } from "@rakazo/mobile/lib/api/api-server.js";
import {
  jsonResponse,
  mockSecureStore,
  rpcErrorResponse,
} from "@rakazo/mobile/lib/api/api-test-helpers.js";
import { restoreSessionToken, saveSessionToken } from "@rakazo/mobile/lib/api/session.js";
import { promptAiConsent } from "@rakazo/mobile/lib/settings/ai-consent.js";
import * as SecureStore from "expo-secure-store";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { writeGenerated } from "./write-generated";

const fixturesDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "fixtures");
const update = process.env.HARMONY_UPDATE_FIXTURES === "1";

const BASE = "https://consent-a.example";
const OTHER = "https://consent-b.example";
const SCOPE = "account-space";
const VERSION = "2026-11-12";

function recipient(key: string, over: Record<string, unknown> = {}) {
  return { key, name: `Provider ${key}`, use: "model", detail: "", allowed: false, ...over };
}

function statusBody(recipients: unknown[], privacyUrl?: string) {
  return {
    json: {
      scope: SCOPE,
      version: VERSION,
      recipients,
      ...(privacyUrl ? { privacyUrl } : {}),
    },
  };
}

interface TransportCall {
  path: string;
  body: unknown;
  base: string;
}
interface PromptCall {
  key: string;
  name: string;
  use: string;
  detail: string;
  privacyUrl?: string;
}
interface ConsentScenario {
  name: string;
  proc: "threads/send" | "threads/answer";
  body: Record<string, unknown>;
  /** What the transport answers per request, in call order; a function answers by path/body. */
  responses: { status?: number; body?: unknown; fail?: boolean }[];
  /** The user's answers in prompt order. */
  promptAnswers: boolean[];
  /** Session events injected at deterministic points (see runScenario). */
  sessionEvent?: "token-during-prompt" | "token-before-allow-response" | "server-during-prompt";
  concurrent?: boolean;
  expected: {
    transport: TransportCall[];
    promptCalls: PromptCall[];
    error?: string;
    errors?: string[];
  };
}

/** Drive one scenario against the real rpc and record what reached the transport. */
async function runScenario(
  scenario: Omit<ConsentScenario, "expected">,
): Promise<ConsentScenario["expected"]> {
  const store = new Map<string, string>();
  mockSecureStore(store);
  await restoreSessionToken("");
  setCachedApiBase(BASE);
  await saveSessionToken("token-a");

  const transport: TransportCall[] = [];
  const promptCalls: PromptCall[] = [];
  let answerIndex = 0;
  let responseIndex = 0;
  let allowSeen = false;

  vi.mocked(promptAiConsent).mockImplementation(
    async (r: { key: string; name: string; use: string; detail: string }, privacyUrl?: string) => {
      promptCalls.push({
        key: r.key,
        name: r.name,
        use: r.use,
        detail: r.detail,
        ...(privacyUrl !== undefined ? { privacyUrl } : {}),
      });
      if (scenario.sessionEvent === "token-during-prompt") {
        await saveSessionToken("token-b");
      }
      if (scenario.sessionEvent === "server-during-prompt") {
        const switched = await saveApiBase(OTHER);
        expect(switched.ok).toBe(true);
      }
      const answer = scenario.promptAnswers[answerIndex] ?? false;
      answerIndex += 1;
      return answer;
    },
  );

  vi.stubGlobal(
    "fetch",
    vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      const parsed = new URL(String(url));
      const body = init?.body ? JSON.parse(String(init.body)).json : undefined;
      transport.push({ path: parsed.pathname, body, base: parsed.origin });
      const spec = scenario.responses[responseIndex] ?? { body: { json: { ok: true } } };
      responseIndex += 1;
      if (
        scenario.sessionEvent === "token-before-allow-response" &&
        parsed.pathname.endsWith("/aiConsent/allow") &&
        !allowSeen
      ) {
        allowSeen = true;
        await saveSessionToken("token-b");
      }
      if (spec.fail) throw new TypeError("fetch failed");
      if (spec.body !== undefined) return jsonResponse(spec.body, { status: spec.status ?? 200 });
      return rpcErrorResponse(spec.status ?? 500, "INTERNAL", "Server fault");
    }),
  );

  const errors: string[] = [];
  if (scenario.concurrent) {
    const results = await Promise.allSettled([
      rpc(scenario.proc, scenario.body as never),
      rpc(scenario.proc, scenario.body as never),
    ]);
    for (const result of results) {
      if (result.status === "rejected") errors.push(String((result.reason as Error).message));
    }
  } else {
    try {
      await rpc(scenario.proc, scenario.body as never);
    } catch (error) {
      errors.push(String((error as Error).message));
    }
  }
  return {
    transport,
    promptCalls,
    ...(errors.length === 1 ? { error: errors[0] } : {}),
    ...(errors.length > 1 ? { errors } : {}),
  };
}

const SEND_BODY = { botId: "bot-1", text: "private content", clientNonce: "nonce-1" };
const ANSWER_BODY = { botId: "bot-1", runId: "run-1", messageId: "msg-1", answer: "allow" };

function scenarios(): Omit<ConsentScenario, "expected">[] {
  const list: Omit<ConsentScenario, "expected">[] = [];
  for (const proc of ["threads/send", "threads/answer"] as const) {
    const body = proc === "threads/send" ? SEND_BODY : ANSWER_BODY;
    list.push(
      {
        name: `${proc}: all allowed dispatches without a prompt`,
        proc,
        body,
        responses: [
          { body: statusBody([recipient("k1", { allowed: true })]) },
          { body: { json: { ok: true } } },
        ],
        promptAnswers: [],
      },
      {
        name: `${proc}: one unallowed recipient, Allow saves then dispatches`,
        proc,
        body,
        responses: [
          { body: statusBody([recipient("k1")], "https://example.com/privacy") },
          { body: statusBody([recipient("k1", { allowed: true })]) },
          { body: { json: { ok: true } } },
        ],
        promptAnswers: [true],
      },
      {
        name: `${proc}: two recipients, second refused after the first Allow`,
        proc,
        body,
        responses: [
          { body: statusBody([recipient("k1"), recipient("k2", { use: "memory" })]) },
          { body: statusBody([recipient("k1", { allowed: true })]) },
        ],
        promptAnswers: [true, false],
      },
      {
        name: `${proc}: refusal blocks the dispatch`,
        proc,
        body,
        responses: [{ body: statusBody([recipient("k1")]) }],
        promptAnswers: [false],
      },
      {
        name: `${proc}: a failed status query blocks the dispatch`,
        proc,
        body,
        responses: [{ fail: true }],
        promptAnswers: [],
      },
      {
        name: `${proc}: status 404 asks for a server update`,
        proc,
        body,
        responses: [
          { status: 404, body: { json: { code: "NOT_FOUND", status: 404, message: "Not found" } } },
        ],
        promptAnswers: [],
      },
      {
        name: `${proc}: a failed allow save blocks the dispatch`,
        proc,
        body,
        responses: [{ body: statusBody([recipient("k1")]) }, { status: 500 }],
        promptAnswers: [true],
      },
      {
        name: `${proc}: concurrent sends share one prompt and each dispatch once`,
        proc,
        body,
        concurrent: true,
        responses: [
          { body: statusBody([recipient("k1")]) },
          { body: statusBody([recipient("k1")]) },
          { body: statusBody([recipient("k1", { allowed: true })]) },
          { body: { json: { ok: true } } },
          { body: { json: { ok: true } } },
        ],
        promptAnswers: [true],
      },
      {
        name: `${proc}: concurrent refusal grants nothing and dispatches nothing`,
        proc,
        body,
        concurrent: true,
        responses: [
          { body: statusBody([recipient("k1")]) },
          { body: statusBody([recipient("k1")]) },
        ],
        promptAnswers: [false],
      },
      {
        name: `${proc}: a sign-in during the prompt blocks allow and dispatch`,
        proc,
        body,
        sessionEvent: "token-during-prompt",
        responses: [{ body: statusBody([recipient("k1")]) }],
        promptAnswers: [true],
      },
      {
        name: `${proc}: a sign-in before the allow response blocks the dispatch`,
        proc,
        body,
        sessionEvent: "token-before-allow-response",
        responses: [
          { body: statusBody([recipient("k1")]) },
          { body: statusBody([recipient("k1", { allowed: true })]) },
        ],
        promptAnswers: [true],
      },
      {
        name: `${proc}: a server switch during the prompt keeps every request on the old server`,
        proc,
        body,
        sessionEvent: "server-during-prompt",
        responses: [{ body: statusBody([recipient("k1")]) }],
        promptAnswers: [true],
      },
    );
  }
  return list;
}

async function generateConsentFixture(): Promise<{ scenarios: ConsentScenario[] }> {
  const generated: ConsentScenario[] = [];
  for (const scenario of scenarios()) {
    const expected = await runScenario(scenario);
    generated.push({ ...scenario, expected });
  }
  return { scenarios: generated };
}

beforeEach(() => {
  vi.mocked(SecureStore.getItemAsync).mockResolvedValue("");
  vi.mocked(promptAiConsent).mockReset();
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe("harmony consent dispatch fixture", () => {
  it("fixture consent matches the committed transport behavior", async () => {
    const generated = await generateConsentFixture();
    const file = path.join(fixturesDir, "consent.json");
    if (update) {
      writeGenerated(file, generated);
      return;
    }
    expect(existsSync(file), "missing fixture; run HARMONY_UPDATE_FIXTURES=1 vitest").toBe(true);
    expect(generated).toEqual(JSON.parse(readFileSync(file, "utf8")));
  });

  it("no refused or stale scenario ever dispatches the private body", async () => {
    const { scenarios: committed } = JSON.parse(
      readFileSync(path.join(fixturesDir, "consent.json"), "utf8"),
    ) as { scenarios: ConsentScenario[] };
    for (const scenario of committed) {
      const gated = `/rpc/${scenario.proc}`;
      const blocked =
        scenario.expected.error !== undefined || scenario.expected.errors !== undefined;
      const dispatched = scenario.expected.transport.filter((call) => call.path === gated);
      if (blocked && !scenario.concurrent) {
        expect(dispatched, scenario.name).toHaveLength(0);
      }
      for (const call of scenario.expected.transport) {
        if (call.path !== gated) {
          expect(JSON.stringify(call.body), scenario.name).not.toContain("private content");
        }
      }
      if (scenario.sessionEvent === "server-during-prompt") {
        for (const call of scenario.expected.transport) {
          expect(call.base, scenario.name).toBe(BASE);
        }
      }
    }
  });
});
