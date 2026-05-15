import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/gallery_models.dart';

class ApiException implements Exception {
  ApiException({
    required this.path,
    required this.statusCode,
    required this.body,
  });

  final String path;
  final int statusCode;
  final String body;

  bool get isNotFound => statusCode == 404;

  @override
  String toString() {
    return 'ApiException($statusCode $path): $body';
  }
}

class LocalApiClient {
  LocalApiClient({
    http.Client? httpClient,
    Uri? baseUri,
    Duration defaultTimeout = const Duration(seconds: 3),
    Duration startupTimeout = const Duration(seconds: 15),
    Duration heavyReadTimeout = const Duration(seconds: 45),
  })  : _httpClient = httpClient ?? http.Client(),
        _baseUri = baseUri ?? Uri.parse('http://127.0.0.1:4821'),
        _defaultTimeout = defaultTimeout,
        _startupTimeout = startupTimeout,
        _heavyReadTimeout = heavyReadTimeout;

  final http.Client _httpClient;
  final Uri _baseUri;
  final Duration _defaultTimeout;
  final Duration _startupTimeout;
  final Duration _heavyReadTimeout;

  Future<void> fetchHealth() async {
    await _getObject('/health');
  }

  Future<MobilePairResponse> pairMobileDevice({
    required String pairingToken,
    required String deviceName,
    required String platform,
    String? vaultId,
  }) async {
    final response = await _postObject('/mobile/pair', {
      'pairing_token': pairingToken,
      'device_name': deviceName,
      'platform': platform,
      if (vaultId != null && vaultId.trim().isNotEmpty) 'vault_id': vaultId,
    });
    return MobilePairResponse.fromJson(response);
  }

  Future<MobileSession> fetchMobileSession({
    required String bearerToken,
  }) async {
    final response = await _getObject(
      '/mobile/session',
      headers: _mobileHeaders(bearerToken),
    );
    return MobileSession.fromJson(response);
  }

  Future<MobileUpload> reserveMobileUpload({
    required String bearerToken,
    required String originalFilename,
    required String mediaKind,
    required String mimeType,
    required int bytes,
    String? contentHash,
    DateTime? capturedAt,
    String? placeHint,
  }) async {
    final response = await _postObject(
      '/mobile/uploads',
      {
        'original_filename': originalFilename,
        'media_kind': mediaKind,
        'mime_type': mimeType,
        'bytes': bytes,
        if (contentHash != null && contentHash.trim().isNotEmpty)
          'content_hash': contentHash.trim(),
        if (capturedAt != null)
          'captured_at': capturedAt.toUtc().toIso8601String(),
        if (placeHint != null && placeHint.trim().isNotEmpty)
          'place_hint': placeHint.trim(),
      },
      headers: _mobileHeaders(bearerToken),
      timeout: _heavyReadTimeout,
    );
    return MobileUpload.fromJson(response);
  }

  Future<MobileUpload> uploadMobileOriginal({
    required String bearerToken,
    required String uploadId,
    required List<int> bytes,
  }) async {
    final response = await _putBytes(
      '/mobile/uploads/$uploadId',
      bytes,
      headers: _mobileHeaders(bearerToken),
      timeout: _heavyReadTimeout,
    );
    return MobileUpload.fromJson(response);
  }

  Future<List<MobileAssetSummary>> fetchMobileAssets({
    required String bearerToken,
  }) async {
    final response = await _getList(
      '/mobile/assets',
      headers: _mobileHeaders(bearerToken),
      timeout: _heavyReadTimeout,
    );
    return response.map(MobileAssetSummary.fromJson).toList();
  }

  Future<List<int>> downloadMobileOriginal({
    required String bearerToken,
    required String assetId,
  }) async {
    final response = await _request(
      () => _httpClient.get(
        _resolve('/mobile/assets/$assetId/original'),
        headers: _mobileHeaders(bearerToken),
      ),
      '/mobile/assets/$assetId/original',
      timeout: _heavyReadTimeout,
    );
    return response.bodyBytes;
  }

  Future<DaemonDiagnostics> fetchDiagnostics() async {
    final response = await _getObject('/diagnostics');
    return DaemonDiagnostics.fromJson(response);
  }

  Future<PrivacyStatus> fetchPrivacyStatus() async {
    final response = await _getObject('/privacy/status');
    return PrivacyStatus.fromJson(response);
  }

  Future<List<ModelArtifact>> fetchModels() async {
    final response = await _getList('/models');
    return response.map(ModelArtifact.fromJson).toList();
  }

  Future<ModelRuntimeStatus> fetchModelRuntimeStatus() async {
    final response = await _getObject('/models/runtime-status');
    return ModelRuntimeStatus.fromJson(response);
  }

  Future<ModelArtifact> installModel({
    required String id,
    String? sourceUrl,
    String? expectedSha256,
    required bool confirmed,
  }) async {
    final response = await _postObject('/models/install', {
      'id': id,
      'confirmed': confirmed,
      if (sourceUrl != null && sourceUrl.trim().isNotEmpty)
        'source_url': sourceUrl.trim(),
      if (expectedSha256 != null && expectedSha256.trim().isNotEmpty)
        'expected_sha256': expectedSha256.trim(),
    });
    return ModelArtifact.fromJson(response);
  }

  Future<ModelArtifact> importLocalModel({
    required String id,
    required String localPath,
    String? expectedSha256,
    required bool confirmed,
  }) async {
    final response = await _postObject('/models/import-local', {
      'id': id,
      'local_path': localPath,
      'confirmed': confirmed,
      if (expectedSha256 != null && expectedSha256.trim().isNotEmpty)
        'expected_sha256': expectedSha256.trim(),
    });
    return ModelArtifact.fromJson(response);
  }

  Future<ModelArtifact> verifyModel(String id) async {
    final response = await _postObject('/models/$id/verify', const {});
    return ModelArtifact.fromJson(response);
  }

  Future<EncryptionActivationResult> activateEncryption() async {
    final response = await _postObject(
      '/security/encryption/activate',
      const {'confirmed': true},
    );
    return EncryptionActivationResult.fromJson(response);
  }

  Future<BackupVerification> verifyBackup({String? exportRoot}) async {
    final response = await _postObject('/backup/verify', {
      if (exportRoot != null && exportRoot.trim().isNotEmpty)
        'export_root': exportRoot.trim(),
    });
    return BackupVerification.fromJson(response);
  }

  Future<BackupExportResult> exportBackup({
    required String exportRoot,
    bool includeModels = true,
  }) async {
    final response = await _postObject('/backup/export', {
      'export_root': exportRoot,
      'include_models': includeModels,
    });
    return BackupExportResult.fromJson(response);
  }

  Future<BackupRestorePlan> planRestoreBackup({
    required String exportRoot,
    required String restoreRoot,
  }) async {
    final response = await _postObject('/backup/restore/plan', {
      'export_root': exportRoot,
      'restore_root': restoreRoot,
    });
    return BackupRestorePlan.fromJson(response);
  }

  Future<BackupRestoreRunResult> runRestoreBackup({
    required String exportRoot,
    required String restoreRoot,
    bool confirmed = true,
  }) async {
    final response = await _postObject('/backup/restore/run', {
      'export_root': exportRoot,
      'restore_root': restoreRoot,
      'confirmed': confirmed,
    });
    return BackupRestoreRunResult.fromJson(response);
  }

  Future<LibraryStatus> fetchLibraryStatus() async {
    final response = await _getObject(
      '/library/status',
      timeout: _startupTimeout,
    );
    return LibraryStatus.fromJson(response);
  }

  Future<LibrarySettings> fetchLibrarySettings() async {
    final response = await _getObject('/library/settings');
    return LibrarySettings.fromJson(response);
  }

  Future<LibrarySettings> saveLibrarySettings(
      LibrarySettingsDraft draft) async {
    final response = await _postObject('/library/settings', draft.toJson());
    return LibrarySettings.fromJson(response);
  }

  Future<List<Vault>> fetchVaults() async {
    final response = await _getList('/vaults');
    return response.map(Vault.fromJson).toList();
  }

  Future<Vault> createVault({
    required String name,
    StoragePolicy? storagePolicy,
  }) async {
    final response = await _postObject('/vaults', {
      'name': name,
      if (storagePolicy != null) 'storage_policy': storagePolicy.toJson(),
    });
    return Vault.fromJson(response);
  }

  Future<VaultStatus> fetchVaultStatus(String id) async {
    final response = await _getObject('/vaults/$id/status');
    return VaultStatus.fromJson(response);
  }

  Future<Vault> updateVaultStoragePolicy(
    String id,
    StoragePolicy policy,
  ) async {
    final response = await _postObject('/vaults/$id/storage-policy', {
      'policy': policy.toJson(),
    });
    return Vault.fromJson(response);
  }

  Future<List<DeviceIdentity>> fetchDevices() async {
    final response = await _getList('/devices');
    return response.map(DeviceIdentity.fromJson).toList();
  }

  Future<DeviceIdentity> createDevice({
    required String displayName,
    required String platform,
    String? publicKey,
    DeviceTrustLevel? trustLevel,
    DeviceRole? role,
    DeviceStorageProfile? storageProfile,
  }) async {
    final response = await _postObject('/devices', {
      'display_name': displayName,
      'platform': platform,
      if (publicKey != null && publicKey.trim().isNotEmpty)
        'public_key': publicKey.trim(),
      if (trustLevel != null) 'trust_level': trustLevel.wireValue,
      if (role != null) 'role': role.wireValue,
      if (storageProfile != null) 'storage_profile': storageProfile.toJson(),
    });
    return DeviceIdentity.fromJson(response);
  }

  Future<DeviceIdentity> enrollDevice({
    required String displayName,
    required String platform,
    String? publicKey,
    String? vaultId,
    DeviceTrustLevel? trustLevel,
    DeviceRole? role,
    DeviceStorageProfile? storageProfile,
    PeerEndpointDescriptor? endpoint,
  }) async {
    final response = await _postObject('/devices/enroll', {
      'display_name': displayName,
      'platform': platform,
      if (publicKey != null && publicKey.trim().isNotEmpty)
        'public_key': publicKey.trim(),
      if (vaultId != null) 'vault_id': vaultId,
      if (trustLevel != null) 'trust_level': trustLevel.wireValue,
      if (role != null) 'role': role.wireValue,
      if (storageProfile != null) 'storage_profile': storageProfile.toJson(),
      if (endpoint != null) 'endpoint': endpoint.toJson(),
    });
    return DeviceIdentity.fromJson(response);
  }

  Future<DeviceIdentity> revokeDevice(String id, {String? reason}) async {
    final response = await _postObject('/devices/$id/revoke', {
      if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
    });
    return DeviceIdentity.fromJson(response);
  }

  Future<SyncPlan> fetchSyncPlan({String? vaultId}) async {
    final response = await _getObject(
      '/sync/plan',
      queryParameters: {
        if (vaultId != null) 'vault_id': vaultId,
      },
    );
    return SyncPlan.fromJson(response);
  }

  Future<SyncPlan> runSync({String? vaultId, bool dryRun = false}) async {
    final response = await _postObject('/sync/run', {
      if (vaultId != null) 'vault_id': vaultId,
      'dry_run': dryRun,
    });
    return SyncPlan.fromJson(response);
  }

  Future<List<SyncTransfer>> fetchSyncTransfers() async {
    final response = await _getList('/sync/transfers');
    return response.map(SyncTransfer.fromJson).toList();
  }

  Future<SyncNetworkStatus> fetchSyncNetworkStatus() async {
    final response = await _getObject('/sync/network/status');
    return SyncNetworkStatus.fromJson(response);
  }

  Future<SyncNetworkStatus> startSyncNetwork() async {
    final response = await _postObject('/sync/network/start', const {});
    return SyncNetworkStatus.fromJson(response);
  }

  Future<SyncNetworkStatus> stopSyncNetwork() async {
    final response = await _postObject('/sync/network/stop', const {});
    return SyncNetworkStatus.fromJson(response);
  }

  Future<LocalEndpointPayload> fetchLocalEndpoint() async {
    final response = await _getObject('/sync/network/local-endpoint');
    return LocalEndpointPayload.fromJson(response);
  }

  Future<SyncTransfer> retrySyncTransfer(String id) async {
    final response = await _postObject('/sync/transfers/$id/retry', const {});
    return SyncTransfer.fromJson(response);
  }

  Future<SyncTransfer> cancelSyncTransfer(String id) async {
    final response = await _postObject('/sync/transfers/$id/cancel', const {});
    return SyncTransfer.fromJson(response);
  }

  Future<AssetAvailability> fetchAssetAvailability(String assetId) async {
    final response = await _getObject('/assets/$assetId/availability');
    return AssetAvailability.fromJson(response);
  }

  Future<AssetAvailability> pinLocalAsset(String assetId) async {
    final response = await _postObject('/assets/$assetId/pin-local', const {});
    return AssetAvailability.fromJson(response);
  }

  Future<AssetAvailability> evictLocalAsset(String assetId) async {
    final response =
        await _postObject('/assets/$assetId/evict-local', const {});
    return AssetAvailability.fromJson(response);
  }

  Future<List<WatchFolder>> fetchWatchFolders() async {
    final response = await _getList('/watch-folders');
    return response.map(WatchFolder.fromJson).toList();
  }

  Future<WatchFolder> createWatchFolder(WatchFolderDraft draft) async {
    final response = await _postObject('/watch-folders', draft.toJson());
    return WatchFolder.fromJson(response);
  }

  Future<void> deleteWatchFolder(String id) async {
    await _delete('/watch-folders/$id');
  }

  Future<ImportSession> scanImport(ImportScanRequest request) async {
    final response = await _postObject('/imports/scan', request.toJson());
    return ImportSession.fromJson(response);
  }

  Future<ImportSession> commitImport(ImportCommitRequest request) async {
    final response = await _postObject('/imports/commit', request.toJson());
    return ImportSession.fromJson(response);
  }

  Future<ImportSession> fetchImportSession(String id) async {
    final response = await _getObject('/imports/sessions/$id');
    return ImportSession.fromJson(response);
  }

  Future<List<ImportSession>> fetchImportSessions() async {
    final response = await _getList('/imports/sessions');
    return response.map(ImportSession.fromJson).toList();
  }

  Future<TimelineResponse> fetchTimeline({
    int? limit,
    int? perBucket,
    String? cursor,
    bool includeArchived = false,
  }) async {
    final response = await _getObject(
      '/timeline',
      queryParameters: {
        if (limit != null) 'limit': limit.toString(),
        if (perBucket != null) 'per_bucket': perBucket.toString(),
        if (cursor != null) 'cursor': cursor,
        if (includeArchived) 'include_archived': 'true',
      },
      timeout: _heavyReadTimeout,
    );
    return TimelineResponse.fromJson(response);
  }

  Future<Asset> updateAssetFlags(
    String assetId, {
    bool? favorite,
    bool? archived,
  }) async {
    final response = await _postObject('/assets/$assetId/flags', {
      if (favorite != null) 'favorite': favorite,
      if (archived != null) 'archived': archived,
    });
    return Asset.fromJson(response);
  }

  Future<List<Asset>> updateAssetsFlags(
    List<String> assetIds, {
    bool? favorite,
    bool? archived,
  }) async {
    final response = await _postList('/assets/flags/bulk', {
      'asset_ids': assetIds,
      if (favorite != null) 'favorite': favorite,
      if (archived != null) 'archived': archived,
    });
    return response.map(Asset.fromJson).toList();
  }

  Future<List<Asset>> fetchFavoriteAssets() async {
    final response = await _getList('/assets/favorites');
    return response.map(Asset.fromJson).toList();
  }

  Future<List<Asset>> fetchArchivedAssets() async {
    final response = await _getList('/assets/archived');
    return response.map(Asset.fromJson).toList();
  }

  Future<List<Album>> fetchAlbums() async {
    final response = await _getList('/albums');
    return response.map(Album.fromJson).toList();
  }

  Future<Album> createAlbum({
    required String title,
    List<String> assetIds = const [],
  }) async {
    final response = await _postObject('/albums', {
      'title': title,
      'asset_ids': assetIds,
    });
    return Album.fromJson(response);
  }

  Future<Album> renameAlbum(String id, String title) async {
    final response = await _postObject('/albums/$id/rename', {
      'title': title,
    });
    return Album.fromJson(response);
  }

  Future<List<Asset>> fetchAlbumAssets(String id) async {
    final response = await _getList('/albums/$id/assets');
    return response.map(Asset.fromJson).toList();
  }

  Future<Album> addAlbumAssets(
    String id, {
    required List<String> assetIds,
  }) async {
    final response = await _postObject('/albums/$id/assets', {
      'asset_ids': assetIds,
    });
    return Album.fromJson(response);
  }

  Future<Album> removeAlbumAssets(
    String id, {
    required List<String> assetIds,
  }) async {
    final response = await _postObject('/albums/$id/assets/remove', {
      'asset_ids': assetIds,
    });
    return Album.fromJson(response);
  }

  Future<void> deleteAlbum(String id) async {
    await _delete('/albums/$id');
  }

  Future<List<PersonCluster>> fetchPeople() async {
    final response = await _getList('/people');
    return response.map(PersonCluster.fromJson).toList();
  }

  Future<PersonCluster> createManualPerson({
    required String displayName,
    List<String> assetIds = const [],
  }) async {
    final response = await _postObject('/people/manual', {
      'display_name': displayName,
      'asset_ids': assetIds,
    });
    return PersonCluster.fromJson(response);
  }

  Future<List<Asset>> fetchPersonAssets(String id) async {
    final response = await _getList('/people/$id/assets');
    return response.map(Asset.fromJson).toList();
  }

  Future<JobRecord> indexPeople() async {
    final response = await _postObject('/people/index', const {'force': false});
    return JobRecord.fromJson(response);
  }

  Future<JobRecord> resetPeople() async {
    final response = await _postObject('/people/reset', const {'force': false});
    return JobRecord.fromJson(response);
  }

  Future<PersonCluster> renamePerson(String id, String displayName) async {
    final response = await _postObject(
      '/people/$id/rename',
      {'display_name': displayName},
    );
    return PersonCluster.fromJson(response);
  }

  Future<PersonCluster> hidePerson(
    String id, {
    required bool hidden,
    String? reason,
  }) async {
    final response = await _postObject(
      '/people/$id/hide',
      {'hidden': hidden, if (reason != null) 'reason': reason},
    );
    return PersonCluster.fromJson(response);
  }

  Future<PersonCluster> rejectPersonMatch(
    String id, {
    String? faceTemplateId,
    String? assetId,
    String? reason,
  }) async {
    final response = await _postObject(
      '/people/$id/reject-match',
      {
        if (faceTemplateId != null) 'face_template_id': faceTemplateId,
        if (assetId != null) 'asset_id': assetId,
        if (reason != null) 'reason': reason,
      },
    );
    return PersonCluster.fromJson(response);
  }

  Future<PersonCluster> addPersonAssets(
    String id, {
    required List<String> assetIds,
  }) async {
    final response = await _postObject('/people/$id/assets', {
      'asset_ids': assetIds,
    });
    return PersonCluster.fromJson(response);
  }

  Future<PersonCluster> removePersonAssets(
    String id, {
    required List<String> assetIds,
  }) async {
    final response = await _postObject('/people/$id/assets/remove', {
      'asset_ids': assetIds,
    });
    return PersonCluster.fromJson(response);
  }

  Future<PersonCluster> mergePerson(
    String targetId,
    List<String> sourcePersonIds,
  ) async {
    final response = await _postObject(
      '/people/$targetId/merge',
      {'source_person_ids': sourcePersonIds},
    );
    return PersonCluster.fromJson(response);
  }

  Future<PersonCluster> splitPerson(
    String id, {
    required List<String> faceTemplateIds,
    String? newDisplayName,
  }) async {
    final response = await _postObject(
      '/people/$id/split',
      {
        'face_template_ids': faceTemplateIds,
        if (newDisplayName != null) 'new_display_name': newDisplayName,
      },
    );
    return PersonCluster.fromJson(response);
  }

  Future<List<PlaceCluster>> fetchPlaces() async {
    final response = await _getList('/places');
    return response.map(PlaceCluster.fromJson).toList();
  }

  Future<List<Asset>> fetchPlaceAssets(String id) async {
    final response = await _getList('/places/$id/assets');
    return response.map(Asset.fromJson).toList();
  }

  Future<JobRecord> rebuildPlaces() async {
    final response = await _postObject('/places/rebuild', const {
      'force': false,
    });
    return JobRecord.fromJson(response);
  }

  Future<PlaceCluster> correctPlace(
    String id, {
    required String label,
    double? latitude,
    double? longitude,
    bool? hideExactGps,
    String? reason,
  }) async {
    final response = await _postObject('/places/$id/correct', {
      'label': label,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (hideExactGps != null) 'hide_exact_gps': hideExactGps,
      if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
    });
    return PlaceCluster.fromJson(response);
  }

  Future<List<EventCluster>> fetchEvents() async {
    final response = await _getList('/events', timeout: _startupTimeout);
    return response.map(EventCluster.fromJson).toList();
  }

  Future<List<Asset>> fetchEventAssets(String id) async {
    final response = await _getList('/events/$id/assets');
    return response.map(Asset.fromJson).toList();
  }

  Future<JobRecord> rebuildEvents() async {
    final response = await _postObject('/events/rebuild', const {
      'force': false,
    });
    return JobRecord.fromJson(response);
  }

  Future<EventCluster> titleEvent(String id, String title) async {
    final response = await _postObject('/events/$id/title', {'title': title});
    return EventCluster.fromJson(response);
  }

  Future<List<JobRecord>> fetchJobs() async {
    final response = await _getList('/jobs', timeout: _startupTimeout);
    return response.map(JobRecord.fromJson).toList();
  }

  Future<JobRecord> fetchJob(String id) async {
    final response = await _getObject('/jobs/$id');
    return JobRecord.fromJson(response);
  }

  Future<List<JobLog>> fetchJobLogs(String id) async {
    final response = await _getList('/jobs/$id/logs');
    return response.map(JobLog.fromJson).toList();
  }

  Future<JobRecord> cancelJob(String id) async {
    final response = await _postObject('/jobs/$id/cancel', const {});
    return JobRecord.fromJson(response);
  }

  Future<JobRecord> retryJob(String id) async {
    final response = await _postObject('/jobs/$id/retry', const {});
    return JobRecord.fromJson(response);
  }

  Future<SearchResponse> search(SearchQuery query) async {
    final response = await _getObject(
      '/search',
      queryParameters: query.toQueryParameters(),
    );
    return SearchResponse.fromJson(response);
  }

  Future<SearchIndexStatus> fetchSearchStatus() async {
    final response = await _getObject('/search/status');
    return SearchIndexStatus.fromJson(response);
  }

  Future<JobRecord> rebuildOcr({int? limit}) async {
    final payload = <String, dynamic>{'force': false};
    if (limit != null) {
      payload['limit'] = limit;
    }
    final response = await _postObject(
      '/ocr/rebuild',
      payload,
      timeout: const Duration(minutes: 2),
    );
    return JobRecord.fromJson(response);
  }

  Future<JobRecord> rebuildScenes({int? limit}) async {
    final payload = <String, dynamic>{'force': false};
    if (limit != null) {
      payload['limit'] = limit;
    }
    final response = await _postObject(
      '/scenes/rebuild',
      payload,
      timeout: const Duration(minutes: 2),
    );
    return JobRecord.fromJson(response);
  }

  Future<List<OcrBlock>> fetchAssetOcrBlocks(String assetId) async {
    final response = await _getList('/ocr/assets/$assetId');
    return response.map(OcrBlock.fromJson).toList();
  }

  Future<Map<String, dynamic>> _getObject(
    String path, {
    Map<String, String>? queryParameters,
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    final response = await _request(
      () => _httpClient.get(
        _resolve(path, queryParameters: queryParameters),
        headers: headers,
      ),
      path,
      timeout: timeout,
    );
    return _decodeObject(response);
  }

  Future<List<Map<String, dynamic>>> _getList(
    String path, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    final response = await _request(
      () => _httpClient.get(_resolve(path), headers: headers),
      path,
      timeout: timeout,
    );
    return _decodeList(response);
  }

  Future<Map<String, dynamic>> _postObject(
    String path,
    Map<String, dynamic> payload, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    final response = await _request(
      () => _httpClient.post(
        _resolve(path),
        headers: {
          'content-type': 'application/json',
          if (headers != null) ...headers,
        },
        body: jsonEncode(payload),
      ),
      path,
      timeout: timeout,
    );
    return _decodeObject(response);
  }

  Future<List<Map<String, dynamic>>> _postList(
    String path,
    Map<String, dynamic> payload, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    final response = await _request(
      () => _httpClient.post(
        _resolve(path),
        headers: {
          'content-type': 'application/json',
          if (headers != null) ...headers,
        },
        body: jsonEncode(payload),
      ),
      path,
      timeout: timeout,
    );
    return _decodeList(response);
  }

  Future<Map<String, dynamic>> _putBytes(
    String path,
    List<int> body, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    final response = await _request(
      () => _httpClient.put(
        _resolve(path),
        headers: {
          'content-type': 'application/octet-stream',
          if (headers != null) ...headers,
        },
        body: body,
      ),
      path,
      timeout: timeout,
    );
    return _decodeObject(response);
  }

  Future<void> _delete(String path) async {
    await _request(
      () => _httpClient.delete(_resolve(path)),
      path,
    );
  }

  Future<http.Response> _request(
    Future<http.Response> Function() send,
    String path, {
    Duration? timeout,
  }) async {
    late final http.Response response;
    try {
      response = await send().timeout(timeout ?? _defaultTimeout);
    } on TimeoutException {
      throw SocketException('Timed out while reaching ${_resolve(path)}');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        path: path,
        statusCode: response.statusCode,
        body: response.body,
      );
    }

    return response;
  }

  Uri _resolve(String path, {Map<String, String>? queryParameters}) {
    final uri = _baseUri.resolve(path);
    if (queryParameters == null || queryParameters.isEmpty) {
      return uri;
    }
    return uri.replace(queryParameters: queryParameters);
  }

  Map<String, dynamic> _decodeObject(http.Response response) {
    final raw = jsonDecode(response.body);
    if (raw is! Map) {
      throw const FormatException('Expected a JSON object response');
    }

    return raw.map(
      (key, value) => MapEntry(key.toString(), value),
    );
  }

  List<Map<String, dynamic>> _decodeList(http.Response response) {
    final raw = jsonDecode(response.body);
    if (raw is! List) {
      throw const FormatException('Expected a JSON list response');
    }

    return raw
        .whereType<Map>()
        .map(
          (item) => item.map(
            (key, value) => MapEntry(key.toString(), value),
          ),
        )
        .toList();
  }

  Map<String, String> _mobileHeaders(String bearerToken) {
    return {'authorization': 'Bearer ${bearerToken.trim()}'};
  }
}
