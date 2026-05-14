import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/gallery_models.dart';
import '../../repositories/gallery_repository.dart';

class ImportScreen extends StatefulWidget {
  const ImportScreen({
    super.key,
    required this.repository,
    required this.defaultImportMode,
  });

  final GalleryRepository repository;
  final ImportMode defaultImportMode;

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  static const String _recommendedSourceRoot =
      '/mnt/windows/transfer/Ok/Photos/Unfiltered';
  static const String _recommendedVideoRoot = '/mnt/windows/transfer/Ok/video';
  static const String _recommendedAudioRoot = '/mnt/windows/transfer/Ok/Audio';

  late final TextEditingController _sourcePathController;
  late final TextEditingController _placeHintController;
  ImportMode _importMode = ImportMode.move;
  ImportSourceKind _importSource = ImportSourceKind.folder;
  bool _addAsWatchFolder = false;
  bool _recursive = true;
  bool _busy = false;
  bool _moveConfirmed = false;
  ImportSession? _session;
  ImportSession? _committedSession;
  List<ImportSession> _recentSessions = const [];
  Set<String> _selectedCandidateIds = <String>{};
  String? _error;

  @override
  void initState() {
    super.initState();
    _importMode = widget.defaultImportMode;
    _sourcePathController = TextEditingController(text: _recommendedSourceRoot);
    _placeHintController = TextEditingController();
    _loadRecentSessions();
  }

  @override
  void dispose() {
    _sourcePathController.dispose();
    _placeHintController.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final sourcePath = _sourcePathController.text.trim();
    if (sourcePath.isEmpty) {
      setState(() => _error = 'Enter a folder or removable-drive path first.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _committedSession = null;
      _moveConfirmed = false;
    });

    try {
      final session = await widget.repository.scanImport(
        ImportScanRequest(
          sourcePath: sourcePath,
          sourceKind: _importSource,
          importMode: _importMode,
          addAsWatchFolder: _addAsWatchFolder,
          placeHint: _placeHintController.text.trim().isEmpty
              ? null
              : _placeHintController.text.trim(),
          recursive: _recursive,
        ),
      );

      setState(() {
        _session = session;
        _selectedCandidateIds = session.candidates
            .where((candidate) => !candidate.isDuplicate && candidate.selected)
            .map((candidate) => candidate.id)
            .toSet();
        if (_selectedCandidateIds.isEmpty) {
          _selectedCandidateIds = session.candidates
              .where((candidate) => !candidate.isDuplicate)
              .map((candidate) => candidate.id)
              .toSet();
        }
      });
      await _loadRecentSessions();
    } catch (error) {
      setState(() => _error = '$error');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _commit() async {
    final session = _session;
    if (session == null) {
      return;
    }
    if (_selectedCandidateIds.isEmpty) {
      setState(() => _error = 'Choose at least one candidate to import.');
      return;
    }
    if (_selectedNonDuplicateCount(session) == 0) {
      setState(
        () => _error =
            'There are no selected non-duplicate files to move or import.',
      );
      return;
    }
    if (_importMode == ImportMode.move && !_moveConfirmed) {
      setState(
        () => _error =
            'Confirm the verified move safety statement before committing.',
      );
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final committed = await widget.repository.commitImport(
        ImportCommitRequest(
          sessionId: session.id,
          candidateIds: _selectedCandidateIds.toList(),
          importMode: _importMode,
        ),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _committedSession = committed;
        _session = committed;
        _selectedCandidateIds = committed.candidates
            .where((candidate) => candidate.selected && !candidate.isDuplicate)
            .map((candidate) => candidate.id)
            .toSet();
      });
      await _loadRecentSessions();
    } catch (error) {
      setState(() => _error = '$error');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _loadRecentSessions() async {
    try {
      final sessions = await widget.repository.fetchImportSessions();
      if (!mounted) {
        return;
      }
      setState(() => _recentSessions = sessions.take(8).toList());
    } catch (_) {
      // History is helpful but should never block scanning/importing.
    }
  }

  int _selectedNonDuplicateCount(ImportSession session) {
    return session.candidates
        .where(
          (candidate) =>
              _selectedCandidateIds.contains(candidate.id) &&
              !candidate.isDuplicate,
        )
        .length;
  }

  int _selectedBytes(ImportSession session) {
    return session.candidates
        .where(
          (candidate) =>
              _selectedCandidateIds.contains(candidate.id) &&
              !candidate.isDuplicate,
        )
        .fold<int>(0, (sum, candidate) => sum + candidate.bytes);
  }

  int _selectedSidecars(ImportSession session) {
    return session.candidates
        .where(
          (candidate) =>
              _selectedCandidateIds.contains(candidate.id) &&
              !candidate.isDuplicate,
        )
        .fold<int>(0, (sum, candidate) => sum + candidate.sidecarPaths.length);
  }

  void _applyPreset(_ImportPreset preset) {
    setState(() {
      _sourcePathController.text = preset.path;
      _placeHintController.text = preset.placeHint;
      _importMode = preset.importMode;
      _importSource = ImportSourceKind.folder;
      _addAsWatchFolder = preset.addAsWatchFolder;
      _recursive = true;
      _moveConfirmed = false;
      _session = null;
      _committedSession = null;
      _selectedCandidateIds = <String>{};
      _error = preset.disabledReason;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Import media'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'Preview and safely organize local media before committing changes.',
            style: theme.textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          Text(
            'Scan is read-only. Move mode verifies file hashes before the old path is removed, keeps matching JSON sidecars with media, and avoids creating a duplicate archive.',
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 16),
          _OrganizedArchivePanel(onSelect: _applyPreset),
          const SizedBox(height: 16),
          Card(
            color: theme.colorScheme.primaryContainer,
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  _SafetyPill(
                    icon: Icons.lock_outline,
                    label: 'Local only',
                  ),
                  _SafetyPill(
                    icon: Icons.cloud_off_outlined,
                    label: 'No cloud upload',
                  ),
                  _SafetyPill(
                    icon: Icons.rule_folder_outlined,
                    label: 'Sidecars kept with media',
                  ),
                  _SafetyPill(
                    icon: Icons.verified_outlined,
                    label: 'Hash verified move',
                  ),
                ],
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!),
              ),
            ),
          ],
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Scan source', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _sourcePathController,
                    decoration: const InputDecoration(
                      labelText: 'Source path',
                      hintText: _recommendedSourceRoot,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SegmentedButton<ImportSourceKind>(
                    segments: ImportSourceKind.values
                        .map(
                          (source) => ButtonSegment<ImportSourceKind>(
                            value: source,
                            label: Text(source.label),
                            icon: Icon(
                              source == ImportSourceKind.folder
                                  ? Icons.folder_outlined
                                  : Icons.usb_outlined,
                            ),
                          ),
                        )
                        .toList(),
                    selected: {_importSource},
                    onSelectionChanged: (selection) {
                      setState(() {
                        _importSource = selection.first;
                        if (_importSource == ImportSourceKind.removableDrive) {
                          _addAsWatchFolder = false;
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  SegmentedButton<ImportMode>(
                    segments: ImportMode.values
                        .map(
                          (mode) => ButtonSegment<ImportMode>(
                            value: mode,
                            label: Text(mode.label),
                          ),
                        )
                        .toList(),
                    selected: {_importMode},
                    onSelectionChanged: (selection) {
                      setState(() {
                        _importMode = selection.first;
                        _moveConfirmed = false;
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _placeHintController,
                    decoration: const InputDecoration(
                      labelText: 'Optional place hint',
                      hintText: 'Goa trip or Home archive',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: _addAsWatchFolder,
                    title: const Text('Add folder as watched source'),
                    subtitle: const Text(
                      'Keep this off for removable drives and one-off imports.',
                    ),
                    onChanged: _importSource == ImportSourceKind.removableDrive
                        ? null
                        : (value) {
                            setState(() => _addAsWatchFolder = value);
                          },
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: _recursive,
                    title: const Text('Scan subfolders'),
                    subtitle: const Text(
                      'Turn this off for a single flat import directory.',
                    ),
                    onChanged: (value) {
                      setState(() => _recursive = value);
                    },
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _busy ? null : _scan,
                    icon: _busy
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.travel_explore_outlined),
                    label: const Text('Scan source'),
                  ),
                ],
              ),
            ),
          ),
          if (_session != null) ...[
            const SizedBox(height: 24),
            _ImportPreflightPanel(
              session: _session!,
              selectedCandidateCount: _selectedNonDuplicateCount(_session!),
              selectedBytes: _selectedBytes(_session!),
              selectedSidecarCount: _selectedSidecars(_session!),
            ),
            if (_importMode == ImportMode.move) ...[
              const SizedBox(height: 12),
              CheckboxListTile(
                value: _moveConfirmed,
                onChanged: _selectedNonDuplicateCount(_session!) == 0 ||
                        _committedSession != null
                    ? null
                    : (value) {
                        setState(() => _moveConfirmed = value ?? false);
                      },
                title: const Text(
                  'I understand selected files will move into the managed library after hash verification.',
                ),
                subtitle: const Text(
                  'Source files are removed only after the destination hash matches.',
                ),
              ),
            ],
            if (_committedSession != null) ...[
              const SizedBox(height: 16),
              _CommitResultPanel(session: _committedSession!),
            ],
            const SizedBox(height: 24),
            _ImportSessionResults(
              session: _session!,
              selectedCandidateIds: _selectedCandidateIds,
              onToggleCandidate: (candidateId, selected) {
                setState(() {
                  if (selected) {
                    _selectedCandidateIds.add(candidateId);
                  } else {
                    _selectedCandidateIds.remove(candidateId);
                  }
                  _moveConfirmed = false;
                });
              },
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: _busy ||
                          _committedSession != null ||
                          _selectedNonDuplicateCount(_session!) == 0 ||
                          (_importMode == ImportMode.move && !_moveConfirmed)
                      ? null
                      : _commit,
                  icon: const Icon(Icons.file_download_done_outlined),
                  label: Text(
                    _importMode == ImportMode.move
                        ? 'Move verified files'
                        : 'Import ${_selectedNonDuplicateCount(_session!)} selected',
                  ),
                ),
                if (_committedSession != null)
                  FilledButton.tonalIcon(
                    onPressed: () {
                      Navigator.of(context).pop(_committedSession);
                    },
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('Done and refresh library'),
                  ),
                OutlinedButton.icon(
                  onPressed: _busy || _committedSession != null
                      ? null
                      : () {
                          setState(() {
                            _selectedCandidateIds = _session!.candidates
                                .where((candidate) => !candidate.isDuplicate)
                                .map((candidate) => candidate.id)
                                .toSet();
                            _moveConfirmed = false;
                          });
                        },
                  icon: const Icon(Icons.done_all_outlined),
                  label: const Text('Select non-duplicates'),
                ),
              ],
            ),
          ],
          if (_recentSessions.isNotEmpty) ...[
            const SizedBox(height: 24),
            _RecentImportSessions(
              sessions: _recentSessions,
              onOpen: (session) {
                setState(() {
                  _session = session;
                  _importMode = session.importMode;
                  _committedSession =
                      session.status == ImportSessionStatus.committed
                          ? session
                          : null;
                  _selectedCandidateIds = session.candidates
                      .where(
                        (candidate) =>
                            candidate.selected && !candidate.isDuplicate,
                      )
                      .map((candidate) => candidate.id)
                      .toSet();
                  _moveConfirmed =
                      session.status == ImportSessionStatus.committed;
                });
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _ImportPreset {
  const _ImportPreset({
    required this.title,
    required this.description,
    required this.path,
    required this.placeHint,
    required this.importMode,
    required this.addAsWatchFolder,
    this.disabledReason,
  });

  final String title;
  final String description;
  final String path;
  final String placeHint;
  final ImportMode importMode;
  final bool addAsWatchFolder;
  final String? disabledReason;

  bool get enabled => disabledReason == null;
}

class _OrganizedArchivePanel extends StatelessWidget {
  const _OrganizedArchivePanel({required this.onSelect});

  final void Function(_ImportPreset preset) onSelect;

  static const _presets = [
    _ImportPreset(
      title: 'Index organized photos',
      description:
          'Reference the cleaned Unfiltered photo library in place without moving it again.',
      path: _ImportScreenState._recommendedSourceRoot,
      placeHint: 'Local organized photos',
      importMode: ImportMode.reference,
      addAsWatchFolder: true,
    ),
    _ImportPreset(
      title: 'Index organized videos',
      description:
          'Reference the verified video folder separately, keeping video files under Ok/video.',
      path: _ImportScreenState._recommendedVideoRoot,
      placeHint: 'Local organized videos',
      importMode: ImportMode.reference,
      addAsWatchFolder: true,
    ),
    _ImportPreset(
      title: 'Audio stays separate',
      description:
          'Audio was organized under Ok/Audio, but this gallery indexes photos and videos only.',
      path: _ImportScreenState._recommendedAudioRoot,
      placeHint: 'Local organized audio',
      importMode: ImportMode.reference,
      addAsWatchFolder: false,
      disabledReason:
          'Audio import is intentionally outside this Google Photos-like gallery slice.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      color: theme.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Index your organized archive',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Use these presets after local cleanup. They reference files in place, so the app can build timeline/search metadata without duplicating or moving the cleaned folders.',
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final preset in _presets)
                  Tooltip(
                    message: preset.description,
                    child: FilledButton.tonalIcon(
                      onPressed: preset.enabled ? () => onSelect(preset) : null,
                      icon: Icon(
                        preset.path == _ImportScreenState._recommendedVideoRoot
                            ? Icons.video_library_outlined
                            : preset.path ==
                                    _ImportScreenState._recommendedAudioRoot
                                ? Icons.audio_file_outlined
                                : Icons.photo_library_outlined,
                      ),
                      label: Text(preset.title),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ImportPreflightPanel extends StatelessWidget {
  const _ImportPreflightPanel({
    required this.session,
    required this.selectedCandidateCount,
    required this.selectedBytes,
    required this.selectedSidecarCount,
  });

  final ImportSession session;
  final int selectedCandidateCount;
  final int selectedBytes;
  final int selectedSidecarCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warnings = <String>[
      if (session.sourceContainsManagedLibrary)
        'The managed library is inside the source folder and will be excluded from recursive scans.',
      if (session.selectedOutsideSourceCount > 0)
        '${session.selectedOutsideSourceCount} selected files are outside the chosen source root.',
      if (selectedCandidateCount == 0)
        'Nothing will be moved: selected items are duplicates, unsupported, or empty.',
    ];

    return Card(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              session.importMode == ImportMode.move
                  ? 'Preflight before moving'
                  : 'Preflight before importing',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Scan is read-only. Commit is the only step that changes files.',
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _PreflightChip(
                  label: '$selectedCandidateCount selected media',
                ),
                _PreflightChip(
                  label: '${session.duplicateCount} duplicates skipped',
                ),
                _PreflightChip(
                  label: '${session.unsupportedCount} unsupported ignored',
                ),
                _PreflightChip(
                  label: '$selectedSidecarCount sidecars attached',
                ),
                _PreflightChip(label: '${_formatBytes(selectedBytes)} total'),
              ],
            ),
            if (session.destinationRoot != null) ...[
              const SizedBox(height: 12),
              Text(
                'Destination root: ${session.destinationRoot}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (session.importMode == ImportMode.move) ...[
              const SizedBox(height: 12),
              const Text(
                'Move safety: source files are removed only after the destination hash is verified.',
              ),
            ],
            if (warnings.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final warning in warnings)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.warning_amber_outlined, size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: Text(warning)),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PreflightChip extends StatelessWidget {
  const _PreflightChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(label: Text(label));
  }
}

class _CommitResultPanel extends StatelessWidget {
  const _CommitResultPanel({required this.session});

  final ImportSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failedCount = session.failedCandidateIds.length;

    return Card(
      color: failedCount == 0
          ? theme.colorScheme.primaryContainer
          : theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Import result', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              '${session.importedAssetIds.length} imported • ${session.movedAssetIds.length} moved • ${session.skippedDuplicateIds.length} duplicates skipped • $failedCount failed • ${session.sidecarsMoved} sidecars moved',
            ),
            if (failedCount > 0) ...[
              const SizedBox(height: 8),
              const Text(
                'Some files stayed in the source folder. Review failed candidates below before retrying.',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RecentImportSessions extends StatelessWidget {
  const _RecentImportSessions({
    required this.sessions,
    required this.onOpen,
  });

  final List<ImportSession> sessions;
  final void Function(ImportSession session) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final formatter = DateFormat.yMMMd().add_jm();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Recent imports', style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            for (final session in sessions)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(session.sourcePath),
                subtitle: Text(
                  [
                    session.status.label,
                    session.importMode.label,
                    '${session.importedAssetIds.length} imported',
                    '${session.movedAssetIds.length} moved',
                    '${session.skippedDuplicateIds.length} skipped',
                    '${session.failedCandidateIds.length} failed',
                    '${session.sidecarsMoved} sidecars',
                    '${session.unsupportedCount} unsupported',
                    formatter.format(session.createdAt.toLocal()),
                  ].join(' • '),
                ),
                trailing: TextButton(
                  onPressed: () => onOpen(session),
                  child: const Text('Open'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ImportSessionResults extends StatelessWidget {
  const _ImportSessionResults({
    required this.session,
    required this.selectedCandidateIds,
    required this.onToggleCandidate,
  });

  final ImportSession session;
  final Set<String> selectedCandidateIds;
  final void Function(String candidateId, bool selected) onToggleCandidate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final formatter = DateFormat.yMMMd();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Scan results', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              '${session.candidates.length} candidates • ${session.duplicateCount} duplicates flagged • ${session.sidecarCount} sidecars attached • ${session.unsupportedFilePaths.length} unsupported ignored • ${_formatBytes(session.selectedBytes)} selected',
            ),
            if (session.unsupportedFilePaths.isNotEmpty) ...[
              const SizedBox(height: 12),
              _ImportWarningPanel(
                unsupportedPaths: session.unsupportedFilePaths,
              ),
            ],
            if (session.placeHint != null && session.placeHint!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Place hint: ${session.placeHint}'),
            ],
            const SizedBox(height: 20),
            for (final candidate in session.candidates)
              CheckboxListTile(
                value: selectedCandidateIds.contains(candidate.id),
                onChanged: candidate.isDuplicate
                    ? null
                    : (selected) {
                        onToggleCandidate(candidate.id, selected ?? false);
                      },
                contentPadding: EdgeInsets.zero,
                title: Text(candidate.originalFilename),
                subtitle: Text(
                  [
                    candidate.sourcePath,
                    if (candidate.destinationPath != null)
                      'To ${candidate.destinationPath}',
                    if (candidate.placeHint != null) candidate.placeHint!,
                    if (candidate.capturedAt != null)
                      formatter.format(candidate.capturedAt!),
                    candidate.mimeType,
                    '${candidate.sidecarPaths.length} sidecars',
                    candidate.safetyStatus.replaceAll('_', ' '),
                    candidate.isDuplicate
                        ? 'Duplicate detected'
                        : 'Ready to import',
                  ].join(' • '),
                ),
                secondary: Icon(
                  candidate.mediaKind == 'video'
                      ? Icons.videocam_outlined
                      : Icons.image_outlined,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ImportWarningPanel extends StatelessWidget {
  const _ImportWarningPanel({required this.unsupportedPaths});

  final List<String> unsupportedPaths;

  @override
  Widget build(BuildContext context) {
    final shownPaths = unsupportedPaths.take(4).toList();
    final hiddenCount = unsupportedPaths.length - shownPaths.length;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Unsupported files ignored',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            const Text(
              'These files are not photos/videos and will not be moved. JSON sidecars that match media are handled separately.',
            ),
            const SizedBox(height: 8),
            for (final path in shownPaths)
              Text(
                path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            if (hiddenCount > 0) Text('+$hiddenCount more ignored files'),
          ],
        ),
      ),
    );
  }
}

class _SafetyPill extends StatelessWidget {
  const _SafetyPill({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 6),
        Text(label),
      ],
    );
  }
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
