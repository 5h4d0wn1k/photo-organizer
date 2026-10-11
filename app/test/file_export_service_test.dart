import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_gallery_app/src/services/file_export_service.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  test('does not download when the save dialog is cancelled', () async {
    var downloadCalled = false;
    final service = FileExportService(saveLocation: (_) async => null);

    final result = await service.saveDesktop(
      suggestedName: 'photo.jpg',
      download: (_) async {
        downloadCalled = true;
        return File('/unused');
      },
    );

    expect(result.status, FileExportStatus.cancelled);
    expect(downloadCalled, isFalse);
  });

  test('saves only after the downloader completes', () async {
    final directory = await Directory.systemTemp.createTemp('po-save-test-');
    addTearDown(() => directory.delete(recursive: true));
    final destination = File('${directory.path}/photo.jpg');
    final service = FileExportService(
      saveLocation: (_) async => FileSaveLocation(destination.path),
    );

    final result = await service.saveDesktop(
      suggestedName: 'photo.jpg',
      download: (file) async {
        await file.writeAsBytes(const [1, 2, 3]);
        return file;
      },
    );

    expect(result.status, FileExportStatus.saved);
    expect(result.path, destination.path);
    expect(await destination.readAsBytes(), const [1, 2, 3]);
  });

  test(
    'mobile share reports selected action and removes temporary export',
    () async {
      String? sharedPath;
      final service = FileExportService(
        shareFile: (params) async {
          sharedPath = params.files!.single.path;
          expect(await File(sharedPath!).readAsBytes(), const [4, 5, 6]);
          return const ShareResult('selected', ShareResultStatus.success);
        },
      );

      final result = await service.shareMobile(
        filename: 'photo.jpg',
        mimeType: 'image/jpeg',
        download: (file) async {
          await file.writeAsBytes(const [4, 5, 6]);
          return file;
        },
      );

      expect(result.status, FileExportStatus.shareActionSelected);
      expect(await File(sharedPath!).exists(), isFalse);
    },
  );

  test('mobile share preserves dismissed and unavailable outcomes', () async {
    for (final expected in [
      ShareResultStatus.dismissed,
      ShareResultStatus.unavailable,
    ]) {
      final service = FileExportService(
        shareFile: (_) async => ShareResult('result', expected),
      );
      final result = await service.shareMobile(
        filename: 'photo.jpg',
        mimeType: 'image/jpeg',
        download: (file) async {
          await file.writeAsBytes(const [7]);
          return file;
        },
      );
      expect(
        result.status,
        expected == ShareResultStatus.dismissed
            ? FileExportStatus.cancelled
            : FileExportStatus.unavailable,
      );
    }
  });
}
