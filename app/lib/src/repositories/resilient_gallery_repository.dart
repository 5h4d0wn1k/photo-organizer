import '../api/local_api_client.dart';
import '../models/gallery_models.dart';
import 'gallery_repository.dart';
import 'local_gallery_repository.dart';

class ResilientGalleryRepository implements GalleryRepository {
  ResilientGalleryRepository({LocalApiClient? apiClient})
      : _delegate = LocalGalleryRepository(apiClient ?? LocalApiClient());

  final LocalGalleryRepository _delegate;

  @override
  Future<AppLaunchResult> loadWorkspace({bool attemptStartIfNeeded = false}) {
    return _delegate.loadWorkspace(attemptStartIfNeeded: attemptStartIfNeeded);
  }

  @override
  Future<LibrarySettings> saveLibrarySettings(LibrarySettingsDraft draft) {
    return _delegate.saveLibrarySettings(draft);
  }

  @override
  Future<List<Vault>> fetchVaults() {
    return _delegate.fetchVaults();
  }

  @override
  Future<Vault> createVault({
    required String name,
    StoragePolicy? storagePolicy,
  }) {
    return _delegate.createVault(name: name, storagePolicy: storagePolicy);
  }

  @override
  Future<VaultStatus> fetchVaultStatus(String id) {
    return _delegate.fetchVaultStatus(id);
  }

  @override
  Future<Vault> updateVaultStoragePolicy(String id, StoragePolicy policy) {
    return _delegate.updateVaultStoragePolicy(id, policy);
  }

  @override
  Future<List<DeviceIdentity>> fetchDevices() {
    return _delegate.fetchDevices();
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
    return _delegate.createDevice(
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
  }) {
    return _delegate.enrollDevice(
      displayName: displayName,
      platform: platform,
      publicKey: publicKey,
      vaultId: vaultId,
      trustLevel: trustLevel,
      role: role,
      storageProfile: storageProfile,
    );
  }

  @override
  Future<DeviceIdentity> revokeDevice(String id, {String? reason}) {
    return _delegate.revokeDevice(id, reason: reason);
  }

  @override
  Future<SyncPlan> fetchSyncPlan({String? vaultId}) {
    return _delegate.fetchSyncPlan(vaultId: vaultId);
  }

  @override
  Future<SyncPlan> runSync({String? vaultId, bool dryRun = false}) {
    return _delegate.runSync(vaultId: vaultId, dryRun: dryRun);
  }

  @override
  Future<List<SyncTransfer>> fetchSyncTransfers() {
    return _delegate.fetchSyncTransfers();
  }

  @override
  Future<SyncNetworkStatus> fetchSyncNetworkStatus() {
    return _delegate.fetchSyncNetworkStatus();
  }

  @override
  Future<SyncNetworkStatus> startSyncNetwork() {
    return _delegate.startSyncNetwork();
  }

  @override
  Future<SyncNetworkStatus> stopSyncNetwork() {
    return _delegate.stopSyncNetwork();
  }

  @override
  Future<SyncTransfer> retrySyncTransfer(String id) {
    return _delegate.retrySyncTransfer(id);
  }

  @override
  Future<SyncTransfer> cancelSyncTransfer(String id) {
    return _delegate.cancelSyncTransfer(id);
  }

  @override
  Future<AssetAvailability> fetchAssetAvailability(String assetId) {
    return _delegate.fetchAssetAvailability(assetId);
  }

  @override
  Future<AssetAvailability> pinLocalAsset(String assetId) {
    return _delegate.pinLocalAsset(assetId);
  }

  @override
  Future<AssetAvailability> evictLocalAsset(String assetId) {
    return _delegate.evictLocalAsset(assetId);
  }

  @override
  Future<EncryptionActivationResult> activateEncryption() {
    return _delegate.activateEncryption();
  }

  @override
  Future<ModelArtifact> installModel({
    required String id,
    String? sourceUrl,
    String? expectedSha256,
    required bool confirmed,
  }) {
    return _delegate.installModel(
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
    return _delegate.importLocalModel(
      id: id,
      localPath: localPath,
      expectedSha256: expectedSha256,
      confirmed: confirmed,
    );
  }

  @override
  Future<ModelArtifact> verifyModel(String id) {
    return _delegate.verifyModel(id);
  }

  @override
  Future<BackupVerification> verifyBackup({String? exportRoot}) {
    return _delegate.verifyBackup(exportRoot: exportRoot);
  }

  @override
  Future<BackupExportResult> exportBackup({
    required String exportRoot,
    bool includeModels = true,
  }) {
    return _delegate.exportBackup(
      exportRoot: exportRoot,
      includeModels: includeModels,
    );
  }

  @override
  Future<BackupRestorePlan> planRestoreBackup({
    required String exportRoot,
    required String restoreRoot,
  }) {
    return _delegate.planRestoreBackup(
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
    return _delegate.runRestoreBackup(
      exportRoot: exportRoot,
      restoreRoot: restoreRoot,
      confirmed: confirmed,
    );
  }

  @override
  Future<WatchFolder> addWatchFolder(WatchFolderDraft draft) {
    return _delegate.addWatchFolder(draft);
  }

  @override
  Future<void> deleteWatchFolder(String id) {
    return _delegate.deleteWatchFolder(id);
  }

  @override
  Future<ImportSession> scanImport(ImportScanRequest request) {
    return _delegate.scanImport(request);
  }

  @override
  Future<ImportSession> commitImport(ImportCommitRequest request) {
    return _delegate.commitImport(request);
  }

  @override
  Future<ImportSession> fetchImportSession(String id) {
    return _delegate.fetchImportSession(id);
  }

  @override
  Future<List<ImportSession>> fetchImportSessions() {
    return _delegate.fetchImportSessions();
  }

  @override
  Future<TimelineResponse> fetchTimelinePage({
    String? cursor,
    int? limit,
    bool includeArchived = false,
  }) {
    return _delegate.fetchTimelinePage(
      cursor: cursor,
      limit: limit,
      includeArchived: includeArchived,
    );
  }

  @override
  Future<Asset> updateAssetFlags(
    String assetId, {
    bool? favorite,
    bool? archived,
  }) {
    return _delegate.updateAssetFlags(
      assetId,
      favorite: favorite,
      archived: archived,
    );
  }

  @override
  Future<List<Asset>> updateAssetsFlags(
    List<String> assetIds, {
    bool? favorite,
    bool? archived,
  }) {
    return _delegate.updateAssetsFlags(
      assetIds,
      favorite: favorite,
      archived: archived,
    );
  }

  @override
  Future<List<Asset>> fetchFavoriteAssets() {
    return _delegate.fetchFavoriteAssets();
  }

  @override
  Future<List<Asset>> fetchArchivedAssets() {
    return _delegate.fetchArchivedAssets();
  }

  @override
  Future<Album> createAlbum({
    required String title,
    List<String> assetIds = const [],
  }) {
    return _delegate.createAlbum(title: title, assetIds: assetIds);
  }

  @override
  Future<List<Asset>> fetchAlbumAssets(String id) {
    return _delegate.fetchAlbumAssets(id);
  }

  @override
  Future<Album> addAlbumAssets(
    String id, {
    required List<String> assetIds,
  }) {
    return _delegate.addAlbumAssets(id, assetIds: assetIds);
  }

  @override
  Future<Album> removeAlbumAssets(
    String id, {
    required List<String> assetIds,
  }) {
    return _delegate.removeAlbumAssets(id, assetIds: assetIds);
  }

  @override
  Future<Album> renameAlbum(String id, String title) {
    return _delegate.renameAlbum(id, title);
  }

  @override
  Future<void> deleteAlbum(String id) {
    return _delegate.deleteAlbum(id);
  }

  @override
  Future<SearchResponse> search(String query) {
    return _delegate.search(query);
  }

  @override
  Future<SearchIndexStatus?> fetchSearchStatus() {
    return _delegate.fetchSearchStatus();
  }

  @override
  Future<JobRecord> rebuildOcr({int? limit}) {
    return _delegate.rebuildOcr(limit: limit);
  }

  @override
  Future<JobRecord> rebuildScenes({int? limit}) {
    return _delegate.rebuildScenes(limit: limit);
  }

  @override
  Future<JobRecord> fetchJob(String id) {
    return _delegate.fetchJob(id);
  }

  @override
  Future<List<JobLog>> fetchJobLogs(String id) {
    return _delegate.fetchJobLogs(id);
  }

  @override
  Future<JobRecord> cancelJob(String id) {
    return _delegate.cancelJob(id);
  }

  @override
  Future<JobRecord> retryJob(String id) {
    return _delegate.retryJob(id);
  }

  @override
  Future<PersonCluster> createManualPerson({
    required String displayName,
    List<String> assetIds = const [],
  }) {
    return _delegate.createManualPerson(
      displayName: displayName,
      assetIds: assetIds,
    );
  }

  @override
  Future<List<Asset>> fetchPersonAssets(String id) {
    return _delegate.fetchPersonAssets(id);
  }

  @override
  Future<PersonCluster> addPersonAssets(
    String id, {
    required List<String> assetIds,
  }) {
    return _delegate.addPersonAssets(id, assetIds: assetIds);
  }

  @override
  Future<PersonCluster> removePersonAssets(
    String id, {
    required List<String> assetIds,
  }) {
    return _delegate.removePersonAssets(id, assetIds: assetIds);
  }

  @override
  Future<JobRecord> indexPeople() {
    return _delegate.indexPeople();
  }

  @override
  Future<JobRecord> resetPeople() {
    return _delegate.resetPeople();
  }

  @override
  Future<JobRecord> rebuildPlaces() {
    return _delegate.rebuildPlaces();
  }

  @override
  Future<List<Asset>> fetchPlaceAssets(String id) {
    return _delegate.fetchPlaceAssets(id);
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
    return _delegate.correctPlace(
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
    return _delegate.rebuildEvents();
  }

  @override
  Future<List<Asset>> fetchEventAssets(String id) {
    return _delegate.fetchEventAssets(id);
  }

  @override
  Future<EventCluster> titleEvent(String id, String title) {
    return _delegate.titleEvent(id, title);
  }

  @override
  Future<PersonCluster> renamePerson(String id, String displayName) {
    return _delegate.renamePerson(id, displayName);
  }

  @override
  Future<PersonCluster> hidePerson(
    String id, {
    required bool hidden,
    String? reason,
  }) {
    return _delegate.hidePerson(id, hidden: hidden, reason: reason);
  }

  @override
  Future<PersonCluster> rejectPersonMatch(
    String id, {
    String? faceTemplateId,
    String? assetId,
    String? reason,
  }) {
    return _delegate.rejectPersonMatch(
      id,
      faceTemplateId: faceTemplateId,
      assetId: assetId,
      reason: reason,
    );
  }

  @override
  Future<PersonCluster> mergePerson(String targetId, List<String> sourceIds) {
    return _delegate.mergePerson(targetId, sourceIds);
  }

  @override
  Future<PersonCluster> splitPerson(
    String id, {
    required List<String> faceTemplateIds,
    String? newDisplayName,
  }) {
    return _delegate.splitPerson(
      id,
      faceTemplateIds: faceTemplateIds,
      newDisplayName: newDisplayName,
    );
  }
}
