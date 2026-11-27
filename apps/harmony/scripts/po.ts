// Shared catalog reader: lingui's own PO parser (C-1) over the real catalogs, producing the
// msgid → msgstr map the device runtime loads. No hand-rolled PO parsing.

import { readFileSync } from "node:fs";
import path from "node:path";
import { parsePoFile } from "@lingui/format-po";

export function readCatalog(localesDir: string, locale: string): Record<string, string> {
  const po = parsePoFile(readFileSync(path.join(localesDir, locale, "messages.po"), "utf8"));
  // The device runtime keys by msgid alone and has no context form. A msgctxt entry is a
  // different message (web's "email sign-in" Code) that must not shadow the plain msgid the
  // mobile ports read: the context-free value wins.
  const plain: Record<string, string> = {};
  const contextual: Record<string, string> = {};
  for (const item of po.items) {
    if (!item.msgid || item.obsolete) continue;
    const translation = item.msgstr[0] ?? "";
    // An empty translation falls back to the source string at runtime, like lingui.
    if (!translation) continue;
    if (item.msgctxt === null || item.msgctxt === undefined) {
      plain[item.msgid] = translation;
    } else {
      contextual[item.msgid] = translation;
    }
  }
  return { ...contextual, ...plain };
}
