// Layer 2 fixture generators (design §4.3.3, M1 scope): drive the REAL TypeScript reference
// implementations and record their observable behavior as committed JSON. The vitest test
// regenerates and diffs; the ArkTS ports replay the same files under hypium. Upstream changes
// a ported behavior without changing any schema, and this goes red.

import path from "node:path";
import { fileURLToPath } from "node:url";
import { i18n } from "@lingui/core";
import { isPrivateNetworkHost } from "@rakazo/contracts";
import {
  IDLE_TIMEOUT_MS,
  isRetryableError,
  jitterMs,
  MAX_RETRY_AFTER_MS,
  parseRetryAfter,
  RECONNECT_SPREAD_MS,
  reconnectDelayMs,
  retryDelayMs,
} from "@rakazo/core";
import { MAX_MOBILE_RPC_RESPONSE_BYTES } from "@rakazo/mobile/lib/api/api.js";
import { subscribeThread } from "@rakazo/mobile/lib/api/api-live.js";
import { normalizeApiBase, probeApiBase } from "@rakazo/mobile/lib/api/endpoint.js";
import { vi } from "vitest";
import { readCatalog as readPoCatalog } from "../scripts/po.ts";

const localesDir = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../../packages/i18n/locales",
);

function readCatalog(locale: string): Record<string, string> {
  return readPoCatalog(localesDir, locale);
}

// ---------------------------------------------------------------- retry

interface RetryErrorSpec {
  status?: number;
  retryAfterMs?: number | null;
}
/** Omitted = no error (undefined); {text} = a string error; otherwise an error object. */
type DelayError = RetryErrorSpec | { text: string } | undefined;
interface RetryFixture {
  constants: { maxRetryAfterMs: number; reconnectSpreadMs: number };
  isRetryable: { error: RetryErrorSpec | string | null | undefined; expected: boolean }[];
  parseRetryAfter: { value: string | null; now: number; expected: number | null }[];
  jitter: { ms: number; random: number; expected: number }[];
  retryDelay: { error?: DelayError; backoffMs: number; random: number; expected: number }[];
  reconnectDelay: { error?: DelayError; random: number; expected: number }[];
}

function materializeError(spec: RetryErrorSpec | string | null | undefined): unknown {
  if (spec === undefined) return undefined;
  if (spec === null || typeof spec === "string") return spec;
  const error: Record<string, unknown> = {};
  if (spec.status !== undefined) error.status = spec.status;
  if (spec.retryAfterMs !== undefined) error.retryAfterMs = spec.retryAfterMs;
  return error;
}

function materializeDelayError(spec: DelayError): unknown {
  if (spec === undefined) return undefined;
  if ("text" in spec) return spec.text;
  return materializeError(spec);
}

export function generateRetryFixture(): RetryFixture {
  const now = 1_750_000_000_000;
  const errors: (RetryErrorSpec | string | null | undefined)[] = [
    undefined,
    null,
    "transport failure",
    {},
    { status: 302 },
    { status: 400 },
    { status: 401 },
    { status: 404 },
    { status: 408 },
    { status: 426 },
    { status: 429 },
    { status: 500 },
    { status: 503 },
    { retryAfterMs: 5_000 },
    { status: 503, retryAfterMs: 120_000 },
    { retryAfterMs: 0 },
    { retryAfterMs: -5 },
    { retryAfterMs: null },
    { retryAfterMs: 999_999_999 },
  ];
  const randoms = [0, 0.25, 0.5, 0.999];
  // null behaves like {} in every delay function, so the delay lists use {} for that path.
  const delayErrors: DelayError[] = [
    undefined,
    { text: "transport failure" },
    ...errors.filter((e): e is RetryErrorSpec => typeof e === "object" && e !== null),
  ];
  const fixture: RetryFixture = {
    constants: { maxRetryAfterMs: MAX_RETRY_AFTER_MS, reconnectSpreadMs: RECONNECT_SPREAD_MS },
    isRetryable: errors.map((error) => ({
      error,
      expected: isRetryableError(materializeError(error)),
    })),
    parseRetryAfter: [
      null,
      "",
      "   ",
      "120",
      "0",
      "-5",
      "999999",
      "not a date",
      new Date(now + 60_000).toUTCString(),
      new Date(now - 60_000).toUTCString(),
    ].map((value) => ({
      value,
      now,
      expected: parseRetryAfter(value, now) ?? null,
    })),
    jitter: [0, 1, 1000, 30_000].flatMap((ms) =>
      randoms.map((random) => ({ ms, random, expected: jitterMs(ms, () => random) })),
    ),
    retryDelay: delayErrors.flatMap((error) =>
      randoms.map((random) => {
        const entry: RetryFixture["retryDelay"][number] = {
          backoffMs: 1000,
          random,
          expected: retryDelayMs(materializeDelayError(error), 1000, () => random),
        };
        if (error !== undefined) entry.error = error;
        return entry;
      }),
    ),
    reconnectDelay: delayErrors.flatMap((error) =>
      randoms.map((random) => {
        const entry: RetryFixture["reconnectDelay"][number] = {
          random,
          expected: reconnectDelayMs(materializeDelayError(error), () => random),
        };
        if (error !== undefined) entry.error = error;
        return entry;
      }),
    ),
  };
  return fixture;
}

// ---------------------------------------------------------------- endpoint

interface EndpointFixture {
  normalize: { input: string; ok: boolean; url?: string; error?: string }[];
  privateHost: { host: string; expected: boolean }[];
  probe: {
    input: string;
    response: { status: number; body: string } | "unreachable";
    ok: boolean;
    url?: string;
    error?: string;
  }[];
}

export async function generateEndpointFixture(): Promise<EndpointFixture> {
  // Render t`...` errors as their source msgid: the ArkTS port returns the msgid and the UI
  // translates it, so the fixture pins the key, not one locale's wording.
  i18n.load("en", {});
  i18n.activate("en");
  const inputs = [
    "",
    "   ",
    "example.com",
    "https://example.com",
    "https://example.com/path?query=1#frag",
    "HTTPS://Example.COM:8443/x",
    "http://example.com",
    "http://10.0.2.2:3100",
    "http://192.168.1.5:3100",
    "http://172.16.0.1:3100",
    "http://100.64.0.1:3100",
    "http://127.0.0.1:3100",
    "http://localhost:3100",
    "http://localhost.:3100",
    "http://my-server.local:3100",
    "http://[::1]:3100",
    "http://[fd00::1]:3100",
    "http://[fe80::1]:3100",
    "http://169.254.169.254",
    "http://100.100.100.200",
    "http://metadata.google.internal",
    "http://010.0.0.1",
    "http://256.0.0.1",
    "ftp://example.com",
    "not a url at all",
    "http://",
    "https://user:pass@example.com",
    "http://[2001:db8::1]:3100",
    "http://[::ffff:10.0.0.1]:3100",
  ];
  const normalize = inputs.map((input) => {
    const result = normalizeApiBase(input);
    return result.ok
      ? { input, ok: true, url: result.url }
      : { input, ok: false, error: result.error };
  });
  const hosts = [
    "localhost",
    "LOCALHOST",
    "localhost.",
    "sub.localhost",
    "printer.local",
    "example.com",
    "127.0.0.1",
    "127.5.5.5",
    "10.1.2.3",
    "172.16.0.1",
    "172.32.0.1",
    "192.168.0.1",
    "100.64.0.1",
    "100.128.0.1",
    "169.254.169.254",
    "100.100.100.200",
    "8.8.8.8",
    "010.0.0.1",
    "::1",
    "[::1]",
    "fd00::1",
    "fc00::1",
    "fe80::1",
    "2001:db8::1",
    "::ffff:10.0.0.1",
    "::ffff:127.0.0.1",
    "64:ff9b::10.0.0.1",
    "2002:0a00:0001::",
    "metadata.google.internal",
    "fd00:ec2::254",
    "fe80::1%en0",
  ];
  const privateHost = hosts.map((host) => ({ host, expected: isPrivateNetworkHost(host) }));

  const probeCases: EndpointFixture["probe"] = [];
  const probes: {
    input: string;
    response: { status: number; body: string } | "unreachable";
  }[] = [
    {
      input: "https://good.example",
      response: { status: 200, body: '{"json":{"ok":true,"version":"1.0.0"}}' },
    },
    { input: "https://bad.example", response: { status: 200, body: '{"json":{"ok":false}}' } },
    {
      input: "https://error.example",
      response: { status: 200, body: '{"error":{"message":"nope"}}' },
    },
    { input: "https://html.example", response: { status: 200, body: "<html>proxy</html>" } },
    { input: "https://404.example", response: { status: 404, body: '{"json":{}}' } },
    { input: "https://down.example", response: "unreachable" },
    { input: "http://public.example", response: { status: 200, body: '{"json":{"ok":true}}' } },
  ];
  for (const probe of probes) {
    const fetchImpl =
      probe.response === "unreachable"
        ? async () => {
            throw new TypeError("fetch failed");
          }
        : async () =>
            new Response(probe.response.body, {
              status: probe.response.status,
              headers: { "content-type": "application/json" },
            });
    const result = await probeApiBase(probe.input, fetchImpl as typeof fetch);
    probeCases.push({
      input: probe.input,
      response: probe.response,
      ok: result.ok,
      ...(result.ok ? { url: result.url } : { error: result.error }),
    });
  }
  return { normalize, privateHost, probe: probeCases };
}

// ---------------------------------------------------------------- SSE

type ChunkSpec = { b64: string } | { fill: string; count: number };
interface SseCase {
  name: string;
  chunks: ChunkSpec[];
  events: Record<string, unknown>[];
  error?: "range";
  idle?: boolean;
}
interface SseFixture {
  maxFrameBytes: number;
  idleTimeoutMs: number;
  cases: SseCase[];
}

const encoder = new TextEncoder();
function b64(bytes: Uint8Array): ChunkSpec {
  return { b64: Buffer.from(bytes).toString("base64") };
}
function text(chunk: string): ChunkSpec {
  return b64(encoder.encode(chunk));
}
function frame(event: Record<string, unknown>): string {
  return `data: ${JSON.stringify({ json: event })}\n\n`;
}
function expand(spec: ChunkSpec): Uint8Array {
  if ("fill" in spec) return new Uint8Array(spec.count).fill(spec.fill.charCodeAt(0));
  return new Uint8Array(Buffer.from(spec.b64, "base64"));
}

export async function generateSseFixture(): Promise<SseFixture> {
  const max = MAX_MOBILE_RPC_RESPONSE_BYTES;
  const a = { type: "thread.progress", seq: 1, payload: { delta: "Hi" } };
  const b = { type: "thread.message.created", seq: 2, payload: {} };
  const splitText = frame({ type: "split", seq: 2, text: "鸿蒙" });
  const splitBytes = encoder.encode(splitText);
  const cut = splitBytes.indexOf(0xe9) + 1;

  const scripted: { name: string; chunks: ChunkSpec[]; error?: "range" }[] = [
    { name: "single frame in one chunk", chunks: [text(frame(a))] },
    { name: "two frames in one chunk", chunks: [text(frame(a) + frame(b))] },
    {
      name: "crlf blank lines are not frame boundaries",
      chunks: [
        text(
          `data: ${JSON.stringify({ json: a })}\r\n\r\ndata: ${JSON.stringify({ json: b })}\n\n`,
        ),
      ],
    },
    {
      name: "delimiter split across chunks",
      chunks: [text(`data: ${JSON.stringify({ json: a })}\n`), text(`\n${frame(b)}`)],
    },
    {
      name: "multiple data lines rejoin without separator",
      chunks: [
        text(
          'data: {"json":{"type":"thread.progress",\ndata: "seq":1,"payload":{"delta":"Hi"}}}\n\n',
        ),
      ],
    },
    {
      name: "heartbeat proves liveness only",
      chunks: [text(frame({ type: "heartbeat" })), text(frame(a))],
    },
    { name: "done marker is skipped", chunks: [text("data: [DONE]\n\n"), text(frame(a))] },
    {
      name: "bad json is skipped without breaking the stream",
      chunks: [text("data: not-json\n\n"), text(frame(a))],
    },
    { name: "event without a type is skipped", chunks: [text(frame({ seq: 1 }))] },
    { name: "empty data line is skipped", chunks: [text("data: \n\n"), text(frame(a))] },
    {
      name: "frame at the byte budget is allowed",
      chunks: [{ fill: "x", count: max - 2 }, text("\n\n")],
    },
    {
      name: "frame one byte over the budget throws",
      chunks: [{ fill: "x", count: max - 1 }, text("\n\n")],
      error: "range",
    },
    { name: "oversized frame throws", chunks: [{ fill: "x", count: max + 1 }], error: "range" },
    {
      name: "eof drops the incomplete tail frame",
      chunks: [text(frame(a)), text('data: {"json":{"type":"tail"')],
    },
    {
      name: "utf-8 character split across chunks",
      chunks: [b64(splitBytes.slice(0, cut)), b64(splitBytes.slice(cut))],
    },
  ];

  const cases: SseCase[] = [];
  for (const scriptedCase of scripted) {
    const chunks = scriptedCase.chunks.map(expand);
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        for (const chunk of chunks) controller.enqueue(chunk);
        controller.close();
      },
    });
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response(stream, { status: 200 })),
    );
    const events: Record<string, unknown>[] = [];
    let error: "range" | undefined;
    try {
      await subscribeThread(
        { botId: "bot-1" },
        0,
        (event) => events.push(event),
        new AbortController().signal,
      );
    } catch (caught) {
      if (caught instanceof RangeError) error = "range";
      else throw caught;
    }
    if (scriptedCase.error && error !== scriptedCase.error) {
      throw new Error(`case "${scriptedCase.name}": expected ${scriptedCase.error} error`);
    }
    cases.push({
      name: scriptedCase.name,
      chunks: scriptedCase.chunks,
      events: JSON.parse(JSON.stringify(events)) as Record<string, unknown>[],
      ...(error ? { error } : {}),
    });
  }

  // 45s without any chunk ends the subscription so the caller reconnects (controlled clock).
  vi.useFakeTimers();
  try {
    let controller: ReadableStreamDefaultController<Uint8Array> | undefined;
    const stream = new ReadableStream<Uint8Array>({
      start(c) {
        controller = c;
      },
    });
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response(stream, { status: 200 })),
    );
    const events: Record<string, unknown>[] = [];
    const running = subscribeThread(
      { botId: "bot-1" },
      0,
      (event) => events.push(event),
      new AbortController().signal,
    );
    controller?.enqueue(encoder.encode(frame(a)));
    await vi.advanceTimersByTimeAsync(0);
    await vi.advanceTimersByTimeAsync(IDLE_TIMEOUT_MS - 1);
    await vi.advanceTimersByTimeAsync(1);
    await running;
    cases.push({
      name: "idle timeout ends the stream for reconnect",
      chunks: [text(frame(a))],
      events: JSON.parse(JSON.stringify(events)) as Record<string, unknown>[],
      idle: true,
    });
  } finally {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  }
  return { maxFrameBytes: max, idleTimeoutMs: IDLE_TIMEOUT_MS, cases };
}

// ---------------------------------------------------------------- ICU

interface IcuCase {
  locale: string;
  msgid: string;
  /** The catalog translation, so the device replay needs no resource loading. */
  message: string;
  values: Record<string, string | number>;
  expected: string;
}
interface IcuFixture {
  cases: IcuCase[];
}

/** Placeholder names a message reads at the top level, e.g. {host} or {0, plural, …}. */
function placeholders(msgid: string): string[] {
  const names = [...msgid.matchAll(/\{([a-zA-Z0-9_]+)(?=[,}])/g)].map((match) => match[1]!);
  return [...new Set(names)];
}

const SAMPLE_VALUES: Record<string, string | number> = {
  name: "Ada",
  host: "chat.example.com",
  email: "ada@example.com",
  count: 3,
  max: 8,
  0: 3,
};

export function generateIcuFixture(): IcuFixture {
  const cases: IcuCase[] = [];
  for (const locale of ["en", "zh-CN"]) {
    const catalog = readCatalog(locale);
    i18n.load(locale, catalog);
    i18n.activate(locale);
    const msgids = Object.keys(catalog);
    // Every plural message, at the counts that pick different categories.
    for (const msgid of msgids.filter((id) => /\{[^}]*,\s*plural,/.test(id))) {
      const name = placeholders(msgid)[0] ?? "count";
      for (const count of [0, 1, 2, 5]) {
        cases.push({
          locale,
          msgid,
          message: catalog[msgid]!,
          values: { [name]: count },
          expected: i18n._(msgid, { [name]: count }),
        });
      }
    }
    // A fixed set of interpolation messages: the M1 screens' strings, apostrophes, several
    // placeholders, and a nested plural inside surrounding text.
    const interpolation = [
      "Custom server {host}",
      "Continue with {name}",
      "Account menu for {name}",
      "Password must be {max} characters or fewer",
      "Don’t have an account?",
      "Already have an account?",
      "Did you mean {email}?",
      "Connect MCP server {name}",
      "{count} spaces",
      "1 bot now uses the space default.",
      "Sign in to Rakazo",
      "Enter a server URL",
      "Public servers need https://. HTTP only works on your local network.",
      "Something went wrong. Try again.",
      "Could not reach the server",
      "Invalid code",
      "Request a new code",
      "Too many attempts. Try again in a few minutes.",
    ];
    for (const msgid of interpolation) {
      if (!(msgid in catalog)) continue;
      const values: Record<string, string | number> = {};
      for (const name of placeholders(msgid)) values[name] = SAMPLE_VALUES[name] ?? "value";
      cases.push({
        locale,
        msgid,
        message: catalog[msgid]!,
        values,
        expected: i18n._(msgid, values),
      });
    }
  }
  return { cases };
}

export const fixtureGenerators: Record<string, () => unknown | Promise<unknown>> = {
  retry: generateRetryFixture,
  endpoint: generateEndpointFixture,
  sse: generateSseFixture,
  icu: generateIcuFixture,
};
