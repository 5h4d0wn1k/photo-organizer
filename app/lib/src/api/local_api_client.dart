import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'local_api_platform_io.dart'
    if (dart.library.html) 'local_api_platform_web.dart';
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
  static const _mobileDownloadChunkBytes = 4 * 1024 * 1024;

  LocalApiClient({
    http.Client? httpClient,
    Uri? baseUri,
    Duration defaultTimeout = const Duration(seconds: 3),
    Duration startupTimeout = const Duration(seconds: 15),
    Duration heavyReadTimeout = const Duration(seconds: 45),
  }) : _httpClient = httpClient ?? http.Client(),
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

  Future<DevicePairing> createPairingSession({
    required String deviceName,
    required String platform,
    String? vaultId,
  }) async {
    final response = await _postObject('/pairing/sessions', {
      'device_name': deviceName,
      'platform': platform,
      if (vaultId != null && vaultId.trim().isNotEmpty) 'vault_id': vaultId,
    });
    return DevicePairing.fromJson(response);
  }

  Future<MobilePairResponse> pairMobileDevice({
    required String pairingToken,
    required String deviceName,
    required String platform,
    String? vaultId,
    DeviceStorageProfile? storageProfile,
  }) async {
    final response = await _postObject('/mobile/pair', {
      'pairing_token': pairingToken,
      'device_name': deviceName,
      'platform': platform,
      if (vaultId != null && vaultId.trim().isNotEmpty) 'vault_id': vaultId,
      if (storageProfile != null) 'storage_profile': storageProfile.toJson(),
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

  Future<List<MobileSession>> fetchMobileSessions({
    required String bearerToken,
  }) async {
    final response = await _getList(
      '/mobile/sessions',
      headers: _mobileHeaders(bearerToken),
    );
    return response.map(MobileSession.fromJson).toList();
  }

  Future<DeviceIdentity> updateMobileStorageProfile({
    required String bearerToken,
    required DeviceStorageProfile storageProfile,
  }) async {
    final response = await _postObject('/mobile/storage-profile', {
      'storage_profile': storageProfile.toJson(),
    }, headers: _mobileHeaders(bearerToken));
    return DeviceIdentity.fromJson(response);
  }

  Future<MobileStoragePlan> fetchMobileStoragePlan({
    required String bearerToken,
  }) async {
    final response = await _getObject(
      '/mobile/storage/plan',
      headers: _mobileHeaders(bearerToken),
    );
    return MobileStoragePlan.fromJson(response);
  }

  Future<List<int>> downloadMobileReplicaChunk({
    required String bearerToken,
    required String blobId,
    required int chunkIndex,
  }) async {
    final response = await _request(
      () => _httpClient.get(
        _resolve('/mobile/storage/blobs/$blobId/chunks/$chunkIndex'),
        headers: _mobileHeaders(bearerToken),
      ),
      '/mobile/storage/blobs/$blobId/chunks/$chunkIndex',
      timeout: _heavyReadTimeout,
    );
    return response.bodyBytes;
  }

  Future<MobileReplicaReport> reportMobileReplica({
    required String bearerToken,
    required MobileReplicaAssignment assignment,
    required Map<int, String> chunkProofsByIndex,
  }) async {
    final response = await _postObject(
      '/mobile/storage/blobs/${assignment.blobId}/report',
      {
        'transfer_id': assignment.transferId,
        'chunks': [
          for (final chunk in assignment.chunks)
            chunk.toReportJson(
              proof: chunkProofsByIndex[chunk.chunkIndex] ?? '',
            ),
        ],
      },
      headers: _mobileHeaders(bearerToken),
    );
    return MobileReplicaReport.fromJson(response);
  }

  Future<Map<String, dynamic>> restoreMobileReplicaChunk({
    required String bearerToken,
    required String blobId,
    required int chunkIndex,
    required List<int> bytes,
  }) {
    return _putBytes(
      '/mobile/storage/blobs/$blobId/chunks/$chunkIndex',
      bytes,
      headers: _mobileHeaders(bearerToken),
      timeout: _heavyReadTimeout,
    );
  }

  Future<MobileSessionRefreshResponse> refreshMobileSession({
    required String bearerToken,
  }) async {
    final response = await _postObject(
      '/mobile/session/refresh',
      const {},
      headers: _mobileHeaders(bearerToken),
    );
    return MobileSessionRefreshResponse.fromJson(response);
  }

  Future<MobileSession> revokeCurrentMobileSession({
    required String bearerToken,
  }) async {
    final response = await _postObject(
      '/mobile/session/revoke',
      const {},
      headers: _mobileHeaders(bearerToken),
    );
    return MobileSession.fromJson(response);
  }

  Future<List<MobileSession>> revokeMobileDeviceSessions({
    required String bearerToken,
    required String deviceId,
  }) async {
    final response = await _postList(
      '/mobile/devices/$deviceId/sessions/revoke',
      const {},
      headers: _mobileHeaders(bearerToken),
    );
    return response.map(MobileSession.fromJson).toList();
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

  Future<MobileUpload> fetchMobileUpload({
    required String bearerToken,
    required String uploadId,
  }) async {
    final response = await _getObject(
      '/mobile/uploads/$uploadId',
      headers: _mobileHeaders(bearerToken),
      timeout: _heavyReadTimeout,
    );
    return MobileUpload.fromJson(response);
  }

  Future<MobileUpload> cancelMobileUpload({
    required String bearerToken,
    required String uploadId,
  }) async {
    final response = await _request(
      () => _httpClient.delete(
        _resolve('/mobile/uploads/$uploadId'),
        headers: _mobileHeaders(bearerToken),
      ),
      '/mobile/uploads/$uploadId',
      timeout: _heavyReadTimeout,
    );
    return MobileUpload.fromJson(_decodeObject(response));
  }

  Future<MobileUpload> uploadMobileOriginalChunk({
    required String bearerToken,
    required String uploadId,
    required int offset,
    required List<int> bytes,
  }) async {
    final response = await _putBytes(
      '/mobile/uploads/$uploadId/chunks/$offset',
      bytes,
      headers: _mobileHeaders(bearerToken),
      timeout: _heavyReadTimeout,
    );
    return MobileUpload.fromJson(response);
  }

  Future<MobileUpload> completeMobileUpload({
    required String bearerToken,
    required String uploadId,
  }) async {
    final response = await _postObject(
      '/mobile/uploads/$uploadId/complete',
      const {},
      headers: _mobileHeaders(bearerToken),
      timeout: _heavyReadTimeout,
    );
    return MobileUpload.fromJson(response);
  }

  Future<MobileUpload> uploadMobileOriginalFile({
    required String bearerToken,
    required String uploadId,
    required Object file,
    int chunkSize = 4 * 1024 * 1024,
    void Function(MobileUpload upload)? onProgress,
    FutureOr<bool> Function(MobileUpload upload)? shouldCancel,
  }) async {
    if (chunkSize <= 0) {
      throw ArgumentError.value(chunkSize, 'chunkSize', 'must be positive');
    }
    final localFile = localApiFileFromObject(file);
    final totalBytes = await localApiFileLength(localFile);
    var upload = await fetchMobileUpload(
      bearerToken: bearerToken,
      uploadId: uploadId,
    );
    if (upload.bytesTotal != totalBytes) {
      throw StateError(
        'Reserved upload size ${upload.bytesTotal} does not match file size $totalBytes',
      );
    }
    onProgress?.call(upload);
    if (_isTerminalMobileUpload(upload)) {
      return upload;
    }
    if (await _mobileUploadCancelRequested(shouldCancel, upload)) {
      final canceled = await cancelMobileUpload(
        bearerToken: bearerToken,
        uploadId: uploadId,
      );
      onProgress?.call(canceled);
      return canceled;
    }

    var offset = upload.bytesReceived;
    while (offset < totalBytes) {
      if (await _mobileUploadCancelRequested(shouldCancel, upload)) {
        final canceled = await cancelMobileUpload(
          bearerToken: bearerToken,
          uploadId: uploadId,
        );
        onProgress?.call(canceled);
        return canceled;
      }
      final remaining = totalBytes - offset;
      final readLength = remaining < chunkSize ? remaining : chunkSize;
      final chunk = await localApiReadFileChunk(localFile, offset, readLength);
      if (chunk.isEmpty) {
        throw StateError('File ended before reserved mobile upload completed');
      }
      try {
        upload = await uploadMobileOriginalChunk(
          bearerToken: bearerToken,
          uploadId: uploadId,
          offset: offset,
          bytes: chunk,
        );
      } on ApiException {
        if (await _mobileUploadCancelRequested(shouldCancel, upload)) {
          final canceled = await cancelMobileUpload(
            bearerToken: bearerToken,
            uploadId: uploadId,
          );
          onProgress?.call(canceled);
          return canceled;
        }
        rethrow;
      }
      onProgress?.call(upload);
      if (_isTerminalMobileUpload(upload)) {
        return upload;
      }
      if (await _mobileUploadCancelRequested(shouldCancel, upload)) {
        final canceled = await cancelMobileUpload(
          bearerToken: bearerToken,
          uploadId: uploadId,
        );
        onProgress?.call(canceled);
        return canceled;
      }
      if (upload.bytesReceived <= offset) {
        throw StateError(
          'Mobile upload did not advance past byte offset $offset',
        );
      }
      offset = upload.bytesReceived;
    }

    final completed = await completeMobileUpload(
      bearerToken: bearerToken,
      uploadId: uploadId,
    );
    onProgress?.call(completed);
    return completed;
  }

  bool _isTerminalMobileUpload(MobileUpload upload) {
    return upload.status == MobileUploadStatus.completed ||
        upload.status == MobileUploadStatus.failed ||
        upload.status == MobileUploadStatus.canceled;
  }

  Future<bool> _mobileUploadCancelRequested(
    FutureOr<bool> Function(MobileUpload upload)? shouldCancel,
    MobileUpload upload,
  ) async {
    if (shouldCancel == null) {
      return false;
    }
    return await Future<bool>.value(shouldCancel(upload));
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

  Future<VaultFileTreeResponse> fetchMobileFileTree({
    required String bearerToken,
    bool includeTrashed = false,
  }) async {
    final response = await _getObject(
      '/mobile/files/tree',
      queryParameters: {if (includeTrashed) 'include_trashed': 'true'},
      headers: _mobileHeaders(bearerToken),
      timeout: _heavyReadTimeout,
    );
    return VaultFileTreeResponse.fromJson(response);
  }

  Future<MobileWorkspaceSnapshot> fetchMobileWorkspace({
    required String bearerToken,
  }) async {
    final response = await _getObject(
      '/mobile/workspace',
      headers: _mobileHeaders(bearerToken),
      timeout: _heavyReadTimeout,
    );
    return MobileWorkspaceSnapshot.fromJson(response);
  }

  Future<SearchResponse> searchMobile({
    required String bearerToken,
    required SearchQuery query,
  }) async {
    final response = await _getObject(
      '/mobile/search',
      queryParameters: query.toQueryParameters(),
      headers: _mobileHeaders(bearerToken),
      timeout: _heavyReadTimeout,
    );
    return SearchResponse.fromJson(response);
  }

  Future<AssetAvailability> fetchMobileAssetAvailability({
    required String bearerToken,
    required String assetId,
  }) async {
    final response = await _getObject(
      '/mobile/assets/$assetId/availability',
      headers: _mobileHeaders(bearerToken),
      timeout: _heavyReadTimeout,
    );
    return AssetAvailability.fromJson(response);
  }

  Future<Asset> updateMobileAssetFlags({
    required String bearerToken,
    required String assetId,
    bool? favorite,
    bool? archived,
  }) async {
    final response = await _postObject(
      '/mobile/assets/$assetId/flags',
      {
        if (favorite != null) 'favorite': favorite,
        if (archived != null) 'archived': archived,
      },
      headers: _mobileHeaders(bearerToken),
      timeout: _heavyReadTimeout,
    );
    return Asset.fromJson(response);
  }

  Future<Asset> updateMobileAssetTags({
    required String bearerToken,
    required String assetId,
    required List<String> tags,
  }) async {
    final response = await _postObject(
      '/mobile/assets/$assetId/tags',
      {'tags': tags},
      headers: _mobileHeaders(bearerToken),
      timeout: _heavyReadTimeout,
    );
    return Asset.fromJson(response);
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

  Future<List<int>> downloadMobileFileOriginal({
    required String bearerToken,
    required String entryId,
  }) async {
    final response = await _request(
      () => _httpClient.get(
        _resolve('/mobile/files/$entryId/original'),
        headers: _mobileHeaders(bearerToken),
      ),
      '/mobile/files/$entryId/original',
      timeout: _heavyReadTimeout,
    );
    return response.bodyBytes;
  }

  Future<T> downloadMobileOriginalToFile<T extends Object>({
    required String bearerToken,
    required String assetId,
    required T destination,
  }) async {
    final downloaded = await _downloadMobilePathToFile(
      bearerToken: bearerToken,
      path: '/mobile/assets/$assetId/original',
      destination: localApiFileFromObject(destination),
    );
    return downloaded as T;
  }

  Future<T> downloadMobileFileOriginalToFile<T extends Object>({
    required String bearerToken,
    required String entryId,
    required T destination,
  }) async {
    final downloaded = await _downloadMobilePathToFile(
      bearerToken: bearerToken,
      path: '/mobile/files/$entryId/original',
      destination: localApiFileFromObject(destination),
    );
    return downloaded as T;
  }

  Future<List<int>> downloadMobilePreview({
    required String bearerToken,
    required String assetId,
  }) async {
    final response = await _request(
      () => _httpClient.get(
        mobileAssetPreviewUri(assetId),
        headers: mobileAuthorizationHeaders(bearerToken),
      ),
      '/mobile/assets/$assetId/preview',
      timeout: _heavyReadTimeout,
    );
    return response.bodyBytes;
  }

  Uri mobileAssetPreviewUri(String assetId) {
    return _resolve('/mobile/assets/$assetId/preview');
  }

  Map<String, String> mobileAuthorizationHeaders(String bearerToken) {
    return _mobileHeaders(bearerToken);
  }

  Future<DaemonDiagnostics> fetchDiagnostics() async {
    final response = await _getObject('/diagnostics');
    return DaemonDiagnostics.fromJson(response);
  }

  Future<PrivacyStatus> fetchPrivacyStatus() async {
    final response = await _getObject('/privacy/status');
    return PrivacyStatus.fromJson(response);
  }

  Future<EntitlementStatusResponse> fetchEntitlementStatus() async {
    final response = await _getObject('/entitlements/status');
    return EntitlementStatusResponse.fromJson(response);
  }

  Future<PlatformReleaseReadinessResponse>
  fetchPlatformReleaseReadiness() async {
    final response = await _getObject('/release/readiness');
    return PlatformReleaseReadinessResponse.fromJson(response);
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
    final response = await _postObject('/security/encryption/activate', const {
      'confirmed': true,
    });
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

  Future<SupportBundleExportResult> exportSupportBundle({
    required String exportRoot,
    bool includeReleaseReadiness = true,
  }) async {
    final response = await _postObject('/support/bundle', {
      'export_root': exportRoot,
      'include_release_readiness': includeReleaseReadiness,
    });
    return SupportBundleExportResult.fromJson(response);
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
    LibrarySettingsDraft draft,
  ) async {
    final response = await _postObject('/library/settings', draft.toJson());
    return LibrarySettings.fromJson(response);
  }

  Future<List<Vault>> fetchVaults() async {
    final response = await _getList('/vaults');
    return response.map(Vault.fromJson).toList();
  }

  Future<Vault> createVault({
    String? id,
    required String name,
    StoragePolicy? storagePolicy,
  }) async {
    final response = await _postObject('/vaults', {
      if (id != null && id.trim().isNotEmpty) 'id': id.trim(),
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
      queryParameters: {if (vaultId != null) 'vault_id': vaultId},
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

  Future<VaultFileTreeResponse> fetchFileTree({
    String? vaultId,
    bool includeTrashed = false,
  }) async {
    final response = await _getObject(
      '/files/tree',
      queryParameters: {
        if (vaultId != null) 'vault_id': vaultId,
        if (includeTrashed) 'include_trashed': 'true',
      },
      timeout: _heavyReadTimeout,
    );
    return VaultFileTreeResponse.fromJson(response);
  }

  Future<VaultFileEntry> createFileFolder({
    String? vaultId,
    String? parentId,
    required String name,
  }) async {
    final response = await _postObject('/files/folders', {
      if (vaultId != null) 'vault_id': vaultId,
      if (parentId != null) 'parent_id': parentId,
      'name': name,
    });
    return VaultFileEntry.fromJson(response);
  }

  Future<VaultFileEntry> renameFileEntry({
    required String entryId,
    required String name,
  }) async {
    final response = await _patchObject('/files/$entryId', {'name': name});
    return VaultFileEntry.fromJson(response);
  }

  Future<VaultFileEntry> moveFileEntry({
    required String entryId,
    String? parentId,
  }) async {
    final response = await _postObject('/files/$entryId/move', {
      if (parentId != null) 'parent_id': parentId,
    });
    return VaultFileEntry.fromJson(response);
  }

  Future<VaultFileEntry> trashFileEntry(String entryId) async {
    final response = await _postObject('/files/$entryId/trash', const {});
    return VaultFileEntry.fromJson(response);
  }

  Future<VaultFileEntry> restoreFileEntry(String entryId) async {
    final response = await _postObject('/files/$entryId/restore', const {});
    return VaultFileEntry.fromJson(response);
  }

  Future<List<int>> downloadFileOriginal({required String entryId}) async {
    final response = await _request(
      () => _httpClient.get(_resolve('/files/$entryId/original')),
      '/files/$entryId/original',
      timeout: _heavyReadTimeout,
    );
    return response.bodyBytes;
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
    final response = await _postObject(
      '/assets/$assetId/evict-local',
      const {},
    );
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

  Future<DuplicateReviewSummary> fetchDuplicateReviewSummary() async {
    final response = await _getObject('/duplicates');
    return DuplicateReviewSummary.fromJson(response);
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

  Future<Asset> updateAssetTags(
    String assetId, {
    required List<String> tags,
  }) async {
    final response = await _postObject('/assets/$assetId/tags', {'tags': tags});
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
    final response = await _postObject('/albums/$id/rename', {'title': title});
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

  Future<List<SmartFolder>> fetchSmartFolders() async {
    final response = await _getList('/smart-folders');
    return response.map(SmartFolder.fromJson).toList();
  }

  Future<SmartFolder> createSmartFolder({
    required String title,
    required SearchQuery query,
  }) async {
    final response = await _postObject('/smart-folders', {
      'title': title,
      'query': query.toJson(),
    });
    return SmartFolder.fromJson(response);
  }

  Future<SearchResponse> runSmartFolder(String id) async {
    final response = await _getObject('/smart-folders/$id/search');
    return SearchResponse.fromJson(response);
  }

  Future<void> deleteSmartFolder(String id) async {
    await _delete('/smart-folders/$id');
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
    final response = await _postObject('/people/$id/rename', {
      'display_name': displayName,
    });
    return PersonCluster.fromJson(response);
  }

  Future<PersonCluster> hidePerson(
    String id, {
    required bool hidden,
    String? reason,
  }) async {
    final response = await _postObject('/people/$id/hide', {
      'hidden': hidden,
      if (reason != null) 'reason': reason,
    });
    return PersonCluster.fromJson(response);
  }

  Future<PersonCluster> rejectPersonMatch(
    String id, {
    String? faceTemplateId,
    String? assetId,
    String? reason,
  }) async {
    final response = await _postObject('/people/$id/reject-match', {
      if (faceTemplateId != null) 'face_template_id': faceTemplateId,
      if (assetId != null) 'asset_id': assetId,
      if (reason != null) 'reason': reason,
    });
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
    final response = await _postObject('/people/$targetId/merge', {
      'source_person_ids': sourcePersonIds,
    });
    return PersonCluster.fromJson(response);
  }

  Future<PersonCluster> splitPerson(
    String id, {
    required List<String> faceTemplateIds,
    String? newDisplayName,
  }) async {
    final response = await _postObject('/people/$id/split', {
      'face_template_ids': faceTemplateIds,
      if (newDisplayName != null) 'new_display_name': newDisplayName,
    });
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

  Future<List<AuditEvent>> fetchAuditEvents({int? limit}) async {
    final response = await _getList(
      '/audit/events',
      queryParameters: {if (limit != null) 'limit': '$limit'},
      timeout: _startupTimeout,
    );
    return response.map(AuditEvent.fromJson).toList();
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

  Future<Map<String, dynamic>> _patchObject(
    String path,
    Map<String, dynamic> payload, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    final response = await _request(
      () => _httpClient.patch(
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

  Future<LocalApiFile> _downloadMobilePathToFile({
    required String bearerToken,
    required String path,
    required LocalApiFile destination,
  }) async {
    await localApiCreateParent(destination);
    final temp = localApiPartFile(destination);
    var offset = await localApiFileExists(temp)
        ? await localApiFileLength(temp)
        : 0;
    int? expectedTotal;
    var restarted = false;

    while (expectedTotal == null || offset < expectedTotal) {
      final rangeEnd = offset + _mobileDownloadChunkBytes - 1;
      final request = http.Request('GET', _resolve(path))
        ..headers.addAll(_mobileHeaders(bearerToken))
        ..headers['range'] = 'bytes=$offset-$rangeEnd';
      late final http.StreamedResponse response;
      try {
        response = await _httpClient.send(request).timeout(_heavyReadTimeout);
      } on TimeoutException {
        throw localApiTimeoutException(_resolve(path));
      }

      if (response.statusCode == localHttpStatusOk && offset == 0) {
        await localApiWriteStreamToFile(
          response.stream,
          temp,
          append: false,
          expectedBytes: response.contentLength,
          timeout: _heavyReadTimeout,
        );
        expectedTotal = await localApiFileLength(temp);
        offset = expectedTotal;
        break;
      }
      if (response.statusCode == localHttpStatusOk &&
          offset > 0 &&
          !restarted) {
        await response.stream.drain<List<int>>();
        await localApiDeleteFile(temp);
        offset = 0;
        expectedTotal = null;
        restarted = true;
        continue;
      }
      if (response.statusCode == localHttpStatusRequestedRangeNotSatisfiable &&
          offset > 0 &&
          !restarted) {
        await response.stream.drain<List<int>>();
        await localApiDeleteFile(temp);
        offset = 0;
        expectedTotal = null;
        restarted = true;
        continue;
      }
      if (response.statusCode != localHttpStatusPartialContent) {
        throw ApiException(
          path: path,
          statusCode: response.statusCode,
          body: await response.stream.bytesToString(),
        );
      }

      final contentRange = _parseContentRange(
        response.headers['content-range'],
      );
      if (contentRange == null || contentRange.start != offset) {
        throw localApiTransferException(
          'Unexpected content-range for $path: ${response.headers['content-range']}',
        );
      }
      final received = await localApiWriteStreamToFile(
        response.stream,
        temp,
        append: offset != 0,
        expectedBytes: response.contentLength,
        timeout: _heavyReadTimeout,
      );
      final expectedRangeBytes = contentRange.end - contentRange.start + 1;
      if (received != expectedRangeBytes) {
        throw localApiTransferException(
          'Downloaded $received bytes for $path, expected $expectedRangeBytes',
        );
      }
      expectedTotal = contentRange.total;
      offset = contentRange.end + 1;
    }

    if (await localApiFileExists(destination)) {
      await localApiDeleteFile(destination);
    }
    return localApiRenameFile(temp, destination);
  }

  _ContentRange? _parseContentRange(String? value) {
    if (value == null) {
      return null;
    }
    final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(value);
    if (match == null) {
      return null;
    }
    final start = int.parse(match.group(1)!);
    final end = int.parse(match.group(2)!);
    final total = int.parse(match.group(3)!);
    if (end < start || total <= end) {
      return null;
    }
    return _ContentRange(start: start, end: end, total: total);
  }

  Future<void> _delete(String path) async {
    await _request(() => _httpClient.delete(_resolve(path)), path);
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
      throw localApiTimeoutException(_resolve(path));
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

    return raw.map((key, value) => MapEntry(key.toString(), value));
  }

  List<Map<String, dynamic>> _decodeList(http.Response response) {
    final raw = jsonDecode(response.body);
    if (raw is! List) {
      throw const FormatException('Expected a JSON list response');
    }

    return raw
        .whereType<Map>()
        .map(
          (item) => item.map((key, value) => MapEntry(key.toString(), value)),
        )
        .toList();
  }

  Map<String, String> _mobileHeaders(String bearerToken) {
    return {'authorization': 'Bearer ${bearerToken.trim()}'};
  }
}

class _ContentRange {
  const _ContentRange({
    required this.start,
    required this.end,
    required this.total,
  });

  final int start;
  final int end;
  final int total;
}
