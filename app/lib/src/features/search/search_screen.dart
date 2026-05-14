import 'package:flutter/material.dart';

import '../../models/gallery_models.dart';
import '../../repositories/gallery_repository.dart';
import '../../widgets/asset_grid.dart';
import '../../widgets/empty_state_panel.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    required this.repository,
  });

  final GalleryRepository repository;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  static const int _safeOcrBatchLimit = 10;

  final TextEditingController _controller = TextEditingController();
  Future<SearchResponse>? _searchFuture;
  late Future<SearchIndexStatus?> _statusFuture;
  String? _submittedQuery;
  JobRecord? _lastOcrJob;
  JobRecord? _lastSceneJob;
  String? _ocrError;
  String? _sceneError;
  bool _ocrRunning = false;
  bool _sceneRunning = false;

  @override
  void initState() {
    super.initState();
    _statusFuture = widget.repository.fetchSearchStatus();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _runSearch() {
    final query = _controller.text.trim();
    if (query.isEmpty) {
      setState(() {
        _submittedQuery = null;
        _searchFuture = null;
      });
      return;
    }

    setState(() {
      _submittedQuery = query;
      _searchFuture = widget.repository.search(query);
    });
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
      final job =
          await widget.repository.rebuildScenes(limit: _safeOcrBatchLimit);
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
          Text(
            'Search stays honest in this slice: if the daemon has not indexed anything yet, you will see empty results instead of demo matches.',
            style: theme.textTheme.bodyLarge,
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
                            const Text(
                              'Uses local Tesseract only, skips already-indexed photos, and never uploads media.',
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
                                      Icons.auto_awesome_mosaic_outlined),
                              label: Text(
                                _sceneRunning
                                    ? 'Indexing scenes locally...'
                                    : 'Index next $_safeOcrBatchLimit scene tags',
                              ),
                            ),
                            const Text(
                              'Uses local heuristic image analysis only. No cloud labels, no model download.',
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
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  decoration: const InputDecoration(
                    hintText: 'Try “Goa”, “family dinner”, or a filename',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _runSearch(),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _runSearch,
                icon: const Icon(Icons.search),
                label: const Text('Find'),
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
                          Text(
                            'Assets',
                            style: theme.textTheme.titleLarge,
                          ),
                          const SizedBox(height: 12),
                          AssetGrid(assets: data.assets),
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
