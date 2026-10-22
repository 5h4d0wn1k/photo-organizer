import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:private_gallery_app/src/api/local_api_client.dart';
import 'package:private_gallery_app/src/app/private_gallery_app.dart';
import 'package:private_gallery_app/src/features/files/files_screen.dart';

void main() {
  testWidgets(
    'narrow IndexedStack import navigation refreshes duplicate summary',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final httpClient = _FilesTreeClient()..duplicateCandidates = 2;
      final apiClient = LocalApiClient(
        httpClient: httpClient,
        baseUri: Uri.parse('http://127.0.0.1:4821'),
      );
      var selectedIndex = 0;
      var refreshToken = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) => Scaffold(
              body: Column(
                children: [
                  Expanded(
                    child: IndexedStack(
                      index: selectedIndex,
                      children: [
                        const Center(child: Text('Gallery target')),
                        FilesScreen(
                          apiClient: apiClient,
                          onLibraryChanged: () async {},
                          refreshToken: refreshToken,
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        httpClient.duplicateCandidates = 7;
                        selectedIndex = importLandingIndex(
                          viewDuplicateSummary: true,
                        );
                        refreshToken++;
                      });
                    },
                    child: const Text('Complete duplicate import'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(httpClient.duplicateSummaryRequests, 1);
      expect(importLandingIndex(viewDuplicateSummary: false), 0);
      expect(find.text('Gallery target'), findsOneWidget);

      await tester.tap(find.text('Complete duplicate import'));
      await tester.pumpAndSettle();

      expect(importLandingIndex(viewDuplicateSummary: true), 1);
      expect(httpClient.duplicateSummaryRequests, 2);
      expect(find.text('Duplicate review'), findsOneWidget);
      expect(find.text('7 skipped duplicates across 1 import'), findsOneWidget);
      expect(find.text('Gallery target'), findsNothing);
    },
  );

  testWidgets('shows smart file groups from local organization hints', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final httpClient = _FilesTreeClient();
    final apiClient = LocalApiClient(
      httpClient: httpClient,
      baseUri: Uri.parse('http://127.0.0.1:4821'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: FilesScreen(apiClient: apiClient, onLibraryChanged: () async {}),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('launch-plan.pdf'), findsOneWidget);
    expect(find.text('Duplicate review'), findsOneWidget);
    expect(find.text('2 skipped duplicates across 1 import'), findsOneWidget);
    expect(find.text('4.0 KB'), findsWidgets);
    expect(
      find.textContaining('Device: Office laptop (linux)'),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('File availability').first);
    await tester.pumpAndSettle();

    expect(find.text('File availability'), findsOneWidget);
    expect(find.text('Under-replicated'), findsOneWidget);
    expect(find.text('1/2 replicas'), findsOneWidget);
    expect(find.textContaining('only 1/2 required replicas'), findsOneWidget);

    final evict = find.widgetWithText(OutlinedButton, 'Evict local');
    await tester.ensureVisible(evict);
    await tester.tap(evict);
    await tester.pumpAndSettle();

    expect(httpClient.evictions, 1);
    expect(find.text('Remote reachable'), findsOneWidget);
    expect(find.text('2/2 replicas'), findsOneWidget);

    final pin = find.widgetWithText(FilledButton, 'Pin local');
    await tester.ensureVisible(pin);
    await tester.tap(pin);
    await tester.pumpAndSettle();

    expect(httpClient.pins, 1);
    expect(find.text('Transfer pending'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Smart groups'));
    await tester.pumpAndSettle();

    expect(find.text('Device: Office laptop (linux)'), findsOneWidget);
    expect(find.text('Workspace: Office'), findsOneWidget);
    expect(find.text('Client: Acme'), findsOneWidget);
    expect(find.text('Project: Launch'), findsOneWidget);
    expect(find.text('Type: PDFs'), findsOneWidget);
    expect(find.text('launch-plan.pdf'), findsWidgets);
  });
}

class _FilesTreeClient extends http.BaseClient {
  var evictions = 0;
  var pins = 0;
  var duplicateCandidates = 2;
  var duplicateSummaryRequests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'GET' && request.url.path == '/files/tree') {
      return _jsonResponse({
        'vault_id': 'vault-1',
        'root_entry_ids': ['root-1'],
        'entries': [
          {
            'id': 'root-1',
            'vault_id': 'vault-1',
            'name': 'Office vault',
            'kind': 'folder',
            'bytes': 0,
            'created_at': '2026-05-26T06:00:00Z',
            'updated_at': '2026-05-26T06:00:00Z',
          },
          {
            'id': 'file-1',
            'vault_id': 'vault-1',
            'parent_id': 'root-1',
            'asset_id': 'asset-1',
            'name': 'launch-plan.pdf',
            'kind': 'file',
            'media_kind': 'document',
            'mime_type': 'application/pdf',
            'bytes': 8192,
            'content_hash': 'hash',
            'origin_device_id': 'device-1',
            'created_at': '2026-05-26T06:01:00Z',
            'updated_at': '2026-05-26T06:01:00Z',
            'organization': {
              'source_folder': 'Project Launch',
              'workspace': 'Office',
              'client': 'Acme',
              'project': 'Launch',
              'topic': 'Reports',
              'path_segments': ['Office', 'Acme', 'Launch'],
            },
          },
        ],
        'devices': [
          {
            'id': 'device-1',
            'display_name': 'Office laptop',
            'platform': 'linux',
          },
        ],
      });
    }
    if (request.method == 'GET' && request.url.path == '/duplicates') {
      duplicateSummaryRequests++;
      return _jsonResponse({
        'generated_at': '2026-05-13T06:00:00Z',
        'duplicate_assets': 1,
        'duplicate_candidates': duplicateCandidates,
        'protected_bytes': 4096,
        'sessions_with_duplicates': 1,
        'entries': [
          {
            'asset_id': 'asset-1',
            'media_kind': 'document',
            'original_bytes': 2048,
            'duplicate_candidates': duplicateCandidates,
            'protected_bytes': duplicateCandidates * 2048,
            'first_seen_at': '2026-05-13T06:00:00Z',
            'last_seen_at': '2026-05-13T06:05:00Z',
            'import_session_ids': ['session-1'],
            'source_kinds': ['folder'],
          },
        ],
        'privacy_detail': 'Computed locally.',
      });
    }
    if (request.method == 'GET' &&
        request.url.path == '/assets/asset-1/availability') {
      return _jsonResponse(_availabilityJson());
    }
    if (request.method == 'POST' &&
        request.url.path == '/assets/asset-1/evict-local') {
      evictions += 1;
      return _jsonResponse(
        _availabilityJson(
          state: 'remote_available',
          localReplica: false,
          replicaCount: 2,
          detail: 'original is stored on another reachable device',
          reachableReplicaDeviceIds: ['device-1'],
        ),
      );
    }
    if (request.method == 'POST' &&
        request.url.path == '/assets/asset-1/pin-local') {
      pins += 1;
      return _jsonResponse(
        _availabilityJson(
          state: 'transfer_pending',
          localReplica: false,
          replicaCount: 2,
          detail: 'a local pin or replica transfer is pending',
          reachableReplicaDeviceIds: ['device-1'],
        ),
      );
    }
    return _jsonResponse({'error': 'not found'}, statusCode: 404);
  }

  Map<String, Object?> _availabilityJson({
    String state = 'under_replicated',
    bool localReplica = true,
    int replicaCount = 1,
    int requiredReplicaCount = 2,
    String detail =
        'original opens locally, but only 1/2 required replicas are healthy',
    List<String> reachableReplicaDeviceIds = const [],
    List<String> offlineReplicaDeviceIds = const [],
  }) {
    return {
      'asset_id': 'asset-1',
      'vault_id': 'vault-1',
      'state': state,
      'local_replica': localReplica,
      'reachable_replica_device_ids': reachableReplicaDeviceIds,
      'offline_replica_device_ids': offlineReplicaDeviceIds,
      'replica_count': replicaCount,
      'required_replica_count': requiredReplicaCount,
      'detail': detail,
    };
  }

  http.StreamedResponse _jsonResponse(Object body, {int statusCode = 200}) {
    final bytes = utf8.encode(jsonEncode(body));
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      statusCode,
      headers: {'content-type': 'application/json'},
    );
  }
}
