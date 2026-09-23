import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/device_group_invite.dart';

class CloudBootstrapConfig {
  const CloudBootstrapConfig({
    required this.url,
    required this.anonKey,
  });

  final String url;
  final String anonKey;

  bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;

  static const fromEnvironment = CloudBootstrapConfig(
    url: String.fromEnvironment('PRIVATE_GALLERY_SUPABASE_URL'),
    anonKey: String.fromEnvironment('PRIVATE_GALLERY_SUPABASE_ANON_KEY'),
  );
}

abstract class CloudBootstrapGateway {
  bool get isConfigured;

  Future<CloudDeviceGroup?> loadSavedGroup();

  Future<CloudDeviceGroup> createGroup({
    required String groupName,
    required String deviceName,
    required String platform,
  });

  Future<DeviceGroupInvite> createInvite({
    required CloudDeviceGroup group,
  });

  Future<CloudDeviceGroup> joinGroup({
    required DeviceGroupInvite invite,
    required String deviceName,
    required String platform,
  });
}

class CloudBootstrapService implements CloudBootstrapGateway {
  CloudBootstrapService({
    CloudBootstrapConfig config = CloudBootstrapConfig.fromEnvironment,
  }) : _config = config;

  static const _storage = FlutterSecureStorage();
  static const _groupIdKey = 'private_gallery.cloud_group_id';
  static const _groupNameKey = 'private_gallery.cloud_group_name';
  static const _deviceIdKey = 'private_gallery.cloud_device_id';

  final CloudBootstrapConfig _config;

  @override
  bool get isConfigured => _config.isConfigured;

  SupabaseClient get _client => Supabase.instance.client;

  static Future<void> initializeIfConfigured({
    CloudBootstrapConfig config = CloudBootstrapConfig.fromEnvironment,
  }) async {
    if (!config.isConfigured) {
      return;
    }
    await Supabase.initialize(
      url: config.url,
      publishableKey: config.anonKey,
      authOptions: const FlutterAuthClientOptions(
        localStorage: _SecureSupabaseStorage(),
      ),
    );
  }

  @override
  Future<CloudDeviceGroup?> loadSavedGroup() async {
    final id = await _storage.read(key: _groupIdKey);
    final name = await _storage.read(key: _groupNameKey);
    if (id == null || id.isEmpty || name == null || name.isEmpty) {
      return null;
    }
    return CloudDeviceGroup(id: id, name: name);
  }

  @override
  Future<CloudDeviceGroup> createGroup({
    required String groupName,
    required String deviceName,
    required String platform,
  }) async {
    _requireConfigured();
    await _ensureSession();
    final deviceId = await _loadOrCreateDeviceId();
    final group = await _client
        .from('device_groups')
        .insert({
          'name': groupName.trim().isEmpty ? 'My Private Gallery' : groupName,
        })
        .select()
        .single();
    final groupId = group['id'].toString();
    final created = CloudDeviceGroup(
      id: groupId,
      name: group['name']?.toString() ?? groupName,
    );
    await _client.from('device_group_devices').insert({
      'group_id': groupId,
      'client_device_id': deviceId,
      'display_name': deviceName.trim().isEmpty ? 'This device' : deviceName,
      'platform': platform,
      'role': 'owner',
      'capability': 'metadata_only',
    });
    await _saveGroup(created);
    return created;
  }

  @override
  Future<DeviceGroupInvite> createInvite({
    required CloudDeviceGroup group,
  }) async {
    _requireConfigured();
    await _ensureSession();
    final secret = _randomToken();
    final secretHash = sha256.convert(secret.codeUnits).toString();
    final expiresAt = DateTime.now().toUtc().add(const Duration(minutes: 10));
    final invite = await _client
        .from('device_group_invites')
        .insert({
          'group_id': group.id,
          'secret_hash': secretHash,
          'role': 'member',
          'capability': 'metadata_only',
          'expires_at': expiresAt.toIso8601String(),
        })
        .select('id')
        .single();
    return DeviceGroupInvite.cloud(
      groupId: group.id,
      groupName: group.name,
      cloudInviteId: invite['id'].toString(),
      cloudInviteSecret: secret,
      expiresAt: expiresAt,
    );
  }

  @override
  Future<CloudDeviceGroup> joinGroup({
    required DeviceGroupInvite invite,
    required String deviceName,
    required String platform,
  }) async {
    _requireConfigured();
    if (!invite.supportsCloud ||
        invite.cloudInviteId == null ||
        invite.cloudInviteSecret == null) {
      throw const CloudBootstrapException('Scan a valid cloud group invite.');
    }
    if (invite.isExpired) {
      throw const CloudBootstrapException('This invite expired.');
    }
    await _ensureSession();
    final deviceId = await _loadOrCreateDeviceId();
    final response = await _client.rpc(
      'claim_device_group_invite',
      params: {
        'p_invite_id': invite.cloudInviteId!,
        'p_invite_secret': invite.cloudInviteSecret!,
        'p_client_device_id': deviceId,
        'p_display_name':
            deviceName.trim().isEmpty ? 'This device' : deviceName.trim(),
        'p_platform': platform,
      },
    ).single();
    final row = Map<String, dynamic>.from(response as Map);
    final groupId = row['group_id'].toString();
    final groupName = row['group_name']?.toString() ?? invite.groupName;
    final group = CloudDeviceGroup(id: groupId, name: groupName);
    await _saveGroup(group);
    return group;
  }

  Future<void> _ensureSession() async {
    if (_client.auth.currentSession != null) {
      return;
    }
    await _client.auth.signInAnonymously();
  }

  void _requireConfigured() {
    if (!isConfigured) {
      throw const CloudBootstrapException(
        'Cloud bootstrap is not configured in this build. Create a local group on the desktop, then scan its invite QR.',
      );
    }
  }

  Future<void> _saveGroup(CloudDeviceGroup group) async {
    await _storage.write(key: _groupIdKey, value: group.id);
    await _storage.write(key: _groupNameKey, value: group.name);
  }

  Future<String> _loadOrCreateDeviceId() async {
    final existing = await _storage.read(key: _deviceIdKey);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    final created = 'pgd_${_randomToken()}';
    await _storage.write(key: _deviceIdKey, value: created);
    return created;
  }

  String _randomToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}

class CloudDeviceGroup {
  const CloudDeviceGroup({
    required this.id,
    required this.name,
  });

  final String id;
  final String name;
}

class CloudBootstrapException implements Exception {
  const CloudBootstrapException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _SecureSupabaseStorage extends LocalStorage {
  const _SecureSupabaseStorage();

  static const _storage = FlutterSecureStorage();
  static const _key = 'private_gallery.supabase_session';

  @override
  Future<void> initialize() async {}

  @override
  Future<String?> accessToken() {
    return _storage.read(key: _key);
  }

  @override
  Future<bool> hasAccessToken() {
    return _storage.containsKey(key: _key);
  }

  @override
  Future<void> persistSession(String persistSessionString) {
    return _storage.write(key: _key, value: persistSessionString);
  }

  @override
  Future<void> removePersistedSession() {
    return _storage.delete(key: _key);
  }
}
