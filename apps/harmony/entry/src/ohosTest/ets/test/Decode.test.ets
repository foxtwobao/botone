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
  decodeModelCatalog,
  decodeModelCatalogEntry,
  decodeOk,
  decodeRoster,
  decodeSpaceNavigation,
} from '../../../main/ets/contract/decode';
import { decodeVoiceCatalog, decodeVoiceCredential } from '../../../main/ets/contract/decode-voice';

const ME_JSON = '{"userId":"u1","email":"ada@example.com","name":"Ada","spaceId":"s1",'
  + '"needsModel":false,"defaultProvider":null,"defaultModel":"m1","unknownExtra":{"x":1}}';
/** A voice catalog entry, closed by each case with the optional fields it varies. */
const VOICE_ENTRY_JSON = '{"id":"fake-voice","name":"Fake Voice","transcribe":true';
/** A saved voice connection that authenticates without a key. */
const VOICE_CREDENTIAL_JSON = '{"id":"c1","provider":"fake-voice","hasKey":false,"voiceId":"v1",'
  + '"speechModel":"","transcribe":false,"endpoint":"","ttsModel":"","sttModel":""}';

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

    it('provider_presentation_decodes_optional_and_rejects_broken', 0, () => {
      // A full presentation: variant and mark with brand-colored and inherited paths.
      const full = decodeAuthCapabilities(JSON.parse('{"passwordAuth":true,"passwordReset":true,'
        + '"resetUrl":null,"emailCode":false,"sso":null,"providers":[{"id":"p1","name":"P1",'
        + '"presentation":{"variant":"outline","mark":{"viewBox":"0 0 24 24","paths":['
        + '{"d":"M1 1L3 3","fill":"#3EC5A8"},{"d":"M4 4L6 6"}]}}}]}'));
      expect(full !== null).assertTrue();
      expect(full!.providers[0].variant).assertEqual('outline');
      expect(full!.providers[0].mark!.viewBox).assertEqual('0 0 24 24');
      expect(full!.providers[0].mark!.paths.length).assertEqual(2);
      expect(full!.providers[0].mark!.paths[0].fill).assertEqual('#3EC5A8');
      // An absent fill is legal (the wire schema makes it optional): the row inherits the
      // button's text color, so the view carries null.
      expect(full!.providers[0].mark!.paths[1].fill).assertNull();
      // Absent presentation (older servers): no variant, no mark, still decodes.
      const bare = decodeAuthCapabilities(JSON.parse('{"passwordAuth":true,"passwordReset":true,'
        + '"resetUrl":null,"emailCode":false,"sso":null,"providers":[{"id":"p1","name":"P1"}]}'));
      expect(bare !== null).assertTrue();
      expect(bare!.providers[0].variant).assertNull();
      expect(bare!.providers[0].mark).assertNull();
      // A broken mark (paths missing, or a path without d) fails its own provider row only;
      // the rest of the capabilities still decode.
      const broken = decodeAuthCapabilities(JSON.parse('{"passwordAuth":true,"passwordReset":true,'
        + '"resetUrl":null,"emailCode":false,"sso":null,"providers":[{"id":"p1","name":"P1",'
        + '"presentation":{"mark":{"viewBox":"0 0 24 24"}}},{"id":"p2","name":"P2"}]}'));
      expect(broken !== null).assertTrue();
      expect(broken!.providers.length).assertEqual(1);
      expect(broken!.providers[0].id).assertEqual('p2');
      const noD = decodeAuthCapabilities(JSON.parse('{"passwordAuth":true,"passwordReset":true,'
        + '"resetUrl":null,"emailCode":false,"sso":null,"providers":[{"id":"p1","name":"P1",'
        + '"presentation":{"mark":{"viewBox":"0 0 24 24","paths":[{"fill":"#000000"}]}}},'
        + '{"id":"p2","name":"P2"}]}'));
      expect(noD !== null).assertTrue();
      expect(noD!.providers.length).assertEqual(1);
      expect(noD!.providers[0].id).assertEqual('p2');
      // A fill value present but not #rrggbb is invalid: the row drops, the decode survives.
      const badFill = decodeAuthCapabilities(JSON.parse('{"passwordAuth":true,"passwordReset":true,'
        + '"resetUrl":null,"emailCode":false,"sso":null,"providers":[{"id":"p1","name":"P1",'
        + '"presentation":{"mark":{"viewBox":"0 0 24 24","paths":[{"d":"M1 1L3 3",'
        + '"fill":"brand-red"}]}}},{"id":"p2","name":"P2"}]}'));
      expect(badFill !== null).assertTrue();
      expect(badFill!.providers.length).assertEqual(1);
      expect(badFill!.providers[0].id).assertEqual('p2');
    });

    it('capabilities_registration_open_defaults_and_closes', 0, () => {
      // Older servers omit the field: registration reads as open.
      const absent = decodeAuthCapabilities(JSON.parse('{"passwordAuth":true,"passwordReset":true,'
        + '"resetUrl":null,"emailCode":false,"sso":null,"providers":[]}'));
      expect(absent !== null).assertTrue();
      expect(absent!.registrationOpen).assertTrue();
      // An explicit false closes registration for this request.
      const closed = decodeAuthCapabilities(JSON.parse('{"passwordAuth":true,"passwordReset":true,'
        + '"resetUrl":null,"emailCode":false,"sso":null,"providers":[],'
        + '"registrationOpen":false}'));
      expect(closed !== null).assertTrue();
      expect(closed!.registrationOpen).assertFalse();
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
      + '"preview":"Hi","status":"running","updatedAt":"2026-11-21T10:00:00.000Z","autoSpeak":true,"extra":1}';

    it('bot_decodes_consumed_fields_and_ignores_extras', 0, () => {
      const bot = decodeBot(JSON.parse(BOT_JSON));
      expect(bot !== null).assertTrue();
      expect(bot!.id).assertEqual('b1');
      expect(bot!.color).assertEqual('#3EC5A8');
      expect(bot!.pinned).assertTrue();
      expect(bot!.unread).assertTrue();
      expect(bot!.status).assertEqual('running');
      expect(bot!.snoozedUntil).assertNull();
      expect(bot!.autoSpeak).assertTrue();
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

    it('bot_autoSpeak_missing_defaults_false_but_a_wrong_type_fails', 0, () => {
      // An older server's bot row carries no autoSpeak: the row still decodes, without reading
      // aloud, rather than dropping the whole bot from the list.
      const old = decodeBot(JSON.parse(BOT_JSON.replace('"autoSpeak":true,', '')));
      expect(old !== null).assertTrue();
      expect(old!.autoSpeak).assertFalse();
      const nulled = decodeBot(JSON.parse(BOT_JSON.replace('"autoSpeak":true', '"autoSpeak":null')));
      expect(nulled !== null).assertTrue();
      expect(nulled!.autoSpeak).assertFalse();
      expect(decodeBot(JSON.parse(BOT_JSON.replace('"autoSpeak":true', '"autoSpeak":"yes"')))).assertNull();
    });

    it('voice_catalog_model_connections_missing_read_as_none_but_a_wrong_shape_fails', 0, () => {
      // An older server's catalog entry offers neither model connections nor a sign-in: the row
      // still decodes, with neither offered. A value of another shape fails the row.
      const offered = decodeVoiceCatalog(JSON.parse(`[${VOICE_ENTRY_JSON},`
        + '"modelConnections":[{"id":"model-work","label":"Work"}],"modelSignIn":"Sign in"}]'));
      expect(offered !== null).assertTrue();
      expect(offered![0].modelConnections![0].label).assertEqual('Work');
      expect(offered![0].modelSignIn).assertEqual('Sign in');
      const older = decodeVoiceCatalog(JSON.parse(`[${VOICE_ENTRY_JSON}}]`));
      expect(older !== null).assertTrue();
      expect(older![0].modelConnections).assertUndefined();
      expect(older![0].modelSignIn).assertUndefined();
      const nulled = decodeVoiceCatalog(JSON.parse(`[${VOICE_ENTRY_JSON},"modelConnections":null}]`));
      expect(nulled !== null).assertTrue();
      expect(nulled![0].modelConnections).assertUndefined();
      expect(decodeVoiceCatalog(JSON.parse(`[${VOICE_ENTRY_JSON},"modelConnections":"work"}]`))).assertNull();
      expect(decodeVoiceCatalog(JSON.parse(`[${VOICE_ENTRY_JSON},"modelSignIn":true}]`))).assertNull();
    });

    it('voice_credential_model_connection_missing_reads_as_none_but_a_wrong_type_fails', 0, () => {
      // An older server's saved connection names no model connection: the row still decodes. A
      // value of another type fails the row.
      const older = decodeVoiceCredential(JSON.parse(VOICE_CREDENTIAL_JSON));
      expect(older !== null).assertTrue();
      expect(older!.modelCredentialId).assertUndefined();
      const bound = decodeVoiceCredential(JSON.parse(VOICE_CREDENTIAL_JSON.replace(
        '"hasKey":false', '"hasKey":false,"modelCredentialId":"model-work"')));
      expect(bound !== null).assertTrue();
      expect(bound!.modelCredentialId).assertEqual('model-work');
      expect(decodeVoiceCredential(JSON.parse(VOICE_CREDENTIAL_JSON.replace(
        '"hasKey":false', '"hasKey":false,"modelCredentialId":7')))).assertNull();
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
      const bots = decodeBotList(JSON.parse(`[${BOT_JSON},{"id":"bad"},${BOT_JSON.replace('"id":"b1"', '"id":"b2"')}]`));
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

    it('model_catalog_reads_the_four_whitelisted_fields', 0, () => {
      const entry = decodeModelCatalogEntry(JSON.parse(
        '{"provider":"p1","id":"m1","label":"Fast Model","providerName":"Maker",'
        + '"billing":"credits","managed":true,"unknownExtra":{"x":1}}'));
      expect(entry !== null).assertTrue();
      expect(entry!.provider).assertEqual('p1');
      expect(entry!.id).assertEqual('m1');
      expect(entry!.label).assertEqual('Fast Model');
      expect(entry!.providerName).assertEqual('Maker');
      // providerName is optional: absent and null both read as null, a non-string fails.
      expect(decodeModelCatalogEntry(JSON.parse('{"provider":"p","id":"m","label":"L"}'))!.providerName)
        .assertNull();
      expect(decodeModelCatalogEntry(JSON.parse(
        '{"provider":"p","id":"m","label":"L","providerName":null}'))!.providerName).assertNull();
      expect(decodeModelCatalogEntry(JSON.parse(
        '{"provider":"p","id":"m","label":"L","providerName":7}'))).assertNull();
    });

    it('model_catalog_rejects_missing_consumed_fields_and_drops_bad_rows', 0, () => {
      expect(decodeModelCatalogEntry(JSON.parse('{"id":"m","label":"L"}'))).assertNull();
      expect(decodeModelCatalogEntry(JSON.parse('{"provider":"p","label":"L"}'))).assertNull();
      expect(decodeModelCatalogEntry(JSON.parse('{"provider":"p","id":"m"}'))).assertNull();
      expect(decodeModelCatalogEntry(JSON.parse('{"provider":"","id":"m","label":"L"}'))).assertNull();
      expect(decodeModelCatalogEntry(null)).assertNull();
      // A bad row is dropped, not fatal; a non-array fails whole.
      const list = decodeModelCatalog(JSON.parse(
        '[{"provider":"p","id":"m1","label":"L1"},{"id":"bad"},{"provider":"p","id":"m2","label":"L2"}]'));
      expect(list !== null).assertTrue();
      expect(list!.length).assertEqual(2);
      expect(list![0].id).assertEqual('m1');
      expect(list![1].id).assertEqual('m2');
      expect(decodeModelCatalog(JSON.parse('{}'))).assertNull();
      expect(decodeModelCatalog(null)).assertNull();
    });
  });
}
