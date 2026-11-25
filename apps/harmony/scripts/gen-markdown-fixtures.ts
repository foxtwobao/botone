// Layer-2 markdown fixtures (M5): the mobile app draws bot Markdown with a native GitHub-flavored
// parser (md4c). The same parser ships as WebAssembly inside that dependency, so the expected
// trees here come from the real renderer's parser rather than from a re-implementation, and the
// ArkTS port (thread/markdown-*.ets) must produce the same tree for the same text.
//
// Flags are the configuration the port implements: GitHub flavor (tables, task lists,
// strikethrough), admonitions, permissive autolinks, inline HTML left as text, spoilers on; the
// others off. Math is the one place this differs from the mobile call site: chat-ui passes no
// parser flags, so the component's default applies and mobile resolves `$…$` as a math span (this
// app's mobile build ships no math renderer). HarmonyOS has none either and leaves `$` as text, so
// a document with math is not a fixture case.

import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { randomDocuments } from "./markdown-fixture-corpus.ts";

type ParseFn = (
  markdown: string,
  underline: number,
  latexMath: number,
  superscript: number,
  subscript: number,
  highlight: number,
  hardSoftBreaks: number,
  preserveBlankLines: number,
  admonitions: number,
  permissiveAutolinks: number,
) => string;

const require = createRequire(import.meta.url);
const bundle = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../mobile/node_modules/react-native-enriched-markdown/src/web/wasm/md4c.js",
);

let loading: Promise<ParseFn> | null = null;

/** The reference parser, loaded once per process. */
export function md4c(): Promise<ParseFn> {
  if (!loading) {
    loading = (require(bundle) as () => Promise<{ cwrap: (...args: unknown[]) => unknown }>)()
      .then((module) =>
        module.cwrap("parseMarkdown", "string", ["string", ...Array(9).fill("number")]),
      )
      .then((parse) => parse as ParseFn)
      .catch((error: unknown) => {
        loading = null;
        throw error;
      });
  }
  return loading;
}

export interface AstNode {
  type: string;
  content?: string;
  attributes?: Record<string, string | undefined>;
  children?: AstNode[];
}

/** One document parsed exactly as the mobile bubble parses it. */
export async function parseReference(markdown: string): Promise<AstNode> {
  const parse = await md4c();
  return JSON.parse(parse(markdown, 0, 0, 0, 0, 0, 0, 0, 1, 1)) as AstNode;
}

/** The port's node. Fields always exist on the port (defaults when absent), and the fixture writes
 * only the non-default ones, in this order, so a tree compares as one plain JSON string on both
 * sides (compactNode below and mdCompact in markdown-lite.ets are the same rule). */
export interface MdNode {
  type: string;
  text: string;
  href: string;
  title: string;
  level: number;
  lang: string;
  fence: string;
  start: number;
  tight: boolean;
  /** "" for a plain item; the task mark (" ", "x" or "X") for a task item. */
  task: string;
  /** An admonition's type (note, tip, …) or a table cell's alignment. */
  kind: string;
  cols: number;
  heads: number;
  bodies: number;
  children: MdNode[];
}

export function emptyNode(type: string): MdNode {
  return {
    type,
    text: "",
    href: "",
    title: "",
    level: 0,
    lang: "",
    fence: "",
    start: 1,
    tight: false,
    task: "",
    kind: "",
    cols: 0,
    heads: 0,
    bodies: 0,
    children: [],
  };
}

const leafText = (node: AstNode): string =>
  (node.children ?? []).map((child) => child.content ?? "").join("");

/** The reference tree in the port's shape: a renaming, with no rendering decisions. */
export function projectTree(node: AstNode): MdNode | null {
  const attributes = node.attributes ?? {};
  const out = emptyNode(node.type);
  switch (node.type) {
    case "Document":
      out.type = "doc";
      break;
    case "Paragraph":
      out.type = "p";
      out.tight = attributes.tight === "true";
      break;
    case "Text":
    case "Code":
    case "CodeBlock":
      out.type = node.type === "Text" ? "text" : node.type === "Code" ? "code" : "codeblock";
      out.text = node.type === "Text" ? (node.content ?? "") : leafText(node);
      out.lang = attributes.language ?? "";
      out.fence = attributes.fenceChar ?? "";
      break;
    case "Link":
      out.type = "a";
      break;
    case "Image":
      out.type = "img";
      break;
    case "Heading":
      out.type = "h";
      out.level = Number(attributes.level ?? "1");
      break;
    case "LineBreak":
      out.type = "br";
      break;
    case "SoftBreak":
      out.type = "softbr";
      break;
    case "Strong":
      out.type = "strong";
      break;
    case "Emphasis":
      out.type = "em";
      break;
    case "Strikethrough":
      out.type = "del";
      break;
    case "Spoiler":
      out.type = "spoiler";
      break;
    case "Blockquote":
      out.type = "quote";
      break;
    case "Admonition":
      out.type = "admonition";
      out.kind = attributes.admonitionType ?? "";
      break;
    case "UnorderedList":
      out.type = "ul";
      break;
    case "OrderedList":
      out.type = "ol";
      out.start = Number(attributes.start ?? "1");
      break;
    case "ListItem":
      out.type = "li";
      out.task =
        attributes.isTask === "true" ? (attributes.taskChecked === "true" ? "x" : " ") : "";
      break;
    case "ThematicBreak":
      out.type = "hr";
      break;
    case "Table":
      out.type = "table";
      out.cols = Number(attributes.colCount ?? "0");
      out.heads = Number(attributes.headRowCount ?? "0");
      out.bodies = Number(attributes.bodyRowCount ?? "0");
      break;
    case "TableHead":
      out.type = "thead";
      break;
    case "TableBody":
      out.type = "tbody";
      break;
    case "TableRow":
      out.type = "tr";
      break;
    case "TableHeaderCell":
      out.type = "th";
      out.kind = attributes.align ?? "default";
      break;
    case "TableCell":
      out.type = "td";
      out.kind = attributes.align ?? "default";
      break;
    case "Video":
      out.type = "video";
      break;
    default:
      // A node type the port does not know keeps its words rather than vanishing.
      out.type = "text";
      out.text = node.content ?? "";
      return out;
  }
  out.href = attributes.url ?? "";
  out.title = attributes.title ?? "";
  out.children = (node.children ?? [])
    .map(projectTree)
    .filter((child): child is MdNode => child !== null);
  return out;
}

export interface MarkdownCase {
  name: string;
  markdown: string;
  tree: ReturnType<typeof compactNode>;
}

/** The fixture's form of a node: the type, then only what is not the default. */
export function compactNode(node: MdNode): Record<string, unknown> {
  const out: Record<string, unknown> = { type: node.type };
  const text = (key: string, value: string): void => {
    if (value !== "") out[key] = value;
  };
  text("text", node.text);
  text("href", node.href);
  text("title", node.title);
  if (node.level !== 0) out.level = node.level;
  text("lang", node.lang);
  text("fence", node.fence);
  if (node.start !== 1) out.start = node.start;
  if (node.tight) out.tight = true;
  text("task", node.task);
  text("kind", node.kind);
  if (node.cols !== 0) out.cols = node.cols;
  if (node.heads !== 0) out.heads = node.heads;
  if (node.bodies !== 0) out.bodies = node.bodies;
  if (node.children.length > 0) out.children = node.children.map(compactNode);
  return out;
}

export const MARKDOWN_CORPUS: { name: string; markdown: string }[] = [
  { name: "empty", markdown: "" },
  { name: "only whitespace", markdown: "   \n  \n\t\n" },
  { name: "plain paragraph", markdown: "Hello, world." },
  { name: "two paragraphs", markdown: "First one.\n\nSecond one." },
  { name: "soft break joins lines in one paragraph", markdown: "Line one\nline two\n\nLine three" },
  { name: "hard break with two trailing spaces", markdown: "Line  \nbreak" },
  { name: "hard break with backslash", markdown: "line\\\nbreak" },
  { name: "backslash at the end of a paragraph", markdown: "line\\" },
  { name: "crlf line endings", markdown: "one\r\n\r\ntwo\r\n" },
  { name: "cr line endings", markdown: "one\r\r\ntwo\r" },
  { name: "multiple spaces kept in text", markdown: "a  b   c" },
  { name: "tab kept inside text", markdown: "a\tb" },
  { name: "trailing spaces trimmed", markdown: "word   \nnext   " },
  { name: "non-breaking space is not a break", markdown: "a\u00a0b c" },

  {
    name: "atx heading levels",
    markdown: "# H1\n\n## H2\n\n### H3\n\n#### H4\n\n##### H5\n\n###### H6",
  },
  { name: "seven hashes is text", markdown: "####### H7" },
  { name: "heading needs a space", markdown: "#NoSpaceHeading" },
  { name: "closing hashes dropped", markdown: "# h1 #\n\n## h2 ##   \n" },
  { name: "empty headings", markdown: "#\n\n#\n\n## " },
  { name: "closing hashes need a space before", markdown: "# h1###" },
  { name: "heading with inline markup", markdown: "## **bold** and `code` and [l](https://x.com)" },
  { name: "heading interrupts a paragraph", markdown: "para\n# heading" },
  { name: "indented heading up to three spaces", markdown: "   # indented" },
  { name: "four-space indent is code, not a heading", markdown: "para\n\n    # not a heading" },
  { name: "setext level one", markdown: "Setext\n======\n\npara" },
  { name: "setext level two", markdown: "Title\n---\n\npara" },
  { name: "setext with trailing spaces", markdown: "Title\n===   \n\npara" },
  { name: "setext only after a paragraph", markdown: "---\n\nnot setext" },
  { name: "setext after a list item is a thematic break", markdown: "- list\n---" },
  { name: "setext multi-line paragraph", markdown: "Line one\nline two\n---" },
  { name: "underline with other text is a paragraph", markdown: "Title\n--- text" },
  { name: "heading inside a quote", markdown: "> # quoted head" },

  { name: "thematic break variants", markdown: "***\n\n---\n\n___ \n\n* * *\n\n- - -" },
  { name: "thematic break ends a paragraph", markdown: "a\n***\nb" },
  { name: "two marks is not a break", markdown: "a\n--\nb" },
  { name: "break with other text is not a break", markdown: "-- x" },
  { name: "mixed marks is not a break", markdown: "*-_" },

  { name: "bullet markers", markdown: "- dash\n\n* star\n\n+ plus" },
  { name: "ordered with dot and paren", markdown: "1. one\n\n2) two" },
  { name: "ordered list keeps its start", markdown: "5. five\n6. six" },
  { name: "ordered start with leading zeros", markdown: "007. seven" },
  { name: "ten digits is not a list", markdown: "1234567890. no" },
  { name: "different bullet starts a new list", markdown: "- a\n\n* b\n\n+ c" },
  { name: "same bullet continues one list", markdown: "- a\n- b\n- c" },
  { name: "tight list", markdown: "- a\n- b\n- c" },
  { name: "blank lines loosen a list", markdown: "- a\n\n- b\n\n- c" },
  { name: "two-line items stay tight", markdown: "- item\n  continued\n- item 2\n  continued" },
  { name: "lazy continuation line", markdown: "- item\nlazy continuation\n- item 2" },
  { name: "second paragraph loosens only its list", markdown: "- item\n\n  second para\n- next" },
  { name: "paragraph after a list", markdown: "- item\n\nplain para" },
  { name: "list interrupts a paragraph", markdown: "para\n- item" },
  { name: "ordered list starting at one interrupts a paragraph", markdown: "para\n1. item" },
  { name: "ordered list not starting at one cannot interrupt", markdown: "para\n2. item" },
  { name: "empty list item", markdown: "- a\n-\n- b" },
  { name: "marker alone", markdown: "-" },
  { name: "marker then blank line cannot interrupt", markdown: "para\n-\nafter" },
  {
    name: "nested lists",
    markdown: "- a\n  - b\n    - c\n      paragraph\n\n\n- after blank lines",
  },
  { name: "nested ordered in unordered", markdown: "1. one\n   1. inner\n2. two" },
  { name: "deep nesting with paragraph", markdown: "- a\n  - b\n    - c\n      para\n\n- next" },
  { name: "five spaces after marker leave one for code", markdown: "-     code\n-      more" },
  { name: "one to four spaces after marker are content", markdown: "-     code" },
  { name: "four-space indent continues the item", markdown: "- item\n\n    continuation para" },
  { name: "code block in a list item", markdown: "- item\n\n      indented code\n" },
  { name: "fence inside a list item", markdown: "- item\n\n  ```\n  code\n  ```\n" },
  { name: "list inside a quote", markdown: "> - list in quote\n>   - deeper" },
  { name: "quote inside a list item", markdown: "- item\n\n  > quoted" },
  { name: "list item with a heading", markdown: "- item\n\n  # head in list" },
  { name: "two blank lines end a list item", markdown: "- a\n\n\n  not in the list" },
  { name: "tab after marker", markdown: "-\tfoo\n\n-\t\tbar" },
  { name: "tab-indented list continuation", markdown: "-\tfoo\n\n\tbar" },
  { name: "task list", markdown: "- [ ] todo\n- [x] done\n- [X] done too\n- [y] not a task" },
  { name: "task marker needs a space after", markdown: "- [ ]todo" },
  { name: "task list ordered", markdown: "1. [ ] a\n2. [x] b" },
  { name: "task item with nested list", markdown: "- [x] done\n  - nested" },
  { name: "indented code", markdown: "para\n\n    code\n    more\n\npara2" },
  { name: "indented code keeps extra indent", markdown: "      code after 6\n    back to 4" },
  { name: "tab-indented code", markdown: "\tcode by tab" },
  { name: "blank lines inside indented code", markdown: "    a\n\n    b" },
  { name: "indented code after a list", markdown: "- item\n\n      code indented in list" },
  { name: "indented code cannot interrupt a paragraph", markdown: "para\n    continued" },
  { name: "fenced code with language", markdown: "```js\nconst a = 1;\n```" },
  { name: "fenced code without language", markdown: "```\nplain\n```" },
  { name: "tilde fence", markdown: "~~~py\nprint(1)\n~~~" },
  { name: "longer fence wraps shorter ones", markdown: "````\n```\nnested\n````" },
  { name: "tilde fence does not close on backticks", markdown: "~~~~ py\n~~~\n``` \n" },
  { name: "unclosed fence runs to the end", markdown: "```js\nlet x = 1;\n(no close)" },
  { name: "empty fence", markdown: "```\n\n```" },
  { name: "fence with attributes after language", markdown: '```js title="x" {1,2}\ncode\n```' },
  { name: "fence language with symbols", markdown: "```c++\nx\n```" },
  { name: "backtick fence info cannot hold a backtick", markdown: "``` a`b ```" },
  { name: "indented fence", markdown: "   ```\n   indented fence\n   ```" },
  { name: "fence in a quote", markdown: "> ```\n> code in quote\n> ```" },
  { name: "closing fence with trailing text does not close", markdown: "```\ncode\n``` x\n```" },
  { name: "closing fence with leading indent", markdown: "```\ncode\n   ```\n" },
  { name: "blank lines inside a fence", markdown: "```\na\n\n\nb\n```" },
  { name: "fence interrupts a paragraph", markdown: "para\n```\ncode\n```" },
  { name: "code keeps markdown literal", markdown: "```\n# not a heading\n*not em*\n```" },

  { name: "quote", markdown: "> quoted\n> more\n\n>second" },
  { name: "quote without space", markdown: ">no space" },
  { name: "nested quote", markdown: "> > deep\n\n> outer\n> > inner" },
  { name: "lazy continuation in a quote", markdown: "> quote\nlazy line" },
  { name: "lazy continuation ends at a blank line", markdown: "> a\n> b\nlazy\n\nnot" },
  { name: "quote with two paragraphs", markdown: "> first\n>\n> second" },
  { name: "quote ends and paragraph follows", markdown: "> quote\n\npara" },
  { name: "quote with list and code", markdown: "> - item\n>\n> ```\n> code\n> ```" },
  { name: "empty quote line", markdown: ">\n> text" },
  { name: "admonition note", markdown: "> [!NOTE]\n> Useful info." },
  { name: "admonition warning with markup", markdown: "> [!WARNING]\n> careful **text**\n> more" },
  {
    name: "admonition types",
    markdown: "> [!TIP]\n> t\n\n> [!IMPORTANT]\n> i\n\n> [!CAUTION]\n> c",
  },
  { name: "admonition tag is case-insensitive", markdown: "> [!Note]\n> body" },
  { name: "admonition with a following list", markdown: "> [!NOTE]\n> - a\n> - b" },
  { name: "brackets that are not an admonition", markdown: "> [not an admonition]\n> text" },
  { name: "admonition tag must be alone on its first line", markdown: "> [!NOTE] more\n> body" },
  { name: "admonition tag on the second line is text", markdown: "> body\n> [!NOTE]" },
  { name: "unknown admonition type is text", markdown: "> [!BOGUS]\n> body" },
  { name: "admonition in a list", markdown: "- item\n\n  > [!TIP]\n  > body" },

  { name: "inline emphasis", markdown: "**bold** *em* __bold2__ _em2_ ***both***" },
  { name: "strikethrough", markdown: "~~gone~~" },
  { name: "single tilde is not strikethrough", markdown: "~kept~" },
  { name: "three tildes are text", markdown: "~~~a~~~" },
  { name: "emphasis needs a non-space neighbour", markdown: "a * b ** c" },
  { name: "unclosed emphasis stays", markdown: "never *closed" },
  { name: "intraword underscore is literal", markdown: "snake_case_word 2_3_4" },
  { name: "intraword asterisk emphasizes", markdown: "2*3*4 a*b c*d" },
  { name: "emphasis around punctuation", markdown: '*(a)* **(b)** "*c*" *("d")* a*,* *\'e\'*' },
  {
    name: "emphasis opener and closer runs",
    markdown: "*foo**bar**baz* and ***foo** bar* and *foo **bar***",
  },
  { name: "unclosed mixed emphasis", markdown: "*a **b* c** and _a *b_ c*" },
  { name: "rule of three", markdown: "*a**b* and **a*b** and ***a*b*" },
  { name: "many asterisks", markdown: "*****" },
  { name: "emphasis spanning a soft break", markdown: "*foo\nbar*" },
  { name: "emphasis cannot span a blank line", markdown: "*foo\n\nbar*" },
  {
    name: "emphasis inside a link label",
    markdown: "*[link](https://x.com)* and [*em*](https://x.com)",
  },
  { name: "emphasis with unicode punctuation", markdown: "中文**加粗**中文 「*引*」" },
  { name: "emphasis next to an emoji", markdown: "🙂**bold**🙂" },
  { name: "strikethrough needs flanks", markdown: "a ~~ b ~~ c" },
  { name: "inline code", markdown: "a `code` b ``with ` tick`` c" },
  { name: "code span edge cases", markdown: "` ` and `` ` `` and `a``b` and ```a```" },
  { name: "code span strips one surrounding space", markdown: "`  x  ` and ` `" },
  { name: "code span across lines", markdown: "`a\nb`" },
  { name: "unclosed backtick", markdown: "a ` b" },
  { name: "code span keeps markup literal", markdown: "`**not bold** <i>&amp;</i>`" },
  { name: "very long backtick run is text", markdown: "`".repeat(40) },
  { name: "inline link", markdown: "[label](https://x.com/a)" },
  { name: "inline link with title", markdown: '[t](https://x.com/a "title")' },
  { name: "link destination in angle brackets", markdown: "[a](<https://x.com/a b>)" },
  { name: "link destination with spaces around", markdown: "[a](  https://x.com/a  )" },
  {
    name: "link with balanced parentheses",
    markdown: "[wiki](https://en.wikipedia.org/wiki/A_(b))",
  },
  { name: "link with empty destination", markdown: "[a]()" },
  { name: "link with title only is not a link", markdown: '[a]("title")' },
  { name: "link across lines", markdown: '[a](\nhttps://x.com\n"t"\n)' },
  { name: "unclosed link", markdown: "[unclosed(https://x.com" },
  { name: "link whose closer sits in a code span", markdown: "[a `b`](c) and [`c`](d`)" },
  { name: "nested brackets in a label", markdown: "[a [b] c](https://x.com)" },
  { name: "link inside image label", markdown: "![*[alt]*(https://x.com/i.png)" },
  { name: "image", markdown: "![alt text](https://x.com/i.png)" },
  { name: "image with title", markdown: '![alt](https://x.com/i.png "title")' },
  { name: "image with an empty label", markdown: "![](https://x.com/i.png)" },
  { name: "bang outside brackets is text", markdown: "! [a](https://x.com)" },
  {
    name: "links with other schemes stay links",
    markdown: "[weird](javascript:alert(1)) [ftp](ftp://x.com) [rel](/path) [page](page:abc_1)",
  },
  { name: "autolink in angle brackets", markdown: "<https://angle.example>" },
  { name: "email autolink", markdown: "<x@y.zz>" },
  { name: "angle brackets that are not autolinks", markdown: "<not a link> <a b> <http://x y>" },
  { name: "bare url autolink", markdown: "Text with https://example.com link" },
  { name: "bare www autolink", markdown: "www.example.com and example.com" },
  {
    name: "autolink with balanced parentheses",
    markdown: "(see https://en.wikipedia.org/wiki/A_(b)) and https://x.com/a)",
  },
  {
    name: "autolink drops trailing punctuation",
    markdown: "visit https://example.com. then https://example.com, ok?",
  },
  { name: "autolink with path, query and fragment", markdown: "https://x.com/a/b?c=d&e=f#g" },
  { name: "autolink inside emphasis", markdown: "*https://x.com*" },
  { name: "email autolinks", markdown: "a@b, mailto:x@y.zz, <x@y.zz>, x+y@sub.example.co.uk" },
  { name: "email needs neighbours", markdown: "contact bob@example.com now" },
  { name: "ftp url", markdown: "ftp://files.example.org/x" },
  { name: "autolink next to brackets", markdown: "[https://x.com] and (https://x.com)" },
  {
    name: "autolink that is the whole label is not doubled",
    markdown: "[https://x.com](https://x.com)",
  },
  { name: "url in a code span is not linked", markdown: "`https://x.com`" },

  {
    name: "link reference full form",
    markdown: '[ref][id] and [x][ID]\n\n[id]: https://x.com/a "t"',
  },
  {
    name: "link reference collapsed and shortcut",
    markdown: "[ref][] and [ref]\n\n[ref]: https://x.com/a",
  },
  { name: "link reference is case-insensitive", markdown: "[REF][]\n\n[ref]: https://x.com/a" },
  {
    name: "first definition wins",
    markdown: "[a][]\n\n[a]: https://first.example\n[a]: https://second.example",
  },
  { name: "image reference", markdown: "![ref][id]\n\n[id]: https://x.com/i.png" },
  { name: "definition alone renders nothing", markdown: "[id]: https://x.com/a\n\ntext" },
  {
    name: "definitions at the top of a paragraph are eaten",
    markdown: "[a]: https://x.com/1\n[b]: https://x.com/2\nVisible text",
  },
  { name: "definition in the middle of a paragraph stays", markdown: "text\n[a]: https://x.com/1" },
  { name: "definition spanning lines", markdown: '[a]:\nhttps://x.com/1\n  "title"\n\ntext' },
  {
    name: "definition with text after it is not a definition",
    markdown: "[a]: https://x.com/1 extra\n\ntext",
  },
  {
    name: "definition then setext underline becomes a break",
    markdown: "[a]: https://x.com/1\n---\n",
  },
  { name: "undefined reference stays literal", markdown: "[nope][] and [nope][nope]" },
  {
    name: "reference label cannot contain brackets",
    markdown: "[a[b][]\n\n[a\\[b]: https://x.com",
  },
  { name: "reference in a heading", markdown: "# [ref][]\n\n[ref]: https://x.com/h" },

  {
    name: "inline html stays text",
    markdown: 'a <b>bold</b> and <br> and <span class="x">y</span> and a < b',
  },
  { name: "html block is dropped", markdown: "<div>html</div>\n\ntext" },
  { name: "html comment block is dropped", markdown: "<!-- comment -->\n\ntext" },
  {
    name: "html block type six ends at a blank line",
    markdown: "<p>para one\nstill html</p>\n\nafter",
  },
  { name: "html block type one ends at its closing tag", markdown: "<pre>\nline\n</pre>\nafter" },
  { name: "html script block", markdown: "<script>\nvar a = 1;\n</script>\n\nafter" },
  { name: "unknown tag alone on a line is an html block", markdown: "<custom>\n\nafter" },
  { name: "unknown tag cannot interrupt a paragraph", markdown: "para\n<custom>" },
  { name: "html block in a list item", markdown: "- item\n\n  <div>x</div>\n\n  after" },
  { name: "angle brackets that are text", markdown: "a <3 b >3 c" },

  { name: "table", markdown: "| a | b |\n| --- | --- |\n| 1 | 2 |" },
  {
    name: "table with alignment markers",
    markdown: "| a | b | c |\n| :--- | ---: | :---: |\n| 1 | 2 | 3 |",
  },
  { name: "table without outer pipes", markdown: "a | b\n--- | ---\n1 | 2" },
  {
    name: "table cells keep inline markup",
    markdown: "| **a** | [l](https://x.com) | `c` |\n| --- | --- | --- |\n| ~~d~~ | *e* | f |",
  },
  { name: "escaped pipe in a cell", markdown: "| a | b |\n| --- | --- |\n| 1 \\| 2 | 3 |" },
  {
    name: "pipe inside a code span does not split cells",
    markdown: "| a | b |\n| --- | --- |\n| `x|y` | z |",
  },
  {
    name: "short rows are padded",
    markdown: "| a | b | c |\n| --- | --- | --- |\n| 1 |\n| 1 | 2 | 3 | 4 |",
  },
  {
    name: "table cannot interrupt a paragraph",
    markdown: "para\n| a | b |\n| --- | --- |\n| 1 | 2 |",
  },
  { name: "underline needs a pipe", markdown: "a\n---\n" },
  { name: "table with an empty body", markdown: "| a | b |\n| --- | --- |" },
  { name: "table in a list item", markdown: "- item\n\n  | a | b |\n  | --- | --- |\n  | 1 | 2 |" },
  { name: "table with a blank cell", markdown: "| a | b |\n| --- | --- |\n|  | x |" },
  { name: "row after the table", markdown: "| a | b |\n| --- | --- |\n| 1 | 2 |\nnot | table" },

  { name: "spoiler", markdown: "a ||hidden|| b ||**bold hidden**||" },
  { name: "three pipes are not a spoiler", markdown: "a |||b||| c" },
  { name: "unclosed spoiler", markdown: "a ||b" },

  {
    name: "entities",
    markdown: "&amp; &copy; &nbsp; &#65; &#x41; &lt; &gt; &quot; &unknown; &amp",
  },
  {
    name: "numeric entity bounds",
    markdown: "&#0; &#x10FFFF; &#x110000; &#99999999; &#X6a; &#xD800;",
  },
  { name: "entity inside a link destination", markdown: "[l](https://x.com/?a=1&amp;b=2)" },
  { name: "entity inside a link label", markdown: "[**a&amp;b**](https://x.com)" },

  { name: "backslash escapes", markdown: "foo\\*bar \\_baz \\[br\\] \\# \\`x\\` \\\\ a\\-b" },
  { name: "backslash before a letter is literal", markdown: "a\\nb" },
  { name: "escaped bang before brackets", markdown: "\\![a](https://x.com)" },
  { name: "escaped brackets", markdown: "\\[a](https://x.com)" },

  {
    name: "mixed document",
    markdown:
      "Intro **bold**:\n\n1. first\n2. second\n\n> note\n\n```ts\nconst z: number = 3;\n```\n\nDone https://end.example",
  },
  {
    name: "chinese document",
    markdown: "中文 **加粗** 列表：\n- 项目一\n- 项目二\n\n```\n代码块\n```",
  },
  { name: "long line", markdown: "x".repeat(600) },
  { name: "many blank lines", markdown: "a\n\n\n\n\nb" },
  { name: "deep quote nesting", markdown: `${"> ".repeat(12)}deep` },
  {
    name: "deep list nesting",
    markdown: Array.from({ length: 8 }, (_, i) => `${"  ".repeat(i)}- l${i}`).join("\n"),
  },
  { name: "astral characters", markdown: "𝒜 *𝒷* 😀 **𝒸**" },
];

/** Every named entity the reference knows, in slices, so a miss narrows to one slice. */
async function entitySlices(): Promise<{ name: string; markdown: string }[]> {
  const source = await import("./gen-markdown-tables.ts");
  const { entities } = source.loadTables();
  const slices: { name: string; markdown: string }[] = [];
  const size = 150;
  for (let index = 0; index < entities.length; index += size) {
    slices.push({
      name: `named entities ${index + 1}-${Math.min(index + size, entities.length)}`,
      markdown: entities
        .slice(index, index + size)
        .map((entity) => entity.name)
        .join(" "),
    });
  }
  return slices;
}

export async function generateMarkdownFixture(): Promise<{ cases: MarkdownCase[] }> {
  const inputs = [...MARKDOWN_CORPUS, ...(await entitySlices()), ...randomDocuments(240, 20261124)];
  const cases: MarkdownCase[] = [];
  for (const input of inputs) {
    const tree = projectTree(await parseReference(input.markdown));
    if (tree === null) throw new Error(`no tree for ${input.name}`);
    cases.push({ name: input.name, markdown: input.markdown, tree: compactNode(tree) });
  }
  return { cases };
}
