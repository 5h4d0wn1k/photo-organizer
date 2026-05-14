import '../models/gallery_models.dart';

abstract class GalleryRepository {
  Future<AppLaunchResult> loadWorkspace({bool attemptStartIfNeeded = false});
  Future<EncryptionActivationResult> activateEncryption();
  Future<ModelArtifact> installModel({
    required String id,
    String? sourceUrl,
    String? expectedSha256,
    required bool confirmed,
  });
  Future<ModelArtifact> importLocalModel({
    required String id,
    required String localPath,
    String? expectedSha256,
    required bool confirmed,
  });
  Future<ModelArtifact> verifyModel(String id);
  Future<BackupVerification> verifyBackup({String? exportRoot});
  Future<BackupExportResult> exportBackup({
    required String exportRoot,
    bool includeModels,
  });
  Future<LibrarySettings> saveLibrarySettings(LibrarySettingsDraft draft);
  Future<List<Vault>> fetchVaults();
  Future<Vault> createVault({
    required String name,
    StoragePolicy? storagePolicy,
  });
  Future<VaultStatus> fetchVaultStatus(String id);
  Future<Vault> updateVaultStoragePolicy(String id, StoragePolicy policy);
  Future<List<DeviceIdentity>> fetchDevices();
  Future<DeviceIdentity> createDevice({
    required String displayName,
    required String platform,
    String? publicKey,
    DeviceTrustLevel? trustLevel,
    DeviceRole? role,
    DeviceStorageProfile? storageProfile,
  });
  Future<DeviceIdentity> enrollDevice({
    required String displayName,
    required String platform,
    String? publicKey,
    String? vaultId,
    DeviceTrustLevel? trustLevel,
    DeviceRole? role,
    DeviceStorageProfile? storageProfile,
  });
  Future<DeviceIdentity> revokeDevice(String id, {String? reason});
  Future<SyncPlan> fetchSyncPlan({String? vaultId});
  Future<SyncPlan> runSync({String? vaultId, bool dryRun});
  Future<List<SyncTransfer>> fetchSyncTransfers();
  Future<AssetAvailability> fetchAssetAvailability(String assetId);
  Future<AssetAvailability> pinLocalAsset(String assetId);
  Future<AssetAvailability> evictLocalAsset(String assetId);
  Future<WatchFolder> addWatchFolder(WatchFolderDraft draft);
  Future<void> deleteWatchFolder(String id);
  Future<ImportSession> scanImport(ImportScanRequest request);
  Future<ImportSession> commitImport(ImportCommitRequest request);
  Future<ImportSession> fetchImportSession(String id);
  Future<List<ImportSession>> fetchImportSessions();
  Future<TimelineResponse> fetchTimelinePage({
    String? cursor,
    int? limit,
    bool includeArchived = false,
  });
  Future<Asset> updateAssetFlags(
    String assetId, {
    bool? favorite,
    bool? archived,
  });
  Future<List<Asset>> updateAssetsFlags(
    List<String> assetIds, {
    bool? favorite,
    bool? archived,
  });
  Future<List<Asset>> fetchFavoriteAssets();
  Future<List<Asset>> fetchArchivedAssets();
  Future<Album> createAlbum({
    required String title,
    List<String> assetIds,
  });
  Future<List<Asset>> fetchAlbumAssets(String id);
  Future<Album> addAlbumAssets(
    String id, {
    required List<String> assetIds,
  });
  Future<Album> removeAlbumAssets(
    String id, {
    required List<String> assetIds,
  });
  Future<Album> renameAlbum(String id, String title);
  Future<void> deleteAlbum(String id);
  Future<SearchResponse> search(String query);
  Future<SearchIndexStatus?> fetchSearchStatus();
  Future<JobRecord> rebuildOcr({int? limit});
  Future<JobRecord> rebuildScenes({int? limit});
  Future<JobRecord> fetchJob(String id);
  Future<List<JobLog>> fetchJobLogs(String id);
  Future<JobRecord> cancelJob(String id);
  Future<JobRecord> retryJob(String id);
  Future<PersonCluster> createManualPerson({
    required String displayName,
    List<String> assetIds,
  });
  Future<List<Asset>> fetchPersonAssets(String id);
  Future<PersonCluster> addPersonAssets(
    String id, {
    required List<String> assetIds,
  });
  Future<PersonCluster> removePersonAssets(
    String id, {
    required List<String> assetIds,
  });
  Future<JobRecord> indexPeople();
  Future<JobRecord> resetPeople();
  Future<JobRecord> rebuildPlaces();
  Future<List<Asset>> fetchPlaceAssets(String id);
  Future<PlaceCluster> correctPlace(
    String id, {
    required String label,
    double? latitude,
    double? longitude,
    bool? hideExactGps,
    String? reason,
  });
  Future<JobRecord> rebuildEvents();
  Future<List<Asset>> fetchEventAssets(String id);
  Future<EventCluster> titleEvent(String id, String title);
  Future<PersonCluster> renamePerson(String id, String displayName);
  Future<PersonCluster> hidePerson(
    String id, {
    required bool hidden,
    String? reason,
  });
  Future<PersonCluster> rejectPersonMatch(
    String id, {
    String? faceTemplateId,
    String? assetId,
    String? reason,
  });
  Future<PersonCluster> mergePerson(String targetId, List<String> sourceIds);
  Future<PersonCluster> splitPerson(
    String id, {
    required List<String> faceTemplateIds,
    String? newDisplayName,
  });
}
