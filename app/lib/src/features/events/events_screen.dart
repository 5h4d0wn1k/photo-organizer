import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/gallery_models.dart';
import '../../widgets/asset_grid.dart';
import '../../widgets/empty_state_panel.dart';

class EventsScreen extends StatelessWidget {
  const EventsScreen({
    super.key,
    required this.events,
    required this.libraryRoot,
    required this.onFetchEventAssets,
    required this.onRebuildEvents,
    required this.onTitleEvent,
  });

  final List<EventCluster> events;
  final String libraryRoot;
  final Future<List<Asset>> Function(String id) onFetchEventAssets;
  final Future<void> Function() onRebuildEvents;
  final Future<void> Function(String id, String title) onTitleEvent;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const EmptyStatePanel(
              icon: Icons.event_outlined,
              title: 'No event clusters yet',
              message:
                  'Event grouping depends on imported timestamps and place hints. Once the daemon clusters real assets, editable occasions will appear here.',
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRebuildEvents,
              icon: const Icon(Icons.auto_awesome_motion_outlined),
              label: const Text('Rebuild local events'),
            ),
          ],
        ),
      );
    }

    final formatter = DateFormat.yMMMd();
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                const Icon(Icons.event_available_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${events.length} local occasion clusters. Titles are editable and survive event rebuilds.',
                  ),
                ),
                FilledButton.icon(
                  onPressed: onRebuildEvents,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Rebuild'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        for (final event in events) ...[
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.all(20),
              onTap: () => _showEventAssets(context, event),
              leading: const Icon(Icons.event_outlined),
              title: Text(event.title),
              subtitle: Text(
                '${formatter.format(event.startAt)} - ${formatter.format(event.endAt)} • ${event.assetIds.length} assets • ${event.peopleIds.length} people',
              ),
              trailing: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Chip(label: Text(event.titleSource)),
                  IconButton(
                    tooltip: 'Rename occasion',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => _showRenameDialog(context, event),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  Future<void> _showEventAssets(
    BuildContext context,
    EventCluster event,
  ) async {
    final assetsFuture = onFetchEventAssets(event.id);
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(event.title),
          content: SizedBox(
            width: 920,
            child: FutureBuilder<List<Asset>>(
              future: assetsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snapshot.hasError) {
                  return Text(
                      'Unable to load occasion assets: ${snapshot.error}');
                }

                final assets = snapshot.data ?? const [];
                if (assets.isEmpty) {
                  return const EmptyStatePanel(
                    icon: Icons.photo_library_outlined,
                    title: 'No assets in this occasion',
                    message:
                        'Rebuild events after importing media or correcting timestamps.',
                  );
                }

                return SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${assets.length} local asset(s) in this occasion. Event grouping is rebuildable and titles survive rebuilds.',
                      ),
                      const SizedBox(height: 16),
                      AssetGrid(
                        assets: assets,
                        libraryRoot: libraryRoot,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
            TextButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                _showRenameDialog(context, event);
              },
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Rename'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showRenameDialog(
    BuildContext context,
    EventCluster event,
  ) async {
    final controller = TextEditingController(text: event.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Rename occasion'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Occasion title',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Save title'),
            ),
          ],
        );
      },
    );

    if (newTitle == null || newTitle.trim().isEmpty) {
      return;
    }
    await onTitleEvent(event.id, newTitle.trim());
  }
}
