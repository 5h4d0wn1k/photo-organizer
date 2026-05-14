import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_gallery_app/src/features/search/search_screen.dart';
import 'package:private_gallery_app/src/models/gallery_models.dart';
import 'package:private_gallery_app/src/repositories/gallery_repository.dart';

void main() {
  testWidgets('starts OCR in a safe local batch', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final repository = _FakeSearchRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchScreen(repository: repository),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Index next 10 photos'));
    await tester.pumpAndSettle();

    expect(repository.ocrLimits, [10]);
    expect(find.text('OCR batch finished'), findsOneWidget);
    expect(find.textContaining('OCR processed 1 asset'), findsOneWidget);
    expect(find.textContaining('OCR coverage is partial'), findsOneWidget);
  });
}

class _FakeSearchRepository implements GalleryRepository {
  final List<int?> ocrLimits = [];

  @override
  Future<SearchIndexStatus?> fetchSearchStatus() async {
    return SearchIndexStatus(
      filenameReady: true,
      metadataReady: true,
      ocrReady: false,
      ocrTextBlockCount: 9,
      ocrIndexedAssetCount: 9,
      ocrTotalPhotoCount: 50434,
      ocrRemainingPhotoCount: 50425,
      sceneReady: false,
      semanticReady: false,
      updatedAt: DateTime.utc(2026, 5, 12),
      detail:
          'Filename/date/place/event search is available. OCR has not been indexed yet.',
    );
  }

  @override
  Future<JobRecord> rebuildOcr({int? limit}) async {
    ocrLimits.add(limit);
    return JobRecord(
      id: 'job-1',
      kind: 'ocr_index',
      status: 'completed',
      progress: 100,
      queuedAt: DateTime.utc(2026, 5, 12),
      startedAt: DateTime.utc(2026, 5, 12),
      completedAt: DateTime.utc(2026, 5, 12),
      detail:
          'OCR processed 1 asset: 1 searchable text block, confirmed 0 no-text assets, skipped 0, failed 0 with batch limit 10',
      cancelRequested: false,
      retryOfJobId: null,
      attempt: 1,
    );
  }

  @override
  Future<JobRecord> rebuildScenes({int? limit}) async {
    return JobRecord(
      id: 'job-scenes',
      kind: 'scene_index',
      status: 'completed',
      progress: 100,
      queuedAt: DateTime.utc(2026, 5, 12),
      startedAt: DateTime.utc(2026, 5, 12),
      completedAt: DateTime.utc(2026, 5, 12),
      detail: 'Scene indexing processed 1 asset.',
      cancelRequested: false,
      retryOfJobId: null,
      attempt: 1,
    );
  }

  @override
  Future<JobRecord> fetchJob(String id) {
    throw UnimplementedError();
  }

  @override
  Future<List<JobLog>> fetchJobLogs(String id) {
    throw UnimplementedError();
  }

  @override
  Future<JobRecord> cancelJob(String id) {
    throw UnimplementedError();
  }

  @override
  Future<JobRecord> retryJob(String id) {
    throw UnimplementedError();
  }

  @override
  Future<PersonCluster> createManualPerson({
    required String displayName,
    List<String> assetIds = const [],
  }) {
    throw UnimplementedError();
  }

  @override
  Future<List<Asset>> fetchPersonAssets(String id) {
    throw UnimplementedError();
  }

  @override
  Future<PersonCluster> addPersonAssets(
    String id, {
    required List<String> assetIds,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<PersonCluster> removePersonAssets(
    String id, {
    required List<String> assetIds,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<SearchResponse> search(String query) {
    throw UnimplementedError();
  }

  @override
  Future<EncryptionActivationResult> activateEncryption() {
    throw UnimplementedError();
  }

  @override
  Future<ModelArtifact> installModel({
    required String id,
    String? sourceUrl,
    String? expectedSha256,
    required bool confirmed,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ModelArtifact> importLocalModel({
    required String id,
    required String localPath,
    String? expectedSha256,
    required bool confirmed,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ModelArtifact> verifyModel(String id) {
    throw UnimplementedError();
  }

  @override
  Future<BackupVerification> verifyBackup({String? exportRoot}) {
    throw UnimplementedError();
  }

  @override
  Future<BackupExportResult> exportBackup({
    required String exportRoot,
    bool includeModels = true,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<WatchFolder> addWatchFolder(WatchFolderDraft draft) {
    throw UnimplementedError();
  }

  @override
  Future<ImportSession> commitImport(ImportCommitRequest request) {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteWatchFolder(String id) {
    throw UnimplementedError();
  }

  @override
  Future<ImportSession> fetchImportSession(String id) {
    throw UnimplementedError();
  }

  @override
  Future<List<ImportSession>> fetchImportSessions() {
    throw UnimplementedError();
  }

  @override
  Future<TimelineResponse> fetchTimelinePage({
    String? cursor,
    int? limit,
    bool includeArchived = false,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<Asset> updateAssetFlags(
    String assetId, {
    bool? favorite,
    bool? archived,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<List<Asset>> updateAssetsFlags(
    List<String> assetIds, {
    bool? favorite,
    bool? archived,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<List<Asset>> fetchFavoriteAssets() {
    throw UnimplementedError();
  }

  @override
  Future<List<Asset>> fetchArchivedAssets() {
    throw UnimplementedError();
  }

  @override
  Future<Album> createAlbum({
    required String title,
    List<String> assetIds = const [],
  }) {
    throw UnimplementedError();
  }

  @override
  Future<List<Asset>> fetchAlbumAssets(String id) {
    throw UnimplementedError();
  }

  @override
  Future<Album> addAlbumAssets(String id, {required List<String> assetIds}) {
    throw UnimplementedError();
  }

  @override
  Future<Album> removeAlbumAssets(String id, {required List<String> assetIds}) {
    throw UnimplementedError();
  }

  @override
  Future<Album> renameAlbum(String id, String title) {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteAlbum(String id) {
    throw UnimplementedError();
  }

  @override
  Future<AppLaunchResult> loadWorkspace({bool attemptStartIfNeeded = false}) {
    throw UnimplementedError();
  }

  @override
  Future<LibrarySettings> saveLibrarySettings(LibrarySettingsDraft draft) {
    throw UnimplementedError();
  }

  @override
  Future<ImportSession> scanImport(ImportScanRequest request) {
    throw UnimplementedError();
  }

  @override
  Future<JobRecord> indexPeople() {
    throw UnimplementedError();
  }

  @override
  Future<JobRecord> resetPeople() {
    throw UnimplementedError();
  }

  @override
  Future<JobRecord> rebuildPlaces() {
    throw UnimplementedError();
  }

  @override
  Future<List<Asset>> fetchPlaceAssets(String id) {
    throw UnimplementedError();
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
    throw UnimplementedError();
  }

  @override
  Future<JobRecord> rebuildEvents() {
    throw UnimplementedError();
  }

  @override
  Future<List<Asset>> fetchEventAssets(String id) {
    throw UnimplementedError();
  }

  @override
  Future<EventCluster> titleEvent(String id, String title) {
    throw UnimplementedError();
  }

  @override
  Future<PersonCluster> renamePerson(String id, String displayName) {
    throw UnimplementedError();
  }

  @override
  Future<PersonCluster> hidePerson(
    String id, {
    required bool hidden,
    String? reason,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<PersonCluster> rejectPersonMatch(
    String id, {
    String? faceTemplateId,
    String? assetId,
    String? reason,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<PersonCluster> mergePerson(String targetId, List<String> sourceIds) {
    throw UnimplementedError();
  }

  @override
  Future<PersonCluster> splitPerson(
    String id, {
    required List<String> faceTemplateIds,
    String? newDisplayName,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<List<Vault>> fetchVaults() {
    throw UnimplementedError();
  }

  @override
  Future<Vault> createVault({
    required String name,
    StoragePolicy? storagePolicy,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<VaultStatus> fetchVaultStatus(String id) {
    throw UnimplementedError();
  }

  @override
  Future<Vault> updateVaultStoragePolicy(String id, StoragePolicy policy) {
    throw UnimplementedError();
  }

  @override
  Future<List<DeviceIdentity>> fetchDevices() {
    throw UnimplementedError();
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
    throw UnimplementedError();
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
    throw UnimplementedError();
  }

  @override
  Future<DeviceIdentity> revokeDevice(String id, {String? reason}) {
    throw UnimplementedError();
  }

  @override
  Future<SyncPlan> fetchSyncPlan({String? vaultId}) {
    throw UnimplementedError();
  }

  @override
  Future<SyncPlan> runSync({String? vaultId, bool dryRun = false}) {
    throw UnimplementedError();
  }

  @override
  Future<List<SyncTransfer>> fetchSyncTransfers() {
    throw UnimplementedError();
  }

  @override
  Future<AssetAvailability> fetchAssetAvailability(String assetId) {
    throw UnimplementedError();
  }

  @override
  Future<AssetAvailability> pinLocalAsset(String assetId) {
    throw UnimplementedError();
  }

  @override
  Future<AssetAvailability> evictLocalAsset(String assetId) {
    throw UnimplementedError();
  }
}
