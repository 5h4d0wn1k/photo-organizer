import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:qr_flutter/qr_flutter.dart';

class MobilePairingScreen extends StatefulWidget {
  const MobilePairingScreen({super.key});

  @override
  State<MobilePairingScreen> createState() => _MobilePairingScreenState();
}

class _MobilePairingScreenState extends State<MobilePairingScreen> {
  static const _storage = FlutterSecureStorage();
  static const _pairingKey = 'private_gallery.pending_pairing_payload';
  static const _deviceClaim = 'private-gallery-mobile-v1';

  final _manualController = TextEditingController();
  MobileScannerController? _scannerController;
  var _scanning = false;
  var _busy = false;
  String? _status;

  @override
  void dispose() {
    _manualController.dispose();
    _scannerController?.dispose();
    super.dispose();
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
    final stopFuture = _scannerController?.stop();
    await _storage.write(key: _pairingKey, value: trimmed);
    await stopFuture;
    if (!mounted) {
      return;
    }
    setState(() {
      _manualController.text = trimmed;
      _scanning = false;
      _status =
          'Pairing payload saved on this device. Desktop enrollment handshake is the next sync milestone.';
    });
  }

  Future<void> _checkCameraRollAccess() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.isAuth) {
        setState(() {
          _status =
              'Photo library permission is required before camera-roll upload can start.';
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
    } catch (error) {
      setState(() {
        _status = 'Unable to check camera roll access: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
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
              'This Android client keeps media local and pairs with your desktop vault before camera-roll upload or remote original fetches are enabled.',
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 20),
            const _ReadinessTile(
              icon: Icons.lock_outline,
              title: 'Local-first vault',
              message:
                  'Pairing data is stored in Android secure storage. Photos are not uploaded to hosted services.',
            ),
            const SizedBox(height: 12),
            _ReadinessTile(
              icon: Icons.photo_library_outlined,
              title: 'Camera roll upload queue',
              message:
                  'Grant media access to prepare incremental upload scanning for the next sync step.',
              action: OutlinedButton.icon(
                onPressed: _busy ? null : _checkCameraRollAccess,
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('Check access'),
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _manualController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Desktop pairing payload',
                hintText: 'Paste pairing code or scan QR',
              ),
              minLines: 1,
              maxLines: 4,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _savePairingPayload(_manualController.text),
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Save pairing code'),
                ),
                OutlinedButton.icon(
                  onPressed: _scanPairingQr,
                  icon: const Icon(Icons.qr_code_scanner_outlined),
                  label: const Text('Scan desktop QR'),
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
