import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/gallery_models.dart';
import '../../widgets/app_ui.dart';

typedef AssetAvailabilityAction =
    Future<AssetAvailability> Function(String assetId);

class MediaViewer extends StatelessWidget {
  const MediaViewer({
    super.key,
    required this.asset,
    this.libraryRoot,
    this.onToggleFavorite,
    this.onToggleArchived,
    this.onAddToAlbum,
    this.onAssignPerson,
    this.onEditTags,
    this.loadAvailability,
    this.pinLocalAsset,
    this.evictLocalAsset,
  });

  final Asset asset;
  final String? libraryRoot;
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onToggleArchived;
  final VoidCallback? onAddToAlbum;
  final VoidCallback? onAssignPerson;
  final VoidCallback? onEditTags;
  final AssetAvailabilityAction? loadAvailability;
  final AssetAvailabilityAction? pinLocalAsset;
  final AssetAvailabilityAction? evictLocalAsset;

  static Future<void> show(
    BuildContext context, {
    required Asset asset,
    String? libraryRoot,
    VoidCallback? onToggleFavorite,
    VoidCallback? onToggleArchived,
    VoidCallback? onAddToAlbum,
    VoidCallback? onAssignPerson,
    VoidCallback? onEditTags,
    AssetAvailabilityAction? loadAvailability,
    AssetAvailabilityAction? pinLocalAsset,
    AssetAvailabilityAction? evictLocalAsset,
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
                onEditTags: onEditTags,
                loadAvailability: loadAvailability,
                pinLocalAsset: pinLocalAsset,
                evictLocalAsset: evictLocalAsset,
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
              onEditTags: onEditTags,
              loadAvailability: loadAvailability,
              pinLocalAsset: pinLocalAsset,
              evictLocalAsset: evictLocalAsset,
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
                    if (asset.manualTags.isNotEmpty)
                      AppMetadataRow(
                        label: 'Tags',
                        value: asset.manualTags.join(', '),
                      ),
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
                        onEditTags: onEditTags,
                      ),
                      if (loadAvailability != null) ...[
                        const SizedBox(height: 16),
                        _AvailabilityPane(
                          assetId: asset.id,
                          loadAvailability: loadAvailability!,
                          pinLocalAsset: pinLocalAsset,
                          evictLocalAsset: evictLocalAsset,
                        ),
                      ],
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
                            onEditTags: onEditTags,
                          ),
                          if (loadAvailability != null) ...[
                            const SizedBox(height: 16),
                            _AvailabilityPane(
                              assetId: asset.id,
                              loadAvailability: loadAvailability!,
                              pinLocalAsset: pinLocalAsset,
                              evictLocalAsset: evictLocalAsset,
                            ),
                          ],
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

class _AvailabilityPane extends StatefulWidget {
  const _AvailabilityPane({
    required this.assetId,
    required this.loadAvailability,
    required this.pinLocalAsset,
    required this.evictLocalAsset,
  });

  final String assetId;
  final AssetAvailabilityAction loadAvailability;
  final AssetAvailabilityAction? pinLocalAsset;
  final AssetAvailabilityAction? evictLocalAsset;

  @override
  State<_AvailabilityPane> createState() => _AvailabilityPaneState();
}

class _AvailabilityPaneState extends State<_AvailabilityPane> {
  late Future<AssetAvailability> _future;
  var _busy = false;
  String? _actionError;

  @override
  void initState() {
    super.initState();
    _future = widget.loadAvailability(widget.assetId);
  }

  @override
  void didUpdateWidget(covariant _AvailabilityPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assetId != widget.assetId ||
        oldWidget.loadAvailability != widget.loadAvailability) {
      _future = widget.loadAvailability(widget.assetId);
      _actionError = null;
    }
  }

  void _refresh() {
    setState(() {
      _future = widget.loadAvailability(widget.assetId);
      _actionError = null;
    });
  }

  Future<void> _run(AssetAvailabilityAction action) async {
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      final availability = await action(widget.assetId);
      if (!mounted) {
        return;
      }
      setState(() {
        _future = Future.value(availability);
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _actionError = '$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppSurface(
      child: FutureBuilder<AssetAvailability>(
        future: _future,
        builder: (context, snapshot) {
          final availability = snapshot.data;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Availability',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    onPressed: _busy ? null : _refresh,
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Refresh availability',
                  ),
                ],
              ),
              if (snapshot.connectionState != ConnectionState.done &&
                  availability == null)
                const LinearProgressIndicator(minHeight: 2)
              else if (snapshot.hasError && availability == null)
                Text(
                  'Availability unavailable: ${snapshot.error}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                )
              else if (availability != null) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    AppStatusBadge(
                      label: _availabilityLabel(availability.state),
                      tone: _availabilityTone(availability.state),
                      icon: _availabilityIcon(availability.state),
                    ),
                    AppStatusBadge(
                      label:
                          '${availability.replicaCount}/${availability.requiredReplicaCount} replicas',
                      tone:
                          availability.replicaCount >=
                              availability.requiredReplicaCount
                          ? AppStatusTone.success
                          : AppStatusTone.warning,
                      icon: Icons.hub_outlined,
                    ),
                    if (availability.reachableReplicaDeviceIds.isNotEmpty)
                      AppStatusBadge(
                        label:
                            '${availability.reachableReplicaDeviceIds.length} reachable',
                        tone: AppStatusTone.info,
                        icon: Icons.lan_outlined,
                      ),
                    if (availability.offlineReplicaDeviceIds.isNotEmpty)
                      AppStatusBadge(
                        label:
                            '${availability.offlineReplicaDeviceIds.length} offline',
                        tone: AppStatusTone.warning,
                        icon: Icons.cloud_off_outlined,
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(availability.detail),
                if (_actionError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _actionError!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilledButton.icon(
                      onPressed:
                          widget.pinLocalAsset == null ||
                              _busy ||
                              availability.localReplica
                          ? null
                          : () => _run(widget.pinLocalAsset!),
                      icon: _busy
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download_for_offline_outlined),
                      label: Text(
                        availability.localReplica ? 'Pinned here' : 'Pin local',
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed:
                          widget.evictLocalAsset == null ||
                              _busy ||
                              !availability.localReplica
                          ? null
                          : () => _run(widget.evictLocalAsset!),
                      icon: const Icon(Icons.cloud_upload_outlined),
                      label: const Text('Evict local'),
                    ),
                  ],
                ),
              ],
            ],
          );
        },
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
    required this.onEditTags,
  });

  final Asset asset;
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onToggleArchived;
  final VoidCallback? onAddToAlbum;
  final VoidCallback? onAssignPerson;
  final VoidCallback? onEditTags;

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
          OutlinedButton.icon(
            onPressed: onEditTags,
            icon: const Icon(Icons.sell_outlined),
            label: const Text('Edit tags'),
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

String _availabilityLabel(AssetAvailabilityState state) {
  return switch (state) {
    AssetAvailabilityState.localAvailable => 'Local',
    AssetAvailabilityState.remoteAvailable => 'Remote reachable',
    AssetAvailabilityState.remoteOffline => 'Remote offline',
    AssetAvailabilityState.underReplicated => 'Under-replicated',
    AssetAvailabilityState.missing => 'Missing',
    AssetAvailabilityState.corrupt => 'Corrupt',
    AssetAvailabilityState.transferPending => 'Transfer pending',
  };
}

AppStatusTone _availabilityTone(AssetAvailabilityState state) {
  return switch (state) {
    AssetAvailabilityState.localAvailable => AppStatusTone.success,
    AssetAvailabilityState.remoteAvailable => AppStatusTone.info,
    AssetAvailabilityState.remoteOffline => AppStatusTone.warning,
    AssetAvailabilityState.underReplicated => AppStatusTone.warning,
    AssetAvailabilityState.missing => AppStatusTone.danger,
    AssetAvailabilityState.corrupt => AppStatusTone.danger,
    AssetAvailabilityState.transferPending => AppStatusTone.info,
  };
}

IconData _availabilityIcon(AssetAvailabilityState state) {
  return switch (state) {
    AssetAvailabilityState.localAvailable => Icons.cloud_done_outlined,
    AssetAvailabilityState.remoteAvailable => Icons.cloud_download_outlined,
    AssetAvailabilityState.remoteOffline => Icons.cloud_off_outlined,
    AssetAvailabilityState.underReplicated => Icons.warning_amber_outlined,
    AssetAvailabilityState.missing => Icons.report_gmailerrorred_outlined,
    AssetAvailabilityState.corrupt => Icons.gpp_bad_outlined,
    AssetAvailabilityState.transferPending => Icons.sync_outlined,
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
