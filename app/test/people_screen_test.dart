import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_gallery_app/src/features/people/people_screen.dart';
import 'package:private_gallery_app/src/models/gallery_models.dart';

void main() {
  testWidgets('shows face indexing gate and calls index action', (
    WidgetTester tester,
  ) async {
    var indexCalls = 0;
    var resetCalls = 0;
    var createCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PeopleScreen(
            people: const [],
            models: const [
              ModelArtifact(
                id: 'scrfd-face-detector',
                name: 'SCRFD face detector candidate',
                version: 'review',
                task: ModelTask.faceDetection,
                license: 'review required',
                sourceUrl: null,
                expectedSha256: null,
                installedPath: null,
                installedSha256: null,
                installStatus: ModelInstallStatus.pendingReview,
                reviewNotes: 'Not approved yet.',
                approvedForPersonalFamilyUse: false,
              ),
            ],
            libraryRoot: '/tmp/library',
            privacyStatus: _privacyStatus(),
            onIndexPeople: () async {
              indexCalls += 1;
            },
            onResetPeople: () async {
              resetCalls += 1;
            },
            onCreateManualPerson: (_) async {
              createCalls += 1;
            },
            onFetchPersonAssets: (_) async => const [],
            onRemovePersonAssets: (_, {required List<String> assetIds}) async =>
                _person(),
            onPeopleChanged: () async {},
            onRenamePerson: (_, _) async {},
            onHidePerson: (_, _) async {},
            onRejectPersonMatch: (_) async {},
            onMergePerson: (_, _) async {},
            onSplitPerson:
                (_, {required faceTemplateIds, newDisplayName}) async {},
          ),
        ),
      ),
    );

    expect(find.text('Local face indexing is gated'), findsOneWidget);
    expect(find.text('No people yet'), findsOneWidget);

    await tester.tap(find.text('Check face indexing gate'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Reset people data'));
    await tester.pumpAndSettle();
    expect(resetCalls, 0);
    await tester.tap(find.widgetWithText(FilledButton, 'Reset people data'));
    await tester.pumpAndSettle();

    expect(indexCalls, 1);
    expect(resetCalls, 1);
    expect(createCalls, 0);
  });

  testWidgets('creates a manual person without face indexing', (
    WidgetTester tester,
  ) async {
    final createdNames = <String>[];
    var changedCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PeopleScreen(
            people: const [],
            models: const [],
            libraryRoot: '/tmp/library',
            privacyStatus: _privacyStatus(),
            onIndexPeople: () async {},
            onResetPeople: () async {},
            onCreateManualPerson: (name) async {
              createdNames.add(name);
            },
            onFetchPersonAssets: (_) async => const [],
            onRemovePersonAssets: (_, {required List<String> assetIds}) async =>
                _person(),
            onPeopleChanged: () async {
              changedCalls += 1;
            },
            onRenamePerson: (_, _) async {},
            onHidePerson: (_, _) async {},
            onRejectPersonMatch: (_) async {},
            onMergePerson: (_, _) async {},
            onSplitPerson:
                (_, {required faceTemplateIds, newDisplayName}) async {},
          ),
        ),
      ),
    );

    await tester.tap(
      find.widgetWithText(OutlinedButton, 'Create manual person'),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Mom');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(createdNames, ['Mom']);
    expect(changedCalls, 1);
  });

  testWidgets('opens assigned person assets', (WidgetTester tester) async {
    var fetchCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PeopleScreen(
            people: [
              _person(assetIds: const ['asset-1']),
            ],
            models: const [],
            libraryRoot: '/tmp/library',
            privacyStatus: _privacyStatus(),
            onIndexPeople: () async {},
            onResetPeople: () async {},
            onCreateManualPerson: (_) async {},
            onFetchPersonAssets: (_) async {
              fetchCalls += 1;
              return [_asset()];
            },
            onRemovePersonAssets: (_, {required List<String> assetIds}) async =>
                _person(),
            onPeopleChanged: () async {},
            onRenamePerson: (_, _) async {},
            onHidePerson: (_, _) async {},
            onRejectPersonMatch: (_) async {},
            onMergePerson: (_, _) async {},
            onSplitPerson:
                (_, {required faceTemplateIds, newDisplayName}) async {},
          ),
        ),
      ),
    );

    await tester.tap(find.text('Mom'));
    await tester.pumpAndSettle();

    expect(fetchCalls, 1);
    expect(find.text('a.jpg'), findsOneWidget);
    expect(find.textContaining('Select one to remove'), findsOneWidget);
  });

  testWidgets('renaming a person refreshes organization state', (
    WidgetTester tester,
  ) async {
    String? renamed;
    var changedCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PeopleScreen(
            people: [
              _person(assetIds: const ['asset-1']),
            ],
            models: const [],
            libraryRoot: '/tmp/library',
            privacyStatus: _privacyStatus(),
            onIndexPeople: () async {},
            onResetPeople: () async {},
            onCreateManualPerson: (_) async {},
            onFetchPersonAssets: (_) async => const [],
            onRemovePersonAssets: (_, {required List<String> assetIds}) async =>
                _person(),
            onPeopleChanged: () async {
              changedCalls += 1;
            },
            onRenamePerson: (id, name) async {
              renamed = '$id:$name';
            },
            onHidePerson: (_, _) async {},
            onRejectPersonMatch: (_) async {},
            onMergePerson: (_, _) async {},
            onSplitPerson:
                (_, {required faceTemplateIds, newDisplayName}) async {},
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Mom edited');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(renamed, 'person-1:Mom edited');
    expect(changedCalls, 1);
    expect(find.text('Person renamed.'), findsOneWidget);
  });
}

PersonCluster _person({List<String> assetIds = const []}) {
  return PersonCluster(
    id: 'person-1',
    displayName: 'Mom',
    assetIds: assetIds,
    faceTemplateIds: const [],
    representativeAssetId: null,
    hidden: false,
    derived: ModelProvenance(
      modelName: 'manual-person',
      modelVersion: 'v1',
      modelHash: null,
      createdAt: DateTime.utc(2026, 5, 13),
      rebuildable: true,
    ),
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

PrivacyStatus _privacyStatus() {
  return const PrivacyStatus(
    networkPolicy: NetworkPolicy.askBeforeDownload,
    daemonBindAddress: '127.0.0.1:4821',
    loopbackOnly: true,
    developerMode: false,
    remoteMobileAccessEnabled: false,
    photoProcessingNetworkAllowed: false,
    modelDownloadRequiresConfirmation: true,
    telemetryEnabled: false,
    analyticsEnabled: false,
    cloudAiEnabled: false,
    installedModels: [],
    localOnlyDisclosure: 'Everything stays local.',
    encryption: EncryptionStatus(
      databaseEncrypted: true,
      derivedDataEncrypted: true,
      keyStorage: 'os_keychain',
      sensitiveIndexingAllowed: true,
      warning: 'Encrypted.',
    ),
  );
}
