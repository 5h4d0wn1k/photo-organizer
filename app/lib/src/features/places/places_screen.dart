import 'package:flutter/material.dart';

import '../../models/gallery_models.dart';
import '../../widgets/asset_grid.dart';
import '../../widgets/empty_state_panel.dart';

class PlacesScreen extends StatelessWidget {
  const PlacesScreen({
    super.key,
    required this.places,
    required this.libraryRoot,
    required this.onFetchPlaceAssets,
    required this.onRebuildPlaces,
    required this.onCorrectPlace,
  });

  final List<PlaceCluster> places;
  final String libraryRoot;
  final Future<List<Asset>> Function(String id) onFetchPlaceAssets;
  final Future<void> Function() onRebuildPlaces;
  final Future<void> Function(
    String id, {
    required String label,
    double? latitude,
    double? longitude,
    bool? hideExactGps,
  }) onCorrectPlace;

  @override
  Widget build(BuildContext context) {
    if (places.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const EmptyStatePanel(
              icon: Icons.place_outlined,
              title: 'No place clusters yet',
              message:
                  'Places stay empty until imports include EXIF coordinates or manual place hints. The client now shows the live API state instead of generated travel examples.',
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRebuildPlaces,
              icon: const Icon(Icons.travel_explore_outlined),
              label: const Text('Rebuild local places'),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                const Icon(Icons.public_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${places.length} local place clusters. Use corrections for coarse/private labels; no online geocoding is used.',
                  ),
                ),
                FilledButton.icon(
                  onPressed: onRebuildPlaces,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Rebuild'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        for (final place in places) ...[
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.all(20),
              onTap: () => _showPlaceAssets(context, place),
              leading: const Icon(Icons.place_outlined),
              title: Text(place.label),
              subtitle: Text(
                '${place.region ?? 'Unknown region'} • ${place.assetIds.length} assets',
              ),
              trailing: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (place.countryCode != null)
                    Chip(label: Text(place.countryCode!)),
                  IconButton(
                    tooltip: 'Correct place',
                    icon: const Icon(Icons.edit_location_alt_outlined),
                    onPressed: () => _showCorrectDialog(context, place),
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

  Future<void> _showPlaceAssets(
    BuildContext context,
    PlaceCluster place,
  ) async {
    final assetsFuture = onFetchPlaceAssets(place.id);
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(place.label),
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
                  return Text('Unable to load place assets: ${snapshot.error}');
                }

                final assets = snapshot.data ?? const [];
                if (assets.isEmpty) {
                  return const EmptyStatePanel(
                    icon: Icons.photo_library_outlined,
                    title: 'No assets in this place',
                    message:
                        'Rebuild places after importing media with EXIF GPS, Takeout sidecars, or manual place hints.',
                  );
                }

                return SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${assets.length} local asset(s). Places are coarse/private by default and do not use online geocoding.',
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
                _showCorrectDialog(context, place);
              },
              icon: const Icon(Icons.edit_location_alt_outlined),
              label: const Text('Correct'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showCorrectDialog(
    BuildContext context,
    PlaceCluster place,
  ) async {
    final labelController = TextEditingController(text: place.label);
    final latitudeController = TextEditingController(
      text: place.centroidLatitude?.toString() ?? '',
    );
    final longitudeController = TextEditingController(
      text: place.centroidLongitude?.toString() ?? '',
    );
    var hideExactGps = true;

    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Correct place'),
              content: SizedBox(
                width: 520,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: labelController,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Place label',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: latitudeController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Latitude (optional)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: longitudeController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Longitude (optional)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: hideExactGps,
                      title: const Text('Hide exact GPS by default'),
                      onChanged: (value) {
                        setDialogState(() => hideExactGps = value ?? true);
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Save correction'),
                ),
              ],
            );
          },
        );
      },
    );

    final label = labelController.text.trim();
    final latitude = double.tryParse(latitudeController.text.trim());
    final longitude = double.tryParse(longitudeController.text.trim());

    if (shouldSave != true || label.isEmpty) {
      return;
    }
    await onCorrectPlace(
      place.id,
      label: label,
      latitude: latitude,
      longitude: longitude,
      hideExactGps: hideExactGps,
    );
  }
}
