import 'package:flutter/material.dart';

import '../../models/gallery_models.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({
    super.key,
    required this.message,
    required this.libraryStatus,
    required this.diagnostics,
    required this.submitting,
    required this.onSubmit,
    required this.onRetry,
    required this.onStartDaemon,
  });

  final String? message;
  final LibraryStatus? libraryStatus;
  final DaemonDiagnostics? diagnostics;
  final bool submitting;
  final Future<void> Function(SetupDraft draft) onSubmit;
  final Future<void> Function() onRetry;
  final Future<void> Function() onStartDaemon;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  static const String _recommendedLibraryRoot =
      '/mnt/windows/transfer/Ok/Photos/PrivateGalleryLibrary';
  static const String _recommendedSourceRoot =
      '/mnt/windows/transfer/Ok/Photos';

  late final TextEditingController _libraryRootController;
  late final TextEditingController _watchFoldersController;
  ImportMode _importMode = ImportMode.move;

  @override
  void initState() {
    super.initState();
    _libraryRootController = TextEditingController(
      text: widget.libraryStatus?.settings?.libraryRoot ??
          widget.diagnostics?.libraryRoot ??
          _recommendedLibraryRoot,
    );
    _watchFoldersController = TextEditingController(
      text: widget.libraryStatus?.watchFolders
              .map((folder) => folder.path)
              .join('\n') ??
          _recommendedSourceRoot,
    );
    _importMode =
        widget.libraryStatus?.settings?.defaultImportMode ?? ImportMode.move;
  }

  @override
  void dispose() {
    _libraryRootController.dispose();
    _watchFoldersController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final libraryRoot = _libraryRootController.text.trim();
    if (libraryRoot.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a library root path first.')),
      );
      return;
    }

    final watchFolders = _watchFoldersController.text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .map(
          (path) => WatchFolderDraft(
            path: path,
            recursive: true,
            importMode: _importMode,
          ),
        )
        .toList();

    await widget.onSubmit(
      SetupDraft(
        settings: LibrarySettingsDraft(
          libraryRoot: libraryRoot,
          defaultImportMode: _importMode,
        ),
        watchFolders: watchFolders,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Set up your local library')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                'Create the local managed library for your photos and videos.',
                style: theme.textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              Text(
                'This flow keeps organization on this machine. The recommended mode moves files into the managed library only after hash verification, so the app avoids duplicate archives and does not use cloud services.',
                style: theme.textTheme.bodyLarge,
              ),
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
                        icon: Icons.content_cut_outlined,
                        label: 'No duplicate archive by default',
                      ),
                      _SafetyPill(
                        icon: Icons.verified_outlined,
                        label: 'Hash verified before source removal',
                      ),
                    ],
                  ),
                ),
              ),
              if (widget.message != null) ...[
                const SizedBox(height: 16),
                Card(
                  color: theme.colorScheme.secondaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(widget.message!),
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
                      Text('Library root', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 8),
                      const Text(
                        'Use a local encrypted drive when possible. The default path below keeps the managed library inside your Photos folder for this project.',
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _libraryRootController,
                        decoration: const InputDecoration(
                          labelText: 'Library root path',
                          hintText:
                              '/mnt/windows/transfer/Ok/Photos/PrivateGalleryLibrary',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 20),
                      DropdownButtonFormField<ImportMode>(
                        initialValue: _importMode,
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
                          setState(() => _importMode = value);
                        },
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: _watchFoldersController,
                        minLines: 3,
                        maxLines: 6,
                        decoration: const InputDecoration(
                          labelText: 'Initial watched folders',
                          hintText: '/mnt/windows/transfer/Ok/Photos',
                          helperText:
                              'Use your current photo source here. The managed library folder is excluded from recursive scans.',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          FilledButton.icon(
                            onPressed: widget.submitting ? null : _submit,
                            icon: widget.submitting
                                ? const SizedBox(
                                    height: 18,
                                    width: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.save_outlined),
                            label: const Text('Save setup'),
                          ),
                          OutlinedButton.icon(
                            onPressed:
                                widget.submitting ? null : widget.onRetry,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Retry API'),
                          ),
                          TextButton.icon(
                            onPressed:
                                widget.submitting ? null : widget.onStartDaemon,
                            icon: const Icon(Icons.play_circle_outline),
                            label: const Text('Start daemon'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (widget.diagnostics != null) ...[
                const SizedBox(height: 24),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Live daemon diagnostics',
                          style: theme.textTheme.titleLarge,
                        ),
                        const SizedBox(height: 12),
                        Text(
                            'Database path: ${widget.diagnostics!.databasePath ?? 'Unknown'}'),
                        Text(
                            'Library root: ${widget.diagnostics!.libraryRoot ?? 'Unknown'}'),
                        Text('Known assets: ${widget.diagnostics!.assets}'),
                        Text('Known jobs: ${widget.diagnostics!.jobs}'),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
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
