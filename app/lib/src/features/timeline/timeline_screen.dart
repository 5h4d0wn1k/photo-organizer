import 'package:flutter/material.dart';

import '../media/media_viewer.dart';
import '../../models/gallery_models.dart';
import '../../repositories/gallery_repository.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/asset_grid.dart';
import '../../widgets/empty_state_panel.dart';

class TimelineScreen extends StatefulWidget {
  const TimelineScreen({
    super.key,
    required this.workspace,
    required this.repository,
    required this.onImportNow,
    required this.onLibraryChanged,
  });

  final WorkspaceSnapshot workspace;
  final GalleryRepository repository;
  final VoidCallback onImportNow;
  final Future<void> Function() onLibraryChanged;

  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends State<TimelineScreen> {
  late TimelineResponse _timeline;
  var _loadingMore = false;
  var _reloadingTimeline = false;
  var _showArchived = false;
  var _selectionMode = false;
  final Set<String> _selectedAssetIds = <String>{};
  String? _loadMoreError;

  @override
  void initState() {
    super.initState();
    _timeline = widget.workspace.dashboard.timeline;
  }

  @override
  void didUpdateWidget(covariant TimelineScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_showArchived &&
        !identical(
          oldWidget.workspace.dashboard.timeline,
          widget.workspace.dashboard.timeline,
        )) {
      _timeline = widget.workspace.dashboard.timeline;
      _loadMoreError = null;
      _selectedAssetIds.removeWhere((id) => !_visibleAssetIds.contains(id));
    }
  }

  Set<String> get _visibleAssetIds =>
      _visibleAssets.map((asset) => asset.id).toSet();

  List<Asset> get _visibleAssets => _timeline.buckets
      .expand((bucket) => bucket.assets)
      .toList(growable: false);

  Future<void> _reloadTimeline({required bool includeArchived}) async {
    setState(() {
      _reloadingTimeline = true;
      _loadMoreError = null;
      _showArchived = includeArchived;
    });

    try {
      final timeline = await widget.repository.fetchTimelinePage(
        limit: 1500,
        includeArchived: includeArchived,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _timeline = timeline;
        _selectedAssetIds.removeWhere((id) => !_visibleAssetIds.contains(id));
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadMoreError = 'Unable to refresh timeline assets: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _reloadingTimeline = false;
        });
      }
    }
  }

  void _toggleAssetSelection(Asset asset) {
    setState(() {
      if (_selectedAssetIds.contains(asset.id)) {
        _selectedAssetIds.remove(asset.id);
      } else {
        _selectedAssetIds.add(asset.id);
      }
      if (_selectedAssetIds.isEmpty) {
        _selectionMode = true;
      }
    });
  }

  void _selectVisibleAssets() {
    setState(() {
      _selectionMode = true;
      _selectedAssetIds
        ..clear()
        ..addAll(_visibleAssetIds);
    });
  }

  void _clearSelection() {
    setState(() {
      _selectedAssetIds.clear();
      _selectionMode = false;
    });
  }

  Future<void> _bulkUpdateAssetFlags({bool? favorite, bool? archived}) async {
    final ids = _selectedAssetIds.toList(growable: false);
    if (ids.isEmpty) {
      return;
    }

    try {
      final updated = await widget.repository.updateAssetsFlags(
        ids,
        favorite: favorite,
        archived: archived,
      );
      await widget.onLibraryChanged();
      await _reloadTimeline(includeArchived: _showArchived);
      if (!mounted) {
        return;
      }
      _clearSelection();
      final action = archived != null
          ? archived
                ? 'archived'
                : 'unarchived'
          : favorite == true
          ? 'marked as favorite'
          : 'removed from favorites';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${updated.length} assets $action.')),
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

  Future<void> _bulkAddSelectedToAlbum() async {
    final ids = _selectedAssetIds.toList(growable: false);
    if (ids.isEmpty) {
      return;
    }
    final albums = widget.workspace.dashboard.albums;
    String? selectedAlbumId = albums.isEmpty ? null : albums.first.id;
    final newAlbumController = TextEditingController();

    final assignment = await showDialog<_AlbumAssignment>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text('Add ${ids.length} assets to album'),
              content: SizedBox(
                width: 520,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (albums.isNotEmpty) ...[
                      DropdownButtonFormField<String>(
                        initialValue: selectedAlbumId,
                        decoration: const InputDecoration(
                          labelText: 'Existing album',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          for (final album in albums)
                            DropdownMenuItem(
                              value: album.id,
                              child: Text(album.title),
                            ),
                        ],
                        onChanged: (value) {
                          setDialogState(() => selectedAlbumId = value);
                        },
                      ),
                      const SizedBox(height: 16),
                    ],
                    TextField(
                      controller: newAlbumController,
                      decoration: const InputDecoration(
                        labelText: 'Or create a new album',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'This changes album metadata only. Media files are not moved, deleted, uploaded, or modified.',
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                if (albums.isNotEmpty)
                  OutlinedButton(
                    onPressed: selectedAlbumId == null
                        ? null
                        : () => Navigator.of(
                            context,
                          ).pop(_AlbumAssignment.existing(selectedAlbumId!)),
                    child: const Text('Add existing'),
                  ),
                FilledButton(
                  onPressed: () => Navigator.of(
                    context,
                  ).pop(_AlbumAssignment.create(newAlbumController.text)),
                  child: const Text('Create and add'),
                ),
              ],
            );
          },
        );
      },
    );

    if (assignment == null || !mounted) {
      return;
    }

    try {
      if (assignment.createTitle != null) {
        final title = assignment.createTitle!.trim();
        if (title.isEmpty) {
          return;
        }
        await widget.repository.createAlbum(title: title, assetIds: ids);
      } else if (assignment.albumId != null) {
        await widget.repository.addAlbumAssets(
          assignment.albumId!,
          assetIds: ids,
        );
      }
      await widget.onLibraryChanged();
      if (!mounted) {
        return;
      }
      _clearSelection();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${ids.length} assets added to album locally.')),
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

  Future<void> _loadMore() async {
    final cursor = _timeline.nextCursor;
    if (cursor == null || _loadingMore) {
      return;
    }

    setState(() {
      _loadingMore = true;
      _loadMoreError = null;
    });

    try {
      final nextPage = await widget.repository.fetchTimelinePage(
        cursor: cursor,
        limit: 1500,
        includeArchived: _showArchived,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _timeline = _timeline.append(nextPage);
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadMoreError = 'Unable to load more timeline assets: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingMore = false;
        });
      }
    }
  }

  Future<void> _showAssetDetails(Asset asset) {
    return MediaViewer.show(
      context,
      asset: asset,
      libraryRoot: widget.workspace.settings.libraryRoot,
      onToggleFavorite: () {
        Navigator.of(context).maybePop();
        _updateAssetFlags(asset, favorite: !asset.favorite);
      },
      onToggleArchived: () {
        Navigator.of(context).maybePop();
        _updateAssetFlags(asset, archived: !asset.archived);
      },
      onAssignPerson: () {
        Navigator.of(context).maybePop();
        _assignAssetToPerson(asset);
      },
      onAddToAlbum: () {
        Navigator.of(context).maybePop();
        _addAssetToAlbum(asset);
      },
      onEditTags: () {
        Navigator.of(context).maybePop();
        _editAssetTags(asset);
      },
      loadAvailability: widget.repository.fetchAssetAvailability,
      pinLocalAsset: widget.repository.pinLocalAsset,
      evictLocalAsset: widget.repository.evictLocalAsset,
    );
  }

  Future<void> _editAssetTags(Asset asset) async {
    final controller = TextEditingController(text: asset.manualTags.join(', '));
    final value = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Edit tags for ${asset.originalFilename}'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Tags',
              hintText: 'work, invoice, family',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Save'),
            ),
          ],
        );
      },
    ).whenComplete(controller.dispose);
    if (value == null) {
      return;
    }
    final tags = value
        .split(',')
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toList();
    try {
      final updated = await widget.repository.updateAssetTags(
        asset.id,
        tags: tags,
      );
      await widget.onLibraryChanged();
      await _reloadTimeline(includeArchived: _showArchived);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${updated.originalFilename} tags updated.')),
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

  Future<void> _updateAssetFlags(
    Asset asset, {
    bool? favorite,
    bool? archived,
  }) async {
    try {
      final updated = await widget.repository.updateAssetFlags(
        asset.id,
        favorite: favorite,
        archived: archived,
      );
      await widget.onLibraryChanged();
      await _reloadTimeline(includeArchived: _showArchived);
      if (!mounted) {
        return;
      }
      final action = archived != null
          ? updated.archived
                ? 'archived'
                : 'unarchived'
          : updated.favorite
          ? 'marked as favorite'
          : 'removed from favorites';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${updated.originalFilename} $action.')),
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

  Future<void> _addAssetToAlbum(Asset asset) async {
    final albums = widget.workspace.dashboard.albums;
    String? selectedAlbumId = albums.isEmpty ? null : albums.first.id;
    final newAlbumController = TextEditingController();

    final assignment = await showDialog<_AlbumAssignment>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text('Add ${asset.originalFilename} to album'),
              content: SizedBox(
                width: 520,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (albums.isNotEmpty) ...[
                      DropdownButtonFormField<String>(
                        initialValue: selectedAlbumId,
                        decoration: const InputDecoration(
                          labelText: 'Existing album',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          for (final album in albums)
                            DropdownMenuItem(
                              value: album.id,
                              child: Text(album.title),
                            ),
                        ],
                        onChanged: (value) {
                          setDialogState(() => selectedAlbumId = value);
                        },
                      ),
                      const SizedBox(height: 16),
                    ],
                    TextField(
                      controller: newAlbumController,
                      decoration: const InputDecoration(
                        labelText: 'Or create a new album',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Albums are local metadata only. The media file is not moved, deleted, uploaded, or modified.',
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                if (albums.isNotEmpty)
                  OutlinedButton(
                    onPressed: selectedAlbumId == null
                        ? null
                        : () => Navigator.of(
                            context,
                          ).pop(_AlbumAssignment.existing(selectedAlbumId!)),
                    child: const Text('Add existing'),
                  ),
                FilledButton(
                  onPressed: () => Navigator.of(
                    context,
                  ).pop(_AlbumAssignment.create(newAlbumController.text)),
                  child: const Text('Create and add'),
                ),
              ],
            );
          },
        );
      },
    );

    if (assignment == null || !mounted) {
      return;
    }

    try {
      if (assignment.createTitle != null) {
        final title = assignment.createTitle!.trim();
        if (title.isEmpty) {
          return;
        }
        await widget.repository.createAlbum(title: title, assetIds: [asset.id]);
      } else if (assignment.albumId != null) {
        await widget.repository.addAlbumAssets(
          assignment.albumId!,
          assetIds: [asset.id],
        );
      }
      await widget.onLibraryChanged();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Asset added to album locally.')),
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

  Future<void> _assignAssetToPerson(Asset asset) async {
    final people = widget.workspace.dashboard.people;
    String? selectedPersonId = people.isEmpty ? null : people.first.id;
    final newPersonController = TextEditingController();

    final assignment = await showDialog<_PersonAssignment>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text('Assign ${asset.originalFilename}'),
              content: SizedBox(
                width: 520,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (people.isNotEmpty) ...[
                      DropdownButtonFormField<String>(
                        initialValue: selectedPersonId,
                        decoration: const InputDecoration(
                          labelText: 'Existing person',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          for (final person in people)
                            DropdownMenuItem(
                              value: person.id,
                              child: Text(person.displayName),
                            ),
                        ],
                        onChanged: (value) {
                          setDialogState(() => selectedPersonId = value);
                        },
                      ),
                      const SizedBox(height: 16),
                    ],
                    TextField(
                      controller: newPersonController,
                      decoration: const InputDecoration(
                        labelText: 'Or create a new person',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'This is manual local organization. No face model runs and no photo leaves this machine.',
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                if (people.isNotEmpty)
                  OutlinedButton(
                    onPressed: selectedPersonId == null
                        ? null
                        : () => Navigator.of(
                            context,
                          ).pop(_PersonAssignment.existing(selectedPersonId!)),
                    child: const Text('Assign existing'),
                  ),
                FilledButton(
                  onPressed: () => Navigator.of(
                    context,
                  ).pop(_PersonAssignment.create(newPersonController.text)),
                  child: const Text('Create and assign'),
                ),
              ],
            );
          },
        );
      },
    );

    if (assignment == null || !mounted) {
      return;
    }

    try {
      if (assignment.createName != null) {
        final name = assignment.createName!.trim();
        if (name.isEmpty) {
          return;
        }
        await widget.repository.createManualPerson(
          displayName: name,
          assetIds: [asset.id],
        );
      } else if (assignment.personId != null) {
        await widget.repository.addPersonAssets(
          assignment.personId!,
          assetIds: [asset.id],
        );
      }
      await widget.onLibraryChanged();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Person assignment saved locally.')),
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

  @override
  Widget build(BuildContext context) {
    final allAssetCount =
        widget.workspace.diagnostics?.assets ?? _timeline.totalAssets;
    final totalAssetCount = _timeline.totalAssets;
    final visibleAssetCount = _timeline.visibleAssetCount;
    final onlyArchivedHidden =
        allAssetCount > 0 && totalAssetCount == 0 && !_showArchived;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        AppSectionHeader(
          title: 'Gallery',
          subtitle:
              'Your local-first photo and video library, organized without sending originals to cloud storage.',
          trailing: FilledButton.icon(
            onPressed: widget.onImportNow,
            icon: const Icon(Icons.file_upload_outlined),
            label: const Text('Import'),
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            AppMetricChip(
              icon: Icons.photo_library_outlined,
              label: 'Media',
              value: '$allAssetCount',
            ),
            AppMetricChip(
              icon: Icons.folder_copy_outlined,
              label: 'Watch folders',
              value: '${widget.workspace.watchFolders.length}',
            ),
            AppMetricChip(
              icon: Icons.compare_arrows_outlined,
              label: 'Import mode',
              value:
                  widget.workspace.settings.defaultImportMode == ImportMode.copy
                  ? 'Copy'
                  : widget.workspace.settings.defaultImportMode ==
                        ImportMode.move
                  ? 'Move'
                  : 'Reference',
            ),
          ],
        ),
        const SizedBox(height: 24),
        AppSurface(
          padding: EdgeInsets.zero,
          child: SwitchListTile(
            value: _showArchived,
            onChanged: _reloadingTimeline
                ? null
                : (value) => _reloadTimeline(includeArchived: value),
            secondary: _reloadingTimeline
                ? const SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.inventory_2_outlined),
            title: const Text('Show archived media'),
            subtitle: Text(
              _showArchived
                  ? 'Archived assets are included for review. No files are moved or deleted.'
                  : 'Archived assets stay in the library but are hidden from the main timeline.',
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (_timeline.buckets.isNotEmpty) ...[
          AppSurface(
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  _selectedAssetIds.isEmpty
                      ? 'Organize loaded media'
                      : '${_selectedAssetIds.length} selected',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                OutlinedButton.icon(
                  onPressed: () {
                    setState(() {
                      _selectionMode = !_selectionMode;
                      if (!_selectionMode) {
                        _selectedAssetIds.clear();
                      }
                    });
                  },
                  icon: Icon(
                    _selectionMode
                        ? Icons.check_box_outlined
                        : Icons.check_box_outline_blank,
                  ),
                  label: Text(_selectionMode ? 'Selection on' : 'Select'),
                ),
                OutlinedButton.icon(
                  onPressed: _visibleAssets.isEmpty
                      ? null
                      : _selectVisibleAssets,
                  icon: const Icon(Icons.select_all),
                  label: const Text('Select visible'),
                ),
                OutlinedButton.icon(
                  onPressed: _selectedAssetIds.isEmpty ? null : _clearSelection,
                  icon: const Icon(Icons.clear),
                  label: const Text('Clear'),
                ),
                FilledButton.icon(
                  onPressed: _selectedAssetIds.isEmpty
                      ? null
                      : () => _bulkUpdateAssetFlags(favorite: true),
                  icon: const Icon(Icons.star_rounded),
                  label: const Text('Favorite'),
                ),
                FilledButton.icon(
                  onPressed: _selectedAssetIds.isEmpty
                      ? null
                      : () => _bulkUpdateAssetFlags(archived: true),
                  icon: const Icon(Icons.archive_outlined),
                  label: const Text('Archive'),
                ),
                FilledButton.icon(
                  onPressed: _selectedAssetIds.isEmpty
                      ? null
                      : _bulkAddSelectedToAlbum,
                  icon: const Icon(Icons.photo_album_outlined),
                  label: const Text('Add to album'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (visibleAssetCount < totalAssetCount) ...[
          AppSurface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Showing $visibleAssetCount of $totalAssetCount assets.',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  'Gallery pages are loaded locally in batches so large libraries open quickly.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (_loadMoreError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _loadMoreError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _timeline.nextCursor == null || _loadingMore
                      ? null
                      : _loadMore,
                  icon: _loadingMore
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.expand_more),
                  label: Text(_loadingMore ? 'Loading...' : 'Load more'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (_timeline.buckets.isEmpty)
          EmptyStatePanel(
            icon: onlyArchivedHidden
                ? Icons.archive_outlined
                : Icons.photo_library_outlined,
            title: onlyArchivedHidden
                ? 'No visible media in the timeline'
                : 'No imported media yet',
            message: onlyArchivedHidden
                ? 'All indexed assets are currently archived. They are still in the local library and can be reviewed by showing archived media.'
                : 'Scan a folder or removable drive to populate the timeline. The desktop client now avoids demo media and only shows what the local API really knows about.',
            actionLabel: onlyArchivedHidden ? 'Show archived' : 'Import media',
            onAction: onlyArchivedHidden
                ? () => _reloadTimeline(includeArchived: true)
                : widget.onImportNow,
          )
        else
          for (final bucket in _timeline.buckets) ...[
            Text(bucket.label, style: Theme.of(context).textTheme.titleLarge),
            if (bucket.assets.length < bucket.totalAssets)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${bucket.assets.length} of ${bucket.totalAssets} assets shown in this month',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 12),
            AssetGrid(
              assets: bucket.assets,
              libraryRoot: widget.workspace.settings.libraryRoot,
              selectionEnabled: _selectionMode,
              selectedAssetIds: _selectedAssetIds,
              onAssetSelectionToggled: _toggleAssetSelection,
              onAssetSelected: (asset) {
                _showAssetDetails(asset);
              },
            ),
            const SizedBox(height: 24),
          ],
      ],
    );
  }
}

class _PersonAssignment {
  const _PersonAssignment._({this.personId, this.createName});

  factory _PersonAssignment.existing(String personId) {
    return _PersonAssignment._(personId: personId);
  }

  factory _PersonAssignment.create(String displayName) {
    return _PersonAssignment._(createName: displayName);
  }

  final String? personId;
  final String? createName;
}

class _AlbumAssignment {
  const _AlbumAssignment._({this.albumId, this.createTitle});

  factory _AlbumAssignment.existing(String albumId) {
    return _AlbumAssignment._(albumId: albumId);
  }

  factory _AlbumAssignment.create(String title) {
    return _AlbumAssignment._(createTitle: title);
  }

  final String? albumId;
  final String? createTitle;
}
