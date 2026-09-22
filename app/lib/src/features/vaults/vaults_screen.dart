import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/device_group_invite.dart';
import '../../models/gallery_models.dart';
import '../../repositories/gallery_repository.dart';
import '../../services/cloud_bootstrap_service.dart';
import '../../widgets/app_ui.dart';

class VaultsScreen extends StatefulWidget {
  const VaultsScreen({super.key, required this.repository, this.cloud});

  final GalleryRepository repository;
  final CloudBootstrapGateway? cloud;

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
  LocalEndpointPayload? _localEndpoint;
  SyncPlan? _syncPlan;
  String? _syncPlanError;
  bool _planningSync = false;
  late final CloudBootstrapGateway _cloud;

  @override
  void initState() {
    super.initState();
    _cloud = widget.cloud ?? CloudBootstrapService();
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
      SyncPlan? syncPlan;
      String? syncPlanError;
      try {
        syncPlan = await widget.repository.fetchSyncPlan();
      } catch (error) {
        syncPlanError = '$error';
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _vaults = vaults;
        _statuses = statuses;
        _devices = devices;
        _transfers = transfers;
        _networkStatus = networkStatus;
        _syncPlan = syncPlan;
        _syncPlanError = syncPlanError;
        _planningSync = false;
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
      setState(() {
        _planningSync = true;
        _syncPlanError = null;
      });
      final plan = await widget.repository.runSync();
      await _reload();
      final completed = plan.executionResults
          .where(
            (result) => result.status == SyncTransferExecutionStatus.completed,
          )
          .length;
      final failed = plan.executionResults
          .where(
            (result) => result.status == SyncTransferExecutionStatus.failed,
          )
          .length;
      final skipped = plan.executionResults
          .where(
            (result) => result.status == SyncTransferExecutionStatus.skipped,
          )
          .length;
      if (plan.executionResults.isEmpty) {
        _showMessage('No P2P transfers ran.');
      } else {
        _showMessage(
          'P2P sync: $completed completed, $failed failed, $skipped skipped.',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _planningSync = false;
          _syncPlanError = '$error';
        });
      }
      _showMessage('$error');
    }
  }

  Future<void> _previewSyncPlan() async {
    setState(() {
      _planningSync = true;
      _syncPlanError = null;
    });
    try {
      final plan = await widget.repository.fetchSyncPlan();
      if (!mounted) {
        return;
      }
      setState(() {
        _syncPlan = plan;
        _planningSync = false;
      });
      if (plan.policySatisfied) {
        _showMessage('Protection policy is already satisfied.');
      } else {
        _showMessage(
          'Repair plan: ${plan.transfers.length} transfer(s), ${plan.underReplicatedBlobIds.length} under-replicated blob(s).',
        );
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _syncPlanError = '$error';
        _planningSync = false;
      });
      _showMessage('$error');
    }
  }

  Future<void> _startNetwork() async {
    try {
      await widget.repository.startSyncNetwork();
      final endpoint = await widget.repository.fetchLocalEndpoint();
      await _reload();
      if (!mounted) {
        return;
      }
      setState(() {
        _localEndpoint = endpoint;
      });
      _showMessage('P2P sync network started.');
    } catch (error) {
      _showMessage('$error');
    }
  }

  Future<void> _stopNetwork() async {
    try {
      await widget.repository.stopSyncNetwork();
      await _reload();
      if (!mounted) {
        return;
      }
      setState(() {
        _localEndpoint = null;
      });
      _showMessage('P2P sync network stopped.');
    } catch (error) {
      _showMessage('$error');
    }
  }

  Future<void> _createDeviceGroup() async {
    final controller = TextEditingController(text: 'My Private Gallery');
    final name = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Create Device Group'),
          content: SizedBox(
            width: 420,
            child: TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Group name',
                prefixIcon: Icon(Icons.lock_outline),
              ),
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
              label: const Text('Create'),
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
      final vault = await widget.repository.createVault(name: name);
      await _reload();
      _showMessage('Created ${vault.name}. Use Add Device to invite phones.');
    } catch (error) {
      _showMessage('$error');
    }
  }

  Future<void> _invitePhone() async {
    if (_statuses.isEmpty) {
      await _createDeviceGroup();
      return;
    }

    final status = _statuses.first;
    final suggestedUrl = await _suggestLanBaseUrl();
    if (!mounted) {
      return;
    }
    final draft = await _showInviteDraftDialog(
      vaultName: status.vault.name,
      suggestedUrl: suggestedUrl,
    );
    if (draft == null) {
      return;
    }

    try {
      final pairing = await widget.repository.createPairingSession(
        deviceName: draft.deviceName,
        platform: 'android',
        vaultId: status.vault.id,
      );
      final invite = DeviceGroupInvite.lan(
        groupId: status.vault.id,
        groupName: status.vault.name,
        baseUrl: draft.baseUrl,
        pairingToken: pairing.pairingToken,
        vaultId: status.vault.id,
        expiresAt: pairing.expiresAt,
      );
      if (!mounted) {
        return;
      }
      await _showInviteQrDialog(groupName: status.vault.name, invite: invite);
    } catch (error) {
      _showMessage('$error');
    }
  }

  Future<void> _joinDeviceGroup() async {
    final invite = await _showJoinGroupDialog();
    if (invite == null) {
      return;
    }
    if (invite.isExpired) {
      _showMessage('This invite expired. Create a fresh invite.');
      return;
    }
    if (!invite.supportsCloud) {
      _showMessage('Desktop join supports cloud or hybrid group invites.');
      return;
    }
    if (!_cloud.isConfigured) {
      _showMessage('Cloud bootstrap is not configured in this desktop build.');
      return;
    }

    try {
      final group = await _cloud.joinGroup(
        invite: invite,
        deviceName: Platform.localHostname.isEmpty
            ? 'Desktop'
            : Platform.localHostname,
        platform: Platform.operatingSystem,
      );
      final vault = await widget.repository.createVault(
        id: group.id,
        name: group.name,
      );
      await _reload();
      _showMessage('Joined ${vault.name}. Use Add device to invite phones.');
    } catch (error) {
      _showMessage('$error');
    }
  }

  Future<DeviceGroupInvite?> _showJoinGroupDialog() async {
    final controller = TextEditingController();
    final invite = await showDialog<DeviceGroupInvite>(
      context: context,
      builder: (context) {
        String? error;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Join Group'),
              content: SizedBox(
                width: 520,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Paste a cloud or hybrid invite from another device.',
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: controller,
                      autofocus: true,
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        labelText: 'Invite JSON',
                        prefixIcon: const Icon(Icons.key_outlined),
                        errorText: error,
                      ),
                      minLines: 3,
                      maxLines: 6,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton.icon(
                  onPressed: () {
                    try {
                      Navigator.of(
                        context,
                      ).pop(DeviceGroupInvite.parse(controller.text));
                    } on FormatException catch (parseError) {
                      setDialogState(() {
                        error = parseError.message;
                      });
                    }
                  },
                  icon: const Icon(Icons.login_outlined),
                  label: const Text('Join'),
                ),
              ],
            );
          },
        );
      },
    );
    controller.dispose();
    return invite;
  }

  Future<_InvitePhoneDraft?> _showInviteDraftDialog({
    required String vaultName,
    required String suggestedUrl,
  }) async {
    final urlController = TextEditingController(text: suggestedUrl);
    final nameController = TextEditingController(text: 'Android phone');
    final draft = await showDialog<_InvitePhoneDraft>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Add Device'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Group: $vaultName',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: urlController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Desktop LAN URL',
                    prefixIcon: Icon(Icons.link_outlined),
                    helperText:
                        'Use the laptop hotspot or LAN IP. Port must be 4821.',
                  ),
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Phone name',
                    prefixIcon: Icon(Icons.phone_android_outlined),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).pop(
                  _InvitePhoneDraft(
                    baseUrl: urlController.text.trim(),
                    deviceName: nameController.text.trim().isEmpty
                        ? 'Android phone'
                        : nameController.text.trim(),
                  ),
                );
              },
              icon: const Icon(Icons.qr_code_2_outlined),
              label: const Text('Create QR'),
            ),
          ],
        );
      },
    );
    urlController.dispose();
    nameController.dispose();
    return draft;
  }

  Future<void> _showInviteQrDialog({
    required String groupName,
    required DeviceGroupInvite invite,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Scan Invite QR'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'On the phone, open Private Gallery Mobile, tap Join group, then scan this QR.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                Center(
                  child: SizedBox(
                    width: 260,
                    height: 260,
                    child: QrImageView(
                      data: invite.encode(),
                      version: QrVersions.auto,
                      backgroundColor: Theme.of(context).colorScheme.surface,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _InviteDetail(label: 'Group', value: groupName),
                _InviteDetail(label: 'Desktop URL', value: invite.baseUrl!),
                _InviteDetail(
                  label: 'Expires',
                  value: '${invite.expiresAt?.toLocal() ?? 'soon'}',
                ),
                const SizedBox(height: 8),
                Text(
                  'The QR contains a one-time token for this vault. Originals, thumbnails, vault keys, and bearer tokens are not placed in cloud services.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: invite.encode()));
                if (context.mounted) {
                  Navigator.of(context).pop();
                }
                _showMessage('Invite copied.');
              },
              icon: const Icon(Icons.copy_outlined),
              label: const Text('Copy Invite'),
            ),
          ],
        );
      },
    );
  }

  Future<String> _suggestLanBaseUrl() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLoopback) {
            return 'http://${address.address}:4821';
          }
        }
      }
    } catch (_) {
      // Fall back to localhost when interface discovery is unavailable.
    }
    return 'http://127.0.0.1:4821';
  }

  Future<void> _showLocalEndpoint() async {
    try {
      final endpoint = await widget.repository.fetchLocalEndpoint();
      if (!mounted) {
        return;
      }
      setState(() {
        _localEndpoint = endpoint;
      });
      await showDialog<void>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('Local Endpoint'),
            content: SizedBox(
              width: 560,
              child: SelectableText(endpoint.pairingPayload),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
              FilledButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: endpoint.pairingPayload),
                  );
                  if (context.mounted) {
                    Navigator.of(context).pop();
                  }
                  _showMessage('Endpoint copied.');
                },
                icon: const Icon(Icons.copy_outlined),
                label: const Text('Copy'),
              ),
            ],
          );
        },
      );
    } catch (error) {
      _showMessage('$error');
    }
  }

  Future<void> _enrollPeerEndpoint() async {
    final controller = TextEditingController();
    final payload = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Paste Peer Endpoint'),
          content: SizedBox(
            width: 560,
            child: TextField(
              controller: controller,
              autofocus: true,
              minLines: 8,
              maxLines: 12,
              decoration: const InputDecoration(
                labelText: 'Endpoint JSON',
                prefixIcon: Icon(Icons.hub_outlined),
                border: OutlineInputBorder(),
              ),
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
              icon: const Icon(Icons.link_outlined),
              label: const Text('Enroll'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (payload == null || payload.isEmpty) {
      return;
    }
    try {
      final json = Map<String, dynamic>.from(jsonDecode(payload) as Map);
      final endpoint = PeerEndpointDescriptor.fromJson(json);
      await widget.repository.enrollDevice(
        displayName: endpoint.deviceName,
        platform: endpoint.platform,
        publicKey: endpoint.nodeId,
        trustLevel: endpoint.trustLevel,
        role: endpoint.role,
        endpoint: endpoint,
      );
      await _reload();
      _showMessage('Peer endpoint enrolled.');
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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
          AppSectionHeader(
            title: 'My Devices',
            subtitle:
                'Create or join a device group, invite phones, and track which devices can protect this local library.',
            trailing: _loading
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: _loading ? null : _runSync,
                icon: const Icon(Icons.sync),
                label: const Text('Run sync'),
              ),
              OutlinedButton.icon(
                onPressed: _loading ? null : _previewSyncPlan,
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('Preview repair'),
              ),
              FilledButton.icon(
                onPressed: _loading ? null : _createDeviceGroup,
                icon: const Icon(Icons.add),
                label: const Text('Create group'),
              ),
              FilledButton.icon(
                onPressed: _loading || _statuses.isEmpty ? null : _invitePhone,
                icon: const Icon(Icons.qr_code_2_outlined),
                label: const Text('Add device'),
              ),
              OutlinedButton.icon(
                onPressed: _loading ? null : _joinDeviceGroup,
                icon: const Icon(Icons.login_outlined),
                label: const Text('Join group'),
              ),
              OutlinedButton.icon(
                onPressed: _loading ? null : _startNetwork,
                icon: const Icon(Icons.play_arrow_outlined),
                label: const Text('Start Network'),
              ),
              OutlinedButton.icon(
                onPressed: _loading ? null : _stopNetwork,
                icon: const Icon(Icons.stop_outlined),
                label: const Text('Stop Network'),
              ),
              OutlinedButton.icon(
                onPressed: _loading ? null : _showLocalEndpoint,
                icon: const Icon(Icons.copy_outlined),
                label: const Text('Copy Endpoint'),
              ),
              OutlinedButton.icon(
                onPressed: _loading ? null : _enrollPeerEndpoint,
                icon: const Icon(Icons.link_outlined),
                label: const Text('Paste Peer Endpoint'),
              ),
              OutlinedButton.icon(
                onPressed: _loading ? null : _addStorageOnlyDevice,
                icon: const Icon(Icons.dns_outlined),
                label: const Text('Add Storage Placeholder'),
              ),
              OutlinedButton.icon(
                onPressed: _loading ? null : _reload,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _NetworkPanel(status: _networkStatus, endpoint: _localEndpoint),
          const SizedBox(height: 20),
          _SyncRepairPanel(
            plan: _syncPlan,
            error: _syncPlanError,
            loading: _planningSync,
            onPreview: _previewSyncPlan,
            onRun: _runSync,
          ),
          const SizedBox(height: 20),
          Text('Device groups', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          if (_statuses.isEmpty)
            const _EmptyPanel(
              icon: Icons.lock_outline,
              title: 'No vaults found',
              message: 'Create a device group before inviting phones.',
            )
          else
            for (final status in _statuses) _VaultStatusTile(status: status),
          const SizedBox(height: 24),
          Text(
            'Members and storage devices',
            style: theme.textTheme.titleLarge,
          ),
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
  const _NetworkPanel({required this.status, required this.endpoint});

  final SyncNetworkStatus? status;
  final LocalEndpointPayload? endpoint;

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
            _Metric(label: 'Transport', value: status?.transport ?? 'unknown'),
            _Metric(
              label: 'State',
              value: status?.started == true ? 'listening' : 'stopped',
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
                endpoint?.detail ??
                    status?.detail ??
                    'Sync network status is unavailable.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            if (status?.localNodeId?.isNotEmpty == true)
              SizedBox(
                width: 240,
                child: Text(
                  status!.localNodeId!,
                  overflow: TextOverflow.ellipsis,
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
    return AppSurface(
      padding: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(
          status.policySatisfied
              ? Icons.verified_user_outlined
              : Icons.warning_amber_outlined,
          color: status.policySatisfied
              ? theme.colorScheme.tertiary
              : theme.colorScheme.error,
        ),
        title: Text(status.vault.name),
        subtitle: Text(
          '${policy.mode.wireValue.replaceAll('_', ' ')} | ${status.localAvailableAssets}/${status.assetsTotal} local | ${status.underReplicatedBlobs} under-replicated',
        ),
        trailing: AppStatusBadge(
          label: status.policySatisfied
              ? 'Protected'
              : '${policy.minReplicas}x needed',
          tone: status.policySatisfied
              ? AppStatusTone.success
              : AppStatusTone.warning,
          icon: status.policySatisfied
              ? Icons.shield_outlined
              : Icons.warning_amber_outlined,
        ),
      ),
    );
  }
}

class _SyncRepairPanel extends StatelessWidget {
  const _SyncRepairPanel({
    required this.plan,
    required this.error,
    required this.loading,
    required this.onPreview,
    required this.onRun,
  });

  final SyncPlan? plan;
  final String? error;
  final bool loading;
  final VoidCallback onPreview;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentPlan = plan;
    final runnableTransfers = currentPlan?.transfers.length ?? 0;
    final underReplicated = currentPlan?.underReplicatedBlobIds.length ?? 0;
    final conflicts = currentPlan?.conflicts.length ?? 0;
    final policySatisfied = currentPlan?.policySatisfied ?? false;
    final needsRepair = currentPlan != null && !policySatisfied;
    final detail =
        error ??
        currentPlan?.detail ??
        'Preview the repair plan to see under-replicated encrypted chunks, runnable peer transfers, and conflicts before starting LAN sync.';

    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                policySatisfied
                    ? Icons.verified_user_outlined
                    : Icons.health_and_safety_outlined,
                color: policySatisfied
                    ? theme.colorScheme.tertiary
                    : theme.colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Protection repair',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(detail, style: theme.textTheme.bodyMedium),
                  ],
                ),
              ),
              AppStatusBadge(
                label: policySatisfied
                    ? 'Protected'
                    : currentPlan == null
                    ? 'Not planned'
                    : 'Needs repair',
                tone: policySatisfied
                    ? AppStatusTone.success
                    : needsRepair
                    ? AppStatusTone.warning
                    : AppStatusTone.neutral,
                icon: policySatisfied
                    ? Icons.shield_outlined
                    : Icons.warning_amber_outlined,
              ),
            ],
          ),
          if (loading) ...[
            const SizedBox(height: 14),
            const LinearProgressIndicator(minHeight: 2),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 18,
            runSpacing: 12,
            children: [
              _Metric(label: 'Under-replicated', value: '$underReplicated'),
              _Metric(label: 'Runnable transfers', value: '$runnableTransfers'),
              _Metric(label: 'Conflicts', value: '$conflicts'),
            ],
          ),
          if (needsRepair && runnableTransfers == 0) ...[
            const SizedBox(height: 12),
            Text(
              'No runnable transfer is available yet. Start the network and enroll a fresh peer endpoint from a storage-capable device.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: loading ? null : onPreview,
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('Preview repair'),
              ),
              FilledButton.icon(
                onPressed:
                    loading || (currentPlan != null && runnableTransfers == 0)
                    ? null
                    : onRun,
                icon: const Icon(Icons.sync),
                label: const Text('Run repair'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({required this.device});

  final DeviceIdentity device;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = _deviceStatus(device);
    return AppSurface(
      padding: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(
          device.trustLevel == DeviceTrustLevel.storageOnly
              ? Icons.dns_outlined
              : Icons.devices_outlined,
          color: device.revoked
              ? theme.disabledColor
              : theme.colorScheme.primary,
        ),
        title: Text(device.displayName),
        subtitle: Text(
          '${device.platform} | ${device.trustLevel.wireValue.replaceAll('_', ' ')}',
        ),
        trailing: AppStatusBadge(
          label: status.label,
          tone: status.tone,
          icon: status.icon,
        ),
      ),
    );
  }
}

class _DeviceReachability {
  const _DeviceReachability({
    required this.label,
    required this.icon,
    required this.tone,
  });

  final String label;
  final IconData icon;
  final AppStatusTone tone;
}

_DeviceReachability _deviceStatus(DeviceIdentity device) {
  if (device.revoked) {
    return const _DeviceReachability(
      label: 'Revoked',
      icon: Icons.block_outlined,
      tone: AppStatusTone.danger,
    );
  }
  final lastSeen = device.lastSeenAt;
  if (lastSeen == null ||
      DateTime.now().toUtc().difference(lastSeen.toUtc()) >
          const Duration(minutes: 15)) {
    return const _DeviceReachability(
      label: 'Out of network',
      icon: Icons.cloud_off_outlined,
      tone: AppStatusTone.neutral,
    );
  }
  return const _DeviceReachability(
    label: 'Online',
    icon: Icons.cloud_done_outlined,
    tone: AppStatusTone.success,
  );
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
    final canRetry =
        transfer.status == SyncTransferStatus.failed ||
        transfer.status == SyncTransferStatus.aborted;
    final canCancel =
        transfer.status == SyncTransferStatus.pending ||
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

class _InvitePhoneDraft {
  const _InvitePhoneDraft({required this.baseUrl, required this.deviceName});

  final String baseUrl;
  final String deviceName;
}

class _InviteDetail extends StatelessWidget {
  const _InviteDetail({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(label, style: theme.textTheme.labelMedium),
          ),
          Expanded(
            child: SelectableText(value, style: theme.textTheme.bodyMedium),
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
