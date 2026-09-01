import 'package:flutter/material.dart';

import '../../models/gallery_models.dart';
import '../../repositories/gallery_repository.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/asset_grid.dart';
import '../../widgets/empty_state_panel.dart';
import '../media/media_viewer.dart';

class ArchiveScreen extends StatefulWidget {
  const ArchiveScreen({
    super.key,
    required this.repository,
    required this.libraryRoot,
    required this.onLibraryChanged,
  });

  final GalleryRepository repository;
  final String libraryRoot;
  final Future<void> Function() onLibraryChanged;

  @override
  State<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends State<ArchiveScreen> {
  late Future<List<Asset>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.repository.fetchArchivedAssets();
  }

  void _reload() {
    setState(() {
      _future = widget.repository.fetchArchivedAssets();
    });
  }

  Future<void> _unarchive(Asset asset) async {
    try {
      await widget.repository.updateAssetFlags(asset.id, archived: false);
      await widget.onLibraryChanged();
      _reload();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${asset.originalFilename} restored.')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _openAsset(Asset asset) {
    return MediaViewer.show(
      context,
      asset: asset,
      libraryRoot: widget.libraryRoot,
      onToggleArchived: () {
        Navigator.of(context).maybePop();
        _unarchive(asset);
      },
      loadAvailability: widget.repository.fetchAssetAvailability,
      pinLocalAsset: widget.repository.pinLocalAsset,
      evictLocalAsset: widget.repository.evictLocalAsset,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Asset>>(
      future: _future,
      builder: (context, snapshot) {
        final loading = snapshot.connectionState != ConnectionState.done;
        final assets = snapshot.data ?? const <Asset>[];
        return RefreshIndicator(
          onRefresh: () async => _reload(),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              AppSectionHeader(
                title: 'Archive',
                subtitle:
                    'Hidden media stays in the local library. Nothing is moved, deleted, or uploaded.',
                trailing: OutlinedButton.icon(
                  onPressed: loading ? null : _reload,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                ),
              ),
              const SizedBox(height: 16),
              if (loading)
                const LinearProgressIndicator(minHeight: 2)
              else if (snapshot.hasError)
                AppNotice(
                  icon: Icons.warning_amber_outlined,
                  title: 'Archive unavailable',
                  message: '${snapshot.error}',
                  action: OutlinedButton.icon(
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                )
              else if (assets.isEmpty)
                const EmptyStatePanel(
                  icon: Icons.archive_outlined,
                  title: 'Archive is empty',
                  message:
                      'Archived photos and videos will appear here without being moved or deleted.',
                )
              else ...[
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    AppMetricChip(
                      icon: Icons.archive_outlined,
                      label: 'Archived',
                      value: '${assets.length}',
                    ),
                    AppMetricChip(
                      icon: Icons.cloud_done_outlined,
                      label: 'Available',
                      value:
                          '${assets.where((asset) => asset.isAvailable).length}',
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                AssetGrid(
                  assets: assets,
                  libraryRoot: widget.libraryRoot,
                  onAssetSelected: _openAsset,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
