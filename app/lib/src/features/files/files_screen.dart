import 'package:flutter/material.dart';

import '../../api/local_api_client.dart';
import '../../models/gallery_models.dart';
import '../../widgets/app_ui.dart';

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
  bool _loading = true;
  bool _busy = false;
  bool _includeTrashed = false;
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
      final preferred = preferredFolderId ?? _currentFolder?.id;
      final current = _folderById(tree, preferred) ?? tree.roots.firstOrNull;
      if (!mounted) {
        return;
      }
      setState(() {
        _tree = tree;
        _currentFolder = current;
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
            if (tree != null && current != null) ...[
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
                  onOpen: child.isFolder
                      ? () => setState(() => _currentFolder = child)
                      : null,
                  onDownload: child.isFile ? () => _download(child) : null,
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
            ],
          ],
        ),
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
    this.onOpen,
    this.onDownload,
    this.onRename,
    this.onTrash,
    this.onRestore,
  });

  final VaultFileEntry entry;
  final bool disabled;
  final VoidCallback? onOpen;
  final VoidCallback? onDownload;
  final VoidCallback? onRename;
  final VoidCallback? onTrash;
  final VoidCallback? onRestore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tone = entry.isTrashed
        ? AppStatusTone.warning
        : AppStatusTone.neutral;
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
                      entry.isFolder
                          ? 'Folder'
                          : '${entry.mediaKind ?? 'file'} | ${_formatBytes(entry.bytes)}',
                      style: theme.textTheme.bodySmall,
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

IconData _iconFor(VaultFileEntry entry) {
  if (entry.isFolder) {
    return Icons.folder_outlined;
  }
  return switch (entry.mediaKind) {
    'photo' => Icons.image_outlined,
    'video' => Icons.movie_outlined,
    'document' => Icons.description_outlined,
    'audio' => Icons.audio_file_outlined,
    'archive' => Icons.folder_zip_outlined,
    'text' => Icons.notes_outlined,
    _ => Icons.insert_drive_file_outlined,
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
