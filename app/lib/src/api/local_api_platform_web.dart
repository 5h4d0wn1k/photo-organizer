import 'dart:async';

class LocalApiFile {
  const LocalApiFile();
}

const localHttpStatusOk = 200;
const localHttpStatusPartialContent = 206;
const localHttpStatusRequestedRangeNotSatisfiable = 416;

Exception localApiTimeoutException(Uri uri) {
  return TimeoutException('Timed out while reaching $uri');
}

Exception localApiTransferException(String message) {
  return Exception(message);
}

UnsupportedError _unsupportedFileStreaming() {
  return UnsupportedError(
    'Local file streaming is not available in the browser; use the byte-based API instead.',
  );
}

LocalApiFile localApiFileFromObject(Object file) {
  throw _unsupportedFileStreaming();
}

Future<int> localApiFileLength(LocalApiFile file) {
  throw _unsupportedFileStreaming();
}

Future<List<int>> localApiReadFileChunk(
  LocalApiFile file,
  int offset,
  int length,
) {
  throw _unsupportedFileStreaming();
}

Future<void> localApiCreateParent(LocalApiFile file) {
  throw _unsupportedFileStreaming();
}

LocalApiFile localApiPartFile(LocalApiFile destination) {
  throw _unsupportedFileStreaming();
}

Future<bool> localApiFileExists(LocalApiFile file) {
  throw _unsupportedFileStreaming();
}

Future<void> localApiDeleteFile(LocalApiFile file) {
  throw _unsupportedFileStreaming();
}

Future<LocalApiFile> localApiRenameFile(
  LocalApiFile file,
  LocalApiFile destination,
) {
  throw _unsupportedFileStreaming();
}

Future<int> localApiWriteStreamToFile(
  Stream<List<int>> stream,
  LocalApiFile file, {
  required bool append,
  int? expectedBytes,
  required Duration timeout,
}) {
  throw _unsupportedFileStreaming();
}
