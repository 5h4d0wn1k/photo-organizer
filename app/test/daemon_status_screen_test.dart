import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_gallery_app/src/features/setup/daemon_status_screen.dart';
import 'package:private_gallery_app/src/models/gallery_models.dart';

void main() {
  testWidgets('automatically retries while waiting for daemon startup',
      (tester) async {
    var retryCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: DaemonStatusScreen(
          title: 'Local daemon unavailable',
          message: 'The local gallery daemon is not reachable.',
          launchResult: const DaemonLaunchResult.none(),
          onRetry: () async {
            retryCalls += 1;
          },
          onStartDaemon: () async {},
        ),
      ),
    );

    expect(retryCalls, 0);
    expect(find.textContaining('checks again automatically'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(retryCalls, 1);
  });

  testWidgets('manual retry is disabled while retry is in progress',
      (tester) async {
    final retryCompleter = Completer<void>();

    await tester.pumpWidget(
      MaterialApp(
        home: DaemonStatusScreen(
          title: 'Local daemon unavailable',
          message: 'The local gallery daemon is not reachable.',
          launchResult: const DaemonLaunchResult.none(),
          onRetry: () => retryCompleter.future,
          onStartDaemon: () async {},
        ),
      ),
    );

    await tester.tap(find.text('Retry'));
    await tester.pump();

    final retryButton =
        tester.widget<OutlinedButton>(find.byType(OutlinedButton));
    expect(retryButton.onPressed, isNull);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    retryCompleter.complete();
    await tester.pump();
  });
}
