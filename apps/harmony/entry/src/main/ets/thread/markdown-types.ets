// Shared shapes of the markdown parser port (M5): the tree the renderer reads, and the small
// records the pure passes hand each other. Pure data: no ArkUI, no kits.

/** One node of a parsed document: a block, an inline, or (in `children`) both. */
export class MdNode {
  /** doc | p | h | ul | ol | li | quote | admonition | codeblock | hr | table | thead | tbody | tr
   * | th | td | text | strong | em | del | code | a | img | br | softbr | spoiler | video. */
  type: string = '';
  /** text, code and codeblock: the words. */
  text: string = '';
  /** a, img, video: the address. */
  href: string = '';
  /** a, img: the optional title. */
  title: string = '';
  /** h: 1 to 6. */
  level: number = 0;
  /** codeblock: the language the fence names. */
  lang: string = '';
  /** codeblock: the fence character ('`' or '~'); empty for indented code. */
  fence: string = '';
  /** ol: the first item's number. */
  start: number = 1;
  /** p: true inside a tight list item (the reference wraps these after parsing). */
  tight: boolean = false;
  /** li: "" for a plain item, else the task mark (" ", "x" or "X"). */
  task: string = '';
  /** admonition: its type; th, td: the column's alignment. */
  kind: string = '';
  /** table: the column count. */
  cols: number = 0;
  /** table: how many rows are the head. */
  heads: number = 0;
  /** table: how many rows are the body. */
  bodies: number = 0;
  children: MdNode[] = [];
}

/** A case-folded code point (link labels compare case-insensitively). */
export class FoldInfo {
  codepoints: number[] = [0, 0, 0];
  n: number = 1;
}

/** What the parser reports as it reads a document, in document order. */
export interface MdSink {
  enterBlock(type: string, node: MdNode): void;
  leaveBlock(type: string): void;
  enterSpan(type: string, node: MdNode): void;
  leaveSpan(type: string): void;
  /** Words to add to the node being built (a character reference arrives already decoded). */
  text(value: string): void;
  /** A line break inside a paragraph: softbr or br. */
  lineBreak(kind: string): void;
}
