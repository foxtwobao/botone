// Shared catalog reader: lingui's own PO parser (C-1) over the real catalogs, producing the
// msgid → msgstr map the device runtime loads. No hand-rolled PO parsing.

import { readFileSync } from "node:fs";
import path from "node:path";
import { parsePoFile } from "@lingui/format-po";

export function readCatalog(localesDir: string, locale: string): Record<string, string> {
  const po = parsePoFile(readFileSync(path.join(localesDir, locale, "messages.po"), "utf8"));
  const messages: Record<string, string> = {};
  for (const item of po.items) {
    if (!item.msgid || item.obsolete) continue;
    const translation = item.msgstr[0] ?? "";
    // An empty translation falls back to the source string at runtime, like lingui.
    if (translation) messages[item.msgid] = translation;
  }
  return messages;
}
