import 'package:flutter_test/flutter_test.dart';
import 'package:private_gallery_app/src/models/gallery_models.dart';

void main() {
  test('parses timeline response payload', () {
    final response = TimelineResponse.fromJson({
      'buckets': [
        {
          'label': 'January 2025',
          'asset_ids': ['asset-1'],
          'assets': [
            {
              'id': 'asset-1',
              'original_filename': 'beach.jpg',
              'relative_original_path': 'objects/a/b/beach.jpg',
              'content_hash': 'hash',
              'media_kind': 'photo',
              'bytes': 100,
              'mime_type': 'image/jpeg',
              'captured_at': '2025-01-03T09:30:00Z',
              'imported_at': '2025-01-03T10:30:00Z',
              'archived': false,
              'favorite': true,
              'place_hint': 'Goa',
              'metadata': {
                'asset_id': 'asset-1',
                'captured_at': '2025-01-03T09:30:00Z',
                'captured_at_source': 'takeout_sidecar',
                'width': 4000,
                'height': 3000,
                'camera': {'make': 'Google', 'model': 'Pixel'},
                'geo': {
                  'latitude': 15.2993,
                  'longitude': 74.1240,
                  'source': 'takeout_sidecar',
                  'exact_hidden': false,
                },
                'model_name': 'metadata-extractor',
                'model_version': 'v1',
                'created_at': '2025-01-03T10:35:00Z',
                'rebuildable': true,
              },
              'variants': [
                {
                  'id': 'variant-1',
                  'kind': 'thumbnail',
                  'relative_path': 'variants/thumbs/beach.webp',
                  'mime_type': 'image/webp',
                  'bytes': 10,
                  'width': 480,
                  'height': 480,
                  'model_name': 'thumb',
                  'model_version': 'v1',
                  'created_at': '2025-01-03T10:35:00Z',
                  'rebuildable': true,
                },
              ],
            },
          ],
        },
      ],
    });

    expect(response.buckets.single.assets.single.originalFilename, 'beach.jpg');
    expect(response.buckets.single.assets.single.variants.single.kind,
        'thumbnail');
    expect(response.buckets.single.assets.single.metadata?.capturedAtSource,
        'takeout_sidecar');
    expect(
        response.buckets.single.assets.single.metadata?.geo?.latitude, 15.2993);
  });

  test('parses import session preflight fields with fallback safety', () {
    final session = ImportSession.fromJson({
      'id': 'session-1',
      'source_kind': 'folder',
      'source_path': '/tmp/source',
      'import_mode': 'move',
      'add_as_watch_folder': false,
      'status': 'scanned',
      'created_at': '2026-05-10T10:00:00Z',
      'candidates': [
        {
          'id': 'candidate-1',
          'session_id': 'session-1',
          'source_path': '/tmp/source/a.jpg',
          'original_filename': 'a.jpg',
          'media_kind': 'photo',
          'mime_type': 'image/jpeg',
          'bytes': 100,
          'content_hash': 'hash-a',
          'selected': true,
          'import_mode': 'move',
          'sidecar_paths': ['/tmp/source/a.jpg.json'],
          'safety_status': 'ready_to_move_verified_after_commit',
        },
        {
          'id': 'candidate-2',
          'session_id': 'session-1',
          'source_path': '/tmp/source/b.jpg',
          'original_filename': 'b.jpg',
          'media_kind': 'photo',
          'mime_type': 'image/jpeg',
          'bytes': 200,
          'content_hash': 'hash-b',
          'duplicate_asset_id': 'asset-1',
          'selected': true,
          'import_mode': 'move',
          'sidecar_paths': [],
          'safety_status': 'duplicate_skip',
        },
      ],
      'imported_asset_ids': [],
      'duplicate_asset_ids': [],
      'moved_asset_ids': [],
      'skipped_duplicate_ids': [],
      'failed_candidate_ids': [],
      'sidecars_moved': 0,
      'unsupported_file_paths': ['/tmp/source/desktop.ini'],
      'destination_root': '/tmp/source/PrivateGalleryLibrary',
      'requires_move_confirmation': true,
      'source_contains_managed_library': true,
    });

    expect(session.selectedCandidateCount, 1);
    expect(session.selectedBytes, 100);
    expect(session.duplicateCount, 1);
    expect(session.unsupportedCount, 1);
    expect(session.sidecarCount, 1);
    expect(session.requiresMoveConfirmation, isTrue);
    expect(session.sourceContainsManagedLibrary, isTrue);
  });

  test('parses privacy status and model governance fields', () {
    final status = PrivacyStatus.fromJson({
      'network_policy': 'ask_before_download',
      'daemon_bind_address': '127.0.0.1:4821',
      'loopback_only': true,
      'developer_mode': false,
      'photo_processing_network_allowed': false,
      'model_download_requires_confirmation': true,
      'telemetry_enabled': false,
      'analytics_enabled': false,
      'cloud_ai_enabled': false,
      'local_only_disclosure': 'Everything stays local.',
      'installed_models': [
        {
          'id': 'scrfd-face-detector',
          'name': 'SCRFD face detector candidate',
          'version': 'onnx-personal-review',
          'task': 'face_detection',
          'license': 'review required',
          'source_url': 'https://example.invalid/model.onnx',
          'expected_sha256': 'abc123',
          'installed_path': '/tmp/model.onnx',
          'installed_sha256': 'abc123',
          'install_status': 'installed',
          'review_notes': 'Personal use only.',
          'approved_for_personal_family_use': true,
        },
      ],
    });

    expect(status.localOnlyHealthy, isTrue);
    expect(status.networkPolicy, NetworkPolicy.askBeforeDownload);
    expect(status.installedModels.single.installed, isTrue);
    expect(status.installedModels.single.task, ModelTask.faceDetection);
    expect(status.installedModels.single.installStatus,
        ModelInstallStatus.installed);
  });

  test('parses search index OCR coverage fields with safe defaults', () {
    final status = SearchIndexStatus.fromJson({
      'filename_ready': true,
      'metadata_ready': true,
      'ocr_ready': true,
      'ocr_text_block_count': 9,
      'ocr_indexed_asset_count': 9,
      'ocr_total_photo_count': 50434,
      'ocr_remaining_photo_count': 50425,
      'scene_ready': false,
      'semantic_ready': false,
      'updated_at': '2026-05-12T15:00:00Z',
      'detail': 'OCR is partial.',
    });

    expect(status.ocrReady, isTrue);
    expect(status.ocrTextBlockCount, 9);
    expect(status.ocrIndexedAssetCount, 9);
    expect(status.ocrTotalPhotoCount, 50434);
    expect(status.ocrRemainingPhotoCount, 50425);
    expect(status.ocrPartiallyIndexed, isTrue);
  });

  test('parses distributed vault sync and availability fields', () {
    final vault = Vault.fromJson({
      'id': 'vault-1',
      'name': 'Family',
      'storage_policy': {
        'mode': 'protected_min_2',
        'min_replicas': 2,
        'preferred_device_ids': ['device-2'],
        'excluded_device_ids': [],
        'min_free_space_bytes': 1024,
        'allow_metered_network': false,
        'pause_on_low_battery': true,
      },
      'key_version': 1,
      'deletion_grace_days': 30,
      'created_at': '2026-05-13T06:00:00Z',
      'updated_at': '2026-05-13T06:00:00Z',
    });
    final device = DeviceIdentity.fromJson({
      'id': 'device-2',
      'display_name': 'NAS',
      'platform': 'linux',
      'public_key': 'nas-key',
      'trust_level': 'storage_only',
      'storage_profile': {
        'device_id': 'device-2',
        'available_bytes': 90000,
        'reserved_bytes': 1024,
        'accepts_storage': true,
        'battery_powered': false,
        'metered_network': false,
        'low_battery': false,
      },
      'enrolled_at': '2026-05-13T06:00:00Z',
    });
    final plan = SyncPlan.fromJson({
      'generated_at': '2026-05-13T06:00:00Z',
      'vault_ids': ['vault-1'],
      'transfers': [
        {
          'id': 'transfer-1',
          'vault_id': 'vault-1',
          'blob_id': 'blob-1',
          'from_device_id': 'device-1',
          'to_device_id': 'device-2',
          'status': 'pending',
          'bytes_total': 100,
          'bytes_completed': 0,
          'updated_at': '2026-05-13T06:00:00Z',
          'resumable_until': '2026-05-20T06:00:00Z',
        }
      ],
      'conflicts': [],
      'under_replicated_blob_ids': ['blob-1'],
      'policy_satisfied': false,
      'detail': 'pending transfer',
    });
    final availability = AssetAvailability.fromJson({
      'asset_id': 'asset-1',
      'vault_id': 'vault-1',
      'state': 'under_replicated',
      'local_replica': true,
      'reachable_replica_device_ids': [],
      'offline_replica_device_ids': [],
      'replica_count': 1,
      'required_replica_count': 2,
      'detail': 'only one replica',
    });

    expect(vault.storagePolicy.mode, StoragePolicyMode.protectedMin2);
    expect(vault.storagePolicy.preferredDeviceIds, ['device-2']);
    expect(device.trustLevel, DeviceTrustLevel.storageOnly);
    expect(device.storageProfile.acceptsStorage, isTrue);
    expect(plan.transfers.single.toDeviceId, 'device-2');
    expect(plan.underReplicatedBlobIds, ['blob-1']);
    expect(availability.state, AssetAvailabilityState.underReplicated);
    expect(availability.opensLocally, isTrue);
  });
}
