import 'package:flutter/material.dart';

import '../../api/local_api_client.dart';
import '../../models/gallery_models.dart';
import '../../widgets/app_ui.dart';

enum _FilesViewMode { folders, smart }

class FilesScreen extends StatefulWidget {
  const FilesScreen({
    super.key,
    required this.apiClient,
    required this.onLibraryChanged,
  });

  final LocalApiClient apiClient;
  final Future<void> Function() onLibraryChanged;

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  VaultFileTreeResponse? _tree;
  VaultFileEntry? _currentFolder;
  DuplicateReviewSummary? _duplicateSummary;
  bool _loading = true;
  bool _busy = false;
  bool _includeTrashed = false;
  _FilesViewMode _viewMode = _FilesViewMode.folders;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadTree();
  }

  Future<void> _loadTree({String? preferredFolderId}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final tree = await widget.apiClient.fetchFileTree(
        includeTrashed: _includeTrashed,
      );
      final duplicateSummary = await _safeDuplicateReviewSummary();
      final preferred = preferredFolderId ?? _currentFolder?.id;
      final current = _folderById(tree, preferred) ?? tree.roots.firstOrNull;
      if (!mounted) {
        return;
      }
      setState(() {
        _tree = tree;
        _currentFolder = current;
        _duplicateSummary = duplicateSummary;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  Future<DuplicateReviewSummary?> _safeDuplicateReviewSummary() async {
    try {
      return await widget.apiClient.fetchDuplicateReviewSummary();
    } catch (_) {
      return null;
    }
  }

  Future<void> _runMutation(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await _loadTree();
      await widget.onLibraryChanged();
    } catch (error) {
      _showMessage('$error');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _createFolder() async {
    final current = _currentFolder;
    if (current == null) {
      return;
    }
    final name = await _promptForName(title: 'New folder');
    if (name == null || name.trim().isEmpty) {
      return;
    }
    await _runMutation(() async {
      await widget.apiClient.createFileFolder(
        vaultId: current.vaultId,
        parentId: current.id,
        name: name.trim(),
      );
    });
  }

  Future<void> _rename(VaultFileEntry entry) async {
    final name = await _promptForName(
      title: 'Rename',
      initialValue: entry.name,
    );
    if (name == null || name.trim().isEmpty || name.trim() == entry.name) {
      return;
    }
    await _runMutation(() async {
      await widget.apiClient.renameFileEntry(
        entryId: entry.id,
        name: name.trim(),
      );
    });
  }

  Future<void> _trash(VaultFileEntry entry) async {
    await _runMutation(() async {
      await widget.apiClient.trashFileEntry(entry.id);
    });
  }

  Future<void> _restore(VaultFileEntry entry) async {
    await _runMutation(() async {
      await widget.apiClient.restoreFileEntry(entry.id);
    });
  }

  Future<void> _download(VaultFileEntry entry) async {
    setState(() => _busy = true);
    try {
      final bytes = await widget.apiClient.downloadFileOriginal(
        entryId: entry.id,
      );
      _showMessage(
        'Downloaded ${_formatBytes(bytes.length)} from ${entry.name}.',
      );
    } catch (error) {
      _showMessage('$error');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _showAvailability(VaultFileEntry entry) {
    if (entry.assetId == null) {
      return Future<void>.value();
    }
    return showDialog<void>(
      context: context,
      builder: (context) {
        return _FileAvailabilityDialog(
          apiClient: widget.apiClient,
          entry: entry,
        );
      },
    );
  }

  Future<String?> _promptForName({
    required String title,
    String initialValue = '',
  }) {
    final controller = TextEditingController(text: initialValue);
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
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
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final tree = _tree;
    final current = _currentFolder;
    final children = tree == null || current == null
        ? const <VaultFileEntry>[]
        : _childrenOf(tree, current.id);

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () => _loadTree(),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            AppSectionHeader(
              title: 'Files',
              subtitle: current == null ? null : _pathFor(tree!, current),
              trailing: Wrap(
                spacing: 8,
                children: [
                  FilterChip(
                    selected: _includeTrashed,
                    onSelected: _busy
                        ? null
                        : (value) {
                            setState(() => _includeTrashed = value);
                            _loadTree();
                          },
                    avatar: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Trash'),
                  ),
                  IconButton.filledTonal(
                    onPressed: _busy || current == null ? null : _createFolder,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    tooltip: 'New folder',
                  ),
                  IconButton.filledTonal(
                    onPressed: _busy || _loading ? null : () => _loadTree(),
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Refresh files',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (_loading) const LinearProgressIndicator(),
            if (_error != null) ...[
              AppSurface(
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (_duplicateSummary != null) ...[
              _DuplicateReviewPanel(summary: _duplicateSummary!),
              const SizedBox(height: 16),
            ],
            if (tree != null && current != null) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: SegmentedButton<_FilesViewMode>(
                  segments: const [
                    ButtonSegment<_FilesViewMode>(
                      value: _FilesViewMode.folders,
                      icon: Icon(Icons.account_tree_outlined),
                      label: Text('Folders'),
                    ),
                    ButtonSegment<_FilesViewMode>(
                      value: _FilesViewMode.smart,
                      icon: Icon(Icons.auto_awesome_motion_outlined),
                      label: Text('Smart groups'),
                    ),
                  ],
                  selected: {_viewMode},
                  onSelectionChanged: _busy
                      ? null
                      : (selection) {
                          setState(() => _viewMode = selection.single);
                        },
                ),
              ),
              const SizedBox(height: 12),
              if (_viewMode == _FilesViewMode.folders) ...[
                _Breadcrumbs(
                  tree: tree,
                  current: current,
                  onOpen: (entry) {
                    setState(() => _currentFolder = entry);
                  },
                ),
                const SizedBox(height: 12),
                for (final child in children)
                  _FileEntryRow(
                    entry: child,
                    disabled: _busy,
                    sourceDeviceLabel: _deviceLabelForEntry(tree, child),
                    onOpen: child.isFolder
                        ? () => setState(() => _currentFolder = child)
                        : null,
                    onDownload: child.isFile ? () => _download(child) : null,
                    onAvailability: child.assetId == null
                        ? null
                        : () => _showAvailability(child),
                    onRename: child.parentId == null
                        ? null
                        : () => _rename(child),
                    onTrash: child.parentId == null || child.isTrashed
                        ? null
                        : () => _trash(child),
                    onRestore: child.isTrashed ? () => _restore(child) : null,
                  ),
                if (children.isEmpty)
                  const AppSurface(child: Text('This folder is empty.')),
              ] else
                _SmartFileGroups(
                  tree: tree,
                  disabled: _busy,
                  onDownload: _download,
                  onAvailability: _showAvailability,
                  onRename: _rename,
                  onTrash: _trash,
                  onRestore: _restore,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SmartFileGroups extends StatelessWidget {
  const _SmartFileGroups({
    required this.tree,
    required this.disabled,
    required this.onDownload,
    required this.onAvailability,
    required this.onRename,
    required this.onTrash,
    required this.onRestore,
  });

  final VaultFileTreeResponse tree;
  final bool disabled;
  final ValueChanged<VaultFileEntry> onDownload;
  final ValueChanged<VaultFileEntry> onAvailability;
  final ValueChanged<VaultFileEntry> onRename;
  final ValueChanged<VaultFileEntry> onTrash;
  final ValueChanged<VaultFileEntry> onRestore;

  @override
  Widget build(BuildContext context) {
    final groups = _smartFileGroups(tree);
    if (groups.isEmpty) {
      return const AppSurface(child: Text('No smart file groups yet.'));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final group in groups)
          _SmartFileGroupSection(
            group: group,
            tree: tree,
            disabled: disabled,
            onDownload: onDownload,
            onAvailability: onAvailability,
            onRename: onRename,
            onTrash: onTrash,
            onRestore: onRestore,
          ),
      ],
    );
  }
}

class _DuplicateReviewPanel extends StatelessWidget {
  const _DuplicateReviewPanel({required this.summary});

  final DuplicateReviewSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = summary.entries.take(3).toList();
    final importLabel = summary.sessionsWithDuplicates == 1
        ? 'import'
        : 'imports';
    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.content_copy_outlined,
                color: summary.hasDuplicates
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Duplicate review',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      summary.hasDuplicates
                          ? '${summary.duplicateCandidates} skipped duplicates across ${summary.sessionsWithDuplicates} $importLabel'
                          : 'No committed duplicate imports yet',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              AppStatusBadge(
                label: summary.hasDuplicates ? 'Protected' : 'Clear',
                tone: summary.hasDuplicates
                    ? AppStatusTone.success
                    : AppStatusTone.neutral,
                icon: summary.hasDuplicates
                    ? Icons.verified_outlined
                    : Icons.check_circle_outline,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 10,
            children: [
              _DuplicateReviewMetric(
                label: 'Protected',
                value: _formatBytes(summary.protectedBytes),
              ),
              _DuplicateReviewMetric(
                label: 'Assets',
                value: '${summary.duplicateAssets}',
              ),
              _DuplicateReviewMetric(
                label: 'Candidates',
                value: '${summary.duplicateCandidates}',
              ),
            ],
          ),
          if (entries.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 8),
            for (final entry in entries) _DuplicateReviewRow(entry: entry),
          ],
        ],
      ),
    );
  }
}

class _DuplicateReviewMetric extends StatelessWidget {
  const _DuplicateReviewMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 132,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: theme.textTheme.labelSmall),
          const SizedBox(height: 2),
          Text(value, style: theme.textTheme.titleSmall),
        ],
      ),
    );
  }
}

class _DuplicateReviewRow extends StatelessWidget {
  const _DuplicateReviewRow({required this.entry});

  final DuplicateReviewEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sourceKinds = entry.sourceKinds.isEmpty
        ? 'imports'
        : entry.sourceKinds.join(', ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(_iconForMediaKind(entry.mediaKind), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${entry.duplicateCandidates} ${entry.mediaKind} duplicates from $sourceKinds',
              style: theme.textTheme.bodyMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _formatBytes(entry.protectedBytes),
            style: theme.textTheme.labelLarge,
          ),
        ],
      ),
    );
  }
}

class _SmartFileGroupSection extends StatelessWidget {
  const _SmartFileGroupSection({
    required this.group,
    required this.tree,
    required this.disabled,
    required this.onDownload,
    required this.onAvailability,
    required this.onRename,
    required this.onTrash,
    required this.onRestore,
  });

  final _SmartFileGroup group;
  final VaultFileTreeResponse tree;
  final bool disabled;
  final ValueChanged<VaultFileEntry> onDownload;
  final ValueChanged<VaultFileEntry> onAvailability;
  final ValueChanged<VaultFileEntry> onRename;
  final ValueChanged<VaultFileEntry> onTrash;
  final ValueChanged<VaultFileEntry> onRestore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(group.icon, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${group.category}: ${group.label}',
                  style: theme.textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              AppStatusBadge(
                label: '${group.entries.length}',
                tone: AppStatusTone.neutral,
                icon: Icons.insert_drive_file_outlined,
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final entry in group.entries)
            _FileEntryRow(
              entry: entry,
              disabled: disabled,
              sourceDeviceLabel: _deviceLabelForEntry(tree, entry),
              onDownload: () => onDownload(entry),
              onAvailability: entry.assetId == null
                  ? null
                  : () => onAvailability(entry),
              onRename: () => onRename(entry),
              onTrash: entry.isTrashed ? null : () => onTrash(entry),
              onRestore: entry.isTrashed ? () => onRestore(entry) : null,
            ),
        ],
      ),
    );
  }
}

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({
    required this.tree,
    required this.current,
    required this.onOpen,
  });

  final VaultFileTreeResponse tree;
  final VaultFileEntry current;
  final ValueChanged<VaultFileEntry> onOpen;

  @override
  Widget build(BuildContext context) {
    final path = _pathEntries(tree, current);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      runSpacing: 4,
      children: [
        for (var index = 0; index < path.length; index++) ...[
          ActionChip(
            avatar: Icon(
              index == 0 ? Icons.cloud_queue : Icons.folder_outlined,
              size: 18,
            ),
            label: Text(path[index].name),
            onPressed: index == path.length - 1
                ? null
                : () {
                    onOpen(path[index]);
                  },
          ),
          if (index < path.length - 1)
            const Icon(Icons.chevron_right, size: 18),
        ],
      ],
    );
  }
}

class _FileEntryRow extends StatelessWidget {
  const _FileEntryRow({
    required this.entry,
    required this.disabled,
    this.sourceDeviceLabel,
    this.onOpen,
    this.onDownload,
    this.onAvailability,
    this.onRename,
    this.onTrash,
    this.onRestore,
  });

  final VaultFileEntry entry;
  final bool disabled;
  final String? sourceDeviceLabel;
  final VoidCallback? onOpen;
  final VoidCallback? onDownload;
  final VoidCallback? onAvailability;
  final VoidCallback? onRename;
  final VoidCallback? onTrash;
  final VoidCallback? onRestore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tone = entry.isTrashed
        ? AppStatusTone.warning
        : AppStatusTone.neutral;
    final subtitle = _fileSubtitle(entry, sourceDeviceLabel);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppSurface(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(
              _iconFor(entry),
              color: entry.isFolder
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: InkWell(
                onTap: disabled ? null : onOpen,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
            if (entry.isTrashed)
              AppStatusBadge(
                label: 'Trash',
                tone: tone,
                icon: Icons.delete_outline,
              ),
            const SizedBox(width: 8),
            if (onDownload != null)
              IconButton(
                onPressed: disabled ? null : onDownload,
                icon: const Icon(Icons.download_outlined),
                tooltip: 'Download original',
              ),
            if (onAvailability != null)
              IconButton(
                onPressed: disabled ? null : onAvailability,
                icon: const Icon(Icons.cloud_done_outlined),
                tooltip: 'File availability',
              ),
            IconButton(
              onPressed: disabled ? null : onRename,
              icon: const Icon(Icons.drive_file_rename_outline),
              tooltip: 'Rename',
            ),
            if (entry.isTrashed)
              IconButton(
                onPressed: disabled ? null : onRestore,
                icon: const Icon(Icons.restore_from_trash_outlined),
                tooltip: 'Restore',
              )
            else
              IconButton(
                onPressed: disabled ? null : onTrash,
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Move to trash',
              ),
          ],
        ),
      ),
    );
  }
}

class _FileAvailabilityDialog extends StatefulWidget {
  const _FileAvailabilityDialog({required this.apiClient, required this.entry});

  final LocalApiClient apiClient;
  final VaultFileEntry entry;

  @override
  State<_FileAvailabilityDialog> createState() =>
      _FileAvailabilityDialogState();
}

class _FileAvailabilityDialogState extends State<_FileAvailabilityDialog> {
  late Future<AssetAvailability> _future;
  var _busy = false;
  String? _actionError;

  String get _assetId => widget.entry.assetId!;

  @override
  void initState() {
    super.initState();
    _future = widget.apiClient.fetchAssetAvailability(_assetId);
  }

  void _refresh() {
    setState(() {
      _future = widget.apiClient.fetchAssetAvailability(_assetId);
      _actionError = null;
    });
  }

  Future<void> _run(
    Future<AssetAvailability> Function(String assetId) action,
  ) async {
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      final availability = await action(_assetId);
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
    return AlertDialog(
      title: const Text('File availability'),
      content: SizedBox(
        width: 520,
        child: FutureBuilder<AssetAvailability>(
          future: _future,
          builder: (context, snapshot) {
            final availability = snapshot.data;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.entry.name,
                  style: theme.textTheme.titleSmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 12),
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
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
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
                  const SizedBox(height: 12),
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
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton.icon(
                        onPressed: _busy || availability.localReplica
                            ? null
                            : () => _run(widget.apiClient.pinLocalAsset),
                        icon: _busy
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.download_for_offline_outlined),
                        label: Text(
                          availability.localReplica
                              ? 'Pinned here'
                              : 'Pin local',
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy || !availability.localReplica
                            ? null
                            : () => _run(widget.apiClient.evictLocalAsset),
                        icon: const Icon(Icons.cloud_upload_outlined),
                        label: const Text('Evict local'),
                      ),
                      IconButton.outlined(
                        onPressed: _busy ? null : _refresh,
                        icon: const Icon(Icons.refresh),
                        tooltip: 'Refresh availability',
                      ),
                    ],
                  ),
                ],
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _SmartFileGroup {
  const _SmartFileGroup({
    required this.order,
    required this.category,
    required this.label,
    required this.icon,
    required this.entries,
  });

  final int order;
  final String category;
  final String label;
  final IconData icon;
  final List<VaultFileEntry> entries;
}

class _MutableSmartFileGroup {
  _MutableSmartFileGroup({
    required this.order,
    required this.category,
    required this.label,
    required this.icon,
  });

  final int order;
  final String category;
  final String label;
  final IconData icon;
  final List<VaultFileEntry> entries = [];

  _SmartFileGroup freeze() {
    entries.sort(_compareFileEntries);
    return _SmartFileGroup(
      order: order,
      category: category,
      label: label,
      icon: icon,
      entries: List.unmodifiable(entries),
    );
  }
}

class _SmartGroupSpec {
  const _SmartGroupSpec({
    required this.order,
    required this.category,
    required this.icon,
    required this.valueFor,
  });

  final int order;
  final String category;
  final IconData icon;
  final String? Function(VaultFileEntry entry) valueFor;
}

VaultFileEntry? _folderById(VaultFileTreeResponse tree, String? id) {
  if (id == null) {
    return null;
  }
  for (final entry in tree.entries) {
    if (entry.id == id && entry.isFolder) {
      return entry;
    }
  }
  return null;
}

List<VaultFileEntry> _childrenOf(VaultFileTreeResponse tree, String parentId) {
  final children = tree.childrenOf(parentId);
  children.sort((left, right) {
    final kind = (left.isFile ? 1 : 0).compareTo(right.isFile ? 1 : 0);
    if (kind != 0) {
      return kind;
    }
    return left.name.toLowerCase().compareTo(right.name.toLowerCase());
  });
  return children;
}

List<_SmartFileGroup> _smartFileGroups(VaultFileTreeResponse tree) {
  final devicesById = tree.devicesById;
  final specs = <_SmartGroupSpec>[
    _SmartGroupSpec(
      order: 0,
      category: 'Device',
      icon: Icons.devices_outlined,
      valueFor: (entry) {
        final originDeviceId = entry.originDeviceId;
        if (originDeviceId == null) {
          return null;
        }
        return devicesById[originDeviceId]?.label ?? 'Unknown device';
      },
    ),
    _SmartGroupSpec(
      order: 1,
      category: 'Workspace',
      icon: Icons.workspaces_outline,
      valueFor: (entry) => entry.organization.workspace,
    ),
    _SmartGroupSpec(
      order: 2,
      category: 'Client',
      icon: Icons.business_center_outlined,
      valueFor: (entry) => entry.organization.client,
    ),
    _SmartGroupSpec(
      order: 3,
      category: 'Project',
      icon: Icons.folder_special_outlined,
      valueFor: (entry) => entry.organization.project,
    ),
    _SmartGroupSpec(
      order: 4,
      category: 'Topic',
      icon: Icons.sell_outlined,
      valueFor: (entry) => entry.organization.topic,
    ),
    _SmartGroupSpec(
      order: 5,
      category: 'Source folder',
      icon: Icons.source_outlined,
      valueFor: (entry) => entry.organization.sourceFolder,
    ),
    const _SmartGroupSpec(
      order: 6,
      category: 'Type',
      icon: Icons.category_outlined,
      valueFor: _fileTypeGroup,
    ),
  ];
  final groups = <String, _MutableSmartFileGroup>{};
  for (final entry in tree.entries.where((entry) => entry.isFile)) {
    for (final spec in specs) {
      final label = _cleanGroupValue(spec.valueFor(entry));
      if (label == null) {
        continue;
      }
      final key = '${spec.category}\u0000${label.toLowerCase()}';
      final group = groups.putIfAbsent(
        key,
        () => _MutableSmartFileGroup(
          order: spec.order,
          category: spec.category,
          label: label,
          icon: spec.icon,
        ),
      );
      group.entries.add(entry);
    }
  }
  final frozen = groups.values.map((group) => group.freeze()).toList();
  frozen.sort((left, right) {
    final order = left.order.compareTo(right.order);
    if (order != 0) {
      return order;
    }
    final count = right.entries.length.compareTo(left.entries.length);
    if (count != 0) {
      return count;
    }
    return left.label.toLowerCase().compareTo(right.label.toLowerCase());
  });
  return frozen;
}

String? _cleanGroupValue(String? value) {
  final cleaned = value?.trim();
  return cleaned == null || cleaned.isEmpty ? null : cleaned;
}

String _fileTypeGroup(VaultFileEntry entry) {
  return switch (entry.mediaKind) {
    'photo' => 'Photos',
    'video' => 'Videos',
    'document' => _documentTypeLabel(entry),
    'audio' => 'Audio',
    'archive' => 'Archives',
    'text' => 'Text files',
    _ => 'Other files',
  };
}

String _documentTypeLabel(VaultFileEntry entry) {
  return switch (entry.mimeType) {
    'application/pdf' => 'PDFs',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document' =>
      'Documents',
    'application/msword' => 'Documents',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' =>
      'Spreadsheets',
    'application/vnd.ms-excel' => 'Spreadsheets',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation' =>
      'Presentations',
    'application/vnd.ms-powerpoint' => 'Presentations',
    _ => 'Documents',
  };
}

int _compareFileEntries(VaultFileEntry left, VaultFileEntry right) {
  final kind = (left.isFile ? 1 : 0).compareTo(right.isFile ? 1 : 0);
  if (kind != 0) {
    return kind;
  }
  return left.name.toLowerCase().compareTo(right.name.toLowerCase());
}

List<VaultFileEntry> _pathEntries(
  VaultFileTreeResponse tree,
  VaultFileEntry current,
) {
  final byId = {for (final entry in tree.entries) entry.id: entry};
  final path = <VaultFileEntry>[];
  var cursor = current;
  while (true) {
    path.insert(0, cursor);
    final parentId = cursor.parentId;
    if (parentId == null || !byId.containsKey(parentId)) {
      break;
    }
    cursor = byId[parentId]!;
  }
  return path;
}

String _pathFor(VaultFileTreeResponse tree, VaultFileEntry current) {
  return _pathEntries(tree, current).map((entry) => entry.name).join(' / ');
}

String? _deviceLabelForEntry(VaultFileTreeResponse tree, VaultFileEntry entry) {
  final originDeviceId = entry.originDeviceId;
  if (originDeviceId == null) {
    return null;
  }
  return tree.devicesById[originDeviceId]?.label ?? 'Unknown device';
}

String _fileSubtitle(VaultFileEntry entry, String? sourceDeviceLabel) {
  if (entry.isFolder) {
    return 'Folder';
  }
  final base = '${entry.mediaKind ?? 'file'} | ${_formatBytes(entry.bytes)}';
  final parts = <String>[base];
  if (sourceDeviceLabel != null && sourceDeviceLabel.trim().isNotEmpty) {
    parts.add('Device: $sourceDeviceLabel');
  }
  final organization = entry.organization.summary;
  if (organization.isNotEmpty) {
    parts.add(organization);
  }
  return parts.join(' | ');
}

IconData _iconFor(VaultFileEntry entry) {
  if (entry.isFolder) {
    return Icons.folder_outlined;
  }
  return _iconForMediaKind(entry.mediaKind);
}

IconData _iconForMediaKind(String? mediaKind) {
  return switch (mediaKind) {
    'photo' => Icons.image_outlined,
    'video' => Icons.movie_outlined,
    'document' => Icons.description_outlined,
    'audio' => Icons.audio_file_outlined,
    'archive' => Icons.folder_zip_outlined,
    'text' => Icons.notes_outlined,
    _ => Icons.insert_drive_file_outlined,
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

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '$bytes B';
}
