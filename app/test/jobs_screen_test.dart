import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_gallery_app/src/features/jobs/jobs_screen.dart';
import 'package:private_gallery_app/src/models/gallery_models.dart';

void main() {
  testWidgets('shows job logs and retries failed jobs', (tester) async {
    final retryIds = <String>[];
    var refreshCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: JobsScreen(
            jobs: [_job(status: 'failed')],
            onFetchLogs: (_) async => [
              JobLog(
                id: 'log-1',
                jobId: 'job-1',
                level: 'error',
                message: 'local OCR provider missing',
                createdAt: DateTime.utc(2026, 5, 13, 7),
              ),
            ],
            onCancelJob: (_) => throw UnimplementedError(),
            onRetryJob: (id) async {
              retryIds.add(id);
              return _job(
                id: 'job-2',
                status: 'queued',
                detail: 'retry queued',
              );
            },
            onRefresh: () async {
              refreshCount += 1;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('View logs'));
    await tester.pumpAndSettle();

    expect(find.textContaining('local OCR provider missing'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(retryIds, ['job-1']);
    expect(refreshCount, 1);
    expect(find.text('retry queued'), findsOneWidget);
  });

  testWidgets('cancels running jobs and refreshes the list', (tester) async {
    final cancelIds = <String>[];
    var refreshCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: JobsScreen(
            jobs: [_job(status: 'running')],
            onFetchLogs: (_) async => const [],
            onCancelJob: (id) async {
              cancelIds.add(id);
              return _job(status: 'canceled', detail: 'job canceled');
            },
            onRetryJob: (_) => throw UnimplementedError(),
            onRefresh: () async {
              refreshCount += 1;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(cancelIds, ['job-1']);
    expect(refreshCount, 1);
    expect(find.text('job canceled'), findsOneWidget);
  });
}

JobRecord _job({
  String id = 'job-1',
  required String status,
  String? detail,
}) {
  return JobRecord(
    id: id,
    kind: 'ocr_index',
    status: status,
    progress: status == 'completed' ? 100 : 25,
    queuedAt: DateTime.utc(2026, 5, 13, 6),
    startedAt: DateTime.utc(2026, 5, 13, 6, 1),
    completedAt: status == 'running' || status == 'queued'
        ? null
        : DateTime.utc(2026, 5, 13, 6, 2),
    detail: detail ?? 'OCR job detail',
    cancelRequested: false,
    retryOfJobId: null,
    attempt: 1,
  );
}
