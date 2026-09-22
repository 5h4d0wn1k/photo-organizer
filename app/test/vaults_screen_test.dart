import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:private_gallery_app/src/features/vaults/vaults_screen.dart';
import 'package:private_gallery_app/src/models/gallery_models.dart';
import 'package:private_gallery_app/src/repositories/gallery_repository.dart';

void main() {
  testWidgets('vaults screen previews and runs protection repair', (
    WidgetTester tester,
  ) async {
    final repository = _FakeVaultRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: VaultsScreen(repository: repository)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Protection repair'), findsOneWidget);
    expect(find.text('Under-replicated'), findsOneWidget);
    expect(find.text('Runnable transfers'), findsOneWidget);
    expect(find.text('Needs repair'), findsWidgets);
    expect(
      find.text('1 transfer is ready for encrypted LAN repair.'),
      findsOneWidget,
    );

    await tester.tap(
      find.widgetWithText(OutlinedButton, 'Preview repair').first,
    );
    await tester.pumpAndSettle();
    expect(repository.planRequests, 2);

    final runRepair = find.widgetWithText(FilledButton, 'Run repair');
    await tester.ensureVisible(runRepair);
    await tester.pumpAndSettle();
    await tester.tap(runRepair);
    await tester.pumpAndSettle();

    expect(repository.runRequests, 1);
  });
}

class _FakeVaultRepository implements GalleryRepository {
  var planRequests = 0;
  var runRequests = 0;

  @override
  Future<List<Vault>> fetchVaults() async => [_vault()];

  @override
  Future<VaultStatus> fetchVaultStatus(String id) async {
    return VaultStatus.fromJson({
      'vault': _vaultJson(),
      'members': [
        {
          'id': 'member-1',
          'vault_id': 'vault-1',
          'device_id': 'device-1',
          'role': 'admin',
          'trust_level': 'trusted',
          'display_name': 'Laptop',
          'added_at': '2026-05-13T06:00:00Z',
          'revoked_at': null,
        },
      ],
      'devices': [_deviceJson()],
      'assets_total': 1,
      'blobs_total': 1,
      'local_available_assets': 1,
      'remote_available_assets': 0,
      'under_replicated_blobs': 1,
      'missing_blobs': 0,
      'policy_satisfied': false,
      'detail': 'one encrypted chunk needs another replica',
    });
  }

  @override
  Future<List<DeviceIdentity>> fetchDevices() async {
    return [
      DeviceIdentity.fromJson(_deviceJson()),
      DeviceIdentity.fromJson(
        _deviceJson(
          id: 'device-2',
          displayName: 'NAS',
          trustLevel: 'storage_only',
        ),
      ),
    ];
  }

  @override
  Future<List<SyncTransfer>> fetchSyncTransfers() async {
    return [SyncTransfer.fromJson(_transferJson())];
  }

  @override
  Future<SyncNetworkStatus> fetchSyncNetworkStatus() async {
    return SyncNetworkStatus.fromJson({
      'started': true,
      'transport': 'iroh-quic-v1',
      'local_device_id': 'device-1',
      'local_node_id': 'node-1',
      'direct_addresses': ['192.168.1.10:4821'],
      'relay_urls': [],
      'active_transfer_count': 0,
      'pending_transfer_count': 1,
      'completed_transfer_count': 0,
      'failed_transfer_count': 0,
      'detail': 'P2P sync is listening',
    });
  }

  @override
  Future<SyncPlan> fetchSyncPlan({String? vaultId}) async {
    planRequests += 1;
    return _syncPlan(executed: false);
  }

  @override
  Future<SyncPlan> runSync({String? vaultId, bool dryRun = false}) async {
    runRequests += 1;
    return _syncPlan(executed: true);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Vault _vault() => Vault.fromJson(_vaultJson());

SyncPlan _syncPlan({required bool executed}) {
  return SyncPlan.fromJson({
    'generated_at': '2026-05-13T06:00:00Z',
    'vault_ids': ['vault-1'],
    'transfers': [_transferJson()],
    'conflicts': [],
    'under_replicated_blob_ids': ['blob-1'],
    'policy_satisfied': false,
    'detail': '1 transfer is ready for encrypted LAN repair.',
    'execution_results': executed
        ? [
            {
              'transfer_id': 'transfer-1',
              'blob_id': 'blob-1',
              'from_device_id': 'device-1',
              'to_device_id': 'device-2',
              'status': 'completed',
              'bytes_transferred': 2048,
              'detail': 'encrypted chunks verified by remote peer',
            },
          ]
        : [],
  });
}

Map<String, Object?> _vaultJson() {
  return {
    'id': 'vault-1',
    'name': 'Family vault',
    'storage_policy': {
      'mode': 'protected_min_2',
      'min_replicas': 2,
      'preferred_device_ids': [],
      'excluded_device_ids': [],
      'min_free_space_bytes': 1024,
      'allow_metered_network': false,
      'pause_on_low_battery': true,
    },
    'key_version': 1,
    'deletion_grace_days': 30,
    'created_at': '2026-05-13T06:00:00Z',
    'updated_at': '2026-05-13T06:00:00Z',
  };
}

Map<String, Object?> _deviceJson({
  String id = 'device-1',
  String displayName = 'Laptop',
  String trustLevel = 'trusted',
}) {
  return {
    'id': id,
    'display_name': displayName,
    'platform': id == 'device-1' ? 'linux' : 'storage',
    'public_key': '$id-key',
    'trust_level': trustLevel,
    'storage_profile': {
      'device_id': id,
      'total_bytes': 100000,
      'available_bytes': 90000,
      'reserved_bytes': 1024,
      'accepts_storage': true,
      'battery_powered': false,
      'metered_network': false,
      'low_battery': false,
    },
    'enrolled_at': '2026-05-13T06:00:00Z',
    'last_seen_at': '2026-05-13T06:00:00Z',
    'revoked_at': null,
  };
}

Map<String, Object?> _transferJson() {
  return {
    'id': 'transfer-1',
    'vault_id': 'vault-1',
    'blob_id': 'blob-1',
    'from_device_id': 'device-1',
    'to_device_id': 'device-2',
    'status': 'pending',
    'bytes_total': 2048,
    'bytes_completed': 0,
    'started_at': null,
    'updated_at': '2026-05-13T06:00:00Z',
    'resumable_until': '2026-05-20T06:00:00Z',
  };
}
