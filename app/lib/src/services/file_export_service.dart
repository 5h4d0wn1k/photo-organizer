import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:share_plus/share_plus.dart';

enum FileExportStatus { saved, shared, cancelled, unavailable }

class FileExportResult {
  const FileExportResult(this.status, {this.path});

  final FileExportStatus status;
  final String? path;
}

class FileExportService {
  const FileExportService();

  Future<FileExportResult> saveDesktop({
    required String suggestedName,
    required Future<File> Function(File destination) download,
  }) async {
    final location = await getSaveLocation(suggestedName: suggestedName);
    if (location == null) {
      return const FileExportResult(FileExportStatus.cancelled);
    }
    final saved = await download(File(location.path));
    return FileExportResult(FileExportStatus.saved, path: saved.path);
  }

  Future<FileExportResult> shareMobile({
    required String filename,
    required String? mimeType,
    required Future<File> Function(File destination) download,
  }) async {
    final directory = await Directory.systemTemp.createTemp('photo-organizer-');
    final file = File('${directory.path}/$filename');
    try {
      final downloaded = await download(file);
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(downloaded.path, mimeType: mimeType)],
          subject: filename,
          title: filename,
        ),
      );
      switch (result.status) {
        case ShareResultStatus.success:
          return const FileExportResult(FileExportStatus.shared);
        case ShareResultStatus.dismissed:
          return const FileExportResult(FileExportStatus.cancelled);
        case ShareResultStatus.unavailable:
          return const FileExportResult(FileExportStatus.unavailable);
      }
    } finally {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  }
}
