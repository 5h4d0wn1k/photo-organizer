import 'package:flutter_test/flutter_test.dart';
import 'package:private_gallery_app/src/models/device_group_invite.dart';

void main() {
  test('round trips a LAN device group invite', () {
    final expiresAt = DateTime.utc(2026, 5, 15, 12);
    final invite = DeviceGroupInvite.lan(
      groupId: 'vault-1',
      groupName: 'Family Vault',
      baseUrl: 'http://10.0.0.5:4821',
      pairingToken: 'private-gallery-mobile-v1',
      vaultId: 'vault-1',
      expiresAt: expiresAt,
    );

    final parsed = DeviceGroupInvite.parse(invite.encode());

    expect(parsed.isLan, isTrue);
    expect(parsed.supportsLan, isTrue);
    expect(parsed.supportsCloud, isFalse);
    expect(parsed.groupId, 'vault-1');
    expect(parsed.groupName, 'Family Vault');
    expect(parsed.baseUrl, 'http://10.0.0.5:4821');
    expect(parsed.pairingToken, 'private-gallery-mobile-v1');
    expect(parsed.vaultId, 'vault-1');
    expect(parsed.expiresAt, expiresAt);
  });

  test('keeps raw legacy pairing tokens usable', () {
    final invite = DeviceGroupInvite.parse('private-gallery-mobile-v1');

    expect(invite.isLan, isTrue);
    expect(invite.groupName, 'Private Gallery');
    expect(invite.pairingToken, 'private-gallery-mobile-v1');
  });

  test('round trips a cloud invite', () {
    final invite = DeviceGroupInvite.cloud(
      groupId: 'group-1',
      groupName: 'Family Vault',
      cloudInviteId: 'invite-1',
      cloudInviteSecret: 'secret-1',
      expiresAt: DateTime.utc(2026, 6, 1, 12),
    );

    final parsed = DeviceGroupInvite.parse(invite.encode());

    expect(parsed.isCloud, isTrue);
    expect(parsed.supportsCloud, isTrue);
    expect(parsed.groupId, 'group-1');
    expect(parsed.cloudInviteId, 'invite-1');
    expect(parsed.cloudInviteSecret, 'secret-1');
  });

  test('round trips a hybrid invite', () {
    final invite = DeviceGroupInvite.hybrid(
      groupId: 'group-1',
      groupName: 'Family Vault',
      baseUrl: 'http://10.0.0.5:4821',
      pairingToken: 'pair-token',
      cloudInviteId: 'invite-1',
      cloudInviteSecret: 'secret-1',
      expiresAt: DateTime.utc(2026, 6, 1, 12),
    );

    final parsed = DeviceGroupInvite.parse(invite.encode());

    expect(parsed.isHybrid, isTrue);
    expect(parsed.supportsLan, isTrue);
    expect(parsed.supportsCloud, isTrue);
    expect(parsed.vaultId, 'group-1');
    expect(parsed.baseUrl, 'http://10.0.0.5:4821');
  });

  test('rejects malformed structured invites', () {
    expect(
      () => DeviceGroupInvite.parse('{"type":"other"}'),
      throwsFormatException,
    );
    expect(
      () => DeviceGroupInvite.parse(
        '{"type":"private_gallery_device_group_invite","version":2}',
      ),
      throwsFormatException,
    );
    expect(
      () => DeviceGroupInvite.parse(
        '{"type":"private_gallery_device_group_invite","mode":"cloud","group_id":"g"}',
      ),
      throwsFormatException,
    );
  });

  test('flags expired invites', () {
    final invite = DeviceGroupInvite.cloud(
      groupId: 'group-1',
      groupName: 'Family Vault',
      cloudInviteId: 'invite-1',
      cloudInviteSecret: 'secret-1',
      expiresAt: DateTime.utc(2020, 1, 1),
    );

    expect(DeviceGroupInvite.parse(invite.encode()).isExpired, isTrue);
  });
}
