// Layer-2 fixture for the reply-quote surface (B1): the quote sheet's selectable text, the
// reply-quote cap, and the send body the mobile sender builds when a selection is quoted. Every
// quote case is derived through the REAL server rule (deriveMessageQuote) at generation time on
// both sides: the mobile conversion the port reproduces, and the Harmony port itself (loaded from
// its .ets source, as quote-port.test does). A selection the sheet offers that the server cannot
// find in the parent message is a defect, because the reply would silently degrade to a plain one.
// `segments` holds the cases where the port reproduces the mobile conversion exactly; `quotes`
// holds the wider corpus the port must at least keep locatable (task boxes, loose lists, images,
// hard breaks).

import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import type { MessageBlock } from "@rakazo/contracts";
import { REPLY_QUOTE_MAX_LENGTH, truncateReplyQuote } from "@rakazo/contracts";
import { resolveComposerSendPlan } from "@rakazo/core";
import { deriveMessageQuote, MAX_QUOTABLE_SOURCE_LENGTH } from "@rakazo/core/message-quote";
import type { rpc } from "@rakazo/mobile/lib/api/api.js";
import { quotableMessageSegments } from "@rakazo/mobile/lib/messages/message-presentation.js";
import type { SendAttempt, SendPayload } from "@rakazo/mobile/lib/thread/send/thread-feedback.js";
import { deliverSend } from "@rakazo/mobile/lib/thread/send/thread-feedback.js";

type QuoteRole = "user" | "bot";
type QuotePort = typeof import("../entry/src/main/ets/thread/message-quote.ets");

let cachedPort: Promise<QuotePort> | null = null;

/** The Harmony port, loaded from its .ets source the way contract/quote-port.test loads it. */
function quotePort(): Promise<QuotePort> {
  cachedPort ??= (async (): Promise<QuotePort> => {
    const directory = mkdtempSync(path.join(tmpdir(), "harmony-quote-port-"));
    try {
      for (const file of ["markdown-plain", "message-quote"]) {
        const source = readFileSync(
          new URL(`../entry/src/main/ets/thread/${file}.ets`, import.meta.url),
          "utf8",
        );
        writeFileSync(
          path.join(directory, `${file}.ts`),
          source.replace(/from '\.\/([a-z.-]+?)'/g, "from './$1.ts'"),
        );
      }
      return (await import(
        pathToFileURL(path.join(directory, "message-quote.ts")).href
      )) as QuotePort;
    } finally {
      rmSync(directory, { force: true, recursive: true });
    }
  })();
  return cachedPort;
}

interface QuoteCase {
  name: string;
  role: QuoteRole;
  blocks: MessageBlock[];
}

function textCase(name: string, role: QuoteRole, ...texts: string[]): QuoteCase {
  return {
    name,
    role,
    blocks: texts.map((text): MessageBlock => ({ kind: "text", text })),
  };
}

// The conversion the port reproduces word for word: paragraph joins, headings, list markers,
// tables with escaped pipes, quotes, footnotes with the renderer's number, HTML blocks, code.
const SEGMENT_CASES: QuoteCase[] = [
  textCase("paragraph", "bot", "Hello world, this is fine."),
  textCase("two-paragraphs", "bot", "p1\n\np2"),
  textCase("soft-break", "bot", "line one\nline two"),
  textCase("heading", "bot", "# Title\n\nBody"),
  textCase("heading-closing-hashes", "bot", "## Title ##"),
  textCase("setext-heading", "bot", "Title\n=====\n\nSub\n---"),
  textCase("bullet-list", "bot", "- one\n- two\n  - nested"),
  textCase("ordered-list", "bot", "1. first\n2. second"),
  textCase("ordered-paren-list", "bot", "1) one\n2) two"),
  textCase("table", "bot", "| a | b |\n|---|---|\n| 1 | 2 |"),
  textCase("table-alignment", "bot", "| h1 | h2 |\n|:--|--:|\n| 1 | 2 |"),
  textCase("table-escaped-pipe", "bot", "| a | b |\n|---|---|\n| x \\| y | z |"),
  textCase("table-br-cell", "bot", "| h |\n|---|\n| a<br>b |"),
  textCase("blockquote", "bot", "> quoted\n> more"),
  textCase("nested-blockquote", "bot", "> outer\n> > inner"),
  textCase("quoted-table", "bot", "> | a | b |\n> |---|---|\n> | 1 | 2 |"),
  textCase("footnote", "bot", "Note[^word]\n\n[^word]: The definition"),
  textCase(
    "footnotes-numbered-by-first-reference",
    "bot",
    "A[^b] C[^a]\n\n[^a]: first\n[^b]: second",
  ),
  textCase("html-block", "bot", "<div>hidden</div>\n\nVisible"),
  textCase("html-comment", "bot", "<!-- secret -->\n\nvisible"),
  textCase("html-type-7-block", "bot", "<custom-tag>\ncontent\n</custom-tag>\n\nvisible"),
  textCase("inline-html", "bot", "before <b>bold</b> after"),
  textCase("html-span-line", "bot", "<span>hi</span>\n\nvisible"),
  textCase("fenced-code", "bot", "```\ncode line\n  indented\n```"),
  textCase("fenced-code-language", "bot", "```js\nconst a = 1;\n```"),
  textCase("code-between-paragraphs", "bot", "text\n\n```\ncode\n```\n\nmore"),
  textCase("indented-code", "bot", "    indented code\n    line two"),
  textCase("inline-code", "bot", "use `x = 1` now"),
  textCase("emphasis", "bot", "**bold** and *ital*"),
  textCase("strikethrough", "bot", "~~gone~~ kept"),
  textCase("underscore-emphasis", "bot", "_em_ text"),
  textCase("intraword-underscore", "bot", "foo_bar_baz"),
  textCase("link", "bot", "[label](https://example.test/x)"),
  textCase("bare-url", "bot", "see https://example.test/x now"),
  textCase("autolink", "bot", "<https://e.test/x>"),
  textCase("email-autolink", "bot", "<a@e.test>"),
  textCase("escape", "bot", "a \\* b"),
  textCase("entity", "bot", "a &amp; b"),
  textCase("thematic-break", "bot", "a\n\n---\n\nb"),
  textCase("list-after-paragraph", "bot", "para\n- item"),
  textCase("heading-then-list", "bot", "## T\n\n- a"),
  textCase("two-lists", "bot", "- a\n- b\n\n1. c\n2. d"),
  textCase("quoted-list", "bot", "> - a\n> - b"),
  textCase("blank-line-runs", "bot", "a\n\n\n\nb"),
  textCase("two-text-blocks", "bot", "first block", "second block"),
  textCase("user-plain-text", "user", "  user plain text\nno markdown **here**"),
  textCase("user-two-blocks", "user", "one", "  two "),
  // B1 review shapes: a reference link the message defines, image syntax inside code, a raw
  // pipe inside a table cell's code, entities, <br>, a pipe line after a table's blank line,
  // a nested-bracket image, and a fence inside a blockquote.
  textCase("reference-link-full", "bot", "[x][1]\n\n[1]: https://e.test/a"),
  textCase("reference-link-label", "bot", "[label][ref]\n\n[ref]: https://e.test/a"),
  textCase("reference-link-collapsed", "bot", "[foo][]\n\n[foo]: https://e.test/a"),
  textCase("reference-link-shortcut-in-list", "bot", "- [a]\n\n[a]: https://e.test/a"),
  textCase("inline-code-image", "bot", "a `![alt](x.png)` b"),
  textCase("table-code-raw-pipe", "bot", "| h | i |\n|---|---|\n| `a|b` | c |"),
  textCase("table-code-raw-pipe-wide", "bot", "| h | i | j |\n|---|---|---|\n| `a|b` | c | d |"),
  textCase("entity-copy", "bot", "a &copy; b"),
  textCase("entity-mdash", "bot", "a &mdash; b"),
  textCase("html-br-inline", "bot", "a<br>b"),
  textCase("table-blank-line-between-rows", "bot", "| a | b |\n|---|---|\n| 1 | 2 |\n\n| 3 | 4 |"),
  textCase("nested-bracket-image", "bot", "![a [b] c](https://e.test/i.png)"),
  textCase("quoted-fenced-code", "bot", "> ```\n> code\n> ```"),
  textCase("quoted-fenced-code-language", "bot", "> ```js\n> const a = 1;\n> ```"),
];

// The wider corpus: selections here may read slightly differently from the renderer, but the
// server must still find every one of them in the message the sheet quotes.
const QUOTE_CASES: QuoteCase[] = [
  ...SEGMENT_CASES,
  textCase("task-list", "bot", "- [ ] todo\n- [x] done"),
  textCase("nested-task-list", "bot", "- [ ] parent\n  - [x] child"),
  textCase("loose-list", "bot", "- a\n\n- b"),
  textCase("inline-image", "bot", "before ![alt](https://e.test/i.png) after"),
  textCase("image-only", "bot", "![alt](https://e.test/i.png)"),
  textCase("table-body-without-pipes", "bot", "| h1 | h2 |\n|----|----|\nbody has no pipe"),
  textCase("code-in-list-item", "bot", "- item\n  ```\n  code\n  ```\n- next"),
  textCase("mixed-marks", "bot", "**bold** and `code` and [link](https://e.test)"),
  // Locatable only: the renderer keeps a hard break's newline, the port joins with a space, and
  // the server's search folds both to one space.
  textCase("hard-break-backslash", "bot", "a\\\nb"),
  textCase("hard-break-spaces", "bot", "a  \nb"),
];

async function sendCase(
  name: string,
  target: { botId?: string; groupId?: string },
  text: string,
  replyQuote: string | null,
  replyToMessageId: string,
  asFile: boolean,
) {
  const payload: SendPayload = {
    originThreadKey: "thread-probe",
    botTarget: target.botId,
    groupTarget: target.groupId,
    displayText: text,
    replyPreview: null,
    reroutedToGroup: false,
    plan: resolveComposerSendPlan({ text, mentions: [], hasAttachments: false }),
    attachments: [],
    replyTargetId: replyToMessageId || undefined,
    replyQuote,
  };
  const attempt: SendAttempt = {
    payload,
    clientNonce: "nonce-probe",
    artifactIds: new Map<string, string>(),
    session: 1,
    apiBase: "https://example.test",
    spaceId: "space-probe",
    userId: "user-probe",
    cacheSession: "cache-probe",
    state: "pending",
    imageHandling: asFile ? "file" : undefined,
  };
  const calls: { path: string; body: unknown }[] = [];
  const request = (async (path: string, body: unknown) => {
    calls.push({ path, body: JSON.parse(JSON.stringify(body)) });
    return { seq: 9, taskId: "task-probe", runId: "run-probe" };
  }) as typeof rpc;
  await deliverSend(payload, attempt, request);
  return {
    name,
    botId: target.botId ?? "",
    groupId: target.groupId ?? "",
    text,
    replyQuote: replyQuote ?? "",
    replyToMessageId,
    clientNonce: attempt.clientNonce,
    imagesAsFiles: asFile,
    body: calls.at(-1)?.body,
  };
}

export async function generateQuoteFixture() {
  const port = await quotePort();
  const segments = SEGMENT_CASES.map((entry) => ({
    name: entry.name,
    role: entry.role,
    blocks: entry.blocks,
    expected: quotableMessageSegments(entry.role, entry.blocks),
  }));
  const quotes = QUOTE_CASES.map((entry) => {
    const format = entry.role === "user" ? "plain-text" : "markdown";
    const offered = quotableMessageSegments(entry.role, entry.blocks);
    const expected = offered.map((segment) => {
      const derived = deriveMessageQuote(entry.blocks, segment, format);
      if (!derived) {
        throw new Error(`quote case ${entry.name} offers a segment the server cannot find`);
      }
      return derived;
    });
    // The port's own segments are what the device offers, so they are held to the same rule
    // here: a shape the conversion misses can never reach a fixture and only fail on a phone.
    for (const [index, segment] of port
      .quotableMessageSegments(entry.role, entry.blocks)
      .entries()) {
      if (!deriveMessageQuote(entry.blocks, segment, format)) {
        throw new Error(
          `quote case ${entry.name} offers port segment ${index} the server cannot find`,
        );
      }
    }
    return { name: entry.name, role: entry.role, blocks: entry.blocks, expected };
  });
  const truncateValues = [
    "",
    "short",
    "a".repeat(REPLY_QUOTE_MAX_LENGTH),
    "a".repeat(REPLY_QUOTE_MAX_LENGTH + 1),
    `${"a".repeat(REPLY_QUOTE_MAX_LENGTH - 1)}😀`,
    `${"a".repeat(REPLY_QUOTE_MAX_LENGTH - 2)}😀`,
    "😀".repeat(REPLY_QUOTE_MAX_LENGTH / 2 + 1),
  ];
  const probe = "hello";
  const empty: MessageBlock[] = [{ kind: "text", text: "   " }];
  const chart: MessageBlock[] = [{ kind: "chart" } as unknown as MessageBlock];
  const imageOnly: MessageBlock[] = [{ kind: "text", text: "![alt](https://e.test/i.png)" }];
  const oversized: MessageBlock[] = [
    { kind: "text", text: "a".repeat(MAX_QUOTABLE_SOURCE_LENGTH) },
    { kind: "text", text: "b" },
  ];
  const ordinary: MessageBlock[] = [{ kind: "text", text: "hello" }];
  const hasQuotable = [
    { name: "user-text", role: "user" as QuoteRole, blocks: ordinary },
    { name: "bot-text", role: "bot" as QuoteRole, blocks: ordinary },
    { name: "blank-text", role: "bot" as QuoteRole, blocks: empty },
    { name: "chart-only", role: "bot" as QuoteRole, blocks: chart },
    { name: "image-only", role: "bot" as QuoteRole, blocks: imageOnly },
    { name: "over-source-limit", role: "bot" as QuoteRole, blocks: oversized },
  ].map((entry) => ({
    name: entry.name,
    role: entry.role,
    blocks: entry.blocks,
    expected: quotableMessageSegments(entry.role, entry.blocks).length > 0,
  }));
  return {
    constants: {
      replyQuoteMaxLength: REPLY_QUOTE_MAX_LENGTH,
      maxQuotableSourceLength: MAX_QUOTABLE_SOURCE_LENGTH,
      replyQuoteProbe: truncateReplyQuote(probe),
    },
    segments,
    truncate: truncateValues.map((value) => ({ value, expected: truncateReplyQuote(value) })),
    hasQuotable,
    send: [
      await sendCase(
        "bot-quote",
        { botId: "bot-probe" },
        " hello ",
        "Quoted words",
        "message-probe",
        false,
      ),
      await sendCase(
        "group-quote",
        { groupId: "group-probe" },
        "hello there",
        "A quoted line\nand its second line",
        "message-probe",
        true,
      ),
      await sendCase("bot-plain", { botId: "bot-probe" }, "hello", null, "message-probe", false),
    ],
    quotes,
  };
}
