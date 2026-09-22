import 'dart:async';
import 'dart:io';

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

Future<void> localApiDeleteFile(LocalApiFile file) {
  return file.delete();
}

Future<LocalApiFile> localApiRenameFile(
  LocalApiFile file,
  LocalApiFile destination,
) {
  return file.rename(destination.path);
}

Future<int> localApiWriteStreamToFile(
  Stream<List<int>> stream,
  LocalApiFile file, {
  required bool append,
  int? expectedBytes,
  required Duration timeout,
}) async {
  var received = 0;
  final sink = file.openWrite(mode: append ? FileMode.append : FileMode.write);
  try {
    await for (final chunk in stream.timeout(timeout)) {
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
