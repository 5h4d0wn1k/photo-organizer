import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/gallery_models.dart';

class DaemonStatusScreen extends StatefulWidget {
  const DaemonStatusScreen({
    super.key,
    required this.title,
    required this.message,
    required this.launchResult,
    required this.onRetry,
    required this.onStartDaemon,
  });

  final String title;
  final String message;
  final DaemonLaunchResult launchResult;
  final Future<void> Function() onRetry;
  final Future<void> Function() onStartDaemon;

  @override
  State<DaemonStatusScreen> createState() => _DaemonStatusScreenState();
}

class _DaemonStatusScreenState extends State<DaemonStatusScreen> {
  static const int _maxAutoRetries = 90;

  Timer? _timer;
  var _retrying = false;
  var _autoRetries = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      _autoRetry();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _autoRetry() async {
    if (_retrying || _autoRetries >= _maxAutoRetries) {
      return;
    }
    _autoRetries += 1;
    await _runRetry();
  }

  Future<void> _runRetry() async {
    if (_retrying) {
      return;
    }
    setState(() {
      _retrying = true;
    });
    try {
      await widget.onRetry();
    } finally {
      if (mounted) {
        setState(() {
          _retrying = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Private Gallery')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.cloud_off_outlined,
                      size: 40,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(widget.title, style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 12),
                    Text(widget.message, style: theme.textTheme.bodyLarge),
                    if (_retrying) ...[
                      const SizedBox(height: 16),
                      const LinearProgressIndicator(minHeight: 2),
                      const SizedBox(height: 8),
                      Text(
                        'Checking whether the local daemon has finished starting...',
                        style: theme.textTheme.bodySmall,
                      ),
                    ] else if (_autoRetries < _maxAutoRetries) ...[
                      const SizedBox(height: 16),
                      Text(
                        'This screen checks again automatically for up to 3 minutes.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                    if (widget.launchResult.attemptedCommands.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      Text(
                        'Attempted commands',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      for (final command
                          in widget.launchResult.attemptedCommands)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: SelectableText(command),
                        ),
                    ],
                    const SizedBox(height: 24),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        FilledButton.icon(
                          onPressed: widget.onStartDaemon,
                          icon: const Icon(Icons.play_circle_outline),
                          label: const Text('Start daemon'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _retrying ? null : _runRetry,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
