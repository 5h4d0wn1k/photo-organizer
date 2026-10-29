import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:private_gallery_app/src/models/gallery_models.dart';
import 'package:private_gallery_app/src/widgets/desktop_asset_preview.dart';

void main() {
  testWidgets('full-size photo decodes a valid local API image', (
    tester,
  ) async {
    final client = _ImageClient();
    Object? imageError;
    debugNetworkImageHttpClientProvider = () => client;
    addTearDown(() {
      debugNetworkImageHttpClientProvider = null;
      PaintingBinding.instance.imageCache.clear();
    });
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopAssetPreview(
            asset: _asset('photo'),
            fullSize: true,
            decodeWidth: 2048,
            fallback: const Text('Preview unavailable'),
          ),
        ),
      );
      tester
          .widget<Image>(find.byType(Image))
          .image
          .resolve(ImageConfiguration.empty)
          .addListener(
            ImageStreamListener(
              (_, _) {},
              onError: (Object error, StackTrace? stack) {
                imageError = error;
              },
            ),
          );
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
        if (find.byType(RawImage).evaluate().isNotEmpty &&
            tester.widget<RawImage>(find.byType(RawImage)).image != null) {
          break;
        }
      }
    });
    expect(client.requested?.queryParameters['full_size'], 'true');
    expect(imageError, isNull);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    expect(find.text('Preview unavailable'), findsNothing);
    expect(tester.takeException(), isNull);
    debugNetworkImageHttpClientProvider = null;
  });

  testWidgets('encrypted managed photo uses private preview, never disk path', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopAssetPreview(
          asset: _asset('photo'),
          fallback: const Text('Preview unavailable'),
        ),
      ),
    );
    final image = tester.widget<Image>(find.byType(Image));
    final resized = image.image as ResizeImage;
    final provider = resized.imageProvider as NetworkImage;
    expect(provider.url, 'http://127.0.0.1:4821/assets/asset-1/preview');
    expect(resized.width, 512);
    await tester.pumpAndSettle();
    expect(find.text('Preview unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('documents show fallback without attempting an image request', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopAssetPreview(
          asset: _asset('document'),
          fallback: const Text('Document'),
        ),
      ),
    );
    expect(find.text('Document'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });
}

Asset _asset(String kind) => Asset(
  id: 'asset-1',
  originalFilename: 'family.jpg',
  relativeOriginalPath: 'encrypted/original',
  sourcePath: '/unavailable/original.jpg',
  importMode: ImportMode.copy,
  isAvailable: true,
  contentHash: 'hash',
  mediaKind: kind,
  bytes: 100,
  mimeType: 'image/jpeg',
  capturedAt: DateTime.utc(2026),
  importedAt: DateTime.utc(2026),
  archived: false,
  favorite: false,
  placeHint: null,
  metadata: null,
  variants: const [],
);

class _ImageClient implements HttpClient {
  Uri? requested;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requested = url;
    return _ImageRequest();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageRequest implements HttpClientRequest {
  @override
  Future<HttpClientResponse> close() async => _ImageResponse();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageResponse extends Stream<List<int>> implements HttpClientResponse {
  final _bytes = image.encodePng(
    image.Image(width: 2, height: 2)..setPixelRgba(0, 0, 255, 0, 0, 255),
  );
  @override
  int get statusCode => HttpStatus.ok;
  @override
  int get contentLength => _bytes.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(_bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
