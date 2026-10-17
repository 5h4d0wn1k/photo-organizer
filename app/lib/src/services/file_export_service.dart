import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:share_plus/share_plus.dart';

enum FileExportStatus { saved, shareActionSelected, cancelled, unavailable }

class FileExportResult {
  const FileExportResult(this.status, {this.path});

  final FileExportStatus status;
  final String? path;
}

class FileExportService {
  const FileExportService({this.saveLocation, this.shareFile});

  final Future<FileSaveLocation?> Function(String suggestedName)? saveLocation;
  final Future<ShareResult> Function(ShareParams params)? shareFile;

  Future<FileExportResult> saveDesktop({
    required String suggestedName,
    required Future<File> Function(File destination) download,
  }) async {
    final location = await (saveLocation ?? _getSaveLocation)(suggestedName);
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
      final result = await (shareFile ?? _shareFile)(
        ShareParams(
          files: [XFile(downloaded.path, mimeType: mimeType)],
          subject: filename,
          title: filename,
        ),
      );
      switch (result.status) {
        case ShareResultStatus.success:
          return const FileExportResult(FileExportStatus.shareActionSelected);
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

Future<FileSaveLocation?> _getSaveLocation(String suggestedName) {
  return getSaveLocation(suggestedName: suggestedName);
}

Future<ShareResult> _shareFile(ShareParams params) {
  return SharePlus.instance.share(params);
}
