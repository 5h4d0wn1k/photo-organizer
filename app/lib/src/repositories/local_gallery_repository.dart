import 'dart:io';

import '../api/local_api_client.dart';
import '../models/gallery_models.dart';
import '../services/local_daemon_launcher.dart';
import 'gallery_repository.dart';

class LocalGalleryRepository implements GalleryRepository {
  LocalGalleryRepository(this._apiClient, {LocalDaemonLauncher? daemonLauncher})
    : _daemonLauncher = daemonLauncher ?? const LocalDaemonLauncher();

  final LocalApiClient _apiClient;
  final LocalDaemonLauncher _daemonLauncher;
  static const int _startupTimelineAssetLimit = 1500;

  @override
  Future<AppLaunchResult> loadWorkspace({
    bool attemptStartIfNeeded = false,
  }) async {
    var launchResult = const DaemonLaunchResult.none();

    try {
      await _apiClient.fetchHealth();
    } on SocketException catch (_) {
      if (!attemptStartIfNeeded) {
        return AppLaunchResult.daemonUnavailable(
          launchResult: launchResult,
          message:
              'The local gallery daemon is not reachable at http://127.0.0.1:4821.',
        );
      }

      launchResult = await _daemonLauncher.ensureRunning(_apiClient);
      if (!launchResult.started) {
        return AppLaunchResult.daemonUnavailable(
          launchResult: launchResult,
          message: launchResult.message,
        );
      }
    } catch (error) {
      return AppLaunchResult.error(
        launchResult: launchResult,
        message: 'Unable to contact the local API: $error',
      );
    }

    final diagnostics = await _safeDiagnostics();
    final privacyStatus = await _safePrivacyStatus();
    final entitlementStatus = await _safeEntitlementStatus();
    final platformReleaseReadiness = await _safePlatformReleaseReadiness();

    try {
      final status = await _apiClient.fetchLibraryStatus();
      if (!status.isInitialized || status.settings == null) {
        return AppLaunchResult.setupRequired(
          libraryStatus: status,
          launchResult: launchResult,
          diagnostics: diagnostics,
          message:
              'Set the master library root and default import mode before the desktop client can show timeline data.',
        );
      }

      final dashboard = await _loadDashboard();
      return AppLaunchResult.ready(
        workspace: WorkspaceSnapshot(
          status: status,
          dashboard: dashboard,
          diagnostics: diagnostics,
          privacyStatus: privacyStatus,
          entitlementStatus: entitlementStatus,
          platformReleaseReadiness: platformReleaseReadiness,
        ),
        launchResult: launchResult,
      );
    } on ApiException catch (error) {
      return AppLaunchResult.error(
        launchResult: launchResult,
        diagnostics: diagnostics,
        message:
            'The local API returned ${error.statusCode} for ${error.path}.',
      );
    } catch (error) {
      return AppLaunchResult.error(
        launchResult: launchResult,
        diagnostics: diagnostics,
        message: 'Unable to load the local library state: $error',
      );
    }
  }

  @override
  Future<LibrarySettings> saveLibrarySettings(LibrarySettingsDraft draft) {
    return _apiClient.saveLibrarySettings(draft);
  }

  @override
  Future<List<Vault>> fetchVaults() {
    return _apiClient.fetchVaults();
  }

  @override
  Future<Vault> createVault({
    String? id,
    required String name,
    StoragePolicy? storagePolicy,
  }) {
    return _apiClient.createVault(
      id: id,
      name: name,
      storagePolicy: storagePolicy,
    );
  }

  @override
  Future<DevicePairing> createPairingSession({
    required String deviceName,
    required String platform,
    String? vaultId,
  }) {
    return _apiClient.createPairingSession(
      deviceName: deviceName,
      platform: platform,
      vaultId: vaultId,
    );
  }

  @override
  Future<VaultStatus> fetchVaultStatus(String id) {
    return _apiClient.fetchVaultStatus(id);
  }

  @override
  Future<Vault> updateVaultStoragePolicy(String id, StoragePolicy policy) {
    return _apiClient.updateVaultStoragePolicy(id, policy);
  }

  @override
  Future<List<DeviceIdentity>> fetchDevices() {
    return _apiClient.fetchDevices();
  }

  @override
  Future<DeviceIdentity> createDevice({
    required String displayName,
    required String platform,
    String? publicKey,
    DeviceTrustLevel? trustLevel,
    DeviceRole? role,
    DeviceStorageProfile? storageProfile,
  }) {
    return _apiClient.createDevice(
      displayName: displayName,
      platform: platform,
      publicKey: publicKey,
      trustLevel: trustLevel,
      role: role,
      storageProfile: storageProfile,
    );
  }

  @override
  Future<DeviceIdentity> enrollDevice({
    required String displayName,
    required String platform,
    String? publicKey,
    String? vaultId,
    DeviceTrustLevel? trustLevel,
    DeviceRole? role,
    DeviceStorageProfile? storageProfile,
    PeerEndpointDescriptor? endpoint,
  }) {
    return _apiClient.enrollDevice(
      displayName: displayName,
      platform: platform,
      publicKey: publicKey,
      vaultId: vaultId,
      trustLevel: trustLevel,
      role: role,
      storageProfile: storageProfile,
      endpoint: endpoint,
    );
  }

  @override
  Future<DeviceIdentity> revokeDevice(String id, {String? reason}) {
    return _apiClient.revokeDevice(id, reason: reason);
  }

  @override
  Future<SyncPlan> fetchSyncPlan({String? vaultId}) {
    return _apiClient.fetchSyncPlan(vaultId: vaultId);
  }

  @override
  Future<SyncPlan> runSync({String? vaultId, bool dryRun = false}) {
    return _apiClient.runSync(vaultId: vaultId, dryRun: dryRun);
  }

  @override
  Future<List<SyncTransfer>> fetchSyncTransfers() {
    return _apiClient.fetchSyncTransfers();
  }

  @override
  Future<SyncNetworkStatus> fetchSyncNetworkStatus() {
    return _apiClient.fetchSyncNetworkStatus();
  }

  @override
  Future<SyncNetworkStatus> startSyncNetwork() {
    return _apiClient.startSyncNetwork();
  }

  @override
  Future<SyncNetworkStatus> stopSyncNetwork() {
    return _apiClient.stopSyncNetwork();
  }

  @override
  Future<LocalEndpointPayload> fetchLocalEndpoint() {
    return _apiClient.fetchLocalEndpoint();
  }

  @override
  Future<SyncTransfer> retrySyncTransfer(String id) {
    return _apiClient.retrySyncTransfer(id);
  }

  @override
  Future<SyncTransfer> cancelSyncTransfer(String id) {
    return _apiClient.cancelSyncTransfer(id);
  }

  @override
  Future<AssetAvailability> fetchAssetAvailability(String assetId) {
    return _apiClient.fetchAssetAvailability(assetId);
  }

  @override
  Future<AssetAvailability> pinLocalAsset(String assetId) {
    return _apiClient.pinLocalAsset(assetId);
  }

  @override
  Future<AssetAvailability> evictLocalAsset(String assetId) {
    return _apiClient.evictLocalAsset(assetId);
  }

  @override
  Future<EncryptionActivationResult> activateEncryption() {
    return _apiClient.activateEncryption();
  }

  @override
  Future<ModelArtifact> installModel({
    required String id,
    String? sourceUrl,
    String? expectedSha256,
    required bool confirmed,
  }) {
    return _apiClient.installModel(
      id: id,
      sourceUrl: sourceUrl,
      expectedSha256: expectedSha256,
      confirmed: confirmed,
    );
  }

  @override
  Future<ModelArtifact> importLocalModel({
    required String id,
    required String localPath,
    String? expectedSha256,
    required bool confirmed,
  }) {
    return _apiClient.importLocalModel(
      id: id,
      localPath: localPath,
      expectedSha256: expectedSha256,
      confirmed: confirmed,
    );
  }

  @override
  Future<ModelArtifact> verifyModel(String id) {
    return _apiClient.verifyModel(id);
  }

  @override
  Future<BackupVerification> verifyBackup({String? exportRoot}) {
    return _apiClient.verifyBackup(exportRoot: exportRoot);
  }

  @override
  Future<BackupExportResult> exportBackup({
    required String exportRoot,
    bool includeModels = true,
  }) {
    return _apiClient.exportBackup(
      exportRoot: exportRoot,
      includeModels: includeModels,
    );
  }

  @override
  Future<SupportBundleExportResult> exportSupportBundle({
    required String exportRoot,
    bool includeReleaseReadiness = true,
  }) {
    return _apiClient.exportSupportBundle(
      exportRoot: exportRoot,
      includeReleaseReadiness: includeReleaseReadiness,
    );
  }

  @override
  Future<BackupRestorePlan> planRestoreBackup({
    required String exportRoot,
    required String restoreRoot,
  }) {
    return _apiClient.planRestoreBackup(
      exportRoot: exportRoot,
      restoreRoot: restoreRoot,
    );
  }

  @override
  Future<BackupRestoreRunResult> runRestoreBackup({
    required String exportRoot,
    required String restoreRoot,
    bool confirmed = true,
  }) {
    return _apiClient.runRestoreBackup(
      exportRoot: exportRoot,
      restoreRoot: restoreRoot,
      confirmed: confirmed,
    );
  }

  @override
  Future<WatchFolder> addWatchFolder(WatchFolderDraft draft) {
    return _apiClient.createWatchFolder(draft);
  }

  @override
  Future<void> deleteWatchFolder(String id) {
    return _apiClient.deleteWatchFolder(id);
  }

  @override
  Future<ImportSession> scanImport(ImportScanRequest request) {
    return _apiClient.scanImport(request);
  }

  @override
  Future<ImportSession> commitImport(ImportCommitRequest request) {
    return _apiClient.commitImport(request);
  }

  @override
  Future<ImportSession> fetchImportSession(String id) {
    return _apiClient.fetchImportSession(id);
  }

  @override
  Future<List<ImportSession>> fetchImportSessions() {
    return _apiClient.fetchImportSessions();
  }

  @override
  Future<TimelineResponse> fetchTimelinePage({
    String? cursor,
    int? limit,
    bool includeArchived = false,
  }) {
    return _apiClient.fetchTimeline(
      cursor: cursor,
      limit: limit ?? _startupTimelineAssetLimit,
      includeArchived: includeArchived,
    );
  }

  @override
  Future<Asset> updateAssetFlags(
    String assetId, {
    bool? favorite,
    bool? archived,
  }) {
    return _apiClient.updateAssetFlags(
      assetId,
      favorite: favorite,
      archived: archived,
    );
  }

  @override
  Future<Asset> updateAssetTags(String assetId, {required List<String> tags}) {
    return _apiClient.updateAssetTags(assetId, tags: tags);
  }

  @override
  Future<List<Asset>> updateAssetsFlags(
    List<String> assetIds, {
    bool? favorite,
    bool? archived,
  }) {
    return _apiClient.updateAssetsFlags(
      assetIds,
      favorite: favorite,
      archived: archived,
    );
  }

  @override
  Future<List<Asset>> fetchFavoriteAssets() {
    return _apiClient.fetchFavoriteAssets();
  }

  @override
  Future<List<Asset>> fetchArchivedAssets() {
    return _apiClient.fetchArchivedAssets();
  }

  @override
  Future<Album> createAlbum({
    required String title,
    List<String> assetIds = const [],
  }) {
    return _apiClient.createAlbum(title: title, assetIds: assetIds);
  }

  @override
  Future<List<Asset>> fetchAlbumAssets(String id) {
    return _apiClient.fetchAlbumAssets(id);
  }

  @override
  Future<Album> addAlbumAssets(String id, {required List<String> assetIds}) {
    return _apiClient.addAlbumAssets(id, assetIds: assetIds);
  }

  @override
  Future<Album> removeAlbumAssets(String id, {required List<String> assetIds}) {
    return _apiClient.removeAlbumAssets(id, assetIds: assetIds);
  }

  @override
  Future<Album> renameAlbum(String id, String title) {
    return _apiClient.renameAlbum(id, title);
  }

  @override
  Future<void> deleteAlbum(String id) {
    return _apiClient.deleteAlbum(id);
  }

  @override
  Future<List<SmartFolder>> fetchSmartFolders() {
    return _apiClient.fetchSmartFolders();
  }

  @override
  Future<SmartFolder> createSmartFolder({
    required String title,
    required SearchQuery query,
  }) {
    return _apiClient.createSmartFolder(title: title, query: query);
  }

  @override
  Future<SearchResponse> runSmartFolder(String id) {
    return _apiClient.runSmartFolder(id);
  }

  @override
  Future<void> deleteSmartFolder(String id) {
    return _apiClient.deleteSmartFolder(id);
  }

  @override
  Future<SearchResponse> search(SearchQuery query) {
    return _apiClient.search(query);
  }

  @override
  Future<SearchIndexStatus?> fetchSearchStatus() async {
    try {
      return await _apiClient.fetchSearchStatus();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<JobRecord> rebuildOcr({int? limit}) {
    return _apiClient.rebuildOcr(limit: limit);
  }

  @override
  Future<JobRecord> rebuildScenes({int? limit}) {
    return _apiClient.rebuildScenes(limit: limit);
  }

  @override
  Future<JobRecord> fetchJob(String id) {
    return _apiClient.fetchJob(id);
  }

  @override
  Future<List<JobLog>> fetchJobLogs(String id) {
    return _apiClient.fetchJobLogs(id);
  }

  @override
  Future<JobRecord> cancelJob(String id) {
    return _apiClient.cancelJob(id);
  }

  @override
  Future<JobRecord> retryJob(String id) {
    return _apiClient.retryJob(id);
  }

  @override
  Future<PersonCluster> createManualPerson({
    required String displayName,
    List<String> assetIds = const [],
  }) {
    return _apiClient.createManualPerson(
      displayName: displayName,
      assetIds: assetIds,
    );
  }

  @override
  Future<List<Asset>> fetchPersonAssets(String id) {
    return _apiClient.fetchPersonAssets(id);
  }

  @override
  Future<PersonCluster> addPersonAssets(
    String id, {
    required List<String> assetIds,
  }) {
    return _apiClient.addPersonAssets(id, assetIds: assetIds);
  }

  @override
  Future<PersonCluster> removePersonAssets(
    String id, {
    required List<String> assetIds,
  }) {
    return _apiClient.removePersonAssets(id, assetIds: assetIds);
  }

  @override
  Future<JobRecord> indexPeople() {
    return _apiClient.indexPeople();
  }

  @override
  Future<JobRecord> resetPeople() {
    return _apiClient.resetPeople();
  }

  @override
  Future<JobRecord> rebuildPlaces() {
    return _apiClient.rebuildPlaces();
  }

  @override
  Future<List<Asset>> fetchPlaceAssets(String id) {
    return _apiClient.fetchPlaceAssets(id);
  }

  @override
  Future<PlaceCluster> correctPlace(
    String id, {
    required String label,
    double? latitude,
    double? longitude,
    bool? hideExactGps,
    String? reason,
  }) {
    return _apiClient.correctPlace(
      id,
      label: label,
      latitude: latitude,
      longitude: longitude,
      hideExactGps: hideExactGps,
      reason: reason,
    );
  }

  @override
  Future<JobRecord> rebuildEvents() {
    return _apiClient.rebuildEvents();
  }

  @override
  Future<List<Asset>> fetchEventAssets(String id) {
    return _apiClient.fetchEventAssets(id);
  }

  @override
  Future<EventCluster> titleEvent(String id, String title) {
    return _apiClient.titleEvent(id, title);
  }

  @override
  Future<PersonCluster> renamePerson(String id, String displayName) {
    return _apiClient.renamePerson(id, displayName);
  }

  @override
  Future<PersonCluster> hidePerson(
    String id, {
    required bool hidden,
    String? reason,
  }) {
    return _apiClient.hidePerson(id, hidden: hidden, reason: reason);
  }

  @override
  Future<PersonCluster> rejectPersonMatch(
    String id, {
    String? faceTemplateId,
    String? assetId,
    String? reason,
  }) {
    return _apiClient.rejectPersonMatch(
      id,
      faceTemplateId: faceTemplateId,
      assetId: assetId,
      reason: reason,
    );
  }

  @override
  Future<PersonCluster> mergePerson(String targetId, List<String> sourceIds) {
    return _apiClient.mergePerson(targetId, sourceIds);
  }

  @override
  Future<PersonCluster> splitPerson(
    String id, {
    required List<String> faceTemplateIds,
    String? newDisplayName,
  }) {
    return _apiClient.splitPerson(
      id,
      faceTemplateIds: faceTemplateIds,
      newDisplayName: newDisplayName,
    );
  }

  Future<GalleryDashboardData> _loadDashboard() async {
    final timeline = await _apiClient.fetchTimeline(
      limit: _startupTimelineAssetLimit,
    );
    final albums = await _apiClient.fetchAlbums();
    final people = await _apiClient.fetchPeople();
    final places = await _apiClient.fetchPlaces();
    final events = await _apiClient.fetchEvents();
    final jobs = await _apiClient.fetchJobs();
    final auditEvents = await _safeAuditEvents();
    final models = await _safeModels();
    final modelRuntimeStatus = await _safeModelRuntimeStatus();

    return GalleryDashboardData(
      timeline: timeline,
      albums: albums,
      people: people,
      places: places,
      events: events,
      auditEvents: auditEvents,
      jobs: jobs,
      models: models,
      modelRuntimeStatus: modelRuntimeStatus,
    );
  }

  Future<DaemonDiagnostics?> _safeDiagnostics() async {
    try {
      return await _apiClient.fetchDiagnostics();
    } catch (_) {
      return null;
    }
  }

  Future<PrivacyStatus?> _safePrivacyStatus() async {
    try {
      return await _apiClient.fetchPrivacyStatus();
    } catch (_) {
      return null;
    }
  }

  Future<EntitlementStatusResponse?> _safeEntitlementStatus() async {
    try {
      return await _apiClient.fetchEntitlementStatus();
    } catch (_) {
      return null;
    }
  }

  Future<PlatformReleaseReadinessResponse?>
  _safePlatformReleaseReadiness() async {
    try {
      return await _apiClient.fetchPlatformReleaseReadiness();
    } catch (_) {
      return null;
    }
  }

  Future<List<ModelArtifact>> _safeModels() async {
    try {
      return await _apiClient.fetchModels();
    } catch (_) {
      return const [];
    }
  }

  Future<List<AuditEvent>> _safeAuditEvents() async {
    try {
      return await _apiClient.fetchAuditEvents(limit: 50);
    } catch (_) {
      return const [];
    }
  }

  Future<ModelRuntimeStatus?> _safeModelRuntimeStatus() async {
    try {
      return await _apiClient.fetchModelRuntimeStatus();
    } catch (_) {
      return null;
    }
  }
}
