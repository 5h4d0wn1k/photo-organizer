import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/gallery_models.dart';

class MobileGalleryPanel extends StatelessWidget {
  const MobileGalleryPanel({
    super.key,
    required this.assets,
    required this.loading,
    required this.busy,
    this.error,
    this.onRefresh,
    this.onCheckSession,
    this.onUploadNewestItem,
    this.onOpenAsset,
    this.previewImageFor,
  });

  final List<MobileAssetSummary> assets;
  final bool loading;
  final bool busy;
  final String? error;
  final VoidCallback? onRefresh;
  final VoidCallback? onCheckSession;
  final VoidCallback? onUploadNewestItem;
  final ValueChanged<MobileAssetSummary>? onOpenAsset;
  final ImageProvider<Object>? Function(MobileAssetSummary asset)?
  previewImageFor;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: busy ? null : onRefresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
            OutlinedButton.icon(
              onPressed: busy ? null : onUploadNewestItem,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('Upload'),
            ),
            IconButton.outlined(
              onPressed: busy ? null : onCheckSession,
              icon: const Icon(Icons.verified_user_outlined),
              tooltip: 'Check session',
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: Text(
                '${assets.length} item${assets.length == 1 ? '' : 's'}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (loading)
              const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        if (error != null) ...[
          const SizedBox(height: 12),
          _MobileGalleryNotice(
            icon: Icons.warning_amber_outlined,
            title: 'Gallery unavailable',
            message: error!,
          ),
        ],
        const SizedBox(height: 12),
        if (assets.isEmpty && !loading)
          _MobileGalleryNotice(
            icon: Icons.photo_library_outlined,
            title: 'No group media yet',
            message: 'Upload from this phone or import media on the desktop.',
            action: onUploadNewestItem == null
                ? null
                : OutlinedButton.icon(
                    onPressed: busy ? null : onUploadNewestItem,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: const Text('Upload'),
                  ),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final crossAxisCount = constraints.maxWidth >= 700 ? 3 : 2;
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: assets.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: 0.78,
                ),
                itemBuilder: (context, index) {
                  return _MobileAssetTile(
                    asset: assets[index],
                    previewImage: previewImageFor?.call(assets[index]),
                    onTap: onOpenAsset == null
                        ? null
                        : () => onOpenAsset!(assets[index]),
                  );
                },
              );
            },
          ),
      ],
    );
  }
}

class _MobileAssetTile extends StatelessWidget {
  const _MobileAssetTile({required this.asset, this.previewImage, this.onTap});

  final MobileAssetSummary asset;
  final ImageProvider<Object>? previewImage;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isVideo =
        asset.mediaKind == 'video' || asset.mimeType.startsWith('video/');
    final kindIcon = _assetKindIcon(asset.mediaKind, asset.mimeType);
    final preview = previewImage;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Semantics(
      button: onTap != null,
      label: asset.originalFilename,
      child: Material(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ColoredBox(
                  color: isVideo
                      ? colorScheme.secondaryContainer
                      : colorScheme.primaryContainer,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (preview != null)
                        Image(
                          image: preview,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _AssetTypeIcon(
                            icon: kindIcon,
                            colorScheme: colorScheme,
                          ),
                        )
                      else
                        _AssetTypeIcon(
                          icon: kindIcon,
                          colorScheme: colorScheme,
                        ),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.black.withValues(alpha: 0.02),
                              Colors.black.withValues(alpha: 0.12),
                            ],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                        ),
                      ),
                      Positioned(
                        right: 8,
                        top: 8,
                        child: Icon(
                          asset.available
                              ? Icons.cloud_done_outlined
                              : Icons.cloud_off_outlined,
                          size: 20,
                          color: isVideo
                              ? colorScheme.onSecondaryContainer
                              : colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      asset.originalFilename,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      DateFormat.yMMMd().format(asset.capturedAt.toLocal()),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_assetKindLabel(asset.mediaKind)} • ${_formatBytes(asset.bytes)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssetTypeIcon extends StatelessWidget {
  const _AssetTypeIcon({required this.icon, required this.colorScheme});

  final IconData icon;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Icon(icon, size: 42, color: colorScheme.onPrimaryContainer),
    );
  }
}

IconData _assetKindIcon(String mediaKind, String mimeType) {
  final kind = mediaKind.toLowerCase();
  final mime = mimeType.toLowerCase();
  if (kind == 'video' || mime.startsWith('video/')) {
    return Icons.videocam_outlined;
  }
  if (kind == 'document' || mime == 'application/pdf') {
    return Icons.description_outlined;
  }
  if (kind == 'audio' || mime.startsWith('audio/')) {
    return Icons.audiotrack_outlined;
  }
  if (kind == 'archive') {
    return Icons.folder_zip_outlined;
  }
  if (kind == 'text' || mime.startsWith('text/')) {
    return Icons.article_outlined;
  }
  if (kind == 'other') {
    return Icons.insert_drive_file_outlined;
  }
  return Icons.image_outlined;
}

String _assetKindLabel(String mediaKind) {
  return switch (mediaKind.toLowerCase()) {
    'photo' => 'Photo',
    'video' => 'Video',
    'document' => 'Document',
    'audio' => 'Audio',
    'archive' => 'Archive',
    'text' => 'Text',
    'other' => 'File',
    _ => mediaKind,
  };
}

class _MobileGalleryNotice extends StatelessWidget {
  const _MobileGalleryNotice({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 28),
            const SizedBox(height: 10),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(message),
            if (action != null) ...[const SizedBox(height: 12), action!],
          ],
        ),
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  final kb = bytes / 1024;
  if (kb < 1024) {
    return '${kb.toStringAsFixed(kb >= 100 ? 0 : 1)} KB';
  }
  final mb = kb / 1024;
  if (mb < 1024) {
    return '${mb.toStringAsFixed(mb >= 100 ? 0 : 1)} MB';
  }
  final gb = mb / 1024;
  return '${gb.toStringAsFixed(gb >= 100 ? 0 : 1)} GB';
}
