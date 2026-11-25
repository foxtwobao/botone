// Stage D render logic (design §6.4): the three-tier block degradation, markdown-lite, and the
// transcript row projection. Pure functions, no network. The unknown-kind placeholder is the M3
// DoD's "伪造新 kind 渲染为占位不崩溃" case; the tier table mirrors the design whitelist.
import { describe, expect, it } from '@ohos/hypium';
import { blockView, isDeliveryMessage, messageBlockViews, TIER_FULL, TIER_TEXT, TIER_PLACEHOLDER } from '../../../main/ets/thread/block-view';
import { markdownPlainText, mdCompact, parseMarkdown } from '../../../main/ets/thread/markdown-lite';
import { daySeparatorLabel, messageKey, projectRows } from '../../../main/ets/stores/thread-store';
import { t } from '../../../main/ets/i18n/i18n';
import type { MdNode } from '../../../main/ets/thread/markdown-types';
import { inlineRuns } from '../../../main/ets/features/chat/markdown-runs';
import type { TextRun } from '../../../main/ets/features/chat/markdown-runs';
import type { LiveMessage, ThreadSnapshot } from '../../../main/ets/thread/thread-snapshot';

function block(json: string): Record<string, Object> {
  return JSON.parse(json) as Record<string, Object>;
}

function message(id: string, role: string, createdAt: string, blocksJson: string): LiveMessage {
  const parsed: Record<string, Object>[] = [];
  for (const item of JSON.parse(blocksJson) as Object[]) {
    parsed.push(item as Record<string, Object>);
  }
  const result: LiveMessage = {
    id: id, threadId: 't1', seq: 1, role: role, blocks: parsed, createdAt: createdAt,
  };
  return result;
}

export default function threadRenderTest() {
  describe('ThreadRender', () => {
    it('unknown_kind_degrades_to_placeholder', 0, () => {
      // A fabricated future kind must never crash the transcript (M3 DoD).
      const view = blockView(block('{"kind":"hologram_v9","payload":{"x":1}}'));
      expect(view.tier).assertEqual(TIER_PLACEHOLDER);
      expect(view.kind).assertEqual('hologram_v9');
      // An empty/missing kind is also a placeholder, not a throw.
      expect(blockView(block('{}')).tier).assertEqual(TIER_PLACEHOLDER);
    });

    it('tier_table_matches_design_whitelist', 0, () => {
      // T1 full render.
      expect(blockView(block('{"kind":"text","text":"hi"}')).tier).assertEqual(TIER_FULL);
      expect(blockView(block('{"kind":"meta","text":"note"}')).tier).assertEqual(TIER_FULL);
      expect(blockView(block('{"kind":"progress","text":"thinking"}')).tier).assertEqual(TIER_FULL);
      expect(blockView(block('{"kind":"card","lines":[{"k":"a","v":"b"}]}')).tier).assertEqual(TIER_FULL);
      expect(blockView(block('{"kind":"steps","steps":[{"label":"Read","count":2}]}')).tier).assertEqual(TIER_FULL);
      expect(blockView(block('{"kind":"routine_event","change":"created","name":"Daily"}')).tier).assertEqual(TIER_FULL);
      // T2 text extraction.
      expect(blockView(block('{"kind":"handoff","text":"over to you"}')).tier).assertEqual(TIER_TEXT);
      expect(blockView(block('{"kind":"channel_message","fromLabel":"IRC","text":"hi"}')).tier).assertEqual(TIER_TEXT);
      expect(blockView(block('{"kind":"bot_message_sent","toBotName":"Helper","text":"go"}')).tier).assertEqual(TIER_TEXT);
      expect(blockView(block('{"kind":"bot_message_received","fromBotName":"Helper","text":"done"}')).tier).assertEqual(TIER_TEXT);
      expect(blockView(block('{"kind":"voice_call","title":"Call","farewell":"bye"}')).tier).assertEqual(TIER_TEXT);
      expect(blockView(block('{"kind":"computer","state":"on","text":"clicking"}')).tier).assertEqual(TIER_TEXT);
      expect(blockView(block('{"kind":"subagent","name":"Scout","task":"search"}')).tier).assertEqual(TIER_TEXT);
      expect(blockView(block('{"kind":"image","name":"photo.png"}')).tier).assertEqual(TIER_TEXT);
      expect(blockView(block('{"kind":"file","name":"doc.pdf"}')).tier).assertEqual(TIER_TEXT);
      // T3 placeholder for the unsupported kinds.
      expect(blockView(block('{"kind":"chart"}')).tier).assertEqual(TIER_PLACEHOLDER);
      expect(blockView(block('{"kind":"app"}')).tier).assertEqual(TIER_PLACEHOLDER);
      expect(blockView(block('{"kind":"page"}')).tier).assertEqual(TIER_PLACEHOLDER);
      expect(blockView(block('{"kind":"mcp_approval"}')).tier).assertEqual(TIER_PLACEHOLDER);
      expect(blockView(block('{"kind":"cloud_agent"}')).tier).assertEqual(TIER_PLACEHOLDER);
      expect(blockView(block('{"kind":"tool_question"}')).tier).assertEqual(TIER_PLACEHOLDER);
      expect(blockView(block('{"kind":"call_request"}')).tier).assertEqual(TIER_PLACEHOLDER);
    });

    it('ask_approval_and_text_answerable_secret_placeholder', 0, () => {
      const approval = blockView(block('{"kind":"ask","text":"Allow fetch?","status":"pending","actions":[{"id":"allow","label":"Allow"},{"id":"deny","label":"Deny"}]}'));
      expect(approval.tier).assertEqual(TIER_FULL);
      expect(approval.ask!.answerable).assertEqual(true);
      expect(approval.ask!.actions.length).assertEqual(2);
      expect(approval.ask!.actions[0].id).assertEqual('allow');
      // A pure-text question (no actions, input text) answers from its own field.
      const text = blockView(block('{"kind":"ask","text":"What name?","input":"text","status":"pending"}'));
      expect(text.tier).assertEqual(TIER_FULL);
      expect(text.ask!.textInput).assertEqual(true);
      expect(text.ask!.answerable).assertEqual(true);
      // A secret card stays T3 (vault is Phase 2).
      const secret = blockView(block('{"kind":"ask","text":"Password?","input":"secret","status":"pending"}'));
      expect(secret.tier).assertEqual(TIER_PLACEHOLDER);
      // An answered card shows its answer, no controls.
      const answered = blockView(block('{"kind":"ask","text":"Allow?","status":"answered","answer":"allow","actions":[{"id":"allow","label":"Allow"}]}'));
      expect(answered.tier).assertEqual(TIER_FULL);
      expect(answered.ask!.answered).assertEqual(true);
      expect(answered.ask!.answerable).assertEqual(false);
      expect(answered.ask!.answer).assertEqual('allow');
    });

    it('choice_read_only_with_answer_highlight', 0, () => {
      const view = blockView(block('{"kind":"choice","question":"Pick one","options":[{"id":"a","letter":"A","label":"Alpha"},{"id":"b","letter":"B","label":"Beta"}],"answerId":"b"}'));
      expect(view.tier).assertEqual(TIER_FULL);
      expect(view.choice!.question).assertEqual('Pick one');
      expect(view.choice!.options.length).assertEqual(2);
      expect(view.choice!.answerId).assertEqual('b');
    });

    it('delivery_block_hides_whole_message', 0, () => {
      const blocks: Record<string, Object>[] = [block('{"kind":"text","text":"wake prompt"}'), block('{"kind":"delivery"}')];
      expect(isDeliveryMessage(blocks)).assertEqual(true);
      expect(isDeliveryMessage([block('{"kind":"text","text":"hi"}')])).assertEqual(false);
    });

    it('progress_activity_flag_and_text', 0, () => {
      const activity = blockView(block('{"kind":"progress","text":"Reading file","activity":true}'));
      expect(activity.activity).assertEqual(true);
      expect(activity.text).assertEqual('Reading file');
      const narration = blockView(block('{"kind":"progress","text":"Here is the answer"}'));
      expect(narration.activity).assertEqual(false);
    });

    it('markdown_tree_blocks', 0, () => {
      // The tree the bubble renders: headings, paragraphs, lists, fenced code and quotes in order.
      const root = parseMarkdown('# Title\n\nSome **bold** and `code`.\n\n- one\n- two\n\n```\nlet x = 1;\n```\n\n> quoted');
      const types: string[] = root.children.map((child: MdNode): string => child.type);
      expect(JSON.stringify(types)).assertEqual('["h","p","ul","codeblock","quote"]');
      expect(root.children[0].level).assertEqual(1);
      expect(root.children[3].text).assertEqual('let x = 1;\n');
      // A closing fence is not content.
      expect(root.children[3].text.includes('```')).assertEqual(false);
    });

    it('markdown_inline_spans', 0, () => {
      const root = parseMarkdown('a **b** *c* `d` [e](https://x.com)');
      const runs = inlineRuns(root.children[0]);
      expect(runs.map((run: TextRun): string => run.text).join('')).assertEqual('a b c d e');
      expect(runs.filter((run: TextRun): boolean => run.bold).map((run: TextRun): string => run.text).join('')).assertEqual('b');
      expect(runs.filter((run: TextRun): boolean => run.italic).map((run: TextRun): string => run.text).join('')).assertEqual('c');
      expect(runs.filter((run: TextRun): boolean => run.code).map((run: TextRun): string => run.text).join('')).assertEqual('d');
      const link = runs.find((run: TextRun): boolean => run.href !== '');
      expect(link!.text).assertEqual('e');
      expect(link!.href).assertEqual('https://x.com');
      // An unpaired marker stays literal (no closing delimiter), never a crash.
      expect(markdownPlainText('a * b')).assertEqual('a * b');
      expect(markdownPlainText('plain text only')).assertEqual('plain text only');
    });

    it('markdown_plain_text_strips_markers', 0, () => {
      expect(markdownPlainText('# Hi\n\n- **bold** item')).assertEqual('Hi bold item');
    });

    it('row_projection_day_separators_and_delivery_hidden', 0, () => {
      const snapshot: ThreadSnapshot = {
        threadId: 't1', cursor: 3, olderCursor: null,
        messages: [
          message('m1', 'user', '2026-11-21T10:00:00Z', '[{"kind":"text","text":"yesterday"}]'),
          message('m2', 'bot', '2026-11-22T10:00:00Z', '[{"kind":"text","text":"today"}]'),
          message('m3', 'user', '2026-11-22T11:00:00Z', '[{"kind":"delivery"},{"kind":"text","text":"wake"}]'),
          message('m4', 'bot', '2026-11-22T12:00:00Z', '[{"kind":"text","text":"reply"}]'),
        ],
        run: null, activeRuns: [],
      };
      const rows = projectRows(snapshot);
      // day(yesterday) + m1 + day(today) + m2 + m4 — m3 (delivery) hidden whole.
      expect(rows.length).assertEqual(5);
      expect(rows[0].type).assertEqual('day');
      expect(rows[1].type).assertEqual('message');
      expect(rows[1].message!.id).assertEqual('m1');
      expect(rows[2].type).assertEqual('day');
      // Rows carry the timestamp, not a baked label: the separator renders at build time, so a
      // hot locale switch re-translates it (the M4 Pinned-heading bug class).
      expect(rows[2].dayAt).assertEqual('2026-11-22T10:00:00Z');
      // The day label is the product separator (Today/Yesterday + clock, locale-formatted); the
      // fixture-aligned format itself is covered by DatesFixture. Here: the day RULE.
      const now = new Date('2026-11-22T13:00:00Z').getTime();
      expect(daySeparatorLabel(rows[2].dayAt, now).startsWith(t('Today'))).assertEqual(true);
      expect(rows[3].message!.id).assertEqual('m2');
      expect(rows[4].message!.id).assertEqual('m4');
      // A null snapshot projects no rows.
      expect(projectRows(null).length).assertEqual(0);
    });

    it('message_key_carries_content_for_rerender', 0, () => {
      const before = message('m1', 'bot', '2026-11-22T10:00:00Z', '[{"kind":"progress","text":"partial"}]');
      const after = message('m1', 'bot', '2026-11-22T10:00:00Z', '[{"kind":"progress","text":"partial answer"}]');
      // Same id, different content → different key, so LazyForEach re-renders the changed row.
      expect(messageKey(before) === messageKey(after)).assertEqual(false);
      expect(messageKey(before) === messageKey(before)).assertEqual(true);
    });

    it('message_block_views_maps_every_block', 0, () => {
      const views = messageBlockViews([block('{"kind":"text","text":"a"}'), block('{"kind":"chart"}')]);
      expect(views.length).assertEqual(2);
      expect(views[0].tier).assertEqual(TIER_FULL);
      expect(views[1].tier).assertEqual(TIER_PLACEHOLDER);
    });
  });
}
