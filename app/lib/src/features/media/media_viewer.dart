import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/gallery_models.dart';
import '../../widgets/app_ui.dart';

class MediaViewer extends StatelessWidget {
  const MediaViewer({
    super.key,
    required this.asset,
    this.libraryRoot,
    this.onToggleFavorite,
    this.onToggleArchived,
    this.onAddToAlbum,
    this.onAssignPerson,
  });

  final Asset asset;
  final String? libraryRoot;
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onToggleArchived;
  final VoidCallback? onAddToAlbum;
  final VoidCallback? onAssignPerson;

  static Future<void> show(
    BuildContext context, {
    required Asset asset,
    String? libraryRoot,
    VoidCallback? onToggleFavorite,
    VoidCallback? onToggleArchived,
    VoidCallback? onAddToAlbum,
    VoidCallback? onAssignPerson,
  }) {
    final wide = MediaQuery.sizeOf(context).width >= 760;
    if (wide) {
      return showDialog<void>(
        context: context,
        builder: (context) {
          return Dialog(
            insetPadding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1120),
              child: MediaViewer(
                asset: asset,
                libraryRoot: libraryRoot,
                onToggleFavorite: onToggleFavorite,
                onToggleArchived: onToggleArchived,
                onAddToAlbum: onAddToAlbum,
                onAssignPerson: onAssignPerson,
              ),
            ),
          );
        },
      );
    }
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.9,
            ),
            child: MediaViewer(
              asset: asset,
              libraryRoot: libraryRoot,
              onToggleFavorite: onToggleFavorite,
              onToggleArchived: onToggleArchived,
              onAddToAlbum: onAddToAlbum,
              onAssignPerson: onAssignPerson,
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final previewPath = _previewPath(asset, libraryRoot);
    final metadata = asset.metadata;
    final dimensions = metadata?.width != null && metadata?.height != null
        ? '${metadata!.width} x ${metadata.height}'
        : 'Unknown';
    final place = asset.placeHint ?? metadata?.folderHint ?? 'Unknown';
    final geo = metadata?.geo;

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Material(
        color: theme.colorScheme.surface,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        asset.originalFilename,
                        style: theme.textTheme.headlineSmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          AppStatusBadge(
                            label: asset.isAvailable
                                ? 'Available here'
                                : 'Out of network',
                            tone: asset.isAvailable
                                ? AppStatusTone.success
                                : AppStatusTone.warning,
                            icon: asset.isAvailable
                                ? Icons.cloud_done_outlined
                                : Icons.cloud_off_outlined,
                          ),
                          if (asset.favorite)
                            const AppStatusBadge(
                              label: 'Favorite',
                              tone: AppStatusTone.info,
                              icon: Icons.star_rounded,
                            ),
                          if (asset.archived)
                            const AppStatusBadge(
                              label: 'Archived',
                              tone: AppStatusTone.neutral,
                              icon: Icons.archive_outlined,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close),
                  tooltip: 'Close media view',
                ),
              ],
            ),
            const SizedBox(height: 20),
            LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 840;
                final preview = _PreviewPane(asset: asset, path: previewPath);
                final details = _DetailsPane(
                  rows: [
                    AppMetadataRow(label: 'Kind', value: asset.mediaKind),
                    AppMetadataRow(label: 'MIME type', value: asset.mimeType),
                    AppMetadataRow(
                      label: 'Captured',
                      value: DateFormat.yMMMd().add_jm().format(
                        asset.capturedAt.toLocal(),
                      ),
                    ),
                    AppMetadataRow(
                      label: 'Date source',
                      value: metadata?.capturedAtSource ?? 'filesystem',
                    ),
                    AppMetadataRow(label: 'Dimensions', value: dimensions),
                    AppMetadataRow(label: 'Place', value: place),
                    if (geo != null)
                      AppMetadataRow(
                        label: 'GPS',
                        value:
                            '${geo.latitude.toStringAsFixed(5)}, ${geo.longitude.toStringAsFixed(5)}',
                      ),
                    AppMetadataRow(
                      label: 'Import mode',
                      value: asset.importMode.label,
                    ),
                    AppMetadataRow(label: 'Bytes', value: '${asset.bytes}'),
                    AppMetadataRow(
                      label: 'Content hash',
                      value: asset.contentHash,
                      selectable: true,
                    ),
                    AppMetadataRow(
                      label: 'Library path',
                      value: asset.relativeOriginalPath,
                      selectable: true,
                    ),
                    AppMetadataRow(
                      label: 'Source path',
                      value: asset.sourcePath,
                      selectable: true,
                    ),
                    if (metadata?.sidecarTitle != null)
                      AppMetadataRow(
                        label: 'Title',
                        value: metadata!.sidecarTitle!,
                      ),
                    if (metadata?.sidecarDescription != null)
                      AppMetadataRow(
                        label: 'Description',
                        value: metadata!.sidecarDescription!,
                      ),
                  ],
                );
                if (!wide) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      preview,
                      const SizedBox(height: 16),
                      _Actions(
                        asset: asset,
                        onToggleFavorite: onToggleFavorite,
                        onToggleArchived: onToggleArchived,
                        onAddToAlbum: onAddToAlbum,
                        onAssignPerson: onAssignPerson,
                      ),
                      const SizedBox(height: 16),
                      details,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 6, child: preview),
                    const SizedBox(width: 20),
                    Expanded(
                      flex: 4,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _Actions(
                            asset: asset,
                            onToggleFavorite: onToggleFavorite,
                            onToggleArchived: onToggleArchived,
                            onAddToAlbum: onAddToAlbum,
                            onAssignPerson: onAssignPerson,
                          ),
                          const SizedBox(height: 16),
                          details,
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewPane extends StatelessWidget {
  const _PreviewPane({required this.asset, required this.path});

  final Asset asset;
  final String? path;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (path != null)
                Image.file(
                  File(path!),
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => _PreviewFallback(asset: asset),
                )
              else
                _PreviewFallback(asset: asset),
              Positioned(
                left: 12,
                bottom: 12,
                child: AppStatusBadge(
                  label: _assetKindLabel(asset.mediaKind),
                  tone: AppStatusTone.neutral,
                  icon: _assetKindIcon(asset.mediaKind, asset.mimeType),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewFallback extends StatelessWidget {
  const _PreviewFallback({required this.asset});

  final Asset asset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _assetKindIcon(asset.mediaKind, asset.mimeType),
            size: 72,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            asset.isAvailable
                ? 'Preview is not available yet.'
                : 'Original is currently out of network.',
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.asset,
    required this.onToggleFavorite,
    required this.onToggleArchived,
    required this.onAddToAlbum,
    required this.onAssignPerson,
  });

  final Asset asset;
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onToggleArchived;
  final VoidCallback? onAddToAlbum;
  final VoidCallback? onAssignPerson;

  @override
  Widget build(BuildContext context) {
    return AppSurface(
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          FilledButton.icon(
            onPressed: onToggleFavorite,
            icon: Icon(asset.favorite ? Icons.star_border : Icons.star_rounded),
            label: Text(asset.favorite ? 'Unfavorite' : 'Favorite'),
          ),
          OutlinedButton.icon(
            onPressed: onToggleArchived,
            icon: Icon(
              asset.archived
                  ? Icons.unarchive_outlined
                  : Icons.archive_outlined,
            ),
            label: Text(asset.archived ? 'Unarchive' : 'Archive'),
          ),
          OutlinedButton.icon(
            onPressed: onAddToAlbum,
            icon: const Icon(Icons.photo_album_outlined),
            label: const Text('Add to album'),
          ),
          OutlinedButton.icon(
            onPressed: onAssignPerson,
            icon: const Icon(Icons.person_add_alt_1_outlined),
            label: const Text('Assign person'),
          ),
        ],
      ),
    );
  }
}

class _DetailsPane extends StatelessWidget {
  const _DetailsPane({required this.rows});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Details', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final row in rows) ...[
            row,
            if (row != rows.last) const Divider(height: 1),
          ],
        ],
      ),
    );
  }
}

IconData _assetKindIcon(String mediaKind, String mimeType) {
  final kind = mediaKind.toLowerCase();
  final mime = mimeType.toLowerCase();
  if (kind == 'video' || mime.startsWith('video/')) {
    return Icons.play_circle_outline;
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

String? _previewPath(Asset asset, String? libraryRoot) {
  if (asset.mediaKind != 'photo' || !asset.isAvailable) {
    return null;
  }
  if (asset.importMode == ImportMode.reference) {
    return asset.sourcePath.isEmpty ? null : asset.sourcePath;
  }
  final root = libraryRoot;
  if (root == null || root.isEmpty || asset.relativeOriginalPath.isEmpty) {
    return null;
  }
  final separator = root.endsWith('/') || root.endsWith('\\')
      ? ''
      : Platform.pathSeparator;
  final relative = asset.relativeOriginalPath.replaceFirst(
    RegExp(r'^[\\/]+'),
    '',
  );
  return '$root$separator$relative';
}
