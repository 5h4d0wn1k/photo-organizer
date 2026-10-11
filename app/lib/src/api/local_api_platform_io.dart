import 'dart:async';
import 'dart:io';
import 'dart:math';

typedef LocalApiFile = File;

const localHttpStatusOk = HttpStatus.ok;
const localHttpStatusPartialContent = HttpStatus.partialContent;
const localHttpStatusRequestedRangeNotSatisfiable =
    HttpStatus.requestedRangeNotSatisfiable;

Exception localApiTimeoutException(Uri uri) {
  return SocketException('Timed out while reaching $uri');
}

Exception localApiTransferException(String message) {
  return SocketException(message);
}

LocalApiFile localApiFileFromObject(Object file) {
  if (file is File) {
    return file;
  }
  throw ArgumentError.value(file, 'file', 'must be a dart:io File');
}

Future<int> localApiFileLength(LocalApiFile file) {
  return file.length();
}

Future<List<int>> localApiReadFileChunk(
  LocalApiFile file,
  int offset,
  int length,
) async {
  final handle = await file.open();
  try {
    await handle.setPosition(offset);
    return await handle.read(length);
  } finally {
    await handle.close();
  }
}

Future<void> localApiCreateParent(LocalApiFile file) {
  return file.parent.create(recursive: true);
}

LocalApiFile localApiPartFile(LocalApiFile destination) {
  return File('${destination.path}.part');
}

Future<bool> localApiFileExists(LocalApiFile file) {
  return file.exists();
}

Future<void> localApiRecoverDownloadedFile(LocalApiFile destination) async {
  if (await destination.exists()) {
    return;
  }
  final parent = destination.parent;
  if (!await parent.exists()) {
    return;
  }
  final backupPattern = RegExp(
    '^${RegExp.escape(destination.path)}\\.previous\\.[0-9a-f]{32}\$',
  );
  final backups = <File>[];
  await for (final entity in parent.list(followLinks: false)) {
    if (entity is File && backupPattern.hasMatch(entity.path)) {
      backups.add(entity);
    }
  }
  backups.sort((left, right) => left.path.compareTo(right.path));
  if (backups.isNotEmpty) {
    await backups.last.rename(destination.path);
  }
}

Future<void> localApiDeleteFile(LocalApiFile file) {
  return file.delete();
}

Future<LocalApiFile> localApiRenameFile(
  LocalApiFile file,
  LocalApiFile destination,
) {
  return file.rename(destination.path);
}

Stream<List<int>> localApiOpenRead(LocalApiFile file) => file.openRead();

Future<void> localApiCommitDownloadedFile(
  LocalApiFile temporary,
  LocalApiFile destination,
) async {
  final random = Random.secure();
  final backupId = List<String>.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  final backup = File('${destination.path}.previous.$backupId');
  final hadDestination = await destination.exists();
  if (hadDestination) {
    await destination.rename(backup.path);
  }
  try {
    await temporary.rename(destination.path);
  } catch (_) {
    if (hadDestination && await backup.exists()) {
      await backup.rename(destination.path);
    }
    rethrow;
  }
  if (hadDestination && await backup.exists()) {
    await backup.delete();
  }
}

Future<int> localApiWriteStreamToFile(
  Stream<List<int>> stream,
  LocalApiFile file, {
  required bool append,
  int? expectedBytes,
  int? maxBytes,
  required Duration timeout,
}) async {
  var received = 0;
  final sink = file.openWrite(mode: append ? FileMode.append : FileMode.write);
  try {
    await for (final chunk in stream.timeout(timeout)) {
      if (maxBytes != null && chunk.length > maxBytes - received) {
        throw localApiTransferException(
          'Download exceeded the allowed $maxBytes bytes',
        );
      }
      received += chunk.length;
      sink.add(chunk);
    }
  } finally {
    await sink.close();
  }
  if (expectedBytes != null && received != expectedBytes) {
    throw localApiTransferException(
      'Downloaded $received bytes, expected $expectedBytes',
    );
  }
  return received;
}
