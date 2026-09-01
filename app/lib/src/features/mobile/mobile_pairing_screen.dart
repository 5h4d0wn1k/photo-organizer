import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../api/local_api_client.dart';
import '../../models/device_group_invite.dart';
import '../../models/gallery_models.dart'
    show
        Asset,
        Album,
        DeviceIdentity,
        DeviceStorageProfile,
        EventCluster,
        JobRecord,
        MobileAssetSummary,
        MobilePairResponse,
        MobileReplicaAssignment,
        MobileReplicaChunkDescriptor,
        MobileUpload,
        MobileUploadStatus,
        MobileWorkspaceSnapshot,
        PersonCluster,
        PlaceCluster,
        SearchQuery,
        SearchResponse,
        VaultFileEntry,
        VaultFileTreeResponse;
import '../../services/cloud_bootstrap_service.dart';
import '../../theme/app_theme.dart';
import 'mobile_gallery_panel.dart';
import 'mobile_media_viewer.dart';
import 'mobile_workspace_panel.dart';

enum _MobileOnboardingMode { overview, join, paired }

enum _MobilePairedTab { gallery, files, search, devices, settings }

enum _MobileGalleryFilter {
  all,
  photos,
  videos,
  documents,
  audio,
  archives,
  text,
  other,
  favorites,
  thisDevice,
}

class MobilePairingScreen extends StatefulWidget {
  const MobilePairingScreen({super.key, this.cloud});

  final CloudBootstrapGateway? cloud;

  @override
  State<MobilePairingScreen> createState() => _MobilePairingScreenState();
}

class _MobilePairingScreenState extends State<MobilePairingScreen> {
  static const _storage = FlutterSecureStorage();
  static const _launchInviteChannel = MethodChannel(
    'private_gallery/launch_invite',
  );
  static const _deviceStorageChannel = MethodChannel(
    'private_gallery/device_storage',
  );
  static const _pairingKey = 'private_gallery.pending_pairing_payload';
  static const _desktopUrlKey = 'private_gallery.desktop_url';
  static const _bearerTokenKey = 'private_gallery.mobile_bearer_token';
  static const _deviceNameKey = 'private_gallery.mobile_device_name';
  static const _localOnlyModeKey = 'private_gallery.local_only_mode';

  final _desktopUrlController = TextEditingController(
    text: 'http://127.0.0.1:4821',
  );
  final _pairingTokenController = TextEditingController();
  final _deviceNameController = TextEditingController(text: 'Android phone');
  final _cloudGroupNameController = TextEditingController(
    text: 'My Private Gallery',
  );
  final _mobileSearchController = TextEditingController();
  final _mobileDiscoverySearchController = TextEditingController();
  late final CloudBootstrapGateway _cloud;

  MobileScannerController? _scannerController;
  _MobileOnboardingMode _mode = _MobileOnboardingMode.overview;
  _MobilePairedTab _pairedTab = _MobilePairedTab.gallery;
  _MobileGalleryFilter _galleryFilter = _MobileGalleryFilter.all;
  var _showManualJoin = false;
  var _scanning = false;
  var _busy = false;
  var _pairingInFlight = false;
  var _loadingGallery = false;
  var _loadingMobileFiles = false;
  var _loadingLocalMedia = false;
  var _pairedSearching = false;
  var _localOnlyMode = false;
  String? _bearerToken;
  String? _status;
  String? _galleryError;
  String? _mobileFileError;
  String? _localMediaError;
  String? _pairedSearchError;
  DeviceGroupInvite? _pendingInvite;
  DeviceGroupInvite? _cloudInvite;
  CloudDeviceGroup? _cloudGroup;
  MobileWorkspaceSnapshot? _mobileWorkspace;
  VaultFileTreeResponse? _mobileFileTree;
  String? _mobileFileFolderId;
  SearchResponse? _pairedSearchResult;
  MobileUpload? _activeUpload;
  String? _activeUploadFilename;
  List<MobileAssetSummary> _mobileAssets = const [];
  List<AssetEntity> _localDeviceAssets = const [];
  List<AssetPathEntity> _localDeviceAlbums = const [];
  var _cancelUploadRequested = false;

  @override
  void initState() {
    super.initState();
    _cloud = widget.cloud ?? CloudBootstrapService();
    _configureLaunchInviteChannel();
    _loadSavedState();
  }

  @override
  void dispose() {
    _desktopUrlController.dispose();
    _pairingTokenController.dispose();
    _deviceNameController.dispose();
    _cloudGroupNameController.dispose();
    _mobileSearchController.dispose();
    _mobileDiscoverySearchController.dispose();
    _scannerController?.dispose();
    super.dispose();
  }

  Future<void> _loadSavedState() async {
    final desktopUrl = await _storage.read(key: _desktopUrlKey);
    final pairingPayload = await _storage.read(key: _pairingKey);
    final bearerToken = await _storage.read(key: _bearerTokenKey);
    final deviceName = await _storage.read(key: _deviceNameKey);
    final localOnlyMode = await _storage.read(key: _localOnlyModeKey);
    final cloudGroup = await _cloud.loadSavedGroup();
    if (!mounted) {
      return;
    }
    setState(() {
      if (desktopUrl != null && desktopUrl.trim().isNotEmpty) {
        _desktopUrlController.text = desktopUrl;
      }
      if (pairingPayload != null && pairingPayload.trim().isNotEmpty) {
        _applyInvite(DeviceGroupInvite.parse(pairingPayload), persist: false);
      }
      if (deviceName != null && deviceName.trim().isNotEmpty) {
        _deviceNameController.text = deviceName;
      }
      _bearerToken = bearerToken;
      _localOnlyMode = localOnlyMode == 'true';
      _cloudGroup = cloudGroup;
      if (bearerToken != null && bearerToken.isNotEmpty) {
        _mode = _MobileOnboardingMode.paired;
        _status = 'Saved local group session loaded.';
      } else if (cloudGroup != null) {
        _status =
            'Metadata group ${cloudGroup.name} is ready. Add a desktop or storage device to begin private backup.';
      }
    });
    await _consumeInitialLaunchInvite();
    if (!mounted) {
      return;
    }
    Future<void>.delayed(Duration.zero, () async {
      await _refreshLocalDeviceMedia(requestPermission: true);
      final token = _bearerToken;
      if (token != null && token.isNotEmpty) {
        await _refreshMobileGallery();
      }
    });
  }

  void _configureLaunchInviteChannel() {
    if (!Platform.isAndroid) {
      return;
    }
    _launchInviteChannel.setMethodCallHandler((call) async {
      if (call.method == 'privateGalleryInvite') {
        await _handleLaunchInvite(call.arguments);
      }
    });
  }

  Future<void> _consumeInitialLaunchInvite() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      final payload = await _launchInviteChannel.invokeMethod<Object?>(
        'consumeInitialInvite',
      );
      await _handleLaunchInvite(payload);
    } on MissingPluginException {
      return;
    }
  }

  Future<void> _handleLaunchInvite(Object? raw) async {
    final payload = _stringKeyMap(raw);
    if (payload == null || !mounted) {
      return;
    }

    final desktopUrl = _readNonEmpty(payload['desktopUrl']);
    final bearerToken = _readNonEmpty(payload['bearerToken']);
    final deviceName = _readNonEmpty(payload['deviceName']);
    if (desktopUrl != null && bearerToken != null) {
      if (!kDebugMode) {
        setState(() {
          _status =
              'Direct mobile session injection is available in debug builds only.';
        });
        return;
      }
      await _storage.write(key: _desktopUrlKey, value: desktopUrl);
      await _storage.write(key: _bearerTokenKey, value: bearerToken);
      if (deviceName != null) {
        await _storage.write(key: _deviceNameKey, value: deviceName);
      }
      await _storage.delete(key: _pairingKey);
      await _writeDebugPairingMarker(
        desktopUrl: desktopUrl,
        deviceName: deviceName,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _desktopUrlController.text = desktopUrl;
        if (deviceName != null) {
          _deviceNameController.text = deviceName;
        }
        _bearerToken = bearerToken;
        _pendingInvite = null;
        _mode = _MobileOnboardingMode.paired;
        _status = 'Debug device session loaded for ${deviceName ?? 'Android'}.';
      });
      await _refreshMobileGallery();
      return;
    }

    final pairingPayload = _readNonEmpty(payload['pairingPayload']);
    if (pairingPayload == null) {
      return;
    }
    try {
      final invite = DeviceGroupInvite.parse(pairingPayload);
      await _storage.write(key: _pairingKey, value: invite.encode());
      if (!mounted) {
        return;
      }
      setState(() {
        _applyInvite(invite, persist: false);
        _mode = _MobileOnboardingMode.join;
        _showManualJoin = true;
        _status = 'Local invite loaded from Android.';
      });
      if (payload['autoPair'] == true) {
        await _pairWithDesktop();
      }
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = error.message;
      });
    }
  }

  Map<String, Object?>? _stringKeyMap(Object? raw) {
    if (raw == null) {
      return null;
    }
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    return null;
  }

  String? _readNonEmpty(Object? raw) {
    if (raw is! String) {
      return null;
    }
    final value = raw.trim();
    return value.isEmpty ? null : value;
  }

  Future<void> _writeDebugPairingMarker({
    required String desktopUrl,
    String? deviceName,
  }) async {
    if (!kDebugMode) {
      return;
    }
    final root = await getApplicationSupportDirectory();
    final marker = File(
      '${root.path}/private_gallery_mobile_pairing_status.json',
    );
    await marker.writeAsString(
      jsonEncode({
        'desktop_url': desktopUrl,
        'device_name': deviceName,
        'token_present': true,
        'paired_at': DateTime.now().toUtc().toIso8601String(),
      }),
    );
  }

  LocalApiClient _client() {
    final uri = Uri.tryParse(_desktopUrlController.text.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const FormatException('Enter the desktop URL from the invite.');
    }
    return LocalApiClient(baseUri: uri);
  }

  Future<DeviceStorageProfile> _phoneStorageProfile({
    required bool acceptsStorage,
  }) async {
    int? totalBytes;
    int? availableBytes;
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final result = await _deviceStorageChannel
            .invokeMapMethod<String, Object?>('getStorageProfile');
        totalBytes = (result?['totalBytes'] as num?)?.toInt();
        availableBytes = (result?['availableBytes'] as num?)?.toInt();
      } catch (_) {
        totalBytes = null;
        availableBytes = null;
      }
    }
    return DeviceStorageProfile(
      deviceId: null,
      totalBytes: totalBytes,
      availableBytes: availableBytes,
      reservedBytes: acceptsStorage ? 1024 * 1024 * 1024 : 0,
      acceptsStorage: acceptsStorage,
      batteryPowered: true,
      meteredNetwork: false,
      lowBattery: false,
    );
  }

  Future<void> _scanInviteQr() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      setState(() {
        _status = 'Camera permission is required to scan a group invite QR.';
      });
      return;
    }
    setState(() {
      _scannerController ??= MobileScannerController();
      _mode = _MobileOnboardingMode.join;
      _showManualJoin = false;
      _status = null;
      _scanning = true;
    });
  }

  Future<void> _saveManualInvite() async {
    await _saveInvitePayload(_pairingTokenController.text);
  }

  Future<void> _saveInvitePayload(String payload) async {
    try {
      final invite = DeviceGroupInvite.parse(payload);
      if (invite.isExpired) {
        setState(() {
          _status = 'This invite expired. Create a fresh invite.';
        });
        return;
      }
      await _storage.write(key: _pairingKey, value: invite.encode());
      final stopFuture = _scannerController?.stop();
      await stopFuture;
      if (!mounted) {
        return;
      }
      setState(() {
        _applyInvite(invite, persist: false);
        _scanning = false;
        _mode = _MobileOnboardingMode.join;
        _showManualJoin = true;
        _status = invite.supportsCloud && !invite.supportsLan
            ? 'Cloud invite saved. Join the metadata group to continue.'
            : 'Local invite saved. Pair with the desktop group to continue.';
      });
    } on FormatException catch (error) {
      setState(() {
        _status = error.message;
      });
    }
  }

  void _applyInvite(DeviceGroupInvite invite, {required bool persist}) {
    _pendingInvite = invite;
    if (invite.baseUrl != null && invite.baseUrl!.trim().isNotEmpty) {
      _desktopUrlController.text = invite.baseUrl!.trim();
    }
    if (invite.pairingToken != null && invite.pairingToken!.trim().isNotEmpty) {
      _pairingTokenController.text = invite.pairingToken!.trim();
    }
    if (persist) {
      _storage.write(key: _pairingKey, value: invite.encode()).ignore();
    }
  }

  Future<void> _createCloudGroup() async {
    await _runBusy(() async {
      final group = await _cloud.createGroup(
        groupName: _cloudGroupNameController.text,
        deviceName: _deviceNameController.text,
        platform: 'android',
      );
      final invite = await _cloud.createInvite(group: group);
      setState(() {
        _cloudGroup = group;
        _cloudInvite = invite;
        _status =
            'Created ${group.name}. This cloud record stores metadata only; add a desktop or storage device before backup starts.';
      });
    });
  }

  Future<void> _startCreateGroup() async {
    if (!_cloud.isConfigured) {
      setState(() {
        _status =
            'Cloud bootstrap is not configured in this build. Create a local group on the desktop, then scan its invite.';
      });
      return;
    }
    await _createCloudGroup();
  }

  Future<void> _joinCloudGroup() async {
    await _runBusy(_joinCloudGroupInternal);
  }

  Future<void> _joinCloudGroupInternal() async {
    final invite = _pendingInvite;
    if (invite == null || !invite.supportsCloud) {
      throw const CloudBootstrapException('Scan a cloud group invite first.');
    }
    final group = await _cloud.joinGroup(
      invite: invite,
      deviceName: _deviceNameController.text,
      platform: 'android',
    );
    setState(() {
      _cloudGroup = group;
      _status =
          'Joined ${group.name}. Add a desktop or storage device before private backup starts.';
    });
  }

  Future<void> _pairWithDesktop() async {
    if (_pairingInFlight) {
      return;
    }
    _pairingInFlight = true;
    try {
      await _runBusy(() async {
        final invite =
            _pendingInvite ??
            DeviceGroupInvite.parse(_pairingTokenController.text.trim());
        if (!invite.supportsLan && invite.supportsCloud) {
          await _joinCloudGroupInternal();
          return;
        }
        if (invite.pairingToken == null || invite.pairingToken!.isEmpty) {
          throw const FormatException(
            'Scan or paste a desktop pairing invite.',
          );
        }
        late final MobilePairResponse response;
        try {
          await _client().fetchHealth();
          response = await _client().pairMobileDevice(
            pairingToken: invite.pairingToken!,
            deviceName: _deviceNameController.text.trim().isEmpty
                ? 'Android phone'
                : _deviceNameController.text.trim(),
            platform: 'android',
            vaultId: invite.vaultId,
          );
        } catch (_) {
          if (invite.supportsCloud) {
            await _joinCloudGroupInternal();
            return;
          }
          rethrow;
        }
        await _storage.write(
          key: _desktopUrlKey,
          value: _desktopUrlController.text.trim(),
        );
        await _storage.write(
          key: _deviceNameKey,
          value: _deviceNameController.text.trim(),
        );
        await _storage.write(key: _bearerTokenKey, value: response.bearerToken);
        await _storage.delete(key: _pairingKey);
        await _writeDebugPairingMarker(
          desktopUrl: _desktopUrlController.text.trim(),
          deviceName: _deviceNameController.text.trim(),
        );
        setState(() {
          _bearerToken = response.bearerToken;
          _mode = _MobileOnboardingMode.paired;
          _status =
              'Joined ${invite.groupName}. Session expires ${response.session.expiresAt.toLocal()}.';
        });
        await _refreshMobileGallery();
      });
    } finally {
      _pairingInFlight = false;
    }
  }

  Future<void> _checkSession() async {
    await _runBusy(() async {
      final token = _requireBearerToken();
      final session = await _client().fetchMobileSession(bearerToken: token);
      setState(() {
        _status =
            'Connected to group ${session.vaultId}. Last seen ${session.lastSeenAt?.toLocal() ?? 'now'}.';
      });
    });
  }

  Future<void> _refreshSession() async {
    await _runBusy(() async {
      final token = _requireBearerToken();
      final refreshed = await _client().refreshMobileSession(
        bearerToken: token,
      );
      await _storage.write(key: _bearerTokenKey, value: refreshed.bearerToken);
      if (!mounted) {
        return;
      }
      setState(() {
        _bearerToken = refreshed.bearerToken;
        _status =
            'Session refreshed. Expires ${refreshed.session.expiresAt.toLocal()}.';
      });
      await _refreshMobileGallery();
    });
  }

  Future<void> _revokeCurrentSession() async {
    await _runBusy(() async {
      final token = _requireBearerToken();
      await _client().revokeCurrentMobileSession(bearerToken: token);
      await _storage.delete(key: _bearerTokenKey);
      if (!mounted) {
        return;
      }
      setState(() {
        _bearerToken = null;
        _mobileWorkspace = null;
        _mobileFileTree = null;
        _mobileFileFolderId = null;
        _mobileAssets = const [];
        _mode = _MobileOnboardingMode.overview;
        _status =
            'This phone session was revoked. Scan a fresh invite to reconnect.';
      });
    });
  }

  Future<void> _revokeDeviceSessions(String deviceId) async {
    await _runBusy(() async {
      final token = _requireBearerToken();
      await _client().revokeMobileDeviceSessions(
        bearerToken: token,
        deviceId: deviceId,
      );
      if (_mobileWorkspace?.session.deviceId == deviceId) {
        await _storage.delete(key: _bearerTokenKey);
        if (!mounted) {
          return;
        }
        setState(() {
          _bearerToken = null;
          _mobileWorkspace = null;
          _mobileFileTree = null;
          _mobileFileFolderId = null;
          _mobileAssets = const [];
          _mode = _MobileOnboardingMode.overview;
          _status =
              'This phone session was revoked. Scan a fresh invite to reconnect.';
        });
        return;
      }
      await _refreshMobileGallery();
    });
  }

  Future<void> _checkCameraRollAccess() async {
    await _runBusy(() async {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.hasAccess) {
        setState(() {
          _status =
              'Photo library permission is required before mobile backup can run.';
        });
        return;
      }
      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.common,
        onlyAll: true,
      );
      final cacheRoot = await getApplicationSupportDirectory();
      final count = albums.isEmpty ? 0 : await albums.first.assetCountAsync;
      setState(() {
        _status =
            'Camera roll access is ready. Found $count item(s). Mobile cache root: ${cacheRoot.path}';
      });
      await _refreshLocalDeviceMedia(requestPermission: false);
    });
  }

  Future<void> _refreshLocalDeviceMedia({
    required bool requestPermission,
  }) async {
    if (_loadingLocalMedia) {
      return;
    }
    setState(() {
      _loadingLocalMedia = true;
      _localMediaError = null;
    });
    try {
      final permission = requestPermission
          ? await PhotoManager.requestPermissionExtend()
          : await PhotoManager.getPermissionState(
              requestOption: const PermissionRequestOption(),
            );
      if (!permission.hasAccess) {
        if (!mounted) {
          return;
        }
        setState(() {
          _localDeviceAssets = const [];
          _localDeviceAlbums = const [];
          _localMediaError =
              'Allow photo access to browse and organize media on this phone.';
        });
        return;
      }
      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.common,
        hasAll: true,
      );
      final allAlbum = albums.isEmpty
          ? null
          : albums.firstWhere((album) => album.isAll, orElse: () => albums[0]);
      final total = allAlbum == null ? 0 : await allAlbum.assetCountAsync;
      final pageSize = total < 240 ? total : 240;
      final assets = allAlbum == null || pageSize <= 0
          ? const <AssetEntity>[]
          : await allAlbum.getAssetListPaged(page: 0, size: pageSize);
      if (!mounted) {
        return;
      }
      setState(() {
        _localDeviceAlbums = albums;
        _localDeviceAssets = assets;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _localMediaError = '$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingLocalMedia = false;
        });
      }
    }
  }

  Future<void> _uploadNewestCameraRollItem() async {
    await _runBusy(() async {
      final token = _requireBearerToken();
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.hasAccess) {
        setState(() {
          _status = 'Grant media access before uploading from this device.';
        });
        return;
      }
      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.common,
        onlyAll: true,
      );
      if (albums.isEmpty) {
        setState(() {
          _status = 'No camera-roll albums are visible to the app.';
        });
        return;
      }
      final assets = await albums.first.getAssetListPaged(page: 0, size: 1);
      if (assets.isEmpty) {
        setState(() {
          _status = 'No camera-roll items are available to upload.';
        });
        return;
      }
      final entity = assets.first;
      final file = await entity.file;
      if (file == null) {
        setState(() {
          _status = 'The newest camera-roll item is not available as a file.';
        });
        return;
      }
      final filename = _filenameFor(entity, file);
      final completed = await _reserveAndUploadMobileFile(
        token: token,
        file: file,
        filename: filename,
        mediaKind: entity.type == AssetType.video ? 'video' : 'photo',
        mimeType: _mimeTypeFor(filename, entity.type),
        capturedAt: entity.createDateTime,
      );
      if (completed.status == MobileUploadStatus.canceled) {
        setState(() {
          _status = 'Upload canceled: $filename.';
        });
        return;
      }
      if (completed.status != MobileUploadStatus.completed) {
        setState(() {
          _status =
              'Upload ended as ${_mobileUploadStatusLabel(completed.status)}: $filename.';
        });
        return;
      }
      await _refreshMobileGallery();
      setState(() {
        _status =
            'Uploaded $filename as asset ${completed.assetId ?? 'pending asset'}.';
      });
    });
  }

  Future<void> _uploadLocalDeviceAsset(AssetEntity entity) async {
    await _runBusy(() async {
      final token = _requireBearerToken();
      final file = await entity.file;
      if (file == null) {
        setState(() {
          _status = 'This item is not available as a local file.';
        });
        return;
      }
      final filename = _filenameFor(entity, file);
      final completed = await _reserveAndUploadMobileFile(
        token: token,
        file: file,
        filename: filename,
        mediaKind: entity.type == AssetType.video ? 'video' : 'photo',
        mimeType: _mimeTypeFor(filename, entity.type),
        capturedAt: entity.createDateTime,
      );
      if (completed.status == MobileUploadStatus.canceled) {
        setState(() {
          _status = 'Upload canceled: $filename.';
        });
        return;
      }
      if (completed.status != MobileUploadStatus.completed) {
        setState(() {
          _status =
              'Upload ended as ${_mobileUploadStatusLabel(completed.status)}: $filename.';
        });
        return;
      }
      await _refreshMobileGallery();
      setState(() {
        _status =
            'Uploaded $filename as asset ${completed.assetId ?? 'pending asset'}.';
      });
    });
  }

  Future<MobileUpload> _reserveAndUploadMobileFile({
    required String token,
    required File file,
    required String filename,
    required String mediaKind,
    required String mimeType,
    DateTime? capturedAt,
  }) async {
    final length = await file.length();
    final contentHash = await _sha256File(file);
    final reserved = await _client().reserveMobileUpload(
      bearerToken: token,
      originalFilename: filename,
      mediaKind: mediaKind,
      mimeType: mimeType,
      bytes: length,
      contentHash: contentHash,
      capturedAt: capturedAt,
    );
    if (mounted) {
      setState(() {
        _activeUpload = reserved;
        _activeUploadFilename = filename;
        _cancelUploadRequested = false;
        _status = 'Uploading $filename...';
      });
    }
    try {
      return await _client().uploadMobileOriginalFile(
        bearerToken: token,
        uploadId: reserved.id,
        file: file,
        onProgress: (upload) {
          if (!mounted || _activeUpload?.id != upload.id) {
            return;
          }
          setState(() {
            _activeUpload = upload;
          });
        },
        shouldCancel: (upload) {
          return _activeUpload?.id == upload.id && _cancelUploadRequested;
        },
      );
    } finally {
      if (mounted && _activeUpload?.id == reserved.id) {
        setState(() {
          _activeUpload = null;
          _activeUploadFilename = null;
          _cancelUploadRequested = false;
        });
      }
    }
  }

  Future<void> _cancelActiveMobileUpload() async {
    final upload = _activeUpload;
    final token = _bearerToken;
    if (upload == null || token == null || token.isEmpty) {
      return;
    }
    setState(() {
      _cancelUploadRequested = true;
      _status =
          'Canceling upload ${_activeUploadFilename ?? upload.originalFilename}...';
    });
    try {
      final canceled = await _client().cancelMobileUpload(
        bearerToken: token,
        uploadId: upload.id,
      );
      if (!mounted || _activeUpload?.id != upload.id) {
        return;
      }
      setState(() {
        _activeUpload = canceled;
      });
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = _friendlyApiError(error);
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = '$error';
      });
    }
  }

  Future<String> _sha256File(File file) async {
    final digest = await sha256.bind(file.openRead()).single;
    return digest.toString();
  }

  Future<void> _downloadFirstVaultOriginal() async {
    await _runBusy(() async {
      final token = _requireBearerToken();
      final assets = await _client().fetchMobileAssets(bearerToken: token);
      if (assets.isEmpty) {
        setState(() {
          _status = 'No group assets are available to download yet.';
        });
        return;
      }
      final file = await _saveMobileOriginal(assets.first);
      setState(() {
        _status =
            'Downloaded ${assets.first.originalFilename} to ${file.path}.';
      });
    });
  }

  Future<void> _syncPhoneStorage() async {
    await _runBusy(() async {
      final token = _requireBearerToken();
      final client = _client();
      await client.updateMobileStorageProfile(
        bearerToken: token,
        storageProfile: await _phoneStorageProfile(acceptsStorage: true),
      );
      final plan = await client.fetchMobileStoragePlan(bearerToken: token);
      if (plan.assignments.isEmpty) {
        setState(() {
          _status = plan.detail;
        });
        await _refreshPairedSurfaces();
        return;
      }

      var chunkCount = 0;
      var bytesStored = 0;
      for (final assignment in plan.assignments) {
        final chunkProofsByIndex = <int, String>{};
        for (final chunk in assignment.chunks) {
          final bytes = await client.downloadMobileReplicaChunk(
            bearerToken: token,
            blobId: assignment.blobId,
            chunkIndex: chunk.chunkIndex,
          );
          final digest = sha256.convert(bytes).toString();
          if (digest != chunk.encryptedHash) {
            throw StateError(
              'Encrypted chunk hash mismatch for ${assignment.blobId}/${chunk.chunkIndex}.',
            );
          }
          await _storeReplicaChunk(assignment, chunk, bytes);
          chunkProofsByIndex[chunk.chunkIndex] = chunk.proofFor(bytes);
          chunkCount += 1;
          bytesStored += bytes.length;
        }
        await client.reportMobileReplica(
          bearerToken: token,
          assignment: assignment,
          chunkProofsByIndex: chunkProofsByIndex,
        );
      }

      setState(() {
        _status =
            'Stored ${_formatBytes(bytesStored)} of encrypted vault chunks across $chunkCount chunk(s).';
      });
      await _refreshPairedSurfaces();
    });
  }

  Future<File> _storeReplicaChunk(
    MobileReplicaAssignment assignment,
    MobileReplicaChunkDescriptor chunk,
    List<int> bytes,
  ) async {
    final root = await getApplicationSupportDirectory();
    final directory = Directory(
      '${root.path}/mobile_replicas/${_safeLocalFilename(assignment.vaultId)}/${_safeLocalFilename(assignment.blobId)}',
    );
    await directory.create(recursive: true);
    final file = File(
      '${directory.path}/${chunk.chunkIndex.toString().padLeft(8, '0')}.pgblob',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<void> _refreshMobileGallery() async {
    final token = _requireBearerToken();
    setState(() {
      _loadingGallery = true;
      _loadingMobileFiles = true;
      _galleryError = null;
      _mobileFileError = null;
    });
    try {
      final client = _client();
      final workspace = await client.fetchMobileWorkspace(bearerToken: token);
      final assets = _mobileAssetsFromWorkspace(workspace);
      assets.sort((left, right) => right.capturedAt.compareTo(left.capturedAt));
      VaultFileTreeResponse? fileTree;
      String? fileTreeError;
      try {
        fileTree = await client.fetchMobileFileTree(bearerToken: token);
      } on ApiException catch (error) {
        fileTreeError = _friendlyApiError(error);
      } catch (error) {
        fileTreeError = '$error';
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _mobileWorkspace = workspace;
        _mobileAssets = assets;
        _mobileFileTree = fileTree;
        _mobileFileFolderId = _validMobileFolderId(
          fileTree,
          _mobileFileFolderId,
        );
        _mobileFileError = fileTreeError;
      });
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      if (error.isNotFound) {
        await _refreshLegacyMobileGallery(token);
      } else if (_isInvalidMobileSession(error)) {
        await _storage.delete(key: _bearerTokenKey);
        if (!mounted) {
          return;
        }
        setState(() {
          _bearerToken = null;
          _mode = _MobileOnboardingMode.join;
          _mobileWorkspace = null;
          _mobileFileTree = null;
          _mobileFileFolderId = null;
          _mobileAssets = const [];
          _galleryError = null;
          _mobileFileError = null;
          _status = 'The mobile session expired. Scan a fresh invite.';
        });
      } else {
        setState(() {
          _galleryError = _friendlyApiError(error);
        });
      }
    } on SocketException {
      if (!mounted) {
        return;
      }
      setState(() {
        _galleryError =
            'Desktop is not reachable. Check that LAN mode is running and use port 4821.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _galleryError = '$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingGallery = false;
          _loadingMobileFiles = false;
        });
      }
    }
  }

  Future<void> _refreshLegacyMobileGallery(String token) async {
    final assets = await _client().fetchMobileAssets(bearerToken: token);
    assets.sort((left, right) => right.capturedAt.compareTo(left.capturedAt));
    if (!mounted) {
      return;
    }
    setState(() {
      _mobileWorkspace = null;
      _mobileFileTree = null;
      _mobileFileFolderId = null;
      _mobileAssets = assets;
    });
  }

  Future<void> _refreshMobileFiles() async {
    final token = _requireBearerToken();
    setState(() {
      _loadingMobileFiles = true;
      _mobileFileError = null;
    });
    try {
      final fileTree = await _client().fetchMobileFileTree(bearerToken: token);
      if (!mounted) {
        return;
      }
      setState(() {
        _mobileFileTree = fileTree;
        _mobileFileFolderId = _validMobileFolderId(
          fileTree,
          _mobileFileFolderId,
        );
      });
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _mobileFileError = _friendlyApiError(error);
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _mobileFileError = '$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingMobileFiles = false;
        });
      }
    }
  }

  Future<void> _refreshPairedSurfaces() async {
    await _refreshLocalDeviceMedia(requestPermission: true);
    if (_bearerToken != null && _bearerToken!.isNotEmpty) {
      await _refreshMobileGallery();
    }
  }

  Future<void> _continueWithoutGroup() async {
    if (_busy) {
      return;
    }
    await _storage.write(key: _localOnlyModeKey, value: 'true');
    if (!mounted) {
      return;
    }
    setState(() {
      _localOnlyMode = true;
      _pairedTab = _MobilePairedTab.gallery;
      _status =
          'Browsing this device. You can create or join a same-LAN group later from Devices.';
    });
    await _refreshLocalDeviceMedia(requestPermission: true);
    if (!mounted) {
      return;
    }
    setState(() {
      _status = _localDeviceAssets.isEmpty
          ? 'Device-only mode is ready. Allow photo access or add media to this phone; LAN group setup remains available from Devices.'
          : 'Browsing this device. LAN group setup remains available from Devices.';
    });
  }

  Future<SearchResponse> _searchMobileWorkspace(SearchQuery query) {
    final token = _requireBearerToken();
    return _client().searchMobile(bearerToken: token, query: query);
  }

  Future<void> _runPairedSearch() async {
    final query = _mobileDiscoverySearchController.text.trim();
    if (query.isEmpty) {
      setState(() {
        _pairedSearchError = null;
        _pairedSearchResult = null;
      });
      return;
    }
    if (_bearerToken == null || _bearerToken!.isEmpty) {
      setState(() {
        _pairedSearchError = null;
        _pairedSearchResult = null;
      });
      return;
    }
    setState(() {
      _pairedSearching = true;
      _pairedSearchError = null;
    });
    try {
      final result = await _searchMobileWorkspace(
        SearchQuery(text: query, limit: 60),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _pairedSearchResult = result;
      });
    } on SocketException {
      if (!mounted) {
        return;
      }
      setState(() {
        _pairedSearchError =
            'Desktop is not reachable. Search will work when the group is online.';
      });
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _pairedSearchError = _friendlyApiError(error);
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _pairedSearchError = '$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _pairedSearching = false;
        });
      }
    }
  }

  Future<void> _toggleMobileFavorite(Asset asset, bool favorite) async {
    final token = _requireBearerToken();
    await _client().updateMobileAssetFlags(
      bearerToken: token,
      assetId: asset.id,
      favorite: favorite,
    );
    await _refreshMobileGallery();
  }

  Future<void> _toggleMobileArchived(Asset asset, bool archived) async {
    final token = _requireBearerToken();
    await _client().updateMobileAssetFlags(
      bearerToken: token,
      assetId: asset.id,
      archived: archived,
    );
    await _refreshMobileGallery();
  }

  Future<File> _saveMobileOriginal(MobileAssetSummary asset) async {
    final token = _requireBearerToken();
    final root = await getApplicationSupportDirectory();
    final downloadDir = Directory('${root.path}/mobile_downloads');
    await downloadDir.create(recursive: true);
    final filename = _safeLocalFilename(asset.originalFilename);
    final file = File('${downloadDir.path}/${asset.assetId}_$filename');
    return _client().downloadMobileOriginalToFile(
      bearerToken: token,
      assetId: asset.assetId,
      destination: file,
    );
  }

  Future<File> _saveMobileFileOriginal(VaultFileEntry entry) async {
    final token = _requireBearerToken();
    final root = await getApplicationSupportDirectory();
    final downloadDir = Directory('${root.path}/mobile_downloads/files');
    await downloadDir.create(recursive: true);
    final filename = _safeLocalFilename(entry.name);
    final file = File('${downloadDir.path}/${entry.id}_$filename');
    return _client().downloadMobileFileOriginalToFile(
      bearerToken: token,
      entryId: entry.id,
      destination: file,
    );
  }

  Future<void> _downloadMobileFile(VaultFileEntry entry) async {
    await _runBusy(() async {
      final file = await _saveMobileFileOriginal(entry);
      setState(() {
        _status = 'Downloaded ${entry.name} to ${file.path}.';
      });
    });
  }

  Future<void> _openMobileAsset(MobileAssetSummary asset) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => MobileMediaViewer.group(
          asset: asset,
          loadOriginalFile: () => _saveMobileOriginal(asset),
          saveOriginal: () => _saveMobileOriginal(asset),
          loadAvailability: () => _client().fetchMobileAssetAvailability(
            bearerToken: _requireBearerToken(),
            assetId: asset.assetId,
          ),
        ),
      ),
    );
  }

  Future<void> _openLocalDeviceAsset(AssetEntity asset) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => MobileMediaViewer.local(
          asset: asset,
          canUpload: _bearerToken != null && _bearerToken!.isNotEmpty,
          onUpload: () => _uploadLocalDeviceAsset(asset),
        ),
      ),
    );
  }

  Future<void> _openLocalAlbum(AssetPathEntity album) async {
    if (_busy) {
      return;
    }
    if (album.isAll) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => _LocalDeviceCollectionScreen(
            title: 'All Photos',
            subtitle: _localDeviceAssets.length >= 240
                ? 'Showing 240 recent items'
                : '${_localDeviceAssets.length} items',
            assets: _localDeviceAssets,
            canUpload: _bearerToken != null && _bearerToken!.isNotEmpty,
            onUpload: _uploadLocalDeviceAsset,
          ),
        ),
      );
      return;
    }
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final count = await album.assetCountAsync.timeout(
        const Duration(seconds: 6),
      );
      final pageSize = count < 240 ? count : 240;
      final assets = pageSize <= 0
          ? const <AssetEntity>[]
          : await album
                .getAssetListPaged(page: 0, size: pageSize)
                .timeout(const Duration(seconds: 8));
      if (!mounted) {
        return;
      }
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => _LocalDeviceCollectionScreen(
            title: album.isAll ? 'All Photos' : album.name,
            subtitle: count > assets.length
                ? 'Showing ${assets.length} of $count items'
                : '$count items',
            assets: assets,
            canUpload: _bearerToken != null && _bearerToken!.isNotEmpty,
            onUpload: _uploadLocalDeviceAsset,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = '$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _openLocalMonth(_LocalMonthBucket month) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _LocalDeviceCollectionScreen(
          title: month.label,
          subtitle: '${month.assets.length} items',
          assets: month.assets,
          canUpload: _bearerToken != null && _bearerToken!.isNotEmpty,
          onUpload: _uploadLocalDeviceAsset,
        ),
      ),
    );
  }

  ImageProvider<Object>? _previewImageFor(MobileAssetSummary asset) {
    if (asset.mediaKind != 'photo' || !asset.available) {
      return null;
    }
    final token = _bearerToken;
    if (token == null || token.isEmpty) {
      return null;
    }
    try {
      final client = _client();
      return NetworkImage(
        client.mobileAssetPreviewUri(asset.assetId).toString(),
        headers: client.mobileAuthorizationHeaders(token),
      );
    } catch (_) {
      return null;
    }
  }

  List<MobileAssetSummary> _filteredMobileAssets(
    List<MobileAssetSummary> assets,
  ) {
    final query = _mobileSearchController.text.trim().toLowerCase();
    return assets
        .where((asset) {
          final filename = asset.originalFilename.toLowerCase();
          final captured = DateFormat.yMMMd()
              .format(asset.capturedAt.toLocal())
              .toLowerCase();
          final matchesQuery =
              query.isEmpty ||
              filename.contains(query) ||
              asset.mediaKind.toLowerCase().contains(query) ||
              asset.mimeType.toLowerCase().contains(query) ||
              captured.contains(query);
          final matchesFilter = switch (_galleryFilter) {
            _MobileGalleryFilter.all => true,
            _MobileGalleryFilter.photos =>
              asset.mediaKind == 'photo' || asset.mimeType.startsWith('image/'),
            _MobileGalleryFilter.videos =>
              asset.mediaKind == 'video' || asset.mimeType.startsWith('video/'),
            _MobileGalleryFilter.documents =>
              asset.mediaKind == 'document' ||
                  asset.mimeType == 'application/pdf',
            _MobileGalleryFilter.audio =>
              asset.mediaKind == 'audio' || asset.mimeType.startsWith('audio/'),
            _MobileGalleryFilter.archives => asset.mediaKind == 'archive',
            _MobileGalleryFilter.text =>
              asset.mediaKind == 'text' || asset.mimeType.startsWith('text/'),
            _MobileGalleryFilter.other => asset.mediaKind == 'other',
            _MobileGalleryFilter.favorites => false,
            _MobileGalleryFilter.thisDevice => asset.available,
          };
          return matchesQuery && matchesFilter;
        })
        .toList(growable: false);
  }

  List<AssetEntity> _filteredLocalDeviceAssets(
    List<AssetEntity> assets, {
    String? query,
  }) {
    final normalizedQuery = (query ?? _mobileSearchController.text)
        .trim()
        .toLowerCase();
    return assets
        .where((asset) {
          final title = (asset.title ?? asset.id).toLowerCase();
          final relativePath = (asset.relativePath ?? '').toLowerCase();
          final captured = DateFormat.yMMMd()
              .format(asset.createDateTime.toLocal())
              .toLowerCase();
          final matchesQuery =
              normalizedQuery.isEmpty ||
              title.contains(normalizedQuery) ||
              relativePath.contains(normalizedQuery) ||
              captured.contains(normalizedQuery);
          final matchesFilter = switch (_galleryFilter) {
            _MobileGalleryFilter.all => true,
            _MobileGalleryFilter.photos => asset.type == AssetType.image,
            _MobileGalleryFilter.videos => asset.type == AssetType.video,
            _MobileGalleryFilter.documents ||
            _MobileGalleryFilter.audio ||
            _MobileGalleryFilter.archives ||
            _MobileGalleryFilter.text ||
            _MobileGalleryFilter.other => false,
            _MobileGalleryFilter.favorites => asset.isFavorite,
            _MobileGalleryFilter.thisDevice => true,
          };
          return matchesQuery && matchesFilter;
        })
        .toList(growable: false);
  }

  int? _onlineDeviceCount(MobileWorkspaceSnapshot? workspace) {
    if (workspace == null) {
      return null;
    }
    final devices = workspace.devices.isEmpty
        ? workspace.vaultStatus.devices
        : workspace.devices;
    return devices.where(_deviceIsOnline).length;
  }

  String _mobileBucketLabel(List<MobileAssetSummary> assets) {
    if (assets.isEmpty) {
      return 'Gallery';
    }
    return DateFormat.yMMMM().format(assets.first.capturedAt.toLocal());
  }

  String _localBucketLabel(List<AssetEntity> assets) {
    if (assets.isEmpty) {
      return 'This Device';
    }
    return DateFormat.yMMMM().format(assets.first.createDateTime.toLocal());
  }

  Future<void> _runBusy(Future<void> Function() work) async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await work();
    } on SocketException {
      if (mounted) {
        setState(() {
          _status =
              'Desktop is not reachable. Check that LAN mode is running and use port 4821.';
        });
      }
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _status = _friendlyApiError(error);
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = '$error';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  String _friendlyApiError(ApiException error) {
    if (error.path == '/mobile/pair' && error.statusCode == 400) {
      return 'The invite expired, was already used, or does not match this group. Create a fresh invite.';
    }
    if (_isInvalidMobileSession(error)) {
      return 'The saved mobile session is no longer valid. Scan a fresh invite.';
    }
    return 'The desktop returned ${error.statusCode} for ${error.path}.';
  }

  bool _isInvalidMobileSession(ApiException error) {
    if (!error.path.startsWith('/mobile/') || error.path == '/mobile/pair') {
      return false;
    }
    final body = error.body.toLowerCase();
    return error.statusCode == 401 ||
        error.statusCode == 403 ||
        (error.statusCode == 400 &&
            (body.contains('mobile session') ||
                body.contains('bearer token') ||
                body.contains('authorization')));
  }

  String _requireBearerToken() {
    final token = _bearerToken?.trim();
    if (token == null || token.isEmpty) {
      throw StateError('Join a local desktop group first.');
    }
    return token;
  }

  String _filenameFor(AssetEntity entity, File file) {
    final title = entity.title;
    if (title != null && title.trim().isNotEmpty) {
      return _safeLocalFilename(title);
    }
    final segments = file.uri.pathSegments;
    if (segments.isNotEmpty) {
      return _safeLocalFilename(segments.last);
    }
    return entity.type == AssetType.video
        ? 'mobile-video.mp4'
        : 'mobile-photo.jpg';
  }

  String _safeLocalFilename(String value) {
    final sanitized = value
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_')
        .replaceAll(RegExp(r'^[ .]+|[ .]+$'), '');
    return sanitized.isEmpty ? 'mobile-media.bin' : sanitized;
  }

  String _mimeTypeFor(String filename, AssetType type) {
    final lower = filename.toLowerCase();
    if (type == AssetType.video) {
      if (lower.endsWith('.mov')) {
        return 'video/quicktime';
      }
      return 'video/mp4';
    }
    if (lower.endsWith('.png')) {
      return 'image/png';
    }
    if (lower.endsWith('.webp')) {
      return 'image/webp';
    }
    if (lower.endsWith('.heic') || lower.endsWith('.heif')) {
      return 'image/heic';
    }
    return 'image/jpeg';
  }

  void _handleBarcode(BarcodeCapture capture) {
    if (!_scanning) {
      return;
    }
    String? value;
    for (final barcode in capture.barcodes) {
      final rawValue = barcode.rawValue;
      if (rawValue != null && rawValue.trim().isNotEmpty) {
        value = rawValue;
        break;
      }
    }
    if (value == null) {
      return;
    }
    setState(() {
      _scanning = false;
    });
    _saveInvitePayload(value);
  }

  @override
  Widget build(BuildContext context) {
    final paired = _bearerToken != null && _bearerToken!.isNotEmpty;
    final joiningUnpaired = !paired && _mode == _MobileOnboardingMode.join;
    final showGalleryShell =
        !joiningUnpaired &&
        (paired || _localOnlyMode || _localDeviceAssets.isNotEmpty);
    if (showGalleryShell) {
      return _buildPairedScaffold(context);
    }

    if (_mode == _MobileOnboardingMode.overview && !paired) {
      return _buildOverview(context);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Private Gallery')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (_mode == _MobileOnboardingMode.join && !paired)
              _buildJoin(context)
            else
              _buildPaired(context),
            if (_busy) ...[
              const SizedBox(height: 20),
              const LinearProgressIndicator(minHeight: 2),
            ],
            if (_status != null) ...[
              const SizedBox(height: 20),
              Text(_status!, style: Theme.of(context).textTheme.bodyMedium),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPairedScaffold(BuildContext context) {
    final paired = _bearerToken != null && _bearerToken!.isNotEmpty;
    final workspace = _mobileWorkspace;
    final rawGroupAssets = workspace == null
        ? _mobileAssets
        : _mobileAssetsFromWorkspace(workspace);
    final groupAssets = _filteredMobileAssets(rawGroupAssets);
    final localAssets = _filteredLocalDeviceAssets(_localDeviceAssets);
    final groupName =
        workspace?.vaultStatus.vault.name ??
        _cloudGroup?.name ??
        _pendingInvite?.groupName ??
        (paired ? 'Family Vault' : 'This Device');
    final onlineCount = _onlineDeviceCount(workspace);
    final subtitle = onlineCount == null
        ? '$groupName • ${_localDeviceAssets.length} on this phone'
        : '$groupName • $onlineCount ${onlineCount == 1 ? 'device' : 'devices'} on LAN';
    final online =
        paired &&
        workspace != null &&
        _galleryError == null &&
        !_loadingGallery;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        toolbarHeight: 64,
        titleSpacing: 16,
        title: Row(
          children: [
            Icon(Icons.shield, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Private Gallery',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      letterSpacing: 0.4,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _busy ? null : _refreshPairedSurfaces,
            icon: Icon(
              paired
                  ? online
                        ? Icons.cloud_done
                        : Icons.cloud_off_outlined
                  : Icons.devices_outlined,
              color: Theme.of(context).colorScheme.primary,
            ),
            tooltip: paired
                ? online
                      ? 'Same-LAN group connected'
                      : 'Same-LAN group unavailable'
                : 'Connect same-LAN group',
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: SizedBox.expand(
          child: switch (_pairedTab) {
            _MobilePairedTab.gallery => _buildReferenceGallery(
              context,
              groupAssets: groupAssets,
              localAssets: localAssets,
              allGroupAssetCount: rawGroupAssets.length,
              allLocalAssetCount: _localDeviceAssets.length,
              workspace: workspace,
            ),
            _MobilePairedTab.files => _buildReferenceFiles(context),
            _MobilePairedTab.search => _buildReferenceSearch(context),
            _MobilePairedTab.devices => _buildReferenceDevices(
              context,
              workspace,
            ),
            _MobilePairedTab.settings => _buildReferenceSettings(context),
          },
        ),
      ),
      floatingActionButton: _pairedTab == _MobilePairedTab.gallery
          ? FloatingActionButton(
              onPressed: _busy
                  ? null
                  : paired
                  ? _uploadNewestCameraRollItem
                  : () => _refreshLocalDeviceMedia(requestPermission: true),
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Theme.of(context).colorScheme.onPrimary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.add_photo_alternate),
            )
          : null,
      bottomNavigationBar: _MobileReferenceBottomNav(
        selected: _pairedTab,
        onSelected: (tab) => setState(() => _pairedTab = tab),
      ),
    );
  }

  Widget _buildReferenceGallery(
    BuildContext context, {
    required List<MobileAssetSummary> groupAssets,
    required List<AssetEntity> localAssets,
    required int allGroupAssetCount,
    required int allLocalAssetCount,
    required MobileWorkspaceSnapshot? workspace,
  }) {
    final localBucketLabel = _localBucketLabel(localAssets);
    final groupBucketLabel = _mobileBucketLabel(groupAssets);
    final showGroupAssets =
        groupAssets.isNotEmpty &&
        _galleryFilter != _MobileGalleryFilter.thisDevice;
    return ListView(
      key: const PageStorageKey('mobile-reference-gallery'),
      primary: false,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 112),
      children: [
        _MobileReferenceSearchAndFilters(
          controller: _mobileSearchController,
          selected: _galleryFilter,
          onChanged: () => setState(() {}),
          onFilterSelected: (filter) => setState(() => _galleryFilter = filter),
          onSubmitted: (_) {
            setState(() => _pairedTab = _MobilePairedTab.search);
            _runPairedSearch();
          },
        ),
        const SizedBox(height: 16),
        _MobileSyncStrip(
          loading: _loadingGallery,
          error: _galleryError,
          workspace: workspace,
          onRefresh: _refreshPairedSurfaces,
          onCreate: _startCreateGroup,
          onPair: _scanInviteQr,
        ),
        if (_activeUpload != null) ...[
          const SizedBox(height: 16),
          _ActiveMobileUploadNotice(
            upload: _activeUpload!,
            filename: _activeUploadFilename ?? _activeUpload!.originalFilename,
            cancelRequested: _cancelUploadRequested,
            onCancel: _cancelActiveMobileUpload,
          ),
        ] else if (_status != null) ...[
          const SizedBox(height: 16),
          _ReferenceNotice(
            icon: Icons.info_outline,
            title: 'Status',
            message: _status!,
          ),
        ],
        const SizedBox(height: 20),
        _LocalMediaStatusStrip(
          loading: _loadingLocalMedia,
          error: _localMediaError,
          assetCount: _localDeviceAssets.length,
          albumCount: _localDeviceAlbums.length,
          onGrantAccess: () =>
              _refreshLocalDeviceMedia(requestPermission: true),
        ),
        const SizedBox(height: 20),
        Text(localBucketLabel, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        if (localAssets.isEmpty && groupAssets.isEmpty)
          _ReferenceEmptyGallery(
            error: _localMediaError ?? _galleryError,
            allAssetCount: allLocalAssetCount + allGroupAssetCount,
            onUpload: _busy
                ? null
                : () => _refreshLocalDeviceMedia(requestPermission: true),
          )
        else
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: localAssets.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 1,
            ),
            itemBuilder: (context, index) {
              final asset = localAssets[index];
              return _ReferenceLocalAssetTile(
                asset: asset,
                onTap: () => _openLocalDeviceAsset(asset),
              );
            },
          ),
        if (showGroupAssets) ...[
          const SizedBox(height: 24),
          Text(
            groupBucketLabel == 'Gallery' ? 'Group Vault' : groupBucketLabel,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: groupAssets.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 1,
            ),
            itemBuilder: (context, index) {
              final asset = groupAssets[index];
              return _ReferenceMobileAssetTile(
                asset: asset,
                previewImage: _previewImageFor(asset),
                onTap: () => _openMobileAsset(asset),
              );
            },
          ),
        ],
      ],
    );
  }

  Widget _buildReferenceFiles(BuildContext context) {
    final tree = _mobileFileTree;
    final roots = tree?.roots ?? const <VaultFileEntry>[];
    final root = roots.firstOrNull;
    final current = tree == null
        ? null
        : _folderByIdMobileTree(tree, _mobileFileFolderId) ?? root;
    final folders = tree?.entries.where((entry) => entry.isFolder).length ?? 0;
    final files = tree?.entries.where((entry) => entry.isFile).length ?? 0;
    final documents =
        tree?.entries
            .where((entry) => entry.isFile && entry.mediaKind == 'document')
            .length ??
        0;
    final currentChildren = tree == null || current == null
        ? const <VaultFileEntry>[]
        : _childrenOfMobileTree(tree, current.id);

    return ListView(
      key: const PageStorageKey('mobile-reference-files'),
      primary: false,
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 112),
      children: [
        Text(
          'Files & Documents',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        Text(
          'Browse shared vault files from trusted devices. Downloads stay on this phone.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        _ReferenceFileSummary(
          folders: folders,
          files: files,
          documents: documents,
          loading: _loadingMobileFiles,
          onRefresh: _busy ? null : _refreshMobileFiles,
        ),
        if (_loadingMobileFiles) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(minHeight: 2),
        ],
        if (_mobileFileError != null) ...[
          const SizedBox(height: 12),
          _ReferenceNotice(
            icon: Icons.warning_amber_outlined,
            title: 'Files unavailable',
            message: _mobileFileError!,
            action: OutlinedButton.icon(
              onPressed: _busy ? null : _refreshMobileFiles,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ),
        ],
        const SizedBox(height: 16),
        if (tree == null || current == null)
          _ReferenceNotice(
            icon: Icons.folder_open_outlined,
            title: 'No shared files yet',
            message: _bearerToken == null
                ? 'Join a trusted group to browse documents, archives, audio, text files, and vault media.'
                : 'Refresh when the desktop is reachable. Shared files appear here beside media originals.',
            action: _bearerToken == null
                ? OutlinedButton.icon(
                    onPressed: _scanInviteQr,
                    icon: const Icon(Icons.qr_code_scanner_outlined),
                    label: const Text('Join group'),
                  )
                : null,
          )
        else ...[
          _ReferenceBreadcrumbRow(
            tree: tree,
            current: current,
            onOpen: (entry) {
              setState(() => _mobileFileFolderId = entry.id);
            },
          ),
          const SizedBox(height: 12),
          if (currentChildren.isEmpty)
            const _ReferenceNotice(
              icon: Icons.inbox_outlined,
              title: 'This folder is empty',
              message:
                  'Upload files from desktop or another trusted device to see them here.',
            )
          else
            for (final entry in currentChildren) ...[
              _ReferenceFileRow(
                entry: entry,
                disabled: _busy || _loadingMobileFiles,
                onOpen: entry.isFolder
                    ? () {
                        setState(() => _mobileFileFolderId = entry.id);
                      }
                    : null,
                onDownload: entry.isFile
                    ? () => _downloadMobileFile(entry)
                    : null,
              ),
              const SizedBox(height: 10),
            ],
        ],
      ],
    );
  }

  Widget _buildReferenceSearch(BuildContext context) {
    final result = _pairedSearchResult;
    final workspace = _mobileWorkspace;
    final query = _mobileDiscoverySearchController.text.trim();
    final localMonths = _localMonthBuckets(_localDeviceAssets);
    final localPlaceCount = _localDeviceAssets
        .where((asset) => asset.latLng != null)
        .length;
    final localFavoriteCount = _localDeviceAssets
        .where((asset) => asset.isFavorite)
        .length;
    final localVideoCount = _localDeviceAssets
        .where((asset) => asset.type == AssetType.video)
        .length;
    final localAssets = _filteredLocalDeviceAssets(
      _localDeviceAssets,
      query: query,
    );
    final assets =
        result?.assets
            .map(
              (asset) => MobileAssetSummary(
                assetId: asset.id,
                originalFilename: asset.originalFilename,
                mediaKind: asset.mediaKind,
                mimeType: asset.mimeType,
                bytes: asset.bytes,
                contentHash: asset.contentHash,
                capturedAt: asset.capturedAt,
                available: asset.isAvailable,
              ),
            )
            .toList() ??
        const <MobileAssetSummary>[];
    Widget localResultsGrid(String title) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: localAssets.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 1,
            ),
            itemBuilder: (context, index) {
              final asset = localAssets[index];
              return _ReferenceLocalAssetTile(
                asset: asset,
                onTap: () => _openLocalDeviceAsset(asset),
              );
            },
          ),
        ],
      );
    }

    return ListView(
      primary: false,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 112),
      children: [
        Text(
          'Search & Organize',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        Text(
          workspace == null
              ? 'Local organization is available on this phone. Pair the same-LAN group to search OCR, people, places, and vault metadata together.'
              : 'Search local filenames and paired vault metadata across your same-LAN group.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _mobileDiscoverySearchController,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _runPairedSearch(),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: workspace == null
                ? 'Search this device...'
                : 'Search photos, people, places, OCR...',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: query.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    onPressed: () {
                      setState(() {
                        _mobileDiscoverySearchController.clear();
                        _pairedSearchError = null;
                        _pairedSearchResult = null;
                      });
                    },
                    icon: const Icon(Icons.close),
                  ),
            filled: true,
            fillColor: AppColors.panel,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.navy),
            ),
          ),
        ),
        const SizedBox(height: 16),
        _ReferenceNotice(
          icon: Icons.manage_search_outlined,
          title: workspace == null
              ? 'Local search ready'
              : 'Group search ready',
          message: workspace == null
              ? 'Use Gallery filters for filenames and media type now. Pair the desktop to enable OCR text, people, places, and event search.'
              : 'Search filenames, OCR text, people, places, events, and indexed metadata from trusted devices on this LAN.',
          action: workspace == null
              ? OutlinedButton.icon(
                  onPressed: _scanInviteQr,
                  icon: const Icon(Icons.qr_code_scanner_outlined),
                  label: const Text('Join LAN group'),
                )
              : null,
        ),
        const SizedBox(height: 16),
        if (_pairedSearching) const LinearProgressIndicator(minHeight: 2),
        if (_pairedSearchError != null) ...[
          const SizedBox(height: 16),
          _ReferenceNotice(
            icon: Icons.warning_amber_outlined,
            title: 'Search unavailable',
            message: _pairedSearchError!,
          ),
          const SizedBox(height: 16),
        ],
        if (result != null && assets.isEmpty && localAssets.isEmpty) ...[
          _ReferenceSearchResultSummary(result: result),
          const SizedBox(height: 16),
        ] else if (result != null) ...[
          _ReferenceSearchResultSummary(result: result),
          const SizedBox(height: 16),
          if (localAssets.isNotEmpty) ...[
            localResultsGrid('This Device'),
            const SizedBox(height: 20),
          ],
          if (assets.isNotEmpty) ...[
            Text('Group Vault', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: assets.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                childAspectRatio: 1,
              ),
              itemBuilder: (context, index) {
                final asset = assets[index];
                return _ReferenceMobileAssetTile(
                  asset: asset,
                  previewImage: _previewImageFor(asset),
                  onTap: () => _openMobileAsset(asset),
                );
              },
            ),
            const SizedBox(height: 20),
          ],
        ] else if (query.isNotEmpty) ...[
          if (localAssets.isEmpty)
            const _ReferenceNotice(
              icon: Icons.search_off_outlined,
              title: 'No local matches',
              message:
                  'Try a filename, month, media type, or pair the same-LAN group for OCR and metadata search.',
            )
          else
            localResultsGrid('This Device Results'),
          const SizedBox(height: 20),
        ],
        _LocalDeviceOrganizationSummary(
          assetCount: _localDeviceAssets.length,
          albumCount: _localDeviceAlbums.length,
          monthCount: localMonths.length,
          favoriteCount: localFavoriteCount,
          videoCount: localVideoCount,
        ),
        const SizedBox(height: 16),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 1.34,
          children: [
            _DiscoveryCountCard(
              icon: Icons.photo_album_outlined,
              title: 'Albums',
              count:
                  _localDeviceAlbums.length + (workspace?.albums.length ?? 0),
              detail: 'Device and vault collections',
            ),
            _DiscoveryCountCard(
              icon: Icons.location_on_outlined,
              title: 'Places',
              count: localPlaceCount + (workspace?.places.length ?? 0),
              detail: 'GPS-derived',
            ),
            _DiscoveryCountCard(
              icon: Icons.event_outlined,
              title: 'Events',
              count: localMonths.length + (workspace?.events.length ?? 0),
              detail: 'Months and memories',
            ),
            _DiscoveryCountCard(
              icon: Icons.face_outlined,
              title: 'People',
              count: workspace?.people.length ?? 0,
              detail: workspace == null ? 'Pair desktop' : 'Face clusters',
            ),
          ],
        ),
        if (query.isEmpty && _localDeviceAlbums.isNotEmpty) ...[
          const SizedBox(height: 20),
          _LocalAlbumsGrid(
            albums: _localDeviceAlbums.take(4).toList(),
            onOpenAlbum: _openLocalAlbum,
          ),
        ],
        if (query.isEmpty && localMonths.isNotEmpty) ...[
          const SizedBox(height: 20),
          _LocalMonthList(
            months: localMonths.take(5).toList(),
            onOpenMonth: _openLocalMonth,
          ),
        ],
      ],
    );
  }

  Widget _buildReferenceDevices(
    BuildContext context,
    MobileWorkspaceSnapshot? workspace,
  ) {
    final List<DeviceIdentity> devices = workspace == null
        ? const <DeviceIdentity>[]
        : workspace.devices.isEmpty
        ? workspace.vaultStatus.devices
        : workspace.devices;
    final jobs = workspace?.jobs ?? const <JobRecord>[];
    final onlineCount = devices.where(_deviceIsOnline).length;
    return ListView(
      key: const PageStorageKey('mobile-reference-devices'),
      primary: false,
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 112),
      children: [
        Text(
          'Devices & Activity',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        Text(
          workspace == null
              ? _bearerToken == null
                    ? 'Browse this phone now. Create or join a same-LAN group here when you are ready to sync the other devices.'
                    : 'Reconnect to the desktop to refresh transfers and device status.'
              : '${workspace.vaultStatus.vault.name} is syncing directly across $onlineCount of ${devices.length} trusted devices on this local network.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        _MobileSyncStrip(
          loading: _loadingGallery,
          error: _galleryError,
          workspace: workspace,
          onRefresh: _refreshPairedSurfaces,
          onCreate: _startCreateGroup,
          onPair: _scanInviteQr,
        ),
        const SizedBox(height: 20),
        Text('Sync Activity', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        if (jobs.isEmpty)
          const _ReferenceNotice(
            icon: Icons.sync_outlined,
            title: 'No active jobs',
            message:
                'Imports, indexing, backups, and P2P transfers appear here as they run.',
          )
        else
          for (final job in jobs.take(8)) ...[
            _ReferenceJobCard(job: job),
            const SizedBox(height: 10),
          ],
        const SizedBox(height: 20),
        Text(
          'Device Management',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        if (devices.isEmpty)
          const _ReferenceNotice(
            icon: Icons.devices_outlined,
            title: 'Device status unavailable',
            message:
                'When the desktop is reachable, phones and storage devices appear here with same-network status.',
          )
        else
          for (final device in devices) ...[
            _ReferenceDeviceRow(device: device),
            const SizedBox(height: 10),
          ],
        OutlinedButton.icon(
          onPressed: _busy ? null : _scanInviteQr,
          icon: const Icon(Icons.qr_code_scanner_outlined),
          label: const Text('Add device'),
        ),
      ],
    );
  }

  Widget _buildReferenceSettings(BuildContext context) {
    final workspace = _mobileWorkspace;
    return ListView(
      key: const PageStorageKey('mobile-reference-settings'),
      primary: false,
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 112),
      children: [
        Text(
          'Vault Settings',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        Text(
          'Manage local security, device access, models, and backups.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        _ReferenceSettingsSection(
          title: 'Account & Group',
          icon: Icons.group_outlined,
          children: [
            _ReferenceInfoRow(
              label: 'Group',
              value:
                  workspace?.vaultStatus.vault.name ??
                  _cloudGroup?.name ??
                  _pendingInvite?.groupName ??
                  'Family Vault',
            ),
            _ReferenceInfoRow(
              label: 'Members',
              value: workspace == null
                  ? 'Offline'
                  : '${workspace.vaultStatus.members.length}',
            ),
            _ReferenceInfoRow(
              label: 'Session',
              value: _bearerToken == null ? 'Not paired' : 'Paired locally',
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy || _bearerToken == null
                        ? null
                        : _checkSession,
                    icon: const Icon(Icons.verified_user_outlined),
                    label: const Text('Check session'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy || _bearerToken == null
                        ? null
                        : _refreshSession,
                    icon: const Icon(Icons.sync_lock_outlined),
                    label: const Text('Refresh token'),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const _ReferenceSettingsSection(
          title: 'Privacy & Encryption',
          icon: Icons.lock_outline,
          emphasized: true,
          children: [
            _ReferenceToggleRow(
              title: 'Protected local database',
              message: 'Metadata indexes and paths are guarded by the vault.',
              value: true,
            ),
            _ReferenceToggleRow(
              title: 'Require biometrics on app open',
              message: 'Use the phone lock screen before exposing the vault.',
              value: false,
            ),
            _ReferenceInfoRow(
              label: 'Auto-lock',
              value: '5 minutes after inactivity',
            ),
          ],
        ),
        const SizedBox(height: 16),
        const _ReferenceSettingsSection(
          title: 'Local AI Models',
          icon: Icons.psychology_outlined,
          children: [
            _ReferenceInfoRow(
              label: 'Scene tagging',
              value: 'Ready when desktop model runtime is installed',
            ),
            _ReferenceInfoRow(
              label: 'OCR',
              value: 'Local-only indexing for searchable screenshots/docs',
            ),
            _ReferenceInfoRow(
              label: 'Faces',
              value: 'Biometric clusters stay on trusted hardware',
            ),
          ],
        ),
        const SizedBox(height: 16),
        _ReferenceActionCard(
          icon: Icons.photo_library_outlined,
          title: 'Camera roll access',
          message:
              'Grant media access before backing up originals into the group.',
          action: OutlinedButton.icon(
            onPressed: _busy ? null : _checkCameraRollAccess,
            icon: const Icon(Icons.folder_open_outlined),
            label: const Text('Check access'),
          ),
        ),
        const SizedBox(height: 12),
        _ReferenceActionCard(
          icon: Icons.dns_outlined,
          title: 'Phone storage contribution',
          message: workspace?.capabilities.canManageStorage == true
              ? 'This phone can store encrypted vault chunks for same-network repair and shared capacity.'
              : 'Enable this phone as encrypted local-cloud storage when it is on a trusted network.',
          action: OutlinedButton.icon(
            onPressed: _busy || _bearerToken == null ? null : _syncPhoneStorage,
            icon: const Icon(Icons.sync_outlined),
            label: const Text('Sync storage'),
          ),
        ),
        const SizedBox(height: 12),
        _ReferenceActionCard(
          icon: Icons.backup_outlined,
          title: 'Backup & Restore',
          message:
              'Move originals into the local group or save an available original onto this phone.',
          action: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: _busy || _bearerToken == null
                    ? null
                    : _uploadNewestCameraRollItem,
                icon: const Icon(Icons.cloud_upload_outlined),
                label: const Text('Upload newest'),
              ),
              OutlinedButton.icon(
                onPressed: _busy || _bearerToken == null
                    ? null
                    : _downloadFirstVaultOriginal,
                icon: const Icon(Icons.download_outlined),
                label: const Text('Download first'),
              ),
            ],
          ),
        ),
        if (_status != null) ...[
          const SizedBox(height: 16),
          Text(_status!, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ],
    );
  }

  Widget _buildOverview(BuildContext context) {
    final theme = Theme.of(context);
    final titleStyle = theme.textTheme.headlineMedium?.copyWith(
      color: AppColors.navy,
      fontSize: 24,
      height: 1.2,
      fontWeight: FontWeight.w700,
      letterSpacing: 0,
    );
    final bodyStyle = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.6,
      letterSpacing: 0,
    );

    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: Stack(
        children: [
          const _OnboardingAmbientBackground(),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 24,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight > 48
                          ? constraints.maxHeight - 48
                          : 0,
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 480),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            DecoratedBox(
                              decoration: BoxDecoration(
                                color: AppColors.panel,
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: [
                                  BoxShadow(
                                    color: AppColors.navy.withValues(
                                      alpha: 0.06,
                                    ),
                                    blurRadius: 24,
                                    offset: const Offset(0, 4),
                                  ),
                                  BoxShadow(
                                    color: AppColors.navy.withValues(
                                      alpha: 0.04,
                                    ),
                                    blurRadius: 3,
                                    offset: const Offset(0, 1),
                                  ),
                                ],
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    const _OnboardingVaultGraphic(),
                                    Padding(
                                      padding: const EdgeInsets.all(32),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          Text(
                                            'Welcome to Private Gallery',
                                            textAlign: TextAlign.center,
                                            style: titleStyle,
                                          ),
                                          const SizedBox(height: 12),
                                          RichText(
                                            textAlign: TextAlign.center,
                                            text: TextSpan(
                                              style: bodyStyle,
                                              children: [
                                                const TextSpan(
                                                  text:
                                                      'Your local-first digital vault. Sync photos instantly across trusted devices without relying on the cloud. ',
                                                ),
                                                TextSpan(
                                                  text:
                                                      'Absolute privacy, guaranteed.',
                                                  style: bodyStyle?.copyWith(
                                                    color: AppColors.navy,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(height: 28),
                                          SizedBox(
                                            height: 56,
                                            child: FilledButton.icon(
                                              onPressed: _busy
                                                  ? null
                                                  : _startCreateGroup,
                                              icon: const Icon(
                                                Icons.add_circle,
                                              ),
                                              label: const Text(
                                                'Create New Group',
                                              ),
                                              style: FilledButton.styleFrom(
                                                backgroundColor: Colors.black,
                                                foregroundColor: Colors.white,
                                                disabledBackgroundColor:
                                                    AppColors.navy.withValues(
                                                      alpha: 0.35,
                                                    ),
                                                disabledForegroundColor: Colors
                                                    .white
                                                    .withValues(alpha: 0.72),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                ),
                                                textStyle: const TextStyle(
                                                  fontSize: 13,
                                                  height: 1.4,
                                                  fontWeight: FontWeight.w700,
                                                  letterSpacing: 0,
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 16),
                                          SizedBox(
                                            height: 56,
                                            child: OutlinedButton.icon(
                                              onPressed: _busy
                                                  ? null
                                                  : _scanInviteQr,
                                              icon: const Icon(
                                                Icons.qr_code_scanner,
                                              ),
                                              label: const Text(
                                                'Join Existing Group',
                                              ),
                                              style: OutlinedButton.styleFrom(
                                                backgroundColor:
                                                    AppColors.panel,
                                                foregroundColor: AppColors.navy,
                                                side: const BorderSide(
                                                  color: AppColors.border,
                                                ),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                ),
                                                textStyle: const TextStyle(
                                                  fontSize: 13,
                                                  height: 1.4,
                                                  fontWeight: FontWeight.w700,
                                                  letterSpacing: 0,
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 12),
                                          SizedBox(
                                            height: 48,
                                            child: TextButton.icon(
                                              onPressed: _busy
                                                  ? null
                                                  : _continueWithoutGroup,
                                              icon: const Icon(
                                                Icons.photo_library_outlined,
                                              ),
                                              label: const Text(
                                                'Browse This Device',
                                              ),
                                              style: TextButton.styleFrom(
                                                foregroundColor: theme
                                                    .colorScheme
                                                    .onSurfaceVariant,
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                ),
                                                textStyle: const TextStyle(
                                                  fontSize: 13,
                                                  height: 1.4,
                                                  fontWeight: FontWeight.w700,
                                                  letterSpacing: 0,
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          Text(
                                            'No group needed now. Create or join a same-LAN group later from Devices.',
                                            textAlign: TextAlign.center,
                                            style: theme.textTheme.bodySmall
                                                ?.copyWith(
                                                  color: theme
                                                      .colorScheme
                                                      .onSurfaceVariant,
                                                  fontSize: 13,
                                                  height: 1.4,
                                                  fontWeight: FontWeight.w500,
                                                  letterSpacing: 0,
                                                ),
                                          ),
                                          const SizedBox(height: 28),
                                          DecoratedBox(
                                            decoration: BoxDecoration(
                                              color: theme
                                                  .colorScheme
                                                  .surfaceContainer,
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              border: Border(
                                                top: BorderSide(
                                                  color: theme
                                                      .colorScheme
                                                      .surfaceContainerHighest,
                                                ),
                                              ),
                                            ),
                                            child: Padding(
                                              padding: const EdgeInsets.all(16),
                                              child: Row(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Icon(
                                                    Icons.info_outline,
                                                    color: theme
                                                        .colorScheme
                                                        .onSurfaceVariant,
                                                    size: 22,
                                                  ),
                                                  const SizedBox(width: 12),
                                                  Expanded(
                                                    child: Text(
                                                      'To connect seamlessly, Gallery will need access to your camera (for QR codes) and local network permissions later.',
                                                      style: theme
                                                          .textTheme
                                                          .bodySmall
                                                          ?.copyWith(
                                                            color: theme
                                                                .colorScheme
                                                                .onSurfaceVariant,
                                                            fontSize: 13,
                                                            height: 1.4,
                                                            fontWeight:
                                                                FontWeight.w500,
                                                            letterSpacing: 0,
                                                          ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                          if (_busy) ...[
                                            const SizedBox(height: 20),
                                            const LinearProgressIndicator(
                                              minHeight: 2,
                                            ),
                                          ],
                                          if (_status != null) ...[
                                            const SizedBox(height: 20),
                                            Text(
                                              _status!,
                                              textAlign: TextAlign.center,
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                    color: theme
                                                        .colorScheme
                                                        .onSurfaceVariant,
                                                  ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (_cloudGroup != null ||
                                _cloudInvite != null) ...[
                              const SizedBox(height: 16),
                              _buildCloudGroupPanel(context),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildJoin(BuildContext context) {
    final invite = _pendingInvite;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ActionPanel(
          icon: Icons.qr_code_scanner_outlined,
          title: 'Join existing group',
          message: invite == null
              ? 'Scan the group invite QR. It fills the URL and one-time token automatically.'
              : 'Invite loaded for ${invite.groupName}.',
          action: FilledButton.icon(
            onPressed: _busy ? null : _scanInviteQr,
            icon: const Icon(Icons.qr_code_scanner_outlined),
            label: const Text('Scan invite'),
          ),
          secondaryAction: OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () {
                    setState(() {
                      _showManualJoin = !_showManualJoin;
                    });
                  },
            icon: const Icon(Icons.keyboard_outlined),
            label: Text(_showManualJoin ? 'Hide manual' : 'Use code'),
          ),
        ),
        if (_scanning) ...[
          const SizedBox(height: 16),
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: MobileScanner(
                controller: _scannerController!,
                onDetect: _handleBarcode,
              ),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () {
              final stopFuture = _scannerController?.stop();
              setState(() {
                _scanning = false;
              });
              stopFuture?.ignore();
            },
            icon: const Icon(Icons.close),
            label: const Text('Stop scanning'),
          ),
        ],
        if (_showManualJoin) ...[
          const SizedBox(height: 16),
          TextField(
            controller: _desktopUrlController,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Desktop URL',
              hintText: 'http://<laptop-hotspot-ip>:4821',
              helperText: 'Required for local LAN invites.',
            ),
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pairingTokenController,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Invite JSON or pairing token',
            ),
            minLines: 1,
            maxLines: 4,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy ? null : _saveManualInvite,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save invite'),
          ),
        ],
        const SizedBox(height: 16),
        TextField(
          controller: _deviceNameController,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'This device name',
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _busy || _pairingInFlight
              ? null
              : invite?.supportsCloud == true && invite?.supportsLan != true
              ? _joinCloudGroup
              : _pairWithDesktop,
          icon: const Icon(Icons.login_outlined),
          label: Text(
            invite?.supportsCloud == true && invite?.supportsLan != true
                ? 'Join group'
                : 'Pair now',
          ),
        ),
        const SizedBox(height: 12),
        TextButton.icon(
          onPressed: _busy
              ? null
              : () {
                  setState(() {
                    _mode = _MobileOnboardingMode.overview;
                    _showManualJoin = false;
                  });
                },
          icon: const Icon(Icons.arrow_back),
          label: const Text('Back'),
        ),
      ],
    );
  }

  Widget _buildPaired(BuildContext context) {
    final paired = _bearerToken != null && _bearerToken!.isNotEmpty;
    if (paired) {
      final workspace = _mobileWorkspace;
      if (workspace != null) {
        return MobileWorkspacePanel(
          workspace: workspace,
          loading: _loadingGallery,
          busy: _busy,
          error: _galleryError,
          onRefresh: _refreshMobileGallery,
          onCheckSession: _checkSession,
          onRefreshSession: _refreshSession,
          onRevokeCurrentSession: _revokeCurrentSession,
          onRevokeDeviceSessions: _revokeDeviceSessions,
          onUploadNewestItem: _uploadNewestCameraRollItem,
          onOpenAsset: _openMobileAsset,
          previewImageFor: _previewImageFor,
          onSearch: _searchMobileWorkspace,
          fileTree: _mobileFileTree,
          fileTreeLoading: _loadingMobileFiles,
          fileTreeError: _mobileFileError,
          onRefreshFiles: _refreshMobileFiles,
          onDownloadFile: _downloadMobileFile,
          onToggleFavorite: _toggleMobileFavorite,
          onToggleArchived: _toggleMobileArchived,
        );
      }
      return MobileGalleryPanel(
        assets: _mobileAssets,
        loading: _loadingGallery,
        busy: _busy,
        error: _galleryError,
        onRefresh: _refreshMobileGallery,
        onCheckSession: _checkSession,
        onUploadNewestItem: _uploadNewestCameraRollItem,
        onOpenAsset: _openMobileAsset,
        previewImageFor: _previewImageFor,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ActionPanel(
          icon: paired ? Icons.verified_user_outlined : Icons.cloud_outlined,
          title: paired ? 'Local group session' : 'Metadata group',
          message: paired
              ? 'This device can upload and download originals through the paired desktop.'
              : 'This cloud group stores metadata only. Add a desktop or storage device before backup starts.',
          action: paired
              ? OutlinedButton.icon(
                  onPressed: _busy ? null : _checkSession,
                  icon: const Icon(Icons.verified_user_outlined),
                  label: const Text('Check session'),
                )
              : null,
        ),
        const SizedBox(height: 12),
        _ActionPanel(
          icon: Icons.photo_library_outlined,
          title: 'Camera roll access',
          message:
              'Grant media access before backing up originals into the group.',
          action: OutlinedButton.icon(
            onPressed: _busy ? null : _checkCameraRollAccess,
            icon: const Icon(Icons.folder_open_outlined),
            label: const Text('Check access'),
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              onPressed: _busy || !paired ? null : _uploadNewestCameraRollItem,
              icon: const Icon(Icons.cloud_upload_outlined),
              label: const Text('Upload newest item'),
            ),
            OutlinedButton.icon(
              onPressed: _busy || !paired ? null : _downloadFirstVaultOriginal,
              icon: const Icon(Icons.download_outlined),
              label: const Text('Download first original'),
            ),
          ],
        ),
        if (_cloudGroup != null || _cloudInvite != null) ...[
          const SizedBox(height: 16),
          _buildCloudGroupPanel(context),
        ],
      ],
    );
  }

  Widget _buildCloudGroupPanel(BuildContext context) {
    final invite = _cloudInvite;
    return _ActionPanel(
      icon: Icons.cloud_done_outlined,
      title: _cloudGroup?.name ?? 'Cloud group',
      message:
          'Cloud bootstrap stores group membership metadata only. Originals, thumbnails, vault keys, and bearer tokens stay off cloud services.',
      action: invite == null
          ? null
          : SizedBox(
              width: 180,
              child: QrImageView(
                data: invite.encode(),
                version: QrVersions.auto,
                backgroundColor: Theme.of(context).colorScheme.surface,
              ),
            ),
      secondaryAction: invite == null
          ? null
          : SelectableText(
              'Invite expires ${invite.expiresAt?.toLocal() ?? 'soon'}',
            ),
    );
  }
}

class _OnboardingAmbientBackground extends StatelessWidget {
  const _OnboardingAmbientBackground();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(
            top: -150,
            left: -150,
            child: _SoftColorField(
              size: 360,
              color: const Color(0xFFD5E3FD).withValues(alpha: 0.38),
            ),
          ),
          Positioned(
            right: -120,
            bottom: -120,
            child: _SoftColorField(
              size: 320,
              color: const Color(0xFFDAE2FD).withValues(alpha: 0.42),
            ),
          ),
        ],
      ),
    );
  }
}

class _SoftColorField extends StatelessWidget {
  const _SoftColorField({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        boxShadow: [BoxShadow(color: color, blurRadius: 120, spreadRadius: 40)],
      ),
    );
  }
}

class _OnboardingVaultGraphic extends StatelessWidget {
  const _OnboardingVaultGraphic();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 224,
      decoration: const BoxDecoration(
        color: AppColors.panelMuted,
        border: Border(bottom: BorderSide(color: Color(0xFFE4E2E4))),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _DottedFieldPainter(
                color: AppColors.navy.withValues(alpha: 0.10),
              ),
            ),
          ),
          SizedBox(
            width: 190,
            height: 190,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                const SizedBox(
                  width: 160,
                  height: 160,
                  child: CustomPaint(
                    painter: _DashedCirclePainter(color: AppColors.border),
                  ),
                ),
                const Positioned(
                  left: -5,
                  child: _OrbitDeviceIcon(icon: Icons.smartphone_outlined),
                ),
                const Positioned(
                  right: -5,
                  child: _OrbitDeviceIcon(icon: Icons.laptop_mac_outlined),
                ),
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.navy.withValues(alpha: 0.08),
                        blurRadius: 24,
                        offset: const Offset(0, 4),
                      ),
                      BoxShadow(
                        color: AppColors.navy.withValues(alpha: 0.04),
                        blurRadius: 3,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.shield,
                    color: Colors.white,
                    size: 40,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _OrbitDeviceIcon extends StatelessWidget {
  const _OrbitDeviceIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.panel,
        boxShadow: [
          BoxShadow(
            color: AppColors.navy.withValues(alpha: 0.08),
            blurRadius: 24,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: AppColors.navy.withValues(alpha: 0.04),
            blurRadius: 3,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Icon(icon, color: AppColors.navy, size: 22),
    );
  }
}

class _DottedFieldPainter extends CustomPainter {
  const _DottedFieldPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    const spacing = 16.0;
    for (var x = 0.0; x <= size.width; x += spacing) {
      for (var y = 0.0; y <= size.height; y += spacing) {
        canvas.drawCircle(Offset(x, y), 1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DottedFieldPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _DashedCirclePainter extends CustomPainter {
  const _DashedCirclePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide - paint.strokeWidth) / 2;
    const segments = 48;
    const dashFraction = 0.56;
    for (var i = 0; i < segments; i += 1) {
      final start = (i / segments) * 2 * 3.141592653589793;
      final sweep = (dashFraction / segments) * 2 * 3.141592653589793;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        start,
        sweep,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DashedCirclePainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

List<MobileAssetSummary> _mobileAssetsFromWorkspace(
  MobileWorkspaceSnapshot workspace,
) {
  return workspace.visibleAssets
      .map(
        (asset) => MobileAssetSummary(
          assetId: asset.id,
          originalFilename: asset.originalFilename,
          mediaKind: asset.mediaKind,
          mimeType: asset.mimeType,
          bytes: asset.bytes,
          contentHash: asset.contentHash,
          capturedAt: asset.capturedAt,
          available: asset.isAvailable,
        ),
      )
      .toList();
}

bool _deviceIsOnline(DeviceIdentity device) {
  if (device.revoked) {
    return false;
  }
  final lastSeen = device.lastSeenAt;
  if (lastSeen == null) {
    return false;
  }
  return DateTime.now().toUtc().difference(lastSeen.toUtc()).inMinutes <= 30;
}

String _relativeTime(DateTime? value) {
  if (value == null) {
    return 'Never seen';
  }
  final delta = DateTime.now().toUtc().difference(value.toUtc());
  if (delta.inSeconds < 60) {
    return 'Just now';
  }
  if (delta.inMinutes < 60) {
    return '${delta.inMinutes}m ago';
  }
  if (delta.inHours < 24) {
    return '${delta.inHours}h ago';
  }
  return '${delta.inDays}d ago';
}

String _formatBytes(int? bytes) {
  if (bytes == null || bytes <= 0) {
    return 'Unknown';
  }
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index += 1;
  }
  final precision = value >= 10 || index == 0 ? 0 : 1;
  return '${value.toStringAsFixed(precision)} ${units[index]}';
}

String _mobileUploadStatusLabel(MobileUploadStatus status) {
  switch (status) {
    case MobileUploadStatus.pending:
      return 'pending';
    case MobileUploadStatus.running:
      return 'running';
    case MobileUploadStatus.completed:
      return 'completed';
    case MobileUploadStatus.failed:
      return 'failed';
    case MobileUploadStatus.canceled:
      return 'canceled';
  }
}

String _durationLabel(Duration duration) {
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds.remainder(60);
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

class _LocalMonthBucket {
  const _LocalMonthBucket({required this.label, required this.assets});

  final String label;
  final List<AssetEntity> assets;
}

List<_LocalMonthBucket> _localMonthBuckets(List<AssetEntity> assets) {
  final buckets = <String, List<AssetEntity>>{};
  for (final asset in assets) {
    final label = DateFormat.yMMMM().format(asset.createDateTime.toLocal());
    buckets.putIfAbsent(label, () => <AssetEntity>[]).add(asset);
  }
  return buckets.entries
      .map((entry) => _LocalMonthBucket(label: entry.key, assets: entry.value))
      .toList(growable: false);
}

class _LocalAlbumPreview {
  const _LocalAlbumPreview({required this.count, required this.thumbnail});

  final int count;
  final Uint8List? thumbnail;
}

Future<_LocalAlbumPreview> _loadAlbumPreview(AssetPathEntity album) async {
  final count = await album.assetCountAsync;
  if (count <= 0) {
    return const _LocalAlbumPreview(count: 0, thumbnail: null);
  }
  final assets = await album.getAssetListRange(start: 0, end: 1);
  final thumbnail = assets.isEmpty
      ? null
      : await assets.first.thumbnailDataWithSize(
          const ThumbnailSize.square(320),
          quality: 82,
        );
  return _LocalAlbumPreview(count: count, thumbnail: thumbnail);
}

String _humanLabel(String value) {
  final cleaned = value.replaceAll(RegExp(r'[_-]+'), ' ').trim();
  if (cleaned.isEmpty) {
    return 'Unknown';
  }
  return cleaned
      .split(RegExp(r'\s+'))
      .map(
        (word) => word.isEmpty
            ? word
            : '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}',
      )
      .join(' ');
}

IconData _deviceIcon(String platform) {
  final lower = platform.toLowerCase();
  if (lower.contains('android') || lower.contains('ios')) {
    return Icons.smartphone_outlined;
  }
  if (lower.contains('linux') ||
      lower.contains('windows') ||
      lower.contains('mac') ||
      lower.contains('desktop')) {
    return Icons.desktop_mac_outlined;
  }
  if (lower.contains('nas') || lower.contains('server')) {
    return Icons.dns_outlined;
  }
  return Icons.devices_other_outlined;
}

IconData _jobIcon(JobRecord job) {
  final kind = job.kind.toLowerCase();
  if (kind.contains('ocr') || kind.contains('index')) {
    return Icons.document_scanner_outlined;
  }
  if (kind.contains('import')) {
    return Icons.file_download_outlined;
  }
  if (kind.contains('backup')) {
    return Icons.backup_outlined;
  }
  if (kind.contains('sync') || kind.contains('replica')) {
    return Icons.sync_outlined;
  }
  return Icons.work_history_outlined;
}

Color _jobColor(JobRecord job) {
  final status = job.status.toLowerCase();
  if (status.contains('fail') || status.contains('error')) {
    return AppColors.danger;
  }
  if (status.contains('complete') || status.contains('done')) {
    return AppColors.active;
  }
  if (status.contains('run') || status.contains('process')) {
    return AppColors.warning;
  }
  return AppColors.muted;
}

String _filterLabel(_MobileGalleryFilter filter) {
  return switch (filter) {
    _MobileGalleryFilter.all => 'All',
    _MobileGalleryFilter.photos => 'Photos',
    _MobileGalleryFilter.videos => 'Videos',
    _MobileGalleryFilter.documents => 'Docs',
    _MobileGalleryFilter.audio => 'Audio',
    _MobileGalleryFilter.archives => 'Archives',
    _MobileGalleryFilter.text => 'Text',
    _MobileGalleryFilter.other => 'Files',
    _MobileGalleryFilter.favorites => 'Favorites',
    _MobileGalleryFilter.thisDevice => 'This Device',
  };
}

IconData _assetKindIcon(String mediaKind, String mimeType) {
  final kind = mediaKind.toLowerCase();
  final mime = mimeType.toLowerCase();
  if (kind == 'video' || mime.startsWith('video/')) {
    return Icons.play_circle_outline;
  }
  if (kind == 'document' || mime == 'application/pdf') {
    return Icons.description_outlined;
  }
  if (kind == 'audio' || mime.startsWith('audio/')) {
    return Icons.audiotrack_outlined;
  }
  if (kind == 'archive') {
    return Icons.folder_zip_outlined;
  }
  if (kind == 'text' || mime.startsWith('text/')) {
    return Icons.article_outlined;
  }
  if (kind == 'other') {
    return Icons.insert_drive_file_outlined;
  }
  return Icons.image_outlined;
}

String? _validMobileFolderId(
  VaultFileTreeResponse? tree,
  String? preferredFolderId,
) {
  if (tree == null) {
    return null;
  }
  final preferred = _folderByIdMobileTree(tree, preferredFolderId);
  if (preferred != null) {
    return preferred.id;
  }
  return tree.roots.firstOrNull?.id;
}

VaultFileEntry? _folderByIdMobileTree(
  VaultFileTreeResponse tree,
  String? folderId,
) {
  if (folderId == null) {
    return null;
  }
  for (final entry in tree.entries) {
    if (entry.id == folderId && entry.isFolder) {
      return entry;
    }
  }
  return null;
}

List<VaultFileEntry> _childrenOfMobileTree(
  VaultFileTreeResponse tree,
  String parentId,
) {
  final children = tree.childrenOf(parentId);
  children.sort((left, right) {
    final kind = (left.isFile ? 1 : 0).compareTo(right.isFile ? 1 : 0);
    if (kind != 0) {
      return kind;
    }
    return left.name.toLowerCase().compareTo(right.name.toLowerCase());
  });
  return children;
}

List<VaultFileEntry> _mobileFilePathEntries(
  VaultFileTreeResponse tree,
  VaultFileEntry current,
) {
  final byId = {for (final entry in tree.entries) entry.id: entry};
  final path = <VaultFileEntry>[];
  var cursor = current;
  while (true) {
    path.insert(0, cursor);
    final parentId = cursor.parentId;
    if (parentId == null || !byId.containsKey(parentId)) {
      break;
    }
    cursor = byId[parentId]!;
  }
  return path;
}

IconData _vaultFileIcon(VaultFileEntry entry) {
  if (entry.isFolder) {
    return Icons.folder_outlined;
  }
  return _assetKindIcon(
    entry.mediaKind ?? 'other',
    entry.mimeType ?? 'application/octet-stream',
  );
}

String _vaultFileSubtitle(VaultFileEntry entry) {
  if (entry.isFolder) {
    return entry.isTrashed ? 'Folder - trash' : 'Folder';
  }
  return [
    entry.mediaKind ?? 'file',
    _formatBytes(entry.bytes),
    if (entry.isTrashed) 'trash',
  ].join(' - ');
}

class _ReferenceFileSummary extends StatelessWidget {
  const _ReferenceFileSummary({
    required this.folders,
    required this.files,
    required this.documents,
    required this.loading,
    required this.onRefresh,
  });

  final int folders;
  final int files;
  final int documents;
  final bool loading;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _ReferenceFileMetric(
                  icon: Icons.folder_outlined,
                  label: 'Folders',
                  value: '$folders',
                ),
                _ReferenceFileMetric(
                  icon: Icons.insert_drive_file_outlined,
                  label: 'Files',
                  value: '$files',
                ),
                _ReferenceFileMetric(
                  icon: Icons.description_outlined,
                  label: 'Docs',
                  value: '$documents',
                ),
                OutlinedButton.icon(
                  onPressed: loading ? null : onRefresh,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ReferenceFileMetric extends StatelessWidget {
  const _ReferenceFileMetric({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.canvas,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: theme.textTheme.labelSmall),
                Text(value, style: theme.textTheme.titleSmall),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ReferenceBreadcrumbRow extends StatelessWidget {
  const _ReferenceBreadcrumbRow({
    required this.tree,
    required this.current,
    required this.onOpen,
  });

  final VaultFileTreeResponse tree;
  final VaultFileEntry current;
  final ValueChanged<VaultFileEntry> onOpen;

  @override
  Widget build(BuildContext context) {
    final path = _mobileFilePathEntries(tree, current);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var index = 0; index < path.length; index++) ...[
            ActionChip(
              avatar: Icon(
                index == 0 ? Icons.cloud_queue : Icons.folder_outlined,
                size: 18,
              ),
              label: Text(path[index].name),
              onPressed: index == path.length - 1
                  ? null
                  : () => onOpen(path[index]),
            ),
            if (index < path.length - 1)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.chevron_right, size: 18),
              ),
          ],
        ],
      ),
    );
  }
}

class _ReferenceFileRow extends StatelessWidget {
  const _ReferenceFileRow({
    required this.entry,
    required this.disabled,
    this.onOpen,
    this.onDownload,
  });

  final VaultFileEntry entry;
  final bool disabled;
  final VoidCallback? onOpen;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: AppColors.panel,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: AppColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        onTap: disabled ? null : onOpen,
        leading: Icon(
          _vaultFileIcon(entry),
          color: entry.isFolder
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
        title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          _vaultFileSubtitle(entry),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: entry.isFile
            ? IconButton(
                onPressed: disabled ? null : onDownload,
                icon: const Icon(Icons.download_outlined),
                tooltip: 'Download file',
              )
            : const Icon(Icons.chevron_right),
      ),
    );
  }
}

class _MobileReferenceBottomNav extends StatelessWidget {
  const _MobileReferenceBottomNav({
    required this.selected,
    required this.onSelected,
  });

  final _MobilePairedTab selected;
  final ValueChanged<_MobilePairedTab> onSelected;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.panel,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 18,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SizedBox(
          height: 68,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _MobileReferenceNavItem(
                icon: Icons.photo_library_outlined,
                selectedIcon: Icons.photo_library,
                label: 'Gallery',
                selected: selected == _MobilePairedTab.gallery,
                onTap: () => onSelected(_MobilePairedTab.gallery),
              ),
              _MobileReferenceNavItem(
                icon: Icons.folder_outlined,
                selectedIcon: Icons.folder,
                label: 'Files',
                selected: selected == _MobilePairedTab.files,
                onTap: () => onSelected(_MobilePairedTab.files),
              ),
              _MobileReferenceNavItem(
                icon: Icons.search,
                selectedIcon: Icons.search,
                label: 'Search',
                selected: selected == _MobilePairedTab.search,
                onTap: () => onSelected(_MobilePairedTab.search),
              ),
              _MobileReferenceNavItem(
                icon: Icons.devices_outlined,
                selectedIcon: Icons.devices,
                label: 'Devices',
                selected: selected == _MobilePairedTab.devices,
                onTap: () => onSelected(_MobilePairedTab.devices),
              ),
              _MobileReferenceNavItem(
                icon: Icons.settings_outlined,
                selectedIcon: Icons.settings,
                label: 'Settings',
                selected: selected == _MobilePairedTab.settings,
                onTap: () => onSelected(_MobilePairedTab.settings),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileReferenceNavItem extends StatelessWidget {
  const _MobileReferenceNavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = selected
        ? AppColors.navy
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: selected
                ? Theme.of(context).colorScheme.secondaryContainer
                : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(selected ? selectedIcon : icon, color: foreground, size: 22),
              const SizedBox(height: 3),
              Text(
                label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: foreground,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileReferenceSearchAndFilters extends StatelessWidget {
  const _MobileReferenceSearchAndFilters({
    required this.controller,
    required this.selected,
    required this.onChanged,
    required this.onFilterSelected,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final _MobileGalleryFilter selected;
  final VoidCallback onChanged;
  final ValueChanged<_MobileGalleryFilter> onFilterSelected;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          onChanged: (_) => onChanged(),
          onSubmitted: onSubmitted,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Search places, people, or dates...',
            prefixIcon: const Icon(Icons.search),
            filled: true,
            fillColor: AppColors.panel,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(999),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(999),
              borderSide: const BorderSide(color: AppColors.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(999),
              borderSide: const BorderSide(color: AppColors.navy),
            ),
          ),
        ),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final filter in _MobileGalleryFilter.values) ...[
                _ReferenceFilterChip(
                  label: _filterLabel(filter),
                  selected: selected == filter,
                  onTap: () => onFilterSelected(filter),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _ReferenceFilterChip extends StatelessWidget {
  const _ReferenceFilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.navy : AppColors.panel,
      shape: StadiumBorder(
        side: BorderSide(color: selected ? AppColors.navy : AppColors.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: selected ? Colors.white : AppColors.slate,
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileSyncStrip extends StatelessWidget {
  const _MobileSyncStrip({
    required this.loading,
    required this.error,
    required this.workspace,
    required this.onRefresh,
    required this.onCreate,
    required this.onPair,
  });

  final bool loading;
  final String? error;
  final MobileWorkspaceSnapshot? workspace;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onCreate;
  final Future<void> Function() onPair;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vault = workspace?.vaultStatus;
    final total = vault?.assetsTotal ?? 0;
    final local = vault?.localAvailableAssets ?? 0;
    final online = workspace == null
        ? 0
        : (workspace!.devices.isEmpty
                  ? workspace!.vaultStatus.devices
                  : workspace!.devices)
              .where(_deviceIsOnline)
              .length;
    final deviceCount = workspace == null
        ? 0
        : (workspace!.devices.isEmpty
                  ? workspace!.vaultStatus.devices
                  : workspace!.devices)
              .length;
    final progress = total <= 0 ? 0.0 : (local / total).clamp(0.0, 1.0);
    final hasError = error != null;
    final color = hasError
        ? AppColors.warning
        : loading
        ? theme.colorScheme.secondary
        : AppColors.active;
    final title = hasError
        ? 'Group currently out of network'
        : loading
        ? 'Syncing to Vault...'
        : workspace == null
        ? 'Connect same-LAN group'
        : 'Same-network sync active';
    final message = hasError
        ? error!
        : workspace == null
        ? 'This phone media is visible now. Scan or refresh a desktop invite to add the other LAN devices.'
        : '$local of $total items available here • $online of $deviceCount devices on this LAN';

    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.035),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                hasError
                    ? Icons.cloud_off_outlined
                    : loading
                    ? Icons.sync
                    : Icons.cloud_done,
                color: color,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(title, style: theme.textTheme.titleSmall),
                      ),
                      if (workspace != null && !hasError)
                        Text(
                          '${(progress * 100).round()}%',
                          style: theme.textTheme.labelMedium,
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(message, style: theme.textTheme.bodySmall),
                  const SizedBox(height: 10),
                  if (loading)
                    const LinearProgressIndicator(minHeight: 2)
                  else if (workspace != null && !hasError)
                    LinearProgressIndicator(
                      minHeight: 3,
                      value: progress == 0 ? null : progress,
                      backgroundColor:
                          theme.colorScheme.surfaceContainerHighest,
                      color: color,
                    ),
                  if (workspace == null && !hasError && !loading) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: onCreate,
                          icon: const Icon(Icons.add_circle_outline),
                          label: const Text('Create group'),
                        ),
                        OutlinedButton.icon(
                          onPressed: onPair,
                          icon: const Icon(Icons.qr_code_scanner_outlined),
                          label: const Text('Join LAN group'),
                        ),
                      ],
                    ),
                  ] else if (hasError) ...[
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: onRefresh,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LocalMediaStatusStrip extends StatelessWidget {
  const _LocalMediaStatusStrip({
    required this.loading,
    required this.error,
    required this.assetCount,
    required this.albumCount,
    required this.onGrantAccess,
  });

  final bool loading;
  final String? error;
  final int assetCount;
  final int albumCount;
  final Future<void> Function() onGrantAccess;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasError = error != null;
    final title = loading
        ? 'Reading this phone...'
        : hasError
        ? 'This device gallery needs access'
        : 'This device is browsable';
    final message = loading
        ? 'Loading local photos and videos from Android media storage.'
        : hasError
        ? error!
        : '$assetCount recent items • $albumCount albums available on this phone';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              hasError ? Icons.photo_library_outlined : Icons.phone_android,
              color: hasError ? AppColors.warning : AppColors.navy,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(message, style: theme.textTheme.bodySmall),
                  if (loading) ...[
                    const SizedBox(height: 10),
                    const LinearProgressIndicator(minHeight: 2),
                  ],
                  if (hasError) ...[
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: onGrantAccess,
                        icon: const Icon(Icons.photo_library_outlined),
                        label: const Text('Allow photos'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReferenceEmptyGallery extends StatelessWidget {
  const _ReferenceEmptyGallery({
    required this.error,
    required this.allAssetCount,
    required this.onUpload,
  });

  final String? error;
  final int allAssetCount;
  final VoidCallback? onUpload;

  @override
  Widget build(BuildContext context) {
    final filtering = error == null && allAssetCount > 0;
    return _ReferenceNotice(
      icon: error == null ? Icons.photo_library_outlined : Icons.photo_library,
      title: filtering
          ? 'No matches in this view'
          : error == null
          ? 'No media on this phone yet'
          : 'Photo access needed',
      message: filtering
          ? 'Adjust the search or filter chips to return to the timeline.'
          : error == null
          ? 'Take photos or import from another device to start the local timeline.'
          : error!,
      action: FilledButton.icon(
        onPressed: onUpload,
        icon: const Icon(Icons.photo_library_outlined),
        label: const Text('Open photos'),
      ),
    );
  }
}

class _ReferenceMobileAssetTile extends StatelessWidget {
  const _ReferenceMobileAssetTile({
    required this.asset,
    required this.previewImage,
    required this.onTap,
  });

  final MobileAssetSummary asset;
  final ImageProvider<Object>? previewImage;
  final VoidCallback onTap;

  bool get _isVideo =>
      asset.mediaKind == 'video' || asset.mimeType.startsWith('video/');

  IconData get _icon => _assetKindIcon(asset.mediaKind, asset.mimeType);

  @override
  Widget build(BuildContext context) {
    final available = asset.available;
    return Semantics(
      button: true,
      label: asset.originalFilename,
      child: Material(
        color: AppColors.panelMuted,
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (previewImage != null)
                Image(
                  image: previewImage!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      _AssetFallback(isVideo: _isVideo, icon: _icon),
                )
              else
                _AssetFallback(isVideo: _isVideo, icon: _icon),
              if (!available)
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.canvas.withValues(alpha: 0.38),
                  ),
                ),
              Positioned(
                right: 6,
                top: 6,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.canvas.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Icon(
                      available ? Icons.cloud_done : Icons.cloud_off,
                      size: 15,
                      color: available ? AppColors.navy : AppColors.muted,
                    ),
                  ),
                ),
              ),
              if (_isVideo)
                Positioned(
                  left: 6,
                  bottom: 6,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.canvas.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      child: Icon(Icons.play_circle_outline, size: 15),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReferenceLocalAssetTile extends StatelessWidget {
  const _ReferenceLocalAssetTile({required this.asset, required this.onTap});

  final AssetEntity asset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isVideo = asset.type == AssetType.video;
    return Semantics(
      button: true,
      label: asset.title ?? 'Local media item',
      child: Material(
        color: AppColors.panelMuted,
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              FutureBuilder<Uint8List?>(
                future: asset.thumbnailDataWithSize(
                  const ThumbnailSize.square(260),
                  quality: 82,
                ),
                builder: (context, snapshot) {
                  final bytes = snapshot.data;
                  if (bytes == null || bytes.isEmpty) {
                    return _AssetFallback(isVideo: isVideo);
                  }
                  return Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (_, __, ___) =>
                        _AssetFallback(isVideo: isVideo),
                  );
                },
              ),
              Positioned(
                right: 6,
                top: 6,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.canvas.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Icon(
                      asset.isFavorite ? Icons.favorite : Icons.phone_android,
                      size: 15,
                      color: AppColors.navy,
                    ),
                  ),
                ),
              ),
              if (isVideo)
                Positioned(
                  left: 6,
                  bottom: 6,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.canvas.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.play_circle_outline, size: 14),
                          const SizedBox(width: 2),
                          Text(
                            _durationLabel(asset.videoDuration),
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LocalDeviceCollectionScreen extends StatelessWidget {
  const _LocalDeviceCollectionScreen({
    required this.title,
    required this.subtitle,
    required this.assets,
    required this.canUpload,
    required this.onUpload,
  });

  final String title;
  final String subtitle;
  final List<AssetEntity> assets;
  final bool canUpload;
  final Future<void> Function(AssetEntity asset) onUpload;

  Future<void> _openAsset(BuildContext context, AssetEntity asset) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => MobileMediaViewer.local(
          asset: asset,
          canUpload: canUpload,
          onUpload: () => onUpload(asset),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        top: false,
        child: assets.isEmpty
            ? const _ReferenceNotice(
                icon: Icons.photo_library_outlined,
                title: 'No media in this collection',
                message:
                    'This album or month does not currently expose any local items.',
              )
            : GridView.builder(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                itemCount: assets.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  childAspectRatio: 1,
                ),
                itemBuilder: (context, index) {
                  final asset = assets[index];
                  return _ReferenceLocalAssetTile(
                    asset: asset,
                    onTap: () => _openAsset(context, asset),
                  );
                },
              ),
      ),
    );
  }
}

class _AssetFallback extends StatelessWidget {
  const _AssetFallback({required this.isVideo, this.icon});

  final bool isVideo;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [AppColors.panelMuted, Color(0xFFE4E2E4)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Icon(
          icon ?? (isVideo ? Icons.play_circle_outline : Icons.image_outlined),
          color: AppColors.muted,
        ),
      ),
    );
  }
}

class _ReferenceNotice extends StatelessWidget {
  const _ReferenceNotice({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(message, style: theme.textTheme.bodyMedium),
                  if (action != null) ...[const SizedBox(height: 12), action!],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActiveMobileUploadNotice extends StatelessWidget {
  const _ActiveMobileUploadNotice({
    required this.upload,
    required this.filename,
    required this.cancelRequested,
    required this.onCancel,
  });

  final MobileUpload upload;
  final String filename;
  final bool cancelRequested;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = upload.bytesTotal;
    final received = total <= 0
        ? upload.bytesReceived
        : upload.bytesReceived.clamp(0, total).toInt();
    final progress = total <= 0 ? null : received / total;
    final canCancel =
        !cancelRequested &&
        (upload.status == MobileUploadStatus.pending ||
            upload.status == MobileUploadStatus.running);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.cloud_upload_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Uploading $filename',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_formatBytes(received)} of ${_formatBytes(total)} - ${_mobileUploadStatusLabel(upload.status)}',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: canCancel ? onCancel : null,
                  icon: const Icon(Icons.cancel_outlined),
                  label: Text(cancelRequested ? 'Canceling' : 'Cancel'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress),
            if (upload.errorDetail != null &&
                upload.errorDetail!.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                upload.errorDetail!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ignore: unused_element
class _ReferenceDiscoveryOverview extends StatelessWidget {
  const _ReferenceDiscoveryOverview({
    required this.workspace,
    required this.localAssets,
    required this.localAlbums,
    required this.onRefresh,
  });

  final MobileWorkspaceSnapshot? workspace;
  final List<AssetEntity> localAssets;
  final List<AssetPathEntity> localAlbums;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final albums = workspace?.albums ?? const <Album>[];
    final people = workspace?.people ?? const <PersonCluster>[];
    final places = workspace?.places ?? const <PlaceCluster>[];
    final events = workspace?.events ?? const <EventCluster>[];
    final localMonths = _localMonthBuckets(localAssets);
    final localPlaceCount = localAssets
        .where((asset) => asset.latLng != null)
        .length;
    final localFavoriteCount = localAssets
        .where((asset) => asset.isFavorite)
        .length;
    final localVideoCount = localAssets
        .where((asset) => asset.type == AssetType.video)
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (workspace == null) ...[
          _ReferenceNotice(
            icon: Icons.manage_search_outlined,
            title: 'Search your private gallery',
            message:
                'Find filenames, people, places, dates, OCR text, and indexed metadata from the paired desktop.',
            action: OutlinedButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh desktop'),
            ),
          ),
          const SizedBox(height: 16),
        ],
        Text('Organize', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 1.34,
          children: [
            _DiscoveryCountCard(
              icon: Icons.photo_album_outlined,
              title: 'Albums',
              count: localAlbums.length + albums.length,
              detail: 'Device and vault collections',
            ),
            _DiscoveryCountCard(
              icon: Icons.face_outlined,
              title: 'People',
              count: people.length,
              detail: people.isEmpty ? 'Index on desktop' : 'Face clusters',
            ),
            _DiscoveryCountCard(
              icon: Icons.location_on_outlined,
              title: 'Places',
              count: places.length + localPlaceCount,
              detail: 'GPS-derived',
            ),
            _DiscoveryCountCard(
              icon: Icons.event_outlined,
              title: 'Events',
              count: events.length + localMonths.length,
              detail: 'Months and memories',
            ),
          ],
        ),
        if (localAssets.isNotEmpty) ...[
          const SizedBox(height: 20),
          _LocalDeviceOrganizationSummary(
            assetCount: localAssets.length,
            albumCount: localAlbums.length,
            monthCount: localMonths.length,
            favoriteCount: localFavoriteCount,
            videoCount: localVideoCount,
          ),
        ],
        if (localAlbums.isNotEmpty) ...[
          const SizedBox(height: 20),
          _LocalAlbumsGrid(albums: localAlbums.take(4).toList()),
        ],
        if (localMonths.isNotEmpty) ...[
          const SizedBox(height: 20),
          _LocalMonthList(months: localMonths.take(5).toList()),
        ],
        if (people.isNotEmpty) ...[
          const SizedBox(height: 20),
          _PeopleStrip(people: people.take(8).toList()),
        ],
        if (places.isNotEmpty) ...[
          const SizedBox(height: 20),
          _PlacesGrid(places: places.take(4).toList()),
        ],
        if (events.isNotEmpty) ...[
          const SizedBox(height: 20),
          _EventsList(events: events.take(4).toList()),
        ],
        if (albums.isNotEmpty) ...[
          const SizedBox(height: 20),
          _AlbumsGrid(albums: albums.take(4).toList()),
        ],
      ],
    );
  }
}

class _LocalDeviceOrganizationSummary extends StatelessWidget {
  const _LocalDeviceOrganizationSummary({
    required this.assetCount,
    required this.albumCount,
    required this.monthCount,
    required this.favoriteCount,
    required this.videoCount,
  });

  final int assetCount;
  final int albumCount;
  final int monthCount;
  final int favoriteCount;
  final int videoCount;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.phone_android, color: AppColors.navy),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'This device organization',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ResultPill(label: 'Items', count: assetCount),
                _ResultPill(label: 'Albums', count: albumCount),
                _ResultPill(label: 'Months', count: monthCount),
                _ResultPill(label: 'Favorites', count: favoriteCount),
                _ResultPill(label: 'Videos', count: videoCount),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LocalAlbumsGrid extends StatelessWidget {
  const _LocalAlbumsGrid({required this.albums, this.onOpenAlbum});

  final List<AssetPathEntity> albums;
  final Future<void> Function(AssetPathEntity album)? onOpenAlbum;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _MiniSectionHeader(
          title: 'This Device Albums',
          trailing: '${albums.length} shown',
        ),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 1.2,
          children: [
            for (final album in albums)
              _LocalAlbumTile(
                album: album,
                onTap: onOpenAlbum == null ? null : () => onOpenAlbum!(album),
              ),
          ],
        ),
      ],
    );
  }
}

class _LocalAlbumTile extends StatelessWidget {
  const _LocalAlbumTile({required this.album, this.onTap});

  final AssetPathEntity album;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_LocalAlbumPreview>(
      future: _loadAlbumPreview(album),
      builder: (context, snapshot) {
        final preview = snapshot.data;
        return Semantics(
          button: onTap != null,
          label: '${album.isAll ? 'All Photos' : album.name} album',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: DecoratedBox(
                decoration: const BoxDecoration(color: AppColors.panel),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (preview?.thumbnail != null)
                      Image.memory(preview!.thumbnail!, fit: BoxFit.cover)
                    else
                      const _AssetFallback(isVideo: false),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.62),
                          ],
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                        ),
                      ),
                    ),
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: 12,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            album.isAll ? 'All Photos' : album.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(color: Colors.white),
                          ),
                          Text(
                            '${preview?.count ?? 0} items',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                    if (onTap != null)
                      Positioned(
                        right: 8,
                        top: 8,
                        child: IconButton.filled(
                          onPressed: onTap,
                          icon: const Icon(Icons.arrow_forward),
                          tooltip: 'Open album',
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.black.withValues(
                              alpha: 0.42,
                            ),
                            foregroundColor: Colors.white,
                            minimumSize: const Size(36, 36),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            padding: const EdgeInsets.all(8),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LocalMonthList extends StatelessWidget {
  const _LocalMonthList({required this.months, this.onOpenMonth});

  final List<_LocalMonthBucket> months;
  final Future<void> Function(_LocalMonthBucket month)? onOpenMonth;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _MiniSectionHeader(
          title: 'Events by Month',
          trailing: '${months.length} shown',
        ),
        const SizedBox(height: 10),
        for (final month in months) ...[
          _DiscoveryImageLessTile(
            icon: Icons.event_outlined,
            title: month.label,
            subtitle: '${month.assets.length} items',
            onTap: onOpenMonth == null ? null : () => onOpenMonth!(month),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _DiscoveryCountCard extends StatelessWidget {
  const _DiscoveryCountCard({
    required this.icon,
    required this.title,
    required this.count,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final int count;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: theme.colorScheme.primary),
            const Spacer(),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(
              '$count $detail',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _PeopleStrip extends StatelessWidget {
  const _PeopleStrip({required this.people});

  final List<PersonCluster> people;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _MiniSectionHeader(title: 'People', trailing: '${people.length} shown'),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final person in people) ...[
                SizedBox(
                  width: 82,
                  child: Column(
                    children: [
                      CircleAvatar(
                        radius: 30,
                        backgroundColor: AppColors.navy,
                        foregroundColor: Colors.white,
                        child: Text(
                          _initials(person.displayName),
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        person.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _PlacesGrid extends StatelessWidget {
  const _PlacesGrid({required this.places});

  final List<PlaceCluster> places;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _MiniSectionHeader(title: 'Places', trailing: '${places.length} shown'),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 1.45,
          children: [
            for (final place in places)
              _DiscoveryImageLessTile(
                icon: Icons.location_on_outlined,
                title: place.label,
                subtitle: '${place.assetIds.length} items',
              ),
          ],
        ),
      ],
    );
  }
}

class _EventsList extends StatelessWidget {
  const _EventsList({required this.events});

  final List<EventCluster> events;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _MiniSectionHeader(title: 'Events', trailing: '${events.length} shown'),
        const SizedBox(height: 10),
        for (final event in events) ...[
          _DiscoveryImageLessTile(
            icon: Icons.event_outlined,
            title: event.title,
            subtitle:
                '${DateFormat.MMMd().format(event.startAt.toLocal())} • ${event.assetIds.length} items',
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _AlbumsGrid extends StatelessWidget {
  const _AlbumsGrid({required this.albums});

  final List<Album> albums;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _MiniSectionHeader(title: 'Albums', trailing: '${albums.length} shown'),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 1.2,
          children: [
            for (final album in albums)
              _DiscoveryImageLessTile(
                icon: Icons.photo_album_outlined,
                title: album.title,
                subtitle: '${album.assetIds.length} items',
              ),
          ],
        ),
      ],
    );
  }
}

class _MiniSectionHeader extends StatelessWidget {
  const _MiniSectionHeader({required this.title, required this.trailing});

  final String title;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        Text(trailing, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}

class _DiscoveryImageLessTile extends StatelessWidget {
  const _DiscoveryImageLessTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: onTap != null,
      label: title,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.panel,
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, color: theme.colorScheme.primary),
                    const Spacer(),
                    if (onTap != null)
                      IconButton(
                        onPressed: onTap,
                        icon: const Icon(Icons.chevron_right),
                        tooltip: 'Open',
                        style: IconButton.styleFrom(
                          foregroundColor: theme.colorScheme.onSurfaceVariant,
                          minimumSize: const Size(36, 36),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          padding: EdgeInsets.zero,
                        ),
                      ),
                  ],
                ),
                const Spacer(),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReferenceSearchResultSummary extends StatelessWidget {
  const _ReferenceSearchResultSummary({required this.result});

  final SearchResponse result;

  @override
  Widget build(BuildContext context) {
    if (result.isEmpty) {
      return const _ReferenceNotice(
        icon: Icons.search_off_outlined,
        title: 'No matches',
        message: 'Try a different person, place, filename, date, or OCR term.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Results', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _ResultPill(label: 'Photos', count: result.assets.length),
            _ResultPill(label: 'People', count: result.people.length),
            _ResultPill(label: 'Places', count: result.places.length),
            _ResultPill(label: 'Events', count: result.events.length),
          ],
        ),
        if (result.people.isNotEmpty) ...[
          const SizedBox(height: 16),
          _PeopleStrip(people: result.people.take(8).toList()),
        ],
        if (result.places.isNotEmpty) ...[
          const SizedBox(height: 16),
          _PlacesGrid(places: result.places.take(4).toList()),
        ],
        if (result.events.isNotEmpty) ...[
          const SizedBox(height: 16),
          _EventsList(events: result.events.take(4).toList()),
        ],
      ],
    );
  }
}

class _ResultPill extends StatelessWidget {
  const _ResultPill({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Text(
          '$label $count',
          style: Theme.of(context).textTheme.labelMedium,
        ),
      ),
    );
  }
}

class _ReferenceJobCard extends StatelessWidget {
  const _ReferenceJobCard({required this.job});

  final JobRecord job;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _jobColor(job);
    final progress = (job.progress.clamp(0, 100) / 100).toDouble();
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.panel,
          border: Border.all(
            color: color == AppColors.danger
                ? AppColors.danger.withValues(alpha: 0.35)
                : AppColors.border,
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              right: 0,
              child: LinearProgressIndicator(
                value: progress == 0 ? null : progress,
                minHeight: 4,
                color: color,
                backgroundColor: Colors.transparent,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 18, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CircleAvatar(
                        radius: 20,
                        backgroundColor: theme.colorScheme.secondaryContainer,
                        foregroundColor: theme.colorScheme.onSecondaryContainer,
                        child: Icon(_jobIcon(job), size: 21),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _humanLabel(job.kind),
                              style: theme.textTheme.titleSmall,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              job.detail ??
                                  'Queued ${_relativeTime(job.queuedAt)}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      _StatusPill(label: _humanLabel(job.status), color: color),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          job.completedAt == null
                              ? 'Started ${_relativeTime(job.startedAt ?? job.queuedAt)}'
                              : 'Finished ${_relativeTime(job.completedAt)}',
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                      Text(
                        '${job.progress.clamp(0, 100)}%',
                        style: theme.textTheme.labelMedium,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReferenceDeviceRow extends StatelessWidget {
  const _ReferenceDeviceRow({required this.device});

  final DeviceIdentity device;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final revoked = device.revoked;
    final online = _deviceIsOnline(device);
    final status = revoked
        ? 'Revoked'
        : online
        ? 'Same network'
        : 'Not seen on LAN';
    final color = revoked
        ? AppColors.danger
        : online
        ? AppColors.active
        : AppColors.muted;
    final total = device.storageProfile.totalBytes;
    final available = device.storageProfile.availableBytes;
    final used = total == null || available == null ? null : total - available;
    final storageProgress = total == null || used == null || total <= 0
        ? null
        : used / total;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(
          color: online ? theme.colorScheme.secondary : AppColors.border,
          width: online ? 1.5 : 1,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 23,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  foregroundColor: theme.colorScheme.onSurfaceVariant,
                  child: Icon(_deviceIcon(device.platform)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      Text(
                        '${_humanLabel(device.platform)} • ${_relativeTime(device.lastSeenAt)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                _StatusPill(label: status, color: color),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Text(
                    device.storageProfile.acceptsStorage
                        ? 'Storage ${_formatBytes(used)} / ${_formatBytes(total)}'
                        : 'Browsing device',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
                Text(
                  device.storageProfile.lowBattery ? 'Low battery' : '',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: AppColors.warning,
                  ),
                ),
              ],
            ),
            if (storageProgress != null) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: storageProgress.clamp(0.0, 1.0),
                minHeight: 3,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                color: online ? AppColors.navy : AppColors.muted,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 7, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReferenceSettingsSection extends StatelessWidget {
  const _ReferenceSettingsSection({
    required this.title,
    required this.icon,
    required this.children,
    this.emphasized = false,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final borderColor = emphasized ? AppColors.navy : AppColors.border;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(color: borderColor, width: emphasized ? 1.6 : 1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (emphasized)
                  const _StatusPill(
                    label: 'E2E Enabled',
                    color: AppColors.navy,
                  ),
              ],
            ),
            const SizedBox(height: 14),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _ReferenceToggleRow extends StatelessWidget {
  const _ReferenceToggleRow({
    required this.title,
    required this.message,
    required this.value,
  });

  final String title;
  final String message;
  final bool value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(message, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          Switch(value: value, onChanged: null),
        ],
      ),
    );
  }
}

class _ReferenceInfoRow extends StatelessWidget {
  const _ReferenceInfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 108,
            child: Text(
              label.toUpperCase(),
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
          Expanded(
            child: Text(value, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}

class _ReferenceActionCard extends StatelessWidget {
  const _ReferenceActionCard({
    required this.icon,
    required this.title,
    required this.message,
    required this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(message, style: theme.textTheme.bodyMedium),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            action,
          ],
        ),
      ),
    );
  }
}

String _initials(String value) {
  final parts = value
      .trim()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty) {
    return '?';
  }
  return parts.take(2).map((part) => part[0].toUpperCase()).join();
}

class _ActionPanel extends StatelessWidget {
  const _ActionPanel({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.secondaryAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  final Widget? secondaryAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(message),
                  if (action != null || secondaryAction != null) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (action != null) action!,
                        if (secondaryAction != null) secondaryAction!,
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
