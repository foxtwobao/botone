import type { Client } from "@larksuiteoapi/node-sdk";
import { deadlineSignal } from "@rakazo/core";
import { z } from "zod";
import { readBoundedText } from "../../../integrations/connector-http.js";
import type {
  FeishuAppendResult,
  FeishuConnectionConfig,
  FeishuDoc,
  FeishuEvent,
  FeishuOfficeProvider,
  FeishuSheet,
  FeishuSheetValues,
  FeishuTask,
  FeishuTaskPage,
} from "./feishu-contracts.js";
import { feishuConnectionSchema } from "./feishu-contracts.js";

const codes = z.enum([
  "forbidden",
  "not_found",
  "invalid_parameters",
  "authorization_required",
  "rate_limited",
]);
export class FeishuServiceError extends Error {
  constructor(
    readonly code: z.infer<typeof codes> | "unavailable" | "invalid_response",
    readonly status = 503,
    /** Feishu's own permission-application page, so the grant happens on Feishu, not in our UI. */
    readonly permissionUrl?: string,
  ) {
    super(`Feishu: ${code}`);
  }
}

/** Feishu business codes the caller can act on; anything else stays a sanitized unavailable. */
function classifyCode(
  code: unknown,
): "forbidden" | "rate_limited" | "authorization_required" | "unavailable" {
  if (code === 99991672) return "forbidden";
  if (code === 99991400) return "rate_limited";
  // Invalid/expired app or user access token: the person must re-authorize, not retry.
  if (code === 99991661 || code === 99991663 || code === 99991664 || code === 99991668)
    return "authorization_required";
  return "unavailable";
}

/** Feishu embeds its official permission-application deep link in the denial message; surface it. */
function permissionUrlFrom(msg: unknown): string | undefined {
  return /https:\/\/open\.(?:feishu\.cn|larksuite\.com)\/app\/\S+/.exec(String(msg ?? ""))?.[0];
}

const DOMAINS = {
  feishu: "https://open.feishu.cn",
  lark: "https://open.larksuite.com",
} as const;

const docSchema = z.object({ document_id: z.string(), title: z.string().default("") });
const taskSchema = z.object({
  guid: z.string().optional(),
  id: z.string().optional(),
  summary: z.string().default(""),
});
const taskPageSchema = z.object({
  items: z.array(taskSchema).default([]),
  page_token: z.string().optional(),
  has_more: z.boolean().default(false),
});

type FeishuCall = <T>(
  method: "GET" | "POST",
  url: string,
  signal: AbortSignal,
  schema: z.ZodType<T>,
  data?: Record<string, unknown>,
  params?: Record<string, unknown>,
) => Promise<T>;

async function createDocOp(
  call: FeishuCall,
  input: { title: string; folderToken?: string },
  signal: AbortSignal,
): Promise<FeishuDoc> {
  const data = await call(
    "POST",
    "/open-apis/docx/v1/documents",
    signal,
    z.object({ document: docSchema }),
    { title: input.title, ...(input.folderToken ? { folder_token: input.folderToken } : {}) },
  );
  return { documentId: data.document.document_id, title: data.document.title };
}
async function readDocOp(
  call: FeishuCall,
  documentId: string,
  signal: AbortSignal,
): Promise<string> {
  const data = await call(
    "GET",
    `/open-apis/docx/v1/documents/${encodeURIComponent(documentId)}/raw_content`,
    signal,
    z.object({ content: z.string().default("") }),
  );
  return data.content;
}
async function createTaskOp(
  call: FeishuCall,
  input: { summary: string; description?: string; dueTimestamp?: number },
  signal: AbortSignal,
): Promise<FeishuTask> {
  const data = await call(
    "POST",
    "/open-apis/task/v2/tasks",
    signal,
    z.object({ task: taskSchema }),
    {
      summary: input.summary,
      ...(input.description ? { description: input.description } : {}),
      ...(input.dueTimestamp !== undefined
        ? { due: { timestamp: String(input.dueTimestamp) } }
        : {}),
    },
  );
  const taskId = data.task.guid ?? data.task.id;
  if (!taskId) throw new FeishuServiceError("invalid_response");
  return { taskId, summary: data.task.summary };
}
async function listTasksOp(
  call: FeishuCall,
  input: { pageSize?: number; pageToken?: string },
  signal: AbortSignal,
  params?: Record<string, unknown>,
): Promise<FeishuTaskPage> {
  const data = await call("GET", "/open-apis/task/v2/tasks", signal, taskPageSchema, undefined, {
    ...(input.pageSize ? { page_size: input.pageSize } : {}),
    ...(input.pageToken ? { page_token: input.pageToken } : {}),
    ...params,
  });
  const tasks = data.items.flatMap((item) => {
    const taskId = item.guid ?? item.id;
    return taskId ? [{ taskId, summary: item.summary }] : [];
  });
  return { tasks, ...(data.has_more && data.page_token ? { nextPageToken: data.page_token } : {}) };
}

async function primaryCalendarId(call: FeishuCall, signal: AbortSignal): Promise<string> {
  const data = await call(
    "GET",
    "/open-apis/calendar/v4/calendars/primary",
    signal,
    z.object({
      calendar_id: z.string().optional(),
      calendar: z.object({ calendar_id: z.string() }).optional(),
    }),
  );
  const id = data.calendar_id ?? data.calendar?.calendar_id;
  if (!id) throw new FeishuServiceError("invalid_response");
  return id;
}
async function listEventsOp(
  call: FeishuCall,
  input: { startTime: number; endTime: number; calendarId?: string },
  signal: AbortSignal,
): Promise<FeishuEvent[]> {
  const calendarId = input.calendarId ?? (await primaryCalendarId(call, signal));
  const data = await call(
    "GET",
    `/open-apis/calendar/v4/calendars/${encodeURIComponent(calendarId)}/events`,
    signal,
    z.object({
      items: z
        .array(z.object({ event_id: z.string(), summary: z.string().default("") }))
        .default([]),
    }),
    undefined,
    { start_time: String(input.startTime), end_time: String(input.endTime) },
  );
  return data.items.map((event) => ({ eventId: event.event_id, summary: event.summary }));
}
async function createEventOp(
  call: FeishuCall,
  input: { summary: string; startTime: number; endTime: number; calendarId?: string },
  signal: AbortSignal,
): Promise<FeishuEvent> {
  const calendarId = input.calendarId ?? (await primaryCalendarId(call, signal));
  const data = await call(
    "POST",
    `/open-apis/calendar/v4/calendars/${encodeURIComponent(calendarId)}/events`,
    signal,
    z.object({ event: z.object({ event_id: z.string(), summary: z.string().default("") }) }),
    {
      summary: input.summary,
      start_time: { timestamp: String(input.startTime) },
      end_time: { timestamp: String(input.endTime) },
    },
  );
  return { eventId: data.event.event_id, summary: data.event.summary };
}
async function createSheetOp(
  call: FeishuCall,
  input: { title: string },
  signal: AbortSignal,
): Promise<FeishuSheet> {
  const data = await call(
    "POST",
    "/open-apis/sheets/v3/spreadsheets",
    signal,
    z.object({
      spreadsheet: z.object({ spreadsheet_token: z.string(), title: z.string().default("") }),
    }),
    { title: input.title },
  );
  return { spreadsheetToken: data.spreadsheet.spreadsheet_token, title: data.spreadsheet.title };
}
async function readSheetOp(
  call: FeishuCall,
  input: { spreadsheetToken: string; range: string },
  signal: AbortSignal,
): Promise<FeishuSheetValues> {
  const data = await call(
    "GET",
    `/open-apis/sheets/v2/spreadsheets/${encodeURIComponent(input.spreadsheetToken)}/values/${encodeURIComponent(input.range)}`,
    signal,
    z.object({
      valueRange: z.object({
        range: z.string().default(""),
        values: z.array(z.array(z.unknown())).default([]),
      }),
    }),
  );
  return { range: data.valueRange.range, values: data.valueRange.values };
}
/** Feishu append rejects a single-cell range; widen it to one row of the values' width. */
function expandAppendRange(range: string, width: number): string {
  const match = /^(.*!)?([A-Z]+)(\d+)$/.exec(range);
  const col = match?.[2];
  const row = match?.[3];
  if (!match || !col || !row || width <= 1) return range;
  const prefix = match[1] ?? "";
  let start = 0;
  for (const ch of col) start = start * 26 + (ch.charCodeAt(0) - 64);
  let end = start + width - 1;
  let endCol = "";
  while (end > 0) {
    endCol = String.fromCharCode(65 + ((end - 1) % 26)) + endCol;
    end = Math.floor((end - 1) / 26);
  }
  return `${prefix}${col}${row}:${endCol}${row}`;
}
async function appendRowsOp(
  call: FeishuCall,
  input: {
    spreadsheetToken: string;
    range: string;
    values: (string | number | boolean | null)[][];
  },
  signal: AbortSignal,
): Promise<FeishuAppendResult> {
  const range = expandAppendRange(input.range, input.values[0]?.length ?? 1);
  const data = await call(
    "POST",
    `/open-apis/sheets/v2/spreadsheets/${encodeURIComponent(input.spreadsheetToken)}/values_append`,
    signal,
    z.object({
      updates: z
        .object({ updatedRows: z.number().optional(), updatedRange: z.string().optional() })
        .optional(),
    }),
    { valueRange: { range, values: input.values } },
    { insertDataOption: "INSERT_ROWS" },
  );
  return {
    range: data.updates?.updatedRange ?? range,
    updatedRows: data.updates?.updatedRows ?? input.values.length,
  };
}

/** App identity (tenant access token); the official SDK owns token caching and refresh. */
export class LarkFeishuProvider implements FeishuOfficeProvider {
  readonly config: FeishuConnectionConfig;
  private loaded?: Promise<Client>;
  constructor(
    config: FeishuConnectionConfig,
    private readonly fetcher = globalThis.fetch,
  ) {
    this.config = feishuConnectionSchema.parse(config);
  }
  private client() {
    this.loaded ??= (async () => {
      const sdk = await import("@larksuiteoapi/node-sdk");
      return new sdk.Client({
        appId: this.config.appId,
        appSecret: this.config.appSecret,
        domain: this.config.domain === "lark" ? sdk.Domain.Lark : sdk.Domain.Feishu,
        loggerLevel: sdk.LoggerLevel.error,
      });
    })();
    return this.loaded;
  }
  private async call<T>(
    method: "GET" | "POST",
    url: string,
    signal: AbortSignal,
    schema: z.ZodType<T>,
    data?: Record<string, unknown>,
    params?: Record<string, unknown>,
  ): Promise<T> {
    if (signal.aborted) throw new FeishuServiceError("unavailable");
    const client = await this.client();
    let body: { code?: number; msg?: string; data?: unknown };
    try {
      body = await client.request({
        method,
        url,
        ...(data ? { data } : {}),
        ...(params ? { params } : {}),
      });
    } catch (error) {
      if (error instanceof FeishuServiceError) throw error;
      const upstream = (error as { response?: { data?: { code?: unknown; msg?: unknown } } })
        ?.response?.data;
      throw new FeishuServiceError(
        classifyCode(upstream?.code),
        503,
        permissionUrlFrom(upstream?.msg),
      );
    }
    if (body.code)
      throw new FeishuServiceError(classifyCode(body.code), 503, permissionUrlFrom(body.msg));
    const parsed = schema.safeParse(body.data);
    if (!parsed.success) throw new FeishuServiceError("invalid_response");
    return parsed.data;
  }
  async verify(signal: AbortSignal) {
    let response: Response;
    try {
      response = await this.fetcher(
        `${DOMAINS[this.config.domain]}/open-apis/auth/v3/tenant_access_token/internal`,
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ app_id: this.config.appId, app_secret: this.config.appSecret }),
          redirect: "manual",
          signal: deadlineSignal(20_000, signal),
        },
      );
    } catch (error) {
      if (error instanceof FeishuServiceError) throw error;
      throw new FeishuServiceError("unavailable");
    }
    if (!response.ok || response.type === "opaqueredirect") {
      await response.body?.cancel();
      throw new FeishuServiceError("authorization_required", 403);
    }
    const body = await readBoundedText(response, 4_096).catch(() => ({
      text: "",
      truncated: true,
    }));
    let code: unknown;
    try {
      code = JSON.parse(body.text)?.code;
    } catch {
      throw new FeishuServiceError("invalid_response");
    }
    if (code !== 0) throw new FeishuServiceError("authorization_required", 403);
  }
  createDoc(input: { title: string; folderToken?: string }, signal: AbortSignal) {
    return createDocOp(this.call.bind(this), input, signal);
  }
  readDoc(documentId: string, signal: AbortSignal) {
    return readDocOp(this.call.bind(this), documentId, signal);
  }
  createTask(
    input: { summary: string; description?: string; dueTimestamp?: number },
    signal: AbortSignal,
  ) {
    return createTaskOp(this.call.bind(this), input, signal);
  }
  listTasks(input: { pageSize?: number; pageToken?: string }, signal: AbortSignal) {
    return listTasksOp(this.call.bind(this), input, signal);
  }
  listEvents(
    input: { startTime: number; endTime: number; calendarId?: string },
    signal: AbortSignal,
  ) {
    return listEventsOp(this.call.bind(this), input, signal);
  }
  createEvent(
    input: { summary: string; startTime: number; endTime: number; calendarId?: string },
    signal: AbortSignal,
  ) {
    return createEventOp(this.call.bind(this), input, signal);
  }
  createSheet(input: { title: string }, signal: AbortSignal) {
    return createSheetOp(this.call.bind(this), input, signal);
  }
  readSheet(input: { spreadsheetToken: string; range: string }, signal: AbortSignal) {
    return readSheetOp(this.call.bind(this), input, signal);
  }
  appendRows(
    input: {
      spreadsheetToken: string;
      range: string;
      values: (string | number | boolean | null)[][];
    },
    signal: AbortSignal,
  ) {
    return appendRowsOp(this.call.bind(this), input, signal);
  }
}

/** User identity (user_access_token); every call acts as the authorizing person. */
export class UserLarkFeishuProvider implements FeishuOfficeProvider {
  readonly config: FeishuConnectionConfig;
  constructor(
    config: FeishuConnectionConfig,
    private readonly accessToken: string,
    private readonly fetcher = globalThis.fetch,
  ) {
    this.config = feishuConnectionSchema.parse(config);
  }
  private async call<T>(
    method: "GET" | "POST",
    url: string,
    signal: AbortSignal,
    schema: z.ZodType<T>,
    data?: Record<string, unknown>,
    params?: Record<string, unknown>,
  ): Promise<T> {
    if (signal.aborted) throw new FeishuServiceError("unavailable");
    const query = params
      ? `?${new URLSearchParams(Object.entries(params).map(([k, v]) => [k, String(v)]))}`
      : "";
    let response: Response;
    try {
      response = await this.fetcher(`${DOMAINS[this.config.domain]}${url}${query}`, {
        method,
        headers: {
          authorization: `Bearer ${this.accessToken}`,
          ...(data ? { "content-type": "application/json" } : {}),
        },
        ...(data ? { body: JSON.stringify(data) } : {}),
        redirect: "manual",
        signal: deadlineSignal(20_000, signal),
      });
    } catch (error) {
      if (error instanceof FeishuServiceError) throw error;
      throw new FeishuServiceError("unavailable");
    }
    const body = await readBoundedText(response, 1_000_000).catch(() => ({
      text: "",
      truncated: true,
    }));
    let envelope: { code?: number; msg?: unknown; data?: unknown };
    try {
      envelope = JSON.parse(body.text);
    } catch {
      throw new FeishuServiceError("invalid_response");
    }
    if (!response.ok || envelope.code)
      throw new FeishuServiceError(
        classifyCode(envelope.code),
        503,
        permissionUrlFrom(envelope.msg),
      );
    const parsed = schema.safeParse(envelope.data);
    if (!parsed.success) throw new FeishuServiceError("invalid_response");
    return parsed.data;
  }
  private openId(signal: AbortSignal) {
    return this.call(
      "GET",
      "/open-apis/authen/v1/user_info",
      signal,
      z.object({ open_id: z.string() }),
    );
  }
  async verify(signal: AbortSignal) {
    await this.openId(signal);
  }
  createDoc(input: { title: string; folderToken?: string }, signal: AbortSignal) {
    return createDocOp(this.call.bind(this), input, signal);
  }
  readDoc(documentId: string, signal: AbortSignal) {
    return readDocOp(this.call.bind(this), documentId, signal);
  }
  createTask(
    input: { summary: string; description?: string; dueTimestamp?: number },
    signal: AbortSignal,
  ) {
    return createTaskOp(this.call.bind(this), input, signal);
  }
  async listTasks(input: { pageSize?: number; pageToken?: string }, signal: AbortSignal) {
    const { open_id } = await this.openId(signal);
    return listTasksOp(this.call.bind(this), input, signal, {
      user_id: open_id,
      user_id_type: "open_id",
    });
  }
  listEvents(
    input: { startTime: number; endTime: number; calendarId?: string },
    signal: AbortSignal,
  ) {
    return listEventsOp(this.call.bind(this), input, signal);
  }
  createEvent(
    input: { summary: string; startTime: number; endTime: number; calendarId?: string },
    signal: AbortSignal,
  ) {
    return createEventOp(this.call.bind(this), input, signal);
  }
  createSheet(input: { title: string }, signal: AbortSignal) {
    return createSheetOp(this.call.bind(this), input, signal);
  }
  readSheet(input: { spreadsheetToken: string; range: string }, signal: AbortSignal) {
    return readSheetOp(this.call.bind(this), input, signal);
  }
  appendRows(
    input: {
      spreadsheetToken: string;
      range: string;
      values: (string | number | boolean | null)[][];
    },
    signal: AbortSignal,
  ) {
    return appendRowsOp(this.call.bind(this), input, signal);
  }
}
