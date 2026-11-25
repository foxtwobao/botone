// Differential check for the thread message-text ports (M5): the port's decisions against the real
// TypeScript they were ported from (core message-text/message-replies/display-name/group-mentions/
// markdown-plain, chat-ui's plain-text link parts, mobile mention targets and selectable text).
// The port is the .ets source loaded as erasable TS, the same trick the markdown fixture replay
// uses; when the two disagree the assertion prints the case. Not a layer-2 fixture: this reads the
// reference directly, so it runs wherever the contract suite runs.
//
// The reference comes in by package name, like every workspace import. Two of its modules need a
// mock keyed by the file they resolve to, because this package declares neither: a bare
// `vi.mock("react-native")` is keyed by that bare name here and misses the import chat-ui's
// native entry makes from inside its own dependency, and the real link splitter is exported only
// from that entry, so a pass-through mock keeps a handle on it. Both resolve as mobile sees them.
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { expectLinearTime } from "@rakazo/contracts/test-timing";
import * as core from "@rakazo/core";
import { blockText } from "@rakazo/mobile/lib/api/mobile-types.js";
import * as mobileMentions from "@rakazo/mobile/lib/messages/message-mentions.js";
import * as mobileSelectable from "@rakazo/mobile/lib/messages/selectable-text.js";
import { afterAll, describe, expect, it, vi } from "vitest";
import type * as markdownPlain from "../entry/src/main/ets/thread/markdown-plain.ets";
import type * as messageLinks from "../entry/src/main/ets/thread/message-links.ets";
import type * as messageMentions from "../entry/src/main/ets/thread/message-mentions.ets";
import type * as messageText from "../entry/src/main/ets/thread/message-text.ets";
import type * as selectableText from "../entry/src/main/ets/thread/selectable-text.ets";
import { linkifyPatterns, renderLinkifyPatterns } from "../scripts/gen-linkify-patterns.ts";
import { loadTables, renderTables } from "../scripts/gen-markdown-tables.ts";

const mobileRequire = await vi.hoisted(async () =>
  (await import("node:module")).createRequire(
    new URL("../../mobile/package.json", import.meta.url),
  ),
);

// react-native ships Flow source node cannot load, and chat-ui's native entry imports it at
// module scope. Anything of its Animated API stands in for anything else.
vi.mock(mobileRequire.resolve("react-native"), () => {
  const anything = new Proxy((): undefined => undefined, {
    get: (): unknown => anything,
    construct: (): Record<string, never> => ({}),
  });
  const component = (): null => null;
  const method = (): (() => undefined) => (): undefined => undefined;
  return {
    Alert: { alert: method() },
    Animated: anything,
    I18nManager: { isRTL: false, doLeftAndRightSwapInRTL: false },
    Image: component,
    Linking: { openURL: method(), canOpenURL: async (): Promise<boolean> => true },
    Platform: {
      OS: "ios",
      Version: 0,
      isTesting: true,
      constants: {},
      select: (options: Record<string, unknown> | undefined) => options?.ios ?? options?.native,
    },
    Pressable: component,
    ScrollView: component,
    StyleSheet: {
      create: (styles: unknown) => styles,
      flatten: (styles: unknown) => styles,
      hairlineWidth: 1,
    },
    Text: component,
    TextInput: component,
    View: component,
  };
});

/** The real link splitter and the real code block extractor, as the native entry loads them. */
const chatUi = vi.hoisted(
  (): {
    plainTextLinkParts?: (text: string) => unknown;
    markdownCodeBlocks?: (markdown: string) => unknown;
  } => ({}),
);
vi.mock(mobileRequire.resolve("@rakazo/chat-ui/native"), async (original) => {
  const actual = await original<Record<string, unknown>>();
  chatUi.plainTextLinkParts = actual.plainTextLinkParts as (text: string) => unknown;
  chatUi.markdownCodeBlocks = actual.markdownCodeBlocks as (markdown: string) => unknown;
  return actual;
});

type Port = typeof markdownPlain &
  typeof messageLinks &
  typeof messageMentions &
  typeof messageText &
  typeof selectableText;

const appRoot = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
// A directory of this run's own: two runs (another worktree, another worker) must not read each
// other's copy of the port.
const outDir = mkdtempSync(path.join(tmpdir(), "harmony-mt-port-"));
const threadDir = path.join(appRoot, "entry/src/main/ets/thread");
for (const file of readdirSync(threadDir)) {
  // The generated modules are rebuilt below from their generators, so a clean checkout that has
  // not run `harmony:codegen` runs this test the same as one that has.
  if (!/^(?:markdown-|message-|selectable-text)[\w.-]*\.ets$/.test(file) || /generated/.test(file))
    continue;
  writeFileSync(
    path.join(outDir, file.replace(/\.ets$/, ".ts")),
    readFileSync(path.join(threadDir, file), "utf8")
      .replace(/from '\.\/([a-z.-]+?)'/g, "from './$1.ts'")
      .replace(/Record<string, Object>/g, "Record<string, object>"),
  );
}
writeFileSync(
  path.join(outDir, "link-patterns.generated.ts"),
  renderLinkifyPatterns(linkifyPatterns()),
);
const tables = loadTables();
writeFileSync(
  path.join(outDir, "markdown-tables.generated.ts"),
  renderTables(tables.maps, tables.entities),
);
// The bubble's flat run list lives beside the bubble; it reads the parser like the ports do.
writeFileSync(
  path.join(outDir, "markdown-runs.ts"),
  readFileSync(
    path.join(appRoot, "entry/src/main/ets/features/chat/markdown-runs.ets"),
    "utf8",
  ).replace(/from '\.\.\/\.\.\/thread\/([a-z.-]+?)'/g, "from './$1.ts'"),
);

function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const key of Object.keys(value as Record<string, unknown>).sort()) {
      const item = (value as Record<string, unknown>)[key];
      if (item !== undefined) out[key] = canonical(item);
    }
    return out;
  }
  return value;
}

const failures: { name: string; input: unknown; expected: unknown; actual: unknown }[] = [];
let checked = 0;
function check(name: string, input: unknown, expected: unknown, actual: unknown) {
  checked += 1;
  if (JSON.stringify(expected) !== JSON.stringify(actual)) {
    failures.push({ name, input, expected, actual });
  }
}

type LinkPart = { type: string; value: string; href?: string; pageId?: string };
let port: Port;

const realLinkParts = (text: string): LinkPart[] => chatUi.plainTextLinkParts?.(text) as LinkPart[];
const realCodeBlocks = (markdown: string): string[] =>
  chatUi.markdownCodeBlocks?.(markdown) as string[];
/** The parts as comparable data: the reference names a page link's target `pageId`. */
const partShape = (parts: LinkPart[]): unknown =>
  parts.map((part) =>
    part.type === "text"
      ? { type: "text", value: part.value }
      : { type: part.type, value: part.value, href: part.pageId ?? part.href },
  );

afterAll(() => {
  rmSync(outDir, { recursive: true, force: true });
});

describe("harmony message-text port", () => {
  it("matches the TypeScript reference", async () => {
    port = Object.assign(
      {},
      ...(await Promise.all(
        [
          "markdown-plain",
          "message-links",
          "message-mentions",
          "message-text",
          "selectable-text",
        ].map(async (name) => await import(pathToFileURL(path.join(outDir, `${name}.ts`)).href)),
      )),
    ) as Port;
    expect(chatUi.plainTextLinkParts, "the real link splitter loaded").toBeTypeOf("function");

    const portLite = await import(pathToFileURL(path.join(outDir, "markdown-lite.ts")).href);
    /** What the copy button on a code block copies: the code each codeblock node carries written. */
    const codeBlocksOfTree = (markdown: string): string[] => {
      const found: string[] = [];
      const walk = (node: { type: string; copyText: string; children: unknown[] }): void => {
        if (node.type === "codeblock") {
          if (/\S/.test(node.copyText)) found.push(node.copyText.replace(/\n$/, ""));
          return;
        }
        for (const child of node.children) walk(child as typeof node);
      };
      walk(portLite.parseMarkdown(markdown) as never);
      return found;
    };

    const LABELS = { photo: "Photo", attachment: "Attachment", message: "Message" };

    // displayName / isOpaqueName
    const NAMES = [
      "Bot",
      "Alice",
      "  Bob  ",
      "",
      " setup.py ",
      "__token__",
      "123e4567-e89b-12d3-a456-426614174000",
      "c123456789012345678901234",
      "aB3xY9qQ2wEr5tYu1IoP",
      "王五",
      "data-processor",
      "note.md",
    ];
    for (const name of NAMES) {
      check("displayName", name, core.displayName(name, "Bot"), port.displayName(name, "Bot"));
      check("isOpaqueName", name, core.isOpaqueName(name), port.isOpaqueName(name));
    }

    // mentionSpans / groupMentionNames / everyoneWords / mentionStandsAlone
    const MEMBER_NAMES = ["Writer", "王五", "All", "Everyone", "helper-bot", "Ana"];
    const TEXTS = [
      "@Writer please",
      "请@Writer你看下",
      "@王五",
      "@Writers",
      "hi@Writer",
      "@Writer@Ana",
      "@All @所有人",
      "x.com/@all",
      "a@all.com",
      "@all/pkg",
      "see @All, thanks",
      "​@Writer",
      "@writer and @WRITER",
      "e-mail bob@x.com then @Writer",
      "`@Writer` in code",
      "```\n@Writer\n```",
      "[t](https://x.com/@all)",
      "@Ana-Marie Smith",
      "@helper-bot v2",
      "@",
      "@ ",
      "@所有人看看",
      "text@所有人",
      "@Everyone and @everyone",
      "https://x.com/a，@所有人",
      "[docs](https://x.com/a)@all",
      "@Writer。stop",
      "！@Writer",
      "a@Writer b",
      "@Writer 你好",
      "@王五@王五",
      "(@Writer)",
      "@Writer)",
      "@Writer(",
      "@所有人",
      "@all",
      "@ALL",
    ];
    for (const text of TEXTS) {
      check(
        "mentionSpans",
        text,
        core.mentionSpans(text, MEMBER_NAMES),
        port.mentionSpans(text, MEMBER_NAMES),
      );
      check(
        "mentionSpans-everyone",
        text,
        core.mentionSpans(text, MEMBER_NAMES, ["all", "所有人", "everyone"]),
        port.mentionSpans(text, MEMBER_NAMES, ["all", "所有人", "everyone"]),
      );
      check(
        "groupMentionNames",
        text,
        core.groupMentionNames(text, MEMBER_NAMES),
        port.groupMentionNames(text, MEMBER_NAMES),
      );
      for (const span of core.mentionSpans(text, MEMBER_NAMES)) {
        check(
          "mentionStandsAlone",
          `${text}@${span.start}`,
          core.mentionStandsAlone(text, span.start, span.end),
          port.mentionStandsAlone(text, span.start, span.end),
        );
      }
    }
    check(
      "everyoneWords",
      "base",
      core.everyoneWords(MEMBER_NAMES),
      port.everyoneWords(MEMBER_NAMES),
    );
    check("everyoneWords-empty", "empty", core.everyoneWords([]), port.everyoneWords([]));

    // userMentionTargets / userTextRuns (splitMentionText over the link parts)
    const MEMBERS = [
      { botId: "b1", name: "Writer", color: "#f00" },
      { botId: "b2", name: "王五", color: "#0f0" },
      { botId: "b3", name: "Writer", color: "#00f" },
      { botId: "b4", name: "  ", color: "#111" },
    ];
    for (const text of [
      "@Writer hello",
      "请@王五看下 @everyone",
      "@b4 nobody",
      "plain text",
      "@all",
      "see https://x.com/@Writer now",
      "mail a@b.co and @Writer",
      "[page](page:p1) @all",
      "[Home](page:p1) then https://x.com/a @Writer",
    ]) {
      const targets = mobileMentions.userMentionTargets(MEMBERS, text);
      const asTarget = (
        target: { kind: string; id: string; name: string; color?: string } | null,
      ) =>
        target
          ? { kind: target.kind, id: target.id, name: target.name, color: target.color ?? "" }
          : null;
      check(
        "userMentionTargets",
        text,
        targets.map(asTarget),
        port.userMentionTargets(MEMBERS, text),
      );
      // The user bubble's runs: mobile lays its linkified text over splitMentionText, so the
      // expected runs come from those two real pieces. One difference is the port's own: a page
      // link is plain text here, since no page opens yet, where mobile opens the page.
      check(
        "userTextRuns",
        text,
        realLinkParts(text).flatMap((piece) =>
          piece.type === "text"
            ? core
                .splitMentionText(piece.value, targets)
                .map((part) => ({ text: part.text, href: "", target: asTarget(part.target) }))
            : [{ text: piece.value, href: piece.type === "link" ? piece.href : "", target: null }],
        ),
        port
          .userTextRuns(text, targets)
          .map((run) => ({ text: run.text, href: run.href, target: asTarget(run.target) })),
      );
    }

    // channelMessageLine / selectableMessageText / copyableMessageText / blockText
    const MESSAGE = {
      role: "bot",
      blocks: [
        {
          kind: "channel_message",
          fromLabel: "Sam",
          provider: "slack",
          transport: "im",
          text: "hello",
        },
        {
          kind: "channel_message",
          fromLabel: "Ann",
          provider: "sendblue",
          transport: "SMS",
          text: "hi",
        },
        { kind: "text", text: "body" },
        { kind: "progress", text: "working", activity: true },
        { kind: "ask", text: "Allow?" },
        { kind: "steps", steps: [{ label: "Read", count: 2 }, { label: "Write" }] },
        { kind: "file", name: "doc.pdf", size: 12 },
        { kind: "image", name: "pic.png" },
        { kind: "chart", name: "growth" },
        { kind: "page", title: "Home" },
        { kind: "app", server: "srv" },
        { kind: "subagent", name: "Scout", task: "search", result: "done" },
        { kind: "cloud_agent", title: "Agent", status: "open", prUrl: "https://x.com/1" },
        { kind: "child_bot", name: "Kid", status: "created" },
        { kind: "tool_question", question: { source: "Why?" } },
        { kind: "handoff", text: "over" },
      ],
    };
    check(
      "selectableMessageText",
      "message",
      core.selectableMessageText(MESSAGE),
      port.selectableMessageText(MESSAGE),
    );
    check(
      "copyableMessageText",
      "message",
      core.copyableMessageText(MESSAGE),
      port.copyableMessageText(MESSAGE),
    );
    check("blockText", "message", blockText(MESSAGE), port.blockText(MESSAGE));

    // reply helpers
    check(
      "replyLineText",
      "a",
      core.replyLineText("q  q", "p", "f"),
      port.replyLineText("q  q", "p", "f"),
    );
    check(
      "replyLineText2",
      "b",
      core.replyLineText(undefined, "p\nlong", undefined),
      port.replyLineText(undefined, "p\nlong", undefined),
    );
    check(
      "compactReplyExcerpt",
      "a",
      core.compactReplyExcerpt("\n  hi there\nnext"),
      port.compactReplyExcerpt("\n  hi there\nnext"),
    );
    check(
      "compactReplyExcerpt-cjk",
      "b",
      core.compactReplyExcerpt("😀".repeat(200)),
      port.compactReplyExcerpt("😀".repeat(200)),
    );
    const ATTACH_BLOCKS = [
      { kind: "image", name: "pic.png", artifactId: "a1", mimeType: "image/png" },
      { kind: "file", name: "doc.pdf", artifactId: "a2" },
    ];
    check(
      "replyAttachment",
      "image-first",
      canonical(core.replyAttachment(ATTACH_BLOCKS)),
      canonical(port.replyAttachment(ATTACH_BLOCKS) as Record<string, unknown>),
    );
    check(
      "replyAttachment-file",
      "file",
      core.replyAttachment([{ kind: "file", name: "doc.pdf" }]),
      port.replyAttachment([{ kind: "file", name: "doc.pdf" }]),
    );
    check(
      "replyLabel",
      "legacy",
      core.replyLabel("pic.png", undefined, { kind: "image", name: "pic.png" }, LABELS),
      port.replyLabel("pic.png", undefined, { kind: "image", name: "pic.png" }, LABELS),
    );
    check(
      "replyLabel2",
      "quote",
      core.replyLabel("multi\nline quote", "preview", null, LABELS),
      port.replyLabel("multi\nline quote", "preview", null, LABELS),
    );
    check(
      "channelMessageSender",
      "a",
      core.channelMessageSender(MESSAGE.blocks),
      port.channelMessageSender(MESSAGE.blocks),
    );
    {
      const previewRef = (message) => core.previewMessageText(message, LABELS);
      const cases = [
        { role: "bot", blocks: [{ kind: "text", text: "**bold** and `code`" }] },
        { role: "user", blocks: [{ kind: "text", text: "plain" }] },
        { role: "bot", blocks: [{ kind: "channel_message", text: "relayed", fromLabel: "Sam" }] },
        { role: "bot", blocks: [{ kind: "image", name: "pic.png" }] },
        { role: "bot", blocks: [{ kind: "file", name: "doc.pdf" }] },
        {
          role: "bot",
          blocks: [{ kind: "ask", text: "What name?", input: "text", status: "pending" }],
        },
        { role: "bot", blocks: [{ kind: "delivery" }, { kind: "text", text: "wake" }] },
        { role: "bot", blocks: [] },
      ];
      for (const message of cases) {
        check(
          "previewMessageText",
          JSON.stringify(message.blocks),
          previewRef(message),
          port.previewMessageText(message, LABELS),
        );
      }
    }
    check(
      "isPageOriginReply",
      "page",
      core.isPageOriginReply({ replyPreview: { page: true }, replyQuote: undefined }),
      port.isPageOriginReply({ replyPreview: { page: true }, replyQuote: undefined }),
    );
    check(
      "isPageOriginReply2",
      "quote",
      core.isPageOriginReply({ replyPreview: { page: true }, replyQuote: "q" }),
      port.isPageOriginReply({ replyPreview: { page: true }, replyQuote: "q" }),
    );
    check(
      "otherAuthor",
      "me",
      core.otherAuthor({ id: "u1", name: "Sam" }, "u2")?.name,
      port.otherAuthor({ id: "u1", name: "Sam" }, "u2") ? "Sam" : undefined,
    );
    check(
      "otherAuthor-self",
      "self",
      core.otherAuthor({ id: "u1", name: "Sam" }, "u1")?.name,
      port.otherAuthor({ id: "u1", name: "Sam" }, "u1") ? "Sam" : undefined,
    );

    // sanitizeMarkdownUrl (chat-ui markdown). Its package entries do not re-export it, so the
    // expectations are written from its rule: http, https, mailto and tel open, every other
    // scheme stays unlinked, and a bare or relative address opens only when relative ones may.
    for (const [url, allowed, allowedRelative] of [
      ["https://x.com/a", "https://x.com/a", "https://x.com/a"],
      ["http://x.com", "http://x.com", "http://x.com"],
      ["ftp://x.com", undefined, undefined],
      ["javascript:alert(1)", undefined, undefined],
      ["data:text/plain,hi", undefined, undefined],
      ["mailto:a@b.c", "mailto:a@b.c", "mailto:a@b.c"],
      ["tel:+1-555-0100", "tel:+1-555-0100", "tel:+1-555-0100"],
      ["HTTPS://X.COM", "HTTPS://X.COM", "HTTPS://X.COM"],
      ["x.com", undefined, undefined],
      ["  https://x.com  ", "https://x.com", "https://x.com"],
      ["//x.com", undefined, "//x.com"],
      ["/docs", undefined, "/docs"],
      ["./rel", undefined, "./rel"],
      ["../up", undefined, "../up"],
      ["#frag", undefined, "#frag"],
      ["", undefined, undefined],
    ] as const) {
      check("sanitizeMarkdownUrl", url, allowed, port.sanitizeMarkdownUrl(url));
      check("sanitizeMarkdownUrl-rel", url, allowedRelative, port.sanitizeMarkdownUrl(url, true));
    }

    const PLAIN_TEXTS = [
      "see https://x.com/a now",
      "a b@c.com d",
      "setup.py notes.md stay",
      "[page](page:p1) then",
      "a (https://x.com/b) c",
      "https://x.com/a, b",
      "visit https://x.com/a.",
      "no links",
      "(https://x.com/a)",
      "https://x.com/a(b)c",
      "see https://x.com/a，then",
      "mixed https://x.com/你好 world",
      "[docs](https://x.com/a) tail",
      "http://x.com:8080/p?q=1#f",
      "a https://x.com/x_(y) b",
      "www.x.com stays",
      "a@b",
      "x@y.co.uk",
      "https://",
      "https://x.com/a)",
      // Where the port used to draw the line differently from the reference.
      "alice@example.com.",
      "[https://example.com](https://example.com)",
    ];
    for (const text of PLAIN_TEXTS) {
      check(
        "plainTextLinkParts",
        text,
        partShape(realLinkParts(text)),
        partShape(port.plainTextLinkParts(text)),
      );
    }

    // plainTextFromMarkdown (the reply-line preview path). markdown-lite.markdownPlainText is the
    // accessibility-label walk (block separators, no table joins): a different contract, checked in
    // ThreadRender, not here.
    const MD_TEXTS = [
      "# Title\n\n- **bold** item\n- `code` item\n\n```\nlet x = 1;\n```\n\n> quote",
      "a *b* **c** ***d*** _e_ __f__ ~~g~~ [l](https://x.com) <https://x.com> &amp; &#65;",
      "2 * y * 3 and 2 ** 3 ** 4",
      "| a | b |\n|---|---|\n| 1 | 2 |",
      "中文 **加粗** 列表",
      "line one\nline two\n\nline three",
      "text with &notanentity; and &amp;",
      "> [!NOTE]\n> body",
      "![alt](https://x.com/i.png)",
      "```\ncode\n```",
      "    indented",
      "<b>bold</b>",
      "a\\*b",
      "§1 © très",
      "1. one\n2. two",
      "- [ ] todo\n- [x] done",
      "---",
      "# a #",
      "term\n---\n",
    ];
    for (const md of MD_TEXTS) {
      check(
        "plainTextFromMarkdown",
        md.slice(0, 40),
        core.plainTextFromMarkdown(md),
        port.plainTextFromMarkdown(md),
      );
    }

    // selectableTextFromMarkdown (mobile): line by line over the preview conversion.
    for (const md of MD_TEXTS.concat([
      "- item\n\n      code indented",
      "para\n\n    code\n    more\n\npara2",
    ])) {
      check(
        "selectableTextFromMarkdown",
        md.slice(0, 40),
        mobileSelectable.selectableTextFromMarkdown(md),
        port.selectableTextFromMarkdown(md),
      );
    }

    // messageMenu: what it offers and what it copies, against what mobile builds the same menu
    // from (message-row.tsx). The code cases keep their indentation: a tab a Makefile needs.
    const MENU_CASES = [
      { id: "m1", role: "user", blocks: [{ kind: "text", text: "hello" }] },
      { id: "m2", role: "bot", blocks: [{ kind: "text", text: "```js\nconst a = 1;\n```" }] },
      { id: "m3", role: "bot", blocks: [{ kind: "chart" }] },
      { id: "progress:x", role: "bot", blocks: [{ kind: "progress", text: "thinking" }] },
      {
        id: "m4",
        role: "bot",
        blocks: [{ kind: "text", text: "```make\nbuild:\n\techo hi\n```" }],
      },
      {
        id: "m5",
        role: "bot",
        blocks: [{ kind: "text", text: "- item\n\n  ```\n  \techo\n  ```" }],
      },
      { id: "m6", role: "bot", blocks: [{ kind: "text", text: "```\n\ta\n```\n\n```\n\tb\n```" }] },
      { id: "m7", role: "bot", blocks: [{ kind: "text", text: "```js\n\n\n```" }] },
      { id: "user-code", role: "user", blocks: [{ kind: "text", text: "```\n\tx\n```" }] },
    ];
    for (const message of MENU_CASES) {
      const text = blockText(message);
      const messageText = core.selectableMessageText(message);
      const codeBlocks = message.role === "user" ? [] : realCodeBlocks(text);
      check(
        "messageMenu",
        message.id,
        {
          select: messageText.trim().length > 0,
          copyCode: codeBlocks.length === 1,
          copyText: core.copyableMessageText(message),
          selectText:
            message.role === "user"
              ? messageText
              : mobileSelectable.selectableTextFromMarkdown(messageText),
          code: codeBlocks[0] ?? "",
        },
        port.messageMenu(message),
      );
    }
    // The code copied, over the shapes a code block takes. Mobile reads it with a second parser
    // (markdown-it), which keeps the tabs the renderer expands, so the port reads it as that does.
    const CODE_CASES = [
      "```make\nbuild:\n\techo hi\n\tcd /tmp\n```",
      "```\n\tindented\n```",
      "```\n\t\tdeep\n```",
      "```\n  \tx\n```",
      " ```\n\techo\n ```",
      "  ```\n\techo\n  ```",
      "   ```\n\techo\n   ```",
      "```\na\tb\n```",
      "```\nab\t\n```",
      "    a\n\tb",
      "\tcode line",
      "\t\tcode",
      "- item\n\n  ```\n  \techo\n  ```",
      "> ```\n> \techo\n> ```",
      "~~~\n\techo\n~~~",
      "```\n\techo",
      "```\n\ta\n```\n\ntext\n\n```\n\tb\n```",
      "```js\tx\n\techo\n```",
      "```\n\t\n\tx\n```",
      "```\r\n\techo\r\n```",
      "- ```\n  \tx\n  ```",
      "```\n    space then\n\ttab\n```",
      // A list item whose own line is the code, blank lines inside indented code, and a quote
      // around a list.
      "-     code",
      "-     \tcode",
      "1.      code",
      "    a\n\t\n    b",
      "    a\n\t\t\n    b",
      "> - ```\n>   \tx\n>   ```",
      "- > ```\n  > \tx\n  > ```",
      // A tab right after the quote mark: the parser takes a column of it for the mark, the
      // copy rule leaves the tab in the line, so the tab is copied whole.
      "> ```\n>\t\tx\n> ```",
      "> ```\n>\tx\n> ```",
      "> ```\n> \tx\n> ```",
      "> ```\n>\t \tx\n> ```",
      "> ```\n>\t\t\ty\n> ```",
      "> > ```\n> >\t\tx\n> > ```",
    ];
    // Inside a quote whose fence line is itself indented (`>  ``` or a tab after the mark) the
    // copied indentation can differ from mobile's by the columns the two parsers give the quote
    // mark; m5-notes records it. These pin what this port does, so a change is seen.
    for (const [markdown, expected] of [
      [">  ```\n>\t\tx\n>  ```", ["\t\tx"]],
      [">\t```\n>\t\tx\n>\t```", ["\t\tx"]],
      [">  ```\n>  x\n>  ```", [" x"]],
    ] as const) {
      check(
        "markdownCodeBlocksInsideAnIndentedQuote",
        markdown,
        [...expected],
        port.markdownCodeBlocks(markdown),
      );
    }
    for (const markdown of CODE_CASES) {
      check(
        "markdownCodeBlocks",
        markdown,
        realCodeBlocks(markdown),
        port.markdownCodeBlocks(markdown),
      );
      // The same value read off the tree, where the copy button on the block itself takes it.
      check(
        "codeBlocksAsTheTreeCarriesThem",
        markdown,
        realCodeBlocks(markdown),
        codeBlocksOfTree(markdown),
      );
    }

    // The flat run list the bubble draws (Span takes no children, so nested emphasis flattens):
    // every run keeps the styles of all its enclosing nodes, and neighbours with the same styles
    // merge. Checked against the parser's own tree, which the fixture already pins.
    const runs = await import(pathToFileURL(path.join(outDir, "markdown-runs.ts")).href);
    /** [text, bold, italic, strike, code, href] as the bubble draws it. */
    type Shape = [string, number, number, number, number, string];
    const runCases: [string, Shape[]][] = [
      ["plain words", [["plain words", 0, 0, 0, 0, ""]]],
      [
        "a **b** and *c*",
        [
          ["a ", 0, 0, 0, 0, ""],
          ["b", 1, 0, 0, 0, ""],
          [" and ", 0, 0, 0, 0, ""],
          ["c", 0, 1, 0, 0, ""],
        ],
      ],
      [
        "**bold *both* end**",
        [
          ["bold ", 1, 0, 0, 0, ""],
          ["both", 1, 1, 0, 0, ""],
          [" end", 1, 0, 0, 0, ""],
        ],
      ],
      [
        "~~gone~~ and `code`",
        [
          ["gone", 0, 0, 1, 0, ""],
          [" and ", 0, 0, 0, 0, ""],
          ["code", 0, 0, 0, 1, ""],
        ],
      ],
      [
        "see [site](https://x.com) now",
        [
          ["see ", 0, 0, 0, 0, ""],
          ["site", 0, 0, 0, 0, "https://x.com"],
          [" now", 0, 0, 0, 0, ""],
        ],
      ],
      // A soft break reads as a space, as mobile shows it; two trailing spaces or a backslash
      // make a hard one. Either merges with the plain text around it.
      ["line one\nline two", [["line one line two", 0, 0, 0, 0, ""]]],
      ["line one  \nline two", [["line one\nline two", 0, 0, 0, 0, ""]]],
      ["line one\\\nline two", [["line one\nline two", 0, 0, 0, 0, ""]]],
      // No image surface yet: the alternative text stands in.
      ["![alt text](https://x.com/i.png)", [["alt text", 0, 0, 0, 0, ""]]],
      ["**[link](https://x.com)**", [["link", 1, 0, 0, 0, "https://x.com"]]],
      // A destination the app cannot follow is plain text: a page link, a bot link, a scheme it
      // refuses, and a relative one. The words stay, with nothing to tap.
      ["[Home](page:p1)", [["Home", 0, 0, 0, 0, ""]]],
      ["[Bot](rakazo-mention:b1)", [["Bot", 0, 0, 0, 0, ""]]],
      ["[x](javascript:alert(1))", [["x", 0, 0, 0, 0, ""]]],
      ["[x](/docs)", [["x", 0, 0, 0, 0, ""]]],
      [
        "**[Home](page:p1)** and [mail](mailto:a@b.co)",
        [
          ["Home", 1, 0, 0, 0, ""],
          [" and ", 0, 0, 0, 0, ""],
          ["mail", 0, 0, 0, 0, "mailto:a@b.co"],
        ],
      ],
    ];
    for (const [markdown, expected] of runCases) {
      const tree = portLite.parseMarkdown(markdown);
      const shape: Shape[] = runs
        .inlineRuns(tree.children[0])
        .map(
          (run: {
            text: string;
            bold: boolean;
            italic: boolean;
            strike: boolean;
            code: boolean;
            href: string;
          }): Shape => [
            run.text,
            Number(run.bold),
            Number(run.italic),
            Number(run.strike),
            Number(run.code),
            run.href,
          ],
        );
      check("inlineRuns", markdown, expected, shape);
    }

    expect(checked, "corpus ran").toBeGreaterThan(150);
    expect(
      failures,
      failures
        .slice(0, 8)
        .map(
          (f) =>
            `${f.name} ${JSON.stringify(f.input)}\n  exp ${JSON.stringify(f.expected)}\n  got ${JSON.stringify(f.actual)}`,
        )
        .join("\n"),
    ).toEqual([]);
  });

  it("agrees with the reference on where a link starts and ends in text built from its edge characters", () => {
    // Where a link starts and ends is decided by single characters (a dot, a bracket, a blank,
    // a full-width mark) and by the letter case of its scheme, so the corpus is short strings
    // drawn from those. The generator is seeded, so a disagreement replays.
    const ALPHABET = [
      "a",
      "b",
      "A",
      "Z",
      "1",
      "9",
      "_",
      "-",
      ".",
      ",",
      ":",
      ";",
      "/",
      "\\",
      "?",
      "!",
      "@",
      "#",
      "%",
      "(",
      ")",
      "[",
      "]",
      "{",
      "}",
      "<",
      ">",
      '"',
      "'",
      " ",
      "\t",
      "\n",
      "\r",
      "\u0000",
      "\u001f",
      "\u00a0",
      "\u3000",
      "\u00ad",
      "\u200b",
      "\ufeff",
      "，",
      "。",
      "、",
      "｜",
      "é",
      "ß",
      "中",
      "\u{1f600}",
      "x.com",
      "a@b.co",
      "https://",
      "HTTPS://",
      "http:",
      "mailto:",
      "MailTo:",
      "ftp:",
      "//",
      "www.",
      "com",
      "uk",
      "zz",
      "dev",
      "cn",
      "io",
      "xn--p1ai",
      "museum",
      "localhost",
      "192.168.0.1",
      "255.255.255.255",
      "999.1.1.1",
      "user:pass@",
      ":8080",
      "?q=1",
      "#f",
      "/path",
      "(x)",
      "[x]",
      '"q"',
      "'q'",
      "e.g",
      "a..b",
      "a--b",
      "-a",
      "a-",
      "..",
      "...",
    ];
    let seed = 0x5eed;
    const next = (bound: number): number => {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      return seed % bound;
    };
    const disagreements: unknown[] = [];
    for (let round = 0; round < 8_000; round += 1) {
      let text = "";
      const length = 1 + next(24);
      for (let piece = 0; piece < length; piece += 1) {
        text += ALPHABET[next(ALPHABET.length)];
      }
      const expected = partShape(realLinkParts(text));
      const got = partShape(port.plainTextLinkParts(text));
      if (JSON.stringify(expected) !== JSON.stringify(got) && disagreements.length < 6) {
        disagreements.push({ text, expected, got });
      }
    }
    expect(disagreements).toEqual([]);
  });

  it("finds the links of a long message in time that grows with its length", () => {
    // Sized so that a scan that restarts at every letter takes minutes: a send may hold 100,000.
    // Plain text has no address anywhere, and one that looks like the start of one at every step.
    // The wall of repeated addresses is one address to the linkifier (the first swallows the
    // rest), and the unclosed parenthesis makes every candidate's check walk the whole run: both
    // were quadratic before the tail was read through a window and covered candidates were
    // skipped.
    for (const text of [
      "a".repeat(100_000),
      "no links here ".repeat(7_700),
      "a@".repeat(50_000),
      "https:// ".repeat(12_500),
      "https://a.b/c ".repeat(7_100),
      "https://x.com/".repeat(12_500),
      `https://x.com/${"(".repeat(60)}a`.concat("https://x.com/".repeat(12_000)),
    ]) {
      expectLinearTime(() => port.plainTextLinkParts(text));
    }
  });
});
