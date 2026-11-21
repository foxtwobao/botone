// Decoder contract: consumed fields decode, missing/mistyped consumed fields fail to null,
// unknown extra fields are ignored (forward compatibility), legacy capabilities shapes work.
import { describe, expect, it } from '@ohos/hypium';
import {
  decodeAuthCapabilities,
  decodeHealth,
  decodeMe,
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
  });
}
