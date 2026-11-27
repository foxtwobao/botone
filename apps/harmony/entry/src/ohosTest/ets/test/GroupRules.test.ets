// M8 group-rules: the group row's per-entry member decode (decodeGroupWithMembers). The default
// name's fixture replay lives on the vitest side (contract/group-rules-port.test.ts), which
// compares the port with the real contracts function; repeating it here would run the same
// branch once more. Pure logic, no network.
import { describe, expect, it } from '@ohos/hypium';
import { decodeGroupWithMembers } from '../../../main/ets/contract/decode-groups';

const GROUP_HEAD = '"id":"g1","name":"Team","pinned":false,"unread":false,"preview":""'
  + ',"updatedAt":"2026-11-21T10:00:00.000Z"';

export default function groupRulesTest() {
  describe('GroupMemberDecode', () => {
    it('members_decode_identity_only', 0, () => {
      // avatarSet and status are on the wire but not in this view; the port ignores them.
      const group = decodeGroupWithMembers(JSON.parse(`{${GROUP_HEAD},"members":[`
        + '{"botId":"b1","name":"Alpha","color":"#3EC5A8",'
        + '"avatarSet":{"kind":"initial","color":"#3EC5A8"},"status":"running"},'
        + '{"botId":"b2","name":"Beta","color":"#F5A03C"}]}'));
      expect(group !== null).assertTrue();
      expect(group!.members.length).assertEqual(2);
      expect(group!.members[0].botId).assertEqual('b1');
      expect(group!.members[0].name).assertEqual('Alpha');
      expect(group!.members[1].color).assertEqual('#F5A03C');
    });

    it('an_absent_members_field_reads_as_none', 0, () => {
      const group = decodeGroupWithMembers(JSON.parse(`{${GROUP_HEAD}}`));
      expect(group !== null).assertTrue();
      expect(group!.members.length).assertEqual(0);
    });

    it('a_members_field_of_another_type_fails_the_row', 0, () => {
      expect(decodeGroupWithMembers(JSON.parse(`{${GROUP_HEAD},"members":"none"}`))).assertNull();
    });

    it('a_bad_entry_is_dropped_without_failing_its_group', 0, () => {
      const group = decodeGroupWithMembers(JSON.parse(`{${GROUP_HEAD},"members":[`
        + '{"botId":"b1","name":"Alpha","color":"#3EC5A8"},'
        + '{"botId":"bad"},{"name":"No id","color":"#fff"},"nope"]}'));
      expect(group !== null).assertTrue();
      expect(group!.members.length).assertEqual(1);
      expect(group!.members[0].botId).assertEqual('b1');
    });
  });
}