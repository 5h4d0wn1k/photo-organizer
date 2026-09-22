import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api/local_api_client.dart';
import '../features/archive/archive_screen.dart';
import '../features/albums/albums_screen.dart';
import '../features/files/files_screen.dart';
import '../features/import/import_screen.dart';
import '../features/events/events_screen.dart';
import '../features/jobs/jobs_screen.dart';
import '../features/mobile/mobile_pairing_screen.dart';
import '../features/people/people_screen.dart';
import '../features/places/places_screen.dart';
import '../features/search/search_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/setup/daemon_status_screen.dart';
import '../features/setup/setup_screen.dart';
import '../features/timeline/timeline_screen.dart';
import '../features/vaults/vaults_screen.dart';
import '../models/gallery_models.dart';
import '../repositories/gallery_repository.dart';
import '../repositories/resilient_gallery_repository.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';

enum GalleryClientMode { desktop, mobile }

class PrivateGalleryApp extends StatelessWidget {
  const PrivateGalleryApp({super.key, this.mode});

  final GalleryClientMode? mode;

  @override
  Widget build(BuildContext context) {
    final effectiveMode = mode ?? defaultGalleryClientMode();
    return MaterialApp(
      title: 'Private Gallery',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: effectiveMode == GalleryClientMode.mobile
          ? const MobilePairingScreen()
          : const GalleryBootstrapPage(),
    );
  }
}

GalleryClientMode defaultGalleryClientMode() {
  if (kIsWeb) {
    return GalleryClientMode.desktop;
  }
  return switch (defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS => GalleryClientMode.mobile,
    TargetPlatform.fuchsia ||
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => GalleryClientMode.desktop,
  };
}

class GalleryBootstrapPage extends StatefulWidget {
  const GalleryBootstrapPage({super.key});

  @override
  State<GalleryBootstrapPage> createState() => _GalleryBootstrapPageState();
}

class _GalleryBootstrapPageState extends State<GalleryBootstrapPage> {
  late final GalleryRepository _repository;
  AppLaunchResult? _launchResult;
  bool _loading = true;
  bool _submittingSetup = false;
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _repository = ResilientGalleryRepository();
    _loadWorkspace(attemptStartIfNeeded: true);
  }

  Future<void> _loadWorkspace({bool attemptStartIfNeeded = false}) async {
    setState(() => _loading = true);
    try {
      final launchResult = await _repository.loadWorkspace(
        attemptStartIfNeeded: attemptStartIfNeeded,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _launchResult = launchResult;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _launchResult = AppLaunchResult.error(
          launchResult: const DaemonLaunchResult.none(),
          message: '$error',
        );
        _loading = false;
      });
    }
  }

  Future<void> _submitSetup(SetupDraft draft) async {
    setState(() => _submittingSetup = true);
    try {
      await _repository.saveLibrarySettings(draft.settings);
      for (final watchFolder in draft.watchFolders) {
        await _repository.addWatchFolder(watchFolder);
      }
      await _loadWorkspace();
    } catch (error) {
      _showMessage('$error');
    } finally {
      if (mounted) {
        setState(() => _submittingSetup = false);
      }
    }
  }

  Future<void> _saveSettings(LibrarySettingsDraft draft) async {
    await _repository.saveLibrarySettings(draft);
    await _loadWorkspace();
  }

  Future<void> _activateEncryption() async {
    try {
      final result = await _repository.activateEncryption();
      await _loadWorkspace();
      _showMessage(
        'Encryption active. Plaintext backup kept at ${result.backupPath}.',
      );
    } catch (error) {
      _showMessage('$error');
    }
  }

  Future<ModelArtifact> _importLocalModel({
    required String id,
    required String localPath,
    String? expectedSha256,
    required bool confirmed,
  }) async {
    final model = await _repository.importLocalModel(
      id: id,
      localPath: localPath,
      expectedSha256: expectedSha256,
      confirmed: confirmed,
    );
    await _loadWorkspace();
    return model;
  }

  Future<ModelArtifact> _verifyModel(String id) async {
    final model = await _repository.verifyModel(id);
    await _loadWorkspace();
    return model;
  }

  Future<void> _addWatchFolder(WatchFolderDraft draft) async {
    await _repository.addWatchFolder(draft);
    await _loadWorkspace();
  }

  Future<void> _deleteWatchFolder(String id) async {
    try {
      await _repository.deleteWatchFolder(id);
      await _loadWorkspace();
      _showMessage('Watch folder removed.');
    } catch (error) {
      _showMessage('$error');
    }
  }

  Future<void> _indexPeople() async {
    try {
      final job = await _repository.indexPeople();
      await _loadWorkspace();
      _showMessage(job.detail ?? 'People indexing job ${job.status}.');
    } catch (error) {
      _showMessage('$error');
    }
  }

  Future<void> _resetPeople() async {
    try {
      final job = await _repository.resetPeople();
      await _loadWorkspace();
      _showMessage(job.detail ?? 'People data reset locally.');
    } catch (error) {
      _showMessage('$error');
    }
  }

  Future<void> _createManualPerson(String displayName) async {
    try {
      await _repository.createManualPerson(displayName: displayName);
      await _loadWorkspace();
      _showMessage('Manual person created.');
    } catch (error) {
      _showMessage('$error');
    }
  }

  Future<void> _renamePerson(String id, String displayName) async {
    try {
      await _repository.renamePerson(id, displayName);
      await _loadWorkspace();
      _showMessage('Person renamed.');
    } catch (error) {
      _showMessage('$error');
    }
  }

  Future<void> _hidePerson(String id, bool hidden) async {
    try {
      await _repository.hidePerson(
        id,
        hidden: hidden,
        reason: hidden ? 'Hidden from People screen' : 'Unhidden locally',
      );
      await _loadWorkspace();
      _showMessage(hidden ? 'Person hidden.' : 'Person unhidden.');
    } catch (error) {
      _showMessage('$error');
    }
  }

  Future<void> _rejectPersonMatch(String id) async {
    try {
      await _repository.rejectPersonMatch(
        id,
        reason: 'Rejected from People screen',
      );
      await _loadWorkspace();
      _showMessage('Match rejection recorded.');
    } catch (error) {
      _showMessage('$error');
    }
  }

  Future<void> _mergePerson(String targetId, List<String> sourceIds) async {
    try {
      await _repository.mergePerson(targetId, sourceIds);
      await _loadWorkspace();
      _showMessage('People merged.');
    } catch (error) {
      _showMessage('$error');
    }
  }

  Future<void> _splitPerson(
    String id, {
    required List<String> faceTemplateIds,
    String? newDisplayName,
  }) async {
    try {
      await _repository.splitPerson(
        id,
        faceTemplateIds: faceTemplateIds,
        newDisplayName: newDisplayName,
      );
      await _loadWorkspace();
      _showMessage('Person split recorded.');
    } catch (error) {
      _showMessage('$error');
    }
  }

  Future<void> _rebuildPlaces() async {
    try {
      final job = await _repository.rebuildPlaces();
      await _loadWorkspace();
      _showMessage(job.detail ?? 'Places rebuilt locally.');
    } catch (error) {
      _showMessage('$error');
    }
  }

  Future<void> _correctPlace(
    String id, {
    required String label,
    double? latitude,
    double? longitude,
    bool? hideExactGps,
  }) async {
    try {
      await _repository.correctPlace(
        id,
        label: label,
        latitude: latitude,
        longitude: longitude,
        hideExactGps: hideExactGps,
        reason: 'Corrected from Places screen',
      );
      await _loadWorkspace();
      _showMessage('Place correction saved.');
    } catch (error) {
      _showMessage('$error');
    }
  }

  Future<void> _rebuildEvents() async {
    try {
      final job = await _repository.rebuildEvents();
      await _loadWorkspace();
      _showMessage(job.detail ?? 'Events rebuilt locally.');
    } catch (error) {
      _showMessage('$error');
    }
  }

  Future<void> _titleEvent(String id, String title) async {
    try {
      await _repository.titleEvent(id, title);
      await _loadWorkspace();
      _showMessage('Event title saved.');
    } catch (error) {
      _showMessage('$error');
    }
  }

  Future<void> _openImport() async {
    final workspace = _launchResult?.workspace;
    if (workspace == null || !mounted) {
      return;
    }

    final result = await Navigator.of(context).push<ImportSession>(
      MaterialPageRoute(
        builder: (_) => ImportScreen(
          repository: _repository,
          defaultImportMode: workspace.settings.defaultImportMode,
        ),
      ),
    );

    if (!mounted || result == null) {
      return;
    }

    await _loadWorkspace();
    if (!mounted) {
      return;
    }
    setState(() => _selectedIndex = 0);
    _showMessage(
      'Imported ${result.importedAssetIds.length} assets, moved ${result.movedAssetIds.length}, moved ${result.sidecarsMoved} sidecars, skipped ${result.skippedDuplicateIds.length} duplicates.',
    );
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _pageTitle(int index) {
    switch (index) {
      case 0:
        return 'Gallery';
      case 1:
        return 'Files';
      case 2:
        return 'Albums';
      case 3:
        return 'People';
      case 4:
        return 'Places';
      case 5:
        return 'Events';
      case 6:
        return 'Search';
      case 7:
        return 'Archive';
      case 8:
        return 'My Devices';
      case 9:
        return 'Sync & Activity';
      case 10:
        return 'Settings';
      default:
        return 'Private Gallery';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _launchResult == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final launchResult = _launchResult;
    if (launchResult == null) {
      return const Scaffold(
        body: Center(child: Text('Unable to initialize the gallery client.')),
      );
    }

    switch (launchResult.status) {
      case AppLaunchStatus.setupRequired:
        return SetupScreen(
          message: launchResult.message,
          libraryStatus: launchResult.libraryStatus,
          diagnostics: launchResult.diagnostics,
          submitting: _submittingSetup,
          onSubmit: _submitSetup,
          onRetry: _loadWorkspace,
          onStartDaemon: () => _loadWorkspace(attemptStartIfNeeded: true),
        );
      case AppLaunchStatus.daemonUnavailable:
      case AppLaunchStatus.error:
        return DaemonStatusScreen(
          title: launchResult.status == AppLaunchStatus.error
              ? 'Unable to load the local workspace'
              : 'Local daemon unavailable',
          message:
              launchResult.message ??
              'The desktop client could not reach the local library daemon.',
          launchResult: launchResult.launchResult,
          onRetry: _loadWorkspace,
          onStartDaemon: () => _loadWorkspace(attemptStartIfNeeded: true),
        );
      case AppLaunchStatus.ready:
        return _GalleryWorkspaceShell(
          workspace: launchResult.workspace!,
          repository: _repository,
          selectedIndex: _selectedIndex,
          loading: _loading,
          onSelectIndex: (value) {
            setState(() => _selectedIndex = value);
          },
          onRefresh: _loadWorkspace,
          onImport: _openImport,
          onActivateEncryption: _activateEncryption,
          onImportLocalModel: _importLocalModel,
          onVerifyModel: _verifyModel,
          onSaveSettings: _saveSettings,
          onAddWatchFolder: _addWatchFolder,
          onDeleteWatchFolder: _deleteWatchFolder,
          onIndexPeople: _indexPeople,
          onResetPeople: _resetPeople,
          onCreateManualPerson: _createManualPerson,
          onRenamePerson: _renamePerson,
          onHidePerson: _hidePerson,
          onRejectPersonMatch: _rejectPersonMatch,
          onMergePerson: _mergePerson,
          onSplitPerson: _splitPerson,
          onRebuildPlaces: _rebuildPlaces,
          onCorrectPlace: _correctPlace,
          onRebuildEvents: _rebuildEvents,
          onTitleEvent: _titleEvent,
          pageTitle: _pageTitle(_selectedIndex),
        );
    }
  }
}

class _GalleryWorkspaceShell extends StatelessWidget {
  const _GalleryWorkspaceShell({
    required this.workspace,
    required this.repository,
    required this.selectedIndex,
    required this.loading,
    required this.onSelectIndex,
    required this.onRefresh,
    required this.onImport,
    required this.onActivateEncryption,
    required this.onImportLocalModel,
    required this.onVerifyModel,
    required this.onSaveSettings,
    required this.onAddWatchFolder,
    required this.onDeleteWatchFolder,
    required this.onIndexPeople,
    required this.onResetPeople,
    required this.onCreateManualPerson,
    required this.onRenamePerson,
    required this.onHidePerson,
    required this.onRejectPersonMatch,
    required this.onMergePerson,
    required this.onSplitPerson,
    required this.onRebuildPlaces,
    required this.onCorrectPlace,
    required this.onRebuildEvents,
    required this.onTitleEvent,
    required this.pageTitle,
  });

  final WorkspaceSnapshot workspace;
  final GalleryRepository repository;
  final int selectedIndex;
  final bool loading;
  final ValueChanged<int> onSelectIndex;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onImport;
  final Future<void> Function() onActivateEncryption;
  final Future<ModelArtifact> Function({
    required String id,
    required String localPath,
    String? expectedSha256,
    required bool confirmed,
  })
  onImportLocalModel;
  final Future<ModelArtifact> Function(String id) onVerifyModel;
  final Future<void> Function(LibrarySettingsDraft draft) onSaveSettings;
  final Future<void> Function(WatchFolderDraft draft) onAddWatchFolder;
  final Future<void> Function(String id) onDeleteWatchFolder;
  final Future<void> Function() onIndexPeople;
  final Future<void> Function() onResetPeople;
  final Future<void> Function(String displayName) onCreateManualPerson;
  final Future<void> Function(String id, String displayName) onRenamePerson;
  final Future<void> Function(String id, bool hidden) onHidePerson;
  final Future<void> Function(String id) onRejectPersonMatch;
  final Future<void> Function(String targetId, List<String> sourceIds)
  onMergePerson;
  final Future<void> Function(
    String id, {
    required List<String> faceTemplateIds,
    String? newDisplayName,
  })
  onSplitPerson;
  final Future<void> Function() onRebuildPlaces;
  final Future<void> Function(
    String id, {
    required String label,
    double? latitude,
    double? longitude,
    bool? hideExactGps,
  })
  onCorrectPlace;
  final Future<void> Function() onRebuildEvents;
  final Future<void> Function(String id, String title) onTitleEvent;
  final String pageTitle;

  @override
  Widget build(BuildContext context) {
    final pages = [
      TimelineScreen(
        workspace: workspace,
        repository: repository,
        onImportNow: () {
          onImport();
        },
        onLibraryChanged: onRefresh,
      ),
      FilesScreen(apiClient: LocalApiClient(), onLibraryChanged: onRefresh),
      AlbumsScreen(
        albums: workspace.dashboard.albums,
        libraryRoot: workspace.settings.libraryRoot,
        onCreateAlbum: (title) => repository.createAlbum(title: title),
        onFetchFavoriteAssets: repository.fetchFavoriteAssets,
        onFetchArchivedAssets: repository.fetchArchivedAssets,
        onFetchAlbumAssets: repository.fetchAlbumAssets,
        onUpdateAssetFlags: repository.updateAssetFlags,
        onRemoveAlbumAssets: repository.removeAlbumAssets,
        onRenameAlbum: repository.renameAlbum,
        onDeleteAlbum: repository.deleteAlbum,
        onAlbumsChanged: onRefresh,
      ),
      PeopleScreen(
        people: workspace.dashboard.people,
        models: workspace.dashboard.models,
        libraryRoot: workspace.settings.libraryRoot,
        privacyStatus: workspace.privacyStatus,
        onIndexPeople: onIndexPeople,
        onResetPeople: onResetPeople,
        onCreateManualPerson: onCreateManualPerson,
        onFetchPersonAssets: repository.fetchPersonAssets,
        onRemovePersonAssets: repository.removePersonAssets,
        onPeopleChanged: onRefresh,
        onRenamePerson: onRenamePerson,
        onHidePerson: onHidePerson,
        onRejectPersonMatch: onRejectPersonMatch,
        onMergePerson: onMergePerson,
        onSplitPerson: onSplitPerson,
      ),
      PlacesScreen(
        places: workspace.dashboard.places,
        libraryRoot: workspace.settings.libraryRoot,
        onFetchPlaceAssets: repository.fetchPlaceAssets,
        onRebuildPlaces: onRebuildPlaces,
        onCorrectPlace: onCorrectPlace,
      ),
      EventsScreen(
        events: workspace.dashboard.events,
        libraryRoot: workspace.settings.libraryRoot,
        onFetchEventAssets: repository.fetchEventAssets,
        onRebuildEvents: onRebuildEvents,
        onTitleEvent: onTitleEvent,
      ),
      SearchScreen(repository: repository),
      ArchiveScreen(
        repository: repository,
        libraryRoot: workspace.settings.libraryRoot,
        onLibraryChanged: onRefresh,
      ),
      VaultsScreen(repository: repository),
      JobsScreen(
        jobs: workspace.dashboard.jobs,
        onFetchLogs: repository.fetchJobLogs,
        onCancelJob: repository.cancelJob,
        onRetryJob: repository.retryJob,
        onRefresh: onRefresh,
      ),
      SettingsScreen(
        key: ValueKey(
          '${workspace.settings.libraryRoot}:${workspace.settings.updatedAt?.toIso8601String()}:${workspace.watchFolders.length}',
        ),
        workspace: workspace,
        onActivateEncryption: onActivateEncryption,
        onImportLocalModel: onImportLocalModel,
        onVerifyModel: onVerifyModel,
        onVerifyBackup: repository.verifyBackup,
        onExportBackup: repository.exportBackup,
        onExportSupportBundle: repository.exportSupportBundle,
        onPlanRestoreBackup: repository.planRestoreBackup,
        onRunRestoreBackup: repository.runRestoreBackup,
        onSaveSettings: onSaveSettings,
        onAddWatchFolder: onAddWatchFolder,
        onDeleteWatchFolder: onDeleteWatchFolder,
        onOpenImport: () {
          onImport();
        },
      ),
    ];

    final destinations = const [
      NavigationRailDestination(
        icon: Icon(Icons.photo_library_outlined),
        label: Text('Gallery'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.folder_outlined),
        label: Text('Files'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.photo_album_outlined),
        label: Text('Albums'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.face_outlined),
        label: Text('People'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.place_outlined),
        label: Text('Places'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.event_outlined),
        label: Text('Events'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.search_outlined),
        label: Text('Search'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.archive_outlined),
        label: Text('Archive'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.devices_outlined),
        label: Text('My Devices'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.sync_outlined),
        label: Text('Activity'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.settings_outlined),
        label: Text('Settings'),
      ),
    ];
    final diagnostics = workspace.diagnostics;
    final assetCount = diagnostics?.assets ?? workspace.dashboard.assetCount;
    final syncSessions = diagnostics?.syncSessions ?? 0;
    final localOnlyHealthy = workspace.privacyStatus?.localOnlyHealthy ?? false;
    final encryptedOnly =
        workspace.settings.originalStoragePolicy ==
        OriginalStoragePolicy.encryptedOnly;

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 980;
        final header = _WorkspaceCommandHeader(
          pageTitle: pageTitle,
          libraryRoot: workspace.settings.libraryRoot,
          assetCount: assetCount,
          watchFolderCount: workspace.watchFolders.length,
          syncSessionCount: syncSessions,
          localOnlyHealthy: localOnlyHealthy,
          encryptedOnly: encryptedOnly,
          loading: loading,
          onImport: onImport,
          onRefresh: onRefresh,
        );

        return Scaffold(
          drawer: wide
              ? null
              : NavigationDrawer(
                  selectedIndex: selectedIndex,
                  onDestinationSelected: (value) {
                    onSelectIndex(value);
                    Navigator.of(context).maybePop();
                  },
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                      child: _DrawerBrandHeader(
                        assetCount: assetCount,
                        encryptedOnly: encryptedOnly,
                        localOnlyHealthy: localOnlyHealthy,
                      ),
                    ),
                    for (final destination in destinations)
                      NavigationDrawerDestination(
                        icon: destination.icon,
                        label: destination.label,
                      ),
                  ],
                ),
          appBar: AppBar(
            title: const Text('Private Gallery'),
            actions: [
              IconButton(
                onPressed: onImport,
                icon: const Icon(Icons.file_upload_outlined),
                tooltip: 'Import media',
              ),
              IconButton(
                onPressed: loading ? null : onRefresh,
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh library',
              ),
            ],
            bottom: loading
                ? const PreferredSize(
                    preferredSize: Size.fromHeight(2),
                    child: LinearProgressIndicator(minHeight: 2),
                  )
                : null,
          ),
          body: wide
              ? Row(
                  children: [
                    NavigationRail(
                      extended: constraints.maxWidth >= 1200,
                      selectedIndex: selectedIndex,
                      destinations: destinations,
                      onDestinationSelected: onSelectIndex,
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: Column(
                        children: [
                          header,
                          Expanded(child: pages[selectedIndex]),
                        ],
                      ),
                    ),
                  ],
                )
              : Column(
                  children: [
                    header,
                    Expanded(
                      child: IndexedStack(
                        index: selectedIndex,
                        children: pages,
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class _WorkspaceCommandHeader extends StatelessWidget {
  const _WorkspaceCommandHeader({
    required this.pageTitle,
    required this.libraryRoot,
    required this.assetCount,
    required this.watchFolderCount,
    required this.syncSessionCount,
    required this.localOnlyHealthy,
    required this.encryptedOnly,
    required this.loading,
    required this.onImport,
    required this.onRefresh,
  });

  final String pageTitle;
  final String libraryRoot;
  final int assetCount;
  final int watchFolderCount;
  final int syncSessionCount;
  final bool localOnlyHealthy;
  final bool encryptedOnly;
  final bool loading;
  final Future<void> Function() onImport;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 760;
            final titleBlock = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(pageTitle, style: theme.textTheme.headlineSmall),
                const SizedBox(height: 6),
                Text(
                  _shortPath(libraryRoot),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    AppStatusBadge(
                      label: localOnlyHealthy ? 'Local only' : 'Remote enabled',
                      tone: localOnlyHealthy
                          ? AppStatusTone.success
                          : AppStatusTone.warning,
                      icon: localOnlyHealthy
                          ? Icons.verified_user_outlined
                          : Icons.public_outlined,
                    ),
                    AppStatusBadge(
                      label: encryptedOnly
                          ? 'Encrypted originals'
                          : 'Plaintext originals',
                      tone: encryptedOnly
                          ? AppStatusTone.success
                          : AppStatusTone.warning,
                      icon: encryptedOnly
                          ? Icons.lock_outline
                          : Icons.folder_open_outlined,
                    ),
                  ],
                ),
              ],
            );

            final metrics = Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _HeaderMetric(
                  icon: Icons.photo_library_outlined,
                  label: 'Items',
                  value: '$assetCount',
                ),
                _HeaderMetric(
                  icon: Icons.folder_copy_outlined,
                  label: 'Watch',
                  value: '$watchFolderCount',
                ),
                _HeaderMetric(
                  icon: Icons.devices_outlined,
                  label: 'Sync',
                  value: '$syncSessionCount',
                ),
              ],
            );

            final actions = Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: onImport,
                  icon: const Icon(Icons.file_upload_outlined),
                  label: const Text('Import'),
                ),
                OutlinedButton.icon(
                  onPressed: loading
                      ? null
                      : () {
                          onRefresh();
                        },
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                ),
              ],
            );

            if (compact) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  titleBlock,
                  const SizedBox(height: 14),
                  metrics,
                  const SizedBox(height: 14),
                  actions,
                ],
              );
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(flex: 2, child: titleBlock),
                const SizedBox(width: 24),
                Expanded(child: metrics),
                const SizedBox(width: 24),
                actions,
              ],
            );
          },
        ),
      ),
    );
  }
}

class _HeaderMetric extends StatelessWidget {
  const _HeaderMetric({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: theme.colorScheme.primary),
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

class _DrawerBrandHeader extends StatelessWidget {
  const _DrawerBrandHeader({
    required this.assetCount,
    required this.encryptedOnly,
    required this.localOnlyHealthy,
  });

  final int assetCount;
  final bool encryptedOnly;
  final bool localOnlyHealthy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Private Gallery', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text('$assetCount indexed items', style: theme.textTheme.bodySmall),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            AppStatusBadge(
              label: localOnlyHealthy ? 'Local only' : 'Remote',
              tone: localOnlyHealthy
                  ? AppStatusTone.success
                  : AppStatusTone.warning,
            ),
            AppStatusBadge(
              label: encryptedOnly ? 'Encrypted' : 'Plaintext',
              tone: encryptedOnly
                  ? AppStatusTone.success
                  : AppStatusTone.warning,
            ),
          ],
        ),
      ],
    );
  }
}

String _shortPath(String path) {
  if (path.isEmpty) {
    return 'No library root selected';
  }
  if (path.length <= 72) {
    return path;
  }
  return '...${path.substring(path.length - 69)}';
}
