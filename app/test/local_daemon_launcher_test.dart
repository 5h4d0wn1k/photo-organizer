import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_gallery_app/src/services/local_daemon_launcher.dart';

void main() {
  test('finds repo-root daemon binaries from a bundle-style path', () async {
    final tempRoot = await Directory.systemTemp.createTemp(
      'private-gallery-launcher-',
    );
    addTearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    final bundleDir = Directory(
      '${tempRoot.path}${Platform.pathSeparator}app${Platform.pathSeparator}build${Platform.pathSeparator}linux${Platform.pathSeparator}x64${Platform.pathSeparator}release${Platform.pathSeparator}bundle',
    );
    await bundleDir.create(recursive: true);

    final bundledBinary = File(
      '${bundleDir.path}${Platform.pathSeparator}${_binaryName()}',
    );
    await bundledBinary.writeAsString('');

    final repoBinary = File(
      '${tempRoot.path}${Platform.pathSeparator}target${Platform.pathSeparator}debug${Platform.pathSeparator}${_binaryName()}',
    );
    await repoBinary.parent.create(recursive: true);
    await repoBinary.writeAsString('');

    final releaseBinary = File(
      '${tempRoot.path}${Platform.pathSeparator}target${Platform.pathSeparator}release${Platform.pathSeparator}${_binaryName()}',
    );
    await releaseBinary.parent.create(recursive: true);
    await releaseBinary.writeAsString('');

    final manifest = File(
      '${tempRoot.path}${Platform.pathSeparator}native_core${Platform.pathSeparator}Cargo.toml',
    );
    await manifest.parent.create(recursive: true);
    await manifest.writeAsString('[package]\nname = "native_core"\n');

    final commands = LocalDaemonLauncher.candidateCommandsForPaths(
      currentDirectory: bundleDir.path,
      executablePath:
          '${bundleDir.path}${Platform.pathSeparator}private_gallery_app',
      resolvedExecutablePath:
          '${bundleDir.path}${Platform.pathSeparator}private_gallery_app',
      isWindows: Platform.isWindows,
    );

    expect(commands.first.first, bundledBinary.path);
    expect(commands.any((command) => command.first == _binaryName()), isTrue);
    expect(commands.any((command) => command.first == repoBinary.path), isTrue);
    expect(
      commands.any((command) => command.first == releaseBinary.path),
      isTrue,
    );
    expect(
      commands.any(
        (command) =>
            command.first == 'cargo' && command.contains(manifest.path),
      ),
      isTrue,
    );
    expect(commands.last.first, _binaryName());
  });
}

String _binaryName() => Platform.isWindows ? 'galleryd.exe' : 'galleryd';
