import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:private_gallery_app/src/api/local_api_client.dart';
import 'package:private_gallery_app/src/models/gallery_models.dart';

void main() {
  test('uses a longer timeout for large timeline reads', () async {
    final client = LocalApiClient(
      httpClient: _DelayedJsonClient(
        delay: const Duration(milliseconds: 25),
        bodyForPath: (_) => {'buckets': <Object>[]},
      ),
      defaultTimeout: const Duration(milliseconds: 5),
      heavyReadTimeout: const Duration(milliseconds: 100),
    );

    final timeline = await client.fetchTimeline();

    expect(timeline.buckets, isEmpty);
  });

  test('keeps quick health checks on the default timeout', () async {
    final client = LocalApiClient(
      httpClient: _DelayedJsonClient(
        delay: const Duration(milliseconds: 25),
        bodyForPath: (_) => {'status': 'ok'},
      ),
      defaultTimeout: const Duration(milliseconds: 5),
      heavyReadTimeout: const Duration(milliseconds: 100),
    );

    expect(
      client.fetchHealth(),
      throwsA(isA<SocketException>()),
    );
  });

  test('uses explicit job detail, log, cancel, and retry endpoints', () async {
    final client = LocalApiClient(
      httpClient: _JobJsonClient(),
      baseUri: Uri.parse('http://127.0.0.1:4821'),
    );

    final job = await client.fetchJob('job-1');
    final logs = await client.fetchJobLogs('job-1');
    final canceled = await client.cancelJob('job-1');
    final retry = await client.retryJob('job-1');
    final scenes = await client.rebuildScenes(limit: 10);

    expect(job.id, 'job-1');
    expect(logs.single.message, 'job started');
    expect(canceled.status, 'canceled');
    expect(retry.retryOfJobId, 'job-1');
    expect(scenes.kind, 'scene_index');
  });

  test('uses confirm-gated local model import and verify endpoints', () async {
    final client = LocalApiClient(
      httpClient: _ModelJsonClient(),
      baseUri: Uri.parse('http://127.0.0.1:4821'),
    );

    final imported = await client.importLocalModel(
      id: 'scrfd-face-detector',
      localPath: '/tmp/model.onnx',
      expectedSha256: 'abc123',
      confirmed: true,
    );
    final verified = await client.verifyModel('scrfd-face-detector');
    final runtime = await client.fetchModelRuntimeStatus();

    expect(imported.installedPath, '/tmp/model.onnx');
    expect(verified.installedSha256, 'abc123');
    expect(runtime.ok, isTrue);
    expect(runtime.offlineReady, isTrue);
  });

  test('uses manual people creation and asset assignment endpoints', () async {
    final client = LocalApiClient(
      httpClient: _PeopleJsonClient(),
      baseUri: Uri.parse('http://127.0.0.1:4821'),
    );

    final created = await client.createManualPerson(
      displayName: 'Mom',
      assetIds: const ['asset-1'],
    );
    final assets = await client.fetchPersonAssets('person-1');
    final updated = await client.addPersonAssets(
      'person-1',
      assetIds: const ['asset-2'],
    );
    final removed = await client.removePersonAssets(
      'person-1',
      assetIds: const ['asset-1'],
    );

    expect(created.displayName, 'Mom');
    expect(assets.single.id, 'asset-1');
    expect(updated.assetIds, ['asset-1', 'asset-2']);
    expect(removed.assetIds, ['asset-2']);
  });

  test('uses organization asset detail endpoints', () async {
    final client = LocalApiClient(
      httpClient: _OrganizationJsonClient(),
      baseUri: Uri.parse('http://127.0.0.1:4821'),
    );

    final placeAssets = await client.fetchPlaceAssets('place-1');
    final eventAssets = await client.fetchEventAssets('event-1');

    expect(placeAssets.single.id, 'asset-1');
    expect(eventAssets.single.originalFilename, 'a.jpg');
  });

  test('updates local-only asset curation flags', () async {
    final client = LocalApiClient(
      httpClient: _AssetFlagsJsonClient(),
      baseUri: Uri.parse('http://127.0.0.1:4821'),
    );

    final updated = await client.updateAssetFlags(
      'asset-1',
      favorite: true,
      archived: true,
    );
    final bulkUpdated = await client.updateAssetsFlags(
      const ['asset-1', 'asset-2'],
      favorite: true,
    );
    final favorites = await client.fetchFavoriteAssets();
    final archived = await client.fetchArchivedAssets();

    expect(updated.favorite, isTrue);
    expect(updated.archived, isTrue);
    expect(bulkUpdated, hasLength(1));
    expect(bulkUpdated.single.favorite, isTrue);
    expect(favorites.single.favorite, isTrue);
    expect(archived.single.archived, isTrue);
  });

  test('uses manual album endpoints', () async {
    final client = LocalApiClient(
      httpClient: _AlbumJsonClient(),
      baseUri: Uri.parse('http://127.0.0.1:4821'),
    );

    final created = await client.createAlbum(
      title: 'Family',
      assetIds: const ['asset-1'],
    );
    final albums = await client.fetchAlbums();
    final assets = await client.fetchAlbumAssets('album-1');
    final added = await client.addAlbumAssets(
      'album-1',
      assetIds: const ['asset-2'],
    );
    final removed = await client.removeAlbumAssets(
      'album-1',
      assetIds: const ['asset-1'],
    );
    final renamed = await client.renameAlbum('album-1', 'Family trip');
    await client.deleteAlbum('album-1');

    expect(created.assetIds, ['asset-1']);
    expect(albums.single.title, 'Family');
    expect(assets.single.id, 'asset-1');
    expect(added.assetIds, ['asset-1', 'asset-2']);
    expect(removed.assetIds, ['asset-2']);
    expect(renamed.title, 'Family trip');
  });

  test('uses distributed vault device and sync endpoints', () async {
    final client = LocalApiClient(
      httpClient: _VaultSyncJsonClient(),
      baseUri: Uri.parse('http://127.0.0.1:4821'),
    );
    const policy = StoragePolicy(
      mode: StoragePolicyMode.protectedMin2,
      minReplicas: 2,
      preferredDeviceIds: [],
      excludedDeviceIds: [],
      minFreeSpaceBytes: 1024,
      allowMeteredNetwork: false,
      pauseOnLowBattery: true,
    );

    final vault =
        await client.createVault(name: 'Family', storagePolicy: policy);
    final vaults = await client.fetchVaults();
    final status = await client.fetchVaultStatus('vault-1');
    final updated = await client.updateVaultStoragePolicy('vault-1', policy);
    final device = await client.enrollDevice(
      displayName: 'NAS',
      platform: 'linux',
      publicKey: 'nas-key',
      trustLevel: DeviceTrustLevel.storageOnly,
      role: DeviceRole.storageOnly,
    );
    final devices = await client.fetchDevices();
    final plan = await client.fetchSyncPlan(vaultId: 'vault-1');
    final runPlan = await client.runSync(vaultId: 'vault-1');
    final transfers = await client.fetchSyncTransfers();
    final availability = await client.fetchAssetAvailability('asset-1');
    final pinned = await client.pinLocalAsset('asset-1');
    final evicted = await client.evictLocalAsset('asset-1');
    final revoked = await client.revokeDevice('device-2', reason: 'lost');

    expect(vault.name, 'Family');
    expect(vaults.single.id, 'vault-1');
    expect(status.underReplicatedBlobs, 1);
    expect(updated.storagePolicy.minReplicas, 2);
    expect(device.trustLevel, DeviceTrustLevel.storageOnly);
    expect(devices, hasLength(2));
    expect(plan.transfers.single.status, SyncTransferStatus.pending);
    expect(runPlan.policySatisfied, isFalse);
    expect(transfers.single.toDeviceId, 'device-2');
    expect(availability.state, AssetAvailabilityState.underReplicated);
    expect(pinned.state, AssetAvailabilityState.transferPending);
    expect(evicted.state, AssetAvailabilityState.remoteAvailable);
    expect(revoked.revoked, isTrue);
  });
}

class _DelayedJsonClient extends http.BaseClient {
  _DelayedJsonClient({
    required this.delay,
    required this.bodyForPath,
  });

  final Duration delay;
  final Map<String, Object?> Function(String path) bodyForPath;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await Future<void>.delayed(delay);
    final bytes = utf8.encode(jsonEncode(bodyForPath(request.url.path)));
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      HttpStatus.ok,
      headers: const {'content-type': 'application/json'},
    );
  }
}

class _JobJsonClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    final body = switch ((request.method, path)) {
      ('GET', '/jobs/job-1') => _jobJson(status: 'failed'),
      ('GET', '/jobs/job-1/logs') => [
          {
            'id': 'log-1',
            'job_id': 'job-1',
            'level': 'info',
            'message': 'job started',
            'created_at': '2026-05-13T06:00:00Z',
          }
        ],
      ('POST', '/jobs/job-1/cancel') => _jobJson(status: 'canceled'),
      ('POST', '/jobs/job-1/retry') => _jobJson(
          id: 'job-2',
          status: 'queued',
          retryOfJobId: 'job-1',
        ),
      ('POST', '/scenes/rebuild') =>
        _jobJson(status: 'completed', kind: 'scene_index'),
      _ => throw StateError('Unexpected ${request.method} $path'),
    };
    final bytes = utf8.encode(jsonEncode(body));
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      HttpStatus.ok,
      headers: const {'content-type': 'application/json'},
    );
  }
}

class _ModelJsonClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    final body = switch ((request.method, path)) {
      ('GET', '/models/runtime-status') => _runtimeJson(),
      ('POST', '/models/import-local') => _modelJson(),
      ('POST', '/models/scrfd-face-detector/verify') => _modelJson(),
      _ => throw StateError('Unexpected ${request.method} $path'),
    };
    final bytes = utf8.encode(jsonEncode(body));
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      HttpStatus.ok,
      headers: const {'content-type': 'application/json'},
    );
  }
}

Map<String, Object?> _runtimeJson() {
  return {
    'ok': true,
    'runtime': 'python-sidecar',
    'sidecar_path': '/tmp/private_gallery_ml_sidecar.py',
    'python_executable': '/usr/bin/python3',
    'python_version': '3.12.0',
    'offline_ready': true,
    'dependencies': [
      {'name': 'numpy', 'available': true, 'version': null},
    ],
    'detail': 'sidecar probe completed',
  };
}

class _PeopleJsonClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    final body = switch ((request.method, path)) {
      ('POST', '/people/manual') => _personJson(['asset-1']),
      ('GET', '/people/person-1/assets') => [_assetJson()],
      ('POST', '/people/person-1/assets') => _personJson([
          'asset-1',
          'asset-2',
        ]),
      ('POST', '/people/person-1/assets/remove') => _personJson(['asset-2']),
      _ => throw StateError('Unexpected ${request.method} $path'),
    };
    final bytes = utf8.encode(jsonEncode(body));
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      HttpStatus.ok,
      headers: const {'content-type': 'application/json'},
    );
  }
}

class _OrganizationJsonClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    final body = switch ((request.method, path)) {
      ('GET', '/places/place-1/assets') => [_assetJson()],
      ('GET', '/events/event-1/assets') => [_assetJson()],
      _ => throw StateError('Unexpected ${request.method} $path'),
    };
    final bytes = utf8.encode(jsonEncode(body));
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      HttpStatus.ok,
      headers: const {'content-type': 'application/json'},
    );
  }
}

class _AssetFlagsJsonClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    final asset = _assetJson()
      ..['favorite'] = true
      ..['archived'] = true;
    final body = switch ((request.method, path)) {
      ('POST', '/assets/asset-1/flags') => asset,
      ('POST', '/assets/flags/bulk') => [asset],
      ('GET', '/assets/favorites') => [asset],
      ('GET', '/assets/archived') => [asset],
      _ => throw StateError('Unexpected ${request.method} $path'),
    };
    if (request.method == 'POST') {
      final streamed = request as http.Request;
      final payload = jsonDecode(streamed.body) as Map<String, Object?>;
      expect(payload['favorite'], isTrue);
      if (path == '/assets/asset-1/flags') {
        expect(payload['archived'], isTrue);
      } else {
        expect(payload['asset_ids'], ['asset-1', 'asset-2']);
      }
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(body))),
      HttpStatus.ok,
      headers: const {'content-type': 'application/json'},
    );
  }
}

class _AlbumJsonClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    final body = switch ((request.method, path)) {
      ('GET', '/albums') => [
          _albumJson(['asset-1'])
        ],
      ('POST', '/albums') => _albumJson(['asset-1']),
      ('GET', '/albums/album-1/assets') => [_assetJson()],
      ('POST', '/albums/album-1/assets') => _albumJson([
          'asset-1',
          'asset-2',
        ]),
      ('POST', '/albums/album-1/assets/remove') => _albumJson(['asset-2']),
      ('POST', '/albums/album-1/rename') => _albumJson(
          ['asset-1'],
          title: 'Family trip',
        ),
      ('DELETE', '/albums/album-1') => null,
      _ => throw StateError('Unexpected ${request.method} $path'),
    };
    final bytes = utf8.encode(jsonEncode(body));
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      request.method == 'DELETE' ? HttpStatus.noContent : HttpStatus.ok,
      headers: const {'content-type': 'application/json'},
    );
  }
}

class _VaultSyncJsonClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    final body = switch ((request.method, path)) {
      ('GET', '/vaults') => [_vaultJson()],
      ('POST', '/vaults') => _vaultJson(name: 'Family'),
      ('GET', '/vaults/vault-1/status') => _vaultStatusJson(),
      ('POST', '/vaults/vault-1/storage-policy') => _vaultJson(),
      ('GET', '/devices') => [_deviceJson(), _deviceJson(id: 'device-2')],
      ('POST', '/devices/enroll') => _deviceJson(
          id: 'device-2',
          displayName: 'NAS',
          trustLevel: 'storage_only',
        ),
      ('POST', '/devices/device-2/revoke') => _deviceJson(
          id: 'device-2',
          displayName: 'NAS',
          trustLevel: 'storage_only',
          revoked: true,
        ),
      ('GET', '/sync/plan') => _syncPlanJson(),
      ('POST', '/sync/run') => _syncPlanJson(),
      ('GET', '/sync/transfers') => [_transferJson()],
      ('GET', '/assets/asset-1/availability') => _availabilityJson(),
      ('POST', '/assets/asset-1/pin-local') =>
        _availabilityJson(state: 'transfer_pending'),
      ('POST', '/assets/asset-1/evict-local') => _availabilityJson(
          state: 'remote_available',
          localReplica: false,
          replicaCount: 2,
        ),
      _ => throw StateError('Unexpected ${request.method} $path'),
    };

    if (request.method == 'GET' && path == '/sync/plan') {
      expect(request.url.queryParameters['vault_id'], 'vault-1');
    }
    if (request.method == 'POST' && path == '/sync/run') {
      final streamed = request as http.Request;
      final payload = jsonDecode(streamed.body) as Map<String, Object?>;
      expect(payload['vault_id'], 'vault-1');
      expect(payload['dry_run'], isFalse);
    }

    final bytes = utf8.encode(jsonEncode(body));
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      HttpStatus.ok,
      headers: const {'content-type': 'application/json'},
    );
  }
}

Map<String, Object?> _storagePolicyJson() {
  return {
    'mode': 'protected_min_2',
    'min_replicas': 2,
    'preferred_device_ids': [],
    'excluded_device_ids': [],
    'min_free_space_bytes': 1024,
    'allow_metered_network': false,
    'pause_on_low_battery': true,
  };
}

Map<String, Object?> _vaultJson({String name = 'Personal vault'}) {
  return {
    'id': 'vault-1',
    'name': name,
    'storage_policy': _storagePolicyJson(),
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
  bool revoked = false,
}) {
  return {
    'id': id,
    'display_name': displayName,
    'platform': 'linux',
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
    'last_seen_at': revoked ? null : '2026-05-13T06:00:00Z',
    'revoked_at': revoked ? '2026-05-13T06:05:00Z' : null,
  };
}

Map<String, Object?> _vaultStatusJson() {
  return {
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
      }
    ],
    'devices': [_deviceJson()],
    'assets_total': 1,
    'blobs_total': 1,
    'local_available_assets': 1,
    'remote_available_assets': 0,
    'under_replicated_blobs': 1,
    'missing_blobs': 0,
    'policy_satisfied': false,
    'detail': 'local control plane',
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
    'bytes_total': 100,
    'bytes_completed': 0,
    'started_at': null,
    'updated_at': '2026-05-13T06:00:00Z',
    'resumable_until': '2026-05-20T06:00:00Z',
  };
}

Map<String, Object?> _syncPlanJson() {
  return {
    'generated_at': '2026-05-13T06:00:00Z',
    'vault_ids': ['vault-1'],
    'transfers': [_transferJson()],
    'conflicts': [],
    'under_replicated_blob_ids': ['blob-1'],
    'policy_satisfied': false,
    'detail': 'pending P2P transfer',
  };
}

Map<String, Object?> _availabilityJson({
  String state = 'under_replicated',
  bool localReplica = true,
  int replicaCount = 1,
}) {
  return {
    'asset_id': 'asset-1',
    'vault_id': 'vault-1',
    'state': state,
    'local_replica': localReplica,
    'reachable_replica_device_ids': ['device-2'],
    'offline_replica_device_ids': [],
    'replica_count': replicaCount,
    'required_replica_count': 2,
    'detail': 'replica status',
  };
}

Map<String, Object?> _assetJson() {
  return {
    'id': 'asset-1',
    'original_filename': 'a.jpg',
    'relative_original_path': 'originals/2026/05/a.jpg',
    'source_path': '/tmp/a.jpg',
    'import_mode': 'reference',
    'is_available': true,
    'content_hash': 'hash-a',
    'media_kind': 'photo',
    'bytes': 100,
    'mime_type': 'image/jpeg',
    'captured_at': '2026-05-13T06:00:00Z',
    'imported_at': '2026-05-13T06:01:00Z',
    'archived': false,
    'favorite': false,
    'place_hint': null,
    'variants': [],
  };
}

Map<String, Object?> _albumJson(
  List<String> assetIds, {
  String title = 'Family',
}) {
  return {
    'id': 'album-1',
    'title': title,
    'asset_ids': assetIds,
    'cover_asset_id': assetIds.isEmpty ? null : assetIds.first,
    'created_at': '2026-05-13T06:00:00Z',
    'updated_at': '2026-05-13T06:00:00Z',
  };
}

Map<String, Object?> _jobJson({
  String id = 'job-1',
  required String status,
  String? retryOfJobId,
  String kind = 'ocr_index',
}) {
  return {
    'id': id,
    'kind': kind,
    'status': status,
    'progress': status == 'completed' ? 100 : 25,
    'queued_at': '2026-05-13T06:00:00Z',
    'started_at': '2026-05-13T06:00:10Z',
    'completed_at': status == 'running' || status == 'queued'
        ? null
        : '2026-05-13T06:01:00Z',
    'detail': 'job detail',
    'cancel_requested': false,
    'retry_of_job_id': retryOfJobId,
    'attempt': retryOfJobId == null ? 1 : 2,
  };
}

Map<String, Object?> _modelJson() {
  return {
    'id': 'scrfd-face-detector',
    'name': 'SCRFD face detector candidate',
    'version': 'onnx-personal-review',
    'task': 'face_detection',
    'license': 'license review required',
    'source_url': 'https://example.invalid/model',
    'expected_sha256': 'abc123',
    'installed_path': '/tmp/model.onnx',
    'installed_sha256': 'abc123',
    'install_status': 'installed',
    'review_notes': 'local test model',
    'approved_for_personal_family_use': false,
  };
}

Map<String, Object?> _personJson(List<String> assetIds) {
  return {
    'id': 'person-1',
    'display_name': 'Mom',
    'asset_ids': assetIds,
    'face_template_ids': [],
    'representative_asset_id': assetIds.isEmpty ? null : assetIds.first,
    'hidden': false,
    'model_name': 'manual-person',
    'model_version': 'v1',
    'model_hash': null,
    'created_at': '2026-05-13T06:00:00Z',
    'rebuildable': true,
  };
}
