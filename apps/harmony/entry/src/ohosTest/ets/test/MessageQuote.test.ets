// B1 quote surface: the sheet's selectable text (replayed from the layer-2 fixture generated
// against the real mobile conversion), the reply-quote cap, the menu's offer rule, the send body
// that carries an excerpt, and one closed loop against the fixture server — a quoted reply is
// accepted and the re-read message keeps its replyQuote. Every id here is a fake probe.
import { afterEach, beforeAll, beforeEach, describe, expect, it } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { app } from '../../../main/ets/app/app-state';
import { initServerStore, switchServer } from '../../../main/ets/net/server-store';
import { clearSessionToken, saveSessionToken, setSelectedSpace } from '../../../main/ets/net/session';
import { setConsentPrompt } from '../../../main/ets/net/consent';
import { rpc } from '../../../main/ets/net/rpc';
import { getJson } from '../../../main/ets/net/http';
import { threadSendBody } from '../../../main/ets/thread/thread-send';
import {
  hasQuotableText,
  MAX_QUOTABLE_SOURCE_LENGTH,
  quotableMessageSegments,
  REPLY_QUOTE_MAX_LENGTH,
  truncateReplyQuote,
} from '../../../main/ets/thread/message-quote';
import { fixtureQuote } from './fixtures.generated';
import { recordOf, stableJson } from './test-utils';

const BASE = 'http://10.0.2.2:8787';

function context(): Context {
  return abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext();
}

function records(value: Object): Record<string, Object>[] {
  return value as Record<string, Object>[];
}

function textOf(record: Record<string, Object>, key: string): string {
  const value = record[key];
  return typeof value === 'string' ? value as string : '';
}

export default function messageQuoteTest() {
  describe('MessageQuoteFixture', () => {
    it('replays_the_quoted_segments_the_sheet_offers', 0, () => {
      const data = recordOf(fixtureQuote);
      const constants = data['constants'] as Record<string, Object>;
      expect(REPLY_QUOTE_MAX_LENGTH).assertEqual(constants['replyQuoteMaxLength'] as number);
      expect(MAX_QUOTABLE_SOURCE_LENGTH).assertEqual(constants['maxQuotableSourceLength'] as number);
      for (const row of records(data['segments'])) {
        const blocks = records(row['blocks']);
        const expected = row['expected'] as Object[];
        expect(stableJson(quotableMessageSegments(textOf(row, 'role'), blocks)))
          .assertEqual(stableJson(expected));
      }
    });

    it('caps_a_quote_exactly_as_the_contract_does', 0, () => {
      const data = recordOf(fixtureQuote);
      for (const row of records(data['truncate'])) {
        expect(truncateReplyQuote(textOf(row, 'value'))).assertEqual(textOf(row, 'expected'));
      }
      expect(truncateReplyQuote('hello')).assertEqual(
        textOf(data['constants'] as Record<string, Object>, 'replyQuoteProbe'));
    });

    it('offers_a_quote_only_when_the_sheet_would_have_text', 0, () => {
      const data = recordOf(fixtureQuote);
      for (const row of records(data['hasQuotable'])) {
        expect(hasQuotableText(textOf(row, 'role'), records(row['blocks'])))
          .assertEqual(row['expected']);
      }
    });

    it('sends_the_quoted_excerpt_in_the_mobile_body', 0, () => {
      const data = recordOf(fixtureQuote);
      for (const row of records(data['send'])) {
        const body = threadSendBody(textOf(row, 'botId'), textOf(row, 'groupId'),
          textOf(row, 'text'), [], textOf(row, 'replyToMessageId'), textOf(row, 'clientNonce'),
          row['imagesAsFiles'] === true, textOf(row, 'replyQuote'));
        expect(stableJson(body)).assertEqual(stableJson(row['body']));
      }
    });
  });

  describe('MessageQuoteAgainstFixtureServer', () => {
    beforeAll(async () => {
      app.detach();
      await initServerStore(context());
      await switchServer(BASE, {});
      setConsentPrompt(async (): Promise<boolean> => true);
    });

    beforeEach(async () => {
      await getJson(`${BASE}/__reset`, {}, 8000, 64 * 1024);
      await saveSessionToken('fake-token');
      setSelectedSpace('space-fake');
    });

    afterEach(async () => {
      setConsentPrompt(null);
      await clearSessionToken();
      setSelectedSpace('');
    });

    it('a_quoted_reply_round_trips_with_its_excerpt', 0, async () => {
      const input: Record<string, Object> = {};
      input['botId'] = 'bot-1';
      input['text'] = 'quote probe';
      input['replyToMessageId'] = 'thread-bot-1-m2';
      input['replyQuote'] = 'Hi there.';
      input['clientNonce'] = 'quote-probe-nonce';
      input['imageHandling'] = 'confirm';
      await rpc('threads/send', input);
      const target: Record<string, Object> = {};
      target['botId'] = 'bot-1';
      const snapshot = await rpc('threads/get', target) as Record<string, Object>;
      const messages = records(snapshot['messages']);
      let echoed = '';
      for (const message of messages) {
        if (message['replyQuote'] === 'Hi there.') {
          echoed = textOf(message, 'replyQuote');
        }
      }
      expect(echoed).assertEqual('Hi there.');
    });
  });
}