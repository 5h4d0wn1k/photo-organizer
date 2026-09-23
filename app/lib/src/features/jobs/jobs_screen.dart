import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/gallery_models.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/empty_state_panel.dart';

typedef JobLogsFetcher = Future<List<JobLog>> Function(String id);
typedef JobAction = Future<JobRecord> Function(String id);

class JobsScreen extends StatefulWidget {
  const JobsScreen({
    super.key,
    required this.jobs,
    required this.onFetchLogs,
    required this.onCancelJob,
    required this.onRetryJob,
    required this.onRefresh,
  });

  final List<JobRecord> jobs;
  final JobLogsFetcher onFetchLogs;
  final JobAction onCancelJob;
  final JobAction onRetryJob;
  final Future<void> Function() onRefresh;

  @override
  State<JobsScreen> createState() => _JobsScreenState();
}

class _JobsScreenState extends State<JobsScreen> {
  String? _busyJobId;

  @override
  Widget build(BuildContext context) {
    if (widget.jobs.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: widget.onRefresh,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
            ),
            const SizedBox(height: 16),
            const EmptyStatePanel(
              icon: Icons.sync_outlined,
              title: 'No sync or activity yet',
              message:
                  'Imports, metadata extraction, OCR, clustering, and sync work will appear here when the local daemon starts real work.',
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(24),
      itemCount: widget.jobs.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        if (index == 0) {
          return _JobsHeader(onRefresh: widget.onRefresh);
        }

        final job = widget.jobs[index - 1];
        final isBusy = _busyJobId == job.id;
        return _JobCard(
          job: job,
          busy: isBusy,
          onViewLogs: () => _showLogs(job),
          onCancel: _canCancel(job) && !isBusy
              ? () => _runJobAction(
                    job,
                    widget.onCancelJob,
                    'Job canceled.',
                  )
              : null,
          onRetry: _canRetry(job) && !isBusy
              ? () => _runJobAction(
                    job,
                    widget.onRetryJob,
                    'Retry job queued.',
                  )
              : null,
        );
      },
    );
  }

  Future<void> _showLogs(JobRecord job) async {
    final logsFuture = widget.onFetchLogs(job.id);
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('${_labelForKind(job.kind)} logs'),
          content: SizedBox(
            width: 680,
            child: FutureBuilder<List<JobLog>>(
              future: logsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snapshot.hasError) {
                  return Text('Unable to load job logs: ${snapshot.error}');
                }

                final logs = snapshot.data ?? const [];
                return _JobLogList(job: job, logs: logs);
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _runJobAction(
    JobRecord job,
    JobAction action,
    String successMessage,
  ) async {
    setState(() => _busyJobId = job.id);
    try {
      final result = await action(job.id);
      await widget.onRefresh();
      _showMessage(result.detail ?? successMessage);
    } catch (error) {
      _showMessage('$error');
    } finally {
      if (mounted) {
        setState(() => _busyJobId = null);
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}

class _JobsHeader extends StatelessWidget {
  const _JobsHeader({required this.onRefresh});

  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return AppSurface(
      child: Row(
        children: [
          const Expanded(
            child: AppSectionHeader(
              title: 'Sync & Activity',
              subtitle:
                  'Review local daemon work, inspect logs, retry failed work, or cancel queued/running jobs.',
            ),
          ),
          OutlinedButton.icon(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh'),
          ),
        ],
      ),
    );
  }
}

class _JobCard extends StatelessWidget {
  const _JobCard({
    required this.job,
    required this.busy,
    required this.onViewLogs,
    required this.onCancel,
    required this.onRetry,
  });

  final JobRecord job;
  final bool busy;
  final VoidCallback onViewLogs;
  final VoidCallback? onCancel;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final formatter = DateFormat.yMMMd().add_jm();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _labelForKind(job.kind),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(job.detail ?? 'Background job'),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                _StatusChip(status: job.status),
              ],
            ),
            const SizedBox(height: 16),
            LinearProgressIndicator(value: job.progress / 100),
            const SizedBox(height: 10),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                Text('${job.progress}% complete'),
                Text('Queued ${formatter.format(job.queuedAt.toLocal())}'),
                if (job.startedAt != null)
                  Text('Started ${formatter.format(job.startedAt!.toLocal())}'),
                if (job.completedAt != null)
                  Text(
                    'Finished ${formatter.format(job.completedAt!.toLocal())}',
                  ),
                if (job.attempt > 1) Text('Attempt ${job.attempt}'),
                if (job.retryOfJobId != null)
                  Text('Retry of ${job.retryOfJobId}'),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton.icon(
                  onPressed: onViewLogs,
                  icon: const Icon(Icons.article_outlined),
                  label: const Text('View logs'),
                ),
                OutlinedButton.icon(
                  onPressed: onCancel,
                  icon: busy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cancel_outlined),
                  label: const Text('Cancel'),
                ),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: busy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'completed' => Colors.green,
      'failed' => Colors.red,
      'canceled' => Colors.orange,
      'running' => Theme.of(context).colorScheme.primary,
      _ => Colors.blueGrey,
    };
    return Chip(
      label: Text(status),
      side: BorderSide(color: color.withValues(alpha: 0.35)),
      backgroundColor: color.withValues(alpha: 0.08),
    );
  }
}

class _JobLogList extends StatelessWidget {
  const _JobLogList({
    required this.job,
    required this.logs,
  });

  final JobRecord job;
  final List<JobLog> logs;

  @override
  Widget build(BuildContext context) {
    final formatter = DateFormat.yMMMd().add_jm();
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Job id: ${job.id}'),
          Text('Status: ${job.status}'),
          Text('Progress: ${job.progress}%'),
          if (job.detail != null) Text('Detail: ${job.detail}'),
          const SizedBox(height: 16),
          if (logs.isEmpty)
            const Text('No logs have been recorded for this job yet.')
          else
            ...logs.map(
              (log) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(
                        color: _colorForLog(log.level, context),
                        width: 3,
                      ),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${log.level.toUpperCase()} • ${formatter.format(log.createdAt.toLocal())}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 3),
                        Text(log.message),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

bool _canCancel(JobRecord job) {
  return job.status == 'queued' || job.status == 'running';
}

bool _canRetry(JobRecord job) {
  return job.status == 'failed' ||
      job.status == 'canceled' ||
      job.status == 'completed';
}

String _labelForKind(String kind) {
  return kind
      .split('_')
      .where((part) => part.isNotEmpty)
      .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
      .join(' ');
}

Color _colorForLog(String level, BuildContext context) {
  return switch (level) {
    'error' => Colors.red,
    'warn' || 'warning' => Colors.orange,
    'debug' => Colors.blueGrey,
    _ => Theme.of(context).colorScheme.primary,
  };
}
