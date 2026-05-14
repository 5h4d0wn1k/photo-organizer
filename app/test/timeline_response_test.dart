import 'package:flutter_test/flutter_test.dart';
import 'package:private_gallery_app/src/models/gallery_models.dart';

void main() {
  test('timeline response appends cursor pages and merges matching buckets',
      () {
    final first = TimelineResponse(
      buckets: [
        TimelineBucket(
          label: 'May 2026',
          assetIds: const ['asset-1'],
          assets: [_asset('asset-1')],
          totalAssets: 3,
        ),
      ],
      nextCursor: '1',
      totalAssets: 3,
      returnedAssets: 1,
    );
    final second = TimelineResponse(
      buckets: [
        TimelineBucket(
          label: 'May 2026',
          assetIds: const ['asset-2'],
          assets: [_asset('asset-2')],
          totalAssets: 3,
        ),
      ],
      nextCursor: '2',
      totalAssets: 3,
      returnedAssets: 1,
    );

    final merged = first.append(second);

    expect(merged.buckets, hasLength(1));
    expect(merged.buckets.single.assetIds, ['asset-1', 'asset-2']);
    expect(merged.visibleAssetCount, 2);
    expect(merged.nextCursor, '2');
    expect(merged.totalAssets, 3);
  });
}

Asset _asset(String id) {
  return Asset(
    id: id,
    originalFilename: '$id.jpg',
    relativeOriginalPath: 'originals/2026/05/$id.jpg',
    sourcePath: '/tmp/$id.jpg',
    importMode: ImportMode.reference,
    isAvailable: true,
    contentHash: id,
    mediaKind: 'photo',
    bytes: 10,
    mimeType: 'image/jpeg',
    capturedAt: DateTime.utc(2026, 5, 13),
    importedAt: DateTime.utc(2026, 5, 13),
    archived: false,
    favorite: false,
    placeHint: null,
    metadata: null,
    variants: const [],
  );
}
