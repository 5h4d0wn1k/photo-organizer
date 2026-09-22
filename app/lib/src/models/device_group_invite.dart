import 'dart:convert';

class DeviceGroupInvite {
  const DeviceGroupInvite({
    required this.version,
    required this.action,
    required this.mode,
    required this.groupName,
    this.groupId,
    this.baseUrl,
    this.pairingToken,
    this.vaultId,
    this.cloudInviteId,
    this.cloudInviteSecret,
    this.expiresAt,
  });

  final int version;
  final String action;
  final String mode;
  final String groupName;
  final String? groupId;
  final String? baseUrl;
  final String? pairingToken;
  final String? vaultId;
  final String? cloudInviteId;
  final String? cloudInviteSecret;
  final DateTime? expiresAt;

  bool get isLan => mode == 'lan';
  bool get isCloud => mode == 'cloud';
  bool get isHybrid => mode == 'hybrid';
  bool get supportsLan => isLan || isHybrid;
  bool get supportsCloud => isCloud || isHybrid;
  bool get isExpired =>
      expiresAt != null && expiresAt!.isBefore(DateTime.now().toUtc());

  Map<String, Object?> toJson() {
    return {
      'type': 'private_gallery_device_group_invite',
      'version': version,
      'action': action,
      'mode': mode,
      'group_name': groupName,
      if (groupId != null) 'group_id': groupId,
      if (baseUrl != null) 'base_url': baseUrl,
      if (pairingToken != null) 'pairing_token': pairingToken,
      if (vaultId != null) 'vault_id': vaultId,
      if (cloudInviteId != null) 'cloud_invite_id': cloudInviteId,
      if (cloudInviteSecret != null) 'cloud_invite_secret': cloudInviteSecret,
      if (expiresAt != null) 'expires_at': expiresAt!.toIso8601String(),
    };
  }

  String encode() => jsonEncode(toJson());

  factory DeviceGroupInvite.lan({
    String? groupId,
    required String groupName,
    required String baseUrl,
    required String pairingToken,
    String? vaultId,
    DateTime? expiresAt,
  }) {
    return DeviceGroupInvite(
      version: 1,
      action: 'join_group',
      mode: 'lan',
      groupName: groupName,
      groupId: groupId ?? vaultId,
      baseUrl: baseUrl,
      pairingToken: pairingToken,
      vaultId: vaultId,
      expiresAt: expiresAt,
    );
  }

  factory DeviceGroupInvite.cloud({
    required String groupId,
    required String groupName,
    required String cloudInviteId,
    required String cloudInviteSecret,
    DateTime? expiresAt,
  }) {
    return DeviceGroupInvite(
      version: 1,
      action: 'join_group',
      mode: 'cloud',
      groupId: groupId,
      groupName: groupName,
      cloudInviteId: cloudInviteId,
      cloudInviteSecret: cloudInviteSecret,
      expiresAt: expiresAt,
    );
  }

  factory DeviceGroupInvite.hybrid({
    required String groupId,
    required String groupName,
    required String baseUrl,
    required String pairingToken,
    required String cloudInviteId,
    required String cloudInviteSecret,
    DateTime? expiresAt,
  }) {
    return DeviceGroupInvite(
      version: 1,
      action: 'join_group',
      mode: 'hybrid',
      groupId: groupId,
      groupName: groupName,
      baseUrl: baseUrl,
      pairingToken: pairingToken,
      vaultId: groupId,
      cloudInviteId: cloudInviteId,
      cloudInviteSecret: cloudInviteSecret,
      expiresAt: expiresAt,
    );
  }

  factory DeviceGroupInvite.fromJson(Map<String, dynamic> json) {
    final type = json['type']?.toString();
    final action = json['action']?.toString() ?? 'join_group';
    if (type != null && type != 'private_gallery_device_group_invite') {
      throw const FormatException('Unsupported invite QR.');
    }
    if (action != 'join_group') {
      throw const FormatException('Unsupported invite action.');
    }
    final version = (json['version'] as num?)?.toInt() ?? 1;
    if (version != 1) {
      throw const FormatException('Unsupported invite version.');
    }
    final mode = json['mode']?.toString() ??
        (json['cloud_invite_id'] != null ? 'cloud' : 'lan');
    if (mode != 'lan' && mode != 'cloud' && mode != 'hybrid') {
      throw const FormatException('Unsupported invite mode.');
    }
    final groupName = _readNonEmpty(json['group_name']) ?? 'Private Gallery';
    final vaultId = _readNonEmpty(json['vault_id']);
    final groupId = _readNonEmpty(json['group_id']) ?? vaultId;
    final baseUrl =
        _readNonEmpty(json['base_url']) ?? _readNonEmpty(json['desktop_url']);
    final pairingToken =
        _readNonEmpty(json['pairing_token']) ?? _readNonEmpty(json['token']);
    final cloudInviteId = _readNonEmpty(json['cloud_invite_id']);
    final cloudInviteSecret = _readNonEmpty(json['cloud_invite_secret']);
    final expiresAt = _readDate(json['expires_at']);

    if ((mode == 'lan' || mode == 'hybrid') && pairingToken == null) {
      throw const FormatException('Local invites require a token.');
    }
    if (mode == 'hybrid' && baseUrl == null) {
      throw const FormatException('Hybrid invites require a URL.');
    }
    if ((mode == 'cloud' || mode == 'hybrid') &&
        (groupId == null ||
            cloudInviteId == null ||
            cloudInviteSecret == null)) {
      throw const FormatException('Cloud invites require group and secret.');
    }

    return DeviceGroupInvite(
      version: version,
      action: action,
      mode: mode,
      groupName: groupName,
      groupId: groupId,
      baseUrl: baseUrl,
      pairingToken: pairingToken,
      vaultId: vaultId ?? groupId,
      cloudInviteId: cloudInviteId,
      cloudInviteSecret: cloudInviteSecret,
      expiresAt: expiresAt,
    );
  }

  static DeviceGroupInvite parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Invite is empty.');
    }
    if (trimmed.startsWith('{')) {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        return DeviceGroupInvite.fromJson(
          decoded.map((key, value) => MapEntry(key.toString(), value)),
        );
      }
      throw const FormatException('Invite QR must contain a JSON object.');
    }
    return DeviceGroupInvite(
      version: 1,
      action: 'join_group',
      mode: 'lan',
      groupName: 'Private Gallery',
      pairingToken: trimmed,
    );
  }
}

DateTime? _readDate(Object? value) {
  if (value == null) {
    return null;
  }
  final parsed = DateTime.tryParse(value.toString())?.toUtc();
  if (parsed == null) {
    throw const FormatException('Invite expiry is invalid.');
  }
  return parsed;
}

String? _readNonEmpty(Object? value) {
  final text = value?.toString().trim();
  if (text == null || text.isEmpty) {
    return null;
  }
  return text;
}
