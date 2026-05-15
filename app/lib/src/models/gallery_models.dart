enum ImportMode {
  copy,
  reference,
  move,
}

extension ImportModeX on ImportMode {
  String get wireValue {
    switch (this) {
      case ImportMode.copy:
        return 'copy';
      case ImportMode.reference:
        return 'reference';
      case ImportMode.move:
        return 'move';
    }
  }

  String get label {
    switch (this) {
      case ImportMode.copy:
        return 'Copy into library';
      case ImportMode.reference:
        return 'Reference in place';
      case ImportMode.move:
        return 'Move into managed library';
    }
  }

  static ImportMode fromJson(String? value) {
    switch (value) {
      case 'move':
        return ImportMode.move;
      case 'reference':
        return ImportMode.reference;
      case 'copy':
      default:
        return ImportMode.copy;
    }
  }
}

enum ImportSourceKind {
  folder,
  removableDrive,
}

extension ImportSourceKindX on ImportSourceKind {
  String get wireValue {
    switch (this) {
      case ImportSourceKind.folder:
        return 'folder';
      case ImportSourceKind.removableDrive:
        return 'removable_drive';
    }
  }

  String get label {
    switch (this) {
      case ImportSourceKind.folder:
        return 'Selected folder';
      case ImportSourceKind.removableDrive:
        return 'Removable drive';
    }
  }

  static ImportSourceKind fromJson(String? value) {
    switch (value) {
      case 'removable_drive':
        return ImportSourceKind.removableDrive;
      case 'folder':
      default:
        return ImportSourceKind.folder;
    }
  }
}

enum ImportSessionStatus {
  scanned,
  committed,
  failed,
}

extension ImportSessionStatusX on ImportSessionStatus {
  String get wireValue {
    switch (this) {
      case ImportSessionStatus.scanned:
        return 'scanned';
      case ImportSessionStatus.committed:
        return 'committed';
      case ImportSessionStatus.failed:
        return 'failed';
    }
  }

  String get label {
    switch (this) {
      case ImportSessionStatus.scanned:
        return 'Scanned';
      case ImportSessionStatus.committed:
        return 'Committed';
      case ImportSessionStatus.failed:
        return 'Failed';
    }
  }

  static ImportSessionStatus fromJson(String? value) {
    switch (value) {
      case 'committed':
        return ImportSessionStatus.committed;
      case 'failed':
        return ImportSessionStatus.failed;
      case 'scanned':
      default:
        return ImportSessionStatus.scanned;
    }
  }
}

enum AppLaunchStatus {
  ready,
  setupRequired,
  daemonUnavailable,
  error,
}

enum DeviceRole {
  admin,
  contributor,
  viewer,
  storageOnly,
}

extension DeviceRoleX on DeviceRole {
  String get wireValue {
    switch (this) {
      case DeviceRole.admin:
        return 'admin';
      case DeviceRole.contributor:
        return 'contributor';
      case DeviceRole.viewer:
        return 'viewer';
      case DeviceRole.storageOnly:
        return 'storage_only';
    }
  }

  static DeviceRole fromJson(String? value) {
    switch (value) {
      case 'admin':
        return DeviceRole.admin;
      case 'viewer':
        return DeviceRole.viewer;
      case 'storage_only':
        return DeviceRole.storageOnly;
      case 'contributor':
      default:
        return DeviceRole.contributor;
    }
  }
}

enum DeviceTrustLevel {
  trusted,
  storageOnly,
}

extension DeviceTrustLevelX on DeviceTrustLevel {
  String get wireValue {
    switch (this) {
      case DeviceTrustLevel.trusted:
        return 'trusted';
      case DeviceTrustLevel.storageOnly:
        return 'storage_only';
    }
  }

  static DeviceTrustLevel fromJson(String? value) {
    switch (value) {
      case 'storage_only':
        return DeviceTrustLevel.storageOnly;
      case 'trusted':
      default:
        return DeviceTrustLevel.trusted;
    }
  }
}

enum StoragePolicyMode {
  maxPoolSingleCopy,
  protectedMin2,
  custom,
}

extension StoragePolicyModeX on StoragePolicyMode {
  String get wireValue {
    switch (this) {
      case StoragePolicyMode.maxPoolSingleCopy:
        return 'max_pool_single_copy';
      case StoragePolicyMode.protectedMin2:
        return 'protected_min_2';
      case StoragePolicyMode.custom:
        return 'custom';
    }
  }

  static StoragePolicyMode fromJson(String? value) {
    switch (value) {
      case 'max_pool_single_copy':
        return StoragePolicyMode.maxPoolSingleCopy;
      case 'custom':
        return StoragePolicyMode.custom;
      case 'protected_min_2':
      default:
        return StoragePolicyMode.protectedMin2;
    }
  }
}

enum ReplicaHealth {
  healthy,
  unverified,
  offline,
  corrupt,
  missing,
}

extension ReplicaHealthX on ReplicaHealth {
  static ReplicaHealth fromJson(String? value) {
    switch (value) {
      case 'unverified':
        return ReplicaHealth.unverified;
      case 'offline':
        return ReplicaHealth.offline;
      case 'corrupt':
        return ReplicaHealth.corrupt;
      case 'missing':
        return ReplicaHealth.missing;
      case 'healthy':
      default:
        return ReplicaHealth.healthy;
    }
  }
}

enum SyncTransferStatus {
  pending,
  running,
  completed,
  failed,
  aborted,
}

extension SyncTransferStatusX on SyncTransferStatus {
  static SyncTransferStatus fromJson(String? value) {
    switch (value) {
      case 'running':
        return SyncTransferStatus.running;
      case 'completed':
        return SyncTransferStatus.completed;
      case 'failed':
        return SyncTransferStatus.failed;
      case 'aborted':
        return SyncTransferStatus.aborted;
      case 'pending':
      default:
        return SyncTransferStatus.pending;
    }
  }
}

enum AssetAvailabilityState {
  localAvailable,
  remoteAvailable,
  remoteOffline,
  underReplicated,
  missing,
  corrupt,
  transferPending,
}

extension AssetAvailabilityStateX on AssetAvailabilityState {
  static AssetAvailabilityState fromJson(String? value) {
    switch (value) {
      case 'local_available':
        return AssetAvailabilityState.localAvailable;
      case 'remote_available':
        return AssetAvailabilityState.remoteAvailable;
      case 'remote_offline':
        return AssetAvailabilityState.remoteOffline;
      case 'missing':
        return AssetAvailabilityState.missing;
      case 'corrupt':
        return AssetAvailabilityState.corrupt;
      case 'transfer_pending':
        return AssetAvailabilityState.transferPending;
      case 'under_replicated':
      default:
        return AssetAvailabilityState.underReplicated;
    }
  }
}

enum NetworkPolicy {
  offlineOnly,
  askBeforeDownload,
  developerFetch,
}

extension NetworkPolicyX on NetworkPolicy {
  String get label {
    switch (this) {
      case NetworkPolicy.offlineOnly:
        return 'Offline only';
      case NetworkPolicy.askBeforeDownload:
        return 'Ask before download';
      case NetworkPolicy.developerFetch:
        return 'Developer fetch';
    }
  }

  static NetworkPolicy fromJson(String? value) {
    switch (value) {
      case 'offline_only':
        return NetworkPolicy.offlineOnly;
      case 'developer_fetch':
        return NetworkPolicy.developerFetch;
      case 'ask_before_download':
      default:
        return NetworkPolicy.askBeforeDownload;
    }
  }
}

enum ModelTask {
  faceDetection,
  faceEmbedding,
  sceneTagging,
  ocr,
  semanticEmbedding,
}

extension ModelTaskX on ModelTask {
  String get label {
    switch (this) {
      case ModelTask.faceDetection:
        return 'Face detection';
      case ModelTask.faceEmbedding:
        return 'Face embedding';
      case ModelTask.sceneTagging:
        return 'Scene tagging';
      case ModelTask.ocr:
        return 'OCR';
      case ModelTask.semanticEmbedding:
        return 'Semantic embedding';
    }
  }

  static ModelTask fromJson(String? value) {
    switch (value) {
      case 'face_embedding':
        return ModelTask.faceEmbedding;
      case 'scene_tagging':
        return ModelTask.sceneTagging;
      case 'ocr':
        return ModelTask.ocr;
      case 'semantic_embedding':
        return ModelTask.semanticEmbedding;
      case 'face_detection':
      default:
        return ModelTask.faceDetection;
    }
  }
}

enum ModelInstallStatus {
  notInstalled,
  installed,
  pendingReview,
  downloadBlocked,
  hashMismatch,
}

extension ModelInstallStatusX on ModelInstallStatus {
  String get label {
    switch (this) {
      case ModelInstallStatus.notInstalled:
        return 'Not installed';
      case ModelInstallStatus.installed:
        return 'Installed';
      case ModelInstallStatus.pendingReview:
        return 'Pending review';
      case ModelInstallStatus.downloadBlocked:
        return 'Download blocked';
      case ModelInstallStatus.hashMismatch:
        return 'Hash mismatch';
    }
  }

  static ModelInstallStatus fromJson(String? value) {
    switch (value) {
      case 'installed':
        return ModelInstallStatus.installed;
      case 'pending_review':
        return ModelInstallStatus.pendingReview;
      case 'download_blocked':
        return ModelInstallStatus.downloadBlocked;
      case 'hash_mismatch':
        return ModelInstallStatus.hashMismatch;
      case 'not_installed':
      default:
        return ModelInstallStatus.notInstalled;
    }
  }
}

class ModelArtifact {
  const ModelArtifact({
    required this.id,
    required this.name,
    required this.version,
    required this.task,
    required this.license,
    required this.sourceUrl,
    required this.expectedSha256,
    required this.installedPath,
    required this.installedSha256,
    required this.installStatus,
    required this.reviewNotes,
    required this.approvedForPersonalFamilyUse,
  });

  final String id;
  final String name;
  final String version;
  final ModelTask task;
  final String? license;
  final String? sourceUrl;
  final String? expectedSha256;
  final String? installedPath;
  final String? installedSha256;
  final ModelInstallStatus installStatus;
  final String reviewNotes;
  final bool approvedForPersonalFamilyUse;

  bool get installed => installStatus == ModelInstallStatus.installed;

  factory ModelArtifact.fromJson(Map<String, dynamic> json) {
    return ModelArtifact(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'Unknown model',
      version: json['version'] as String? ?? 'unknown',
      task: ModelTaskX.fromJson(json['task'] as String?),
      license: json['license'] as String?,
      sourceUrl: json['source_url'] as String?,
      expectedSha256: json['expected_sha256'] as String?,
      installedPath: json['installed_path'] as String?,
      installedSha256: json['installed_sha256'] as String?,
      installStatus:
          ModelInstallStatusX.fromJson(json['install_status'] as String?),
      reviewNotes: json['review_notes'] as String? ?? '',
      approvedForPersonalFamilyUse:
          json['approved_for_personal_family_use'] as bool? ?? false,
    );
  }
}

class ModelRuntimeDependency {
  const ModelRuntimeDependency({
    required this.name,
    required this.available,
    required this.version,
  });

  final String name;
  final bool available;
  final String? version;

  factory ModelRuntimeDependency.fromJson(Map<String, dynamic> json) {
    return ModelRuntimeDependency(
      name: json['name'] as String? ?? 'unknown',
      available: json['available'] as bool? ?? false,
      version: json['version'] as String?,
    );
  }
}

class ModelRuntimeStatus {
  const ModelRuntimeStatus({
    required this.ok,
    required this.runtime,
    required this.sidecarPath,
    required this.pythonExecutable,
    required this.pythonVersion,
    required this.offlineReady,
    required this.dependencies,
    required this.detail,
  });

  final bool ok;
  final String runtime;
  final String? sidecarPath;
  final String pythonExecutable;
  final String? pythonVersion;
  final bool offlineReady;
  final List<ModelRuntimeDependency> dependencies;
  final String detail;

  factory ModelRuntimeStatus.fromJson(Map<String, dynamic> json) {
    return ModelRuntimeStatus(
      ok: json['ok'] as bool? ?? false,
      runtime: json['runtime'] as String? ?? 'unknown',
      sidecarPath: json['sidecar_path'] as String?,
      pythonExecutable: json['python_executable'] as String? ?? 'python3',
      pythonVersion: json['python_version'] as String?,
      offlineReady: json['offline_ready'] as bool? ?? false,
      dependencies: _readList(json['dependencies'])
          .map((item) => ModelRuntimeDependency.fromJson(item))
          .toList(),
      detail: json['detail'] as String? ?? 'Runtime status unavailable.',
    );
  }
}

class PrivacyStatus {
  const PrivacyStatus({
    required this.networkPolicy,
    required this.daemonBindAddress,
    required this.loopbackOnly,
    required this.developerMode,
    required this.photoProcessingNetworkAllowed,
    required this.modelDownloadRequiresConfirmation,
    required this.telemetryEnabled,
    required this.analyticsEnabled,
    required this.cloudAiEnabled,
    required this.installedModels,
    required this.localOnlyDisclosure,
    required this.encryption,
  });

  final NetworkPolicy networkPolicy;
  final String daemonBindAddress;
  final bool loopbackOnly;
  final bool developerMode;
  final bool photoProcessingNetworkAllowed;
  final bool modelDownloadRequiresConfirmation;
  final bool telemetryEnabled;
  final bool analyticsEnabled;
  final bool cloudAiEnabled;
  final List<ModelArtifact> installedModels;
  final String localOnlyDisclosure;
  final EncryptionStatus encryption;

  bool get localOnlyHealthy =>
      loopbackOnly &&
      !photoProcessingNetworkAllowed &&
      !telemetryEnabled &&
      !analyticsEnabled &&
      !cloudAiEnabled;

  factory PrivacyStatus.fromJson(Map<String, dynamic> json) {
    return PrivacyStatus(
      networkPolicy: NetworkPolicyX.fromJson(json['network_policy'] as String?),
      daemonBindAddress: json['daemon_bind_address'] as String? ?? '',
      loopbackOnly: json['loopback_only'] as bool? ?? false,
      developerMode: json['developer_mode'] as bool? ?? false,
      photoProcessingNetworkAllowed:
          json['photo_processing_network_allowed'] as bool? ?? false,
      modelDownloadRequiresConfirmation:
          json['model_download_requires_confirmation'] as bool? ?? true,
      telemetryEnabled: json['telemetry_enabled'] as bool? ?? false,
      analyticsEnabled: json['analytics_enabled'] as bool? ?? false,
      cloudAiEnabled: json['cloud_ai_enabled'] as bool? ?? false,
      installedModels: _readList(json['installed_models'])
          .map((item) => ModelArtifact.fromJson(item))
          .toList(),
      localOnlyDisclosure: json['local_only_disclosure'] as String? ??
          'Photos and generated intelligence stay local.',
      encryption: json['encryption'] is Map
          ? EncryptionStatus.fromJson(
              (json['encryption'] as Map)
                  .map((key, value) => MapEntry(key.toString(), value)),
            )
          : const EncryptionStatus.unavailable(),
    );
  }
}

class EncryptionStatus {
  const EncryptionStatus({
    required this.databaseEncrypted,
    required this.derivedDataEncrypted,
    required this.keyStorage,
    required this.sensitiveIndexingAllowed,
    required this.warning,
  });

  final bool databaseEncrypted;
  final bool derivedDataEncrypted;
  final String? keyStorage;
  final bool sensitiveIndexingAllowed;
  final String warning;

  const EncryptionStatus.unavailable()
      : databaseEncrypted = false,
        derivedDataEncrypted = false,
        keyStorage = null,
        sensitiveIndexingAllowed = false,
        warning = 'Encryption status unavailable.';

  factory EncryptionStatus.fromJson(Map<String, dynamic> json) {
    return EncryptionStatus(
      databaseEncrypted: json['database_encrypted'] as bool? ?? false,
      derivedDataEncrypted: json['derived_data_encrypted'] as bool? ?? false,
      keyStorage: json['key_storage'] as String?,
      sensitiveIndexingAllowed:
          json['sensitive_indexing_allowed'] as bool? ?? false,
      warning: json['warning'] as String? ?? '',
    );
  }
}

class EncryptionActivationResult {
  const EncryptionActivationResult({
    required this.status,
    required this.backupPath,
    required this.activatedAt,
    required this.rowCountsVerified,
    required this.integrityCheck,
  });

  final EncryptionStatus status;
  final String backupPath;
  final DateTime? activatedAt;
  final bool rowCountsVerified;
  final String integrityCheck;

  factory EncryptionActivationResult.fromJson(Map<String, dynamic> json) {
    final rawStatus = json['status'];
    return EncryptionActivationResult(
      status: rawStatus is Map
          ? EncryptionStatus.fromJson(
              rawStatus.map((key, value) => MapEntry(key.toString(), value)),
            )
          : const EncryptionStatus.unavailable(),
      backupPath: json['backup_path'] as String? ?? '',
      activatedAt: _readDateTime(json['activated_at']),
      rowCountsVerified: json['row_counts_verified'] as bool? ?? false,
      integrityCheck: json['integrity_check'] as String? ?? 'unknown',
    );
  }
}

class BackupVerification {
  const BackupVerification({
    required this.checkedAt,
    required this.databasePath,
    required this.libraryRoot,
    required this.databaseSha256,
    required this.assetsChecked,
    required this.missingAssetPaths,
    required this.vaultChunksChecked,
    required this.missingVaultChunkPaths,
    required this.modelFilesChecked,
    required this.missingModelPaths,
    required this.ok,
  });

  final DateTime? checkedAt;
  final String databasePath;
  final String libraryRoot;
  final String? databaseSha256;
  final int assetsChecked;
  final List<String> missingAssetPaths;
  final int vaultChunksChecked;
  final List<String> missingVaultChunkPaths;
  final int modelFilesChecked;
  final List<String> missingModelPaths;
  final bool ok;

  factory BackupVerification.fromJson(Map<String, dynamic> json) {
    return BackupVerification(
      checkedAt: _readDateTime(json['checked_at']),
      databasePath: json['database_path'] as String? ?? '',
      libraryRoot: json['library_root'] as String? ?? '',
      databaseSha256: json['database_sha256'] as String?,
      assetsChecked: (json['assets_checked'] as num?)?.toInt() ?? 0,
      missingAssetPaths: _readStringList(json['missing_asset_paths']),
      vaultChunksChecked: (json['vault_chunks_checked'] as num?)?.toInt() ?? 0,
      missingVaultChunkPaths:
          _readStringList(json['missing_vault_chunk_paths']),
      modelFilesChecked: (json['model_files_checked'] as num?)?.toInt() ?? 0,
      missingModelPaths: _readStringList(json['missing_model_paths']),
      ok: json['ok'] as bool? ?? false,
    );
  }
}

class BackupExportResult {
  const BackupExportResult({
    required this.exportedAt,
    required this.exportRoot,
    required this.manifestPath,
    required this.databaseCopiedTo,
    required this.databaseSha256,
    required this.assetsChecked,
    required this.missingAssetPaths,
    required this.mediaFilesCopied,
    required this.vaultChunksCopied,
    required this.bytesCopied,
    required this.modelFilesChecked,
    required this.missingModelPaths,
    required this.ok,
  });

  final DateTime? exportedAt;
  final String exportRoot;
  final String manifestPath;
  final String databaseCopiedTo;
  final String? databaseSha256;
  final int assetsChecked;
  final List<String> missingAssetPaths;
  final int mediaFilesCopied;
  final int vaultChunksCopied;
  final int bytesCopied;
  final int modelFilesChecked;
  final List<String> missingModelPaths;
  final bool ok;

  factory BackupExportResult.fromJson(Map<String, dynamic> json) {
    return BackupExportResult(
      exportedAt: _readDateTime(json['exported_at']),
      exportRoot: json['export_root'] as String? ?? '',
      manifestPath: json['manifest_path'] as String? ?? '',
      databaseCopiedTo: json['database_copied_to'] as String? ?? '',
      databaseSha256: json['database_sha256'] as String?,
      assetsChecked: (json['assets_checked'] as num?)?.toInt() ?? 0,
      missingAssetPaths: _readStringList(json['missing_asset_paths']),
      mediaFilesCopied: (json['media_files_copied'] as num?)?.toInt() ?? 0,
      vaultChunksCopied: (json['vault_chunks_copied'] as num?)?.toInt() ?? 0,
      bytesCopied: (json['bytes_copied'] as num?)?.toInt() ?? 0,
      modelFilesChecked: (json['model_files_checked'] as num?)?.toInt() ?? 0,
      missingModelPaths: _readStringList(json['missing_model_paths']),
      ok: json['ok'] as bool? ?? false,
    );
  }
}

class BackupRestorePlan {
  const BackupRestorePlan({
    required this.checkedAt,
    required this.exportRoot,
    required this.restoreRoot,
    required this.manifestPath,
    required this.databaseSourcePath,
    required this.databaseTargetPath,
    required this.mediaFilesAvailable,
    required this.vaultChunksAvailable,
    required this.missingPaths,
    required this.destinationConflicts,
    required this.requiresConfirmation,
    required this.ok,
    required this.detail,
  });

  final DateTime? checkedAt;
  final String exportRoot;
  final String restoreRoot;
  final String manifestPath;
  final String databaseSourcePath;
  final String databaseTargetPath;
  final int mediaFilesAvailable;
  final int vaultChunksAvailable;
  final List<String> missingPaths;
  final List<String> destinationConflicts;
  final bool requiresConfirmation;
  final bool ok;
  final String detail;

  factory BackupRestorePlan.fromJson(Map<String, dynamic> json) {
    return BackupRestorePlan(
      checkedAt: _readDateTime(json['checked_at']),
      exportRoot: json['export_root'] as String? ?? '',
      restoreRoot: json['restore_root'] as String? ?? '',
      manifestPath: json['manifest_path'] as String? ?? '',
      databaseSourcePath: json['database_source_path'] as String? ?? '',
      databaseTargetPath: json['database_target_path'] as String? ?? '',
      mediaFilesAvailable:
          (json['media_files_available'] as num?)?.toInt() ?? 0,
      vaultChunksAvailable:
          (json['vault_chunks_available'] as num?)?.toInt() ?? 0,
      missingPaths: _readStringList(json['missing_paths']),
      destinationConflicts: _readStringList(json['destination_conflicts']),
      requiresConfirmation: json['requires_confirmation'] as bool? ?? true,
      ok: json['ok'] as bool? ?? false,
      detail: json['detail'] as String? ?? '',
    );
  }
}

class BackupRestoreRunResult {
  const BackupRestoreRunResult({
    required this.restoredAt,
    required this.restoreRoot,
    required this.databaseRestoredTo,
    required this.mediaFilesCopied,
    required this.vaultChunksCopied,
    required this.bytesCopied,
    required this.ok,
    required this.detail,
  });

  final DateTime? restoredAt;
  final String restoreRoot;
  final String databaseRestoredTo;
  final int mediaFilesCopied;
  final int vaultChunksCopied;
  final int bytesCopied;
  final bool ok;
  final String detail;

  factory BackupRestoreRunResult.fromJson(Map<String, dynamic> json) {
    return BackupRestoreRunResult(
      restoredAt: _readDateTime(json['restored_at']),
      restoreRoot: json['restore_root'] as String? ?? '',
      databaseRestoredTo: json['database_restored_to'] as String? ?? '',
      mediaFilesCopied: (json['media_files_copied'] as num?)?.toInt() ?? 0,
      vaultChunksCopied: (json['vault_chunks_copied'] as num?)?.toInt() ?? 0,
      bytesCopied: (json['bytes_copied'] as num?)?.toInt() ?? 0,
      ok: json['ok'] as bool? ?? false,
      detail: json['detail'] as String? ?? '',
    );
  }
}

class StoragePolicy {
  const StoragePolicy({
    required this.mode,
    required this.minReplicas,
    required this.preferredDeviceIds,
    required this.excludedDeviceIds,
    required this.minFreeSpaceBytes,
    required this.allowMeteredNetwork,
    required this.pauseOnLowBattery,
  });

  final StoragePolicyMode mode;
  final int minReplicas;
  final List<String> preferredDeviceIds;
  final List<String> excludedDeviceIds;
  final int minFreeSpaceBytes;
  final bool allowMeteredNetwork;
  final bool pauseOnLowBattery;

  Map<String, dynamic> toJson() {
    return {
      'mode': mode.wireValue,
      'min_replicas': minReplicas,
      'preferred_device_ids': preferredDeviceIds,
      'excluded_device_ids': excludedDeviceIds,
      'min_free_space_bytes': minFreeSpaceBytes,
      'allow_metered_network': allowMeteredNetwork,
      'pause_on_low_battery': pauseOnLowBattery,
    };
  }

  factory StoragePolicy.fromJson(Map<String, dynamic> json) {
    return StoragePolicy(
      mode: StoragePolicyModeX.fromJson(json['mode'] as String?),
      minReplicas: (json['min_replicas'] as num?)?.toInt() ?? 2,
      preferredDeviceIds: _readStringList(json['preferred_device_ids']),
      excludedDeviceIds: _readStringList(json['excluded_device_ids']),
      minFreeSpaceBytes: (json['min_free_space_bytes'] as num?)?.toInt() ?? 0,
      allowMeteredNetwork: json['allow_metered_network'] as bool? ?? false,
      pauseOnLowBattery: json['pause_on_low_battery'] as bool? ?? true,
    );
  }
}

class DeviceStorageProfile {
  const DeviceStorageProfile({
    required this.deviceId,
    required this.totalBytes,
    required this.availableBytes,
    required this.reservedBytes,
    required this.acceptsStorage,
    required this.batteryPowered,
    required this.meteredNetwork,
    required this.lowBattery,
  });

  final String? deviceId;
  final int? totalBytes;
  final int? availableBytes;
  final int reservedBytes;
  final bool acceptsStorage;
  final bool batteryPowered;
  final bool meteredNetwork;
  final bool lowBattery;

  Map<String, dynamic> toJson() {
    return {
      if (deviceId != null) 'device_id': deviceId,
      if (totalBytes != null) 'total_bytes': totalBytes,
      if (availableBytes != null) 'available_bytes': availableBytes,
      'reserved_bytes': reservedBytes,
      'accepts_storage': acceptsStorage,
      'battery_powered': batteryPowered,
      'metered_network': meteredNetwork,
      'low_battery': lowBattery,
    };
  }

  factory DeviceStorageProfile.fromJson(Map<String, dynamic> json) {
    return DeviceStorageProfile(
      deviceId: json['device_id']?.toString(),
      totalBytes: (json['total_bytes'] as num?)?.toInt(),
      availableBytes: (json['available_bytes'] as num?)?.toInt(),
      reservedBytes: (json['reserved_bytes'] as num?)?.toInt() ?? 0,
      acceptsStorage: json['accepts_storage'] as bool? ?? true,
      batteryPowered: json['battery_powered'] as bool? ?? false,
      meteredNetwork: json['metered_network'] as bool? ?? false,
      lowBattery: json['low_battery'] as bool? ?? false,
    );
  }
}

class Vault {
  const Vault({
    required this.id,
    required this.name,
    required this.storagePolicy,
    required this.keyVersion,
    required this.deletionGraceDays,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final StoragePolicy storagePolicy;
  final int keyVersion;
  final int deletionGraceDays;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory Vault.fromJson(Map<String, dynamic> json) {
    final rawPolicy = json['storage_policy'];
    return Vault(
      id: json['id'].toString(),
      name: json['name'] as String? ?? 'Vault',
      storagePolicy: rawPolicy is Map
          ? StoragePolicy.fromJson(
              rawPolicy.map((key, value) => MapEntry(key.toString(), value)),
            )
          : StoragePolicy.fromJson(const <String, dynamic>{}),
      keyVersion: (json['key_version'] as num?)?.toInt() ?? 1,
      deletionGraceDays: (json['deletion_grace_days'] as num?)?.toInt() ?? 30,
      createdAt: _readDateTime(json['created_at']) ?? DateTime.now().toUtc(),
      updatedAt: _readDateTime(json['updated_at']) ?? DateTime.now().toUtc(),
    );
  }
}

class DeviceIdentity {
  const DeviceIdentity({
    required this.id,
    required this.displayName,
    required this.platform,
    required this.publicKey,
    required this.trustLevel,
    required this.storageProfile,
    required this.enrolledAt,
    required this.lastSeenAt,
    required this.revokedAt,
  });

  final String id;
  final String displayName;
  final String platform;
  final String publicKey;
  final DeviceTrustLevel trustLevel;
  final DeviceStorageProfile storageProfile;
  final DateTime enrolledAt;
  final DateTime? lastSeenAt;
  final DateTime? revokedAt;

  bool get revoked => revokedAt != null;

  factory DeviceIdentity.fromJson(Map<String, dynamic> json) {
    final rawProfile = json['storage_profile'];
    return DeviceIdentity(
      id: json['id'].toString(),
      displayName: json['display_name'] as String? ?? 'Device',
      platform: json['platform'] as String? ?? 'unknown',
      publicKey: json['public_key'] as String? ?? '',
      trustLevel: DeviceTrustLevelX.fromJson(json['trust_level'] as String?),
      storageProfile: rawProfile is Map
          ? DeviceStorageProfile.fromJson(
              rawProfile.map((key, value) => MapEntry(key.toString(), value)),
            )
          : DeviceStorageProfile.fromJson(const <String, dynamic>{}),
      enrolledAt: _readDateTime(json['enrolled_at']) ?? DateTime.now().toUtc(),
      lastSeenAt: _readDateTime(json['last_seen_at']),
      revokedAt: _readDateTime(json['revoked_at']),
    );
  }
}

class VaultMember {
  const VaultMember({
    required this.id,
    required this.vaultId,
    required this.deviceId,
    required this.role,
    required this.trustLevel,
    required this.displayName,
    required this.addedAt,
    required this.revokedAt,
  });

  final String id;
  final String vaultId;
  final String deviceId;
  final DeviceRole role;
  final DeviceTrustLevel trustLevel;
  final String displayName;
  final DateTime addedAt;
  final DateTime? revokedAt;

  factory VaultMember.fromJson(Map<String, dynamic> json) {
    return VaultMember(
      id: json['id'].toString(),
      vaultId: json['vault_id'].toString(),
      deviceId: json['device_id'].toString(),
      role: DeviceRoleX.fromJson(json['role'] as String?),
      trustLevel: DeviceTrustLevelX.fromJson(json['trust_level'] as String?),
      displayName: json['display_name'] as String? ?? 'Device',
      addedAt: _readDateTime(json['added_at']) ?? DateTime.now().toUtc(),
      revokedAt: _readDateTime(json['revoked_at']),
    );
  }
}

class BlobRecord {
  const BlobRecord({
    required this.id,
    required this.vaultId,
    required this.assetId,
    required this.contentHash,
    required this.encryptedHash,
    required this.bytes,
    required this.chunkCount,
    required this.encryptionKeyVersion,
    required this.createdAt,
    required this.tombstonedAt,
  });

  final String id;
  final String vaultId;
  final String assetId;
  final String contentHash;
  final String encryptedHash;
  final int bytes;
  final int chunkCount;
  final int encryptionKeyVersion;
  final DateTime createdAt;
  final DateTime? tombstonedAt;

  factory BlobRecord.fromJson(Map<String, dynamic> json) {
    return BlobRecord(
      id: json['id'].toString(),
      vaultId: json['vault_id'].toString(),
      assetId: json['asset_id'].toString(),
      contentHash: json['content_hash'] as String? ?? '',
      encryptedHash: json['encrypted_hash'] as String? ?? '',
      bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      chunkCount: (json['chunk_count'] as num?)?.toInt() ?? 0,
      encryptionKeyVersion:
          (json['encryption_key_version'] as num?)?.toInt() ?? 1,
      createdAt: _readDateTime(json['created_at']) ?? DateTime.now().toUtc(),
      tombstonedAt: _readDateTime(json['tombstoned_at']),
    );
  }
}

class BlobChunk {
  const BlobChunk({
    required this.id,
    required this.blobId,
    required this.chunkIndex,
    required this.contentHash,
    required this.encryptedHash,
    required this.bytes,
    required this.encryptedBytes,
    required this.localPath,
    required this.nonceHex,
    required this.aad,
  });

  final String id;
  final String blobId;
  final int chunkIndex;
  final String contentHash;
  final String encryptedHash;
  final int bytes;
  final int encryptedBytes;
  final String? localPath;
  final String? nonceHex;
  final String? aad;

  factory BlobChunk.fromJson(Map<String, dynamic> json) {
    return BlobChunk(
      id: json['id'].toString(),
      blobId: json['blob_id'].toString(),
      chunkIndex: (json['chunk_index'] as num?)?.toInt() ?? 0,
      contentHash: json['content_hash'] as String? ?? '',
      encryptedHash: json['encrypted_hash'] as String? ?? '',
      bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      encryptedBytes: (json['encrypted_bytes'] as num?)?.toInt() ?? 0,
      localPath: json['local_path'] as String?,
      nonceHex: json['nonce_hex'] as String?,
      aad: json['aad'] as String?,
    );
  }
}

class BlobReplica {
  const BlobReplica({
    required this.id,
    required this.blobId,
    required this.deviceId,
    required this.health,
    required this.bytesPresent,
    required this.verifiedAt,
    required this.transferId,
  });

  final String id;
  final String blobId;
  final String deviceId;
  final ReplicaHealth health;
  final int bytesPresent;
  final DateTime? verifiedAt;
  final String? transferId;

  factory BlobReplica.fromJson(Map<String, dynamic> json) {
    return BlobReplica(
      id: json['id'].toString(),
      blobId: json['blob_id'].toString(),
      deviceId: json['device_id'].toString(),
      health: ReplicaHealthX.fromJson(json['health'] as String?),
      bytesPresent: (json['bytes_present'] as num?)?.toInt() ?? 0,
      verifiedAt: _readDateTime(json['verified_at']),
      transferId: json['transfer_id']?.toString(),
    );
  }
}

class SyncTransfer {
  const SyncTransfer({
    required this.id,
    required this.vaultId,
    required this.blobId,
    required this.fromDeviceId,
    required this.toDeviceId,
    required this.status,
    required this.bytesTotal,
    required this.bytesCompleted,
    required this.startedAt,
    required this.updatedAt,
    required this.resumableUntil,
  });

  final String id;
  final String vaultId;
  final String blobId;
  final String? fromDeviceId;
  final String toDeviceId;
  final SyncTransferStatus status;
  final int bytesTotal;
  final int bytesCompleted;
  final DateTime? startedAt;
  final DateTime updatedAt;
  final DateTime resumableUntil;

  factory SyncTransfer.fromJson(Map<String, dynamic> json) {
    return SyncTransfer(
      id: json['id'].toString(),
      vaultId: json['vault_id'].toString(),
      blobId: json['blob_id'].toString(),
      fromDeviceId: json['from_device_id']?.toString(),
      toDeviceId: json['to_device_id'].toString(),
      status: SyncTransferStatusX.fromJson(json['status'] as String?),
      bytesTotal: (json['bytes_total'] as num?)?.toInt() ?? 0,
      bytesCompleted: (json['bytes_completed'] as num?)?.toInt() ?? 0,
      startedAt: _readDateTime(json['started_at']),
      updatedAt: _readDateTime(json['updated_at']) ?? DateTime.now().toUtc(),
      resumableUntil:
          _readDateTime(json['resumable_until']) ?? DateTime.now().toUtc(),
    );
  }
}

class SyncConflict {
  const SyncConflict({
    required this.id,
    required this.vaultId,
    required this.assetId,
    required this.field,
    required this.actorDeviceIds,
    required this.detectedAt,
    required this.detail,
  });

  final String id;
  final String vaultId;
  final String? assetId;
  final String field;
  final List<String> actorDeviceIds;
  final DateTime detectedAt;
  final String detail;

  factory SyncConflict.fromJson(Map<String, dynamic> json) {
    return SyncConflict(
      id: json['id'].toString(),
      vaultId: json['vault_id'].toString(),
      assetId: json['asset_id']?.toString(),
      field: json['field'] as String? ?? '',
      actorDeviceIds: _readStringList(json['actor_device_ids']),
      detectedAt: _readDateTime(json['detected_at']) ?? DateTime.now().toUtc(),
      detail: json['detail'] as String? ?? '',
    );
  }
}

class SyncPlan {
  const SyncPlan({
    required this.generatedAt,
    required this.vaultIds,
    required this.transfers,
    required this.conflicts,
    required this.underReplicatedBlobIds,
    required this.policySatisfied,
    required this.detail,
  });

  final DateTime generatedAt;
  final List<String> vaultIds;
  final List<SyncTransfer> transfers;
  final List<SyncConflict> conflicts;
  final List<String> underReplicatedBlobIds;
  final bool policySatisfied;
  final String detail;

  factory SyncPlan.fromJson(Map<String, dynamic> json) {
    return SyncPlan(
      generatedAt:
          _readDateTime(json['generated_at']) ?? DateTime.now().toUtc(),
      vaultIds: _readStringList(json['vault_ids']),
      transfers: _readList(json['transfers'])
          .map((item) => SyncTransfer.fromJson(item))
          .toList(),
      conflicts: _readList(json['conflicts'])
          .map((item) => SyncConflict.fromJson(item))
          .toList(),
      underReplicatedBlobIds:
          _readStringList(json['under_replicated_blob_ids']),
      policySatisfied: json['policy_satisfied'] as bool? ?? false,
      detail: json['detail'] as String? ?? '',
    );
  }
}

class SyncNetworkStatus {
  const SyncNetworkStatus({
    required this.started,
    required this.transport,
    required this.localDeviceId,
    required this.localNodeId,
    required this.directAddresses,
    required this.relayUrls,
    required this.activeTransferCount,
    required this.pendingTransferCount,
    required this.completedTransferCount,
    required this.failedTransferCount,
    required this.detail,
  });

  final bool started;
  final String transport;
  final String? localDeviceId;
  final String? localNodeId;
  final List<String> directAddresses;
  final List<String> relayUrls;
  final int activeTransferCount;
  final int pendingTransferCount;
  final int completedTransferCount;
  final int failedTransferCount;
  final String detail;

  factory SyncNetworkStatus.fromJson(Map<String, dynamic> json) {
    return SyncNetworkStatus(
      started: json['started'] as bool? ?? false,
      transport: json['transport'] as String? ?? 'unknown',
      localDeviceId: json['local_device_id']?.toString(),
      localNodeId: json['local_node_id'] as String?,
      directAddresses: _readStringList(json['direct_addresses']),
      relayUrls: _readStringList(json['relay_urls']),
      activeTransferCount:
          (json['active_transfer_count'] as num?)?.toInt() ?? 0,
      pendingTransferCount:
          (json['pending_transfer_count'] as num?)?.toInt() ?? 0,
      completedTransferCount:
          (json['completed_transfer_count'] as num?)?.toInt() ?? 0,
      failedTransferCount:
          (json['failed_transfer_count'] as num?)?.toInt() ?? 0,
      detail: json['detail'] as String? ?? '',
    );
  }
}

class AssetAvailability {
  const AssetAvailability({
    required this.assetId,
    required this.vaultId,
    required this.state,
    required this.localReplica,
    required this.reachableReplicaDeviceIds,
    required this.offlineReplicaDeviceIds,
    required this.replicaCount,
    required this.requiredReplicaCount,
    required this.detail,
  });

  final String assetId;
  final String? vaultId;
  final AssetAvailabilityState state;
  final bool localReplica;
  final List<String> reachableReplicaDeviceIds;
  final List<String> offlineReplicaDeviceIds;
  final int replicaCount;
  final int requiredReplicaCount;
  final String detail;

  bool get opensLocally => localReplica;

  factory AssetAvailability.fromJson(Map<String, dynamic> json) {
    return AssetAvailability(
      assetId: json['asset_id'].toString(),
      vaultId: json['vault_id']?.toString(),
      state: AssetAvailabilityStateX.fromJson(json['state'] as String?),
      localReplica: json['local_replica'] as bool? ?? false,
      reachableReplicaDeviceIds:
          _readStringList(json['reachable_replica_device_ids']),
      offlineReplicaDeviceIds:
          _readStringList(json['offline_replica_device_ids']),
      replicaCount: (json['replica_count'] as num?)?.toInt() ?? 0,
      requiredReplicaCount:
          (json['required_replica_count'] as num?)?.toInt() ?? 1,
      detail: json['detail'] as String? ?? '',
    );
  }
}

class VaultStatus {
  const VaultStatus({
    required this.vault,
    required this.members,
    required this.devices,
    required this.assetsTotal,
    required this.blobsTotal,
    required this.localAvailableAssets,
    required this.remoteAvailableAssets,
    required this.underReplicatedBlobs,
    required this.missingBlobs,
    required this.policySatisfied,
    required this.detail,
  });

  final Vault vault;
  final List<VaultMember> members;
  final List<DeviceIdentity> devices;
  final int assetsTotal;
  final int blobsTotal;
  final int localAvailableAssets;
  final int remoteAvailableAssets;
  final int underReplicatedBlobs;
  final int missingBlobs;
  final bool policySatisfied;
  final String detail;

  factory VaultStatus.fromJson(Map<String, dynamic> json) {
    final rawVault = json['vault'];
    return VaultStatus(
      vault: rawVault is Map
          ? Vault.fromJson(
              rawVault.map((key, value) => MapEntry(key.toString(), value)),
            )
          : Vault.fromJson(const <String, dynamic>{}),
      members: _readList(json['members'])
          .map((item) => VaultMember.fromJson(item))
          .toList(),
      devices: _readList(json['devices'])
          .map((item) => DeviceIdentity.fromJson(item))
          .toList(),
      assetsTotal: (json['assets_total'] as num?)?.toInt() ?? 0,
      blobsTotal: (json['blobs_total'] as num?)?.toInt() ?? 0,
      localAvailableAssets:
          (json['local_available_assets'] as num?)?.toInt() ?? 0,
      remoteAvailableAssets:
          (json['remote_available_assets'] as num?)?.toInt() ?? 0,
      underReplicatedBlobs:
          (json['under_replicated_blobs'] as num?)?.toInt() ?? 0,
      missingBlobs: (json['missing_blobs'] as num?)?.toInt() ?? 0,
      policySatisfied: json['policy_satisfied'] as bool? ?? false,
      detail: json['detail'] as String? ?? '',
    );
  }
}

class VaultInvite {
  const VaultInvite({
    required this.id,
    required this.vaultId,
    required this.invitedDeviceName,
    required this.role,
    required this.trustLevel,
    required this.inviteCode,
    required this.createdAt,
    required this.expiresAt,
    required this.acceptedAt,
  });

  final String id;
  final String vaultId;
  final String invitedDeviceName;
  final DeviceRole role;
  final DeviceTrustLevel trustLevel;
  final String inviteCode;
  final DateTime createdAt;
  final DateTime expiresAt;
  final DateTime? acceptedAt;

  factory VaultInvite.fromJson(Map<String, dynamic> json) {
    return VaultInvite(
      id: json['id'].toString(),
      vaultId: json['vault_id'].toString(),
      invitedDeviceName: json['invited_device_name'] as String? ?? '',
      role: DeviceRoleX.fromJson(json['role'] as String?),
      trustLevel: DeviceTrustLevelX.fromJson(json['trust_level'] as String?),
      inviteCode: json['invite_code'] as String? ?? '',
      createdAt: _readDateTime(json['created_at']) ?? DateTime.now().toUtc(),
      expiresAt: _readDateTime(json['expires_at']) ?? DateTime.now().toUtc(),
      acceptedAt: _readDateTime(json['accepted_at']),
    );
  }
}

class RelayEndpoint {
  const RelayEndpoint({
    required this.id,
    required this.deviceId,
    required this.nodeId,
    required this.relayUrl,
    required this.directAddresses,
    required this.lastSeenAt,
    required this.expiresAt,
  });

  final String id;
  final String deviceId;
  final String nodeId;
  final String? relayUrl;
  final List<String> directAddresses;
  final DateTime lastSeenAt;
  final DateTime expiresAt;

  factory RelayEndpoint.fromJson(Map<String, dynamic> json) {
    return RelayEndpoint(
      id: json['id'].toString(),
      deviceId: json['device_id'].toString(),
      nodeId: json['node_id'] as String? ?? '',
      relayUrl: json['relay_url'] as String?,
      directAddresses: _readStringList(json['direct_addresses']),
      lastSeenAt: _readDateTime(json['last_seen_at']) ?? DateTime.now().toUtc(),
      expiresAt: _readDateTime(json['expires_at']) ?? DateTime.now().toUtc(),
    );
  }
}

class CapabilityGrant {
  const CapabilityGrant({
    required this.id,
    required this.vaultId,
    required this.deviceId,
    required this.capability,
    required this.grantedByDeviceId,
    required this.grantedAt,
    required this.expiresAt,
  });

  final String id;
  final String vaultId;
  final String deviceId;
  final String capability;
  final String? grantedByDeviceId;
  final DateTime grantedAt;
  final DateTime? expiresAt;

  factory CapabilityGrant.fromJson(Map<String, dynamic> json) {
    return CapabilityGrant(
      id: json['id'].toString(),
      vaultId: json['vault_id'].toString(),
      deviceId: json['device_id'].toString(),
      capability: json['capability'] as String? ?? '',
      grantedByDeviceId: json['granted_by_device_id']?.toString(),
      grantedAt: _readDateTime(json['granted_at']) ?? DateTime.now().toUtc(),
      expiresAt: _readDateTime(json['expires_at']),
    );
  }
}

class ModelProvenance {
  const ModelProvenance({
    required this.modelName,
    required this.modelVersion,
    required this.modelHash,
    required this.createdAt,
    required this.rebuildable,
  });

  final String modelName;
  final String modelVersion;
  final String? modelHash;
  final DateTime createdAt;
  final bool rebuildable;

  factory ModelProvenance.fromJson(Map<String, dynamic> json) {
    return ModelProvenance(
      modelName: json['model_name'] as String? ?? 'unknown',
      modelVersion: json['model_version'] as String? ?? 'unknown',
      modelHash: json['model_hash'] as String?,
      createdAt: _readDateTime(json['created_at']) ?? DateTime.now().toUtc(),
      rebuildable: json['rebuildable'] as bool? ?? true,
    );
  }
}

class AssetVariant {
  const AssetVariant({
    required this.id,
    required this.kind,
    required this.relativePath,
    required this.mimeType,
    required this.bytes,
    required this.width,
    required this.height,
    required this.derived,
  });

  final String id;
  final String kind;
  final String relativePath;
  final String mimeType;
  final int bytes;
  final int? width;
  final int? height;
  final ModelProvenance derived;

  factory AssetVariant.fromJson(Map<String, dynamic> json) {
    return AssetVariant(
      id: json['id'].toString(),
      kind: json['kind'] as String? ?? 'unknown',
      relativePath: json['relative_path'] as String? ?? '',
      mimeType: json['mime_type'] as String? ?? 'application/octet-stream',
      bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      width: (json['width'] as num?)?.toInt(),
      height: (json['height'] as num?)?.toInt(),
      derived: ModelProvenance.fromJson(json),
    );
  }
}

class GeoTag {
  const GeoTag({
    required this.latitude,
    required this.longitude,
    required this.altitudeMeters,
    required this.source,
    required this.exactHidden,
  });

  final double latitude;
  final double longitude;
  final double? altitudeMeters;
  final String source;
  final bool exactHidden;

  factory GeoTag.fromJson(Map<String, dynamic> json) {
    return GeoTag(
      latitude: (json['latitude'] as num?)?.toDouble() ?? 0,
      longitude: (json['longitude'] as num?)?.toDouble() ?? 0,
      altitudeMeters: (json['altitude_meters'] as num?)?.toDouble(),
      source: json['source'] as String? ?? 'unknown',
      exactHidden: json['exact_hidden'] as bool? ?? false,
    );
  }
}

class CameraInfo {
  const CameraInfo({
    required this.make,
    required this.model,
    required this.lensModel,
  });

  final String? make;
  final String? model;
  final String? lensModel;

  factory CameraInfo.fromJson(Map<String, dynamic> json) {
    return CameraInfo(
      make: json['make'] as String?,
      model: json['model'] as String?,
      lensModel: json['lens_model'] as String?,
    );
  }
}

class AssetMetadata {
  const AssetMetadata({
    required this.assetId,
    required this.capturedAt,
    required this.capturedAtSource,
    required this.timezoneOffsetMinutes,
    required this.width,
    required this.height,
    required this.camera,
    required this.geo,
    required this.sidecarTitle,
    required this.sidecarDescription,
    required this.folderHint,
    required this.derived,
  });

  final String assetId;
  final DateTime capturedAt;
  final String capturedAtSource;
  final int? timezoneOffsetMinutes;
  final int? width;
  final int? height;
  final CameraInfo? camera;
  final GeoTag? geo;
  final String? sidecarTitle;
  final String? sidecarDescription;
  final String? folderHint;
  final ModelProvenance derived;

  factory AssetMetadata.fromJson(Map<String, dynamic> json) {
    final rawCamera = json['camera'];
    final rawGeo = json['geo'];
    return AssetMetadata(
      assetId: json['asset_id'].toString(),
      capturedAt: _readDateTime(json['captured_at']) ?? DateTime.now().toUtc(),
      capturedAtSource: json['captured_at_source'] as String? ?? 'unknown',
      timezoneOffsetMinutes: (json['timezone_offset_minutes'] as num?)?.toInt(),
      width: (json['width'] as num?)?.toInt(),
      height: (json['height'] as num?)?.toInt(),
      camera: rawCamera is Map
          ? CameraInfo.fromJson(
              rawCamera.map((key, value) => MapEntry(key.toString(), value)),
            )
          : null,
      geo: rawGeo is Map
          ? GeoTag.fromJson(
              rawGeo.map((key, value) => MapEntry(key.toString(), value)),
            )
          : null,
      sidecarTitle: json['sidecar_title'] as String?,
      sidecarDescription: json['sidecar_description'] as String?,
      folderHint: json['folder_hint'] as String?,
      derived: ModelProvenance.fromJson(json),
    );
  }
}

class Asset {
  const Asset({
    required this.id,
    required this.originalFilename,
    required this.relativeOriginalPath,
    required this.sourcePath,
    required this.importMode,
    required this.isAvailable,
    required this.contentHash,
    required this.mediaKind,
    required this.bytes,
    required this.mimeType,
    required this.capturedAt,
    required this.importedAt,
    required this.archived,
    required this.favorite,
    required this.placeHint,
    required this.metadata,
    required this.variants,
  });

  final String id;
  final String originalFilename;
  final String relativeOriginalPath;
  final String sourcePath;
  final ImportMode importMode;
  final bool isAvailable;
  final String contentHash;
  final String mediaKind;
  final int bytes;
  final String mimeType;
  final DateTime capturedAt;
  final DateTime importedAt;
  final bool archived;
  final bool favorite;
  final String? placeHint;
  final AssetMetadata? metadata;
  final List<AssetVariant> variants;

  factory Asset.fromJson(Map<String, dynamic> json) {
    return Asset(
      id: json['id'].toString(),
      originalFilename: json['original_filename'] as String? ?? '',
      relativeOriginalPath: json['relative_original_path'] as String? ?? '',
      sourcePath: json['source_path'] as String? ?? '',
      importMode: ImportModeX.fromJson(json['import_mode'] as String?),
      isAvailable: json['is_available'] as bool? ?? true,
      contentHash: json['content_hash'] as String? ?? '',
      mediaKind: json['media_kind'] as String? ?? 'photo',
      bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      mimeType: json['mime_type'] as String? ?? 'application/octet-stream',
      capturedAt: _readDateTime(json['captured_at']) ?? DateTime.now().toUtc(),
      importedAt: _readDateTime(json['imported_at']) ?? DateTime.now().toUtc(),
      archived: json['archived'] as bool? ?? false,
      favorite: json['favorite'] as bool? ?? false,
      placeHint: json['place_hint'] as String?,
      metadata: json['metadata'] is Map
          ? AssetMetadata.fromJson(
              (json['metadata'] as Map)
                  .map((key, value) => MapEntry(key.toString(), value)),
            )
          : null,
      variants: _readList(json['variants'])
          .map((item) => AssetVariant.fromJson(item))
          .toList(),
    );
  }
}

class OcrBlock {
  const OcrBlock({
    required this.id,
    required this.assetId,
    required this.text,
    required this.derived,
  });

  final String id;
  final String assetId;
  final String text;
  final ModelProvenance derived;

  factory OcrBlock.fromJson(Map<String, dynamic> json) {
    return OcrBlock(
      id: json['id'].toString(),
      assetId: json['asset_id'].toString(),
      text: json['text'] as String? ?? '',
      derived: ModelProvenance.fromJson(json),
    );
  }
}

class PersonCluster {
  const PersonCluster({
    required this.id,
    required this.displayName,
    required this.assetIds,
    required this.faceTemplateIds,
    required this.representativeAssetId,
    required this.hidden,
    required this.derived,
  });

  final String id;
  final String displayName;
  final List<String> assetIds;
  final List<String> faceTemplateIds;
  final String? representativeAssetId;
  final bool hidden;
  final ModelProvenance derived;

  factory PersonCluster.fromJson(Map<String, dynamic> json) {
    return PersonCluster(
      id: json['id'].toString(),
      displayName: json['display_name'] as String? ?? 'Unnamed person',
      assetIds: _readStringList(json['asset_ids']),
      faceTemplateIds: _readStringList(json['face_template_ids']),
      representativeAssetId: json['representative_asset_id']?.toString(),
      hidden: json['hidden'] as bool? ?? false,
      derived: ModelProvenance.fromJson(json),
    );
  }
}

class PlaceCluster {
  const PlaceCluster({
    required this.id,
    required this.label,
    required this.countryCode,
    required this.region,
    required this.assetIds,
    required this.centroidLatitude,
    required this.centroidLongitude,
    required this.derived,
  });

  final String id;
  final String label;
  final String? countryCode;
  final String? region;
  final List<String> assetIds;
  final double? centroidLatitude;
  final double? centroidLongitude;
  final ModelProvenance derived;

  factory PlaceCluster.fromJson(Map<String, dynamic> json) {
    return PlaceCluster(
      id: json['id'].toString(),
      label: json['label'] as String? ?? 'Unknown place',
      countryCode: json['country_code'] as String?,
      region: json['region'] as String?,
      assetIds: _readStringList(json['asset_ids']),
      centroidLatitude: (json['centroid_latitude'] as num?)?.toDouble(),
      centroidLongitude: (json['centroid_longitude'] as num?)?.toDouble(),
      derived: ModelProvenance.fromJson(json),
    );
  }
}

class EventCluster {
  const EventCluster({
    required this.id,
    required this.title,
    required this.titleSource,
    required this.assetIds,
    required this.startAt,
    required this.endAt,
    required this.placeId,
    required this.peopleIds,
    required this.derived,
  });

  final String id;
  final String title;
  final String titleSource;
  final List<String> assetIds;
  final DateTime startAt;
  final DateTime endAt;
  final String? placeId;
  final List<String> peopleIds;
  final ModelProvenance derived;

  factory EventCluster.fromJson(Map<String, dynamic> json) {
    return EventCluster(
      id: json['id'].toString(),
      title: json['title'] as String? ?? 'Untitled event',
      titleSource: json['title_source'] as String? ?? 'generated',
      assetIds: _readStringList(json['asset_ids']),
      startAt: _readDateTime(json['start_at']) ?? DateTime.now().toUtc(),
      endAt: _readDateTime(json['end_at']) ?? DateTime.now().toUtc(),
      placeId: json['place_id']?.toString(),
      peopleIds: _readStringList(json['people_ids']),
      derived: ModelProvenance.fromJson(json),
    );
  }
}

class JobRecord {
  const JobRecord({
    required this.id,
    required this.kind,
    required this.status,
    required this.progress,
    required this.queuedAt,
    required this.startedAt,
    required this.completedAt,
    required this.detail,
    required this.cancelRequested,
    required this.retryOfJobId,
    required this.attempt,
  });

  final String id;
  final String kind;
  final String status;
  final int progress;
  final DateTime queuedAt;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final String? detail;
  final bool cancelRequested;
  final String? retryOfJobId;
  final int attempt;

  factory JobRecord.fromJson(Map<String, dynamic> json) {
    return JobRecord(
      id: json['id'].toString(),
      kind: json['kind'] as String? ?? 'unknown',
      status: json['status'] as String? ?? 'queued',
      progress: (json['progress'] as num?)?.toInt() ?? 0,
      queuedAt: _readDateTime(json['queued_at']) ?? DateTime.now().toUtc(),
      startedAt: _readDateTime(json['started_at']),
      completedAt: _readDateTime(json['completed_at']),
      detail: json['detail'] as String?,
      cancelRequested: json['cancel_requested'] as bool? ?? false,
      retryOfJobId: json['retry_of_job_id']?.toString(),
      attempt: (json['attempt'] as num?)?.toInt() ?? 1,
    );
  }
}

class JobLog {
  const JobLog({
    required this.id,
    required this.jobId,
    required this.level,
    required this.message,
    required this.createdAt,
  });

  final String id;
  final String jobId;
  final String level;
  final String message;
  final DateTime createdAt;

  factory JobLog.fromJson(Map<String, dynamic> json) {
    return JobLog(
      id: json['id'].toString(),
      jobId: json['job_id'].toString(),
      level: json['level'] as String? ?? 'info',
      message: json['message'] as String? ?? '',
      createdAt: _readDateTime(json['created_at']) ?? DateTime.now().toUtc(),
    );
  }
}

class TimelineBucket {
  const TimelineBucket({
    required this.label,
    required this.assetIds,
    required this.assets,
    required this.totalAssets,
  });

  final String label;
  final List<String> assetIds;
  final List<Asset> assets;
  final int totalAssets;

  factory TimelineBucket.fromJson(Map<String, dynamic> json) {
    final assets =
        _readList(json['assets']).map((item) => Asset.fromJson(item)).toList();
    return TimelineBucket(
      label: json['label'] as String? ?? 'Untitled bucket',
      assetIds: _readStringList(json['asset_ids']),
      assets: assets,
      totalAssets: (json['total_assets'] as num?)?.toInt() ?? assets.length,
    );
  }
}

class TimelineResponse {
  const TimelineResponse({
    required this.buckets,
    required this.nextCursor,
    required this.totalAssets,
    required this.returnedAssets,
  });

  final List<TimelineBucket> buckets;
  final String? nextCursor;
  final int totalAssets;
  final int returnedAssets;

  bool get isEmpty => buckets.every((bucket) => bucket.assets.isEmpty);

  int get visibleAssetCount =>
      buckets.fold<int>(0, (sum, bucket) => sum + bucket.assets.length);

  TimelineResponse append(TimelineResponse nextPage) {
    if (buckets.isEmpty) {
      return nextPage;
    }
    if (nextPage.buckets.isEmpty) {
      return TimelineResponse(
        buckets: buckets,
        nextCursor: nextPage.nextCursor,
        totalAssets: totalAssets,
        returnedAssets: returnedAssets,
      );
    }

    final merged = [...buckets];
    for (final nextBucket in nextPage.buckets) {
      final last = merged.last;
      if (last.label == nextBucket.label) {
        merged[merged.length - 1] = TimelineBucket(
          label: last.label,
          assetIds: [...last.assetIds, ...nextBucket.assetIds],
          assets: [...last.assets, ...nextBucket.assets],
          totalAssets: nextBucket.totalAssets,
        );
      } else {
        merged.add(nextBucket);
      }
    }

    return TimelineResponse(
      buckets: merged,
      nextCursor: nextPage.nextCursor,
      totalAssets:
          nextPage.totalAssets == 0 ? totalAssets : nextPage.totalAssets,
      returnedAssets: returnedAssets + nextPage.returnedAssets,
    );
  }

  factory TimelineResponse.fromJson(Map<String, dynamic> json) {
    final buckets = _readList(json['buckets'])
        .map((item) => TimelineBucket.fromJson(item))
        .toList();
    return TimelineResponse(
      buckets: buckets,
      nextCursor: json['next_cursor'] as String?,
      totalAssets: (json['total_assets'] as num?)?.toInt() ??
          buckets.fold<int>(0, (sum, bucket) => sum + bucket.totalAssets),
      returnedAssets: (json['returned_assets'] as num?)?.toInt() ??
          buckets.fold<int>(0, (sum, bucket) => sum + bucket.assets.length),
    );
  }
}

class SearchQuery {
  const SearchQuery({
    required this.text,
    this.people,
    this.places,
    this.fromDate,
    this.toDate,
    this.includeArchived = false,
    this.limit,
  });

  final String text;
  final String? people;
  final String? places;
  final String? fromDate;
  final String? toDate;
  final bool includeArchived;
  final int? limit;

  Map<String, String> toQueryParameters() {
    return {
      if (text.trim().isNotEmpty) 'text': text.trim(),
      if (people != null && people!.trim().isNotEmpty) 'people': people!.trim(),
      if (places != null && places!.trim().isNotEmpty) 'places': places!.trim(),
      if (fromDate != null && fromDate!.trim().isNotEmpty)
        'from_date': fromDate!.trim(),
      if (toDate != null && toDate!.trim().isNotEmpty)
        'to_date': toDate!.trim(),
      'include_archived': '$includeArchived',
      if (limit != null) 'limit': '$limit',
    };
  }

  factory SearchQuery.fromJson(Map<String, dynamic> json) {
    return SearchQuery(
      text: json['text'] as String? ?? '',
      people: json['people'] as String?,
      places: json['places'] as String?,
      fromDate: json['from_date'] as String?,
      toDate: json['to_date'] as String?,
      includeArchived: json['include_archived'] as bool? ?? false,
      limit: (json['limit'] as num?)?.toInt(),
    );
  }
}

class SearchResponse {
  const SearchResponse({
    required this.query,
    required this.assets,
    required this.people,
    required this.places,
    required this.events,
  });

  final SearchQuery query;
  final List<Asset> assets;
  final List<PersonCluster> people;
  final List<PlaceCluster> places;
  final List<EventCluster> events;

  bool get isEmpty =>
      assets.isEmpty && people.isEmpty && places.isEmpty && events.isEmpty;

  factory SearchResponse.fromJson(Map<String, dynamic> json) {
    final rawQuery = json['query'];
    final queryMap = rawQuery is Map
        ? rawQuery.map((key, value) => MapEntry(key.toString(), value))
        : <String, dynamic>{'text': ''};

    return SearchResponse(
      query: SearchQuery.fromJson(queryMap),
      assets: _readList(json['assets'])
          .map((item) => Asset.fromJson(item))
          .toList(),
      people: _readList(json['people'])
          .map((item) => PersonCluster.fromJson(item))
          .toList(),
      places: _readList(json['places'])
          .map((item) => PlaceCluster.fromJson(item))
          .toList(),
      events: _readList(json['events'])
          .map((item) => EventCluster.fromJson(item))
          .toList(),
    );
  }
}

class SearchIndexStatus {
  const SearchIndexStatus({
    required this.filenameReady,
    required this.metadataReady,
    required this.ocrReady,
    required this.ocrTextBlockCount,
    required this.ocrIndexedAssetCount,
    required this.ocrTotalPhotoCount,
    required this.ocrRemainingPhotoCount,
    required this.sceneReady,
    required this.semanticReady,
    required this.updatedAt,
    required this.detail,
  });

  final bool filenameReady;
  final bool metadataReady;
  final bool ocrReady;
  final int ocrTextBlockCount;
  final int ocrIndexedAssetCount;
  final int ocrTotalPhotoCount;
  final int ocrRemainingPhotoCount;
  final bool sceneReady;
  final bool semanticReady;
  final DateTime? updatedAt;
  final String detail;

  bool get ocrPartiallyIndexed =>
      ocrIndexedAssetCount > 0 && ocrRemainingPhotoCount > 0;

  bool get intelligenceReady => ocrReady || sceneReady || semanticReady;

  factory SearchIndexStatus.fromJson(Map<String, dynamic> json) {
    return SearchIndexStatus(
      filenameReady: json['filename_ready'] as bool? ?? false,
      metadataReady: json['metadata_ready'] as bool? ?? false,
      ocrReady: json['ocr_ready'] as bool? ?? false,
      ocrTextBlockCount: (json['ocr_text_block_count'] as num?)?.toInt() ?? 0,
      ocrIndexedAssetCount:
          (json['ocr_indexed_asset_count'] as num?)?.toInt() ?? 0,
      ocrTotalPhotoCount: (json['ocr_total_photo_count'] as num?)?.toInt() ?? 0,
      ocrRemainingPhotoCount:
          (json['ocr_remaining_photo_count'] as num?)?.toInt() ?? 0,
      sceneReady: json['scene_ready'] as bool? ?? false,
      semanticReady: json['semantic_ready'] as bool? ?? false,
      updatedAt: _readDateTime(json['updated_at']),
      detail: json['detail'] as String? ??
          'Search index status unavailable from this daemon.',
    );
  }
}

class GalleryDashboardData {
  const GalleryDashboardData({
    required this.timeline,
    required this.albums,
    required this.people,
    required this.places,
    required this.events,
    required this.jobs,
    required this.models,
    required this.modelRuntimeStatus,
  });

  final TimelineResponse timeline;
  final List<Album> albums;
  final List<PersonCluster> people;
  final List<PlaceCluster> places;
  final List<EventCluster> events;
  final List<JobRecord> jobs;
  final List<ModelArtifact> models;
  final ModelRuntimeStatus? modelRuntimeStatus;

  int get assetCount => timeline.buckets
      .fold<int>(0, (sum, bucket) => sum + bucket.assets.length);
}

class Album {
  const Album({
    required this.id,
    required this.title,
    required this.assetIds,
    required this.coverAssetId,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final List<String> assetIds;
  final String? coverAssetId;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory Album.fromJson(Map<String, dynamic> json) {
    return Album(
      id: json['id'].toString(),
      title: json['title'] as String? ?? 'Untitled album',
      assetIds: _readStringList(json['asset_ids']),
      coverAssetId: json['cover_asset_id']?.toString(),
      createdAt: _readDateTime(json['created_at']),
      updatedAt: _readDateTime(json['updated_at']),
    );
  }
}

class LibrarySettings {
  const LibrarySettings({
    required this.libraryRoot,
    required this.defaultImportMode,
    required this.initializedAt,
    required this.updatedAt,
  });

  final String libraryRoot;
  final ImportMode defaultImportMode;
  final DateTime? initializedAt;
  final DateTime? updatedAt;

  factory LibrarySettings.fromJson(Map<String, dynamic> json) {
    return LibrarySettings(
      libraryRoot: json['library_root'] as String? ?? '',
      defaultImportMode: ImportModeX.fromJson(
        json['default_import_mode'] as String?,
      ),
      initializedAt: _readDateTime(json['initialized_at']),
      updatedAt: _readDateTime(json['updated_at']),
    );
  }
}

class LibrarySettingsDraft {
  const LibrarySettingsDraft({
    required this.libraryRoot,
    required this.defaultImportMode,
  });

  final String libraryRoot;
  final ImportMode defaultImportMode;

  Map<String, dynamic> toJson() {
    return {
      'library_root': libraryRoot,
      'default_import_mode': defaultImportMode.wireValue,
    };
  }
}

class WatchFolder {
  const WatchFolder({
    required this.id,
    required this.path,
    required this.recursive,
    required this.importMode,
    required this.createdAt,
    required this.lastScannedAt,
  });

  final String id;
  final String path;
  final bool recursive;
  final ImportMode importMode;
  final DateTime? createdAt;
  final DateTime? lastScannedAt;

  factory WatchFolder.fromJson(Map<String, dynamic> json) {
    return WatchFolder(
      id: json['id'].toString(),
      path: json['path'] as String? ?? '',
      recursive: json['recursive'] as bool? ?? true,
      importMode: ImportModeX.fromJson(json['import_mode'] as String?),
      createdAt: _readDateTime(json['created_at']),
      lastScannedAt: _readDateTime(json['last_scanned_at']),
    );
  }
}

class WatchFolderDraft {
  const WatchFolderDraft({
    required this.path,
    required this.recursive,
    required this.importMode,
  });

  final String path;
  final bool recursive;
  final ImportMode importMode;

  Map<String, dynamic> toJson() {
    return {
      'path': path,
      'recursive': recursive,
      'import_mode': importMode.wireValue,
    };
  }
}

class ImportCandidate {
  const ImportCandidate({
    required this.id,
    required this.sessionId,
    required this.sourcePath,
    required this.originalFilename,
    required this.mediaKind,
    required this.mimeType,
    required this.bytes,
    required this.capturedAt,
    required this.placeHint,
    required this.contentHash,
    required this.duplicateAssetId,
    required this.selected,
    required this.importMode,
    required this.destinationPath,
    required this.sidecarPaths,
    required this.safetyStatus,
  });

  final String id;
  final String sessionId;
  final String sourcePath;
  final String originalFilename;
  final String mediaKind;
  final String mimeType;
  final int bytes;
  final DateTime? capturedAt;
  final String? placeHint;
  final String contentHash;
  final String? duplicateAssetId;
  final bool selected;
  final ImportMode importMode;
  final String? destinationPath;
  final List<String> sidecarPaths;
  final String safetyStatus;

  bool get isDuplicate => duplicateAssetId != null;

  factory ImportCandidate.fromJson(Map<String, dynamic> json) {
    return ImportCandidate(
      id: json['id'].toString(),
      sessionId: json['session_id'].toString(),
      sourcePath: json['source_path'] as String? ?? '',
      originalFilename: json['original_filename'] as String? ?? '',
      mediaKind: json['media_kind'] as String? ?? 'photo',
      mimeType: json['mime_type'] as String? ?? 'application/octet-stream',
      bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      capturedAt: _readDateTime(json['captured_at']),
      placeHint: json['place_hint'] as String?,
      contentHash: json['content_hash'] as String? ?? '',
      duplicateAssetId: json['duplicate_asset_id']?.toString(),
      selected: json['selected'] as bool? ?? false,
      importMode: ImportModeX.fromJson(json['import_mode'] as String?),
      destinationPath: json['destination_path'] as String?,
      sidecarPaths: _readStringList(json['sidecar_paths']),
      safetyStatus: json['safety_status'] as String? ?? 'ready',
    );
  }
}

class ImportSession {
  const ImportSession({
    required this.id,
    required this.sourceKind,
    required this.sourcePath,
    required this.importMode,
    required this.addAsWatchFolder,
    required this.status,
    required this.createdAt,
    required this.completedAt,
    required this.placeHint,
    required this.candidates,
    required this.importedAssetIds,
    required this.duplicateAssetIds,
    required this.movedAssetIds,
    required this.skippedDuplicateIds,
    required this.failedCandidateIds,
    required this.sidecarsMoved,
    required this.unsupportedFilePaths,
    required this.selectedCandidateCount,
    required this.selectedBytes,
    required this.duplicateCount,
    required this.unsupportedCount,
    required this.sidecarCount,
    required this.destinationRoot,
    required this.requiresMoveConfirmation,
    required this.sourceContainsManagedLibrary,
    required this.selectedOutsideSourceCount,
  });

  final String id;
  final ImportSourceKind sourceKind;
  final String sourcePath;
  final ImportMode importMode;
  final bool addAsWatchFolder;
  final ImportSessionStatus status;
  final DateTime createdAt;
  final DateTime? completedAt;
  final String? placeHint;
  final List<ImportCandidate> candidates;
  final List<String> importedAssetIds;
  final List<String> duplicateAssetIds;
  final List<String> movedAssetIds;
  final List<String> skippedDuplicateIds;
  final List<String> failedCandidateIds;
  final int sidecarsMoved;
  final List<String> unsupportedFilePaths;
  final int selectedCandidateCount;
  final int selectedBytes;
  final int duplicateCount;
  final int unsupportedCount;
  final int sidecarCount;
  final String? destinationRoot;
  final bool requiresMoveConfirmation;
  final bool sourceContainsManagedLibrary;
  final int selectedOutsideSourceCount;

  int get computedDuplicateCount =>
      candidates.where((candidate) => candidate.isDuplicate).length;

  int get computedSidecarCount => candidates.fold<int>(
        0,
        (sum, candidate) => sum + candidate.sidecarPaths.length,
      );

  int get computedSelectedBytes => candidates
      .where((candidate) => candidate.selected && !candidate.isDuplicate)
      .fold<int>(0, (sum, candidate) => sum + candidate.bytes);

  factory ImportSession.fromJson(Map<String, dynamic> json) {
    final candidates = _readList(json['candidates'])
        .map((item) => ImportCandidate.fromJson(item))
        .toList();
    final unsupportedFilePaths =
        _readStringList(json['unsupported_file_paths']);
    final fallbackDuplicateCount =
        candidates.where((candidate) => candidate.isDuplicate).length;
    final fallbackSidecarCount = candidates.fold<int>(
      0,
      (sum, candidate) => sum + candidate.sidecarPaths.length,
    );
    final fallbackSelectedCandidates = candidates
        .where((candidate) => candidate.selected && !candidate.isDuplicate)
        .toList();
    final fallbackSelectedBytes = fallbackSelectedCandidates.fold<int>(
      0,
      (sum, candidate) => sum + candidate.bytes,
    );

    return ImportSession(
      id: json['id'].toString(),
      sourceKind: ImportSourceKindX.fromJson(json['source_kind'] as String?),
      sourcePath: json['source_path'] as String? ?? '',
      importMode: ImportModeX.fromJson(json['import_mode'] as String?),
      addAsWatchFolder: json['add_as_watch_folder'] as bool? ?? false,
      status: ImportSessionStatusX.fromJson(json['status'] as String?),
      createdAt: _readDateTime(json['created_at']) ?? DateTime.now().toUtc(),
      completedAt: _readDateTime(json['completed_at']),
      placeHint: json['place_hint'] as String?,
      candidates: candidates,
      importedAssetIds: _readStringList(json['imported_asset_ids']),
      duplicateAssetIds: _readStringList(json['duplicate_asset_ids']),
      movedAssetIds: _readStringList(json['moved_asset_ids']),
      skippedDuplicateIds: _readStringList(json['skipped_duplicate_ids']),
      failedCandidateIds: _readStringList(json['failed_candidate_ids']),
      sidecarsMoved: (json['sidecars_moved'] as num?)?.toInt() ?? 0,
      unsupportedFilePaths: unsupportedFilePaths,
      selectedCandidateCount:
          (json['selected_candidate_count'] as num?)?.toInt() ??
              fallbackSelectedCandidates.length,
      selectedBytes:
          (json['selected_bytes'] as num?)?.toInt() ?? fallbackSelectedBytes,
      duplicateCount:
          (json['duplicate_count'] as num?)?.toInt() ?? fallbackDuplicateCount,
      unsupportedCount: (json['unsupported_count'] as num?)?.toInt() ??
          unsupportedFilePaths.length,
      sidecarCount:
          (json['sidecar_count'] as num?)?.toInt() ?? fallbackSidecarCount,
      destinationRoot: json['destination_root'] as String?,
      requiresMoveConfirmation:
          json['requires_move_confirmation'] as bool? ?? false,
      sourceContainsManagedLibrary:
          json['source_contains_managed_library'] as bool? ?? false,
      selectedOutsideSourceCount:
          (json['selected_outside_source_count'] as num?)?.toInt() ?? 0,
    );
  }
}

class ImportScanRequest {
  const ImportScanRequest({
    required this.sourcePath,
    required this.sourceKind,
    required this.importMode,
    required this.addAsWatchFolder,
    required this.placeHint,
    required this.recursive,
  });

  final String sourcePath;
  final ImportSourceKind sourceKind;
  final ImportMode importMode;
  final bool addAsWatchFolder;
  final String? placeHint;
  final bool recursive;

  Map<String, dynamic> toJson() {
    return {
      'source_path': sourcePath,
      'source_kind': sourceKind.wireValue,
      'import_mode': importMode.wireValue,
      'add_as_watch_folder': addAsWatchFolder,
      'recursive': recursive,
      if (placeHint != null && placeHint!.trim().isNotEmpty)
        'place_hint': placeHint!.trim(),
    };
  }
}

class ImportCommitRequest {
  const ImportCommitRequest({
    required this.sessionId,
    required this.candidateIds,
    required this.importMode,
  });

  final String sessionId;
  final List<String> candidateIds;
  final ImportMode importMode;

  Map<String, dynamic> toJson() {
    return {
      'session_id': sessionId,
      'selected_candidate_ids': candidateIds,
      'import_mode': importMode.wireValue,
    };
  }
}

class LibraryStatus {
  const LibraryStatus({
    required this.settings,
    required this.watchFolders,
    required this.isInitialized,
  });

  final LibrarySettings? settings;
  final List<WatchFolder> watchFolders;
  final bool isInitialized;

  factory LibraryStatus.fromJson(Map<String, dynamic> json) {
    final rawSettings = json['settings'];
    final settings = rawSettings is Map
        ? LibrarySettings.fromJson(
            rawSettings.map(
              (key, value) => MapEntry(key.toString(), value),
            ),
          )
        : null;

    return LibraryStatus(
      settings: settings,
      watchFolders: _readList(json['watch_folders'])
          .map((item) => WatchFolder.fromJson(item))
          .toList(),
      isInitialized: json['is_initialized'] as bool? ?? settings != null,
    );
  }
}

class SetupDraft {
  const SetupDraft({
    required this.settings,
    required this.watchFolders,
  });

  final LibrarySettingsDraft settings;
  final List<WatchFolderDraft> watchFolders;
}

class DaemonDiagnostics {
  const DaemonDiagnostics({
    required this.assets,
    required this.people,
    required this.places,
    required this.events,
    required this.jobs,
    required this.syncSessions,
    required this.databasePath,
    required this.libraryRoot,
  });

  final int assets;
  final int people;
  final int places;
  final int events;
  final int jobs;
  final int syncSessions;
  final String? databasePath;
  final String? libraryRoot;

  factory DaemonDiagnostics.fromJson(Map<String, dynamic> json) {
    return DaemonDiagnostics(
      assets: (json['assets'] as num?)?.toInt() ?? 0,
      people: (json['people'] as num?)?.toInt() ?? 0,
      places: (json['places'] as num?)?.toInt() ?? 0,
      events: (json['events'] as num?)?.toInt() ?? 0,
      jobs: (json['jobs'] as num?)?.toInt() ?? 0,
      syncSessions: (json['sync_sessions'] as num?)?.toInt() ?? 0,
      databasePath: json['database_path'] as String?,
      libraryRoot: json['library_root'] as String?,
    );
  }
}

class DaemonLaunchResult {
  const DaemonLaunchResult({
    required this.attempted,
    required this.started,
    required this.alreadyRunning,
    required this.attemptedCommands,
    required this.message,
  });

  const DaemonLaunchResult.none()
      : attempted = false,
        started = false,
        alreadyRunning = false,
        attemptedCommands = const [],
        message = null;

  final bool attempted;
  final bool started;
  final bool alreadyRunning;
  final List<String> attemptedCommands;
  final String? message;
}

class WorkspaceSnapshot {
  const WorkspaceSnapshot({
    required this.status,
    required this.dashboard,
    required this.diagnostics,
    required this.privacyStatus,
  });

  final LibraryStatus status;
  final GalleryDashboardData dashboard;
  final DaemonDiagnostics? diagnostics;
  final PrivacyStatus? privacyStatus;

  LibrarySettings get settings => status.settings!;
  List<WatchFolder> get watchFolders => status.watchFolders;
}

class AppLaunchResult {
  const AppLaunchResult._({
    required this.status,
    required this.launchResult,
    this.workspace,
    this.libraryStatus,
    this.diagnostics,
    this.message,
  });

  final AppLaunchStatus status;
  final WorkspaceSnapshot? workspace;
  final LibraryStatus? libraryStatus;
  final DaemonDiagnostics? diagnostics;
  final String? message;
  final DaemonLaunchResult launchResult;

  bool get isReady => status == AppLaunchStatus.ready && workspace != null;

  factory AppLaunchResult.ready({
    required WorkspaceSnapshot workspace,
    required DaemonLaunchResult launchResult,
  }) {
    return AppLaunchResult._(
      status: AppLaunchStatus.ready,
      workspace: workspace,
      libraryStatus: workspace.status,
      diagnostics: workspace.diagnostics,
      launchResult: launchResult,
    );
  }

  factory AppLaunchResult.setupRequired({
    required LibraryStatus libraryStatus,
    required DaemonLaunchResult launchResult,
    DaemonDiagnostics? diagnostics,
    String? message,
  }) {
    return AppLaunchResult._(
      status: AppLaunchStatus.setupRequired,
      libraryStatus: libraryStatus,
      diagnostics: diagnostics,
      message: message,
      launchResult: launchResult,
    );
  }

  factory AppLaunchResult.daemonUnavailable({
    required DaemonLaunchResult launchResult,
    String? message,
  }) {
    return AppLaunchResult._(
      status: AppLaunchStatus.daemonUnavailable,
      message: message,
      launchResult: launchResult,
    );
  }

  factory AppLaunchResult.error({
    required DaemonLaunchResult launchResult,
    String? message,
    DaemonDiagnostics? diagnostics,
  }) {
    return AppLaunchResult._(
      status: AppLaunchStatus.error,
      message: message,
      diagnostics: diagnostics,
      launchResult: launchResult,
    );
  }
}

DateTime? _readDateTime(Object? raw) {
  if (raw is! String || raw.isEmpty) {
    return null;
  }
  return DateTime.tryParse(raw)?.toUtc();
}

List<Map<String, dynamic>> _readList(Object? raw) {
  if (raw is! List) {
    return const [];
  }

  return raw
      .whereType<Map>()
      .map(
        (item) => item.map(
          (key, value) => MapEntry(key.toString(), value),
        ),
      )
      .toList();
}

List<String> _readStringList(Object? raw) {
  if (raw is! List) {
    return const [];
  }

  return raw.map((item) => item.toString()).toList();
}
