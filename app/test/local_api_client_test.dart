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

    expect(client.fetchHealth(), throwsA(isA<SocketException>()));
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

  test('fetches local duplicate review summaries', () async {
    final client = LocalApiClient(
      httpClient: _DuplicateReviewJsonClient(),
      baseUri: Uri.parse('http://127.0.0.1:4821'),
    );

    final summary = await client.fetchDuplicateReviewSummary();

    expect(summary.duplicateCandidates, 2);
    expect(summary.protectedBytes, 4096);
    expect(summary.entries.single.assetId, 'asset-1');
    expect(summary.entries.single.sourceKinds, ['folder']);
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
    final tagged = await client.updateAssetTags(
      'asset-1',
      tags: const ['invoice', 'client'],
    );
    final bulkUpdated = await client.updateAssetsFlags(const [
      'asset-1',
      'asset-2',
    ], favorite: true);
    final favorites = await client.fetchFavoriteAssets();
    final archived = await client.fetchArchivedAssets();

    expect(updated.favorite, isTrue);
    expect(updated.archived, isTrue);
    expect(tagged.manualTags, ['invoice', 'client']);
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

  test('uses saved smart folder endpoints', () async {
    final client = LocalApiClient(
      httpClient: _SmartFolderJsonClient(),
      baseUri: Uri.parse('http://127.0.0.1:4821'),
    );

    final created = await client.createSmartFolder(
      title: 'Acme reports',
      query: const SearchQuery(
        text: '',
        workspace: 'Office',
        client: 'Acme',
        topic: 'Reports',
        mediaKind: 'document',
      ),
    );
    final folders = await client.fetchSmartFolders();
    final search = await client.runSmartFolder('smart-1');
    await client.deleteSmartFolder('smart-1');

    expect(created.title, 'Acme reports');
    expect(created.query.client, 'Acme');
    expect(folders.single.id, 'smart-1');
    expect(search.query.topic, 'Reports');
    expect(search.assets.single.id, 'asset-1');
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

    final vault = await client.createVault(
      id: 'cloud-group-id',
      name: 'Family',
      storagePolicy: policy,
    );
    final vaults = await client.fetchVaults();
    final status = await client.fetchVaultStatus('vault-1');
    final updated = await client.updateVaultStoragePolicy('vault-1', policy);
    final pairing = await client.createPairingSession(
      deviceName: 'Moto G',
      platform: 'android',
      vaultId: 'vault-1',
    );
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
    final network = await client.fetchSyncNetworkStatus();
    final started = await client.startSyncNetwork();
    final stopped = await client.stopSyncNetwork();
    final endpoint = await client.fetchLocalEndpoint();
    final retried = await client.retrySyncTransfer('transfer-1');
    final canceled = await client.cancelSyncTransfer('transfer-1');
    final entitlementStatus = await client.fetchEntitlementStatus();
    final releaseReadiness = await client.fetchPlatformReleaseReadiness();
    final supportBundle = await client.exportSupportBundle(
      exportRoot: '/backup',
    );
    final auditEvents = await client.fetchAuditEvents(limit: 5);
    final availability = await client.fetchAssetAvailability('asset-1');
    final pinned = await client.pinLocalAsset('asset-1');
    final evicted = await client.evictLocalAsset('asset-1');
    final revoked = await client.revokeDevice('device-2', reason: 'lost');

    expect(vault.name, 'Family');
    expect(vaults.single.id, 'vault-1');
    expect(status.underReplicatedBlobs, 1);
    expect(updated.storagePolicy.minReplicas, 2);
    expect(pairing.vaultId, 'vault-1');
    expect(device.trustLevel, DeviceTrustLevel.storageOnly);
    expect(devices, hasLength(2));
    expect(plan.transfers.single.status, SyncTransferStatus.pending);
    expect(runPlan.policySatisfied, isFalse);
    expect(transfers.single.toDeviceId, 'device-2');
    expect(network.pendingTransferCount, 1);
    expect(started.started, isTrue);
    expect(stopped.transport, contains('encrypted'));
    expect(endpoint.descriptor.nodeId, 'local-node-device-1');
    expect(retried.status, SyncTransferStatus.pending);
    expect(canceled.status, SyncTransferStatus.aborted);
    expect(entitlementStatus.tier, EntitlementTier.personalCore);
    expect(entitlementStatus.safeLocalAccessAllowed, isTrue);
    expect(releaseReadiness.requiredSurfaceCount, 8);
    expect(releaseReadiness.blockedSurfaceCount, 0);
    expect(supportBundle.privateDataExcluded, isTrue);
    expect(supportBundle.redactedFields, contains('account_id_hash'));
    expect(auditEvents.single.action, 'device.enroll');
    expect(auditEvents.single.actorLabel, 'Office desktop');
    expect(availability.state, AssetAvailabilityState.underReplicated);
    expect(pinned.state, AssetAvailabilityState.transferPending);
    expect(evicted.state, AssetAvailabilityState.remoteAvailable);
    expect(revoked.revoked, isTrue);
  });

  test('uses authenticated mobile sync endpoints', () async {
    final client = LocalApiClient(
      httpClient: _MobileSyncJsonClient(),
      baseUri: Uri.parse('http://127.0.0.1:4821'),
    );

    final paired = await client.pairMobileDevice(
      pairingToken: 'pair-token',
      deviceName: 'Moto G',
      platform: 'android',
    );
    final session = await client.fetchMobileSession(
      bearerToken: paired.bearerToken,
    );
    final sessions = await client.fetchMobileSessions(
      bearerToken: paired.bearerToken,
    );
    final refreshed = await client.refreshMobileSession(
      bearerToken: paired.bearerToken,
    );
    final reserved = await client.reserveMobileUpload(
      bearerToken: paired.bearerToken,
      originalFilename: 'photo.jpg',
      mediaKind: 'photo',
      mimeType: 'image/jpeg',
      bytes: 3,
      capturedAt: DateTime.parse('2026-05-13T06:00:00Z'),
    );
    final completed = await client.uploadMobileOriginal(
      bearerToken: paired.bearerToken,
      uploadId: reserved.id,
      bytes: const [1, 2, 3],
    );
    final uploadStatus = await client.fetchMobileUpload(
      bearerToken: paired.bearerToken,
      uploadId: reserved.id,
    );
    final canceledUpload = await client.cancelMobileUpload(
      bearerToken: paired.bearerToken,
      uploadId: reserved.id,
    );
    final chunked = await client.uploadMobileOriginalChunk(
      bearerToken: paired.bearerToken,
      uploadId: reserved.id,
      offset: 0,
      bytes: const [1, 2],
    );
    final chunkedComplete = await client.completeMobileUpload(
      bearerToken: paired.bearerToken,
      uploadId: reserved.id,
    );
    final tempDir = await Directory.systemTemp.createTemp('pg-mobile-client-');
    addTearDown(() => tempDir.delete(recursive: true));
    final sourceFile = File('${tempDir.path}/chunked.jpg');
    await sourceFile.writeAsBytes(const [1, 2, 3], flush: true);
    final fileCompleted = await client.uploadMobileOriginalFile(
      bearerToken: paired.bearerToken,
      uploadId: reserved.id,
      file: sourceFile,
      chunkSize: 2,
    );
    final assets = await client.fetchMobileAssets(
      bearerToken: paired.bearerToken,
    );
    final workspace = await client.fetchMobileWorkspace(
      bearerToken: paired.bearerToken,
    );
    final storageDevice = await client.updateMobileStorageProfile(
      bearerToken: paired.bearerToken,
      storageProfile: const DeviceStorageProfile(
        deviceId: null,
        totalBytes: null,
        availableBytes: null,
        reservedBytes: 1024,
        acceptsStorage: true,
        batteryPowered: true,
        meteredNetwork: false,
        lowBattery: false,
      ),
    );
    final storagePlan = await client.fetchMobileStoragePlan(
      bearerToken: paired.bearerToken,
    );
    final replicaChunk = await client.downloadMobileReplicaChunk(
      bearerToken: paired.bearerToken,
      blobId: storagePlan.assignments.single.blobId,
      chunkIndex: storagePlan.assignments.single.chunks.single.chunkIndex,
    );
    final replicaProof = storagePlan.assignments.single.chunks.single.proofFor(
      replicaChunk,
    );
    final replicaReport = await client.reportMobileReplica(
      bearerToken: paired.bearerToken,
      assignment: storagePlan.assignments.single,
      chunkProofsByIndex: {0: replicaProof},
    );
    final replicaRestore = await client.restoreMobileReplicaChunk(
      bearerToken: paired.bearerToken,
      blobId: storagePlan.assignments.single.blobId,
      chunkIndex: storagePlan.assignments.single.chunks.single.chunkIndex,
      bytes: replicaChunk,
    );
    final search = await client.searchMobile(
      bearerToken: paired.bearerToken,
      query: const SearchQuery(
        text: 'photo',
        device: 'Moto G',
        tags: 'invoice',
        limit: 25,
      ),
    );
    final availability = await client.fetchMobileAssetAvailability(
      bearerToken: paired.bearerToken,
      assetId: assets.single.assetId,
    );
    final flagged = await client.updateMobileAssetFlags(
      bearerToken: paired.bearerToken,
      assetId: assets.single.assetId,
      favorite: true,
    );
    final tagged = await client.updateMobileAssetTags(
      bearerToken: paired.bearerToken,
      assetId: assets.single.assetId,
      tags: const ['invoice'],
    );
    final original = await client.downloadMobileOriginal(
      bearerToken: paired.bearerToken,
      assetId: assets.single.assetId,
    );
    final streamedOriginal = await client.downloadMobileOriginalToFile(
      bearerToken: paired.bearerToken,
      assetId: assets.single.assetId,
      destination: File('${tempDir.path}/downloaded.jpg'),
    );
    final preview = await client.downloadMobilePreview(
      bearerToken: paired.bearerToken,
      assetId: assets.single.assetId,
    );
    final revokedDeviceSessions = await client.revokeMobileDeviceSessions(
      bearerToken: paired.bearerToken,
      deviceId: session.deviceId,
    );
    final revokedCurrent = await client.revokeCurrentMobileSession(
      bearerToken: paired.bearerToken,
    );

    expect(paired.device.displayName, 'Moto G');
    expect(session.deviceId, 'device-mobile');
    expect(sessions.single.deviceId, 'device-mobile');
    expect(refreshed.bearerToken, 'mobile-token-rotated');
    expect(refreshed.previousSessionId, 'session-1');
    expect(reserved.status, MobileUploadStatus.pending);
    expect(completed.status, MobileUploadStatus.completed);
    expect(completed.assetId, 'asset-1');
    expect(uploadStatus.status, MobileUploadStatus.pending);
    expect(canceledUpload.status, MobileUploadStatus.canceled);
    expect(chunked.status, MobileUploadStatus.running);
    expect(chunked.bytesReceived, 2);
    expect(chunkedComplete.status, MobileUploadStatus.completed);
    expect(fileCompleted.status, MobileUploadStatus.completed);
    expect(assets.single.originalFilename, 'photo.jpg');
    expect(workspace.timeline.totalAssets, 1);
    expect(workspace.vaultStatus.vault.name, 'Personal vault');
    expect(workspace.capabilities.canSearch, isTrue);
    expect(storageDevice.storageProfile.acceptsStorage, isTrue);
    expect(storagePlan.assignments.single.blobId, 'blob-1');
    expect(replicaChunk, [7, 8, 9]);
    expect(replicaReport.health, 'healthy');
    expect(replicaRestore['restored_local_chunk'], isTrue);
    expect(search.assets.single.id, 'asset-1');
    expect(availability.state, AssetAvailabilityState.underReplicated);
    expect(flagged.favorite, isTrue);
    expect(tagged.manualTags, ['invoice']);
    expect(original, [1, 2, 3]);
    expect(streamedOriginal.path, endsWith('downloaded.jpg'));
    expect(await streamedOriginal.readAsBytes(), [1, 2, 3]);
    expect(preview, [4, 5, 6]);
    expect(revokedDeviceSessions.single.revokedAt, isNotNull);
    expect(revokedCurrent.revokedAt, isNotNull);
  });

  test(
    'resumes mobile original downloads from an existing partial file',
    () async {
      final httpClient = _ResumeDownloadClient();
      final client = LocalApiClient(
        httpClient: httpClient,
        baseUri: Uri.parse('http://127.0.0.1:4821'),
      );
      final tempDir = await Directory.systemTemp.createTemp(
        'pg-mobile-resume-',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final destination = File('${tempDir.path}/original.jpg');
      await File('${destination.path}.part').writeAsBytes(const [1, 2]);

      final file = await client.downloadMobileOriginalToFile(
        bearerToken: 'mobile-token',
        assetId: 'asset-1',
        destination: destination,
      );

      expect(await file.readAsBytes(), [1, 2, 3, 4]);
      expect(httpClient.ranges, ['bytes=2-4194305']);
      expect(await File('${destination.path}.part').exists(), isFalse);
    },
  );

  test('cancels resumable mobile file uploads between chunks', () async {
    final httpClient = _CancelUploadClient();
    final client = LocalApiClient(
      httpClient: httpClient,
      baseUri: Uri.parse('http://127.0.0.1:4821'),
    );
    final tempDir = await Directory.systemTemp.createTemp('pg-mobile-cancel-');
    addTearDown(() => tempDir.delete(recursive: true));
    final sourceFile = File('${tempDir.path}/cancel.jpg');
    await sourceFile.writeAsBytes(const [1, 2, 3, 4], flush: true);
    final progress = <MobileUpload>[];

    final result = await client.uploadMobileOriginalFile(
      bearerToken: 'mobile-token',
      uploadId: 'upload-1',
      file: sourceFile,
      chunkSize: 2,
      onProgress: progress.add,
      shouldCancel: (upload) => upload.bytesReceived >= 2,
    );

    expect(result.status, MobileUploadStatus.canceled);
    expect(result.bytesReceived, 2);
    expect(httpClient.chunkOffsets, [0]);
    expect(httpClient.cancelRequests, 1);
    expect(progress.map((upload) => upload.status), [
      MobileUploadStatus.pending,
      MobileUploadStatus.running,
      MobileUploadStatus.canceled,
    ]);
  });

  test('treats in-flight chunk rejection as canceled when requested', () async {
    final httpClient = _RejectingCancelUploadClient();
    final client = LocalApiClient(
      httpClient: httpClient,
      baseUri: Uri.parse('http://127.0.0.1:4821'),
    );
    final tempDir = await Directory.systemTemp.createTemp(
      'pg-mobile-cancel-race-',
    );
    addTearDown(() => tempDir.delete(recursive: true));
    final sourceFile = File('${tempDir.path}/cancel-race.jpg');
    await sourceFile.writeAsBytes(const [1, 2], flush: true);
    var cancelChecks = 0;

    final result = await client.uploadMobileOriginalFile(
      bearerToken: 'mobile-token',
      uploadId: 'upload-1',
      file: sourceFile,
      chunkSize: 2,
      shouldCancel: (_) {
        cancelChecks += 1;
        return cancelChecks >= 3;
      },
    );

    expect(result.status, MobileUploadStatus.canceled);
    expect(httpClient.rejectedChunks, 1);
    expect(httpClient.cancelRequests, 1);
  });
}

class _DelayedJsonClient extends http.BaseClient {
  _DelayedJsonClient({required this.delay, required this.bodyForPath});

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
        },
      ],
      ('POST', '/jobs/job-1/cancel') => _jobJson(status: 'canceled'),
      ('POST', '/jobs/job-1/retry') => _jobJson(
        id: 'job-2',
        status: 'queued',
        retryOfJobId: 'job-1',
      ),
      ('POST', '/scenes/rebuild') => _jobJson(
        status: 'completed',
        kind: 'scene_index',
      ),
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

class _DuplicateReviewJsonClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = switch ((request.method, request.url.path)) {
      ('GET', '/duplicates') => {
        'generated_at': '2026-05-13T06:00:00Z',
        'duplicate_assets': 1,
        'duplicate_candidates': 2,
        'protected_bytes': 4096,
        'sessions_with_duplicates': 1,
        'entries': [
          {
            'asset_id': 'asset-1',
            'media_kind': 'photo',
            'original_bytes': 2048,
            'duplicate_candidates': 2,
            'protected_bytes': 4096,
            'first_seen_at': '2026-05-13T06:00:00Z',
            'last_seen_at': '2026-05-13T06:05:00Z',
            'import_session_ids': ['session-1'],
            'source_kinds': ['folder'],
          },
        ],
        'privacy_detail': 'Computed locally.',
      },
      _ => throw StateError('Unexpected ${request.method} ${request.url.path}'),
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
    final tagged = _assetJson()..['manual_tags'] = ['invoice', 'client'];
    final body = switch ((request.method, path)) {
      ('POST', '/assets/asset-1/flags') => asset,
      ('POST', '/assets/asset-1/tags') => tagged,
      ('POST', '/assets/flags/bulk') => [asset],
      ('GET', '/assets/favorites') => [asset],
      ('GET', '/assets/archived') => [asset],
      _ => throw StateError('Unexpected ${request.method} $path'),
    };
    if (request.method == 'POST') {
      final streamed = request as http.Request;
      final payload = jsonDecode(streamed.body) as Map<String, Object?>;
      if (path == '/assets/asset-1/flags') {
        expect(payload['favorite'], isTrue);
        expect(payload['archived'], isTrue);
      } else if (path == '/assets/asset-1/tags') {
        expect(payload['tags'], ['invoice', 'client']);
      } else {
        expect(payload['favorite'], isTrue);
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
        _albumJson(['asset-1']),
      ],
      ('POST', '/albums') => _albumJson(['asset-1']),
      ('GET', '/albums/album-1/assets') => [_assetJson()],
      ('POST', '/albums/album-1/assets') => _albumJson(['asset-1', 'asset-2']),
      ('POST', '/albums/album-1/assets/remove') => _albumJson(['asset-2']),
      ('POST', '/albums/album-1/rename') => _albumJson([
        'asset-1',
      ], title: 'Family trip'),
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

class _SmartFolderJsonClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    final body = switch ((request.method, path)) {
      ('GET', '/smart-folders') => [_smartFolderJson()],
      ('POST', '/smart-folders') => _smartFolderJson(),
      ('GET', '/smart-folders/smart-1/search') => {
        'query': _smartFolderQueryJson(),
        'assets': [_assetJson()],
        'people': [],
        'places': [],
        'events': [],
      },
      ('DELETE', '/smart-folders/smart-1') => null,
      _ => throw StateError('Unexpected ${request.method} $path'),
    };

    if (request.method == 'POST' && path == '/smart-folders') {
      final streamed = request as http.Request;
      final payload = jsonDecode(streamed.body) as Map<String, Object?>;
      expect(payload['title'], 'Acme reports');
      final query = payload['query'] as Map<String, Object?>;
      expect(query['workspace'], 'Office');
      expect(query['client'], 'Acme');
      expect(query['topic'], 'Reports');
      expect(query['media_kind'], 'document');
      expect(query['include_archived'], isFalse);
    }

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
      ('POST', '/pairing/sessions') => _devicePairingJson(),
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
      ('GET', '/sync/network/status') => _networkStatusJson(),
      ('POST', '/sync/network/start') => _networkStatusJson(),
      ('POST', '/sync/network/stop') => _networkStatusJson(),
      ('GET', '/sync/network/local-endpoint') => _localEndpointJson(),
      ('POST', '/sync/transfers/transfer-1/retry') => _transferJson(),
      ('POST', '/sync/transfers/transfer-1/cancel') => _transferJson(
        status: 'aborted',
      ),
      ('GET', '/entitlements/status') => _entitlementStatusJson(),
      ('GET', '/release/readiness') => _releaseReadinessJson(),
      ('POST', '/support/bundle') => _supportBundleJson(),
      ('GET', '/audit/events') => [_auditEventJson()],
      ('GET', '/assets/asset-1/availability') => _availabilityJson(),
      ('POST', '/assets/asset-1/pin-local') => _availabilityJson(
        state: 'transfer_pending',
      ),
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
    if (request.method == 'POST' && path == '/vaults') {
      final streamed = request as http.Request;
      final payload = jsonDecode(streamed.body) as Map<String, Object?>;
      expect(payload['id'], 'cloud-group-id');
      expect(payload['name'], 'Family');
    }
    if (request.method == 'POST' && path == '/support/bundle') {
      final streamed = request as http.Request;
      final payload = jsonDecode(streamed.body) as Map<String, Object?>;
      expect(payload['export_root'], '/backup');
      expect(payload['include_release_readiness'], isTrue);
    }
    if (request.method == 'POST' && path == '/pairing/sessions') {
      final streamed = request as http.Request;
      final payload = jsonDecode(streamed.body) as Map<String, Object?>;
      expect(payload['device_name'], 'Moto G');
      expect(payload['platform'], 'android');
      expect(payload['vault_id'], 'vault-1');
    }
    if (request.method == 'GET' && path == '/audit/events') {
      expect(request.url.queryParameters['limit'], '5');
    }

    final bytes = utf8.encode(jsonEncode(body));
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      HttpStatus.ok,
      headers: const {'content-type': 'application/json'},
    );
  }
}

Map<String, Object?> _auditEventJson() {
  return {
    'id': 'audit-1',
    'action': 'device.enroll',
    'target_kind': 'device',
    'target_id': 'device-2',
    'actor_device_id': 'device-1',
    'actor_label': 'Office desktop',
    'summary': 'Enrolled device NAS',
    'payload': {
      'device_id': 'device-2',
      'vault_id': 'vault-1',
      'accepts_storage': true,
    },
    'created_at': '2026-05-14T07:00:00Z',
  };
}

class _MobileSyncJsonClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    if (path != '/mobile/pair') {
      expect(request.headers['authorization'], 'Bearer mobile-token');
    }
    if (request.method == 'GET' && path == '/mobile/assets/asset-1/original') {
      final range = request.headers['range'];
      if (range != null) {
        expect(range, 'bytes=0-4194303');
        return http.StreamedResponse(
          Stream<List<int>>.value(const [1, 2, 3]),
          HttpStatus.partialContent,
          headers: const {
            'content-type': 'image/jpeg',
            'content-range': 'bytes 0-2/3',
            'content-length': '3',
          },
          contentLength: 3,
        );
      }
      return http.StreamedResponse(
        Stream<List<int>>.value(const [1, 2, 3]),
        HttpStatus.ok,
        headers: const {'content-type': 'image/jpeg', 'content-length': '3'},
        contentLength: 3,
      );
    }
    if (request.method == 'GET' && path == '/mobile/assets/asset-1/preview') {
      return http.StreamedResponse(
        Stream<List<int>>.value(const [4, 5, 6]),
        HttpStatus.ok,
        headers: const {'content-type': 'image/jpeg'},
      );
    }
    if (request.method == 'GET' &&
        path == '/mobile/storage/blobs/blob-1/chunks/0') {
      return http.StreamedResponse(
        Stream<List<int>>.value(const [7, 8, 9]),
        HttpStatus.ok,
        headers: const {
          'content-type': 'application/octet-stream',
          'content-length': '3',
        },
        contentLength: 3,
      );
    }
    if (request.method == 'PUT' &&
        path == '/mobile/storage/blobs/blob-1/chunks/0') {
      final streamed = request as http.Request;
      expect(streamed.bodyBytes, [7, 8, 9]);
      return http.StreamedResponse(
        Stream<List<int>>.value(
          utf8.encode(
            jsonEncode({
              'blob_id': 'blob-1',
              'chunk_index': 0,
              'encrypted_hash': 'encrypted-chunk-hash',
              'encrypted_bytes': 3,
              'restored_local_chunk': true,
              'detail': 'restored',
            }),
          ),
        ),
        HttpStatus.ok,
        headers: const {'content-type': 'application/json'},
      );
    }
    if (request.method == 'PUT' &&
        path.startsWith('/mobile/uploads/upload-1/chunks/')) {
      final streamed = request as http.Request;
      final offset = int.parse(
        path.substring('/mobile/uploads/upload-1/chunks/'.length),
      );
      return http.StreamedResponse(
        Stream<List<int>>.value(
          utf8.encode(
            jsonEncode(
              _mobileUploadJson(
                status: 'running',
                bytesReceived: offset + streamed.bodyBytes.length,
              ),
            ),
          ),
        ),
        HttpStatus.ok,
        headers: const {'content-type': 'application/json'},
      );
    }

    final body = switch ((request.method, path)) {
      ('POST', '/mobile/pair') => _mobilePairJson(),
      ('GET', '/mobile/session') => _mobileSessionJson(),
      ('GET', '/mobile/sessions') => [_mobileSessionJson()],
      ('POST', '/mobile/session/refresh') => _mobileSessionRefreshJson(),
      ('POST', '/mobile/session/revoke') => _mobileSessionJson(revoked: true),
      ('POST', '/mobile/devices/device-mobile/sessions/revoke') => [
        _mobileSessionJson(revoked: true),
      ],
      ('GET', '/mobile/workspace') => _mobileWorkspaceJson(),
      ('POST', '/mobile/storage-profile') => _deviceJson(
        id: 'device-mobile',
        displayName: 'Moto G',
      ),
      ('GET', '/mobile/storage/plan') => _mobileStoragePlanJson(),
      ('POST', '/mobile/storage/blobs/blob-1/report') =>
        _mobileReplicaReportJson(),
      ('GET', '/mobile/search') => _mobileSearchJson(),
      ('POST', '/mobile/uploads') => _mobileUploadJson(status: 'pending'),
      ('GET', '/mobile/uploads/upload-1') => _mobileUploadJson(
        status: 'pending',
      ),
      ('DELETE', '/mobile/uploads/upload-1') => _mobileUploadJson(
        status: 'canceled',
      ),
      ('PUT', '/mobile/uploads/upload-1') => _mobileUploadJson(
        status: 'completed',
        assetId: 'asset-1',
      ),
      ('POST', '/mobile/uploads/upload-1/complete') => _mobileUploadJson(
        status: 'completed',
        assetId: 'asset-1',
      ),
      ('GET', '/mobile/assets') => [_mobileAssetJson()],
      ('GET', '/mobile/assets/asset-1/availability') => _availabilityJson(),
      ('POST', '/mobile/assets/asset-1/flags') =>
        _assetJson()..['favorite'] = true,
      ('POST', '/mobile/assets/asset-1/tags') =>
        _assetJson()..['manual_tags'] = ['invoice'],
      _ => throw StateError('Unexpected ${request.method} $path'),
    };

    if (request.method == 'POST' && path == '/mobile/uploads') {
      final streamed = request as http.Request;
      final payload = jsonDecode(streamed.body) as Map<String, Object?>;
      expect(payload['original_filename'], 'photo.jpg');
      expect(payload['bytes'], 3);
    }
    if (request.method == 'PUT' && path == '/mobile/uploads/upload-1') {
      final streamed = request as http.Request;
      expect(streamed.bodyBytes, [1, 2, 3]);
    }
    if (request.method == 'GET' && path == '/mobile/search') {
      expect(request.url.queryParameters['text'], 'photo');
      expect(request.url.queryParameters['device'], 'Moto G');
      expect(request.url.queryParameters['tags'], 'invoice');
      expect(request.url.queryParameters['limit'], '25');
    }
    if (request.method == 'POST' && path == '/mobile/assets/asset-1/flags') {
      final streamed = request as http.Request;
      final payload = jsonDecode(streamed.body) as Map<String, Object?>;
      expect(payload['favorite'], isTrue);
    }
    if (request.method == 'POST' && path == '/mobile/assets/asset-1/tags') {
      final streamed = request as http.Request;
      final payload = jsonDecode(streamed.body) as Map<String, Object?>;
      expect(payload['tags'], ['invoice']);
    }
    if (request.method == 'POST' && path == '/mobile/storage-profile') {
      final streamed = request as http.Request;
      final payload = jsonDecode(streamed.body) as Map<String, Object?>;
      final profile = payload['storage_profile'] as Map<String, Object?>;
      expect(profile['accepts_storage'], isTrue);
    }
    if (request.method == 'POST' &&
        path == '/mobile/storage/blobs/blob-1/report') {
      final streamed = request as http.Request;
      final payload = jsonDecode(streamed.body) as Map<String, Object?>;
      expect(payload['transfer_id'], 'transfer-1');
      final chunks = payload['chunks'] as List<Object?>;
      expect(chunks, isNotEmpty);
      expect((chunks.single as Map<String, Object?>)['proof'], isNotEmpty);
    }

    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(body))),
      HttpStatus.ok,
      headers: const {'content-type': 'application/json'},
    );
  }
}

class _ResumeDownloadClient extends http.BaseClient {
  final ranges = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    expect(request.method, 'GET');
    expect(request.url.path, '/mobile/assets/asset-1/original');
    expect(request.headers['authorization'], 'Bearer mobile-token');
    ranges.add(request.headers['range'] ?? '');
    return http.StreamedResponse(
      Stream<List<int>>.value(const [3, 4]),
      HttpStatus.partialContent,
      headers: const {
        'content-type': 'image/jpeg',
        'content-range': 'bytes 2-3/4',
        'content-length': '2',
      },
      contentLength: 2,
    );
  }
}

class _CancelUploadClient extends http.BaseClient {
  final chunkOffsets = <int>[];
  var bytesReceived = 0;
  var cancelRequests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    expect(request.headers['authorization'], 'Bearer mobile-token');
    final path = request.url.path;
    if (request.method == 'GET' && path == '/mobile/uploads/upload-1') {
      return _jsonResponse(
        _mobileUploadJson(
          status: 'pending',
          bytesTotal: 4,
          bytesReceived: bytesReceived,
        ),
      );
    }
    if (request.method == 'PUT' &&
        path.startsWith('/mobile/uploads/upload-1/chunks/')) {
      final streamed = request as http.Request;
      final offset = int.parse(
        path.substring('/mobile/uploads/upload-1/chunks/'.length),
      );
      chunkOffsets.add(offset);
      bytesReceived = offset + streamed.bodyBytes.length;
      return _jsonResponse(
        _mobileUploadJson(
          status: 'running',
          bytesTotal: 4,
          bytesReceived: bytesReceived,
        ),
      );
    }
    if (request.method == 'DELETE' && path == '/mobile/uploads/upload-1') {
      cancelRequests += 1;
      return _jsonResponse(
        _mobileUploadJson(
          status: 'canceled',
          bytesTotal: 4,
          bytesReceived: bytesReceived,
        ),
      );
    }
    throw StateError('Unexpected ${request.method} $path');
  }
}

class _RejectingCancelUploadClient extends http.BaseClient {
  var rejectedChunks = 0;
  var cancelRequests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    expect(request.headers['authorization'], 'Bearer mobile-token');
    final path = request.url.path;
    if (request.method == 'GET' && path == '/mobile/uploads/upload-1') {
      return _jsonResponse(_mobileUploadJson(status: 'pending', bytesTotal: 2));
    }
    if (request.method == 'PUT' &&
        path.startsWith('/mobile/uploads/upload-1/chunks/')) {
      rejectedChunks += 1;
      return http.StreamedResponse(
        Stream<List<int>>.value(
          utf8.encode('mobile upload is already canceled'),
        ),
        HttpStatus.conflict,
        headers: const {'content-type': 'text/plain'},
      );
    }
    if (request.method == 'DELETE' && path == '/mobile/uploads/upload-1') {
      cancelRequests += 1;
      return _jsonResponse(
        _mobileUploadJson(status: 'canceled', bytesTotal: 2),
      );
    }
    throw StateError('Unexpected ${request.method} $path');
  }
}

http.StreamedResponse _jsonResponse(Object? body) {
  return http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(jsonEncode(body))),
    HttpStatus.ok,
    headers: const {'content-type': 'application/json'},
  );
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

Map<String, Object?> _entitlementStatusJson() {
  return {
    'tier': 'personal_core',
    'effective_status': 'active',
    'limits': {
      'device_limit': 3,
      'member_limit': 1,
      'workspace_limit': 1,
      'monthly_ocr_limit': 1000,
      'relay_priority': 'none',
      'advanced_admin_controls': false,
    },
    'cache': null,
    'offline_grace_active': false,
    'paid_features_available': true,
    'safe_local_access_allowed': true,
    'content_exposure_prevented': true,
    'detail':
        'Personal core local access is available without sending content to billing.',
  };
}

Map<String, Object?> _releaseReadinessJson() {
  return {
    'generated_at': '2026-05-14T07:00:00Z',
    'overall_status': 'in_progress',
    'required_surface_count': 8,
    'ready_surface_count': 0,
    'detail': 'Cross-platform release is incomplete.',
    'surfaces': [
      _releaseSurfaceJson('linux_desktop', 'Linux desktop', 'in_progress'),
      _releaseSurfaceJson('windows_desktop', 'Windows desktop', 'in_progress'),
      _releaseSurfaceJson('macos_desktop', 'macOS desktop', 'in_progress'),
      _releaseSurfaceJson(
        'android_play_store',
        'Android / Play Store',
        'in_progress',
      ),
      _releaseSurfaceJson('ios_app_store', 'iOS / App Store', 'in_progress'),
      _releaseSurfaceJson('web_browser', 'Web/browser', 'in_progress'),
      _releaseSurfaceJson('local_web_ui', 'Local web UI', 'in_progress'),
      _releaseSurfaceJson(
        'direct_desktop_distribution',
        'Direct desktop distribution',
        'in_progress',
      ),
    ],
  };
}

Map<String, Object?> _releaseSurfaceJson(
  String surface,
  String label,
  String status,
) {
  return {
    'surface': surface,
    'label': label,
    'status': status,
    'distribution': 'Release artifact',
    'evidence': [
      {
        'key': '${surface}_evidence',
        'label': 'Evidence',
        'status': 'missing',
        'detail': 'Missing release evidence.',
      },
    ],
    'blockers': ['Missing release evidence.'],
    'next_step': 'Record release evidence.',
  };
}

Map<String, Object?> _supportBundleJson() {
  return {
    'exported_at': '2026-05-14T07:05:00Z',
    'export_root': '/backup',
    'bundle_path': '/backup/support/private-gallery-support-bundle.json',
    'sections': [
      'summary',
      'privacy',
      'entitlements',
      'backup_health',
      'release_readiness',
      'redaction',
    ],
    'redacted_fields': ['original_filename', 'account_id_hash'],
    'private_data_excluded': true,
    'ok': true,
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

Map<String, Object?> _mobileSessionJson({bool revoked = false}) {
  return {
    'id': 'session-1',
    'device_id': 'device-mobile',
    'vault_id': 'vault-1',
    'display_name': 'Moto G',
    'platform': 'android',
    'created_at': '2026-05-13T06:00:00Z',
    'expires_at': '2026-06-12T06:00:00Z',
    'last_seen_at': '2026-05-13T06:01:00Z',
    'revoked_at': revoked ? '2026-05-13T06:05:00Z' : null,
  };
}

Map<String, Object?> _mobilePairJson() {
  return {
    'session': _mobileSessionJson(),
    'device': _deviceJson(id: 'device-mobile', displayName: 'Moto G'),
    'bearer_token': 'mobile-token',
    'detail': 'mobile device paired',
  };
}

Map<String, Object?> _mobileSessionRefreshJson() {
  return {
    'session': _mobileSessionJson()..['id'] = 'session-2',
    'bearer_token': 'mobile-token-rotated',
    'previous_session_id': 'session-1',
    'detail': 'mobile session refreshed',
  };
}

Map<String, Object?> _devicePairingJson() {
  return {
    'id': 'pairing-1',
    'device_name': 'Moto G',
    'platform': 'android',
    'vault_id': 'vault-1',
    'pairing_token': 'pair-token',
    'created_at': '2026-05-13T06:00:00Z',
    'expires_at': '2026-05-13T06:10:00Z',
    'approved_at': null,
  };
}

Map<String, Object?> _mobileUploadJson({
  required String status,
  String? assetId,
  int? bytesReceived,
  int bytesTotal = 3,
}) {
  return {
    'id': 'upload-1',
    'session_id': 'session-1',
    'device_id': 'device-mobile',
    'vault_id': 'vault-1',
    'asset_id': assetId,
    'original_filename': 'photo.jpg',
    'media_kind': 'photo',
    'mime_type': 'image/jpeg',
    'bytes_total': bytesTotal,
    'bytes_received': bytesReceived ?? (status == 'completed' ? bytesTotal : 0),
    'content_hash': 'hash-a',
    'captured_at': '2026-05-13T06:00:00Z',
    'place_hint': null,
    'status': status,
    'error_detail': null,
    'created_at': '2026-05-13T06:00:00Z',
    'updated_at': '2026-05-13T06:01:00Z',
  };
}

Map<String, Object?> _mobileAssetJson() {
  return {
    'asset_id': 'asset-1',
    'original_filename': 'photo.jpg',
    'media_kind': 'photo',
    'mime_type': 'image/jpeg',
    'bytes': 3,
    'content_hash': 'hash-a',
    'captured_at': '2026-05-13T06:00:00Z',
    'available': true,
  };
}

Map<String, Object?> _mobileWorkspaceJson() {
  return {
    'session': _mobileSessionJson(),
    'sessions': [_mobileSessionJson()],
    'timeline': {
      'buckets': [
        {
          'label': 'May 2026',
          'asset_ids': ['asset-1'],
          'assets': [_assetJson()],
          'total_assets': 1,
        },
      ],
      'next_cursor': null,
      'total_assets': 1,
      'returned_assets': 1,
    },
    'albums': [
      _albumJson(['asset-1']),
    ],
    'people': [
      _personJson(['asset-1']),
    ],
    'places': [
      _placeJson(['asset-1']),
    ],
    'events': [
      _eventJson(['asset-1']),
    ],
    'jobs': [_jobJson(status: 'completed')],
    'vault_status': _vaultStatusJson(),
    'devices': [
      _deviceJson(),
      _deviceJson(id: 'device-mobile', displayName: 'Moto G'),
    ],
    'sync_network': _networkStatusJson(),
    'capabilities': {
      'can_browse_library': true,
      'can_search': true,
      'can_upload_camera_roll': true,
      'can_download_originals': true,
      'can_manage_storage': false,
      'can_import_desktop_folders': false,
      'can_run_models': false,
      'role_detail': 'mobile contributor',
    },
  };
}

Map<String, Object?> _mobileStoragePlanJson() {
  return {
    'generated_at': '2026-05-13T06:02:00Z',
    'device': _deviceJson(id: 'device-mobile', displayName: 'Moto G'),
    'assignments': [
      {
        'transfer_id': 'transfer-1',
        'vault_id': 'vault-1',
        'blob_id': 'blob-1',
        'asset_id': 'asset-1',
        'encrypted_hash': 'encrypted-blob-hash',
        'bytes_total': 3,
        'chunks': [
          {
            'chunk_id': 'chunk-1',
            'chunk_index': 0,
            'encrypted_hash': 'encrypted-chunk-hash',
            'encrypted_bytes': 3,
            'plaintext_bytes': 3,
            'proof_challenge': 'challenge-1',
          },
        ],
      },
    ],
    'detail': '1 encrypted blob replica assignment is ready for this phone.',
  };
}

Map<String, Object?> _mobileReplicaReportJson() {
  return {
    'blob_id': 'blob-1',
    'device_id': 'device-mobile',
    'health': 'healthy',
    'bytes_present': 3,
    'verified_at': '2026-05-13T06:03:00Z',
    'transfer_id': 'transfer-1',
    'detail': 'phone reported encrypted chunk replica',
  };
}

Map<String, Object?> _mobileSearchJson() {
  return {
    'query': {'text': 'photo', 'include_archived': false, 'limit': 25},
    'assets': [_assetJson()],
    'people': [
      _personJson(['asset-1']),
    ],
    'places': [
      _placeJson(['asset-1']),
    ],
    'events': [
      _eventJson(['asset-1']),
    ],
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
    'detail': 'local control plane',
  };
}

Map<String, Object?> _transferJson({String status = 'pending'}) {
  return {
    'id': 'transfer-1',
    'vault_id': 'vault-1',
    'blob_id': 'blob-1',
    'from_device_id': 'device-1',
    'to_device_id': 'device-2',
    'status': status,
    'bytes_total': 100,
    'bytes_completed': 0,
    'started_at': null,
    'updated_at': '2026-05-13T06:00:00Z',
    'resumable_until': '2026-05-20T06:00:00Z',
  };
}

Map<String, Object?> _networkStatusJson() {
  return {
    'started': true,
    'transport': 'iroh-quic-v1; encrypted-content-addressed-vault-chunks',
    'local_device_id': 'device-1',
    'local_node_id': 'local-node-device-1',
    'direct_addresses': ['192.168.1.10:4433'],
    'relay_urls': [],
    'active_transfer_count': 0,
    'pending_transfer_count': 1,
    'completed_transfer_count': 0,
    'failed_transfer_count': 0,
    'detail': 'encrypted local sync',
  };
}

Map<String, Object?> _localEndpointJson() {
  return {
    'descriptor': {
      'device_id': 'device-1',
      'device_name': 'Laptop',
      'platform': 'linux',
      'node_id': 'local-node-device-1',
      'relay_urls': [],
      'direct_addresses': ['192.168.1.10:4433'],
      'expires_at': '2026-05-13T06:10:00Z',
      'trust_level': 'trusted',
      'role': 'admin',
    },
    'pairing_payload': '{"node_id":"local-node-device-1"}',
    'detail': 'P2P vault sync is listening',
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
    'execution_results': [],
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
    'manual_tags': [],
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

Map<String, Object?> _smartFolderQueryJson() {
  return {
    'workspace': 'Office',
    'client': 'Acme',
    'topic': 'Reports',
    'media_kind': 'document',
    'include_archived': false,
    'limit': 80,
  };
}

Map<String, Object?> _smartFolderJson() {
  return {
    'id': 'smart-1',
    'title': 'Acme reports',
    'query': _smartFolderQueryJson(),
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

Map<String, Object?> _placeJson(List<String> assetIds) {
  return {
    'id': 'place-1',
    'label': 'Home',
    'country_code': null,
    'region': null,
    'asset_ids': assetIds,
    'centroid_latitude': null,
    'centroid_longitude': null,
    'model_name': 'local-place-cluster',
    'model_version': 'v1',
    'model_hash': null,
    'created_at': '2026-05-13T06:00:00Z',
    'rebuildable': true,
  };
}

Map<String, Object?> _eventJson(List<String> assetIds) {
  return {
    'id': 'event-1',
    'title': 'May 2026',
    'title_source': 'generated',
    'asset_ids': assetIds,
    'start_at': '2026-05-13T06:00:00Z',
    'end_at': '2026-05-13T06:00:00Z',
    'place_id': 'place-1',
    'people_ids': ['person-1'],
    'model_name': 'local-event-cluster',
    'model_version': 'v1',
    'model_hash': null,
    'created_at': '2026-05-13T06:00:00Z',
    'rebuildable': true,
  };
}
