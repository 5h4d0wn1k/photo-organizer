import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_gallery_app/src/features/settings/settings_screen.dart';
import 'package:private_gallery_app/src/models/gallery_models.dart';

void main() {
  testWidgets(
    'export confirms passphrase and clears inputs before request failure',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      var calls = 0;
      String? received;
      final pending = Completer<BackupExportResult>();
      await tester.pumpWidget(
        _screen(
          onExport:
              ({
                required exportRoot,
                includeModels = true,
                recoveryPassphrase,
              }) {
                calls++;
                received = recoveryPassphrase;
                return pending.future;
              },
        ),
      );
      await tester.pumpAndSettle();
      final pass = find.widgetWithText(TextField, 'Backup recovery passphrase');
      final confirm = find.widgetWithText(
        TextField,
        'Confirm backup recovery passphrase',
      );
      final export = find.widgetWithText(FilledButton, 'Export backup');
      const secret = '  private backup value  ';
      await tester.ensureVisible(pass);
      await tester.enterText(pass, secret);
      await tester.ensureVisible(confirm);
      await tester.enterText(confirm, 'different private backup');
      await tester.ensureVisible(export);
      await tester.tap(export);
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(
        find.text('The recovery passphrases do not match.'),
        findsOneWidget,
      );
      await _dismissFeedback(tester);
      await tester.ensureVisible(confirm);
      await tester.enterText(confirm, secret);
      await tester.ensureVisible(export);
      await tester.tap(export);
      await tester.pump();
      expect(calls, 1);
      expect(
        received,
        secret,
        reason: 'Do not trim or normalize a recovery passphrase',
      );
      for (final finder in [pass, confirm]) {
        final field = tester.widget<TextField>(finder);
        expect(field.controller!.text, isEmpty);
        expect(field.obscureText, isTrue);
        expect(field.autocorrect, isFalse);
        expect(field.enableSuggestions, isFalse);
        expect(field.enableIMEPersonalizedLearning, isFalse);
      }
      pending.completeError(StateError(secret));
      await tester.pumpAndSettle();
      expect(find.textContaining(secret), findsNothing);
      expect(
        find.text(
          'Backup export failed. Check the export path and recovery passphrase.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'restore requires plan passphrase and clears it before verified result',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      var calls = 0;
      String? received;
      final pending = Completer<BackupRestoreRunResult>();
      await tester.pumpWidget(
        _screen(
          onRestore:
              ({
                required exportRoot,
                required restoreRoot,
                confirmed = true,
                recoveryPassphrase,
              }) {
                calls++;
                received = recoveryPassphrase;
                expect(confirmed, isTrue);
                return pending.future;
              },
        ),
      );
      await tester.pumpAndSettle();
      final plan = find.widgetWithText(OutlinedButton, 'Plan restore');
      await tester.ensureVisible(plan);
      await tester.tap(plan);
      await tester.pumpAndSettle();
      await _dismissFeedback(tester);
      final restore = find.widgetWithText(FilledButton, 'Restore and verify');
      await tester.ensureVisible(restore);
      await tester.tap(restore);
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(
        find.text('Enter the recovery passphrase for this backup.'),
        findsOneWidget,
      );
      await _dismissFeedback(tester);
      final pass = find.widgetWithText(
        TextField,
        'Restore recovery passphrase',
      );
      await tester.ensureVisible(pass);
      await tester.enterText(pass, 'short');
      await tester.ensureVisible(restore);
      await tester.tap(restore);
      await tester.pumpAndSettle();
      expect(calls, 0);
      await _dismissFeedback(tester);
      const secret = 'sixteen-byte secret!';
      await tester.ensureVisible(pass);
      await tester.enterText(pass, secret);
      await tester.ensureVisible(restore);
      await tester.tap(restore);
      await tester.pump();
      expect(calls, 1);
      expect(received, secret);
      expect(tester.widget<TextField>(pass).controller!.text, isEmpty);
      pending.complete(
        BackupRestoreRunResult.fromJson({
          'ok': true,
          'detail': 'Recovered library verified.',
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('Recovered library verified.'), findsWidgets);
    },
  );
}

Widget _screen({
  Future<BackupExportResult> Function({
    required String exportRoot,
    bool includeModels,
    String? recoveryPassphrase,
  })?
  onExport,
  Future<BackupRestoreRunResult> Function({
    required String exportRoot,
    required String restoreRoot,
    bool confirmed,
    String? recoveryPassphrase,
  })?
  onRestore,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SettingsScreen(
        workspace: WorkspaceSnapshot(
          status: LibraryStatus.fromJson({
            'is_initialized': true,
            'settings': {
              'library_root': '/library',
              'default_import_mode': 'copy',
            },
          }),
          dashboard: GalleryDashboardData(
            timeline: TimelineResponse.fromJson({'buckets': []}),
            albums: const [],
            people: const [],
            places: const [],
            events: const [],
            auditEvents: const [],
            jobs: const [],
            models: const [],
            modelRuntimeStatus: null,
          ),
          diagnostics: null,
          privacyStatus: null,
          entitlementStatus: null,
          platformReleaseReadiness: null,
        ),
        onActivateEncryption: () async {},
        onImportLocalModel:
            ({
              required id,
              required localPath,
              expectedSha256,
              required confirmed,
            }) async => throw UnimplementedError(),
        onVerifyModel: (_) async => throw UnimplementedError(),
        onVerifyBackup: ({exportRoot}) async => throw UnimplementedError(),
        onExportBackup:
            onExport ??
            ({
              required exportRoot,
              includeModels = true,
              recoveryPassphrase,
            }) async => throw UnimplementedError(),
        onExportSupportBundle:
            ({required exportRoot, includeReleaseReadiness = true}) async =>
                throw UnimplementedError(),
        onPlanRestoreBackup:
            ({required exportRoot, required restoreRoot}) async =>
                BackupRestorePlan.fromJson({
                  'ok': true,
                  'requires_recovery_passphrase': true,
                  'activation_supported': true,
                }),
        onRunRestoreBackup:
            onRestore ??
            ({
              required exportRoot,
              required restoreRoot,
              confirmed = true,
              recoveryPassphrase,
            }) async => throw UnimplementedError(),
        onSaveSettings: (_) async {},
        onAddWatchFolder: (_) async {},
        onDeleteWatchFolder: (_) async {},
        onOpenImport: () {},
      ),
    ),
  );
}

Future<void> _dismissFeedback(WidgetTester tester) async {
  // SnackBars queue by design. Finish feedback from the previous action before
  // asserting the next action's independent result.
  ScaffoldMessenger.of(
    tester.element(find.byType(SettingsScreen)),
  ).clearSnackBars();
  await tester.pumpAndSettle();
}
