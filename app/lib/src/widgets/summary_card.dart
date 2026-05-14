import 'package:flutter/material.dart';

class SummaryCard extends StatelessWidget {
  const SummaryCard({
    super.key,
    required this.label,
    required this.value,
    required this.caption,
    required this.icon,
  });

  final String label;
  final String value;
  final String caption;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text(label, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(value, style: theme.textTheme.headlineMedium),
            const SizedBox(height: 8),
            Text(caption, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}
