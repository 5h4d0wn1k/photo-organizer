import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/gallery_models.dart';
import '../../widgets/empty_state_panel.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.workspace,
    required this.onActivateEncryption,
    required this.onImportLocalModel,
    required this.onVerifyModel,
    required this.onVerifyBackup,
    required this.onExportBackup,
    required this.onPlanRestoreBackup,
    required this.onRunRestoreBackup,
    required this.onSaveSettings,
    required this.onAddWatchFolder,
    required this.onDeleteWatchFolder,
    required this.onOpenImport,
  });

  final WorkspaceSnapshot workspace;
  final Future<void> Function() onActivateEncryption;
  final Future<ModelArtifact> Function({
    required String id,
    required String localPath,
    String? expectedSha256,
    required bool confirmed,
  }) onImportLocalModel;
  final Future<ModelArtifact> Function(String id) onVerifyModel;
  final Future<BackupVerification> Function({String? exportRoot})
      onVerifyBackup;
  final Future<BackupExportResult> Function({
    required String exportRoot,
    bool includeModels,
  }) onExportBackup;
  final Future<BackupRestorePlan> Function({
    required String exportRoot,
    required String restoreRoot,
  }) onPlanRestoreBackup;
  final Future<BackupRestoreRunResult> Function({
    required String exportRoot,
    required String restoreRoot,
    bool confirmed,
  }) onRunRestoreBackup;
  final Future<void> Function(LibrarySettingsDraft draft) onSaveSettings;
  final Future<void> Function(WatchFolderDraft draft) onAddWatchFolder;
  final Future<void> Function(String id) onDeleteWatchFolder;
  final VoidCallback onOpenImport;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _libraryRootController;
  late final TextEditingController _watchFolderController;
  late final TextEditingController _backupRootController;
  late final TextEditingController _restoreRootController;
  late final TextEditingController _modelIdController;
  late final TextEditingController _modelPathController;
  late final TextEditingController _modelHashController;
  late ImportMode _defaultImportMode;
  bool _watchRecursive = true;
  bool _savingSettings = false;
  bool _savingWatchFolder = false;
  bool _activatingEncryption = false;
  bool _importingModel = false;
  bool _verifyingModel = false;
  bool _verifyingBackup = false;
  bool _exportingBackup = false;
  bool _planningRestore = false;
  bool _runningRestore = false;
  BackupVerification? _backupVerification;
  BackupExportResult? _backupExport;
  BackupRestorePlan? _restorePlan;
  BackupRestoreRunResult? _restoreRun;
  ModelArtifact? _modelActionResult;

  @override
  void initState() {
    super.initState();
    _libraryRootController = TextEditingController(
      text: widget.workspace.settings.libraryRoot,
    );
    _watchFolderController = TextEditingController();
    _backupRootController = TextEditingController(
      text: '${widget.workspace.settings.libraryRoot}/backups',
    );
    _restoreRootController = TextEditingController(
      text: '${widget.workspace.settings.libraryRoot}-restore-stage',
    );
    _modelIdController = TextEditingController(
      text: _firstModelId(widget.workspace.dashboard.models),
    );
    _modelPathController = TextEditingController();
    _modelHashController = TextEditingController();
    _defaultImportMode = widget.workspace.settings.defaultImportMode;
  }

  @override
  void dispose() {
    _libraryRootController.dispose();
    _watchFolderController.dispose();
    _backupRootController.dispose();
    _restoreRootController.dispose();
    _modelIdController.dispose();
    _modelPathController.dispose();
    _modelHashController.dispose();
    super.dispose();
  }

  Future<void> _saveSettings() async {
    setState(() => _savingSettings = true);
    try {
      await widget.onSaveSettings(
        LibrarySettingsDraft(
          libraryRoot: _libraryRootController.text.trim(),
          defaultImportMode: _defaultImportMode,
        ),
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Library settings saved.')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error')),
      );
    } finally {
      if (mounted) {
        setState(() => _savingSettings = false);
      }
    }
  }

  Future<void> _addWatchFolder() async {
    final path = _watchFolderController.text.trim();
    if (path.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a watch-folder path first.')),
      );
      return;
    }

    setState(() => _savingWatchFolder = true);
    try {
      await widget.onAddWatchFolder(
        WatchFolderDraft(
          path: path,
          recursive: _watchRecursive,
          importMode: _defaultImportMode,
        ),
      );
      if (!mounted) {
        return;
      }
      _watchFolderController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Watch folder added.')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error')),
      );
    } finally {
      if (mounted) {
        setState(() => _savingWatchFolder = false);
      }
    }
  }

  Future<void> _activateEncryption() async {
    setState(() => _activatingEncryption = true);
    try {
      await widget.onActivateEncryption();
    } finally {
      if (mounted) {
        setState(() => _activatingEncryption = false);
      }
    }
  }

  Future<void> _importLocalModel() async {
    final id = _modelIdController.text.trim();
    final localPath = _modelPathController.text.trim();
    final expectedHash = _modelHashController.text.trim();
    if (id.isEmpty || localPath.isEmpty || expectedHash.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter model id, local path, and expected SHA-256.'),
        ),
      );
      return;
    }

    setState(() => _importingModel = true);
    try {
      final result = await widget.onImportLocalModel(
        id: id,
        localPath: localPath,
        expectedSha256: expectedHash,
        confirmed: true,
      );
      if (!mounted) {
        return;
      }
      setState(() => _modelActionResult = result);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Model ${result.id} imported locally.')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error')),
      );
    } finally {
      if (mounted) {
        setState(() => _importingModel = false);
      }
    }
  }

  Future<void> _verifyModel() async {
    final id = _modelIdController.text.trim();
    if (id.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a model id first.')),
      );
      return;
    }

    setState(() => _verifyingModel = true);
    try {
      final result = await widget.onVerifyModel(id);
      if (!mounted) {
        return;
      }
      setState(() => _modelActionResult = result);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Model ${result.id} verified.')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error')),
      );
    } finally {
      if (mounted) {
        setState(() => _verifyingModel = false);
      }
    }
  }

  Future<void> _verifyBackup() async {
    setState(() => _verifyingBackup = true);
    try {
      final result = await widget.onVerifyBackup(
        exportRoot: _backupRootController.text.trim().isEmpty
            ? null
            : _backupRootController.text.trim(),
      );
      if (!mounted) {
        return;
      }
      setState(() => _backupVerification = result);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.ok
              ? 'Backup verification passed.'
              : 'Backup verification found missing files.'),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error')),
      );
    } finally {
      if (mounted) {
        setState(() => _verifyingBackup = false);
      }
    }
  }

  Future<void> _exportBackup() async {
    final exportRoot = _backupRootController.text.trim();
    if (exportRoot.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a backup export path first.')),
      );
      return;
    }

    setState(() => _exportingBackup = true);
    try {
      final result = await widget.onExportBackup(exportRoot: exportRoot);
      if (!mounted) {
        return;
      }
      setState(() => _backupExport = result);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.ok
              ? 'Backup manifest exported.'
              : 'Backup exported with missing file warnings.'),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error')),
      );
    } finally {
      if (mounted) {
        setState(() => _exportingBackup = false);
      }
    }
  }

  Future<void> _planRestoreBackup() async {
    final exportRoot = _backupRootController.text.trim();
    final restoreRoot = _restoreRootController.text.trim();
    if (exportRoot.isEmpty || restoreRoot.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter backup and restore paths first.')),
      );
      return;
    }

    setState(() => _planningRestore = true);
    try {
      final result = await widget.onPlanRestoreBackup(
        exportRoot: exportRoot,
        restoreRoot: restoreRoot,
      );
      if (!mounted) {
        return;
      }
      setState(() => _restorePlan = result);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.ok
              ? 'Restore plan is ready.'
              : 'Restore plan found blockers.'),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error')),
      );
    } finally {
      if (mounted) {
        setState(() => _planningRestore = false);
      }
    }
  }

  Future<void> _runRestoreBackup() async {
    final exportRoot = _backupRootController.text.trim();
    final restoreRoot = _restoreRootController.text.trim();
    if (exportRoot.isEmpty || restoreRoot.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter backup and restore paths first.')),
      );
      return;
    }

    setState(() => _runningRestore = true);
    try {
      final result = await widget.onRunRestoreBackup(
        exportRoot: exportRoot,
        restoreRoot: restoreRoot,
        confirmed: true,
      );
      if (!mounted) {
        return;
      }
      setState(() => _restoreRun = result);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.ok
              ? 'Restore staged for review.'
              : 'Restore finished with warnings.'),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error')),
      );
    } finally {
      if (mounted) {
        setState(() => _runningRestore = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final watchFolders = widget.workspace.watchFolders;
    final settings = widget.workspace.settings;
    final privacyStatus = widget.workspace.privacyStatus;
    final models = widget.workspace.dashboard.models;
    final runtimeStatus = widget.workspace.dashboard.modelRuntimeStatus;
    final formatter = DateFormat.yMMMd().add_jm();

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Library settings', style: theme.textTheme.titleLarge),
                const SizedBox(height: 16),
                TextField(
                  controller: _libraryRootController,
                  decoration: const InputDecoration(
                    labelText: 'Library root',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<ImportMode>(
                  initialValue: _defaultImportMode,
                  decoration: const InputDecoration(
                    labelText: 'Default import mode',
                    border: OutlineInputBorder(),
                  ),
                  items: ImportMode.values
                      .map(
                        (mode) => DropdownMenuItem<ImportMode>(
                          value: mode,
                          child: Text(mode.label),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }
                    setState(() => _defaultImportMode = value);
                  },
                ),
                const SizedBox(height: 12),
                Text(
                  'Initialized: ${settings.initializedAt == null ? 'Unknown' : formatter.format(settings.initializedAt!)}',
                ),
                Text(
                  'Updated: ${settings.updatedAt == null ? 'Unknown' : formatter.format(settings.updatedAt!)}',
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _savingSettings ? null : _saveSettings,
                  icon: _savingSettings
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: const Text('Save settings'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Backup and restore readiness',
                    style: theme.textTheme.titleLarge),
                const SizedBox(height: 12),
                const Text(
                  'This verifies the encrypted database, managed originals, encrypted vault chunks, and installed model files. Export writes a restorable local backup; restore stages into a separate folder without modifying the active library.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _backupRootController,
                  decoration: const InputDecoration(
                    labelText: 'Backup export path',
                    border: OutlineInputBorder(),
                    helperText:
                        'Prefer an external disk or NAS path for real backups.',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _restoreRootController,
                  decoration: const InputDecoration(
                    labelText: 'Restore staging path',
                    border: OutlineInputBorder(),
                    helperText:
                        'Use an empty folder outside the active library/runtime.',
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _verifyingBackup ? null : _verifyBackup,
                      icon: _verifyingBackup
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.fact_check_outlined),
                      label: const Text('Verify backup readiness'),
                    ),
                    FilledButton.icon(
                      onPressed: _exportingBackup ? null : _exportBackup,
                      icon: _exportingBackup
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.backup_outlined),
                      label: const Text('Export restorable backup'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _planningRestore ? null : _planRestoreBackup,
                      icon: _planningRestore
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.manage_search_outlined),
                      label: const Text('Plan restore'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _runningRestore ||
                              (_restorePlan != null && !_restorePlan!.ok)
                          ? null
                          : _runRestoreBackup,
                      icon: _runningRestore
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.restore_page_outlined),
                      label: const Text('Stage restore'),
                    ),
                  ],
                ),
                if (_backupVerification != null) ...[
                  const SizedBox(height: 16),
                  _BackupVerificationPanel(result: _backupVerification!),
                ],
                if (_backupExport != null) ...[
                  const SizedBox(height: 16),
                  _BackupExportPanel(result: _backupExport!),
                ],
                if (_restorePlan != null) ...[
                  const SizedBox(height: 16),
                  _BackupRestorePlanPanel(result: _restorePlan!),
                ],
                if (_restoreRun != null) ...[
                  const SizedBox(height: 16),
                  _BackupRestoreRunPanel(result: _restoreRun!),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Watch folders', style: theme.textTheme.titleLarge),
                const SizedBox(height: 12),
                if (watchFolders.isEmpty)
                  const EmptyStatePanel(
                    icon: Icons.folder_copy_outlined,
                    title: 'No watch folders yet',
                    message:
                        'The library can still import one-off folders and removable drives. Add stable desktop folders here when you want the daemon to remember them.',
                  )
                else
                  for (final folder in watchFolders)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(folder.path),
                      subtitle: Text(
                        [
                          folder.recursive ? 'Recursive' : 'Flat',
                          folder.importMode.label,
                          if (folder.lastScannedAt != null)
                            'Last scanned ${formatter.format(folder.lastScannedAt!)}',
                        ].join(' • '),
                      ),
                      trailing: IconButton(
                        onPressed: () => widget.onDeleteWatchFolder(folder.id),
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Remove watch folder',
                      ),
                    ),
                const SizedBox(height: 16),
                TextField(
                  controller: _watchFolderController,
                  decoration: const InputDecoration(
                    labelText: 'Add watch folder path',
                    border: OutlineInputBorder(),
                  ),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _watchRecursive,
                  title: const Text('Scan subfolders'),
                  onChanged: (value) {
                    setState(() => _watchRecursive = value);
                  },
                ),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton.icon(
                      onPressed: _savingWatchFolder ? null : _addWatchFolder,
                      icon: const Icon(Icons.add_circle_outline),
                      label: const Text('Add watch folder'),
                    ),
                    OutlinedButton.icon(
                      onPressed: widget.onOpenImport,
                      icon: const Icon(Icons.file_open_outlined),
                      label: const Text('Import one-off source'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Local-only privacy status',
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                if (privacyStatus == null)
                  const EmptyStatePanel(
                    icon: Icons.shield_outlined,
                    title: 'Privacy status unavailable',
                    message:
                        'The daemon may be older than this client. The app still uses the loopback API endpoint by default.',
                  )
                else ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      privacyStatus.localOnlyHealthy
                          ? Icons.verified_user_outlined
                          : Icons.warning_amber_outlined,
                    ),
                    title: Text(
                      privacyStatus.localOnlyHealthy
                          ? 'Local-only processing is enforced'
                          : 'Review privacy configuration',
                    ),
                    subtitle: Text(
                      '${privacyStatus.localOnlyDisclosure}\nDaemon: ${privacyStatus.daemonBindAddress} • Policy: ${privacyStatus.networkPolicy.label}',
                    ),
                  ),
                  const Divider(),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.cloud_off_outlined),
                    title: const Text('No cloud AI, analytics, or telemetry'),
                    subtitle: Text(
                      'Cloud AI: ${privacyStatus.cloudAiEnabled ? 'enabled' : 'off'} • Analytics: ${privacyStatus.analyticsEnabled ? 'enabled' : 'off'} • Telemetry: ${privacyStatus.telemetryEnabled ? 'enabled' : 'off'}',
                    ),
                  ),
                  const Divider(),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.lan_outlined),
                    title: const Text('Indexing jobs cannot use network'),
                    subtitle: Text(
                      privacyStatus.photoProcessingNetworkAllowed
                          ? 'Warning: photo processing network access is enabled.'
                          : 'Metadata, places, events, search, OCR, scenes, and faces are designed to run from local files only.',
                    ),
                  ),
                  const Divider(),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.download_for_offline_outlined),
                    title: const Text('Model downloads require confirmation'),
                    subtitle: Text(
                      privacyStatus.modelDownloadRequiresConfirmation
                          ? 'Future download actions must show the exact URL. Photos are never uploaded.'
                          : 'Warning: model downloads are not confirmation-gated.',
                    ),
                  ),
                  const Divider(),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.lock_outline),
                    title: Text(
                      privacyStatus.encryption.sensitiveIndexingAllowed
                          ? 'Encryption active'
                          : 'Encryption gate before faces/OCR',
                    ),
                    subtitle: Text(
                      privacyStatus.encryption.sensitiveIndexingAllowed
                          ? 'Sensitive indexing is allowed by the local encryption policy.'
                          : privacyStatus.encryption.warning,
                    ),
                  ),
                  if (!privacyStatus.encryption.sensitiveIndexingAllowed) ...[
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed:
                          _activatingEncryption ? null : _activateEncryption,
                      icon: _activatingEncryption
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.enhanced_encryption_outlined),
                      label: const Text('Activate encrypted database'),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Model governance', style: theme.textTheme.titleLarge),
                const SizedBox(height: 12),
                const Text(
                  'Manual import is the preferred path for private beta: download/review a model yourself, paste its exact SHA-256, and the daemon installs it only after local hash verification. This never scans or uploads photos.',
                ),
                const SizedBox(height: 16),
                if (runtimeStatus == null)
                  const EmptyStatePanel(
                    icon: Icons.memory_outlined,
                    title: 'ML runtime status unavailable',
                    message:
                        'The daemon did not return Python sidecar status. Faces, scenes, and semantic search remain blocked.',
                  )
                else
                  _ModelRuntimePanel(status: runtimeStatus),
                const SizedBox(height: 16),
                TextField(
                  controller: _modelIdController,
                  decoration: const InputDecoration(
                    labelText: 'Model id',
                    border: OutlineInputBorder(),
                    helperText:
                        'Example: scrfd-face-detector, arcface-embedding, scene-classifier-onnx',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _modelPathController,
                  decoration: const InputDecoration(
                    labelText: 'Local model file path',
                    border: OutlineInputBorder(),
                    helperText:
                        'Use a reviewed local file only. The app verifies the hash before install.',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _modelHashController,
                  decoration: const InputDecoration(
                    labelText: 'Expected SHA-256',
                    border: OutlineInputBorder(),
                    helperText:
                        'Required. Wrong hashes are rejected and the model is not installed.',
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton.icon(
                      onPressed: _importingModel ? null : _importLocalModel,
                      icon: _importingModel
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.inventory_2_outlined),
                      label: const Text('Import local model'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _verifyingModel ? null : _verifyModel,
                      icon: _verifyingModel
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.verified_outlined),
                      label: const Text('Verify installed model'),
                    ),
                  ],
                ),
                if (_modelActionResult != null) ...[
                  const SizedBox(height: 16),
                  _ModelResultPanel(model: _modelActionResult!),
                ],
                const SizedBox(height: 20),
                if (models.isEmpty)
                  const EmptyStatePanel(
                    icon: Icons.model_training_outlined,
                    title: 'No approved local models installed',
                    message:
                        'Faces, scenes, and semantic search stay unavailable until reviewed models are installed. OCR can use the local Tesseract CLI after encryption is active.',
                  )
                else
                  for (final model in models)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        model.installed
                            ? Icons.check_circle_outline
                            : Icons.pending_actions_outlined,
                      ),
                      title: Text(model.name),
                      subtitle: Text(
                        [
                          model.task.label,
                          model.installStatus.label,
                          model.license ?? 'License not reviewed',
                          model.expectedSha256 == null
                              ? 'No pinned hash yet'
                              : 'Pinned hash present',
                          if (model.sourceUrl != null)
                            'Source: ${model.sourceUrl}',
                          if (model.reviewNotes.isNotEmpty) model.reviewNotes,
                        ].join('\n'),
                      ),
                    ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.shield_outlined),
                  title: Text('On-device ML only'),
                  subtitle: Text(
                    'Face matching, OCR, search, and event grouping stay local in v1.',
                  ),
                ),
                Divider(),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.fingerprint_outlined),
                  title: Text('People feature reset'),
                  subtitle: Text(
                    'Biometric artifacts should remain deletable at the daemon layer and never leak into a mock fallback.',
                  ),
                ),
                Divider(),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.location_disabled_outlined),
                  title: Text('Location scope'),
                  subtitle: Text(
                    'Use EXIF and user corrections first. No background location collection.',
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _BackupVerificationPanel extends StatelessWidget {
  const _BackupVerificationPanel({required this.result});

  final BackupVerification result;

  @override
  Widget build(BuildContext context) {
    return _BackupResultCard(
      ok: result.ok,
      title: result.ok ? 'Backup readiness verified' : 'Backup warnings found',
      lines: [
        'Database: ${result.databasePath}',
        'Library: ${result.libraryRoot}',
        'Assets checked: ${result.assetsChecked}',
        'Missing assets: ${result.missingAssetPaths.length}',
        'Encrypted vault chunks checked: ${result.vaultChunksChecked}',
        'Missing encrypted chunks: ${result.missingVaultChunkPaths.length}',
        'Model files checked: ${result.modelFilesChecked}',
        'Missing model files: ${result.missingModelPaths.length}',
        if (result.databaseSha256 != null)
          'Database SHA-256: ${result.databaseSha256}',
        ...result.missingAssetPaths
            .take(5)
            .map((path) => 'Missing asset: $path'),
        ...result.missingVaultChunkPaths
            .take(5)
            .map((path) => 'Missing encrypted chunk: $path'),
        ...result.missingModelPaths
            .take(5)
            .map((path) => 'Missing model: $path'),
      ],
    );
  }
}

class _ModelResultPanel extends StatelessWidget {
  const _ModelResultPanel({required this.model});

  final ModelArtifact model;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(
          color: model.installed ? colorScheme.primary : colorScheme.error,
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  model.installed
                      ? Icons.verified_outlined
                      : Icons.warning_amber_outlined,
                  color:
                      model.installed ? colorScheme.primary : colorScheme.error,
                ),
                const SizedBox(width: 8),
                Text(model.name,
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 10),
            SelectableText('Model id: ${model.id}'),
            Text('Task: ${model.task.label}'),
            Text('Status: ${model.installStatus.label}'),
            Text(
              'Approved for personal/family use: ${model.approvedForPersonalFamilyUse ? 'yes' : 'no'}',
            ),
            if (model.installedPath != null)
              SelectableText('Installed path: ${model.installedPath}'),
            if (model.installedSha256 != null)
              SelectableText('Installed SHA-256: ${model.installedSha256}'),
            if (!model.approvedForPersonalFamilyUse)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Installed files alone do not unlock faces/scenes. The model still needs license/hash approval in the registry.',
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ModelRuntimePanel extends StatelessWidget {
  const _ModelRuntimePanel({required this.status});

  final ModelRuntimeStatus status;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(
          color: status.ok && status.offlineReady
              ? colorScheme.primary
              : colorScheme.error,
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  status.ok && status.offlineReady
                      ? Icons.memory_outlined
                      : Icons.warning_amber_outlined,
                  color: status.ok && status.offlineReady
                      ? colorScheme.primary
                      : colorScheme.error,
                ),
                const SizedBox(width: 8),
                Text(
                  'Python ML sidecar',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(status.detail),
            const SizedBox(height: 8),
            SelectableText(
              [
                'Runtime: ${status.runtime}',
                'Python: ${status.pythonVersion ?? 'unknown'}',
                'Executable: ${status.pythonExecutable}',
                'Sidecar: ${status.sidecarPath ?? 'not found'}',
                'Offline guards: ${status.offlineReady ? 'active' : 'not confirmed'}',
              ].join('\n'),
            ),
            if (status.dependencies.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Optional ML dependencies',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              for (final dependency in status.dependencies)
                Text(
                  '${dependency.name}: ${dependency.available ? 'available' : 'missing'}${dependency.version == null ? '' : ' ${dependency.version}'}',
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _BackupExportPanel extends StatelessWidget {
  const _BackupExportPanel({required this.result});

  final BackupExportResult result;

  @override
  Widget build(BuildContext context) {
    return _BackupResultCard(
      ok: result.ok,
      title:
          result.ok ? 'Backup export written' : 'Backup exported with warnings',
      lines: [
        'Export root: ${result.exportRoot}',
        'Manifest: ${result.manifestPath}',
        'Database copy: ${result.databaseCopiedTo}',
        'Assets checked: ${result.assetsChecked}',
        'Media files copied: ${result.mediaFilesCopied}',
        'Encrypted vault chunks copied: ${result.vaultChunksCopied}',
        'Bytes copied: ${result.bytesCopied}',
        'Missing assets: ${result.missingAssetPaths.length}',
        'Model files checked: ${result.modelFilesChecked}',
        'Missing model files: ${result.missingModelPaths.length}',
        if (result.databaseSha256 != null)
          'Database SHA-256: ${result.databaseSha256}',
      ],
    );
  }
}

class _BackupRestorePlanPanel extends StatelessWidget {
  const _BackupRestorePlanPanel({required this.result});

  final BackupRestorePlan result;

  @override
  Widget build(BuildContext context) {
    return _BackupResultCard(
      ok: result.ok,
      title: result.ok ? 'Restore plan ready' : 'Restore plan blocked',
      lines: [
        result.detail,
        'Export root: ${result.exportRoot}',
        'Restore root: ${result.restoreRoot}',
        'Manifest: ${result.manifestPath}',
        'Database source: ${result.databaseSourcePath}',
        'Database target: ${result.databaseTargetPath}',
        'Media files available: ${result.mediaFilesAvailable}',
        'Encrypted vault chunks available: ${result.vaultChunksAvailable}',
        'Missing paths: ${result.missingPaths.length}',
        'Destination conflicts: ${result.destinationConflicts.length}',
        ...result.missingPaths.take(5).map((path) => 'Missing: $path'),
        ...result.destinationConflicts.take(5).map((path) => 'Conflict: $path'),
      ],
    );
  }
}

class _BackupRestoreRunPanel extends StatelessWidget {
  const _BackupRestoreRunPanel({required this.result});

  final BackupRestoreRunResult result;

  @override
  Widget build(BuildContext context) {
    return _BackupResultCard(
      ok: result.ok,
      title: result.ok ? 'Restore staged' : 'Restore warnings found',
      lines: [
        result.detail,
        'Restore root: ${result.restoreRoot}',
        'Database restored to: ${result.databaseRestoredTo}',
        'Media files copied: ${result.mediaFilesCopied}',
        'Encrypted vault chunks copied: ${result.vaultChunksCopied}',
        'Bytes copied: ${result.bytesCopied}',
      ],
    );
  }
}

String _firstModelId(List<ModelArtifact> models) {
  if (models.isEmpty) {
    return 'scrfd-face-detector';
  }
  return models.first.id;
}

class _BackupResultCard extends StatelessWidget {
  const _BackupResultCard({
    required this.ok,
    required this.title,
    required this.lines,
  });

  final bool ok;
  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(
          color: ok ? colorScheme.primary : colorScheme.error,
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  ok ? Icons.verified_outlined : Icons.warning_amber_outlined,
                  color: ok ? colorScheme.primary : colorScheme.error,
                ),
                const SizedBox(width: 8),
                Text(title, style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 10),
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: SelectableText(line),
              ),
          ],
        ),
      ),
    );
  }
}
