import 'package:flutter/material.dart';

import '../../models/gallery_models.dart';
import '../../repositories/gallery_repository.dart';
import '../../widgets/asset_grid.dart';
import '../../widgets/empty_state_panel.dart';
import '../media/media_viewer.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.repository});

  final GalleryRepository repository;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  static const int _safeOcrBatchLimit = 10;

  final TextEditingController _controller = TextEditingController();
  final TextEditingController _personController = TextEditingController();
  final TextEditingController _placeController = TextEditingController();
  final TextEditingController _eventController = TextEditingController();
  final TextEditingController _workspaceController = TextEditingController();
  final TextEditingController _clientController = TextEditingController();
  final TextEditingController _projectController = TextEditingController();
  final TextEditingController _topicController = TextEditingController();
  final TextEditingController _sourceFolderController = TextEditingController();
  final TextEditingController _deviceController = TextEditingController();
  final TextEditingController _tagsController = TextEditingController();
  final TextEditingController _fromDateController = TextEditingController();
  final TextEditingController _toDateController = TextEditingController();
  Future<SearchResponse>? _searchFuture;
  late Future<SearchIndexStatus?> _statusFuture;
  List<SmartFolder> _smartFolders = const [];
  SearchQuery? _lastSubmittedQuery;
  String? _submittedQuery;
  String? _smartFolderError;
  JobRecord? _lastOcrJob;
  JobRecord? _lastSceneJob;
  String? _ocrError;
  String? _sceneError;
  bool _loadingSmartFolders = false;
  bool _savingSmartFolder = false;
  bool _ocrRunning = false;
  bool _sceneRunning = false;
  bool _includeArchived = false;
  bool _favoritesOnly = false;
  String? _mediaKind;

  @override
  void initState() {
    super.initState();
    _statusFuture = widget.repository.fetchSearchStatus();
    _loadSmartFolders();
  }

  @override
  void dispose() {
    _controller.dispose();
    _personController.dispose();
    _placeController.dispose();
    _eventController.dispose();
    _workspaceController.dispose();
    _clientController.dispose();
    _projectController.dispose();
    _topicController.dispose();
    _sourceFolderController.dispose();
    _deviceController.dispose();
    _tagsController.dispose();
    _fromDateController.dispose();
    _toDateController.dispose();
    super.dispose();
  }

  void _runSearch() {
    final query = SearchQuery(
      text: _controller.text.trim(),
      people: _emptyToNull(_personController.text),
      places: _emptyToNull(_placeController.text),
      events: _emptyToNull(_eventController.text),
      workspace: _emptyToNull(_workspaceController.text),
      client: _emptyToNull(_clientController.text),
      project: _emptyToNull(_projectController.text),
      topic: _emptyToNull(_topicController.text),
      sourceFolder: _emptyToNull(_sourceFolderController.text),
      device: _emptyToNull(_deviceController.text),
      mediaKind: _mediaKind,
      tags: _emptyToNull(_tagsController.text),
      favorite: _favoritesOnly ? true : null,
      fromDate: _emptyToNull(_fromDateController.text),
      toDate: _emptyToNull(_toDateController.text),
      includeArchived: _includeArchived,
      limit: 80,
    );
    if (query.text.isEmpty &&
        query.people == null &&
        query.places == null &&
        query.events == null &&
        query.workspace == null &&
        query.client == null &&
        query.project == null &&
        query.topic == null &&
        query.sourceFolder == null &&
        query.device == null &&
        query.mediaKind == null &&
        query.tags == null &&
        query.favorite == null &&
        query.fromDate == null &&
        query.toDate == null &&
        !query.includeArchived) {
      setState(() {
        _submittedQuery = null;
        _searchFuture = null;
        _lastSubmittedQuery = null;
      });
      return;
    }

    setState(() {
      _submittedQuery = _queryLabel(query);
      _lastSubmittedQuery = query;
      _searchFuture = widget.repository.search(query);
    });
  }

  Future<void> _loadSmartFolders() async {
    setState(() {
      _loadingSmartFolders = true;
      _smartFolderError = null;
    });
    try {
      final folders = await widget.repository.fetchSmartFolders();
      if (!mounted) {
        return;
      }
      setState(() {
        _smartFolders = folders;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _smartFolderError = '$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingSmartFolders = false;
        });
      }
    }
  }

  Future<void> _saveSmartFolder() async {
    final query = _lastSubmittedQuery;
    if (query == null) {
      return;
    }
    final title = await _promptForSmartFolderTitle();
    if (title == null || title.trim().isEmpty) {
      return;
    }
    setState(() {
      _savingSmartFolder = true;
      _smartFolderError = null;
    });
    try {
      await widget.repository.createSmartFolder(
        title: title.trim(),
        query: query,
      );
      await _loadSmartFolders();
      _showMessage('Smart folder saved.');
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _smartFolderError = '$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _savingSmartFolder = false;
        });
      }
    }
  }

  Future<void> _runSmartFolder(SmartFolder folder) async {
    setState(() {
      _submittedQuery = 'smart:${folder.title}';
      _lastSubmittedQuery = folder.query;
      _searchFuture = widget.repository.runSmartFolder(folder.id);
    });
  }

  Future<void> _deleteSmartFolder(SmartFolder folder) async {
    try {
      await widget.repository.deleteSmartFolder(folder.id);
      await _loadSmartFolders();
      _showMessage('Smart folder deleted.');
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _smartFolderError = '$error';
      });
    }
  }

  Future<String?> _promptForSmartFolderTitle() {
    final controller = TextEditingController(
      text: _submittedQuery == null || _submittedQuery!.isEmpty
          ? 'Smart folder'
          : _submittedQuery!,
    );
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Save smart folder'),
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

  String? _emptyToNull(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String _queryLabel(SearchQuery query) {
    final parts = <String>[
      if (query.text.isNotEmpty) query.text,
      if (query.people != null) 'person:${query.people}',
      if (query.places != null) 'place:${query.places}',
      if (query.events != null) 'event:${query.events}',
      if (query.workspace != null) 'workspace:${query.workspace}',
      if (query.client != null) 'client:${query.client}',
      if (query.project != null) 'project:${query.project}',
      if (query.topic != null) 'topic:${query.topic}',
      if (query.sourceFolder != null) 'folder:${query.sourceFolder}',
      if (query.device != null) 'device:${query.device}',
      if (query.mediaKind != null) 'kind:${query.mediaKind}',
      if (query.tags != null) 'tags:${query.tags}',
      if (query.favorite == true) 'favorites',
      if (query.fromDate != null) 'from:${query.fromDate}',
      if (query.toDate != null) 'to:${query.toDate}',
      if (query.includeArchived) 'archived included',
    ];
    return parts.join(' ');
  }

  Future<void> _runOcrBatch() async {
    setState(() {
      _ocrRunning = true;
      _ocrError = null;
    });

    try {
      final job = await widget.repository.rebuildOcr(limit: _safeOcrBatchLimit);
      if (!mounted) {
        return;
      }
      setState(() {
        _lastOcrJob = job;
        _statusFuture = widget.repository.fetchSearchStatus();
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _ocrError = '$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _ocrRunning = false;
        });
      }
    }
  }

  Future<void> _runSceneBatch() async {
    setState(() {
      _sceneRunning = true;
      _sceneError = null;
    });

    try {
      final job = await widget.repository.rebuildScenes(
        limit: _safeOcrBatchLimit,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _lastSceneJob = job;
        _statusFuture = widget.repository.fetchSearchStatus();
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _sceneError = '$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _sceneRunning = false;
        });
      }
    }
  }

  Future<void> _showAssetDetails(Asset asset) {
    return MediaViewer.show(
      context,
      asset: asset,
      loadAvailability: widget.repository.fetchAssetAvailability,
      pinLocalAsset: widget.repository.pinLocalAsset,
      evictLocalAsset: widget.repository.evictLocalAsset,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Search',
            style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          FutureBuilder<SearchIndexStatus?>(
            future: _statusFuture,
            builder: (context, snapshot) {
              final status = snapshot.data;
              if (status == null) {
                return const SizedBox.shrink();
              }
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ListTile(
                        leading: Icon(
                          status.intelligenceReady
                              ? Icons.manage_search_outlined
                              : Icons.lock_outline,
                        ),
                        title: Text(
                          status.intelligenceReady
                              ? 'Local intelligence indexes available'
                              : 'Advanced search is gated',
                        ),
                        subtitle: Text(
                          '${status.detail}\nFilename: ${status.filenameReady ? 'ready' : 'off'} • Metadata: ${status.metadataReady ? 'ready' : 'partial'} • OCR: ${status.ocrReady ? 'ready' : 'not indexed'} • Scenes: ${status.sceneReady ? 'ready' : 'not installed'} • Semantic: ${status.semanticReady ? 'ready' : 'not installed'}',
                        ),
                      ),
                      if (status.ocrIndexedAssetCount > 0 ||
                          status.ocrTotalPhotoCount > 0)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          child: LinearProgressIndicator(
                            value: status.ocrTotalPhotoCount == 0
                                ? null
                                : status.ocrIndexedAssetCount /
                                      status.ocrTotalPhotoCount,
                            minHeight: 8,
                          ),
                        ),
                      if (status.ocrIndexedAssetCount > 0 ||
                          status.ocrTotalPhotoCount > 0)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          child: Text(
                            status.ocrPartiallyIndexed
                                ? 'OCR coverage is partial: ${status.ocrIndexedAssetCount} photo(s) have searchable text blocks, ${status.ocrRemainingPhotoCount} photo(s) still need indexing or no-text confirmation.'
                                : 'OCR coverage: ${status.ocrIndexedAssetCount} of ${status.ocrTotalPhotoCount} photo(s) have searchable text blocks.',
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            OutlinedButton.icon(
                              onPressed: _ocrRunning ? null : _runOcrBatch,
                              icon: _ocrRunning
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.document_scanner_outlined),
                              label: Text(
                                _ocrRunning
                                    ? 'Indexing OCR locally...'
                                    : 'Index next $_safeOcrBatchLimit photos',
                              ),
                            ),
                            OutlinedButton.icon(
                              onPressed: _sceneRunning ? null : _runSceneBatch,
                              icon: _sceneRunning
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.auto_awesome_mosaic_outlined,
                                    ),
                              label: Text(
                                _sceneRunning
                                    ? 'Indexing scenes locally...'
                                    : 'Index next $_safeOcrBatchLimit scene tags',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          if (_loadingSmartFolders ||
              _smartFolders.isNotEmpty ||
              _smartFolderError != null) ...[
            const SizedBox(height: 12),
            _SmartFolderStrip(
              folders: _smartFolders,
              loading: _loadingSmartFolders,
              error: _smartFolderError,
              onOpen: _runSmartFolder,
              onDelete: _deleteSmartFolder,
            ),
          ],
          if (_lastOcrJob != null || _ocrError != null) ...[
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: Icon(
                  _ocrError == null ? Icons.fact_check_outlined : Icons.error,
                ),
                title: Text(
                  _ocrError == null ? 'OCR batch finished' : 'OCR batch failed',
                ),
                subtitle: Text(
                  _ocrError ??
                      '${_lastOcrJob!.status}: ${_lastOcrJob!.detail ?? 'No detail returned.'}',
                ),
              ),
            ),
          ],
          if (_lastSceneJob != null || _sceneError != null) ...[
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: Icon(
                  _sceneError == null ? Icons.fact_check_outlined : Icons.error,
                ),
                title: Text(
                  _sceneError == null
                      ? 'Scene batch finished'
                      : 'Scene batch failed',
                ),
                subtitle: Text(
                  _sceneError ??
                      '${_lastSceneJob!.status}: ${_lastSceneJob!.detail ?? 'No detail returned.'}',
                ),
              ),
            ),
          ],
          const SizedBox(height: 20),
          TextField(
            controller: _controller,
            decoration: const InputDecoration(
              hintText: 'Try “Goa”, “family dinner”, or a filename',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _runSearch(),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _personController,
                  decoration: const InputDecoration(
                    labelText: 'Person',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _runSearch(),
                ),
              ),
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _placeController,
                  decoration: const InputDecoration(
                    labelText: 'Place',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _runSearch(),
                ),
              ),
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _eventController,
                  decoration: const InputDecoration(
                    labelText: 'Event',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _runSearch(),
                ),
              ),
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _workspaceController,
                  decoration: const InputDecoration(
                    labelText: 'Workspace',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _runSearch(),
                ),
              ),
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _clientController,
                  decoration: const InputDecoration(
                    labelText: 'Client',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _runSearch(),
                ),
              ),
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _projectController,
                  decoration: const InputDecoration(
                    labelText: 'Project',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _runSearch(),
                ),
              ),
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _topicController,
                  decoration: const InputDecoration(
                    labelText: 'Topic',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _runSearch(),
                ),
              ),
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _sourceFolderController,
                  decoration: const InputDecoration(
                    labelText: 'Source folder',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _runSearch(),
                ),
              ),
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _deviceController,
                  decoration: const InputDecoration(
                    labelText: 'Device',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _runSearch(),
                ),
              ),
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _tagsController,
                  decoration: const InputDecoration(
                    labelText: 'Tags',
                    hintText: 'invoice, family',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _runSearch(),
                ),
              ),
              SizedBox(
                width: 170,
                child: TextField(
                  controller: _fromDateController,
                  decoration: const InputDecoration(
                    labelText: 'From',
                    hintText: 'YYYY-MM-DD',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _runSearch(),
                ),
              ),
              SizedBox(
                width: 170,
                child: TextField(
                  controller: _toDateController,
                  decoration: const InputDecoration(
                    labelText: 'To',
                    hintText: 'YYYY-MM-DD',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _runSearch(),
                ),
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
                label: const Text('Docs'),
                selected: _mediaKind == 'document',
                onSelected: (value) {
                  setState(() => _mediaKind = value ? 'document' : null);
                  _runSearch();
                },
              ),
              FilterChip(
                avatar: const Icon(Icons.audiotrack_outlined, size: 18),
                label: const Text('Audio'),
                selected: _mediaKind == 'audio',
                onSelected: (value) {
                  setState(() => _mediaKind = value ? 'audio' : null);
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
                avatar: const Icon(Icons.article_outlined, size: 18),
                label: const Text('Text'),
                selected: _mediaKind == 'text',
                onSelected: (value) {
                  setState(() => _mediaKind = value ? 'text' : null);
                  _runSearch();
                },
              ),
              FilterChip(
                avatar: const Icon(Icons.star_border, size: 18),
                label: const Text('Favorites'),
                selected: _favoritesOnly,
                onSelected: (value) {
                  setState(() => _favoritesOnly = value);
                  _runSearch();
                },
              ),
              FilterChip(
                avatar: const Icon(Icons.inventory_2_outlined, size: 18),
                label: const Text('Archived'),
                selected: _includeArchived,
                onSelected: (value) {
                  setState(() => _includeArchived = value);
                  _runSearch();
                },
              ),
              FilledButton.icon(
                onPressed: _runSearch,
                icon: const Icon(Icons.search),
                label: const Text('Find'),
              ),
              OutlinedButton.icon(
                onPressed: _lastSubmittedQuery == null || _savingSmartFolder
                    ? null
                    : _saveSmartFolder,
                icon: _savingSmartFolder
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.create_new_folder_outlined),
                label: const Text('Save smart folder'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Expanded(
            child: _searchFuture == null
                ? const SingleChildScrollView(
                    child: EmptyStatePanel(
                      icon: Icons.search_outlined,
                      title: 'Search your local library',
                      message:
                          'Enter a query to ask the local API for assets, people, places, and events. Empty results are expected when the library is new or indexing is still limited.',
                    ),
                  )
                : FutureBuilder<SearchResponse>(
                    future: _searchFuture,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (snapshot.hasError) {
                        return SingleChildScrollView(
                          child: EmptyStatePanel(
                            icon: Icons.error_outline,
                            title: 'Search failed',
                            message: '${snapshot.error}',
                          ),
                        );
                      }

                      final data = snapshot.data!;
                      if (data.isEmpty) {
                        return SingleChildScrollView(
                          child: EmptyStatePanel(
                            icon: Icons.manage_search_outlined,
                            title: 'No matches for "${_submittedQuery ?? ''}"',
                            message:
                                'The library is either empty or the current daemon has not produced searchable metadata for this query yet.',
                          ),
                        );
                      }

                      return ListView(
                        children: [
                          Text('Assets', style: theme.textTheme.titleLarge),
                          const SizedBox(height: 12),
                          AssetGrid(
                            assets: data.assets,
                            onAssetSelected: _showAssetDetails,
                          ),
                          const SizedBox(height: 24),
                          Text(
                            'People matches: ${data.people.length}',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            data.people.isEmpty
                                ? 'None'
                                : data.people
                                      .map((item) => item.displayName)
                                      .join(', '),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Places matches: ${data.places.length}',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            data.places.isEmpty
                                ? 'None'
                                : data.places
                                      .map((item) => item.label)
                                      .join(', '),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Event matches: ${data.events.length}',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            data.events.isEmpty
                                ? 'None'
                                : data.events
                                      .map((item) => item.title)
                                      .join(', '),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _SmartFolderStrip extends StatelessWidget {
  const _SmartFolderStrip({
    required this.folders,
    required this.loading,
    required this.error,
    required this.onOpen,
    required this.onDelete,
  });

  final List<SmartFolder> folders;
  final bool loading;
  final String? error;
  final ValueChanged<SmartFolder> onOpen;
  final ValueChanged<SmartFolder> onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.auto_awesome_motion_outlined, size: 18),
                const SizedBox(width: 8),
                Text('Smart folders', style: theme.textTheme.titleSmall),
                if (loading) ...[
                  const SizedBox(width: 10),
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
            if (error != null) ...[
              const SizedBox(height: 6),
              Text(error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            if (folders.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final folder in folders)
                    InputChip(
                      avatar: const Icon(Icons.folder_special_outlined),
                      label: Text(folder.title),
                      onPressed: () => onOpen(folder),
                      onDeleted: () => onDelete(folder),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
