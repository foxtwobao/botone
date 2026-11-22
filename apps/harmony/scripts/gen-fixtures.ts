// Layer 2 fixture generators (design §4.3.3, M1 scope): drive the REAL TypeScript reference
// implementations and record their observable behavior as committed JSON. The vitest test
// regenerates and diffs; the ArkTS ports replay the same files under hypium. Upstream changes
// a ported behavior without changing any schema, and this goes red.

import path from "node:path";
import { fileURLToPath } from "node:url";
import { i18n } from "@lingui/core";
import { isPrivateNetworkHost } from "@rakazo/contracts";
import {
  chatSnoozed,
  formatTimeSeparator,
  groupBotsForSidebar,
  IDLE_TIMEOUT_MS,
  isRetryableError,
  isRunWorking,
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
import { activateUiLocale } from "@rakazo/mobile/lib/i18n/i18n.js";
import { formatThreadTime } from "@rakazo/mobile/lib/inbox/inbox.js";
import { vi } from "vitest";
import { generateThreadFixture } from "./gen-thread-fixtures.ts";
import { readCatalog as readPoCatalog } from "./po.ts";

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

/** Every placeholder name a message reads, including names nested inside plural/select branches
 * (e.g. the {peer} in "{count, plural, one {# message with {peer}} …}"). */
function placeholders(msgid: string): string[] {
  const names = [...msgid.matchAll(/\{([a-zA-Z0-9_]+)\s*[,}]/g)].map((match) => match[1]!);
  return [...new Set(names)];
}

/** The argument names a message pluralizes on ({name, plural, …}). */
function pluralArgs(msgid: string): string[] {
  const names = [...msgid.matchAll(/\{([a-zA-Z0-9_]+),\s*plural,/g)].map((match) => match[1]!);
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

/** A sample value for a placeholder: plural args and UPPER_SNAKE constants read as numbers,
 * everything else as a short string. The point is to exercise every branch, not realism. */
function sampleValue(name: string, isPluralArg: boolean): string | number {
  if (name in SAMPLE_VALUES) return SAMPLE_VALUES[name]!;
  if (isPluralArg || /^[A-Z][A-Z0-9_]*$/.test(name) || /^\d+$/.test(name)) return 3;
  return "value";
}

/** Synthetic edge cases the real catalogs do not contain but the parser claims to support:
 * offset, exact =N matches, select, selectordinal, ordinary apostrophes, missing values, and
 * large-count # grouping. Quoted-section literals ('{name}') are out of scope: no shipped catalog
 * message uses them (see the shortcut note in icu.ets). Expected values come from @lingui/core, so the ArkTS port must match. */
const ICU_EDGES: { msgid: string; values: Record<string, string | number> }[] = [
  { msgid: "{count, plural, offset:1 one {# item} other {# items}}", values: { count: 2 } },
  { msgid: "{count, plural, offset:1 one {# item} other {# items}}", values: { count: 1 } },
  { msgid: "{count, plural, =0 {none} one {# item} other {# items}}", values: { count: 0 } },
  { msgid: "{count, plural, =0 {none} one {# item} other {# items}}", values: { count: 1 } },
  { msgid: "{count, plural, =1 {exactly one} one {# item} other {# items}}", values: { count: 1 } },
  { msgid: "{gender, select, male {He} female {She} other {They}}", values: { gender: "male" } },
  { msgid: "{gender, select, male {He} female {She} other {They}}", values: { gender: "female" } },
  { msgid: "{gender, select, male {He} female {She} other {They}}", values: { gender: "x" } },
  { msgid: "{gender, select, male {He} female {She} other {They}}", values: {} },
  {
    msgid: "{count, selectordinal, one {#st} two {#nd} few {#rd} other {#th}}",
    values: { count: 1 },
  },
  {
    msgid: "{count, selectordinal, one {#st} two {#nd} few {#rd} other {#th}}",
    values: { count: 2 },
  },
  {
    msgid: "{count, selectordinal, one {#st} two {#nd} few {#rd} other {#th}}",
    values: { count: 3 },
  },
  {
    msgid: "{count, selectordinal, one {#st} two {#nd} few {#rd} other {#th}}",
    values: { count: 4 },
  },
  {
    msgid: "{count, selectordinal, one {#st} two {#nd} few {#rd} other {#th}}",
    values: { count: 11 },
  },
  {
    msgid: "{count, selectordinal, one {#st} two {#nd} few {#rd} other {#th}}",
    values: { count: 21 },
  },
  {
    msgid: "{count, selectordinal, offset:1 one {#st} two {#nd} few {#rd} other {#th}}",
    values: { count: 2 },
  },
  { msgid: "{count, plural, one {# {name}} other {# {name}s}}", values: { count: 1, name: "bot" } },
  { msgid: "{count, plural, one {# {name}} other {# {name}s}}", values: { count: 3, name: "bot" } },
  {
    msgid: "{name} and {count, plural, one {# bot} other {# bots}}",
    values: { name: "Ada", count: 2 },
  },
  { msgid: "It's a {name}", values: { name: "test" } },
  { msgid: "{a} {b} {c}", values: { a: 1, b: 2 } },
  { msgid: "{name}", values: {} },
  { msgid: "{count, plural, one {# item} other {# items}}", values: { count: 1000000 } },
  { msgid: "{count, plural, one {# item} other {# items}}", values: { count: 1234567 } },
  { msgid: "{count, plural, one {# item} other {# items}}", values: { count: -1 } },
  { msgid: "{count, plural, one {# item} other {# items}}", values: {} },
  { msgid: "{n, plural, one {#} other {#}}", values: { n: 1.5 } },
];

export function generateIcuFixture(): IcuFixture {
  const cases: IcuCase[] = [];
  for (const locale of ["en", "zh-CN", "zh-TW"]) {
    const catalog = readCatalog(locale);
    i18n.load(locale, catalog);
    i18n.activate(locale);
    const msgids = Object.keys(catalog);
    // Every plural message, at the counts that pick different categories.
    for (const msgid of msgids.filter((id) => id.includes(", plural,"))) {
      const name = pluralArgs(msgid)[0] ?? "count";
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
    // FULL catalog validation (M4): every message that contains a placeholder, evaluated with a
    // sample value for each name it reads. This covers all 459 brace messages per locale — the
    // interpolation set, the apostrophes, and the nested plural branches — not just a fixed list.
    for (const msgid of msgids.filter((id) => id.includes("{"))) {
      const args = new Set(pluralArgs(msgid));
      const values: Record<string, string | number> = {};
      for (const name of placeholders(msgid)) values[name] = sampleValue(name, args.has(name));
      cases.push({
        locale,
        msgid,
        message: catalog[msgid]!,
        values,
        expected: i18n._(msgid, values),
      });
    }
    // Synthetic parser edges (offset / =N / select / selectordinal / quoting / missing / grouping).
    for (const edge of ICU_EDGES) {
      cases.push({
        locale,
        msgid: edge.msgid,
        message: edge.msgid,
        values: edge.values,
        expected: i18n._(edge.msgid, edge.values),
      });
    }
  }
  return { cases };
}

// ---------------------------------------------------------------- dates

interface DateCase {
  kind: "row" | "separator";
  locale: string;
  iso: string;
  now: string;
  /** Separator cases only: the localized labels the reference consumed. */
  today?: string;
  yesterday?: string;
  expected: string;
}
interface DatesFixture {
  cases: DateCase[];
}

/** Localized dates (M4): drive the REAL references under each shipped UI locale — mobile's
 * formatThreadTime for inbox rows, core's formatTimeSeparator for thread day separators. Today
 * reads a clock, the past week a weekday name, older a short date — all in the active locale,
 * which is what the ArkTS port (i18n/dates.ets) must reproduce. */
export function generateDatesFixture(): DatesFixture {
  const cases: DateCase[] = [];
  // A fixed local-time "now" so day boundaries are deterministic on any host timezone.
  const now = new Date(2026, 7, 13, 21, 53, 0);
  const local = (dayOffset: number, hour: number, minute: number): string =>
    new Date(2026, 7, 13 - dayOffset, hour, minute, 0).toISOString();
  const samples: { iso: string }[] = [
    { iso: local(0, 14, 44) }, // today → clock
    { iso: local(0, 0, 5) }, // today, padded hour/minute
    { iso: local(1, 10, 0) }, // yesterday → weekday
    { iso: local(2, 10, 0) }, // within the week → weekday
    { iso: local(6, 23, 59) }, // last day of the weekday window
    { iso: local(7, 9, 0) }, // a week ago → short date
    { iso: local(20, 9, 0) }, // older → short date
    { iso: local(400, 9, 0) }, // previous year
    { iso: "not-a-date" }, // invalid → empty
  ];
  const separatorSamples: { iso: string }[] = [
    { iso: local(0, 14, 44) }, // today → label + clock
    { iso: local(1, 10, 0) }, // yesterday → label + clock
    { iso: local(3, 9, 30) }, // within the week → weekday + clock
    { iso: local(10, 8, 15) }, // older, same year → short date + clock
    { iso: local(400, 7, 5) }, // previous year → date gains the year
    { iso: "not-a-date" }, // invalid → empty
  ];
  for (const locale of ["en", "zh-CN", "zh-TW"] as const) {
    activateUiLocale(locale);
    const dateLocale = locale === "en" ? "en-US" : locale;
    const catalog = readCatalog(locale);
    const labels = {
      today: catalog["Today"] ?? "Today",
      yesterday: catalog["Yesterday"] ?? "Yesterday",
    };
    for (const sample of samples) {
      cases.push({
        kind: "row",
        locale,
        iso: sample.iso,
        now: now.toISOString(),
        expected: formatThreadTime(sample.iso, now),
      });
    }
    for (const sample of separatorSamples) {
      cases.push({
        kind: "separator",
        locale,
        iso: sample.iso,
        now: now.toISOString(),
        // The localized Today/Yesterday labels ride with the case: the device replay has no
        // loaded catalog, and the labels are inputs the app passes from its own t().
        today: labels.today,
        yesterday: labels.yesterday,
        expected: formatTimeSeparator(sample.iso, dateLocale, labels, now),
      });
    }
  }
  return { cases };
}

// ---------------------------------------------------------------- inbox

interface InboxBot {
  id: string;
  name: string;
  color: string;
  pinned: boolean;
  sectionId: string | null;
  unread: boolean;
  preview: string;
  status: string;
  updatedAt: string;
  snoozedUntil: string | null;
}
interface InboxGroup {
  id: string;
  name: string;
  pinned: boolean;
  sectionId: string | null;
  unread: boolean;
  preview: string;
  updatedAt: string;
  snoozedUntil: string | null;
}
interface InboxCase {
  name: string;
  now: number;
  bots: InboxBot[];
  groups: InboxGroup[];
  expected: { kind: string; id: string; working: boolean }[];
}
interface InboxFixture {
  working: { status: string; expected: boolean }[];
  snoozed: { snoozedUntil: string | null; now: number; expected: boolean }[];
  cases: InboxCase[];
}

/** The expected row order/working from the REAL core helpers the ArkTS projection ports. */
function expectedRows(bots: InboxBot[], groups: InboxGroup[], now: number) {
  const chats = [
    ...bots.map((bot) => ({
      type: "bot" as const,
      bot,
      id: bot.id,
      pinned: bot.pinned,
      sectionId: bot.sectionId,
    })),
    ...groups.map((group) => ({
      type: "group" as const,
      group,
      id: group.id,
      pinned: group.pinned,
      sectionId: group.sectionId,
    })),
  ];
  const awake = chats.filter(
    (chat) => !chatSnoozed(chat.type === "bot" ? chat.bot : chat.group, now),
  );
  // No sections in Phase 1: groupBotsForSidebar yields the pinned bucket then the unassigned one.
  const grouped = groupBotsForSidebar(awake, [], {});
  return grouped.flatMap((section) =>
    section.bots.map((item) => ({
      kind: item.type,
      id: item.type === "bot" ? item.bot.id : item.group.id,
      working: item.type === "bot" ? isRunWorking(item.bot.status) : false,
    })),
  );
}

export function generateInboxFixture(): InboxFixture {
  const now = Date.parse("2026-11-21T12:00:00.000Z");
  const bot = (id: string, over: Partial<InboxBot> = {}): InboxBot => ({
    id,
    name: id,
    color: "#3EC5A8",
    pinned: false,
    sectionId: null,
    unread: false,
    preview: "",
    status: "idle",
    updatedAt: "2026-11-21T10:00:00.000Z",
    snoozedUntil: null,
    ...over,
  });
  const group = (id: string, over: Partial<InboxGroup> = {}): InboxGroup => ({
    id,
    name: id,
    pinned: false,
    sectionId: null,
    unread: false,
    preview: "",
    updatedAt: "2026-11-21T10:00:00.000Z",
    snoozedUntil: null,
    ...over,
  });

  const scripted: { name: string; bots: InboxBot[]; groups: InboxGroup[] }[] = [
    { name: "empty roster", bots: [], groups: [] },
    {
      name: "bots then groups in server order",
      bots: [bot("b1"), bot("b2")],
      groups: [group("g1"), group("g2")],
    },
    {
      name: "pinned first, bots before groups within each bucket",
      bots: [bot("b1"), bot("b2", { pinned: true }), bot("b3", { pinned: true })],
      groups: [group("g1", { pinned: true }), group("g2")],
    },
    {
      name: "working statuses show, waiting and terminal do not",
      bots: [
        bot("queued", { status: "queued" }),
        bot("leased", { status: "leased" }),
        bot("running", { status: "running" }),
        bot("waiting", { status: "waiting_input" }),
        bot("takeover", { status: "waiting_takeover" }),
        bot("done", { status: "completed" }),
        bot("failed", { status: "failed" }),
        bot("idle", { status: "idle" }),
      ],
      groups: [group("g1")],
    },
    {
      name: "snoozed chats hide until they wake",
      bots: [
        bot("awake"),
        bot("snoozed", { snoozedUntil: "2026-11-21T13:00:00.000Z" }),
        bot("woke", { snoozedUntil: "2026-11-21T11:00:00.000Z" }),
        bot("bad-snooze", { snoozedUntil: "not-a-date" }),
      ],
      groups: [group("g-snoozed", { snoozedUntil: "2026-11-21T13:00:00.000Z" }), group("g-awake")],
    },
    {
      name: "pinned and snoozed together",
      bots: [
        bot("p1", { pinned: true, status: "running" }),
        bot("p2", { pinned: true, snoozedUntil: "2026-11-21T13:00:00.000Z" }),
        bot("u1", { status: "queued" }),
      ],
      groups: [group("pg", { pinned: true }), group("ug", { unread: true })],
    },
  ];

  const cases: InboxCase[] = scripted.map((c) => ({
    name: c.name,
    now,
    bots: c.bots,
    groups: c.groups,
    expected: expectedRows(c.bots, c.groups, now),
  }));

  const working = [
    "idle",
    "queued",
    "leased",
    "running",
    "waiting_input",
    "waiting_takeover",
    "completed",
    "failed",
    "cancelled",
    "something-new",
  ].map((status) => ({ status, expected: isRunWorking(status) }));

  const snoozed = [
    null,
    "",
    "2026-11-21T13:00:00.000Z",
    "2026-11-21T11:00:00.000Z",
    "2026-11-21T12:00:00.000Z",
    "not-a-date",
  ].map((snoozedUntil) => ({ snoozedUntil, now, expected: chatSnoozed({ snoozedUntil }, now) }));

  return { working, snoozed, cases };
}

export const fixtureGenerators: Record<string, () => unknown | Promise<unknown>> = {
  retry: generateRetryFixture,
  endpoint: generateEndpointFixture,
  sse: generateSseFixture,
  icu: generateIcuFixture,
  inbox: generateInboxFixture,
  dates: generateDatesFixture,
  thread: generateThreadFixture,
};
