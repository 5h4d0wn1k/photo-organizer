import 'package:flutter/material.dart';

import '../../models/gallery_models.dart';
import '../../repositories/gallery_repository.dart';

class VaultsScreen extends StatefulWidget {
  const VaultsScreen({
    super.key,
    required this.repository,
  });

  final GalleryRepository repository;

  @override
  State<VaultsScreen> createState() => _VaultsScreenState();
}

class _VaultsScreenState extends State<VaultsScreen> {
  bool _loading = true;
  String? _error;
  List<Vault> _vaults = const [];
  List<VaultStatus> _statuses = const [];
  List<DeviceIdentity> _devices = const [];
  List<SyncTransfer> _transfers = const [];
  SyncNetworkStatus? _networkStatus;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final vaults = await widget.repository.fetchVaults();
      final statuses = <VaultStatus>[];
      for (final vault in vaults) {
        statuses.add(await widget.repository.fetchVaultStatus(vault.id));
      }
      final devices = await widget.repository.fetchDevices();
      final transfers = await widget.repository.fetchSyncTransfers();
      final networkStatus = await widget.repository.fetchSyncNetworkStatus();
      if (!mounted) {
        return;
      }
      setState(() {
        _vaults = vaults;
        _statuses = statuses;
        _devices = devices;
        _transfers = transfers;
        _networkStatus = networkStatus;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  Future<void> _runSync() async {
    try {
      await widget.repository.runSync();
      await _reload();
      _showMessage('Sync plan queued.');
    } catch (error) {
      _showMessage('$error');
    }
  }

  Future<void> _addStorageOnlyDevice() async {
    final controller = TextEditingController(text: 'Storage node');
    final name = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Add Storage Device'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Device name',
              prefixIcon: Icon(Icons.dns_outlined),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: () =>
                  Navigator.of(context).pop(controller.text.trim()),
              icon: const Icon(Icons.add),
              label: const Text('Add'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (name == null || name.isEmpty) {
      return;
    }
    try {
      await widget.repository.enrollDevice(
        displayName: name,
        platform: 'storage',
        trustLevel: DeviceTrustLevel.storageOnly,
        role: DeviceRole.storageOnly,
      );
      await _reload();
      _showMessage('Storage-only device enrolled.');
    } catch (error) {
      _showMessage('$error');
    }
  }

  Future<void> _retryTransfer(String id) async {
    try {
      await widget.repository.retrySyncTransfer(id);
      await _reload();
    } catch (error) {
      _showMessage('$error');
    }
  }

  Future<void> _cancelTransfer(String id) async {
    try {
      await widget.repository.cancelSyncTransfer(id);
      await _reload();
    } catch (error) {
      _showMessage('$error');
    }
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading && _vaults.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _vaults.isEmpty) {
      return Center(
        child: FilledButton.icon(
          onPressed: _reload,
          icon: const Icon(Icons.refresh),
          label: Text(_error!),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: _loading ? null : _runSync,
                icon: const Icon(Icons.sync),
                label: const Text('Run Sync'),
              ),
              OutlinedButton.icon(
                onPressed: _loading ? null : _addStorageOnlyDevice,
                icon: const Icon(Icons.dns_outlined),
                label: const Text('Add Storage Device'),
              ),
              OutlinedButton.icon(
                onPressed: _loading ? null : _reload,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _NetworkPanel(status: _networkStatus),
          const SizedBox(height: 20),
          Text('Vaults', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          if (_statuses.isEmpty)
            const _EmptyPanel(
              icon: Icons.lock_outline,
              title: 'No vaults found',
              message: 'Initialize the library to create the local vault.',
            )
          else
            for (final status in _statuses) _VaultStatusTile(status: status),
          const SizedBox(height: 24),
          Text('Devices', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          if (_devices.isEmpty)
            const _EmptyPanel(
              icon: Icons.devices_other_outlined,
              title: 'No devices',
              message: 'This library has not enrolled any devices yet.',
            )
          else
            for (final device in _devices) _DeviceTile(device: device),
          const SizedBox(height: 24),
          Text('Transfers', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          if (_transfers.isEmpty)
            const _EmptyPanel(
              icon: Icons.swap_horiz_outlined,
              title: 'No transfers queued',
              message: 'Run sync after adding storage-capable devices.',
            )
          else
            for (final transfer in _transfers)
              _TransferTile(
                transfer: transfer,
                onRetry: () => _retryTransfer(transfer.id),
                onCancel: () => _cancelTransfer(transfer.id),
              ),
        ],
      ),
    );
  }
}

class _NetworkPanel extends StatelessWidget {
  const _NetworkPanel({required this.status});

  final SyncNetworkStatus? status;

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
        child: Wrap(
          spacing: 18,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Icon(
              status?.started == true ? Icons.hub_outlined : Icons.hub_outlined,
              color: theme.colorScheme.primary,
            ),
            _Metric(
              label: 'Transport',
              value: status?.transport ?? 'unknown',
            ),
            _Metric(
              label: 'Pending',
              value: '${status?.pendingTransferCount ?? 0}',
            ),
            _Metric(
              label: 'Active',
              value: '${status?.activeTransferCount ?? 0}',
            ),
            _Metric(
              label: 'Completed',
              value: '${status?.completedTransferCount ?? 0}',
            ),
            SizedBox(
              width: 420,
              child: Text(
                status?.detail ?? 'Sync network status is unavailable.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VaultStatusTile extends StatelessWidget {
  const _VaultStatusTile({required this.status});

  final VaultStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final policy = status.vault.storagePolicy;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(
        status.policySatisfied
            ? Icons.verified_user_outlined
            : Icons.warning_amber_outlined,
        color: status.policySatisfied
            ? theme.colorScheme.primary
            : theme.colorScheme.error,
      ),
      title: Text(status.vault.name),
      subtitle: Text(
        '${policy.mode.wireValue.replaceAll('_', ' ')} | ${status.localAvailableAssets}/${status.assetsTotal} local | ${status.underReplicatedBlobs} under-replicated',
      ),
      trailing: Text('${policy.minReplicas}x'),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({required this.device});

  final DeviceIdentity device;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(
        device.trustLevel == DeviceTrustLevel.storageOnly
            ? Icons.dns_outlined
            : Icons.devices_outlined,
        color: device.revoked ? theme.disabledColor : theme.colorScheme.primary,
      ),
      title: Text(device.displayName),
      subtitle: Text(
        '${device.platform} | ${device.trustLevel.wireValue.replaceAll('_', ' ')} | ${device.revoked ? 'revoked' : 'active'}',
      ),
      trailing: device.storageProfile.acceptsStorage
          ? const Icon(Icons.storage_outlined)
          : const Icon(Icons.visibility_outlined),
    );
  }
}

class _TransferTile extends StatelessWidget {
  const _TransferTile({
    required this.transfer,
    required this.onRetry,
    required this.onCancel,
  });

  final SyncTransfer transfer;
  final VoidCallback onRetry;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final canRetry = transfer.status == SyncTransferStatus.failed ||
        transfer.status == SyncTransferStatus.aborted;
    final canCancel = transfer.status == SyncTransferStatus.pending ||
        transfer.status == SyncTransferStatus.running;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: const Icon(Icons.swap_horiz_outlined),
      title: Text(transfer.blobId),
      subtitle: Text(
        '${transfer.status.name} | ${transfer.bytesCompleted}/${transfer.bytesTotal} bytes',
      ),
      trailing: Wrap(
        spacing: 4,
        children: [
          IconButton(
            onPressed: canRetry ? onRetry : null,
            icon: const Icon(Icons.refresh),
            tooltip: 'Retry transfer',
          ),
          IconButton(
            onPressed: canCancel ? onCancel : null,
            icon: const Icon(Icons.cancel_outlined),
            tooltip: 'Cancel transfer',
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 120,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelMedium),
          const SizedBox(height: 3),
          Text(
            value,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

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
          children: [
            Icon(icon, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleMedium),
                  Text(message, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
