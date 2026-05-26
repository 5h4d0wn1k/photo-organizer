import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/gallery_models.dart';
import 'mobile_gallery_panel.dart';

enum _WorkspaceTab { gallery, search, organize, devices, activity }

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
  final Future<void> Function(Asset asset, bool favorite)? onToggleFavorite;
  final Future<void> Function(Asset asset, bool archived)? onToggleArchived;

  @override
  State<MobileWorkspacePanel> createState() => _MobileWorkspacePanelState();
}

class _MobileWorkspacePanelState extends State<MobileWorkspacePanel> {
  final _searchController = TextEditingController();
  var _selectedTab = _WorkspaceTab.gallery;
  var _searching = false;
  SearchResponse? _searchResult;
  String? _searchError;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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
                label: 'Manage storage policy',
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
    if (text.isEmpty) {
      setState(() {
        _searchResult = null;
        _searchError = 'Enter a search term.';
      });
      return;
    }
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final result = await search(SearchQuery(text: text, limit: 60));
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
}

class _WorkspaceSummary extends StatelessWidget {
  const _WorkspaceSummary({
    required this.workspace,
    required this.visibleAssetCount,
  });

  final MobileWorkspaceSnapshot workspace;
  final int visibleAssetCount;

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
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
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

String _tabLabel(_WorkspaceTab tab) {
  switch (tab) {
    case _WorkspaceTab.gallery:
      return 'Gallery';
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
