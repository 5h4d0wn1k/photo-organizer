import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_gallery_app/src/features/archive/archive_screen.dart';
import 'package:private_gallery_app/src/models/gallery_models.dart';
import 'package:private_gallery_app/src/repositories/gallery_repository.dart';

void main() {
  testWidgets('archive screen opens media view and can unarchive media', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final repository = _FakeArchiveRepository([_asset(archived: true)]);
    var libraryChanged = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ArchiveScreen(
            repository: repository,
            libraryRoot: '/tmp/library',
            onLibraryChanged: () async {
              libraryChanged += 1;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Archive'), findsOneWidget);
    expect(find.text('archive.jpg'), findsOneWidget);

    await tester.tap(find.text('archive.jpg'));
    await tester.pumpAndSettle();
    expect(find.text('Details'), findsOneWidget);

    final unarchiveButton = find.widgetWithText(OutlinedButton, 'Unarchive');
    await tester.ensureVisible(unarchiveButton);
    await tester.tap(unarchiveButton);
    await tester.pumpAndSettle();

    expect(repository.updatedArchived, isFalse);
    expect(libraryChanged, 1);
  });
}

class _FakeArchiveRepository implements GalleryRepository {
  _FakeArchiveRepository(this.assets);

  List<Asset> assets;
  bool? updatedArchived;

  @override
  Future<List<Asset>> fetchArchivedAssets() async {
    return assets.where((asset) => asset.archived).toList();
  }

  @override
  Future<Asset> updateAssetFlags(
    String assetId, {
    bool? favorite,
    bool? archived,
  }) async {
    updatedArchived = archived;
    final current = assets.firstWhere((asset) => asset.id == assetId);
    final updated = _asset(
      id: current.id,
      archived: archived ?? current.archived,
      favorite: favorite ?? current.favorite,
    );
    assets = [updated];
    return updated;
  }

  @override
  Future<AssetAvailability> fetchAssetAvailability(String assetId) async {
    return _availability(assetId);
  }

  @override
  Future<AssetAvailability> pinLocalAsset(String assetId) async {
    return _availability(assetId);
  }

  @override
  Future<AssetAvailability> evictLocalAsset(String assetId) async {
    return _availability(assetId, localReplica: false);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(invocation.memberName.toString());
  }
}

AssetAvailability _availability(String assetId, {bool localReplica = true}) {
  return AssetAvailability(
    assetId: assetId,
    vaultId: 'vault-1',
    state: localReplica
        ? AssetAvailabilityState.localAvailable
        : AssetAvailabilityState.remoteAvailable,
    localReplica: localReplica,
    reachableReplicaDeviceIds: localReplica ? const [] : const ['device-2'],
    offlineReplicaDeviceIds: const [],
    replicaCount: 2,
    requiredReplicaCount: 2,
    detail: localReplica
        ? 'original is available on this device'
        : 'original is stored on another reachable device',
  );
}

Asset _asset({
  String id = 'asset-1',
  bool archived = false,
  bool favorite = false,
}) {
  return Asset(
    id: id,
    originalFilename: 'archive.jpg',
    relativeOriginalPath: 'originals/2026/05/archive.jpg',
    sourcePath: '/tmp/archive.jpg',
    importMode: ImportMode.reference,
    isAvailable: true,
    contentHash: 'hash-archive',
    mediaKind: 'photo',
    bytes: 100,
    mimeType: 'image/jpeg',
    capturedAt: DateTime.utc(2026, 5, 13),
    importedAt: DateTime.utc(2026, 5, 13, 1),
    archived: archived,
    favorite: favorite,
    placeHint: 'Home',
    metadata: null,
    variants: const [],
  );
}
