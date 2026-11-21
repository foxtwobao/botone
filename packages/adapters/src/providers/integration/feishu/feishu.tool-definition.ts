import type { ConnectorTool } from "@rakazo/adapter-kit";

export type FeishuModule = "doc" | "task" | "calendar" | "sheet";
export type FeishuTool = ConnectorTool & { title: string };

/** Scopes each module needs; the OAuth request is the union of the enabled modules. */
export const MODULE_SCOPES: Record<FeishuModule, string[]> = {
  doc: ["docx:document"],
  task: ["task:task:read", "task:task:write"],
  calendar: [
    "calendar:calendar:read",
    "calendar:calendar.event:read",
    "calendar:calendar.event:create",
  ],
  sheet: ["sheets:spreadsheet:create", "sheets:spreadsheet:read", "sheets:spreadsheet:write_only"],
};

export const MODULE_TOOLS: Record<FeishuModule, FeishuTool[]> = {
  doc: [
    {
      name: "feishu_create_doc",
      title: "Create document",
      description:
        "Create a Feishu document and return its ID and title. Optionally place it in a folder by its folder token.",
      readOnly: false,
      inputSchema: {
        type: "object",
        additionalProperties: false,
        required: ["title"],
        properties: {
          title: { type: "string", minLength: 1, maxLength: 200 },
          folderToken: { type: "string", minLength: 1, maxLength: 200 },
        },
      },
    },
    {
      name: "feishu_read_doc",
      title: "Read document",
      description:
        "Read the plain-text content of an accessible Feishu document, by its document ID.",
      readOnly: true,
      inputSchema: {
        type: "object",
        additionalProperties: false,
        required: ["documentId"],
        properties: { documentId: { type: "string", minLength: 1, maxLength: 200 } },
      },
    },
  ],
  task: [
    {
      name: "feishu_create_task",
      title: "Create task",
      description:
        "Create a Feishu task with a summary, optional description and optional due time (epoch milliseconds).",
      readOnly: false,
      inputSchema: {
        type: "object",
        additionalProperties: false,
        required: ["summary"],
        properties: {
          summary: { type: "string", minLength: 1, maxLength: 500 },
          description: { type: "string", maxLength: 4000 },
          dueTimestamp: { type: "integer", minimum: 0 },
        },
      },
    },
    {
      name: "feishu_list_tasks",
      title: "List tasks",
      description: "List accessible Feishu tasks. Continue from nextPageToken when present.",
      readOnly: true,
      inputSchema: {
        type: "object",
        additionalProperties: false,
        properties: {
          pageSize: { type: "integer", minimum: 1, maximum: 100 },
          pageToken: { type: "string", minLength: 1, maxLength: 500 },
        },
      },
    },
  ],
  calendar: [
    {
      name: "feishu_list_events",
      title: "List calendar events",
      description:
        "List Feishu calendar events between two unix-second timestamps. Defaults to the primary calendar; pass calendarId for another.",
      readOnly: true,
      inputSchema: {
        type: "object",
        additionalProperties: false,
        required: ["startTime", "endTime"],
        properties: {
          startTime: { type: "integer" },
          endTime: { type: "integer" },
          calendarId: { type: "string", minLength: 1, maxLength: 200 },
        },
      },
    },
    {
      name: "feishu_create_event",
      title: "Create calendar event",
      description:
        "Create a Feishu calendar event with a summary and unix-second start/end times. Defaults to the primary calendar.",
      readOnly: false,
      inputSchema: {
        type: "object",
        additionalProperties: false,
        required: ["summary", "startTime", "endTime"],
        properties: {
          summary: { type: "string", minLength: 1, maxLength: 500 },
          startTime: { type: "integer" },
          endTime: { type: "integer" },
          calendarId: { type: "string", minLength: 1, maxLength: 200 },
        },
      },
    },
  ],
  sheet: [
    {
      name: "feishu_create_sheet",
      title: "Create spreadsheet",
      description: "Create a Feishu spreadsheet and return its token and title.",
      readOnly: false,
      inputSchema: {
        type: "object",
        additionalProperties: false,
        required: ["title"],
        properties: { title: { type: "string", minLength: 1, maxLength: 200 } },
      },
    },
    {
      name: "feishu_read_sheet",
      title: "Read spreadsheet range",
      description:
        "Read cell values of a Feishu spreadsheet range, e.g. Sheet1!A1:C10, by spreadsheet token.",
      readOnly: true,
      inputSchema: {
        type: "object",
        additionalProperties: false,
        required: ["spreadsheetToken", "range"],
        properties: {
          spreadsheetToken: { type: "string", minLength: 1, maxLength: 200 },
          range: { type: "string", minLength: 1, maxLength: 200 },
        },
      },
    },
    {
      name: "feishu_append_rows",
      title: "Append spreadsheet rows",
      description:
        "Append rows of cell values to a Feishu spreadsheet range, by spreadsheet token. A single-cell range is widened to one row of the values' width.",
      readOnly: false,
      inputSchema: {
        type: "object",
        additionalProperties: false,
        required: ["spreadsheetToken", "range", "values"],
        properties: {
          spreadsheetToken: { type: "string", minLength: 1, maxLength: 200 },
          range: { type: "string", minLength: 1, maxLength: 200 },
          values: {
            type: "array",
            minItems: 1,
            maxItems: 100,
            items: { type: "array", items: { type: ["string", "number", "boolean", "null"] } },
          },
        },
      },
    },
  ],
};
