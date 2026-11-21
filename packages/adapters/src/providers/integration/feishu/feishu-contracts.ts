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
}
