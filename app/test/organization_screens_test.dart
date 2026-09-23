import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_gallery_app/src/features/events/events_screen.dart';
import 'package:private_gallery_app/src/features/places/places_screen.dart';
import 'package:private_gallery_app/src/models/gallery_models.dart';

void main() {
  testWidgets('events screen can retitle an occasion', (tester) async {
    String? savedTitle;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EventsScreen(
            events: [_event()],
            libraryRoot: '/tmp/library',
            onFetchEventAssets: (_) async => [_asset()],
            onRebuildEvents: () async {},
            onTitleEvent: (id, title) async {
              savedTitle = '$id:$title';
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Rename occasion'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Birthday dinner');
    await tester.tap(find.text('Save title'));
    await tester.pumpAndSettle();

    expect(savedTitle, 'event-1:Birthday dinner');
  });

  testWidgets('places screen can save a manual place correction',
      (tester) async {
    String? saved;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlacesScreen(
            places: [_place()],
            libraryRoot: '/tmp/library',
            onFetchPlaceAssets: (_) async => [_asset()],
            onRebuildPlaces: () async {},
            onCorrectPlace: (
              id, {
              required label,
              latitude,
              longitude,
              hideExactGps,
            }) async {
              saved = '$id:$label:$hideExactGps';
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Correct place'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Home'), 'Goa trip');
    await tester.tap(find.text('Save correction'));
    await tester.pumpAndSettle();

    expect(saved, 'place-1:Goa trip:true');
  });

  testWidgets('events screen opens occasion assets', (tester) async {
    var fetchCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EventsScreen(
            events: [_event()],
            libraryRoot: '/tmp/library',
            onFetchEventAssets: (_) async {
              fetchCalls += 1;
              return [_asset()];
            },
            onRebuildEvents: () async {},
            onTitleEvent: (_, _) async {},
          ),
        ),
      ),
    );

    await tester.tap(find.text('Untitled event'));
    await tester.pumpAndSettle();

    expect(fetchCalls, 1);
    expect(find.text('a.jpg'), findsOneWidget);
  });

  testWidgets('places screen opens place assets', (tester) async {
    var fetchCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlacesScreen(
            places: [_place()],
            libraryRoot: '/tmp/library',
            onFetchPlaceAssets: (_) async {
              fetchCalls += 1;
              return [_asset()];
            },
            onRebuildPlaces: () async {},
            onCorrectPlace: (
              id, {
              required label,
              latitude,
              longitude,
              hideExactGps,
            }) async {},
          ),
        ),
      ),
    );

    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();

    expect(fetchCalls, 1);
    expect(find.text('a.jpg'), findsOneWidget);
  });
}

EventCluster _event() {
  return EventCluster(
    id: 'event-1',
    title: 'Untitled event',
    titleSource: 'generated',
    assetIds: const ['asset-1'],
    startAt: DateTime.utc(2026, 5, 13),
    endAt: DateTime.utc(2026, 5, 13, 2),
    placeId: null,
    peopleIds: const [],
    derived: _derived(),
  );
}

PlaceCluster _place() {
  return PlaceCluster(
    id: 'place-1',
    label: 'Home',
    countryCode: null,
    region: null,
    assetIds: const ['asset-1'],
    centroidLatitude: null,
    centroidLongitude: null,
    derived: _derived(),
  );
}

ModelProvenance _derived() {
  return ModelProvenance(
    modelName: 'test',
    modelVersion: '1',
    modelHash: null,
    createdAt: DateTime.utc(2026, 5, 13),
    rebuildable: true,
  );
}

Asset _asset() {
  return Asset(
    id: 'asset-1',
    originalFilename: 'a.jpg',
    relativeOriginalPath: 'originals/2026/05/a.jpg',
    sourcePath: '/tmp/a.jpg',
    importMode: ImportMode.reference,
    isAvailable: true,
    contentHash: 'hash-a',
    mediaKind: 'photo',
    bytes: 100,
    mimeType: 'image/jpeg',
    capturedAt: DateTime.utc(2026, 5, 13),
    importedAt: DateTime.utc(2026, 5, 13, 1),
    archived: false,
    favorite: false,
    placeHint: null,
    metadata: null,
    variants: const [],
  );
}
