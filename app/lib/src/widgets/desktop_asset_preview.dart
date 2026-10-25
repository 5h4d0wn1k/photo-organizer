import 'package:flutter/material.dart';

import '../models/gallery_models.dart';

/// Renders media through the private local API rather than opening encrypted
/// managed originals as image files. Decoded images stay in Flutter's memory
/// cache; this widget never exports a decrypted copy to disk.
class DesktopAssetPreview extends StatelessWidget {
  const DesktopAssetPreview({
    super.key,
    required this.asset,
    required this.fallback,
    this.fit = BoxFit.cover,
    this.decodeWidth = 512,
    this.fullSize = false,
  });

  final Asset asset;
  final Widget fallback;
  final BoxFit fit;
  final int decodeWidth;
  final bool fullSize;

  @override
  Widget build(BuildContext context) {
    if (asset.mediaKind != 'photo' && asset.mediaKind != 'video') {
      return fallback;
    }
    // The desktop management API is deliberately loopback-only. Remote peers
    // must use their scoped, authenticated mobile/peer media endpoints.
    final uri = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: 4821,
      pathSegments: ['assets', asset.id, 'preview'],
      queryParameters: fullSize && asset.mediaKind == 'photo'
          ? {'full_size': 'true'}
          : null,
    );
    return Image.network(
      uri.toString(),
      fit: fit,
      cacheWidth: decodeWidth,
      semanticLabel: asset.originalFilename,
      errorBuilder: (_, _, _) => fallback,
      loadingBuilder: (context, child, progress) => progress == null
          ? child
          : const Center(child: CircularProgressIndicator(strokeWidth: 2)),
    );
  }
}
