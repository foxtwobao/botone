// The message-text rules (M5): selectable and copyable text, block text, reply lines, display
// names, @Name mention spans and targets, plain-text link parts, and the long-press menu subset.
// Expected values come from the shared TypeScript the rules were ported from (checked into the
// layer-2 fixture by contract/message-text-port.test.ts); this replays them on the device.
import { describe, expect, it } from '@ohos/hypium';
import { plainTextFromMarkdown } from '../../../main/ets/thread/markdown-plain';
import {
  groupMentionNames,
  mentionSpans,
  splitMentionText,
  userMentionTargets,
  userTextRuns,
} from '../../../main/ets/thread/message-mentions';
import type { MemberLike, UserMentionTarget, UserTextRun } from '../../../main/ets/thread/message-mentions';
import { plainTextLinkParts } from '../../../main/ets/thread/message-links';
import { parseMarkdown } from '../../../main/ets/thread/markdown-lite';
import {
  blockText,
  channelMessageSender,
  compactReplyExcerpt,
  copyableMessageText,
  displayName,
  isOpaqueName,
  isPageOriginReply,
  markdownCodeBlocks,
  messageMenu,
  otherAuthor,
  previewMessageText,
  replyLabel,
  replyLineText,
  selectableMessageText,
} from '../../../main/ets/thread/message-text';
import type {
  Blocks,
  MessageLike,
  PageOriginReplyLike,
  PreviewLabels,
  ReplyAttachment,
  ReplyLabels,
  ReplyPreview,
} from '../../../main/ets/thread/message-text';
import { selectableTextFromMarkdown } from '../../../main/ets/thread/selectable-text';

function block(json: string): Record<string, Object> {
  return JSON.parse(json) as Record<string, Object>;
}

const LABELS: PreviewLabels = { photo: 'Photo', attachment: 'Attachment', message: 'Message' };
const REPLY_LABELS: ReplyLabels = { photo: 'Photo', attachment: 'Attachment' };

export default function messageTextTest() {
  describe('MessageText', () => {
    it('display_names_fallback_for_opaque_ids', 0, () => {
      expect(displayName('Alice', 'Bot')).assertEqual('Alice');
      expect(displayName('  Bob  ', 'Bot')).assertEqual('Bob');
      expect(displayName('', 'Bot')).assertEqual('Bot');
      expect(displayName('__token__', 'Bot')).assertEqual('Bot');
      expect(displayName('123e4567-e89b-12d3-a456-426614174000', 'Bot')).assertEqual('Bot');
      expect(displayName('王五', 'Bot')).assertEqual('王五');
      expect(isOpaqueName('Writer')).assertEqual(false);
    });

    it('mention_spans_take_the_longest_name', 0, () => {
      const names: string[] = ['Writer', '王五', 'All'];
      expect(JSON.stringify(mentionSpans('@Writer please', names).map((span): string => span.name))).assertEqual('["Writer"]');
      expect(JSON.stringify(mentionSpans('请@Writer你看下', names).map((span): string => span.name))).assertEqual('["Writer"]');
      expect(JSON.stringify(mentionSpans('@Writers', names).map((span): string => span.name))).assertEqual('[]');
      expect(JSON.stringify(mentionSpans('hi@Writer', names).map((span): string => span.name))).assertEqual('[]');
      // "all" inside an address or path is not a mention of everyone.
      expect(JSON.stringify(groupMentionNames('x.com/@all', []))).assertEqual('[]');
      expect(JSON.stringify(groupMentionNames('a@all.com', []))).assertEqual('[]');
      expect(JSON.stringify(groupMentionNames('please @all look', []))).assertEqual('["all"]');
      expect(JSON.stringify(groupMentionNames('https://x.com/a，@所有人', []))).assertEqual('["所有人"]');
    });

    it('mention_targets_and_runs', 0, () => {
      const members: MemberLike[] = [
        { botId: 'b1', name: 'Writer', color: '#f00' },
        { botId: 'b2', name: '王五', color: '#0f0' },
        { botId: 'b3', name: 'Writer', color: '#00f' },
      ];
      const targets = userMentionTargets(members, '@Writer hi');
      // A name two members share stays plain text: neither Writer is a target. The other member
      // and the words for everyone still are.
      const writers = targets.filter((target: UserMentionTarget): boolean => target.name === 'Writer');
      expect(writers.length).assertEqual(0);
      expect(targets.some((target: UserMentionTarget): boolean => target.kind === 'everyone')).assertEqual(true);
      expect(targets.some((target: UserMentionTarget): boolean => target.id === 'b2')).assertEqual(true);
      const single: MemberLike[] = [{ botId: 'b1', name: 'Writer', color: '#f00' }, { botId: 'b2', name: '王五', color: '#0f0' }];
      const found = userMentionTargets(single, '@Writer hi');
      // Two members: "everyone" names them all; the other word for it ("all") shows only when the
      // message uses it. Then every uniquely named member, in order.
      expect(found.map((target: UserMentionTarget): string => `${target.kind}:${target.name}`).join(','))
        .assertEqual('everyone:everyone,bot:Writer,bot:王五');
      const runs = userTextRuns('hi @Writer there', found);
      expect(runs.length).assertEqual(3);
      expect(runs[1].text).assertEqual('@Writer');
      expect(runs[1].target!.id).assertEqual('b1');
      // A link is one underlined run of its own, never searched for names.
      const linked = userTextRuns('see https://x.com/@Writer now', found);
      expect(JSON.stringify(linked.map((run: UserTextRun): string =>
        run.href === '' ? (run.target === null ? '-' : 'M') : 'L'))).assertEqual('["-","L","-"]');
      // A page link has no page to open yet, so it is plain text in the bubble, not a dead link.
      expect(JSON.stringify(userTextRuns('[Home](page:p1)', []).map((run: UserTextRun): string =>
        `${run.text}:${run.href === '' ? '-' : 'L'}`))).assertEqual('["Home:-"]');
    });

    it('plain_text_link_parts', 0, () => {
      const parts = plainTextLinkParts('see https://x.com/a now');
      expect(parts.length).assertEqual(3);
      expect(parts[1].type).assertEqual('link');
      expect(parts[1].href).assertEqual('https://x.com/a');
      // Bare domains stay text (a file name must not link).
      expect(plainTextLinkParts('setup.py notes.md').length).assertEqual(1);
      expect(plainTextLinkParts('a b@c.com d')[1].href).assertEqual('mailto:b@c.com');
      // A page link is found as one (it opens a page once pages arrive).
      expect(plainTextLinkParts('[page](page:p1)')[0].type).assertEqual('page');
    });

    it('selectable_and_copyable_text', 0, () => {
      const blocks: Blocks = [
        block('{"kind":"text","text":"  hi  "}'), block('{"kind":"chart"}'), block('{"kind":"ask","text":"Allow?"}'),
      ];
      const user: MessageLike = { id: 'm', role: 'user', blocks: blocks };
      expect(selectableMessageText(user)).assertEqual('  hi  \nAllow?');
      expect(copyableMessageText(user)).assertEqual('hi  \nAllow?');
    });

    it('block_text_joins_every_block', 0, () => {
      const blocks: Blocks = [
        block('{"kind":"text","text":"body"}'), block('{"kind":"steps","steps":[{"label":"Read","count":2}]}'),
        block('{"kind":"image","name":"pic.png"}'), block('{"kind":"file","name":"doc.pdf","size":12}'),
      ];
      const bot: MessageLike = { id: 'm', role: 'bot', blocks: blocks };
      expect(blockText(bot)).assertEqual('body\nRead ×2\n[image: pic.png]\n[file: doc.pdf (12 bytes)]');
    });

    it('reply_line_rules', 0, () => {
      expect(replyLineText('multi\nline  quote')).assertEqual('multi line quote');
      expect(replyLineText(undefined, 'first\nsecond')).assertEqual('first');
      expect(compactReplyExcerpt('\n  first line\nnext')).assertEqual('first line');
      const attachment: ReplyAttachment = { kind: 'image', name: 'pic.png' };
      // An older send persisted the image filename as a quote: it shows as the photo label.
      expect(replyLabel('pic.png', undefined, attachment, REPLY_LABELS)).assertEqual('Photo');
      expect(replyLabel('q', undefined, null, REPLY_LABELS)).assertEqual('q');
      const pagePreview: ReplyPreview = { page: true };
      const fromPage: PageOriginReplyLike = { replyQuote: undefined, replyPreview: pagePreview };
      const fromPageQuoted: PageOriginReplyLike = { replyQuote: 'q', replyPreview: pagePreview };
      expect(isPageOriginReply(fromPage)).assertEqual(true);
      expect(isPageOriginReply(fromPageQuoted)).assertEqual(false);
      const author: Record<string, Object> = { 'id': 'u1' };
      expect(otherAuthor(author, 'u2') !== undefined).assertEqual(true);
      expect(otherAuthor(author, 'u1') === undefined).assertEqual(true);
    });

    it('preview_text_falls_back_to_labels', 0, () => {
      const botText: MessageLike = { id: 'm', role: 'bot', blocks: [block('{"kind":"text","text":"**bold** body"}')] };
      expect(previewMessageText(botText, LABELS)).assertEqual('bold body');
      const botImage: MessageLike = { id: 'm', role: 'bot', blocks: [block('{"kind":"image","name":"pic.png"}')] };
      expect(previewMessageText(botImage, LABELS)).assertEqual('Photo');
      const botEmpty: MessageLike = { id: 'm', role: 'bot', blocks: [] };
      expect(previewMessageText(botEmpty, LABELS)).assertEqual('Message');
      expect(channelMessageSender([block('{"kind":"channel_message","fromLabel":"Sam","text":"hi"}')])).assertEqual('Sam');
    });

    it('plain_text_conversion', 0, () => {
      expect(plainTextFromMarkdown('# Title\n\n- **bold** item')).assertEqual('Title bold item');
      expect(plainTextFromMarkdown('| a | b |\n|---|---|\n| 1 | 2 |')).assertEqual('a, b 1, 2');
      expect(selectableTextFromMarkdown('line one\nline two\n\nline three')).assertEqual('line one\nline two\n\nline three');
      expect(selectableTextFromMarkdown('- item\n\n```\ncode\n```')).assertEqual('• item\n\ncode');
    });

    it('menu_offers_copy_always_and_select_when_there_is_text', 0, () => {
      const hello: MessageLike = { id: 'm1', role: 'user', blocks: [block('{"kind":"text","text":"hello"}')] };
      const text = messageMenu(hello);
      expect(text.select).assertEqual(true);
      expect(text.copyCode).assertEqual(false);
      expect(text.copyText).assertEqual('hello');
      const chart: MessageLike = { id: 'm2', role: 'bot', blocks: [block('{"kind":"chart"}')] };
      const empty = messageMenu(chart);
      expect(empty.select).assertEqual(false);
      const withCode: MessageLike = { id: 'm4', role: 'bot', blocks: [block('{"kind":"text","text":"```js\\nconst a = 1;\\n```"}')] };
      const code = messageMenu(withCode);
      expect(code.copyCode).assertEqual(true);
      expect(code.code).assertEqual('const a = 1;');
    });

    it('copy_code_keeps_the_tabs_the_code_was_written_with', 0, () => {
      // A Makefile's recipe starts with a tab; copied as spaces it would no longer build.
      const makefile: MessageLike = { id: 'm5', role: 'bot', blocks: [block('{"kind":"text","text":"```make\\nbuild:\\n\\techo hi\\n```"}')] };
      expect(messageMenu(makefile).code).assertEqual('build:\n\techo hi');
      expect(markdownCodeBlocks('- item\n\n  ```\n  \techo\n  ```')[0]).assertEqual('\techo');
      expect(markdownCodeBlocks('```\n```').length).assertEqual(0);
      // The copy button on the block itself copies the same tabs: the codeblock node carries them.
      const tree = parseMarkdown('```make\nbuild:\n\techo hi\n```');
      expect(tree.children[0].copyText).assertEqual('build:\n\techo hi\n');
      expect(tree.children[0].text).assertEqual('build:\n    echo hi\n');
    });
  });
}
