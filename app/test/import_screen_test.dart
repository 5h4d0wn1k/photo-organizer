import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_gallery_app/src/features/import/import_screen.dart';
import 'package:private_gallery_app/src/models/gallery_models.dart';
import 'package:private_gallery_app/src/repositories/gallery_repository.dart';

void main() {
  testWidgets('requires move confirmation before committing',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final repository = _FakeGalleryRepository(
      scanSession: _session(status: ImportSessionStatus.scanned),
      commitSession: _session(
        status: ImportSessionStatus.committed,
        importedAssetIds: ['asset-1'],
        movedAssetIds: ['asset-1'],
        sidecarsMoved: 1,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ImportScreen(
          repository: repository,
          defaultImportMode: ImportMode.move,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scanButton = find.widgetWithText(FilledButton, 'Scan source');
    await tester.ensureVisible(scanButton);
    await tester.tap(scanButton);
    await tester.pumpAndSettle();

    expect(find.text('Preflight before moving'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Move verified files'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Move verified files'), findsOneWidget);
    var button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Move verified files'),
    );
    expect(button.onPressed, isNull);

    await tester.tap(
      find.text(
        'I understand selected files will move into the managed library after hash verification.',
      ),
    );
    await tester.pumpAndSettle();
    button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Move verified files'),
    );
    expect(button.onPressed, isNotNull);

    await tester.tap(find.text('Move verified files'));
    await tester.pumpAndSettle();

    expect(repository.commitCalls, 1);
    expect(find.text('Import result'), findsOneWidget);
    expect(find.textContaining('1 imported'), findsOneWidget);
  });

  testWidgets('organized archive preset indexes photos by reference',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final repository = _FakeGalleryRepository(
      scanSession: _session(
        status: ImportSessionStatus.scanned,
        importMode: ImportMode.reference,
      ),
      commitSession: _session(status: ImportSessionStatus.committed),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ImportScreen(
          repository: repository,
          defaultImportMode: ImportMode.move,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Index organized photos'));
    await tester.pumpAndSettle();
    await tester
        .ensureVisible(find.widgetWithText(FilledButton, 'Scan source'));
    await tester.tap(find.widgetWithText(FilledButton, 'Scan source'));
    await tester.pumpAndSettle();

    expect(repository.scanRequests.single.sourcePath,
        '/mnt/windows/transfer/Ok/Photos/Unfiltered');
    expect(repository.scanRequests.single.importMode, ImportMode.reference);
    expect(repository.scanRequests.single.addAsWatchFolder, isTrue);
    expect(repository.scanRequests.single.placeHint, 'Local organized photos');
    expect(find.text('Preflight before importing'), findsOneWidget);
  });
}

class _FakeGalleryRepository implements GalleryRepository {
  _FakeGalleryRepository({
    required this.scanSession,
    required this.commitSession,
  });

  final ImportSession scanSession;
  final ImportSession commitSession;
  int commitCalls = 0;
  final List<ImportScanRequest> scanRequests = [];

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
  Future<BackupRestorePlan> planRestoreBackup({
    required String exportRoot,
    required String restoreRoot,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<BackupRestoreRunResult> runRestoreBackup({
    required String exportRoot,
    required String restoreRoot,
    bool confirmed = true,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ImportSession> scanImport(ImportScanRequest request) async {
    scanRequests.add(request);
    return scanSession;
  }

  @override
  Future<ImportSession> commitImport(ImportCommitRequest request) async {
    commitCalls += 1;
    return commitSession;
  }

  @override
  Future<List<ImportSession>> fetchImportSessions() async {
    return const [];
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
  Future<ImportSession> fetchImportSession(String id) async {
    return scanSession;
  }

  @override
  Future<WatchFolder> addWatchFolder(WatchFolderDraft draft) {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteWatchFolder(String id) {
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
  Future<SearchResponse> search(String query) {
    throw UnimplementedError();
  }

  @override
  Future<SearchIndexStatus?> fetchSearchStatus() {
    throw UnimplementedError();
  }

  @override
  Future<JobRecord> rebuildOcr({int? limit}) {
    throw UnimplementedError();
  }

  @override
  Future<JobRecord> rebuildScenes({int? limit}) {
    throw UnimplementedError();
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
  Future<SyncNetworkStatus> fetchSyncNetworkStatus() {
    throw UnimplementedError();
  }

  @override
  Future<SyncNetworkStatus> startSyncNetwork() {
    throw UnimplementedError();
  }

  @override
  Future<SyncNetworkStatus> stopSyncNetwork() {
    throw UnimplementedError();
  }

  @override
  Future<SyncTransfer> retrySyncTransfer(String id) {
    throw UnimplementedError();
  }

  @override
  Future<SyncTransfer> cancelSyncTransfer(String id) {
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

ImportSession _session({
  required ImportSessionStatus status,
  ImportMode importMode = ImportMode.move,
  List<String> importedAssetIds = const [],
  List<String> movedAssetIds = const [],
  int sidecarsMoved = 0,
}) {
  return ImportSession(
    id: 'session-1',
    sourceKind: ImportSourceKind.folder,
    sourcePath: '/tmp/source',
    importMode: importMode,
    addAsWatchFolder: false,
    status: status,
    createdAt: DateTime.utc(2026, 5, 10, 10),
    completedAt: status == ImportSessionStatus.committed
        ? DateTime.utc(2026, 5, 10, 10, 1)
        : null,
    placeHint: null,
    candidates: [
      ImportCandidate(
        id: 'candidate-1',
        sessionId: 'session-1',
        sourcePath: '/tmp/source/a.jpg',
        originalFilename: 'a.jpg',
        mediaKind: 'photo',
        mimeType: 'image/jpeg',
        bytes: 100,
        capturedAt: null,
        placeHint: null,
        contentHash: 'hash-a',
        duplicateAssetId: null,
        selected: true,
        importMode: importMode,
        destinationPath: '/tmp/source/PrivateGalleryLibrary/originals/a.jpg',
        sidecarPaths: ['/tmp/source/a.jpg.json'],
        safetyStatus: 'ready_to_move_verified_after_commit',
      ),
    ],
    importedAssetIds: importedAssetIds,
    duplicateAssetIds: const [],
    movedAssetIds: movedAssetIds,
    skippedDuplicateIds: const [],
    failedCandidateIds: const [],
    sidecarsMoved: sidecarsMoved,
    unsupportedFilePaths: const [],
    selectedCandidateCount: 1,
    selectedBytes: 100,
    duplicateCount: 0,
    unsupportedCount: 0,
    sidecarCount: 1,
    destinationRoot: '/tmp/source/PrivateGalleryLibrary',
    requiresMoveConfirmation: importMode == ImportMode.move,
    sourceContainsManagedLibrary: true,
    selectedOutsideSourceCount: 0,
  );
}
