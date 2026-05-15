import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../api/local_api_client.dart';

class MobilePairingScreen extends StatefulWidget {
  const MobilePairingScreen({super.key});

  @override
  State<MobilePairingScreen> createState() => _MobilePairingScreenState();
}

class _MobilePairingScreenState extends State<MobilePairingScreen> {
  static const _storage = FlutterSecureStorage();
  static const _pairingKey = 'private_gallery.pending_pairing_payload';
  static const _desktopUrlKey = 'private_gallery.desktop_url';
  static const _bearerTokenKey = 'private_gallery.mobile_bearer_token';
  static const _deviceNameKey = 'private_gallery.mobile_device_name';
  static const _deviceClaim = 'private-gallery-mobile-v1';

  final _desktopUrlController =
      TextEditingController(text: 'http://127.0.0.1:4821');
  final _pairingTokenController = TextEditingController();
  final _deviceNameController = TextEditingController(text: 'Android phone');
  MobileScannerController? _scannerController;
  var _scanning = false;
  var _busy = false;
  String? _bearerToken;
  String? _status;

  @override
  void initState() {
    super.initState();
    _loadSavedSession();
  }

  @override
  void dispose() {
    _desktopUrlController.dispose();
    _pairingTokenController.dispose();
    _deviceNameController.dispose();
    _scannerController?.dispose();
    super.dispose();
  }

  Future<void> _loadSavedSession() async {
    final desktopUrl = await _storage.read(key: _desktopUrlKey);
    final pairingPayload = await _storage.read(key: _pairingKey);
    final bearerToken = await _storage.read(key: _bearerTokenKey);
    final deviceName = await _storage.read(key: _deviceNameKey);
    if (!mounted) {
      return;
    }
    setState(() {
      if (desktopUrl != null && desktopUrl.trim().isNotEmpty) {
        _desktopUrlController.text = desktopUrl;
      }
      if (pairingPayload != null && pairingPayload.trim().isNotEmpty) {
        _pairingTokenController.text = pairingPayload;
      }
      if (deviceName != null && deviceName.trim().isNotEmpty) {
        _deviceNameController.text = deviceName;
      }
      _bearerToken = bearerToken;
      if (bearerToken != null && bearerToken.isNotEmpty) {
        _status = 'Saved mobile vault session loaded.';
      }
    });
  }

  LocalApiClient _client() {
    final uri = Uri.tryParse(_desktopUrlController.text.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const FormatException('Enter the desktop daemon URL.');
    }
    return LocalApiClient(baseUri: uri);
  }

  Future<void> _scanPairingQr() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      setState(() {
        _status =
            'Camera permission is required to scan the desktop pairing QR.';
      });
      return;
    }
    setState(() {
      _scannerController ??= MobileScannerController();
      _status = null;
      _scanning = true;
    });
  }

  Future<void> _savePairingPayload(String payload) async {
    final trimmed = payload.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _status = 'Enter or scan a pairing code from the desktop app.';
      });
      return;
    }
    final token = _extractPairingToken(trimmed);
    final stopFuture = _scannerController?.stop();
    await _storage.write(key: _pairingKey, value: token);
    await stopFuture;
    if (!mounted) {
      return;
    }
    setState(() {
      _pairingTokenController.text = token;
      _scanning = false;
      _status = 'Pairing token saved. Connect to desktop to complete pairing.';
    });
  }

  Future<void> _pairWithDesktop() async {
    await _runBusy(() async {
      final client = _client();
      final response = await client.pairMobileDevice(
        pairingToken: _extractPairingToken(_pairingTokenController.text),
        deviceName: _deviceNameController.text.trim().isEmpty
            ? 'Android phone'
            : _deviceNameController.text.trim(),
        platform: 'android',
      );
      await _storage.write(
        key: _desktopUrlKey,
        value: _desktopUrlController.text.trim(),
      );
      await _storage.write(
        key: _deviceNameKey,
        value: _deviceNameController.text.trim(),
      );
      await _storage.write(
        key: _bearerTokenKey,
        value: response.bearerToken,
      );
      setState(() {
        _bearerToken = response.bearerToken;
        _status =
            'Paired as ${response.device.displayName}. Session expires ${response.session.expiresAt.toLocal()}.';
      });
    });
  }

  Future<void> _checkSession() async {
    await _runBusy(() async {
      final token = _requireBearerToken();
      final session = await _client().fetchMobileSession(bearerToken: token);
      setState(() {
        _status =
            'Connected to vault ${session.vaultId}. Last seen ${session.lastSeenAt?.toLocal() ?? 'now'}.';
      });
    });
  }

  Future<void> _checkCameraRollAccess() async {
    await _runBusy(() async {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.isAuth) {
        setState(() {
          _status =
              'Photo library permission is required before mobile sync can run.';
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
    });
  }

  Future<void> _uploadNewestCameraRollItem() async {
    await _runBusy(() async {
      final token = _requireBearerToken();
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.isAuth) {
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
      final bytes = await file.readAsBytes();
      final filename = _filenameFor(entity, file);
      final reserved = await _client().reserveMobileUpload(
        bearerToken: token,
        originalFilename: filename,
        mediaKind: entity.type == AssetType.video ? 'video' : 'photo',
        mimeType: _mimeTypeFor(filename, entity.type),
        bytes: bytes.length,
        capturedAt: entity.createDateTime,
      );
      final completed = await _client().uploadMobileOriginal(
        bearerToken: token,
        uploadId: reserved.id,
        bytes: bytes,
      );
      setState(() {
        _status =
            'Uploaded $filename as asset ${completed.assetId ?? 'pending asset'}.';
      });
    });
  }

  Future<void> _downloadFirstVaultOriginal() async {
    await _runBusy(() async {
      final token = _requireBearerToken();
      final assets = await _client().fetchMobileAssets(bearerToken: token);
      if (assets.isEmpty) {
        setState(() {
          _status = 'No vault assets are available to download yet.';
        });
        return;
      }
      final asset = assets.first;
      final bytes = await _client().downloadMobileOriginal(
        bearerToken: token,
        assetId: asset.assetId,
      );
      final root = await getApplicationSupportDirectory();
      final downloadDir = Directory('${root.path}/mobile_downloads');
      await downloadDir.create(recursive: true);
      final filename = _safeLocalFilename(asset.originalFilename);
      final file = File('${downloadDir.path}/${asset.assetId}_$filename');
      await file.writeAsBytes(bytes, flush: true);
      setState(() {
        _status = 'Downloaded ${asset.originalFilename} to ${file.path}.';
      });
    });
  }

  Future<void> _runBusy(Future<void> Function() work) async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await work();
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = 'Mobile sync action failed: $error';
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

  String _requireBearerToken() {
    final token = _bearerToken?.trim();
    if (token == null || token.isEmpty) {
      throw StateError('Pair with the desktop vault first.');
    }
    return token;
  }

  String _extractPairingToken(String payload) {
    final trimmed = payload.trim();
    if (trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          final token = decoded['pairing_token'] ?? decoded['token'];
          if (token is String && token.trim().isNotEmpty) {
            return token.trim();
          }
        }
      } on FormatException {
        return trimmed;
      }
    }
    return trimmed;
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
    _savePairingPayload(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final paired = _bearerToken != null && _bearerToken!.isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('Private Gallery Mobile')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'Pair with desktop',
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Sync directly with your desktop vault over your local network. Originals stay on paired devices, not hosted storage.',
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 20),
            _ReadinessTile(
              icon: Icons.lock_outline,
              title: 'Local-first vault',
              message: paired
                  ? 'This device has a saved encrypted local API session.'
                  : 'Pairing data and session tokens are stored in Android secure storage.',
              action: paired
                  ? OutlinedButton.icon(
                      onPressed: _busy ? null : _checkSession,
                      icon: const Icon(Icons.verified_user_outlined),
                      label: const Text('Check session'),
                    )
                  : null,
            ),
            const SizedBox(height: 12),
            _ReadinessTile(
              icon: Icons.photo_library_outlined,
              title: 'Camera roll access',
              message:
                  'Grant media access to upload originals into the paired vault.',
              action: OutlinedButton.icon(
                onPressed: _busy ? null : _checkCameraRollAccess,
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('Check access'),
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _desktopUrlController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Desktop daemon URL',
                hintText: 'http://<laptop-hotspot-ip>:4821',
                helperText:
                    'Use the laptop hotspot or LAN IP. It can change between sessions.',
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _deviceNameController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'This device name',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pairingTokenController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Desktop pairing token',
                hintText: 'Paste pairing token or scan QR',
              ),
              minLines: 1,
              maxLines: 4,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _savePairingPayload(
                            _pairingTokenController.text,
                          ),
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Save token'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _scanPairingQr,
                  icon: const Icon(Icons.qr_code_scanner_outlined),
                  label: const Text('Scan QR'),
                ),
                FilledButton.icon(
                  onPressed: _busy ? null : _pairWithDesktop,
                  icon: const Icon(Icons.link_outlined),
                  label: const Text('Pair now'),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed:
                      _busy || !paired ? null : _uploadNewestCameraRollItem,
                  icon: const Icon(Icons.cloud_upload_outlined),
                  label: const Text('Upload newest item'),
                ),
                OutlinedButton.icon(
                  onPressed:
                      _busy || !paired ? null : _downloadFirstVaultOriginal,
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('Download first original'),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (_scanning) ...[
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
            const SizedBox(height: 24),
            Center(
              child: QrImageView(
                data: _deviceClaim,
                version: QrVersions.auto,
                size: 144,
                backgroundColor: theme.colorScheme.surface,
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                'Device claim preview for desktop enrollment',
                style: theme.textTheme.bodySmall,
              ),
            ),
            if (_busy) ...[
              const SizedBox(height: 20),
              const LinearProgressIndicator(minHeight: 2),
            ],
            if (_status != null) ...[
              const SizedBox(height: 20),
              Text(_status!, style: theme.textTheme.bodyMedium),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReadinessTile extends StatelessWidget {
  const _ReadinessTile({
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
                  if (action != null) ...[
                    const SizedBox(height: 12),
                    action!,
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
