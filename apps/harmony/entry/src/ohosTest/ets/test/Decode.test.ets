// Decoder contract: consumed fields decode, missing/mistyped consumed fields fail to null,
// unknown extra fields are ignored (forward compatibility), legacy capabilities shapes work.
import { describe, expect, it } from '@ohos/hypium';
import {
  decodeAuthCapabilities,
  decodeBot,
  decodeBotList,
  decodeGroup,
  decodeGroupList,
  decodeHealth,
  decodeMe,
  decodeOk,
  decodeRoster,
  decodeSpaceNavigation,
} from '../../../main/ets/contract/decode';

const ME_JSON = '{"userId":"u1","email":"ada@example.com","name":"Ada","spaceId":"s1",'
  + '"needsModel":false,"defaultProvider":null,"defaultModel":"m1","unknownExtra":{"x":1}}';

export default function decodeTest() {
  describe('ContractDecode', () => {
    it('health_decodes_and_rejects', 0, () => {
      const ok = decodeHealth(JSON.parse('{"ok":true,"version":"1.2.3"}'));
      expect(ok !== null).assertTrue();
      expect(ok!.version).assertEqual('1.2.3');
      expect(decodeHealth(JSON.parse('{"ok":false,"version":"1"}'))).assertNull();
      expect(decodeHealth(JSON.parse('{"ok":true}'))).assertNull();
      expect(decodeHealth(JSON.parse('"text"'))).assertNull();
      expect(decodeHealth(null)).assertNull();
    });

    it('me_decodes_consumed_fields_and_ignores_extras', 0, () => {
      const me = decodeMe(JSON.parse(ME_JSON));
      expect(me !== null).assertTrue();
      expect(me!.userId).assertEqual('u1');
      expect(me!.spaceId).assertEqual('s1');
      expect(me!.defaultProvider).assertNull();
      expect(me!.defaultModel).assertEqual('m1');
      expect(me!.needsModel).assertFalse();
    });

    it('me_rejects_missing_or_mistyped_consumed_fields', 0, () => {
      expect(decodeMe(JSON.parse('{"email":"a@b.c","name":"A","spaceId":"s","needsModel":false,'
        + '"defaultProvider":null,"defaultModel":null}'))).assertNull();
      expect(decodeMe(JSON.parse(ME_JSON.replace('"needsModel":false', '"needsModel":"no"')))).assertNull();
      // defaultProvider is required-nullable: absence is a decode failure, null is fine.
      expect(decodeMe(JSON.parse(ME_JSON.replace('"defaultProvider":null,', '')))).assertNull();
    });

    it('spaces_navigation_reads_current_identity_only', 0, () => {
      const nav = decodeSpaceNavigation(JSON.parse('{"current":{"id":"s1","name":"Ada’s Space",'
        + '"bots":[],"groups":[]},"spaces":[],"firstBotDue":false}'));
      expect(nav !== null).assertTrue();
      expect(nav!.currentId).assertEqual('s1');
      expect(nav!.currentName).assertEqual('Ada’s Space');
      expect(decodeSpaceNavigation(JSON.parse('{"current":{"id":"s1"}}'))).assertNull();
      expect(decodeSpaceNavigation(JSON.parse('{}'))).assertNull();
    });

    it('capabilities_modern_shape', 0, () => {
      const caps = decodeAuthCapabilities(JSON.parse('{"passwordAuth":true,"passwordReset":true,'
        + '"resetUrl":"https://example.com/reset","emailCode":true,"sso":null,'
        + '"providers":[{"id":"oidc","name":"Org SSO","presentation":{}}],"passkeyRpId":null}'));
      expect(caps !== null).assertTrue();
      expect(caps!.passwordAuth).assertTrue();
      expect(caps!.emailCode).assertTrue();
      expect(caps!.resetUrl).assertEqual('https://example.com/reset');
      expect(caps!.providers.length).assertEqual(1);
      expect(caps!.providers[0].name).assertEqual('Org SSO');
    });

    it('capabilities_legacy_shape_defaults_password', 0, () => {
      const caps = decodeAuthCapabilities(JSON.parse('{"passwordReset":false,"resetUrl":null}'));
      expect(caps !== null).assertTrue();
      expect(caps!.passwordAuth).assertTrue();
      expect(caps!.emailCode).assertFalse();
      expect(caps!.ssoName).assertNull();
      expect(caps!.providers.length).assertEqual(0);
    });

    it('capabilities_sso_fallback_and_empty_providers', 0, () => {
      const sso = decodeAuthCapabilities(JSON.parse('{"passwordAuth":false,"passwordReset":false,'
        + '"resetUrl":null,"sso":{"name":"Org","availability":"available"}}'));
      expect(sso !== null).assertTrue();
      expect(sso!.providers.length).assertEqual(1);
      expect(sso!.providers[0].id).assertEqual('oidc');
      const empty = decodeAuthCapabilities(JSON.parse('{"passwordAuth":true,"passwordReset":false,'
        + '"resetUrl":null,"sso":{"name":"Org","availability":"available"},"providers":[]}'));
      expect(empty !== null).assertTrue();
      expect(empty!.providers.length).assertEqual(0);
    });

    it('capabilities_rejects_broken_required_fields', 0, () => {
      expect(decodeAuthCapabilities(JSON.parse('{"passwordAuth":true}'))).assertNull();
      expect(decodeAuthCapabilities(JSON.parse('{"passwordReset":true,"resetUrl":42}'))).assertNull();
      expect(decodeAuthCapabilities(null)).assertNull();
    });

    const BOT_JSON = '{"id":"b1","name":"Alpha","color":"#3EC5A8","pinned":true,"unread":true,'
      + '"preview":"Hi","status":"running","updatedAt":"2026-11-21T10:00:00.000Z","extra":1}';

    it('bot_decodes_consumed_fields_and_ignores_extras', 0, () => {
      const bot = decodeBot(JSON.parse(BOT_JSON));
      expect(bot !== null).assertTrue();
      expect(bot!.id).assertEqual('b1');
      expect(bot!.color).assertEqual('#3EC5A8');
      expect(bot!.pinned).assertTrue();
      expect(bot!.unread).assertTrue();
      expect(bot!.status).assertEqual('running');
      expect(bot!.snoozedUntil).assertNull();
    });

    it('bot_snoozed_until_nullable_optional', 0, () => {
      const snoozed = decodeBot(JSON.parse(BOT_JSON.replace('"extra":1', '"snoozedUntil":"2026-11-21T13:00:00.000Z"')));
      expect(snoozed!.snoozedUntil).assertEqual('2026-11-21T13:00:00.000Z');
      const explicitNull = decodeBot(JSON.parse(BOT_JSON.replace('"extra":1', '"snoozedUntil":null')));
      expect(explicitNull!.snoozedUntil).assertNull();
      // A mistyped consumed field fails the row.
      expect(decodeBot(JSON.parse(BOT_JSON.replace('"pinned":true', '"pinned":"yes"')))).assertNull();
      expect(decodeBot(JSON.parse('{"id":"b1"}'))).assertNull();
    });

    it('group_decodes_and_rejects', 0, () => {
      const group = decodeGroup(JSON.parse('{"id":"g1","name":"Team","pinned":false,"unread":true,'
        + '"preview":"Chat","updatedAt":"2026-11-21T10:00:00.000Z"}'));
      expect(group !== null).assertTrue();
      expect(group!.id).assertEqual('g1');
      expect(group!.unread).assertTrue();
      expect(group!.snoozedUntil).assertNull();
      expect(decodeGroup(JSON.parse('{"id":"g1","name":"Team"}'))).assertNull();
    });

    it('lists_drop_bad_rows_but_fail_on_non_array', 0, () => {
      const bots = decodeBotList(JSON.parse(`[${BOT_JSON},{"id":"bad"},${BOT_JSON.replace('"b1"', '"b2"')}]`));
      expect(bots !== null).assertTrue();
      expect(bots!.length).assertEqual(2);
      expect(bots![1].id).assertEqual('b2');
      expect(decodeBotList(JSON.parse('{"not":"array"}'))).assertNull();
      expect(decodeGroupList(JSON.parse('[]'))!.length).assertEqual(0);
    });

    it('roster_reads_current_bots_and_groups', 0, () => {
      const group = '{"id":"g1","name":"Team","pinned":false,"unread":false,"preview":"","updatedAt":"2026-11-21T10:00:00.000Z"}';
      const roster = decodeRoster(JSON.parse(`{"current":{"id":"s1","name":"S","bots":[${BOT_JSON}],"groups":[${group}]}}`));
      expect(roster !== null).assertTrue();
      expect(roster!.bots.length).assertEqual(1);
      expect(roster!.groups.length).assertEqual(1);
      expect(decodeRoster(JSON.parse('{"current":{"id":"s1"}}'))).assertNull();
      expect(decodeRoster(JSON.parse('{}'))).assertNull();
    });

    it('ok_decodes_archive_restore_answer', 0, () => {
      expect(decodeOk(JSON.parse('{"ok":true}'))).assertTrue();
      expect(decodeOk(JSON.parse('{"ok":false}'))).assertFalse();
      expect(decodeOk(JSON.parse('{}'))).assertFalse();
      expect(decodeOk(null)).assertFalse();
    });
  });
}
