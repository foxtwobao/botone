import { z } from "zod";

const httpsLink = z.url().refine((value) => {
  const url = new URL(value);
  return url.protocol === "https:" && !url.username && !url.password && !url.hash;
});

/** Operator configuration for one Feishu app; the same app the messaging surface may use. */
export const feishuConnectionSchema = z.strictObject({
  appId: z.string().min(1).max(100),
  appSecret: z.string().min(1).max(200),
  domain: z.enum(["feishu", "lark"]).default("feishu"),
  /** app acts as itself (tenant token); user acts as each authorizing person (OAuth). */
  identity: z.enum(["app", "user"]).default("app"),
  /** Which office modules' tools are exposed; keeps the bot tool list progressive. */
  modules: z.array(z.enum(["doc", "task", "calendar", "sheet"])).default(["doc", "task"]),
  name: z.string().min(1).max(100),
  icon: httpsLink.optional(),
  spaceIds: z.array(z.string().min(1)).min(1).optional(),
});
export type FeishuConnectionConfig = z.infer<typeof feishuConnectionSchema>;

export const feishuCreateDocSchema = z.strictObject({
  title: z.string().min(1).max(200),
  folderToken: z.string().min(1).max(200).optional(),
});
export const feishuReadDocSchema = z.strictObject({
  documentId: z.string().min(1).max(200),
});
export const feishuCreateTaskSchema = z.strictObject({
  summary: z.string().min(1).max(500),
  description: z.string().max(4_000).optional(),
  dueTimestamp: z.number().int().nonnegative().optional(),
});
export const feishuListTasksSchema = z.strictObject({
  pageSize: z.number().int().min(1).max(100).optional(),
  pageToken: z.string().min(1).max(500).optional(),
});

export interface FeishuDoc {
  documentId: string;
  title: string;
}
export interface FeishuTask {
  taskId: string;
  summary: string;
}
export interface FeishuTaskPage {
  tasks: FeishuTask[];
  nextPageToken?: string;
}

export const feishuListEventsSchema = z.strictObject({
  startTime: z.number().int(),
  endTime: z.number().int(),
  calendarId: z.string().min(1).max(200).optional(),
});
export const feishuCreateEventSchema = z.strictObject({
  summary: z.string().min(1).max(500),
  startTime: z.number().int(),
  endTime: z.number().int(),
  calendarId: z.string().min(1).max(200).optional(),
});
export const feishuCreateSheetSchema = z.strictObject({ title: z.string().min(1).max(200) });
export const feishuReadSheetSchema = z.strictObject({
  spreadsheetToken: z.string().min(1).max(200),
  range: z.string().min(1).max(200),
});
export const feishuAppendRowsSchema = z.strictObject({
  spreadsheetToken: z.string().min(1).max(200),
  range: z.string().min(1).max(200),
  values: z
    .array(z.array(z.union([z.string(), z.number(), z.boolean(), z.null()])))
    .min(1)
    .max(100),
});

export interface FeishuEvent {
  eventId: string;
  summary: string;
}
export interface FeishuSheet {
  spreadsheetToken: string;
  title: string;
}
export interface FeishuSheetValues {
  range: string;
  values: unknown[][];
}
export interface FeishuAppendResult {
  range: string;
  updatedRows: number;
}

/** The office actions one connected Feishu app offers; the provider owns the vendor translation. */
export interface FeishuOfficeProvider {
  /** Confirm the app credentials are accepted, without needing any business permission. */
  verify(signal: AbortSignal): Promise<void>;
  createDoc(input: z.infer<typeof feishuCreateDocSchema>, signal: AbortSignal): Promise<FeishuDoc>;
  readDoc(documentId: string, signal: AbortSignal): Promise<string>;
  createTask(
    input: z.infer<typeof feishuCreateTaskSchema>,
    signal: AbortSignal,
  ): Promise<FeishuTask>;
  listTasks(
    input: z.infer<typeof feishuListTasksSchema>,
    signal: AbortSignal,
  ): Promise<FeishuTaskPage>;
  listEvents(
    input: z.infer<typeof feishuListEventsSchema>,
    signal: AbortSignal,
  ): Promise<FeishuEvent[]>;
  createEvent(
    input: z.infer<typeof feishuCreateEventSchema>,
    signal: AbortSignal,
  ): Promise<FeishuEvent>;
  createSheet(
    input: z.infer<typeof feishuCreateSheetSchema>,
    signal: AbortSignal,
  ): Promise<FeishuSheet>;
  readSheet(
    input: z.infer<typeof feishuReadSheetSchema>,
    signal: AbortSignal,
  ): Promise<FeishuSheetValues>;
  appendRows(
    input: z.infer<typeof feishuAppendRowsSchema>,
    signal: AbortSignal,
  ): Promise<FeishuAppendResult>;
}
