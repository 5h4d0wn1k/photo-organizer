import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:private_gallery_app/src/app/private_gallery_app.dart';
import 'package:private_gallery_app/src/features/mobile/mobile_gallery_panel.dart';
import 'package:private_gallery_app/src/features/mobile/mobile_media_viewer.dart';
import 'package:private_gallery_app/src/features/mobile/mobile_pairing_screen.dart';
import 'package:private_gallery_app/src/features/mobile/mobile_workspace_panel.dart';
import 'package:private_gallery_app/src/models/device_group_invite.dart';
import 'package:private_gallery_app/src/models/gallery_models.dart';
import 'package:private_gallery_app/src/services/cloud_bootstrap_service.dart';

void main() {
  testWidgets('shows bootstrap progress first', (WidgetTester tester) async {
    await tester.pumpWidget(
      const PrivateGalleryApp(mode: GalleryClientMode.desktop),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('shows mobile pairing when mobile mode is selected', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const PrivateGalleryApp(mode: GalleryClientMode.mobile),
    );

    expect(find.text('Welcome to Private Gallery'), findsOneWidget);
    expect(find.text('Create New Group'), findsOneWidget);
    expect(find.text('Join Existing Group'), findsOneWidget);
    expect(find.text('Browse This Device'), findsOneWidget);
  });

  testWidgets('mobile create group uses metadata-only cloud bootstrap', (
    WidgetTester tester,
  ) async {
    final cloud = _FakeCloudBootstrap();
    await tester.pumpWidget(
      MaterialApp(home: MobilePairingScreen(cloud: cloud)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Create New Group'));
    await tester.pumpAndSettle();

    expect(cloud.createdGroups, 1);
    expect(cloud.createdInvites, 1);
    expect(find.text('My Private Gallery'), findsWidgets);
  });

  testWidgets('mobile gallery panel renders paired group media', (
    WidgetTester tester,
  ) async {
    MobileAssetSummary? opened;
    final asset = _mobileAsset();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MobileGalleryPanel(
            assets: [asset],
            loading: false,
            busy: false,
            onRefresh: () {},
            onUploadNewestItem: () {},
            onCheckSession: () {},
            onOpenAsset: (asset) => opened = asset,
          ),
        ),
      ),
    );

    expect(find.text('1 item'), findsOneWidget);
    expect(find.text('family.jpg'), findsWidgets);
    expect(find.widgetWithText(FilledButton, 'Refresh'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Upload'), findsOneWidget);

    await tester.tap(find.text('family.jpg'));
    await tester.pump();

    expect(opened, asset);
  });

  testWidgets('mobile gallery panel has an empty group state', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MobileGalleryPanel(
            assets: const [],
            loading: false,
            busy: false,
            onUploadNewestItem: () {},
          ),
        ),
      ),
    );

    expect(find.text('0 items'), findsOneWidget);
    expect(find.text('No group media yet'), findsOneWidget);
  });

  testWidgets('mobile workspace panel exposes group surfaces', (
    WidgetTester tester,
  ) async {
    var searches = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              MobileWorkspacePanel(
                workspace: _workspace(),
                loading: false,
                busy: false,
                onRefresh: () {},
                onUploadNewestItem: () {},
                onCheckSession: () {},
                onSearch: (query) async {
                  searches += 1;
                  return SearchResponse.fromJson(_searchJson());
                },
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Family group'), findsOneWidget);
    expect(find.text('family.jpg'), findsWidgets);

    await tester.tap(find.widgetWithText(NavigationDestination, 'Devices'));
    await tester.pumpAndSettle();
    expect(find.text('Not seen on LAN'), findsWidgets);

    await tester.tap(find.widgetWithText(NavigationDestination, 'Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'family');
    await tester.tap(find.widgetWithIcon(IconButton, Icons.search));
    await tester.pumpAndSettle();

    expect(searches, 1);
    expect(find.text('family.jpg'), findsOneWidget);
  });

  testWidgets('mobile media viewer exposes gallery-style photo actions', (
    WidgetTester tester,
  ) async {
    final asset = _mobileAsset(available: false);

    await tester.pumpWidget(
      MaterialApp(
        home: MobileMediaViewer.group(
          asset: asset,
          loadOriginalFile: () async => throw StateError('not available'),
          saveOriginal: () async => throw StateError('not available'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('family.jpg'), findsWidgets);
    expect(find.text('Share'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    final topShareButton = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == 'Share',
    );
    expect(tester.widget<IconButton>(topShareButton).onPressed, null);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Share'))
          .onPressed,
      null,
    );

    await tester.tap(find.byIcon(Icons.info_outline).first);
    await tester.pumpAndSettle();

    expect(find.text('Filename'), findsOneWidget);
    expect(find.text('Same-LAN group'), findsOneWidget);
    expect(find.text('Photo stored elsewhere'), findsOneWidget);
  });

  testWidgets('mobile media viewer has a video playback state', (
    WidgetTester tester,
  ) async {
    final asset = _mobileAsset(
      mediaKind: 'video',
      mimeType: 'video/mp4',
      available: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MobileMediaViewer.group(
          asset: asset,
          loadOriginalFile: () async => throw StateError('not available'),
          saveOriginal: () async => throw StateError('not available'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Video stored elsewhere'), findsOneWidget);
    expect(find.text('Trim'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Trim'))
          .onPressed,
      null,
    );
  });
}

MobileAssetSummary _mobileAsset({
  String mediaKind = 'photo',
  String mimeType = 'image/jpeg',
  bool available = true,
}) {
  return MobileAssetSummary(
    assetId: 'asset-1',
    originalFilename: 'family.jpg',
    mediaKind: mediaKind,
    mimeType: mimeType,
    bytes: 2048,
    contentHash: 'hash-1',
    capturedAt: DateTime.utc(2026, 5, 13, 6),
    available: available,
  );
}

MobileWorkspaceSnapshot _workspace() {
  return MobileWorkspaceSnapshot.fromJson({
    'session': {
      'id': 'session-1',
      'device_id': 'phone-1',
      'vault_id': 'vault-1',
      'display_name': 'Phone',
      'platform': 'android',
      'created_at': '2026-05-13T06:00:00Z',
      'expires_at': '2027-05-13T06:00:00Z',
      'last_seen_at': '2026-05-13T06:01:00Z',
      'revoked_at': null,
    },
    'timeline': {
      'buckets': [
        {
          'label': 'May 2026',
          'asset_ids': ['asset-1'],
          'assets': [_assetJson()],
          'total_assets': 1,
        },
      ],
      'next_cursor': null,
      'total_assets': 1,
      'returned_assets': 1,
    },
    'albums': [
      {
        'id': 'album-1',
        'title': 'Family',
        'asset_ids': ['asset-1'],
        'cover_asset_id': 'asset-1',
        'created_at': '2026-05-13T06:00:00Z',
        'updated_at': '2026-05-13T06:00:00Z',
      },
    ],
    'people': [],
    'places': [],
    'events': [],
    'jobs': [
      {
        'id': 'job-1',
        'kind': 'import',
        'status': 'completed',
        'progress': 100,
        'queued_at': '2026-05-13T06:00:00Z',
        'started_at': '2026-05-13T06:00:00Z',
        'completed_at': '2026-05-13T06:00:01Z',
        'detail': 'import complete',
        'cancel_requested': false,
        'retry_of_job_id': null,
        'attempt': 1,
      },
    ],
    'vault_status': {
      'vault': {
        'id': 'vault-1',
        'name': 'Family group',
        'storage_policy': {
          'mode': 'protected_min_2',
          'min_replicas': 2,
          'preferred_device_ids': [],
          'excluded_device_ids': [],
          'min_free_space_bytes': 0,
          'allow_metered_network': false,
          'pause_on_low_battery': true,
        },
        'key_version': 1,
        'deletion_grace_days': 30,
        'created_at': '2026-05-13T06:00:00Z',
        'updated_at': '2026-05-13T06:00:00Z',
      },
      'members': [],
      'devices': [_deviceJson()],
      'assets_total': 1,
      'blobs_total': 1,
      'local_available_assets': 1,
      'remote_available_assets': 0,
      'under_replicated_blobs': 1,
      'missing_blobs': 0,
      'policy_satisfied': false,
      'detail': 'needs another copy',
    },
    'devices': [_deviceJson()],
    'sync_network': {
      'started': true,
      'transport': 'local-lan',
      'local_device_id': 'desktop-1',
      'local_node_id': 'node-1',
      'direct_addresses': ['192.168.1.10:4821'],
      'relay_urls': [],
      'active_transfer_count': 0,
      'pending_transfer_count': 0,
      'completed_transfer_count': 0,
      'failed_transfer_count': 0,
      'detail': 'online',
    },
    'capabilities': {
      'can_browse_library': true,
      'can_search': true,
      'can_upload_camera_roll': true,
      'can_download_originals': true,
      'can_manage_storage': false,
      'can_import_desktop_folders': false,
      'can_run_models': false,
      'role_detail': 'mobile contributor',
    },
  });
}

Map<String, Object?> _searchJson() {
  return {
    'query': {'text': 'family', 'include_archived': false, 'limit': 60},
    'assets': [_assetJson()],
    'people': [],
    'places': [],
    'events': [],
  };
}

Map<String, Object?> _assetJson() {
  return {
    'id': 'asset-1',
    'original_filename': 'family.jpg',
    'relative_original_path': 'originals/family.jpg',
    'source_path': '/tmp/family.jpg',
    'import_mode': 'copy',
    'is_available': true,
    'content_hash': 'hash-1',
    'media_kind': 'photo',
    'bytes': 2048,
    'mime_type': 'image/jpeg',
    'captured_at': '2026-05-13T06:00:00Z',
    'imported_at': '2026-05-13T06:00:01Z',
    'archived': false,
    'favorite': false,
    'place_hint': null,
    'variants': [],
  };
}

Map<String, Object?> _deviceJson() {
  return {
    'id': 'desktop-1',
    'display_name': 'Desktop',
    'platform': 'linux',
    'public_key': 'desktop-key',
    'trust_level': 'trusted',
    'storage_profile': {
      'device_id': 'desktop-1',
      'total_bytes': 100000,
      'available_bytes': 90000,
      'reserved_bytes': 0,
      'accepts_storage': true,
      'battery_powered': false,
      'metered_network': false,
      'low_battery': false,
    },
    'enrolled_at': '2026-05-13T06:00:00Z',
    'last_seen_at': null,
    'revoked_at': null,
  };
}

class _FakeCloudBootstrap implements CloudBootstrapGateway {
  var createdGroups = 0;
  var createdInvites = 0;

  @override
  bool get isConfigured => true;

  @override
  Future<CloudDeviceGroup?> loadSavedGroup() async => null;

  @override
  Future<CloudDeviceGroup> createGroup({
    required String groupName,
    required String deviceName,
    required String platform,
  }) async {
    createdGroups += 1;
    return CloudDeviceGroup(
      id: 'group-1',
      name: groupName.trim().isEmpty ? 'My Private Gallery' : groupName,
    );
  }

  @override
  Future<DeviceGroupInvite> createInvite({
    required CloudDeviceGroup group,
  }) async {
    createdInvites += 1;
    return DeviceGroupInvite.cloud(
      groupId: group.id,
      groupName: group.name,
      cloudInviteId: 'invite-1',
      cloudInviteSecret: 'secret-1',
      expiresAt: DateTime.utc(2026, 6, 1, 12),
    );
  }

  @override
  Future<CloudDeviceGroup> joinGroup({
    required DeviceGroupInvite invite,
    required String deviceName,
    required String platform,
  }) async {
    return CloudDeviceGroup(
      id: invite.groupId ?? 'group-1',
      name: invite.groupName,
    );
  }
}
