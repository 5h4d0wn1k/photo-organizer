import 'dart:async';
import 'dart:io';

import '../api/local_api_client.dart';
import '../models/gallery_models.dart';

class LocalDaemonLauncher {
  const LocalDaemonLauncher();

  Future<DaemonLaunchResult> ensureRunning(LocalApiClient apiClient) async {
    try {
      await apiClient.fetchHealth();
      return const DaemonLaunchResult(
        attempted: false,
        started: true,
        alreadyRunning: true,
        attemptedCommands: [],
        message: 'Local daemon already reachable.',
      );
    } catch (_) {
      // Continue into start attempts.
    }

    if (!(Platform.isLinux || Platform.isMacOS || Platform.isWindows)) {
      return const DaemonLaunchResult(
        attempted: false,
        started: false,
        alreadyRunning: false,
        attemptedCommands: [],
        message: 'Automatic daemon start is only available on desktop targets.',
      );
    }

    final attemptedCommands = <String>[];
    Object? lastStartError;
    for (final command in _candidateCommands()) {
      attemptedCommands.add(_formatCommand(command));

      try {
        final workingDirectory = _workingDirectoryForCommand(command);
        final process = await Process.start(
          command.first,
          command.sublist(1),
          workingDirectory: workingDirectory,
          environment: _environmentForCommand(command, workingDirectory),
          includeParentEnvironment: true,
          mode: ProcessStartMode.detached,
          runInShell: false,
        );
        unawaited(process.exitCode);
      } catch (error) {
        lastStartError = error;
        continue;
      }

      final healthy = await _waitForHealth(apiClient);
      if (healthy) {
        return DaemonLaunchResult(
          attempted: true,
          started: true,
          alreadyRunning: false,
          attemptedCommands: attemptedCommands,
          message: 'Started the local gallery daemon.',
        );
      }
    }

    return DaemonLaunchResult(
      attempted: true,
      started: false,
      alreadyRunning: false,
      attemptedCommands: attemptedCommands,
      message: lastStartError == null
          ? 'Unable to reach the local daemon and no launch command succeeded.'
          : 'Unable to reach the local daemon. Last start error: $lastStartError',
    );
  }

  List<List<String>> _candidateCommands() {
    return candidateCommandsForPaths(
      currentDirectory: Directory.current.path,
      executablePath: Platform.executable,
      resolvedExecutablePath: Platform.resolvedExecutable,
      isWindows: Platform.isWindows,
    );
  }

  Future<bool> _waitForHealth(LocalApiClient apiClient) async {
    for (var attempt = 0; attempt < 180; attempt += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      try {
        await apiClient.fetchHealth();
        return true;
      } catch (_) {
        // Keep polling until retries are exhausted.
      }
    }

    return false;
  }

  static List<List<String>> candidateCommandsForPaths({
    required String currentDirectory,
    required String executablePath,
    required String resolvedExecutablePath,
    required bool isWindows,
  }) {
    final binaryName = isWindows ? 'galleryd.exe' : 'galleryd';
    final commands = <List<String>>[];
    final seen = <String>{};

    final searchRoots = <String>[
      currentDirectory,
      File(executablePath).parent.path,
      File(resolvedExecutablePath).parent.path,
    ];

    for (final root in searchRoots) {
      final siblingBinary = _joinPath(root, [binaryName]);
      _addCommandIfExists(commands, seen, [siblingBinary]);
    }

    final ancestorPaths = <String>[];
    final visitedAncestors = <String>{};
    for (final root in searchRoots) {
      for (final ancestor in _ancestorPaths(root)) {
        if (visitedAncestors.add(ancestor)) {
          ancestorPaths.add(ancestor);
        }
      }
    }

    for (final ancestor in ancestorPaths) {
      final debugBinary = _joinPath(ancestor, ['target', 'debug', binaryName]);
      final releaseBinary = _joinPath(ancestor, [
        'target',
        'release',
        binaryName,
      ]);
      final nativeCoreDebugBinary = _joinPath(ancestor, [
        'native_core',
        'target',
        'debug',
        binaryName,
      ]);
      final nativeCoreReleaseBinary = _joinPath(ancestor, [
        'native_core',
        'target',
        'release',
        binaryName,
      ]);
      final nativeCoreManifest = _joinPath(ancestor, [
        'native_core',
        'Cargo.toml',
      ]);

      for (final command in [
        [debugBinary],
        [releaseBinary],
        [nativeCoreDebugBinary],
        [nativeCoreReleaseBinary],
      ]) {
        _addCommandIfExists(commands, seen, command);
      }

      final cargoCommand = [
        'cargo',
        'run',
        '--manifest-path',
        nativeCoreManifest,
        '--bin',
        'galleryd',
      ];
      final cargoKey = cargoCommand.join('\u0000');
      if (File(nativeCoreManifest).existsSync() && seen.add(cargoKey)) {
        commands.add(cargoCommand);
      }
    }

    _addCommand(commands, seen, [binaryName]);
    return commands;
  }

  static void _addCommandIfExists(
    List<List<String>> commands,
    Set<String> seen,
    List<String> command,
  ) {
    if (File(command.first).existsSync()) {
      _addCommand(commands, seen, command);
    }
  }

  static void _addCommand(
    List<List<String>> commands,
    Set<String> seen,
    List<String> command,
  ) {
    final key = command.join('\u0000');
    if (seen.add(key)) {
      commands.add(command);
    }
  }

  static String _formatCommand(List<String> command) {
    return command.map(_quoteForDisplay).join(' ');
  }

  static String _quoteForDisplay(String value) {
    final simple = RegExp(r'^[A-Za-z0-9_./:=+-]+$');
    if (simple.hasMatch(value)) {
      return value;
    }
    return "'${value.replaceAll("'", "'\\''")}'";
  }

  static List<String> _ancestorPaths(String startPath) {
    final ancestors = <String>[];
    var directory = Directory(startPath).absolute;

    while (true) {
      ancestors.add(directory.path);
      final parent = directory.parent;
      if (parent.path == directory.path) {
        break;
      }
      directory = parent;
    }

    return ancestors;
  }

  static String _joinPath(String base, List<String> segments) {
    final separator = Platform.pathSeparator;
    var value = base;
    for (final segment in segments) {
      if (value.endsWith(separator)) {
        value = '$value$segment';
      } else {
        value = '$value$separator$segment';
      }
    }
    return value;
  }

  static String? _workingDirectoryForCommand(List<String> command) {
    if (command.isEmpty) {
      return null;
    }

    if (command.first == 'cargo') {
      final manifestIndex = command.indexOf('--manifest-path');
      if (manifestIndex >= 0 && manifestIndex + 1 < command.length) {
        final nativeCoreDir = File(command[manifestIndex + 1]).parent;
        return nativeCoreDir.parent.path;
      }
      return null;
    }

    final executable = File(command.first);
    if (!executable.isAbsolute) {
      return null;
    }

    return _repoRootForPath(executable.parent.path) ?? executable.parent.path;
  }

  static Map<String, String> _environmentForCommand(
    List<String> command,
    String? workingDirectory,
  ) {
    if (workingDirectory == null || workingDirectory.isEmpty) {
      return const {};
    }

    final environment = <String, String>{
      'PRIVATE_GALLERY_RUNTIME_ROOT': _joinPath(workingDirectory, ['runtime']),
    };
    final repoSidecar = File(
      _joinPath(workingDirectory, [
        'ml_sidecar',
        'private_gallery_ml_sidecar.py',
      ]),
    );
    if (repoSidecar.existsSync()) {
      environment['PRIVATE_GALLERY_ML_SIDECAR'] = repoSidecar.path;
    } else if (command.isNotEmpty && File(command.first).isAbsolute) {
      final bundledSidecar = File(
        _joinPath(File(command.first).parent.path, [
          'ml_sidecar',
          'private_gallery_ml_sidecar.py',
        ]),
      );
      if (bundledSidecar.existsSync()) {
        environment['PRIVATE_GALLERY_ML_SIDECAR'] = bundledSidecar.path;
      }
    }
    return environment;
  }

  static String? _repoRootForPath(String startPath) {
    for (final ancestor in _ancestorPaths(startPath)) {
      final manifest = File(
        _joinPath(ancestor, ['native_core', 'Cargo.toml']),
      );
      final launcher = File(
        _joinPath(ancestor, ['scripts', 'private_gallery_linux_launcher.sh']),
      );
      if (manifest.existsSync() || launcher.existsSync()) {
        return ancestor;
      }
    }
    return null;
  }
}
