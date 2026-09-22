import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/gallery_models.dart';
import 'mobile_gallery_panel.dart';

enum _WorkspaceTab { gallery, files, search, organize, devices, activity }

class MobileWorkspacePanel extends StatefulWidget {
  const MobileWorkspacePanel({
    super.key,
    required this.workspace,
    required this.loading,
    required this.busy,
    this.error,
    this.onRefresh,
    this.onCheckSession,
    this.onRefreshSession,
    this.onRevokeCurrentSession,
    this.onRevokeDeviceSessions,
    this.onUploadNewestItem,
    this.onOpenAsset,
    this.previewImageFor,
    this.onSearch,
    this.fileTree,
    this.fileTreeLoading = false,
    this.fileTreeError,
    this.onRefreshFiles,
    this.onDownloadFile,
    this.onToggleFavorite,
    this.onToggleArchived,
  });

  final MobileWorkspaceSnapshot workspace;
  final bool loading;
  final bool busy;
  final String? error;
  final VoidCallback? onRefresh;
  final VoidCallback? onCheckSession;
  final VoidCallback? onRefreshSession;
  final VoidCallback? onRevokeCurrentSession;
  final ValueChanged<String>? onRevokeDeviceSessions;
  final VoidCallback? onUploadNewestItem;
  final ValueChanged<MobileAssetSummary>? onOpenAsset;
  final ImageProvider<Object>? Function(MobileAssetSummary asset)?
  previewImageFor;
  final Future<SearchResponse> Function(SearchQuery query)? onSearch;
  final VaultFileTreeResponse? fileTree;
  final bool fileTreeLoading;
  final String? fileTreeError;
  final VoidCallback? onRefreshFiles;
  final Future<void> Function(VaultFileEntry entry)? onDownloadFile;
  final Future<void> Function(Asset asset, bool favorite)? onToggleFavorite;
  final Future<void> Function(Asset asset, bool archived)? onToggleArchived;

  @override
  State<MobileWorkspacePanel> createState() => _MobileWorkspacePanelState();
}

class _MobileWorkspacePanelState extends State<MobileWorkspacePanel> {
  final _searchController = TextEditingController();
  final _workspaceController = TextEditingController();
  final _clientController = TextEditingController();
  final _projectController = TextEditingController();
  final _topicController = TextEditingController();
  final _sourceFolderController = TextEditingController();
  final _deviceController = TextEditingController();
  final _tagsController = TextEditingController();
  var _selectedTab = _WorkspaceTab.gallery;
  var _searching = false;
  String? _mediaKind;
  String? _currentFolderId;
  SearchResponse? _searchResult;
  String? _searchError;

  @override
  void didUpdateWidget(covariant MobileWorkspacePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final tree = widget.fileTree;
    if (tree == null || _currentFolderId == null) {
      return;
    }
    final stillExists = tree.entries.any(
      (entry) => entry.id == _currentFolderId && entry.isFolder,
    );
    if (!stillExists) {
      _currentFolderId = null;
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _workspaceController.dispose();
    _clientController.dispose();
    _projectController.dispose();
    _topicController.dispose();
    _sourceFolderController.dispose();
    _deviceController.dispose();
    _tagsController.dispose();
    super.dispose();
  }

  VaultFileEntry? _currentFolder(VaultFileTreeResponse? tree) {
    if (tree == null) {
      return null;
    }
    return _currentFolderFromTree(tree, _currentFolderId);
  }

  @override
  Widget build(BuildContext context) {
    final workspace = widget.workspace;
    final theme = Theme.of(context);
    final assets = workspace.visibleAssets.map(_summaryFromAsset).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: widget.busy ? null : widget.onRefresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
            OutlinedButton.icon(
              onPressed: widget.busy ? null : widget.onUploadNewestItem,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('Upload'),
            ),
            IconButton.outlined(
              onPressed: widget.busy ? null : widget.onCheckSession,
              icon: const Icon(Icons.verified_user_outlined),
              tooltip: 'Check session',
            ),
            IconButton.outlined(
              onPressed: widget.busy ? null : widget.onRefreshSession,
              icon: const Icon(Icons.sync_lock_outlined),
              tooltip: 'Refresh session token',
            ),
          ],
        ),
        const SizedBox(height: 16),
        _WorkspaceSummary(
          workspace: workspace,
          visibleAssetCount: assets.length,
          fileTree: widget.fileTree,
        ),
        if (widget.error != null) ...[
          const SizedBox(height: 12),
          _Notice(
            icon: Icons.warning_amber_outlined,
            title: 'Workspace unavailable',
            message: widget.error!,
          ),
        ],
        const SizedBox(height: 16),
        if (widget.loading) const LinearProgressIndicator(minHeight: 2),
        if (widget.loading) const SizedBox(height: 16),
        NavigationBar(
          selectedIndex: _WorkspaceTab.values.indexOf(_selectedTab),
          destinations: _WorkspaceTab.values
              .map(
                (tab) => NavigationDestination(
                  icon: Icon(_tabIcon(tab)),
                  label: _tabLabel(tab),
                ),
              )
              .toList(),
          onDestinationSelected: (index) {
            setState(() {
              _selectedTab = _WorkspaceTab.values[index];
            });
          },
        ),
        const SizedBox(height: 16),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: KeyedSubtree(
            key: ValueKey(_selectedTab),
            child: _buildSelectedTab(context, theme, assets),
          ),
        ),
      ],
    );
  }

  Widget _buildSelectedTab(
    BuildContext context,
    ThemeData theme,
    List<MobileAssetSummary> assets,
  ) {
    switch (_selectedTab) {
      case _WorkspaceTab.gallery:
        return MobileGalleryPanel(
          assets: assets,
          loading: widget.loading,
          busy: widget.busy,
          error: null,
          onRefresh: widget.onRefresh,
          onCheckSession: widget.onCheckSession,
          onUploadNewestItem: widget.onUploadNewestItem,
          onOpenAsset: widget.onOpenAsset,
          previewImageFor: widget.previewImageFor,
        );
      case _WorkspaceTab.files:
        return _buildFiles(context);
      case _WorkspaceTab.search:
        return _buildSearch(context);
      case _WorkspaceTab.organize:
        return _buildOrganize(context);
      case _WorkspaceTab.devices:
        return _buildDevices(context);
      case _WorkspaceTab.activity:
        return _buildActivity(context);
    }
  }

  Widget _buildOrganize(BuildContext context) {
    final workspace = widget.workspace;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Section(
          title: 'Albums',
          child: _EntityList(
            emptyTitle: 'No albums yet',
            emptyMessage:
                'Create albums on desktop; paired phones will see them here.',
            children: workspace.albums
                .map(
                  (album) => _EntityRow(
                    icon: Icons.photo_album_outlined,
                    title: album.title,
                    subtitle:
                        '${album.assetIds.length} item${album.assetIds.length == 1 ? '' : 's'}',
                  ),
                )
                .toList(),
          ),
        ),
        const SizedBox(height: 12),
        _Section(
          title: 'People & Faces',
          child: _EntityList(
            emptyTitle: 'No people yet',
            emptyMessage:
                'People clusters appear after indexing or manual setup.',
            children: workspace.people
                .map(
                  (person) => _EntityRow(
                    icon: Icons.person_outline,
                    title: person.displayName,
                    subtitle:
                        '${person.assetIds.length} item${person.assetIds.length == 1 ? '' : 's'}',
                  ),
                )
                .toList(),
          ),
        ),
        const SizedBox(height: 12),
        _Section(
          title: 'Places',
          child: _EntityList(
            emptyTitle: 'No places yet',
            emptyMessage:
                'Places appear from media metadata or desktop corrections.',
            children: workspace.places
                .map(
                  (place) => _EntityRow(
                    icon: Icons.place_outlined,
                    title: place.label,
                    subtitle:
                        '${place.assetIds.length} item${place.assetIds.length == 1 ? '' : 's'}',
                  ),
                )
                .toList(),
          ),
        ),
        const SizedBox(height: 12),
        _Section(
          title: 'Events & Memories',
          child: _EntityList(
            emptyTitle: 'No events yet',
            emptyMessage:
                'Events appear when the local library has enough dated media.',
            children: workspace.events
                .map(
                  (event) => _EntityRow(
                    icon: Icons.event_outlined,
                    title: event.title,
                    subtitle:
                        '${DateFormat.yMMMd().format(event.startAt.toLocal())} - ${event.assetIds.length} item${event.assetIds.length == 1 ? '' : 's'}',
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildFiles(BuildContext context) {
    final tree = widget.fileTree;
    final current = _currentFolder(tree);
    final children = tree == null || current == null
        ? const <VaultFileEntry>[]
        : _childrenOf(tree, current.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Section(
          title: 'Files & Documents',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _Metric(
                    icon: Icons.folder_outlined,
                    label: 'Folders',
                    value:
                        '${tree?.entries.where((entry) => entry.isFolder).length ?? 0}',
                  ),
                  _Metric(
                    icon: Icons.insert_drive_file_outlined,
                    label: 'Files',
                    value:
                        '${tree?.entries.where((entry) => entry.isFile).length ?? 0}',
                  ),
                  _Metric(
                    icon: Icons.description_outlined,
                    label: 'Documents',
                    value:
                        '${tree?.entries.where((entry) => entry.mediaKind == 'document').length ?? 0}',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: widget.busy || widget.fileTreeLoading
                    ? null
                    : widget.onRefreshFiles,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh files'),
              ),
            ],
          ),
        ),
        if (widget.fileTreeLoading) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(minHeight: 2),
        ],
        if (widget.fileTreeError != null) ...[
          const SizedBox(height: 12),
          _Notice(
            icon: Icons.warning_amber_outlined,
            title: 'Files unavailable',
            message: widget.fileTreeError!,
          ),
        ],
        const SizedBox(height: 12),
        if (tree == null || current == null)
          const _Notice(
            icon: Icons.folder_open_outlined,
            title: 'No shared files yet',
            message:
                'Files and documents uploaded to the group appear here alongside photos and videos.',
          )
        else ...[
          _FileBreadcrumbs(
            tree: tree,
            current: current,
            onOpen: (entry) {
              setState(() => _currentFolderId = entry.id);
            },
          ),
          const SizedBox(height: 12),
          _EntityList(
            emptyTitle: 'This folder is empty',
            emptyMessage:
                'Upload media, documents, or other files from a trusted device.',
            children: [
              for (final child in children)
                _EntityRow(
                  icon: _fileIcon(child),
                  title: child.name,
                  subtitle: _fileSubtitle(
                    child,
                    sourceDeviceLabel: _deviceLabelForEntry(tree, child),
                  ),
                  onTap: child.isFolder
                      ? () {
                          setState(() => _currentFolderId = child.id);
                        }
                      : null,
                  trailing: child.isFile
                      ? IconButton(
                          onPressed:
                              widget.busy || widget.onDownloadFile == null
                              ? null
                              : () => widget.onDownloadFile!(child),
                          icon: const Icon(Icons.download_outlined),
                          tooltip: 'Download file',
                        )
                      : const Icon(Icons.chevron_right),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildSearch(BuildContext context) {
    final result = _searchResult;
    final resultAssets =
        result?.assets.map(_summaryFromAsset).toList() ??
        const <MobileAssetSummary>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchController,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Search this group',
                  prefixIcon: Icon(Icons.search),
                ),
                onSubmitted: (_) => _runSearch(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: widget.busy || _searching ? null : _runSearch,
              icon: const Icon(Icons.search),
              tooltip: 'Search',
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _SearchFilterField(
              width: 160,
              controller: _workspaceController,
              label: 'Workspace',
              onSubmitted: _runSearch,
            ),
            _SearchFilterField(
              width: 160,
              controller: _clientController,
              label: 'Client',
              onSubmitted: _runSearch,
            ),
            _SearchFilterField(
              width: 160,
              controller: _projectController,
              label: 'Project',
              onSubmitted: _runSearch,
            ),
            _SearchFilterField(
              width: 160,
              controller: _topicController,
              label: 'Topic',
              onSubmitted: _runSearch,
            ),
            _SearchFilterField(
              width: 180,
              controller: _sourceFolderController,
              label: 'Source folder',
              onSubmitted: _runSearch,
            ),
            _SearchFilterField(
              width: 160,
              controller: _deviceController,
              label: 'Device',
              onSubmitted: _runSearch,
            ),
            _SearchFilterField(
              width: 160,
              controller: _tagsController,
              label: 'Tags',
              onSubmitted: _runSearch,
            ),
            FilterChip(
              avatar: const Icon(Icons.image_outlined, size: 18),
              label: const Text('Photos'),
              selected: _mediaKind == 'photo',
              onSelected: (value) {
                setState(() => _mediaKind = value ? 'photo' : null);
                _runSearch();
              },
            ),
            FilterChip(
              avatar: const Icon(Icons.movie_outlined, size: 18),
              label: const Text('Videos'),
              selected: _mediaKind == 'video',
              onSelected: (value) {
                setState(() => _mediaKind = value ? 'video' : null);
                _runSearch();
              },
            ),
            FilterChip(
              avatar: const Icon(Icons.description_outlined, size: 18),
              label: const Text('Documents'),
              selected: _mediaKind == 'document',
              onSelected: (value) {
                setState(() => _mediaKind = value ? 'document' : null);
                _runSearch();
              },
            ),
            FilterChip(
              avatar: const Icon(Icons.folder_zip_outlined, size: 18),
              label: const Text('Archives'),
              selected: _mediaKind == 'archive',
              onSelected: (value) {
                setState(() => _mediaKind = value ? 'archive' : null);
                _runSearch();
              },
            ),
            FilterChip(
              avatar: const Icon(Icons.notes_outlined, size: 18),
              label: const Text('Text'),
              selected: _mediaKind == 'text',
              onSelected: (value) {
                setState(() => _mediaKind = value ? 'text' : null);
                _runSearch();
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_searching) const LinearProgressIndicator(minHeight: 2),
        if (_searchError != null) ...[
          const SizedBox(height: 12),
          _Notice(
            icon: Icons.warning_amber_outlined,
            title: 'Search unavailable',
            message: _searchError!,
          ),
        ],
        if (result != null && !_searching) ...[
          const SizedBox(height: 12),
          MobileGalleryPanel(
            assets: resultAssets,
            loading: false,
            busy: widget.busy,
            onOpenAsset: widget.onOpenAsset,
            previewImageFor: widget.previewImageFor,
          ),
          if (result.people.isNotEmpty ||
              result.places.isNotEmpty ||
              result.events.isNotEmpty) ...[
            const SizedBox(height: 12),
            _SearchContext(result: result),
          ],
        ] else if (!_searching) ...[
          const SizedBox(height: 12),
          const _Notice(
            icon: Icons.manage_search_outlined,
            title: 'Search group media',
            message:
                'Find filenames, people, places, events, OCR text, and indexed metadata.',
          ),
        ],
      ],
    );
  }

  Widget _buildDevices(BuildContext context) {
    final workspace = widget.workspace;
    final devices = workspace.devices.isEmpty
        ? workspace.vaultStatus.devices
        : workspace.devices;
    final onlineCount = devices.where((device) {
      return _deviceStatus(device).label == 'Same network';
    }).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Section(
          title: 'Group storage',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _FactRow(label: 'Group', value: workspace.vaultStatus.vault.name),
              _FactRow(
                label: 'Protection',
                value: workspace.vaultStatus.policySatisfied
                    ? 'Protected'
                    : '${workspace.vaultStatus.underReplicatedBlobs} item(s) need another copy',
              ),
              _FactRow(
                label: 'Local availability',
                value:
                    '${workspace.vaultStatus.localAvailableAssets}/${workspace.vaultStatus.assetsTotal} item(s)',
              ),
              _FactRow(
                label: 'Sync network',
                value: workspace.syncNetwork.started
                    ? 'Direct LAN sync on ${workspace.syncNetwork.transport}'
                    : 'Stopped',
              ),
              _FactRow(
                label: 'Local devices',
                value:
                    '$onlineCount of ${devices.length} ${devices.length == 1 ? 'device' : 'devices'} on this network',
              ),
              if (workspace.syncNetwork.directAddresses.isNotEmpty)
                _FactRow(
                  label: 'LAN endpoint',
                  value: workspace.syncNetwork.directAddresses.first,
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _EntityList(
          emptyTitle: 'No devices yet',
          emptyMessage:
              'Join another phone or desktop on this LAN to see same-network reachability.',
          children: devices.map((device) {
            final status = _deviceStatus(device);
            return _EntityRow(
              icon: status.icon,
              title: device.displayName,
              subtitle: '${device.platform} - ${status.label}',
              trailing: Text(
                status.label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: status.color(Theme.of(context).colorScheme),
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 12),
        _EntityList(
          emptyTitle: 'No active mobile sessions',
          emptyMessage: 'Pair this phone again to create a fresh session.',
          children: workspace.sessions.map((session) {
            final isCurrent = session.id == workspace.session.id;
            return _EntityRow(
              icon: Icons.key_outlined,
              title: session.displayName,
              subtitle:
                  '${session.platform} - expires ${DateFormat.yMMMd().add_jm().format(session.expiresAt.toLocal())}',
              trailing: IconButton(
                onPressed: widget.busy
                    ? null
                    : isCurrent
                    ? widget.onRevokeCurrentSession
                    : widget.onRevokeDeviceSessions == null
                    ? null
                    : () => widget.onRevokeDeviceSessions!(session.deviceId),
                icon: const Icon(Icons.link_off_outlined),
                tooltip: isCurrent
                    ? 'Revoke this session'
                    : 'Revoke this device sessions',
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildActivity(BuildContext context) {
    final workspace = widget.workspace;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Section(
          title: 'Mobile permissions',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CapabilityLine(
                enabled: workspace.capabilities.canBrowseLibrary,
                label: 'Browse group library',
              ),
              _CapabilityLine(
                enabled: workspace.capabilities.canSearch,
                label: 'Search local indexes',
              ),
              _CapabilityLine(
                enabled: workspace.capabilities.canUploadCameraRoll,
                label: 'Upload camera roll items',
              ),
              _CapabilityLine(
                enabled: workspace.capabilities.canDownloadOriginals,
                label: 'Download available originals',
              ),
              _CapabilityLine(
                enabled: workspace.capabilities.canManageStorage,
                label: 'Contribute encrypted storage',
              ),
              if (workspace.capabilities.roleDetail.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(workspace.capabilities.roleDetail),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        _EntityList(
          emptyTitle: 'No recent jobs',
          emptyMessage: 'Imports, indexing, and sync work will appear here.',
          children: workspace.jobs
              .map(
                (job) => _EntityRow(
                  icon: Icons.task_alt_outlined,
                  title: job.kind,
                  subtitle:
                      '${job.status} - ${job.progress}% - ${DateFormat.yMMMd().add_jm().format(job.queuedAt.toLocal())}',
                ),
              )
              .toList(),
        ),
      ],
    );
  }

  Future<void> _runSearch() async {
    final search = widget.onSearch;
    if (search == null) {
      setState(() {
        _searchError = 'This daemon does not expose mobile search yet.';
      });
      return;
    }
    final text = _searchController.text.trim();
    final workspace = _emptyToNull(_workspaceController.text);
    final client = _emptyToNull(_clientController.text);
    final project = _emptyToNull(_projectController.text);
    final topic = _emptyToNull(_topicController.text);
    final sourceFolder = _emptyToNull(_sourceFolderController.text);
    final device = _emptyToNull(_deviceController.text);
    final tags = _emptyToNull(_tagsController.text);
    if (text.isEmpty &&
        workspace == null &&
        client == null &&
        project == null &&
        topic == null &&
        sourceFolder == null &&
        device == null &&
        _mediaKind == null &&
        tags == null) {
      setState(() {
        _searchResult = null;
        _searchError =
            'Enter a search term, device, kind, or organization filter.';
      });
      return;
    }
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final result = await search(
        SearchQuery(
          text: text,
          workspace: workspace,
          client: client,
          project: project,
          topic: topic,
          sourceFolder: sourceFolder,
          device: device,
          mediaKind: _mediaKind,
          tags: tags,
          limit: 60,
        ),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _searchResult = result;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _searchError = '$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _searching = false;
        });
      }
    }
  }

  String? _emptyToNull(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

class _SearchFilterField extends StatelessWidget {
  const _SearchFilterField({
    required this.width,
    required this.controller,
    required this.label,
    required this.onSubmitted,
  });

  final double width;
  final TextEditingController controller;
  final String label;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: controller,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          labelText: label,
          isDense: true,
        ),
        onSubmitted: (_) => onSubmitted(),
      ),
    );
  }
}

class _WorkspaceSummary extends StatelessWidget {
  const _WorkspaceSummary({
    required this.workspace,
    required this.visibleAssetCount,
    required this.fileTree,
  });

  final MobileWorkspaceSnapshot workspace;
  final int visibleAssetCount;
  final VaultFileTreeResponse? fileTree;

  @override
  Widget build(BuildContext context) {
    final devices = workspace.devices.isEmpty
        ? workspace.vaultStatus.devices
        : workspace.devices;
    return _Section(
      title: workspace.vaultStatus.vault.name,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _Metric(
            icon: Icons.photo_library_outlined,
            label: 'Media',
            value: '$visibleAssetCount',
          ),
          _Metric(
            icon: Icons.insert_drive_file_outlined,
            label: 'Files',
            value:
                '${fileTree?.entries.where((entry) => entry.isFile).length ?? 0}',
          ),
          _Metric(
            icon: Icons.photo_album_outlined,
            label: 'Albums',
            value: '${workspace.albums.length}',
          ),
          _Metric(
            icon: Icons.devices_outlined,
            label: 'Devices',
            value: '${devices.length}',
          ),
          _Metric(
            icon: workspace.vaultStatus.policySatisfied
                ? Icons.verified_outlined
                : Icons.warning_amber_outlined,
            label: 'Protection',
            value: workspace.vaultStatus.policySatisfied
                ? 'Ready'
                : 'Needs copy',
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: theme.textTheme.labelSmall),
                Text(value, style: theme.textTheme.titleSmall),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _EntityList extends StatelessWidget {
  const _EntityList({
    required this.emptyTitle,
    required this.emptyMessage,
    required this.children,
  });

  final String emptyTitle;
  final String emptyMessage;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) {
      return _Notice(
        icon: Icons.inbox_outlined,
        title: emptyTitle,
        message: emptyMessage,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final child in children) ...[child, const SizedBox(height: 8)],
      ],
    );
  }
}

class _EntityRow extends StatelessWidget {
  const _EntityRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListTile(
        onTap: onTap,
        leading: Icon(icon),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: trailing,
      ),
    );
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(label, style: Theme.of(context).textTheme.labelLarge),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class _CapabilityLine extends StatelessWidget {
  const _CapabilityLine({required this.enabled, required this.label});

  final bool enabled;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(
            enabled ? Icons.check_circle_outline : Icons.block_outlined,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }
}

class _SearchContext extends StatelessWidget {
  const _SearchContext({required this.result});

  final SearchResponse result;

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Related matches',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final person in result.people)
            _EntityRow(
              icon: Icons.person_outline,
              title: person.displayName,
              subtitle: '${person.assetIds.length} matching item(s)',
            ),
          for (final place in result.places)
            _EntityRow(
              icon: Icons.place_outlined,
              title: place.label,
              subtitle: '${place.assetIds.length} matching item(s)',
            ),
          for (final event in result.events)
            _EntityRow(
              icon: Icons.event_outlined,
              title: event.title,
              subtitle: '${event.assetIds.length} matching item(s)',
            ),
        ],
      ),
    );
  }
}

class _FileBreadcrumbs extends StatelessWidget {
  const _FileBreadcrumbs({
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
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
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
                  : () => onOpen(path[index]),
            ),
            if (index < path.length - 1)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.chevron_right, size: 18),
              ),
          ],
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

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
          ],
        ),
      ),
    );
  }
}

class _DeviceStatus {
  const _DeviceStatus({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color Function(ColorScheme colorScheme) color;
}

_DeviceStatus _deviceStatus(DeviceIdentity device) {
  if (device.revoked) {
    return _DeviceStatus(
      label: 'Revoked',
      icon: Icons.block_outlined,
      color: (colorScheme) => colorScheme.error,
    );
  }
  final lastSeen = device.lastSeenAt;
  if (lastSeen == null ||
      DateTime.now().toUtc().difference(lastSeen.toUtc()) >
          const Duration(minutes: 15)) {
    return _DeviceStatus(
      label: 'Not seen on LAN',
      icon: Icons.cloud_off_outlined,
      color: (colorScheme) => colorScheme.outline,
    );
  }
  return _DeviceStatus(
    label: 'Same network',
    icon: Icons.cloud_done_outlined,
    color: (colorScheme) => colorScheme.primary,
  );
}

MobileAssetSummary _summaryFromAsset(Asset asset) {
  return MobileAssetSummary(
    assetId: asset.id,
    originalFilename: asset.originalFilename,
    mediaKind: asset.mediaKind,
    mimeType: asset.mimeType,
    bytes: asset.bytes,
    contentHash: asset.contentHash,
    capturedAt: asset.capturedAt,
    available: asset.isAvailable,
  );
}

VaultFileEntry? _currentFolderFromTree(
  VaultFileTreeResponse tree,
  String? currentFolderId,
) {
  if (currentFolderId != null) {
    for (final entry in tree.entries) {
      if (entry.id == currentFolderId && entry.isFolder) {
        return entry;
      }
    }
  }
  return tree.roots.where((entry) => entry.isFolder).firstOrNull;
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

IconData _fileIcon(VaultFileEntry entry) {
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

String? _deviceLabelForEntry(VaultFileTreeResponse tree, VaultFileEntry entry) {
  final originDeviceId = entry.originDeviceId;
  if (originDeviceId == null) {
    return null;
  }
  return tree.devicesById[originDeviceId]?.label ?? 'Unknown device';
}

String _fileSubtitle(VaultFileEntry entry, {String? sourceDeviceLabel}) {
  if (entry.isFolder) {
    return entry.isTrashed ? 'Folder - trash' : 'Folder';
  }
  final type = entry.mediaKind ?? entry.mimeType ?? 'file';
  final parts = <String>['$type - ${_formatBytes(entry.bytes)}'];
  if (sourceDeviceLabel != null && sourceDeviceLabel.trim().isNotEmpty) {
    parts.add('from $sourceDeviceLabel');
  }
  final organization = entry.organization.summary;
  if (organization.isNotEmpty) {
    parts.add(organization);
  }
  return parts.join(' - ');
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

String _tabLabel(_WorkspaceTab tab) {
  switch (tab) {
    case _WorkspaceTab.gallery:
      return 'Gallery';
    case _WorkspaceTab.files:
      return 'Files';
    case _WorkspaceTab.search:
      return 'Search';
    case _WorkspaceTab.organize:
      return 'Organize';
    case _WorkspaceTab.devices:
      return 'Devices';
    case _WorkspaceTab.activity:
      return 'Activity';
  }
}

IconData _tabIcon(_WorkspaceTab tab) {
  switch (tab) {
    case _WorkspaceTab.gallery:
      return Icons.photo_library_outlined;
    case _WorkspaceTab.files:
      return Icons.folder_outlined;
    case _WorkspaceTab.search:
      return Icons.search;
    case _WorkspaceTab.organize:
      return Icons.category_outlined;
    case _WorkspaceTab.devices:
      return Icons.devices_outlined;
    case _WorkspaceTab.activity:
      return Icons.task_alt_outlined;
  }
}
