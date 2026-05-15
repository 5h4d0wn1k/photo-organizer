use std::{
    collections::{BTreeMap, BTreeSet, HashMap},
    fs,
    path::{Path, PathBuf},
    sync::Arc,
};

use chrono::Utc;
use serde_json::json;
use thiserror::Error;
use tokio::sync::RwLock;
use uuid::Uuid;

use crate::{
    config::AppConfig,
    domain::{
        Album, Asset, AssetAvailability, AssetAvailabilityState, BackupExportRequest,
        BackupExportResult, BackupRestorePlan, BackupRestorePlanRequest, BackupRestoreRunRequest,
        BackupRestoreRunResult, BackupVerification, BackupVerifyRequest, BlobChunk, BlobRecord,
        BlobReplica, CapabilityGrant, CorrectDateRequest, CorrectPlaceRequest, CorrectionKind,
        CorrectionRecord, CreateAlbumRequest, CreateDeviceRequest, CreateManualPersonRequest,
        CreatePairingSessionRequest, CreateVaultRequest, CreateWatchFolderRequest, DeviceIdentity,
        DevicePairing, DeviceRole, DeviceStorageProfile, DeviceTrustLevel,
        EncryptionActivationRequest, EncryptionActivationResult, EnrollDeviceRequest, EventCluster,
        FeedbackEvent, HidePersonRequest, ImportAssetRequest, ImportAssetResponse, ImportMode,
        ImportSession, ImportSessionStatus, JobKind, JobLog, JobRecord, JobStatus, LibrarySettings,
        LibraryStatusResponse, MergePersonRequest, MetadataSource, ModelArtifact,
        ModelImportRequest, ModelInstallRequest, ModelTask, OcrBlock, PersonCluster, PlaceCluster,
        PrivacyStatus, RebuildRequest, RejectPersonMatchRequest, RelayEndpoint, RenameAlbumRequest,
        RenamePersonRequest, ReplicaHealth, RevokeDeviceRequest, RunSyncRequest,
        ScanImportSourceRequest, SceneTag, SearchIndexStatus, SearchQuery, SearchResponse,
        SplitPersonRequest, StoragePolicy, StoragePolicyMode, SyncConflict, SyncNetworkStatus,
        SyncPlan, SyncSession, SyncTransfer, SyncTransferStatus, TimelineBucket, TimelineResponse,
        UpdateAlbumAssetsRequest, UpdateAssetFlagsRequest, UpdateAssetsFlagsRequest,
        UpdateLibrarySettingsRequest, UpdatePersonAssetsRequest, UpdateVaultStoragePolicyRequest,
        Vault, VaultInvite, VaultKeyEnvelope, VaultMember, VaultStatus, WatchFolder,
    },
    events, imports, metadata, ml_sidecar, model_registry, ocr, people, search, security,
    storage::{self, PersistedLibraryState, StorageBootstrapReport},
    vault_store,
};

#[derive(Debug, Default)]
struct LibraryState {
    library_settings: Option<LibrarySettings>,
    watch_folders: Vec<WatchFolder>,
    assets: Vec<crate::domain::Asset>,
    albums: Vec<Album>,
    people: Vec<PersonCluster>,
    places: Vec<PlaceCluster>,
    events: Vec<EventCluster>,
    faces: Vec<crate::domain::FaceTemplate>,
    feedback: Vec<FeedbackEvent>,
    vaults: Vec<Vault>,
    devices: Vec<DeviceIdentity>,
    vault_members: Vec<VaultMember>,
    blob_records: Vec<BlobRecord>,
    blob_chunks: Vec<BlobChunk>,
    blob_replicas: Vec<BlobReplica>,
    sync_transfers: Vec<SyncTransfer>,
    sync_conflicts: Vec<SyncConflict>,
    vault_invites: Vec<VaultInvite>,
    vault_key_envelopes: Vec<VaultKeyEnvelope>,
    relay_endpoints: Vec<RelayEndpoint>,
    capability_grants: Vec<CapabilityGrant>,
    pairings: Vec<DevicePairing>,
    sync_sessions: Vec<SyncSession>,
    import_sessions: Vec<ImportSession>,
    jobs: Vec<JobRecord>,
    job_logs: Vec<JobLog>,
    corrections: Vec<CorrectionRecord>,
    ocr_blocks: Vec<OcrBlock>,
    scene_tags: Vec<SceneTag>,
}

impl From<PersistedLibraryState> for LibraryState {
    fn from(state: PersistedLibraryState) -> Self {
        Self {
            library_settings: state.library_settings,
            watch_folders: state.watch_folders,
            assets: state.assets,
            albums: state.albums,
            people: state.people,
            places: state.places,
            events: state.events,
            faces: state.faces,
            feedback: state.feedback,
            vaults: state.vaults,
            devices: state.devices,
            vault_members: state.vault_members,
            blob_records: state.blob_records,
            blob_chunks: state.blob_chunks,
            blob_replicas: state.blob_replicas,
            sync_transfers: state.sync_transfers,
            sync_conflicts: state.sync_conflicts,
            vault_invites: state.vault_invites,
            vault_key_envelopes: state.vault_key_envelopes,
            relay_endpoints: state.relay_endpoints,
            capability_grants: state.capability_grants,
            pairings: state.pairings,
            sync_sessions: state.sync_sessions,
            import_sessions: state.import_sessions,
            jobs: state.jobs,
            job_logs: state.job_logs,
            corrections: state.corrections,
            ocr_blocks: state.ocr_blocks,
            scene_tags: state.scene_tags,
        }
    }
}

impl LibraryState {
    fn to_persisted(&self) -> PersistedLibraryState {
        PersistedLibraryState {
            library_settings: self.library_settings.clone(),
            watch_folders: self.watch_folders.clone(),
            assets: self.assets.clone(),
            albums: self.albums.clone(),
            people: self.people.clone(),
            places: self.places.clone(),
            events: self.events.clone(),
            faces: self.faces.clone(),
            feedback: self.feedback.clone(),
            vaults: self.vaults.clone(),
            devices: self.devices.clone(),
            vault_members: self.vault_members.clone(),
            blob_records: self.blob_records.clone(),
            blob_chunks: self.blob_chunks.clone(),
            blob_replicas: self.blob_replicas.clone(),
            sync_transfers: self.sync_transfers.clone(),
            sync_conflicts: self.sync_conflicts.clone(),
            vault_invites: self.vault_invites.clone(),
            vault_key_envelopes: self.vault_key_envelopes.clone(),
            relay_endpoints: self.relay_endpoints.clone(),
            capability_grants: self.capability_grants.clone(),
            pairings: self.pairings.clone(),
            sync_sessions: self.sync_sessions.clone(),
            import_sessions: self.import_sessions.clone(),
            jobs: self.jobs.clone(),
            job_logs: self.job_logs.clone(),
            corrections: self.corrections.clone(),
            ocr_blocks: self.ocr_blocks.clone(),
            scene_tags: self.scene_tags.clone(),
        }
    }
}

#[derive(Debug, Error)]
pub enum ServiceError {
    #[error("entity not found: {0}")]
    NotFound(String),
    #[error("invalid request: {0}")]
    Invalid(String),
    #[error("storage bootstrap failed: {0}")]
    Storage(String),
    #[error("filesystem operation failed: {0}")]
    Io(String),
}

#[derive(Clone)]
pub struct GalleryService {
    config: AppConfig,
    pub storage: StorageBootstrapReport,
    state: Arc<RwLock<LibraryState>>,
}

impl GalleryService {
    pub fn new(config: AppConfig) -> Result<Self, ServiceError> {
        if !config.developer_mode && !model_registry::is_loopback_host(&config.bind_host) {
            return Err(ServiceError::Invalid(format!(
                "refusing to bind daemon to non-loopback host {} without explicit developer mode",
                config.bind_host
            )));
        }

        let storage = storage::bootstrap_storage(&config)
            .map_err(|err| ServiceError::Storage(err.to_string()))?;
        let persisted =
            storage::load_state(&storage).map_err(|err| ServiceError::Storage(err.to_string()))?;
        let mut state = LibraryState::from(persisted);
        refresh_missing_derived_views(&mut state);
        let compacted_history = compact_job_history(&mut state);
        refresh_import_session_summaries(&mut state, &config);
        let distributed_changed =
            ensure_distributed_defaults(&mut state) || refresh_blob_records(&config, &mut state);
        if compacted_history || distributed_changed {
            storage::save_state(&storage, &state.to_persisted())
                .map_err(|err| ServiceError::Storage(err.to_string()))?;
        }

        Ok(Self {
            config,
            storage,
            state: Arc::new(RwLock::new(state)),
        })
    }

    pub fn config(&self) -> &AppConfig {
        &self.config
    }

    pub async fn library_status(&self) -> LibraryStatusResponse {
        let state = self.state.read().await;
        LibraryStatusResponse {
            is_initialized: state.library_settings.is_some(),
            settings: state.library_settings.clone(),
            watch_folders: state.watch_folders.clone(),
        }
    }

    pub async fn library_settings(&self) -> Result<LibrarySettings, ServiceError> {
        self.state
            .read()
            .await
            .library_settings
            .clone()
            .ok_or_else(|| ServiceError::NotFound("library settings".to_string()))
    }

    pub async fn update_library_settings(
        &self,
        request: UpdateLibrarySettingsRequest,
    ) -> Result<LibrarySettings, ServiceError> {
        let mut state = self.state.write().await;

        if request.library_root.trim().is_empty() {
            return Err(ServiceError::Invalid(
                "library_root must not be empty".to_string(),
            ));
        }

        if let Some(existing) = &state.library_settings
            && existing.library_root != request.library_root
            && state
                .assets
                .iter()
                .any(|asset| matches!(asset.import_mode, ImportMode::Copy | ImportMode::Move))
        {
            return Err(ServiceError::Invalid(
                "library_root cannot change after copy-managed assets exist".to_string(),
            ));
        }

        let library_root = PathBuf::from(&request.library_root);
        storage::ensure_library_layout(&library_root)
            .map_err(|err| ServiceError::Storage(err.to_string()))?;

        let now = Utc::now();
        let settings = LibrarySettings {
            library_root: request.library_root,
            default_import_mode: request.default_import_mode,
            initialized_at: state
                .library_settings
                .as_ref()
                .map(|value| value.initialized_at)
                .unwrap_or(now),
            updated_at: now,
        };
        state.library_settings = Some(settings.clone());
        refresh_asset_availability(&mut state);
        ensure_distributed_defaults(&mut state);
        refresh_blob_records(&self.config, &mut state);
        self.persist_locked_state(&state)?;
        Ok(settings)
    }

    pub async fn watch_folders(&self) -> Vec<WatchFolder> {
        self.state.read().await.watch_folders.clone()
    }

    pub async fn add_watch_folder(
        &self,
        request: CreateWatchFolderRequest,
    ) -> Result<WatchFolder, ServiceError> {
        if request.path.trim().is_empty() {
            return Err(ServiceError::Invalid("path must not be empty".to_string()));
        }

        let path = PathBuf::from(&request.path);
        if !path.exists() || !path.is_dir() {
            return Err(ServiceError::Invalid(
                "watch folder path must exist and be a directory".to_string(),
            ));
        }

        let mut state = self.state.write().await;
        if state
            .watch_folders
            .iter()
            .any(|folder| folder.path == request.path)
        {
            return Err(ServiceError::Invalid(
                "watch folder already exists".to_string(),
            ));
        }

        let folder = WatchFolder {
            id: Uuid::new_v4(),
            path: request.path,
            recursive: request.recursive,
            import_mode: request.import_mode.unwrap_or(default_import_mode(&state)),
            created_at: Utc::now(),
            last_scanned_at: None,
        };

        state.watch_folders.push(folder.clone());
        self.persist_locked_state(&state)?;
        Ok(folder)
    }

    pub async fn delete_watch_folder(&self, watch_folder_id: Uuid) -> Result<(), ServiceError> {
        let mut state = self.state.write().await;
        let before = state.watch_folders.len();
        state
            .watch_folders
            .retain(|folder| folder.id != watch_folder_id);
        if before == state.watch_folders.len() {
            return Err(ServiceError::NotFound(format!(
                "watch folder {watch_folder_id}"
            )));
        }
        self.persist_locked_state(&state)?;
        Ok(())
    }

    pub async fn create_pairing_session(
        &self,
        request: CreatePairingSessionRequest,
    ) -> Result<DevicePairing, ServiceError> {
        let pairing = DevicePairing {
            id: Uuid::new_v4(),
            device_name: request.device_name,
            platform: request.platform,
            pairing_token: Uuid::new_v4().to_string(),
            created_at: Utc::now(),
            expires_at: Utc::now() + chrono::Duration::minutes(10),
            approved_at: None,
        };

        let mut state = self.state.write().await;
        state.pairings.push(pairing.clone());
        self.persist_locked_state(&state)?;
        Ok(pairing)
    }

    pub async fn vaults(&self) -> Vec<Vault> {
        self.state.read().await.vaults.clone()
    }

    pub async fn create_vault(&self, request: CreateVaultRequest) -> Result<Vault, ServiceError> {
        if request.name.trim().is_empty() {
            return Err(ServiceError::Invalid(
                "vault name must not be empty".to_string(),
            ));
        }

        let mut state = self.state.write().await;
        ensure_distributed_defaults(&mut state);
        let local_device = local_device_id(&state).ok_or_else(|| {
            ServiceError::Invalid("local admin device could not be initialized".to_string())
        })?;
        let now = Utc::now();
        let vault = Vault {
            id: Uuid::new_v4(),
            name: request.name.trim().to_string(),
            storage_policy: normalize_storage_policy(request.storage_policy),
            key_version: 1,
            deletion_grace_days: 30,
            created_at: now,
            updated_at: now,
        };
        let local_display_name =
            local_device_name(&state).unwrap_or_else(|| "This device".to_string());
        state.vault_members.push(VaultMember {
            id: Uuid::new_v4(),
            vault_id: vault.id,
            device_id: local_device,
            role: DeviceRole::Admin,
            trust_level: DeviceTrustLevel::Trusted,
            display_name: local_display_name,
            added_at: now,
            revoked_at: None,
        });
        state.vaults.push(vault.clone());
        refresh_blob_records(&self.config, &mut state);
        self.persist_locked_state(&state)?;
        Ok(vault)
    }

    pub async fn vault_status(&self, vault_id: Uuid) -> Result<VaultStatus, ServiceError> {
        let mut state = self.state.write().await;
        ensure_distributed_defaults(&mut state);
        let changed = refresh_blob_records(&self.config, &mut state);
        let status = build_vault_status(&state, vault_id)?;
        if changed {
            self.persist_locked_state(&state)?;
        }
        Ok(status)
    }

    pub async fn update_vault_storage_policy(
        &self,
        vault_id: Uuid,
        request: UpdateVaultStoragePolicyRequest,
    ) -> Result<Vault, ServiceError> {
        let mut state = self.state.write().await;
        let updated = state
            .vaults
            .iter_mut()
            .find(|vault| vault.id == vault_id)
            .ok_or_else(|| ServiceError::NotFound(format!("vault {vault_id}")))?;
        updated.storage_policy = normalize_storage_policy(Some(request.policy));
        updated.updated_at = Utc::now();
        let vault = updated.clone();
        self.persist_locked_state(&state)?;
        Ok(vault)
    }

    pub async fn devices(&self) -> Vec<DeviceIdentity> {
        self.state.read().await.devices.clone()
    }

    pub async fn create_device(
        &self,
        request: CreateDeviceRequest,
    ) -> Result<DeviceIdentity, ServiceError> {
        let mut state = self.state.write().await;
        ensure_distributed_defaults(&mut state);
        let device = build_device_identity(
            request.display_name,
            request.platform,
            request.public_key,
            request.trust_level,
            request.storage_profile,
        )?;
        let role = request
            .role
            .unwrap_or_else(|| default_role_for_trust(device.trust_level));
        let device = add_device_to_state(&mut state, device, role, None)?;
        self.persist_locked_state(&state)?;
        Ok(device)
    }

    pub async fn enroll_device(
        &self,
        request: EnrollDeviceRequest,
    ) -> Result<DeviceIdentity, ServiceError> {
        let mut state = self.state.write().await;
        ensure_distributed_defaults(&mut state);
        let vault_id = match request.vault_id {
            Some(vault_id) => Some(vault_id),
            None => state.vaults.first().map(|vault| vault.id),
        };
        if let Some(vault_id) = vault_id
            && !state.vaults.iter().any(|vault| vault.id == vault_id)
        {
            return Err(ServiceError::NotFound(format!("vault {vault_id}")));
        }

        let device = build_device_identity(
            request.display_name,
            request.platform,
            request.public_key,
            request.trust_level,
            request.storage_profile,
        )?;
        let role = request
            .role
            .unwrap_or_else(|| default_role_for_trust(device.trust_level));
        let device = add_device_to_state(&mut state, device, role, vault_id)?;
        self.persist_locked_state(&state)?;
        Ok(device)
    }

    pub async fn revoke_device(
        &self,
        device_id: Uuid,
        _request: RevokeDeviceRequest,
    ) -> Result<DeviceIdentity, ServiceError> {
        let mut state = self.state.write().await;
        let now = Utc::now();
        let updated = state
            .devices
            .iter_mut()
            .find(|device| device.id == device_id)
            .ok_or_else(|| ServiceError::NotFound(format!("device {device_id}")))?;
        updated.revoked_at = Some(now);
        updated.last_seen_at = None;
        let updated = updated.clone();
        for member in state
            .vault_members
            .iter_mut()
            .filter(|member| member.device_id == device_id)
        {
            member.revoked_at = Some(now);
        }
        for envelope in state
            .vault_key_envelopes
            .iter_mut()
            .filter(|envelope| envelope.device_id == device_id)
        {
            envelope.revoked_at = Some(now);
        }
        for replica in state.blob_replicas.iter_mut().filter(|replica| {
            replica.device_id == device_id && replica.health == ReplicaHealth::Healthy
        }) {
            replica.health = ReplicaHealth::Offline;
        }
        self.persist_locked_state(&state)?;
        Ok(updated)
    }

    pub async fn sync_plan(&self, vault_id: Option<Uuid>) -> Result<SyncPlan, ServiceError> {
        let mut state = self.state.write().await;
        ensure_distributed_defaults(&mut state);
        let changed = refresh_blob_records(&self.config, &mut state);
        let plan = build_sync_plan(&state, vault_id)?;
        if changed {
            self.persist_locked_state(&state)?;
        }
        Ok(plan)
    }

    pub async fn run_sync(&self, request: RunSyncRequest) -> Result<SyncPlan, ServiceError> {
        let mut state = self.state.write().await;
        ensure_distributed_defaults(&mut state);
        refresh_blob_records(&self.config, &mut state);
        let plan = build_sync_plan(&state, request.vault_id)?;
        if !request.dry_run {
            for transfer in &plan.transfers {
                let duplicate = state.sync_transfers.iter().any(|existing| {
                    existing.blob_id == transfer.blob_id
                        && existing.to_device_id == transfer.to_device_id
                        && matches!(
                            existing.status,
                            SyncTransferStatus::Pending | SyncTransferStatus::Running
                        )
                });
                if !duplicate {
                    state.sync_transfers.push(transfer.clone());
                }
            }
            self.persist_locked_state(&state)?;
        }
        Ok(plan)
    }

    pub async fn sync_transfers(&self) -> Vec<SyncTransfer> {
        self.state.read().await.sync_transfers.clone()
    }

    pub async fn sync_network_status(&self) -> SyncNetworkStatus {
        let state = self.state.read().await;
        build_sync_network_status(&state)
    }

    pub async fn start_sync_network(&self) -> Result<SyncNetworkStatus, ServiceError> {
        let mut state = self.state.write().await;
        ensure_distributed_defaults(&mut state);
        self.persist_locked_state(&state)?;
        Ok(build_sync_network_status(&state))
    }

    pub async fn stop_sync_network(&self) -> Result<SyncNetworkStatus, ServiceError> {
        let state = self.state.read().await;
        Ok(build_sync_network_status(&state))
    }

    pub async fn retry_sync_transfer(
        &self,
        transfer_id: Uuid,
    ) -> Result<SyncTransfer, ServiceError> {
        let mut state = self.state.write().await;
        let transfer = state
            .sync_transfers
            .iter_mut()
            .find(|transfer| transfer.id == transfer_id)
            .ok_or_else(|| ServiceError::NotFound(format!("transfer {transfer_id}")))?;
        if matches!(
            transfer.status,
            SyncTransferStatus::Completed | SyncTransferStatus::Running
        ) {
            return Err(ServiceError::Invalid(
                "only pending, failed, or aborted transfers can be retried".to_string(),
            ));
        }
        transfer.status = SyncTransferStatus::Pending;
        transfer.bytes_completed = 0;
        transfer.started_at = None;
        transfer.updated_at = Utc::now();
        transfer.resumable_until = Utc::now() + chrono::Duration::days(7);
        let transfer = transfer.clone();
        self.persist_locked_state(&state)?;
        Ok(transfer)
    }

    pub async fn cancel_sync_transfer(
        &self,
        transfer_id: Uuid,
    ) -> Result<SyncTransfer, ServiceError> {
        let mut state = self.state.write().await;
        let transfer = state
            .sync_transfers
            .iter_mut()
            .find(|transfer| transfer.id == transfer_id)
            .ok_or_else(|| ServiceError::NotFound(format!("transfer {transfer_id}")))?;
        if transfer.status == SyncTransferStatus::Completed {
            return Err(ServiceError::Invalid(
                "completed transfers cannot be canceled".to_string(),
            ));
        }
        transfer.status = SyncTransferStatus::Aborted;
        transfer.updated_at = Utc::now();
        let transfer = transfer.clone();
        self.persist_locked_state(&state)?;
        Ok(transfer)
    }

    pub async fn asset_availability(
        &self,
        asset_id: Uuid,
    ) -> Result<AssetAvailability, ServiceError> {
        let mut state = self.state.write().await;
        ensure_distributed_defaults(&mut state);
        let changed = refresh_blob_records(&self.config, &mut state);
        let availability = build_asset_availability(&state, asset_id)?;
        if changed {
            self.persist_locked_state(&state)?;
        }
        Ok(availability)
    }

    pub async fn pin_local_asset(&self, asset_id: Uuid) -> Result<AssetAvailability, ServiceError> {
        let mut state = self.state.write().await;
        ensure_distributed_defaults(&mut state);
        refresh_blob_records(&self.config, &mut state);
        let local_device = local_device_id(&state).ok_or_else(|| {
            ServiceError::Invalid("local admin device could not be initialized".to_string())
        })?;
        let availability = build_asset_availability(&state, asset_id)?;
        let asset_available = state
            .assets
            .iter()
            .find(|asset| asset.id == asset_id)
            .map(|asset| asset.is_available)
            .unwrap_or(false);
        if availability.local_replica && asset_available {
            return Ok(availability);
        }
        if availability.reachable_replica_device_ids.is_empty() {
            if self.restore_original_from_local_chunks_locked(&mut state, asset_id)? {
                self.persist_locked_state(&state)?;
                return build_asset_availability(&state, asset_id);
            }
            return Err(ServiceError::Invalid(
                "asset has no reachable remote replica to pin locally".to_string(),
            ));
        }
        let blob = state
            .blob_records
            .iter()
            .find(|blob| blob.asset_id == asset_id && blob.tombstoned_at.is_none())
            .cloned()
            .ok_or_else(|| ServiceError::NotFound(format!("blob for asset {asset_id}")))?;
        let transfer = pending_transfer(
            blob.vault_id,
            blob.id,
            availability.reachable_replica_device_ids.first().copied(),
            local_device,
            blob.bytes,
        );
        state.sync_transfers.push(transfer);
        self.persist_locked_state(&state)?;
        build_asset_availability(&state, asset_id)
    }

    pub async fn evict_local_asset(
        &self,
        asset_id: Uuid,
    ) -> Result<AssetAvailability, ServiceError> {
        let mut state = self.state.write().await;
        ensure_distributed_defaults(&mut state);
        refresh_blob_records(&self.config, &mut state);
        let local_device = local_device_id(&state).ok_or_else(|| {
            ServiceError::Invalid("local admin device could not be initialized".to_string())
        })?;
        let blob = state
            .blob_records
            .iter()
            .find(|blob| blob.asset_id == asset_id && blob.tombstoned_at.is_none())
            .cloned()
            .ok_or_else(|| ServiceError::NotFound(format!("blob for asset {asset_id}")))?;
        let vault = state
            .vaults
            .iter()
            .find(|vault| vault.id == blob.vault_id)
            .ok_or_else(|| ServiceError::NotFound(format!("vault {}", blob.vault_id)))?;
        if vault.storage_policy.mode == StoragePolicyMode::MaxPoolSingleCopy {
            return Err(ServiceError::Invalid(
                "local eviction for only-copy vaults requires an explicit risk confirmation UI"
                    .to_string(),
            ));
        }
        let remote_healthy = state
            .blob_replicas
            .iter()
            .filter(|replica| {
                replica.blob_id == blob.id
                    && replica.device_id != local_device
                    && replica.health == ReplicaHealth::Healthy
                    && device_is_active(&state.devices, replica.device_id)
            })
            .count();
        if remote_healthy < vault.storage_policy.min_replicas as usize {
            return Err(ServiceError::Invalid(format!(
                "local eviction blocked until {} healthy remote replicas exist",
                vault.storage_policy.min_replicas
            )));
        }

        let library_root = PathBuf::from(effective_library_root(&state, &self.config));
        let asset = state
            .assets
            .iter_mut()
            .find(|asset| asset.id == asset_id)
            .ok_or_else(|| ServiceError::NotFound(format!("asset {asset_id}")))?;
        if asset.import_mode == ImportMode::Reference {
            return Err(ServiceError::Invalid(
                "referenced originals are outside the managed library and cannot be evicted"
                    .to_string(),
            ));
        }
        let path = asset_file_path(asset, &library_root);
        if path.exists() {
            fs::remove_file(&path).map_err(|err| ServiceError::Io(err.to_string()))?;
        }
        asset.is_available = false;
        remove_local_encrypted_chunks(&mut state, blob.id, &library_root)?;
        if let Some(replica) = state
            .blob_replicas
            .iter_mut()
            .find(|replica| replica.blob_id == blob.id && replica.device_id == local_device)
        {
            replica.health = ReplicaHealth::Missing;
            replica.bytes_present = 0;
            replica.verified_at = None;
        }
        self.persist_locked_state(&state)?;
        build_asset_availability(&state, asset_id)
    }

    pub async fn asset_original_bytes(
        &self,
        asset_id: Uuid,
    ) -> Result<(String, Vec<u8>), ServiceError> {
        let mut state = self.state.write().await;
        ensure_distributed_defaults(&mut state);
        refresh_blob_records(&self.config, &mut state);
        let library_root = PathBuf::from(effective_library_root(&state, &self.config));
        let asset = state
            .assets
            .iter()
            .find(|asset| asset.id == asset_id)
            .cloned()
            .ok_or_else(|| ServiceError::NotFound(format!("asset {asset_id}")))?;
        let original_path = asset_file_path(&asset, &library_root);
        if original_path.is_file() {
            return fs::read(&original_path)
                .map(|bytes| (asset.mime_type, bytes))
                .map_err(|err| ServiceError::Io(err.to_string()));
        }
        let blob = state
            .blob_records
            .iter()
            .find(|blob| blob.asset_id == asset_id && blob.tombstoned_at.is_none())
            .cloned()
            .ok_or_else(|| ServiceError::NotFound(format!("blob for asset {asset_id}")))?;
        let chunks = state
            .blob_chunks
            .iter()
            .filter(|chunk| chunk.blob_id == blob.id)
            .cloned()
            .collect::<Vec<_>>();
        if !vault_store::encrypted_chunk_files_exist(&library_root, &chunks) {
            let availability = build_asset_availability(&state, asset_id)?;
            return Err(ServiceError::Invalid(availability.detail));
        }
        let bytes = vault_store::decrypt_chunks_to_bytes(
            &self.config,
            &library_root,
            blob.vault_id,
            blob.encryption_key_version,
            &chunks,
        )
        .map_err(vault_store_error)?;
        Ok((asset.mime_type, bytes))
    }

    pub async fn scan_import_source(
        &self,
        request: ScanImportSourceRequest,
    ) -> Result<ImportSession, ServiceError> {
        let mut state = self.state.write().await;
        let library_root = effective_library_root(&state, &self.config);
        let library_root_path = PathBuf::from(library_root);
        let session = imports::scan_source(
            &request,
            default_import_mode(&state),
            Some(&library_root_path),
            |hash| {
                state
                    .assets
                    .iter()
                    .find(|asset| asset.content_hash == hash)
                    .map(|asset| asset.id)
            },
        )
        .map_err(|err| ServiceError::Io(err.to_string()))?;

        if let Some(existing) = state
            .import_sessions
            .iter_mut()
            .find(|value| value.id == session.id)
        {
            *existing = session.clone();
        } else {
            state.import_sessions.insert(0, session.clone());
        }

        state.jobs.insert(
            0,
            JobRecord {
                id: Uuid::new_v4(),
                kind: JobKind::Import,
                status: JobStatus::Completed,
                progress: 100,
                queued_at: Utc::now(),
                started_at: Some(Utc::now()),
                completed_at: Some(Utc::now()),
                detail: Some(imports::build_import_job_detail(
                    session.source_kind,
                    &session.source_path,
                    session.candidates.len(),
                )),
                cancel_requested: false,
                retry_of_job_id: None,
                attempt: 1,
            },
        );

        self.persist_locked_state(&state)?;
        Ok(session)
    }

    pub async fn import_session(&self, session_id: Uuid) -> Result<ImportSession, ServiceError> {
        self.state
            .read()
            .await
            .import_sessions
            .iter()
            .find(|session| session.id == session_id)
            .cloned()
            .ok_or_else(|| ServiceError::NotFound(format!("import session {session_id}")))
    }

    pub async fn import_sessions(&self) -> Vec<ImportSession> {
        self.state.read().await.import_sessions.clone()
    }

    pub async fn commit_import_session(
        &self,
        session_id: Uuid,
        selected_candidate_ids: Vec<Uuid>,
        import_mode_override: Option<ImportMode>,
        add_as_watch_folder_override: Option<bool>,
    ) -> Result<ImportSession, ServiceError> {
        let mut state = self.state.write().await;
        let session_index = state
            .import_sessions
            .iter()
            .position(|session| session.id == session_id)
            .ok_or_else(|| ServiceError::NotFound(format!("import session {session_id}")))?;

        let mut session = state.import_sessions[session_index].clone();
        let selected_ids: BTreeSet<Uuid> = if selected_candidate_ids.is_empty() {
            session
                .candidates
                .iter()
                .filter(|candidate| candidate.selected)
                .map(|candidate| candidate.id)
                .collect()
        } else {
            selected_candidate_ids.into_iter().collect()
        };

        if selected_ids.is_empty() {
            return Err(ServiceError::Invalid(
                "selected_candidate_ids must not be empty".to_string(),
            ));
        }

        let effective_mode = import_mode_override.unwrap_or(session.import_mode);
        let add_as_watch_folder =
            add_as_watch_folder_override.unwrap_or(session.add_as_watch_folder);
        let library_root = effective_library_root(&state, &self.config);
        let library_root_path = PathBuf::from(&library_root);
        if effective_mode == ImportMode::Move
            && !session.candidates.iter().any(|candidate| {
                selected_ids.contains(&candidate.id) && candidate.duplicate_asset_id.is_none()
            })
        {
            return Err(ServiceError::Invalid(
                "move commit requires at least one selected non-duplicate candidate".to_string(),
            ));
        }
        if matches!(effective_mode, ImportMode::Copy | ImportMode::Move) {
            storage::ensure_library_layout(&library_root_path)
                .map_err(|err| ServiceError::Storage(err.to_string()))?;
        }

        let mut known_hashes = state
            .assets
            .iter()
            .map(|asset| asset.content_hash.clone())
            .collect::<BTreeSet<_>>();
        let mut imported_asset_ids = Vec::new();
        let mut duplicate_asset_ids = Vec::new();
        let mut moved_asset_ids = Vec::new();
        let mut skipped_duplicate_ids = Vec::new();
        let mut failed_candidate_ids = Vec::new();
        let mut sidecars_moved = 0_usize;
        let mut new_assets: Vec<crate::domain::Asset> = Vec::new();

        for candidate in &mut session.candidates {
            candidate.selected = selected_ids.contains(&candidate.id);
            if !candidate.selected {
                continue;
            }

            if let Some(existing_id) = candidate.duplicate_asset_id {
                duplicate_asset_ids.push(existing_id);
                skipped_duplicate_ids.push(existing_id);
                candidate.safety_status = "duplicate_skip".to_string();
                continue;
            }

            if known_hashes.contains(&candidate.content_hash) {
                if let Some(existing) = state
                    .assets
                    .iter()
                    .find(|asset| asset.content_hash == candidate.content_hash)
                    .or_else(|| {
                        new_assets
                            .iter()
                            .find(|asset| asset.content_hash == candidate.content_hash)
                    })
                {
                    duplicate_asset_ids.push(existing.id);
                    skipped_duplicate_ids.push(existing.id);
                    candidate.duplicate_asset_id = Some(existing.id);
                    candidate.safety_status = "duplicate_skip".to_string();
                }
                continue;
            }

            let request = ImportAssetRequest {
                source_path: candidate.source_path.clone(),
                original_filename: candidate.original_filename.clone(),
                media_kind: candidate.media_kind.clone(),
                mime_type: candidate.mime_type.clone(),
                bytes: candidate.bytes,
                content_hash: Some(candidate.content_hash.clone()),
                captured_at: candidate.captured_at,
                place_hint: candidate.place_hint.clone(),
                import_mode: Some(effective_mode),
            };
            let (mut asset, _job) = imports::build_imported_asset(request);
            attach_extracted_metadata(
                &mut asset,
                candidate,
                &PathBuf::from(&candidate.source_path),
            );

            if effective_mode == ImportMode::Copy {
                let source_path = PathBuf::from(&candidate.source_path);
                let destination = library_root_path.join(&asset.relative_original_path);
                if let Some(parent) = destination.parent() {
                    fs::create_dir_all(parent).map_err(|err| ServiceError::Io(err.to_string()))?;
                }
                if !destination.exists() {
                    fs::copy(&source_path, &destination)
                        .map_err(|err| ServiceError::Io(err.to_string()))?;
                }
                asset.is_available = destination.exists();
            } else if effective_mode == ImportMode::Move {
                let source_path = PathBuf::from(&candidate.source_path);
                match safely_move_candidate(candidate, &mut asset, &source_path, &library_root_path)
                {
                    Ok(moved_sidecars) => {
                        sidecars_moved += moved_sidecars;
                        moved_asset_ids.push(asset.id);
                    }
                    Err(err) => {
                        failed_candidate_ids.push(candidate.id);
                        candidate.safety_status = format!("failed: {err}");
                        continue;
                    }
                }
            } else {
                asset.relative_original_path = candidate.source_path.clone();
                asset.is_available = Path::new(&candidate.source_path).exists();
            }

            known_hashes.insert(asset.content_hash.clone());
            imported_asset_ids.push(asset.id);
            new_assets.push(asset);
        }

        state.assets.extend(new_assets);
        ensure_distributed_defaults(&mut state);
        refresh_blob_records(&self.config, &mut state);
        session.status = ImportSessionStatus::Committed;
        session.import_mode = effective_mode;
        session.add_as_watch_folder = add_as_watch_folder;
        session.completed_at = Some(Utc::now());
        session.imported_asset_ids = imported_asset_ids;
        session.duplicate_asset_ids = duplicate_asset_ids;
        session.moved_asset_ids = moved_asset_ids;
        session.skipped_duplicate_ids = skipped_duplicate_ids;
        session.failed_candidate_ids = failed_candidate_ids;
        session.sidecars_moved = sidecars_moved;
        imports::refresh_import_session_summary(&mut session, Some(&library_root_path));
        state.import_sessions[session_index] = session.clone();

        if add_as_watch_folder && Path::new(&session.source_path).is_dir() {
            upsert_watch_folder(&mut state, &session.source_path, effective_mode);
        }

        refresh_derived_views(&mut state);
        state.jobs.insert(
            0,
            completed_job(
                JobKind::Import,
                format!(
                    "committed {} imported, {} duplicate skipped, {} failed from {}",
                    session.imported_asset_ids.len(),
                    session.skipped_duplicate_ids.len(),
                    session.failed_candidate_ids.len(),
                    session.source_path
                ),
            ),
        );
        self.persist_locked_state(&state)?;
        Ok(session)
    }

    pub async fn import_asset(
        &self,
        request: ImportAssetRequest,
    ) -> Result<ImportAssetResponse, ServiceError> {
        if request.original_filename.trim().is_empty() || request.source_path.trim().is_empty() {
            return Err(ServiceError::Invalid(
                "source_path and original_filename are required".to_string(),
            ));
        }

        let mut state = self.state.write().await;
        let effective_mode = request.import_mode.unwrap_or(default_import_mode(&state));
        let library_root = effective_library_root(&state, &self.config);
        let library_root_path = PathBuf::from(&library_root);
        if matches!(effective_mode, ImportMode::Copy | ImportMode::Move) {
            storage::ensure_library_layout(&library_root_path)
                .map_err(|err| ServiceError::Storage(err.to_string()))?;
        }

        let (mut asset, mut job) = imports::build_imported_asset(ImportAssetRequest {
            import_mode: Some(effective_mode),
            content_hash: None,
            ..request
        });
        let source_for_metadata = PathBuf::from(&asset.source_path);
        let extracted =
            metadata::extract_media_metadata(&source_for_metadata, &[], asset.captured_at);
        asset.captured_at = extracted.captured_at;
        if asset.place_hint.is_none() {
            asset.place_hint = metadata::coarse_place_label(&extracted);
        }
        asset.metadata = Some(extracted.into_asset_metadata(asset.id));

        if state
            .assets
            .iter()
            .any(|existing| existing.content_hash == asset.content_hash)
        {
            return Err(ServiceError::Invalid(
                "asset with identical checksum already exists".to_string(),
            ));
        }

        if effective_mode == ImportMode::Copy {
            let destination = library_root_path.join(&asset.relative_original_path);
            if let Some(parent) = destination.parent() {
                fs::create_dir_all(parent).map_err(|err| ServiceError::Io(err.to_string()))?;
            }
            fs::copy(&asset.source_path, &destination)
                .map_err(|err| ServiceError::Io(err.to_string()))?;
            asset.is_available = destination.exists();
        } else if effective_mode == ImportMode::Move {
            return Err(ServiceError::Invalid(
                "move mode requires the scan/commit import flow".to_string(),
            ));
        } else {
            asset.relative_original_path = asset.source_path.clone();
            asset.is_available = Path::new(&asset.source_path).exists();
        }

        job.status = JobStatus::Completed;
        job.progress = 100;
        job.started_at = Some(Utc::now());
        job.completed_at = Some(Utc::now());
        job.detail = Some(format!("imported {}", asset.original_filename));

        state.assets.push(asset.clone());
        state.jobs.insert(0, job.clone());
        refresh_derived_views(&mut state);
        ensure_distributed_defaults(&mut state);
        refresh_blob_records(&self.config, &mut state);
        self.persist_locked_state(&state)?;
        Ok(ImportAssetResponse { asset, job })
    }

    pub async fn asset_metadata(
        &self,
        asset_id: Uuid,
    ) -> Result<crate::domain::AssetMetadata, ServiceError> {
        self.state
            .read()
            .await
            .assets
            .iter()
            .find(|asset| asset.id == asset_id)
            .and_then(|asset| asset.metadata.clone())
            .ok_or_else(|| ServiceError::NotFound(format!("metadata for asset {asset_id}")))
    }

    pub async fn correct_asset_date(
        &self,
        asset_id: Uuid,
        request: CorrectDateRequest,
    ) -> Result<crate::domain::AssetMetadata, ServiceError> {
        let mut state = self.state.write().await;
        let (metadata, correction) = {
            let asset = state
                .assets
                .iter_mut()
                .find(|asset| asset.id == asset_id)
                .ok_or_else(|| ServiceError::NotFound(format!("asset {asset_id}")))?;
            let previous = json!({
                "captured_at": asset.captured_at,
                "captured_at_source": asset.metadata.as_ref().map(|value| value.captured_at_source),
                "timezone_offset_minutes": asset.metadata.as_ref().and_then(|value| value.timezone_offset_minutes),
            });
            asset.captured_at = request.captured_at;
            let metadata = asset
                .metadata
                .get_or_insert_with(|| crate::domain::AssetMetadata {
                    asset_id,
                    captured_at: request.captured_at,
                    captured_at_source: MetadataSource::Manual,
                    timezone_offset_minutes: request.timezone_offset_minutes,
                    width: None,
                    height: None,
                    camera: None,
                    geo: None,
                    sidecar_title: None,
                    sidecar_description: None,
                    folder_hint: None,
                    derived: crate::domain::ModelProvenance::local("manual-correction", "v1"),
                });
            metadata.captured_at = request.captured_at;
            metadata.captured_at_source = MetadataSource::Manual;
            metadata.timezone_offset_minutes = request.timezone_offset_minutes;
            metadata.derived = crate::domain::ModelProvenance::local("manual-correction", "v1");
            let updated = metadata.clone();
            let correction = CorrectionRecord {
                id: Uuid::new_v4(),
                kind: CorrectionKind::CorrectDate,
                asset_id: Some(asset_id),
                place_id: None,
                event_id: None,
                previous_json: previous,
                applied_json: json!({
                    "captured_at": request.captured_at,
                    "timezone_offset_minutes": request.timezone_offset_minutes,
                    "reason": request.reason,
                }),
                created_at: Utc::now(),
            };
            (updated, correction)
        };
        state.corrections.push(correction);
        refresh_derived_views(&mut state);
        self.persist_locked_state(&state)?;
        Ok(metadata)
    }

    pub async fn rebuild_metadata(&self) -> Result<JobRecord, ServiceError> {
        let mut state = self.state.write().await;
        let library_root = effective_library_root(&state, &self.config);
        let library_root = PathBuf::from(library_root);
        for asset in &mut state.assets {
            let source_path = asset_file_path(asset, &library_root);
            let extracted = metadata::extract_media_metadata(&source_path, &[], asset.captured_at);
            asset.captured_at = extracted.captured_at;
            if asset.place_hint.is_none() {
                asset.place_hint = metadata::coarse_place_label(&extracted);
            }
            asset.metadata = Some(extracted.into_asset_metadata(asset.id));
        }
        refresh_derived_views(&mut state);
        let job = completed_job(
            JobKind::MetadataExtraction,
            format!("rebuilt metadata for {} assets", state.assets.len()),
        );
        state
            .job_logs
            .push(job_log(job.id, "info", "metadata rebuild ran offline-only"));
        state.jobs.insert(0, job.clone());
        self.persist_locked_state(&state)?;
        Ok(job)
    }

    pub async fn rebuild_places(&self) -> Result<JobRecord, ServiceError> {
        let mut state = self.state.write().await;
        state.places = derive_places(&state.assets, &state.places);
        let job = completed_job(
            JobKind::MetadataExtraction,
            format!("rebuilt {} local place clusters", state.places.len()),
        );
        state
            .job_logs
            .push(job_log(job.id, "info", "places rebuild ran offline-only"));
        state.jobs.insert(0, job.clone());
        self.persist_locked_state(&state)?;
        Ok(job)
    }

    pub async fn rebuild_events(&self) -> Result<JobRecord, ServiceError> {
        let mut state = self.state.write().await;
        state.events = derive_events(&state.assets, &state.places, &state.events);
        let job = completed_job(
            JobKind::EventClustering,
            format!("rebuilt {} local event clusters", state.events.len()),
        );
        state
            .job_logs
            .push(job_log(job.id, "info", "events rebuild ran offline-only"));
        state.jobs.insert(0, job.clone());
        self.persist_locked_state(&state)?;
        Ok(job)
    }

    pub async fn timeline(&self) -> TimelineResponse {
        self.timeline_page(None, None, None).await
    }

    pub async fn timeline_with_limit(
        &self,
        asset_limit: Option<usize>,
        per_bucket_limit: Option<usize>,
    ) -> TimelineResponse {
        self.timeline_page(asset_limit, per_bucket_limit, None)
            .await
    }

    pub async fn timeline_page(
        &self,
        asset_limit: Option<usize>,
        per_bucket_limit: Option<usize>,
        cursor_offset: Option<usize>,
    ) -> TimelineResponse {
        self.timeline_page_filtered(asset_limit, per_bucket_limit, cursor_offset, false)
            .await
    }

    pub async fn timeline_page_filtered(
        &self,
        asset_limit: Option<usize>,
        per_bucket_limit: Option<usize>,
        cursor_offset: Option<usize>,
        include_archived: bool,
    ) -> TimelineResponse {
        let state = self.state.read().await;
        let mut assets = state
            .assets
            .iter()
            .filter(|asset| include_archived || !asset.archived)
            .cloned()
            .collect::<Vec<_>>();
        assets.sort_by(|left, right| {
            right
                .captured_at
                .cmp(&left.captured_at)
                .then_with(|| right.id.cmp(&left.id))
        });

        let total_assets = assets.len();
        let offset = cursor_offset.unwrap_or(0).min(total_assets);
        let asset_limit = asset_limit.filter(|limit| *limit > 0).unwrap_or(usize::MAX);
        let per_bucket_limit = per_bucket_limit
            .filter(|limit| *limit > 0)
            .unwrap_or(usize::MAX);

        let mut full_bucket_counts = HashMap::<String, usize>::new();
        for asset in &assets {
            let label = asset.captured_at.format("%B %Y").to_string();
            *full_bucket_counts.entry(label).or_default() += 1;
        }

        let mut buckets = Vec::<TimelineBucket>::new();
        let mut returned_assets = 0_usize;
        let mut next_cursor = None;
        let mut page_bucket_counts = HashMap::<String, usize>::new();

        for (index, asset) in assets.into_iter().enumerate().skip(offset) {
            if returned_assets >= asset_limit {
                next_cursor = Some(index.to_string());
                break;
            }

            let label = asset.captured_at.format("%B %Y").to_string();
            let page_bucket_count = page_bucket_counts.entry(label.clone()).or_default();
            if *page_bucket_count >= per_bucket_limit {
                next_cursor = Some(index.to_string());
                break;
            }
            *page_bucket_count += 1;

            let asset_id = asset.id;
            if let Some(bucket) = buckets.last_mut().filter(|bucket| bucket.label == label) {
                bucket.asset_ids.push(asset_id);
                bucket.assets.push(asset);
            } else {
                buckets.push(TimelineBucket {
                    total_assets: full_bucket_counts.get(&label).copied().unwrap_or(0),
                    label,
                    asset_ids: vec![asset_id],
                    assets: vec![asset],
                });
            }

            returned_assets += 1;
        }

        TimelineResponse {
            buckets,
            next_cursor,
            total_assets,
            returned_assets,
        }
    }

    pub async fn update_asset_flags(
        &self,
        asset_id: Uuid,
        request: UpdateAssetFlagsRequest,
    ) -> Result<Asset, ServiceError> {
        if request.favorite.is_none() && request.archived.is_none() {
            return Err(ServiceError::Invalid(
                "favorite or archived must be provided".to_string(),
            ));
        }

        let mut state = self.state.write().await;
        let (previous_favorite, previous_archived, updated) = {
            let asset = state
                .assets
                .iter_mut()
                .find(|asset| asset.id == asset_id)
                .ok_or_else(|| ServiceError::NotFound(format!("asset {asset_id}")))?;
            let previous_favorite = asset.favorite;
            let previous_archived = asset.archived;
            if let Some(favorite) = request.favorite {
                asset.favorite = favorite;
            }
            if let Some(archived) = request.archived {
                asset.archived = archived;
            }
            (previous_favorite, previous_archived, asset.clone())
        };

        state.feedback.push(FeedbackEvent {
            id: Uuid::new_v4(),
            kind: crate::domain::FeedbackKind::UpdateAssetFlags,
            payload: json!({
                "asset_id": asset_id,
                "previous": {
                    "favorite": previous_favorite,
                    "archived": previous_archived,
                },
                "applied": {
                    "favorite": updated.favorite,
                    "archived": updated.archived,
                },
            }),
            created_at: Utc::now(),
        });
        self.persist_locked_state(&state)?;
        Ok(updated)
    }

    pub async fn update_assets_flags(
        &self,
        request: UpdateAssetsFlagsRequest,
    ) -> Result<Vec<Asset>, ServiceError> {
        if request.asset_ids.is_empty() {
            return Err(ServiceError::Invalid(
                "asset_ids must not be empty".to_string(),
            ));
        }
        if request.favorite.is_none() && request.archived.is_none() {
            return Err(ServiceError::Invalid(
                "favorite or archived must be provided".to_string(),
            ));
        }

        let mut state = self.state.write().await;
        let asset_ids = validate_asset_ids(&state.assets, &request.asset_ids)?;
        let selected = asset_ids.iter().copied().collect::<BTreeSet<_>>();
        let mut previous = Vec::new();
        let mut updated = Vec::new();
        for asset in state
            .assets
            .iter_mut()
            .filter(|asset| selected.contains(&asset.id))
        {
            previous.push(json!({
                "asset_id": asset.id,
                "favorite": asset.favorite,
                "archived": asset.archived,
            }));
            if let Some(favorite) = request.favorite {
                asset.favorite = favorite;
            }
            if let Some(archived) = request.archived {
                asset.archived = archived;
            }
            updated.push(asset.clone());
        }

        state.feedback.push(FeedbackEvent {
            id: Uuid::new_v4(),
            kind: crate::domain::FeedbackKind::UpdateAssetFlags,
            payload: json!({
                "asset_ids": asset_ids,
                "previous": previous,
                "applied": {
                    "favorite": request.favorite,
                    "archived": request.archived,
                },
            }),
            created_at: Utc::now(),
        });
        self.persist_locked_state(&state)?;
        Ok(sorted_assets(updated))
    }

    pub async fn favorite_assets(&self) -> Vec<Asset> {
        let state = self.state.read().await;
        sorted_assets(
            state
                .assets
                .iter()
                .filter(|asset| asset.favorite)
                .cloned()
                .collect(),
        )
    }

    pub async fn archived_assets(&self) -> Vec<Asset> {
        let state = self.state.read().await;
        sorted_assets(
            state
                .assets
                .iter()
                .filter(|asset| asset.archived)
                .cloned()
                .collect(),
        )
    }

    pub async fn albums(&self) -> Vec<Album> {
        self.state.read().await.albums.clone()
    }

    pub async fn album(&self, album_id: Uuid) -> Result<Album, ServiceError> {
        self.state
            .read()
            .await
            .albums
            .iter()
            .find(|album| album.id == album_id)
            .cloned()
            .ok_or_else(|| ServiceError::NotFound(format!("album {album_id}")))
    }

    pub async fn album_assets(&self, album_id: Uuid) -> Result<Vec<Asset>, ServiceError> {
        let state = self.state.read().await;
        let album = state
            .albums
            .iter()
            .find(|album| album.id == album_id)
            .ok_or_else(|| ServiceError::NotFound(format!("album {album_id}")))?;
        assets_by_ids(&state.assets, &album.asset_ids)
    }

    pub async fn create_album(&self, request: CreateAlbumRequest) -> Result<Album, ServiceError> {
        let title = request.title.trim();
        if title.is_empty() {
            return Err(ServiceError::Invalid("title must not be empty".to_string()));
        }

        let mut state = self.state.write().await;
        let asset_ids = validate_asset_ids(&state.assets, &request.asset_ids)?;
        let now = Utc::now();
        let album = Album {
            id: Uuid::new_v4(),
            title: title.to_string(),
            cover_asset_id: asset_ids.first().copied(),
            asset_ids,
            created_at: now,
            updated_at: now,
        };
        state.feedback.push(FeedbackEvent {
            id: Uuid::new_v4(),
            kind: crate::domain::FeedbackKind::CreateAlbum,
            payload: json!({
                "album_id": album.id,
                "title": album.title,
                "asset_ids": album.asset_ids,
            }),
            created_at: now,
        });
        state.albums.insert(0, album.clone());
        self.persist_locked_state(&state)?;
        Ok(album)
    }

    pub async fn rename_album(
        &self,
        album_id: Uuid,
        request: RenameAlbumRequest,
    ) -> Result<Album, ServiceError> {
        let title = request.title.trim();
        if title.is_empty() {
            return Err(ServiceError::Invalid("title must not be empty".to_string()));
        }

        let mut state = self.state.write().await;
        let (previous_title, updated) = {
            let album = state
                .albums
                .iter_mut()
                .find(|album| album.id == album_id)
                .ok_or_else(|| ServiceError::NotFound(format!("album {album_id}")))?;
            let previous_title = album.title.clone();
            album.title = title.to_string();
            album.updated_at = Utc::now();
            (previous_title, album.clone())
        };
        state.feedback.push(FeedbackEvent {
            id: Uuid::new_v4(),
            kind: crate::domain::FeedbackKind::RenameAlbum,
            payload: json!({
                "album_id": album_id,
                "previous_title": previous_title,
                "title": updated.title,
            }),
            created_at: Utc::now(),
        });
        self.persist_locked_state(&state)?;
        Ok(updated)
    }

    pub async fn add_album_assets(
        &self,
        album_id: Uuid,
        request: UpdateAlbumAssetsRequest,
    ) -> Result<Album, ServiceError> {
        let mut state = self.state.write().await;
        let asset_ids = validate_asset_ids(&state.assets, &request.asset_ids)?;
        if asset_ids.is_empty() {
            return Err(ServiceError::Invalid(
                "asset_ids must not be empty".to_string(),
            ));
        }

        let updated = {
            let album = state
                .albums
                .iter_mut()
                .find(|album| album.id == album_id)
                .ok_or_else(|| ServiceError::NotFound(format!("album {album_id}")))?;
            for asset_id in &asset_ids {
                if !album.asset_ids.contains(asset_id) {
                    album.asset_ids.push(*asset_id);
                }
            }
            if album.cover_asset_id.is_none() {
                album.cover_asset_id = album.asset_ids.first().copied();
            }
            album.updated_at = Utc::now();
            album.clone()
        };

        state.feedback.push(FeedbackEvent {
            id: Uuid::new_v4(),
            kind: crate::domain::FeedbackKind::AddAlbumAssets,
            payload: json!({
                "album_id": album_id,
                "asset_ids": asset_ids,
            }),
            created_at: Utc::now(),
        });
        self.persist_locked_state(&state)?;
        Ok(updated)
    }

    pub async fn remove_album_assets(
        &self,
        album_id: Uuid,
        request: UpdateAlbumAssetsRequest,
    ) -> Result<Album, ServiceError> {
        let asset_ids = request.asset_ids.into_iter().collect::<BTreeSet<_>>();
        if asset_ids.is_empty() {
            return Err(ServiceError::Invalid(
                "asset_ids must not be empty".to_string(),
            ));
        }

        let mut state = self.state.write().await;
        let updated = {
            let album = state
                .albums
                .iter_mut()
                .find(|album| album.id == album_id)
                .ok_or_else(|| ServiceError::NotFound(format!("album {album_id}")))?;
            album
                .asset_ids
                .retain(|asset_id| !asset_ids.contains(asset_id));
            if album
                .cover_asset_id
                .map(|id| asset_ids.contains(&id))
                .unwrap_or(false)
            {
                album.cover_asset_id = album.asset_ids.first().copied();
            }
            album.updated_at = Utc::now();
            album.clone()
        };

        state.feedback.push(FeedbackEvent {
            id: Uuid::new_v4(),
            kind: crate::domain::FeedbackKind::RemoveAlbumAssets,
            payload: json!({
                "album_id": album_id,
                "asset_ids": asset_ids,
            }),
            created_at: Utc::now(),
        });
        self.persist_locked_state(&state)?;
        Ok(updated)
    }

    pub async fn delete_album(&self, album_id: Uuid) -> Result<(), ServiceError> {
        let mut state = self.state.write().await;
        let before = state.albums.len();
        state.albums.retain(|album| album.id != album_id);
        if state.albums.len() == before {
            return Err(ServiceError::NotFound(format!("album {album_id}")));
        }
        state.feedback.push(FeedbackEvent {
            id: Uuid::new_v4(),
            kind: crate::domain::FeedbackKind::DeleteAlbum,
            payload: json!({ "album_id": album_id }),
            created_at: Utc::now(),
        });
        self.persist_locked_state(&state)?;
        Ok(())
    }

    pub async fn people(&self) -> Vec<PersonCluster> {
        self.state.read().await.people.clone()
    }

    pub async fn person(&self, person_id: Uuid) -> Result<PersonCluster, ServiceError> {
        self.state
            .read()
            .await
            .people
            .iter()
            .find(|person| person.id == person_id)
            .cloned()
            .ok_or_else(|| ServiceError::NotFound(format!("person {person_id}")))
    }

    pub async fn person_assets(&self, person_id: Uuid) -> Result<Vec<Asset>, ServiceError> {
        let state = self.state.read().await;
        let person = state
            .people
            .iter()
            .find(|person| person.id == person_id)
            .ok_or_else(|| ServiceError::NotFound(format!("person {person_id}")))?;
        let asset_ids = person.asset_ids.iter().copied().collect::<BTreeSet<_>>();
        Ok(state
            .assets
            .iter()
            .filter(|asset| asset_ids.contains(&asset.id))
            .cloned()
            .collect())
    }

    pub async fn create_manual_person(
        &self,
        request: CreateManualPersonRequest,
    ) -> Result<PersonCluster, ServiceError> {
        let display_name = request.display_name.trim();
        if display_name.is_empty() {
            return Err(ServiceError::Invalid(
                "display_name must not be empty".to_string(),
            ));
        }

        let mut state = self.state.write().await;
        let asset_ids = validate_asset_ids(&state.assets, &request.asset_ids)?;
        let person = PersonCluster {
            id: Uuid::new_v4(),
            display_name: display_name.to_string(),
            representative_asset_id: asset_ids.first().copied(),
            asset_ids,
            face_template_ids: Vec::new(),
            hidden: false,
            derived: crate::domain::ModelProvenance::local("manual-person", "v1"),
        };

        state.feedback.push(FeedbackEvent {
            id: Uuid::new_v4(),
            kind: crate::domain::FeedbackKind::CreatePerson,
            payload: json!({
                "person_id": person.id,
                "display_name": person.display_name,
                "asset_ids": person.asset_ids,
            }),
            created_at: Utc::now(),
        });
        state.people.push(person.clone());
        let people_snapshot = state.people.clone();
        refresh_event_people_from_people(&mut state.events, &people_snapshot);
        self.persist_locked_state(&state)?;
        Ok(person)
    }

    pub async fn add_person_assets(
        &self,
        person_id: Uuid,
        request: UpdatePersonAssetsRequest,
    ) -> Result<PersonCluster, ServiceError> {
        let mut state = self.state.write().await;
        let asset_ids = validate_asset_ids(&state.assets, &request.asset_ids)?;
        if asset_ids.is_empty() {
            return Err(ServiceError::Invalid(
                "asset_ids must not be empty".to_string(),
            ));
        }

        let updated = {
            let person = state
                .people
                .iter_mut()
                .find(|person| person.id == person_id)
                .ok_or_else(|| ServiceError::NotFound(format!("person {person_id}")))?;
            for asset_id in &asset_ids {
                if !person.asset_ids.contains(asset_id) {
                    person.asset_ids.push(*asset_id);
                }
            }
            person.asset_ids.sort();
            person.asset_ids.dedup();
            if person.representative_asset_id.is_none() {
                person.representative_asset_id = person.asset_ids.first().copied();
            }
            person.derived = crate::domain::ModelProvenance::local("manual-person-assets", "v1");
            person.clone()
        };

        state.feedback.push(FeedbackEvent {
            id: Uuid::new_v4(),
            kind: crate::domain::FeedbackKind::AssignPersonAssets,
            payload: json!({
                "person_id": person_id,
                "asset_ids": asset_ids,
            }),
            created_at: Utc::now(),
        });
        let people_snapshot = state.people.clone();
        refresh_event_people_from_people(&mut state.events, &people_snapshot);
        self.persist_locked_state(&state)?;
        Ok(updated)
    }

    pub async fn remove_person_assets(
        &self,
        person_id: Uuid,
        request: UpdatePersonAssetsRequest,
    ) -> Result<PersonCluster, ServiceError> {
        let mut state = self.state.write().await;
        let asset_ids = request.asset_ids.into_iter().collect::<BTreeSet<_>>();
        if asset_ids.is_empty() {
            return Err(ServiceError::Invalid(
                "asset_ids must not be empty".to_string(),
            ));
        }

        let updated = {
            let person = state
                .people
                .iter_mut()
                .find(|person| person.id == person_id)
                .ok_or_else(|| ServiceError::NotFound(format!("person {person_id}")))?;
            person
                .asset_ids
                .retain(|asset_id| !asset_ids.contains(asset_id));
            if person
                .representative_asset_id
                .map(|id| asset_ids.contains(&id))
                .unwrap_or(false)
            {
                person.representative_asset_id = person.asset_ids.first().copied();
            }
            person.derived = crate::domain::ModelProvenance::local("manual-person-assets", "v1");
            person.clone()
        };

        state.feedback.push(FeedbackEvent {
            id: Uuid::new_v4(),
            kind: crate::domain::FeedbackKind::RemovePersonAssets,
            payload: json!({
                "person_id": person_id,
                "asset_ids": asset_ids,
            }),
            created_at: Utc::now(),
        });
        let people_snapshot = state.people.clone();
        refresh_event_people_from_people(&mut state.events, &people_snapshot);
        self.persist_locked_state(&state)?;
        Ok(updated)
    }

    pub async fn rename_person(
        &self,
        person_id: Uuid,
        request: RenamePersonRequest,
    ) -> Result<PersonCluster, ServiceError> {
        let display_name = request.display_name.trim();
        if display_name.is_empty() {
            return Err(ServiceError::Invalid(
                "display_name must not be empty".to_string(),
            ));
        }

        let mut state = self.state.write().await;
        let updated = {
            let person = state
                .people
                .iter_mut()
                .find(|person| person.id == person_id)
                .ok_or_else(|| ServiceError::NotFound(format!("person {person_id}")))?;
            let previous = person.display_name.clone();
            person.display_name = display_name.to_string();
            person.derived = crate::domain::ModelProvenance::local("manual-correction", "v1");
            let updated = person.clone();
            state.feedback.push(FeedbackEvent {
                id: Uuid::new_v4(),
                kind: crate::domain::FeedbackKind::RenamePerson,
                payload: json!({
                    "person_id": person_id,
                    "previous_display_name": previous,
                    "display_name": display_name,
                }),
                created_at: Utc::now(),
            });
            updated
        };
        self.persist_locked_state(&state)?;
        Ok(updated)
    }

    pub async fn hide_person(
        &self,
        person_id: Uuid,
        request: HidePersonRequest,
    ) -> Result<PersonCluster, ServiceError> {
        let mut state = self.state.write().await;
        let updated = {
            let person = state
                .people
                .iter_mut()
                .find(|person| person.id == person_id)
                .ok_or_else(|| ServiceError::NotFound(format!("person {person_id}")))?;
            person.hidden = request.hidden;
            person.derived = crate::domain::ModelProvenance::local("manual-correction", "v1");
            let updated = person.clone();
            state.feedback.push(FeedbackEvent {
                id: Uuid::new_v4(),
                kind: crate::domain::FeedbackKind::HideFace,
                payload: json!({
                    "person_id": person_id,
                    "hidden": request.hidden,
                    "reason": request.reason,
                }),
                created_at: Utc::now(),
            });
            updated
        };
        self.persist_locked_state(&state)?;
        Ok(updated)
    }

    pub async fn reject_person_match(
        &self,
        person_id: Uuid,
        request: RejectPersonMatchRequest,
    ) -> Result<PersonCluster, ServiceError> {
        let mut state = self.state.write().await;
        let person = state
            .people
            .iter()
            .find(|person| person.id == person_id)
            .cloned()
            .ok_or_else(|| ServiceError::NotFound(format!("person {person_id}")))?;

        if let Some(face_template_id) = request.face_template_id {
            for face in &mut state.faces {
                if face.id == face_template_id && face.person_cluster_id == Some(person_id) {
                    face.person_cluster_id = None;
                }
            }
        }

        state.feedback.push(FeedbackEvent {
            id: Uuid::new_v4(),
            kind: crate::domain::FeedbackKind::RejectMatch,
            payload: json!({
                "person_id": person_id,
                "face_template_id": request.face_template_id,
                "asset_id": request.asset_id,
                "reason": request.reason,
            }),
            created_at: Utc::now(),
        });
        self.persist_locked_state(&state)?;
        Ok(person)
    }

    pub async fn merge_person(
        &self,
        target_id: Uuid,
        request: MergePersonRequest,
    ) -> Result<PersonCluster, ServiceError> {
        let source_ids: Vec<Uuid> = request
            .source_person_ids
            .iter()
            .copied()
            .filter(|id| *id != target_id)
            .collect();

        if source_ids.is_empty() {
            return Err(ServiceError::Invalid(
                "source_person_ids must not be empty".to_string(),
            ));
        }

        let mut state = self.state.write().await;
        state
            .people
            .iter()
            .position(|person| person.id == target_id)
            .ok_or_else(|| ServiceError::NotFound(format!("person {target_id}")))?;

        let sources: Vec<PersonCluster> = state
            .people
            .iter()
            .filter(|person| source_ids.contains(&person.id))
            .cloned()
            .collect();

        if sources.is_empty() {
            return Err(ServiceError::NotFound("merge sources".to_string()));
        }

        {
            let target = state
                .people
                .iter_mut()
                .find(|person| person.id == target_id)
                .expect("target must exist");
            people::merge_clusters(target, &sources);
        }

        for face in &mut state.faces {
            if let Some(cluster_id) = face.person_cluster_id
                && source_ids.contains(&cluster_id)
            {
                face.person_cluster_id = Some(target_id);
            }
        }

        for event in &mut state.events {
            if event
                .people_ids
                .iter()
                .any(|person_id| source_ids.contains(person_id))
            {
                event.people_ids.retain(|id| !source_ids.contains(id));
                event.people_ids.push(target_id);
                event.people_ids.sort();
                event.people_ids.dedup();
            }
        }

        state
            .people
            .retain(|person| person.id == target_id || !source_ids.contains(&person.id));
        self.persist_locked_state(&state)?;

        state
            .people
            .iter()
            .find(|person| person.id == target_id)
            .cloned()
            .ok_or_else(|| ServiceError::NotFound(format!("person {target_id}")))
    }

    pub async fn split_person(
        &self,
        person_id: Uuid,
        request: SplitPersonRequest,
    ) -> Result<PersonCluster, ServiceError> {
        let mut state = self.state.write().await;
        let target = state
            .people
            .iter_mut()
            .find(|person| person.id == person_id)
            .ok_or_else(|| ServiceError::NotFound(format!("person {person_id}")))?;

        let new_cluster_id = Uuid::new_v4();
        let new_name = request
            .new_display_name
            .unwrap_or_else(|| "New person".to_string());
        let new_cluster =
            people::split_cluster(target, new_cluster_id, new_name, &request.face_template_ids)
                .ok_or_else(|| ServiceError::Invalid("unable to split cluster".to_string()))?;

        for face in &mut state.faces {
            if request.face_template_ids.contains(&face.id) {
                face.person_cluster_id = Some(new_cluster_id);
            }
        }

        state.people.push(new_cluster.clone());
        self.persist_locked_state(&state)?;
        Ok(new_cluster)
    }

    pub async fn places(&self) -> Vec<PlaceCluster> {
        self.state.read().await.places.clone()
    }

    pub async fn place_assets(&self, place_id: Uuid) -> Result<Vec<Asset>, ServiceError> {
        let state = self.state.read().await;
        let place = state
            .places
            .iter()
            .find(|place| place.id == place_id)
            .ok_or_else(|| ServiceError::NotFound(format!("place {place_id}")))?;
        assets_by_ids(&state.assets, &place.asset_ids)
    }

    pub async fn correct_place(
        &self,
        place_id: Uuid,
        request: CorrectPlaceRequest,
    ) -> Result<PlaceCluster, ServiceError> {
        if request.label.trim().is_empty() {
            return Err(ServiceError::Invalid(
                "place label must not be empty".to_string(),
            ));
        }

        let mut state = self.state.write().await;
        let (asset_ids, correction) = {
            let place = state
                .places
                .iter_mut()
                .find(|place| place.id == place_id)
                .ok_or_else(|| ServiceError::NotFound(format!("place {place_id}")))?;
            let previous = json!({
                "label": place.label,
                "centroid_latitude": place.centroid_latitude,
                "centroid_longitude": place.centroid_longitude,
            });
            place.label = request.label.trim().to_string();
            place.centroid_latitude = request.latitude.or(place.centroid_latitude);
            place.centroid_longitude = request.longitude.or(place.centroid_longitude);
            let correction = CorrectionRecord {
                id: Uuid::new_v4(),
                kind: CorrectionKind::CorrectPlace,
                asset_id: None,
                place_id: Some(place_id),
                event_id: None,
                previous_json: previous,
                applied_json: json!({
                    "label": request.label.trim(),
                    "latitude": request.latitude,
                    "longitude": request.longitude,
                    "hide_exact_gps": request.hide_exact_gps,
                    "reason": request.reason,
                }),
                created_at: Utc::now(),
            };
            (place.asset_ids.clone(), correction)
        };
        state.corrections.push(correction);

        for asset in &mut state.assets {
            if !asset_ids.contains(&asset.id) {
                continue;
            }
            asset.place_hint = Some(request.label.trim().to_string());
            if let Some(metadata) = &mut asset.metadata {
                if let (Some(latitude), Some(longitude)) = (request.latitude, request.longitude) {
                    metadata.geo = Some(crate::domain::GeoTag {
                        latitude,
                        longitude,
                        altitude_meters: None,
                        source: MetadataSource::Manual,
                        exact_hidden: request.hide_exact_gps.unwrap_or(true),
                    });
                } else if let Some(hide) = request.hide_exact_gps
                    && let Some(geo) = &mut metadata.geo
                {
                    geo.exact_hidden = hide;
                }
            }
        }

        refresh_derived_views(&mut state);
        let updated = state
            .places
            .iter()
            .find(|place| place.id == place_id)
            .cloned()
            .ok_or_else(|| ServiceError::NotFound(format!("place {place_id}")))?;
        self.persist_locked_state(&state)?;
        Ok(updated)
    }

    pub async fn events(&self) -> Vec<EventCluster> {
        self.state.read().await.events.clone()
    }

    pub async fn event_assets(&self, event_id: Uuid) -> Result<Vec<Asset>, ServiceError> {
        let state = self.state.read().await;
        let event = state
            .events
            .iter()
            .find(|event| event.id == event_id)
            .ok_or_else(|| ServiceError::NotFound(format!("event {event_id}")))?;
        assets_by_ids(&state.assets, &event.asset_ids)
    }

    pub async fn title_event(
        &self,
        event_id: Uuid,
        title: String,
    ) -> Result<EventCluster, ServiceError> {
        let mut state = self.state.write().await;
        let event = state
            .events
            .iter_mut()
            .find(|event| event.id == event_id)
            .ok_or_else(|| ServiceError::NotFound(format!("event {event_id}")))?;
        let previous_title = event.title.clone();
        events::retitle_event(event, title);
        let updated = event.clone();
        state.corrections.push(CorrectionRecord {
            id: Uuid::new_v4(),
            kind: CorrectionKind::TitleEvent,
            asset_id: None,
            place_id: None,
            event_id: Some(event_id),
            previous_json: json!({ "title": previous_title }),
            applied_json: json!({ "title": updated.title }),
            created_at: Utc::now(),
        });
        self.persist_locked_state(&state)?;
        Ok(updated)
    }

    pub async fn record_feedback(
        &self,
        feedback: FeedbackEvent,
    ) -> Result<FeedbackEvent, ServiceError> {
        let mut state = self.state.write().await;
        state.feedback.push(feedback.clone());
        self.persist_locked_state(&state)?;
        Ok(feedback)
    }

    pub async fn search(&self, query: SearchQuery) -> SearchResponse {
        let state = self.state.read().await;
        search::search_library(
            query,
            &state.assets,
            &state.people,
            &state.places,
            &state.events,
            &state.ocr_blocks,
            &state.scene_tags,
        )
    }

    pub async fn search_status(&self) -> Result<SearchIndexStatus, ServiceError> {
        let state = self.state.read().await;
        let metadata_ready =
            !state.assets.is_empty() && state.assets.iter().all(|asset| asset.metadata.is_some());
        let latest_ocr_job = state
            .jobs
            .iter()
            .find(|job| matches!(job.kind, JobKind::OcrIndex));
        let ocr_has_successful_job = latest_ocr_job
            .map(|job| job.status == JobStatus::Completed)
            .unwrap_or(false);
        let ocr_indexed_asset_count = state
            .ocr_blocks
            .iter()
            .map(|block| block.asset_id)
            .collect::<BTreeSet<_>>()
            .len();
        let ocr_text_block_count = state
            .ocr_blocks
            .iter()
            .filter(|block| !block.text.trim().is_empty())
            .count();
        let ocr_total_photo_count = state
            .assets
            .iter()
            .filter(|asset| matches!(asset.media_kind, crate::domain::MediaKind::Photo))
            .count();
        let ocr_remaining_photo_count =
            ocr_total_photo_count.saturating_sub(ocr_indexed_asset_count);
        let ocr_ready = ocr_has_successful_job && ocr_indexed_asset_count > 0;
        let latest_scene_job = state
            .jobs
            .iter()
            .find(|job| matches!(job.kind, JobKind::SceneIndex));
        let scene_ready = latest_scene_job
            .map(|job| job.status == JobStatus::Completed)
            .unwrap_or(false)
            && !state.scene_tags.is_empty();
        Ok(SearchIndexStatus {
            filename_ready: true,
            metadata_ready,
            ocr_ready,
            ocr_text_block_count,
            ocr_indexed_asset_count,
            ocr_total_photo_count,
            ocr_remaining_photo_count,
            scene_ready,
            semantic_ready: false,
            updated_at: Utc::now(),
            detail: if ocr_ready && scene_ready {
                format!(
                    "Live filename/date/place/event/OCR/scene search is available. OCR is partial: {ocr_indexed_asset_count} of {ocr_total_photo_count} photo asset(s) have been OCR-processed, with {ocr_text_block_count} searchable text block(s). Scene search has {} local heuristic tag(s). Semantic indexes are still gated.",
                    state.scene_tags.len()
                )
            } else if scene_ready {
                format!(
                    "Live filename/date/place/event/scene search is available with {} local heuristic scene tag(s). OCR and semantic indexes are not ready.",
                    state.scene_tags.len()
                )
            } else if ocr_ready {
                format!(
                    "Live filename/date/place/event/OCR search is available, but OCR is partial: {ocr_indexed_asset_count} of {ocr_total_photo_count} photo asset(s) have been OCR-processed, with {ocr_text_block_count} searchable text block(s). Scenes and semantic indexes are not ready."
                )
            } else if metadata_ready {
                "Live filename/date/place/event search is available. OCR, scenes, and semantic indexes are not ready."
                    .to_string()
            } else {
                "Filename search is available. Metadata is partial; OCR, scenes, and semantic indexes are not ready."
                    .to_string()
            },
        })
    }

    pub async fn jobs(&self) -> Vec<JobRecord> {
        self.state.read().await.jobs.clone()
    }

    pub async fn job(&self, job_id: Uuid) -> Result<JobRecord, ServiceError> {
        self.state
            .read()
            .await
            .jobs
            .iter()
            .find(|job| job.id == job_id)
            .cloned()
            .ok_or_else(|| ServiceError::NotFound(format!("job {job_id}")))
    }

    pub async fn job_logs(&self, job_id: Uuid) -> Result<Vec<JobLog>, ServiceError> {
        let state = self.state.read().await;
        if !state.jobs.iter().any(|job| job.id == job_id) {
            return Err(ServiceError::NotFound(format!("job {job_id}")));
        }
        Ok(state
            .job_logs
            .iter()
            .filter(|log| log.job_id == job_id)
            .cloned()
            .collect())
    }

    pub async fn cancel_job(&self, job_id: Uuid) -> Result<JobRecord, ServiceError> {
        let mut state = self.state.write().await;
        let job = state
            .jobs
            .iter_mut()
            .find(|job| job.id == job_id)
            .ok_or_else(|| ServiceError::NotFound(format!("job {job_id}")))?;
        if matches!(
            job.status,
            JobStatus::Completed | JobStatus::Failed | JobStatus::Canceled
        ) {
            return Err(ServiceError::Invalid(
                "only queued or running jobs can be canceled".to_string(),
            ));
        }

        job.cancel_requested = true;
        job.status = JobStatus::Canceled;
        job.completed_at = Some(Utc::now());
        job.detail = Some("job canceled by local user request".to_string());
        let updated = job.clone();
        state.job_logs.push(job_log(
            job_id,
            "warn",
            "job canceled by local user request",
        ));
        self.persist_locked_state(&state)?;
        Ok(updated)
    }

    pub async fn retry_job(&self, job_id: Uuid) -> Result<JobRecord, ServiceError> {
        let mut state = self.state.write().await;
        let source = state
            .jobs
            .iter()
            .find(|job| job.id == job_id)
            .cloned()
            .ok_or_else(|| ServiceError::NotFound(format!("job {job_id}")))?;
        if matches!(source.status, JobStatus::Queued | JobStatus::Running) {
            return Err(ServiceError::Invalid(
                "running or queued jobs cannot be retried".to_string(),
            ));
        }

        let retry = queued_retry_job(&source);
        state
            .job_logs
            .push(job_log(retry.id, "info", format!("retry of job {job_id}")));
        state.jobs.insert(0, retry.clone());
        self.persist_locked_state(&state)?;
        Ok(retry)
    }

    pub async fn rebuild_search(&self) -> Result<JobRecord, ServiceError> {
        let mut state = self.state.write().await;
        let job = completed_job(
            JobKind::SearchReindex,
            "rebuilt live filename/place/event search; OCR and semantic indexes are not installed yet"
                .to_string(),
        );
        state
            .job_logs
            .push(job_log(job.id, "info", "search rebuild ran offline-only"));
        state.jobs.insert(0, job.clone());
        self.persist_locked_state(&state)?;
        Ok(job)
    }

    pub async fn rebuild_ocr(&self, request: RebuildRequest) -> Result<JobRecord, ServiceError> {
        let encryption = model_registry::encryption_status(&self.config);
        if !encryption.sensitive_indexing_allowed {
            return self
                .record_failed_job(
                    JobKind::OcrIndex,
                    format!("OCR indexing blocked: {}", encryption.warning),
                )
                .await;
        }

        let provider = ocr::TesseractProvider::from_config(&self.config);
        let provider_info = match provider.provider_info() {
            Ok(info) => info,
            Err(err) => {
                return self
                    .record_failed_job(JobKind::OcrIndex, err.to_string())
                    .await;
            }
        };

        let (assets, library_root) = {
            let state = self.state.read().await;
            let library_root = PathBuf::from(effective_library_root(&state, &self.config));
            let requested_asset_ids = request
                .asset_ids
                .as_ref()
                .map(|ids| ids.iter().copied().collect::<BTreeSet<_>>());
            let indexed_asset_ids = state
                .ocr_blocks
                .iter()
                .map(|block| block.asset_id)
                .collect::<BTreeSet<_>>();
            let force = request.force.unwrap_or(false);
            let assets = state
                .assets
                .iter()
                .filter(|asset| matches!(asset.media_kind, crate::domain::MediaKind::Photo))
                .filter(|asset| {
                    requested_asset_ids
                        .as_ref()
                        .map(|ids| ids.contains(&asset.id))
                        .unwrap_or(true)
                })
                .filter(|asset| force || !indexed_asset_ids.contains(&asset.id))
                .take(request.limit.unwrap_or(usize::MAX))
                .cloned()
                .collect::<Vec<_>>();
            (assets, library_root)
        };

        let mut blocks = Vec::new();
        let mut logs = Vec::new();
        let mut skipped = 0_usize;
        let mut no_text = 0_usize;
        let mut failed = 0_usize;

        for asset in &assets {
            let path = asset_file_path(asset, &library_root);
            if !path.exists() {
                skipped += 1;
                logs.push((
                    "warn".to_string(),
                    format!("OCR skipped missing asset {}", path.to_string_lossy()),
                ));
                continue;
            }

            match provider.recognize_asset(asset.id, &path, &provider_info) {
                Ok(Some(block)) => blocks.push(block),
                Ok(None) => {
                    no_text += 1;
                    blocks.push(ocr_no_text_marker(asset.id, &provider_info));
                    logs.push((
                        "info".to_string(),
                        format!("OCR found no text in {}", asset.original_filename),
                    ));
                }
                Err(err) => {
                    failed += 1;
                    logs.push((
                        "warn".to_string(),
                        format!("OCR failed for {}: {err}", asset.original_filename),
                    ));
                }
            }
        }

        let processed = blocks.len();
        let indexed_text_blocks = blocks
            .iter()
            .filter(|block| !block.text.trim().is_empty())
            .count();
        let mut job = completed_job(
            JobKind::OcrIndex,
            format!(
                "OCR processed {processed} asset(s): {indexed_text_blocks} searchable text block(s), confirmed {no_text} no-text asset(s), skipped {skipped}, failed {failed} using {}{}",
                provider_info.version,
                request
                    .limit
                    .map(|limit| format!(" with batch limit {limit}"))
                    .unwrap_or_default()
            ),
        );
        if failed > 0 && processed == 0 && !assets.is_empty() {
            job.status = JobStatus::Failed;
        }

        let mut state = self.state.write().await;
        let scanned_asset_ids = assets.iter().map(|asset| asset.id).collect::<BTreeSet<_>>();
        state
            .ocr_blocks
            .retain(|block| !scanned_asset_ids.contains(&block.asset_id));
        state.ocr_blocks.extend(blocks);
        state.job_logs.push(job_log(
            job.id,
            "info",
            "OCR rebuild ran offline-only with local tesseract",
        ));
        for (level, message) in logs {
            state.job_logs.push(job_log(job.id, level, message));
        }
        state.jobs.insert(0, job.clone());
        self.persist_locked_state(&state)?;
        Ok(job)
    }

    pub async fn ocr_blocks_for_asset(
        &self,
        asset_id: Uuid,
    ) -> Result<Vec<OcrBlock>, ServiceError> {
        let state = self.state.read().await;
        if !state.assets.iter().any(|asset| asset.id == asset_id) {
            return Err(ServiceError::NotFound(format!("asset {asset_id}")));
        }
        Ok(state
            .ocr_blocks
            .iter()
            .filter(|block| block.asset_id == asset_id)
            .cloned()
            .collect())
    }

    pub async fn rebuild_scenes(&self, request: RebuildRequest) -> Result<JobRecord, ServiceError> {
        let encryption = model_registry::encryption_status(&self.config);
        if !encryption.sensitive_indexing_allowed {
            return self
                .record_failed_job(
                    JobKind::SceneIndex,
                    format!("scene indexing blocked: {}", encryption.warning),
                )
                .await;
        }

        let (assets, library_root) = {
            let state = self.state.read().await;
            let library_root = PathBuf::from(effective_library_root(&state, &self.config));
            let requested_asset_ids = request
                .asset_ids
                .as_ref()
                .map(|ids| ids.iter().copied().collect::<BTreeSet<_>>());
            let indexed_asset_ids = state
                .scene_tags
                .iter()
                .map(|tag| tag.asset_id)
                .collect::<BTreeSet<_>>();
            let force = request.force.unwrap_or(false);
            let assets = state
                .assets
                .iter()
                .filter(|asset| matches!(asset.media_kind, crate::domain::MediaKind::Photo))
                .filter(|asset| {
                    requested_asset_ids
                        .as_ref()
                        .map(|ids| ids.contains(&asset.id))
                        .unwrap_or(true)
                })
                .filter(|asset| force || !indexed_asset_ids.contains(&asset.id))
                .take(request.limit.unwrap_or(usize::MAX))
                .cloned()
                .collect::<Vec<_>>();
            (assets, library_root)
        };

        let mut tags = Vec::new();
        let mut logs = Vec::new();
        let mut skipped = 0_usize;
        let mut failed = 0_usize;

        for asset in &assets {
            let path = asset_file_path(asset, &library_root);
            if !path.exists() {
                skipped += 1;
                logs.push((
                    "warn".to_string(),
                    format!(
                        "Scene indexing skipped missing asset {}",
                        path.to_string_lossy()
                    ),
                ));
                continue;
            }

            match ml_sidecar::analyze_scene_tags(&self.config, asset.id, &path) {
                Ok(mut asset_tags) => {
                    if asset_tags.is_empty() {
                        logs.push((
                            "info".to_string(),
                            format!(
                                "Scene indexing found no tags for {}",
                                asset.original_filename
                            ),
                        ));
                    }
                    tags.append(&mut asset_tags);
                }
                Err(err) => {
                    failed += 1;
                    logs.push((
                        "warn".to_string(),
                        format!(
                            "Scene indexing failed for {}: {err}",
                            asset.original_filename
                        ),
                    ));
                }
            }
        }

        let processed_asset_count = tags
            .iter()
            .map(|tag| tag.asset_id)
            .collect::<BTreeSet<_>>()
            .len();
        let tag_count = tags.len();
        let mut job = completed_job(
            JobKind::SceneIndex,
            format!(
                "Scene indexing processed {processed_asset_count} asset(s), wrote {tag_count} local heuristic tag(s), skipped {skipped}, failed {failed}{}",
                request
                    .limit
                    .map(|limit| format!(" with batch limit {limit}"))
                    .unwrap_or_default()
            ),
        );
        if failed > 0 && processed_asset_count == 0 && !assets.is_empty() {
            job.status = JobStatus::Failed;
        }

        let mut state = self.state.write().await;
        let scanned_asset_ids = assets.iter().map(|asset| asset.id).collect::<BTreeSet<_>>();
        state
            .scene_tags
            .retain(|tag| !scanned_asset_ids.contains(&tag.asset_id));
        state.scene_tags.extend(tags);
        state.job_logs.push(job_log(
            job.id,
            "info",
            "Scene rebuild ran offline-only through the local Python sidecar",
        ));
        for (level, message) in logs {
            state.job_logs.push(job_log(job.id, level, message));
        }
        state.jobs.insert(0, job.clone());
        self.persist_locked_state(&state)?;
        Ok(job)
    }

    pub async fn rebuild_semantic(&self) -> Result<JobRecord, ServiceError> {
        let mut state = self.state.write().await;
        let blocker = sensitive_index_blocker(&self.config, &[ModelTask::SemanticEmbedding]);
        let mut job = completed_job(JobKind::SemanticIndex, blocker.clone());
        job.status = JobStatus::Failed;
        state.job_logs.push(job_log(
            job.id,
            "warn",
            format!("semantic rebuild blocked: {blocker}"),
        ));
        state.jobs.insert(0, job.clone());
        self.persist_locked_state(&state)?;
        Ok(job)
    }

    pub async fn index_people(&self) -> Result<JobRecord, ServiceError> {
        let mut state = self.state.write().await;
        let blocker = sensitive_index_blocker(
            &self.config,
            &[ModelTask::FaceDetection, ModelTask::FaceEmbedding],
        );
        let mut job = completed_job(JobKind::FaceDetection, blocker.clone());
        job.status = JobStatus::Failed;
        job.detail = Some(blocker.clone());
        state.job_logs.push(job_log(
            job.id,
            "warn",
            format!("face indexing blocked: {blocker}"),
        ));
        state.jobs.insert(0, job.clone());
        self.persist_locked_state(&state)?;
        Ok(job)
    }

    pub async fn reset_people(&self) -> Result<JobRecord, ServiceError> {
        let mut state = self.state.write().await;
        state.people.clear();
        state.faces.clear();
        for event in &mut state.events {
            event.people_ids.clear();
        }
        let job = completed_job(
            JobKind::FaceClustering,
            "deleted local people clusters and face templates".to_string(),
        );
        state
            .job_logs
            .push(job_log(job.id, "info", "people artifacts reset locally"));
        state.jobs.insert(0, job.clone());
        self.persist_locked_state(&state)?;
        Ok(job)
    }

    pub async fn privacy_status(&self) -> Result<PrivacyStatus, ServiceError> {
        model_registry::privacy_status(&self.config).map_err(model_registry_error)
    }

    pub async fn models(&self) -> Result<Vec<ModelArtifact>, ServiceError> {
        model_registry::list_models(&self.config).map_err(model_registry_error)
    }

    pub async fn model_runtime_status(&self) -> crate::domain::ModelRuntimeStatus {
        ml_sidecar::runtime_status(&self.config)
    }

    pub async fn install_model(
        &self,
        request: ModelInstallRequest,
    ) -> Result<ModelArtifact, ServiceError> {
        model_registry::install_model(&self.config, request).map_err(model_registry_error)
    }

    pub async fn import_local_model(
        &self,
        request: ModelImportRequest,
    ) -> Result<ModelArtifact, ServiceError> {
        model_registry::import_local_model(&self.config, request).map_err(model_registry_error)
    }

    pub async fn verify_model(&self, model_id: &str) -> Result<ModelArtifact, ServiceError> {
        model_registry::verify_model(&self.config, model_id).map_err(model_registry_error)
    }

    pub async fn encryption_status(&self) -> crate::domain::EncryptionStatus {
        model_registry::encryption_status(&self.config)
    }

    pub async fn activate_encryption(
        &self,
        request: EncryptionActivationRequest,
    ) -> Result<EncryptionActivationResult, ServiceError> {
        if !request.confirmed {
            return Err(ServiceError::Invalid(
                "encryption activation requires explicit confirmation".to_string(),
            ));
        }

        let state = self.state.write().await;
        self.persist_locked_state(&state)?;
        let backup_root = request.backup_root.as_deref().map(Path::new);
        security::activate_encryption(&self.config, backup_root).map_err(security_error)
    }

    pub async fn export_backup(
        &self,
        request: BackupExportRequest,
    ) -> Result<BackupExportResult, ServiceError> {
        if request.export_root.trim().is_empty() {
            return Err(ServiceError::Invalid(
                "export_root must not be empty".to_string(),
            ));
        }

        let export_root = PathBuf::from(&request.export_root);
        let database_dir = export_root.join("database");
        let manifest_dir = export_root.join("manifests");
        let library_export_dir = export_root.join("library");
        fs::create_dir_all(&database_dir).map_err(|err| ServiceError::Io(err.to_string()))?;
        fs::create_dir_all(&manifest_dir).map_err(|err| ServiceError::Io(err.to_string()))?;
        fs::create_dir_all(&library_export_dir).map_err(|err| ServiceError::Io(err.to_string()))?;

        let entries = {
            let mut state = self.state.write().await;
            ensure_distributed_defaults(&mut state);
            let changed = refresh_blob_records(&self.config, &mut state);
            if changed {
                self.persist_locked_state(&state)?;
            }
            let library_root = PathBuf::from(effective_library_root(&state, &self.config));
            collect_backup_file_entries(
                &state,
                &library_root,
                request.include_models,
                &self.config,
            )?
        };

        let database_copy = database_dir.join(
            self.storage
                .database_path
                .file_name()
                .unwrap_or_else(|| std::ffi::OsStr::new("gallery.sqlite3")),
        );
        fs::copy(&self.storage.database_path, &database_copy)
            .map_err(|err| ServiceError::Io(err.to_string()))?;

        let mut media_files_copied = 0_usize;
        let mut vault_chunks_copied = 0_usize;
        let mut bytes_copied = fs::metadata(&database_copy)
            .map(|metadata| metadata.len())
            .unwrap_or(0);
        let mut copied_entries = Vec::new();
        for entry in &entries {
            if !entry.source_path.is_file() {
                continue;
            }
            let destination = export_root.join(&entry.backup_relative_path);
            copy_file_creating_parent(&entry.source_path, &destination)?;
            let copied = fs::metadata(&destination)
                .map(|metadata| metadata.len())
                .unwrap_or(0);
            bytes_copied = bytes_copied.saturating_add(copied);
            match entry.kind {
                "vault_chunk" => vault_chunks_copied += 1,
                "model_file" => {}
                _ => media_files_copied += 1,
            }
            copied_entries.push(json!({
                "kind": entry.kind,
                "asset_id": entry.asset_id.map(|id| id.to_string()),
                "source_path": entry.source_path,
                "backup_relative_path": entry.backup_relative_path,
                "restore_relative_path": entry.restore_relative_path,
                "bytes": copied,
            }));
        }

        let verification = self
            .verify_backup(BackupVerifyRequest {
                export_root: Some(request.export_root.clone()),
            })
            .await?;
        let manifest_path = manifest_dir.join("private-gallery-backup-manifest.json");
        let manifest = json!({
            "exported_at": Utc::now(),
            "library_root": verification.library_root,
            "database_path": verification.database_path,
            "database_copied_to": database_copy,
            "database_sha256": verification.database_sha256,
            "assets_checked": verification.assets_checked,
            "missing_asset_paths": verification.missing_asset_paths,
            "vault_chunks_checked": verification.vault_chunks_checked,
            "missing_vault_chunk_paths": verification.missing_vault_chunk_paths,
            "media_files_copied": media_files_copied,
            "vault_chunks_copied": vault_chunks_copied,
            "bytes_copied": bytes_copied,
            "model_files_checked": verification.model_files_checked,
            "missing_model_paths": verification.missing_model_paths,
            "files": copied_entries,
            "include_models": request.include_models,
            "local_only": true,
        });
        fs::write(
            &manifest_path,
            serde_json::to_string_pretty(&manifest)
                .map_err(|err| ServiceError::Storage(err.to_string()))?,
        )
        .map_err(|err| ServiceError::Io(err.to_string()))?;

        Ok(BackupExportResult {
            exported_at: Utc::now(),
            export_root: export_root.to_string_lossy().to_string(),
            manifest_path: manifest_path.to_string_lossy().to_string(),
            database_copied_to: database_copy.to_string_lossy().to_string(),
            database_sha256: verification.database_sha256,
            assets_checked: verification.assets_checked,
            missing_asset_paths: verification.missing_asset_paths.clone(),
            media_files_copied,
            vault_chunks_copied,
            bytes_copied,
            model_files_checked: verification.model_files_checked,
            missing_model_paths: verification.missing_model_paths.clone(),
            ok: verification.ok,
        })
    }

    pub async fn verify_backup(
        &self,
        _request: BackupVerifyRequest,
    ) -> Result<BackupVerification, ServiceError> {
        let mut state = self.state.write().await;
        ensure_distributed_defaults(&mut state);
        let changed = refresh_blob_records(&self.config, &mut state);
        if changed {
            self.persist_locked_state(&state)?;
        }
        let library_root = PathBuf::from(effective_library_root(&state, &self.config));
        let mut missing_asset_paths = Vec::new();
        for asset in &state.assets {
            let path = asset_file_path(asset, &library_root);
            let encrypted_available = state
                .blob_records
                .iter()
                .find(|blob| blob.asset_id == asset.id && blob.tombstoned_at.is_none())
                .map(|blob| encrypted_chunks_available(&state, blob.id, &library_root))
                .unwrap_or(false);
            if !path.exists() && !encrypted_available {
                missing_asset_paths.push(path.to_string_lossy().to_string());
            }
        }

        let mut vault_chunks_checked = 0_usize;
        let mut missing_vault_chunk_paths = Vec::new();
        for chunk in &state.blob_chunks {
            if let Some(local_path) = &chunk.local_path {
                vault_chunks_checked += 1;
                let path = library_root.join(local_path);
                if let Err(err) =
                    vault_store::verify_encrypted_chunk_files(&library_root, &[chunk.clone()])
                {
                    missing_vault_chunk_paths.push(format!("{}: {err}", path.to_string_lossy()));
                }
            }
        }

        let mut model_files_checked = 0_usize;
        let mut missing_model_paths = Vec::new();
        for model in model_registry::list_models(&self.config).map_err(model_registry_error)? {
            if let Some(path) = model.installed_path {
                model_files_checked += 1;
                if !Path::new(&path).exists() {
                    missing_model_paths.push(path);
                }
            }
        }

        let database_sha256 =
            imports::derive_content_hash_from_file(&self.storage.database_path).ok();
        let ok = missing_asset_paths.is_empty()
            && missing_vault_chunk_paths.is_empty()
            && missing_model_paths.is_empty();

        Ok(BackupVerification {
            checked_at: Utc::now(),
            database_path: self.storage.database_path.to_string_lossy().to_string(),
            library_root: library_root.to_string_lossy().to_string(),
            database_sha256,
            assets_checked: state.assets.len(),
            missing_asset_paths,
            vault_chunks_checked,
            missing_vault_chunk_paths,
            model_files_checked,
            missing_model_paths,
            ok,
        })
    }

    pub async fn plan_restore_backup(
        &self,
        request: BackupRestorePlanRequest,
    ) -> Result<BackupRestorePlan, ServiceError> {
        let active_library_root = {
            let state = self.state.read().await;
            PathBuf::from(effective_library_root(&state, &self.config))
        };
        build_restore_plan(
            &request.export_root,
            &request.restore_root,
            &self.config,
            Some(&active_library_root),
        )
    }

    pub async fn run_restore_backup(
        &self,
        request: BackupRestoreRunRequest,
    ) -> Result<BackupRestoreRunResult, ServiceError> {
        if !request.confirmed {
            return Err(ServiceError::Invalid(
                "restore run requires explicit confirmation".to_string(),
            ));
        }
        let active_library_root = {
            let state = self.state.read().await;
            PathBuf::from(effective_library_root(&state, &self.config))
        };
        let plan = build_restore_plan(
            &request.export_root,
            &request.restore_root,
            &self.config,
            Some(&active_library_root),
        )?;
        if !plan.ok {
            return Err(ServiceError::Invalid(format!(
                "restore plan is not safe to run: {}",
                plan.detail
            )));
        }

        let export_root = PathBuf::from(&request.export_root);
        let restore_root = PathBuf::from(&request.restore_root);
        let database_target = PathBuf::from(&plan.database_target_path);
        copy_file_creating_parent(Path::new(&plan.database_source_path), &database_target)?;

        let manifest = read_backup_manifest(&export_root)?;
        let files = manifest
            .get("files")
            .and_then(|value| value.as_array())
            .cloned()
            .unwrap_or_default();
        let mut media_files_copied = 0_usize;
        let mut vault_chunks_copied = 0_usize;
        let mut bytes_copied = fs::metadata(&database_target)
            .map(|metadata| metadata.len())
            .unwrap_or(0);
        for file in files {
            let Some(backup_relative_path) = file
                .get("backup_relative_path")
                .and_then(|value| value.as_str())
            else {
                continue;
            };
            let Some(restore_relative_path) = file
                .get("restore_relative_path")
                .and_then(|value| value.as_str())
            else {
                continue;
            };
            let backup_relative_path =
                manifest_relative_path(backup_relative_path).ok_or_else(|| {
                    ServiceError::Invalid(
                        "backup manifest contains an unsafe source path".to_string(),
                    )
                })?;
            let restore_relative_path =
                manifest_relative_path(restore_relative_path).ok_or_else(|| {
                    ServiceError::Invalid(
                        "backup manifest contains an unsafe restore path".to_string(),
                    )
                })?;
            let source = export_root.join(backup_relative_path);
            let destination = restore_root.join(restore_relative_path);
            copy_file_creating_parent(&source, &destination)?;
            let copied = fs::metadata(&destination)
                .map(|metadata| metadata.len())
                .unwrap_or(0);
            bytes_copied = bytes_copied.saturating_add(copied);
            if file
                .get("kind")
                .and_then(|value| value.as_str())
                .is_some_and(|kind| kind == "vault_chunk")
            {
                vault_chunks_copied += 1;
            } else if !file
                .get("kind")
                .and_then(|value| value.as_str())
                .is_some_and(|kind| kind == "model_file")
            {
                media_files_copied += 1;
            }
        }

        let report_path = restore_root.join("restore-report.json");
        let result = BackupRestoreRunResult {
            restored_at: Utc::now(),
            restore_root: restore_root.to_string_lossy().to_string(),
            database_restored_to: database_target.to_string_lossy().to_string(),
            media_files_copied,
            vault_chunks_copied,
            bytes_copied,
            ok: true,
            detail: "Restore staged without modifying the active library. Start the daemon with this restore root after review.".to_string(),
        };
        fs::write(
            &report_path,
            serde_json::to_string_pretty(&result)
                .map_err(|err| ServiceError::Storage(err.to_string()))?,
        )
        .map_err(|err| ServiceError::Io(err.to_string()))?;

        Ok(result)
    }

    pub async fn diagnostics(&self) -> serde_json::Value {
        let state = self.state.read().await;
        json!({
            "assets": state.assets.len(),
            "albums": state.albums.len(),
            "people": state.people.len(),
            "places": state.places.len(),
            "events": state.events.len(),
            "jobs": state.jobs.len(),
            "watch_folders": state.watch_folders.len(),
            "import_sessions": state.import_sessions.len(),
            "sync_sessions": state.sync_sessions.len(),
            "vaults": state.vaults.len(),
            "devices": state.devices.len(),
            "blob_records": state.blob_records.len(),
            "blob_replicas": state.blob_replicas.len(),
            "sync_transfers": state.sync_transfers.len(),
            "corrections": state.corrections.len(),
            "database_path": self.storage.database_path,
            "library_root": effective_library_root(&state, &self.config),
            "initialized": state.library_settings.is_some(),
            "database_encrypted": model_registry::encryption_status(&self.config).database_encrypted,
        })
    }

    fn persist_locked_state(&self, state: &LibraryState) -> Result<(), ServiceError> {
        storage::save_state(&self.storage, &state.to_persisted())
            .map_err(|err| ServiceError::Storage(err.to_string()))
    }

    fn restore_original_from_local_chunks_locked(
        &self,
        state: &mut LibraryState,
        asset_id: Uuid,
    ) -> Result<bool, ServiceError> {
        let library_root = PathBuf::from(effective_library_root(state, &self.config));
        let asset = state
            .assets
            .iter()
            .find(|asset| asset.id == asset_id)
            .cloned()
            .ok_or_else(|| ServiceError::NotFound(format!("asset {asset_id}")))?;
        let blob = state
            .blob_records
            .iter()
            .find(|blob| blob.asset_id == asset_id && blob.tombstoned_at.is_none())
            .cloned()
            .ok_or_else(|| ServiceError::NotFound(format!("blob for asset {asset_id}")))?;
        let chunks = state
            .blob_chunks
            .iter()
            .filter(|chunk| chunk.blob_id == blob.id)
            .cloned()
            .collect::<Vec<_>>();
        if !vault_store::encrypted_chunk_files_exist(&library_root, &chunks) {
            return Ok(false);
        }
        let destination = asset_file_path(&asset, &library_root);
        if matches!(asset.import_mode, ImportMode::Reference) {
            return Ok(false);
        }
        vault_store::restore_original_from_chunks(
            &self.config,
            &library_root,
            blob.vault_id,
            blob.encryption_key_version,
            &chunks,
            &destination,
        )
        .map_err(vault_store_error)?;
        if let Some(asset) = state.assets.iter_mut().find(|asset| asset.id == asset_id) {
            asset.is_available = true;
        }
        Ok(true)
    }

    async fn record_failed_job(
        &self,
        kind: JobKind,
        detail: String,
    ) -> Result<JobRecord, ServiceError> {
        let mut job = completed_job(kind, detail.clone());
        job.status = JobStatus::Failed;
        let mut state = self.state.write().await;
        state.job_logs.push(job_log(job.id, "warn", detail));
        state.jobs.insert(0, job.clone());
        self.persist_locked_state(&state)?;
        Ok(job)
    }
}

fn normalize_storage_policy(policy: Option<StoragePolicy>) -> StoragePolicy {
    let mut policy = policy.unwrap_or_else(StoragePolicy::protected_min_2);
    match policy.mode {
        StoragePolicyMode::MaxPoolSingleCopy => policy.min_replicas = 1,
        StoragePolicyMode::ProtectedMin2 => policy.min_replicas = 2,
        StoragePolicyMode::Custom => {
            if policy.min_replicas == 0 {
                policy.min_replicas = 1;
            }
        }
    }
    policy
}

fn ensure_distributed_defaults(state: &mut LibraryState) -> bool {
    if state.library_settings.is_none() {
        return false;
    }

    let mut changed = false;
    let now = Utc::now();
    if state.devices.is_empty() {
        let id = Uuid::new_v4();
        let mut storage_profile = DeviceStorageProfile::default();
        storage_profile.device_id = Some(id);
        state.devices.push(DeviceIdentity {
            id,
            display_name: std::env::var("HOSTNAME")
                .or_else(|_| std::env::var("COMPUTERNAME"))
                .unwrap_or_else(|_| "This device".to_string()),
            platform: std::env::consts::OS.to_string(),
            public_key: format!("local-device-key-pending-iroh-{id}"),
            trust_level: DeviceTrustLevel::Trusted,
            storage_profile,
            enrolled_at: now,
            last_seen_at: Some(now),
            revoked_at: None,
        });
        changed = true;
    }

    if state.vaults.is_empty() {
        state.vaults.push(Vault {
            id: Uuid::new_v4(),
            name: "Personal vault".to_string(),
            storage_policy: StoragePolicy::protected_min_2(),
            key_version: 1,
            deletion_grace_days: 30,
            created_at: now,
            updated_at: now,
        });
        changed = true;
    }

    if let (Some(vault_id), Some(device_id)) = (
        state.vaults.first().map(|vault| vault.id),
        local_device_id(state),
    ) {
        let has_admin = state.vault_members.iter().any(|member| {
            member.vault_id == vault_id
                && member.device_id == device_id
                && member.revoked_at.is_none()
        });
        if !has_admin {
            state.vault_members.push(VaultMember {
                id: Uuid::new_v4(),
                vault_id,
                device_id,
                role: DeviceRole::Admin,
                trust_level: DeviceTrustLevel::Trusted,
                display_name: local_device_name(state).unwrap_or_else(|| "This device".to_string()),
                added_at: now,
                revoked_at: None,
            });
            changed = true;
        }
    }

    changed
}

fn refresh_blob_records(config: &AppConfig, state: &mut LibraryState) -> bool {
    let Some(vault) = state.vaults.first().cloned() else {
        return false;
    };
    let Some(local_device) = local_device_id(state) else {
        return false;
    };
    let mut changed = false;
    refresh_asset_availability(state);
    changed |= ensure_vault_key_envelopes(state);
    let library_root = PathBuf::from(effective_library_root(state, config));

    for asset in state.assets.clone() {
        let blob_id = if let Some(blob) = state
            .blob_records
            .iter()
            .find(|blob| blob.asset_id == asset.id && blob.vault_id == vault.id)
        {
            blob.id
        } else {
            let id = Uuid::new_v4();
            state.blob_records.push(BlobRecord {
                id,
                vault_id: vault.id,
                asset_id: asset.id,
                content_hash: asset.content_hash.clone(),
                encrypted_hash: format!("unsealed-v{}:{}", vault.key_version, asset.content_hash),
                bytes: asset.bytes,
                chunk_count: 0,
                encryption_key_version: vault.key_version,
                created_at: Utc::now(),
                tombstoned_at: None,
            });
            changed = true;
            id
        };

        if blob_needs_local_seal(state, blob_id, &library_root) {
            let source_path = asset_file_path(&asset, &library_root);
            if source_path.is_file() {
                if let Ok(sealed) = vault_store::seal_asset(
                    config,
                    &library_root,
                    vault.id,
                    vault.key_version,
                    blob_id,
                    &asset,
                    &source_path,
                ) {
                    if let Some(blob) = state
                        .blob_records
                        .iter_mut()
                        .find(|blob| blob.id == blob_id)
                    {
                        blob.encrypted_hash = sealed.encrypted_hash;
                        blob.chunk_count = sealed.chunks.len() as u32;
                        blob.encryption_key_version = vault.key_version;
                        blob.bytes = asset.bytes;
                        blob.content_hash = asset.content_hash.clone();
                    }
                    state.blob_chunks.retain(|chunk| chunk.blob_id != blob_id);
                    state
                        .blob_chunks
                        .extend(sealed.chunks.into_iter().map(|chunk| BlobChunk {
                            id: Uuid::new_v4(),
                            blob_id,
                            chunk_index: chunk.chunk_index,
                            content_hash: chunk.content_hash,
                            encrypted_hash: chunk.encrypted_hash,
                            bytes: chunk.bytes,
                            encrypted_bytes: chunk.encrypted_bytes,
                            local_path: Some(chunk.local_path),
                            nonce_hex: Some(chunk.nonce_hex),
                            aad: Some(chunk.aad),
                        }));
                    changed = true;
                }
            } else if !state
                .blob_chunks
                .iter()
                .any(|chunk| chunk.blob_id == blob_id)
            {
                let chunk_count = chunk_count_for_bytes(asset.bytes);
                for chunk_index in 0..chunk_count {
                    state.blob_chunks.push(BlobChunk {
                        id: Uuid::new_v4(),
                        blob_id,
                        chunk_index,
                        content_hash: format!("{}:{chunk_index}", asset.content_hash),
                        encrypted_hash: format!(
                            "unsealed-v{}:{}:{chunk_index}",
                            vault.key_version, asset.content_hash
                        ),
                        bytes: chunk_bytes(asset.bytes, chunk_index, chunk_count),
                        encrypted_bytes: 0,
                        local_path: None,
                        nonce_hex: None,
                        aad: None,
                    });
                }
                if let Some(blob) = state
                    .blob_records
                    .iter_mut()
                    .find(|blob| blob.id == blob_id)
                {
                    blob.chunk_count = chunk_count;
                }
                changed = true;
            }
        }

        let encrypted_chunks_available = encrypted_chunks_available(state, blob_id, &library_root);
        let local_available = asset.is_available || encrypted_chunks_available;
        match state
            .blob_replicas
            .iter_mut()
            .find(|replica| replica.blob_id == blob_id && replica.device_id == local_device)
        {
            Some(replica) => {
                let expected_health = if local_available {
                    ReplicaHealth::Healthy
                } else {
                    ReplicaHealth::Missing
                };
                if replica.health != expected_health
                    || replica.bytes_present != if local_available { asset.bytes } else { 0 }
                {
                    replica.health = expected_health;
                    replica.bytes_present = if local_available { asset.bytes } else { 0 };
                    replica.verified_at = local_available.then(Utc::now);
                    changed = true;
                }
            }
            None => {
                state.blob_replicas.push(BlobReplica {
                    id: Uuid::new_v4(),
                    blob_id,
                    device_id: local_device,
                    health: if local_available {
                        ReplicaHealth::Healthy
                    } else {
                        ReplicaHealth::Missing
                    },
                    bytes_present: if local_available { asset.bytes } else { 0 },
                    verified_at: local_available.then(Utc::now),
                    transfer_id: None,
                });
                changed = true;
            }
        }
    }

    changed
}

fn ensure_vault_key_envelopes(state: &mut LibraryState) -> bool {
    let mut changed = false;
    let now = Utc::now();
    for vault in state.vaults.clone() {
        for member in state
            .vault_members
            .iter()
            .filter(|member| {
                member.vault_id == vault.id
                    && member.revoked_at.is_none()
                    && member.trust_level == DeviceTrustLevel::Trusted
            })
            .cloned()
            .collect::<Vec<_>>()
        {
            let exists = state.vault_key_envelopes.iter().any(|envelope| {
                envelope.vault_id == vault.id
                    && envelope.device_id == member.device_id
                    && envelope.key_version == vault.key_version
                    && envelope.revoked_at.is_none()
            });
            if !exists {
                state.vault_key_envelopes.push(VaultKeyEnvelope {
                    id: Uuid::new_v4(),
                    vault_id: vault.id,
                    device_id: member.device_id,
                    key_version: vault.key_version,
                    algorithm: "local-keyring-reference-v1".to_string(),
                    encrypted_vault_key: vault_store::key_reference(vault.id, vault.key_version),
                    created_at: now,
                    revoked_at: None,
                });
                changed = true;
            }
        }
    }
    changed
}

fn blob_needs_local_seal(state: &LibraryState, blob_id: Uuid, library_root: &Path) -> bool {
    let chunks = state
        .blob_chunks
        .iter()
        .filter(|chunk| chunk.blob_id == blob_id)
        .cloned()
        .collect::<Vec<_>>();
    chunks.is_empty() || !vault_store::encrypted_chunk_files_exist(library_root, &chunks)
}

fn encrypted_chunks_available(state: &LibraryState, blob_id: Uuid, library_root: &Path) -> bool {
    let chunks = state
        .blob_chunks
        .iter()
        .filter(|chunk| chunk.blob_id == blob_id)
        .cloned()
        .collect::<Vec<_>>();
    vault_store::encrypted_chunk_files_exist(library_root, &chunks)
}

fn remove_local_encrypted_chunks(
    state: &mut LibraryState,
    blob_id: Uuid,
    library_root: &Path,
) -> Result<(), ServiceError> {
    for chunk in state
        .blob_chunks
        .iter_mut()
        .filter(|chunk| chunk.blob_id == blob_id)
    {
        if let Some(local_path) = chunk.local_path.take() {
            let path = library_root.join(local_path);
            if path.exists() {
                fs::remove_file(path).map_err(|err| ServiceError::Io(err.to_string()))?;
            }
        }
        chunk.nonce_hex = None;
        chunk.aad = None;
        chunk.encrypted_bytes = 0;
    }
    Ok(())
}

fn chunk_count_for_bytes(bytes: u64) -> u32 {
    const CHUNK_BYTES: u64 = 64 * 1024 * 1024;
    (bytes.max(1).div_ceil(CHUNK_BYTES)).min(u32::MAX as u64) as u32
}

fn chunk_bytes(total_bytes: u64, chunk_index: u32, chunk_count: u32) -> u64 {
    const CHUNK_BYTES: u64 = 64 * 1024 * 1024;
    if chunk_index + 1 == chunk_count {
        total_bytes.saturating_sub(CHUNK_BYTES.saturating_mul(chunk_index as u64))
    } else {
        CHUNK_BYTES.min(total_bytes)
    }
}

fn local_device_id(state: &LibraryState) -> Option<Uuid> {
    state
        .devices
        .iter()
        .find(|device| {
            device.revoked_at.is_none()
                && device.trust_level == DeviceTrustLevel::Trusted
                && device
                    .public_key
                    .starts_with("local-device-key-pending-iroh-")
        })
        .or_else(|| {
            state.devices.iter().find(|device| {
                device.revoked_at.is_none() && device.trust_level == DeviceTrustLevel::Trusted
            })
        })
        .map(|device| device.id)
}

fn local_device_name(state: &LibraryState) -> Option<String> {
    let device_id = local_device_id(state)?;
    state
        .devices
        .iter()
        .find(|device| device.id == device_id)
        .map(|device| device.display_name.clone())
}

fn build_device_identity(
    display_name: String,
    platform: String,
    public_key: Option<String>,
    trust_level: Option<DeviceTrustLevel>,
    storage_profile: Option<DeviceStorageProfile>,
) -> Result<DeviceIdentity, ServiceError> {
    if display_name.trim().is_empty() || platform.trim().is_empty() {
        return Err(ServiceError::Invalid(
            "display_name and platform must not be empty".to_string(),
        ));
    }
    let id = Uuid::new_v4();
    let trust_level = trust_level.unwrap_or(DeviceTrustLevel::Trusted);
    let mut storage_profile = storage_profile.unwrap_or_default();
    storage_profile.device_id = Some(id);
    if trust_level == DeviceTrustLevel::StorageOnly {
        storage_profile.accepts_storage = true;
    }
    let now = Utc::now();
    Ok(DeviceIdentity {
        id,
        display_name: display_name.trim().to_string(),
        platform: platform.trim().to_string(),
        public_key: public_key
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| format!("device-key-pending-iroh-{id}")),
        trust_level,
        storage_profile,
        enrolled_at: now,
        last_seen_at: Some(now),
        revoked_at: None,
    })
}

fn default_role_for_trust(trust_level: DeviceTrustLevel) -> DeviceRole {
    match trust_level {
        DeviceTrustLevel::Trusted => DeviceRole::Contributor,
        DeviceTrustLevel::StorageOnly => DeviceRole::StorageOnly,
    }
}

fn add_device_to_state(
    state: &mut LibraryState,
    device: DeviceIdentity,
    role: DeviceRole,
    vault_id: Option<Uuid>,
) -> Result<DeviceIdentity, ServiceError> {
    if state
        .devices
        .iter()
        .any(|existing| existing.public_key == device.public_key)
    {
        return Err(ServiceError::Invalid(
            "device public_key is already enrolled".to_string(),
        ));
    }
    let vault_id = vault_id.or_else(|| state.vaults.first().map(|vault| vault.id));
    let member_trust = device.trust_level;
    let device_id = device.id;
    let display_name = device.display_name.clone();
    state.devices.push(device.clone());

    if let Some(vault_id) = vault_id {
        state.vault_members.push(VaultMember {
            id: Uuid::new_v4(),
            vault_id,
            device_id,
            role,
            trust_level: member_trust,
            display_name,
            added_at: Utc::now(),
            revoked_at: None,
        });
    }

    Ok(device)
}

fn build_vault_status(state: &LibraryState, vault_id: Uuid) -> Result<VaultStatus, ServiceError> {
    let vault = state
        .vaults
        .iter()
        .find(|vault| vault.id == vault_id)
        .cloned()
        .ok_or_else(|| ServiceError::NotFound(format!("vault {vault_id}")))?;
    let members = state
        .vault_members
        .iter()
        .filter(|member| member.vault_id == vault_id)
        .cloned()
        .collect::<Vec<_>>();
    let member_ids = members
        .iter()
        .map(|member| member.device_id)
        .collect::<BTreeSet<_>>();
    let devices = state
        .devices
        .iter()
        .filter(|device| member_ids.contains(&device.id))
        .cloned()
        .collect::<Vec<_>>();
    let blobs = state
        .blob_records
        .iter()
        .filter(|blob| blob.vault_id == vault_id && blob.tombstoned_at.is_none())
        .cloned()
        .collect::<Vec<_>>();
    let mut local_available_assets = 0_usize;
    let mut remote_available_assets = 0_usize;
    let mut under_replicated_blobs = 0_usize;
    let mut missing_blobs = 0_usize;
    for blob in &blobs {
        let availability = build_asset_availability(state, blob.asset_id)?;
        if availability.local_replica {
            local_available_assets += 1;
        }
        if availability.state == AssetAvailabilityState::RemoteAvailable {
            remote_available_assets += 1;
        }
        if availability.state == AssetAvailabilityState::UnderReplicated {
            under_replicated_blobs += 1;
        }
        if availability.state == AssetAvailabilityState::Missing {
            missing_blobs += 1;
        }
    }

    Ok(VaultStatus {
        vault,
        members,
        devices,
        assets_total: blobs.len(),
        blobs_total: blobs.len(),
        local_available_assets,
        remote_available_assets,
        under_replicated_blobs,
        missing_blobs,
        policy_satisfied: under_replicated_blobs == 0 && missing_blobs == 0,
        detail: "Vault control-plane metadata is local; hosted services are limited to discovery and relay fallback.".to_string(),
    })
}

fn build_asset_availability(
    state: &LibraryState,
    asset_id: Uuid,
) -> Result<AssetAvailability, ServiceError> {
    let asset = state
        .assets
        .iter()
        .find(|asset| asset.id == asset_id)
        .ok_or_else(|| ServiceError::NotFound(format!("asset {asset_id}")))?;
    let Some(blob) = state
        .blob_records
        .iter()
        .find(|blob| blob.asset_id == asset_id && blob.tombstoned_at.is_none())
    else {
        return Ok(AssetAvailability {
            asset_id,
            vault_id: None,
            state: AssetAvailabilityState::Missing,
            local_replica: asset.is_available,
            reachable_replica_device_ids: Vec::new(),
            offline_replica_device_ids: Vec::new(),
            replica_count: usize::from(asset.is_available),
            required_replica_count: 1,
            detail: "asset has no vault blob record yet".to_string(),
        });
    };
    let vault = state
        .vaults
        .iter()
        .find(|vault| vault.id == blob.vault_id)
        .ok_or_else(|| ServiceError::NotFound(format!("vault {}", blob.vault_id)))?;
    let local_device = local_device_id(state);
    let pending_local_transfer = state.sync_transfers.iter().any(|transfer| {
        transfer.blob_id == blob.id
            && Some(transfer.to_device_id) == local_device
            && matches!(
                transfer.status,
                SyncTransferStatus::Pending | SyncTransferStatus::Running
            )
    });
    let mut reachable_replica_device_ids = Vec::new();
    let mut offline_replica_device_ids = Vec::new();
    let mut replica_count = 0_usize;
    let mut local_replica = false;
    let mut corrupt = false;

    for replica in state
        .blob_replicas
        .iter()
        .filter(|replica| replica.blob_id == blob.id)
    {
        if replica.health == ReplicaHealth::Corrupt {
            corrupt = true;
        }
        if replica.health == ReplicaHealth::Healthy
            && device_is_active(&state.devices, replica.device_id)
        {
            replica_count += 1;
            if Some(replica.device_id) == local_device {
                local_replica = true;
            } else if device_is_reachable(&state.devices, replica.device_id) {
                reachable_replica_device_ids.push(replica.device_id);
            } else {
                offline_replica_device_ids.push(replica.device_id);
            }
        } else if Some(replica.device_id) != local_device
            && matches!(
                replica.health,
                ReplicaHealth::Offline | ReplicaHealth::Unverified
            )
        {
            offline_replica_device_ids.push(replica.device_id);
        }
    }

    let required_replica_count = vault.storage_policy.min_replicas.max(1) as usize;
    let state_value = if pending_local_transfer {
        AssetAvailabilityState::TransferPending
    } else if corrupt {
        AssetAvailabilityState::Corrupt
    } else if replica_count == 0 {
        if offline_replica_device_ids.is_empty() {
            AssetAvailabilityState::Missing
        } else {
            AssetAvailabilityState::RemoteOffline
        }
    } else if replica_count < required_replica_count {
        AssetAvailabilityState::UnderReplicated
    } else if local_replica {
        AssetAvailabilityState::LocalAvailable
    } else if !reachable_replica_device_ids.is_empty() {
        AssetAvailabilityState::RemoteAvailable
    } else {
        AssetAvailabilityState::RemoteOffline
    };

    Ok(AssetAvailability {
        asset_id,
        vault_id: Some(blob.vault_id),
        state: state_value,
        local_replica,
        reachable_replica_device_ids,
        offline_replica_device_ids,
        replica_count,
        required_replica_count,
        detail: availability_detail(
            state_value,
            local_replica,
            replica_count,
            required_replica_count,
        ),
    })
}

fn availability_detail(
    state: AssetAvailabilityState,
    local_replica: bool,
    replica_count: usize,
    required_replica_count: usize,
) -> String {
    match state {
        AssetAvailabilityState::LocalAvailable => {
            "original is available on this device".to_string()
        }
        AssetAvailabilityState::RemoteAvailable => {
            "original is stored on another reachable device".to_string()
        }
        AssetAvailabilityState::RemoteOffline => {
            "original is stored on another device that is currently offline".to_string()
        }
        AssetAvailabilityState::UnderReplicated if local_replica => format!(
            "original opens locally, but only {replica_count}/{required_replica_count} required replicas are healthy"
        ),
        AssetAvailabilityState::UnderReplicated => {
            format!("only {replica_count}/{required_replica_count} required replicas are healthy")
        }
        AssetAvailabilityState::Missing => {
            "no healthy replica is known for this original".to_string()
        }
        AssetAvailabilityState::Corrupt => {
            "a known replica failed integrity verification".to_string()
        }
        AssetAvailabilityState::TransferPending => {
            "a local pin or replica transfer is pending".to_string()
        }
    }
}

fn build_sync_plan(state: &LibraryState, vault_id: Option<Uuid>) -> Result<SyncPlan, ServiceError> {
    let selected_vaults = if let Some(vault_id) = vault_id {
        vec![
            state
                .vaults
                .iter()
                .find(|vault| vault.id == vault_id)
                .cloned()
                .ok_or_else(|| ServiceError::NotFound(format!("vault {vault_id}")))?,
        ]
    } else {
        state.vaults.clone()
    };

    let mut transfers = Vec::new();
    let mut under_replicated_blob_ids = Vec::new();
    for vault in &selected_vaults {
        let required = vault.storage_policy.min_replicas.max(1) as usize;
        for blob in state
            .blob_records
            .iter()
            .filter(|blob| blob.vault_id == vault.id && blob.tombstoned_at.is_none())
        {
            let healthy_replicas = state
                .blob_replicas
                .iter()
                .filter(|replica| {
                    replica.blob_id == blob.id
                        && replica.health == ReplicaHealth::Healthy
                        && device_is_active(&state.devices, replica.device_id)
                })
                .collect::<Vec<_>>();
            if healthy_replicas.len() >= required {
                continue;
            }
            under_replicated_blob_ids.push(blob.id);
            let Some(source) = healthy_replicas.first().map(|replica| replica.device_id) else {
                continue;
            };
            if let Some(target) = choose_replica_target(state, vault, blob.id) {
                transfers.push(pending_transfer(
                    vault.id,
                    blob.id,
                    Some(source),
                    target,
                    blob.bytes,
                ));
            }
        }
    }

    Ok(SyncPlan {
        generated_at: Utc::now(),
        vault_ids: selected_vaults.iter().map(|vault| vault.id).collect(),
        conflicts: state.sync_conflicts.clone(),
        policy_satisfied: under_replicated_blob_ids.is_empty(),
        detail: if transfers.is_empty() {
            "No runnable transfers are available locally; discovery/P2P transport is not active in this build.".to_string()
        } else {
            format!(
                "{} transfer(s) are ready for the P2P transport; originals stay off hosted services.",
                transfers.len()
            )
        },
        transfers,
        under_replicated_blob_ids,
    })
}

fn choose_replica_target(state: &LibraryState, vault: &Vault, blob_id: Uuid) -> Option<Uuid> {
    let existing = state
        .blob_replicas
        .iter()
        .filter(|replica| replica.blob_id == blob_id && replica.health == ReplicaHealth::Healthy)
        .map(|replica| replica.device_id)
        .collect::<BTreeSet<_>>();
    let excluded = vault
        .storage_policy
        .excluded_device_ids
        .iter()
        .copied()
        .collect::<BTreeSet<_>>();
    let mut candidates = state
        .devices
        .iter()
        .filter(|device| {
            device.revoked_at.is_none()
                && !existing.contains(&device.id)
                && !excluded.contains(&device.id)
                && device.storage_profile.accepts_storage
                && storage_policy_allows_device(&vault.storage_policy, device)
        })
        .map(|device| device.id)
        .collect::<Vec<_>>();
    candidates.sort_by_key(|device_id| {
        vault
            .storage_policy
            .preferred_device_ids
            .iter()
            .position(|preferred| preferred == device_id)
            .unwrap_or(usize::MAX)
    });
    candidates.into_iter().next()
}

fn storage_policy_allows_device(policy: &StoragePolicy, device: &DeviceIdentity) -> bool {
    if !policy.allow_metered_network && device.storage_profile.metered_network {
        return false;
    }
    if policy.pause_on_low_battery && device.storage_profile.low_battery {
        return false;
    }
    if let Some(available) = device.storage_profile.available_bytes {
        available > policy.min_free_space_bytes + device.storage_profile.reserved_bytes
    } else {
        true
    }
}

fn pending_transfer(
    vault_id: Uuid,
    blob_id: Uuid,
    from_device_id: Option<Uuid>,
    to_device_id: Uuid,
    bytes_total: u64,
) -> SyncTransfer {
    let now = Utc::now();
    SyncTransfer {
        id: Uuid::new_v4(),
        vault_id,
        blob_id,
        from_device_id,
        to_device_id,
        status: SyncTransferStatus::Pending,
        bytes_total,
        bytes_completed: 0,
        started_at: None,
        updated_at: now,
        resumable_until: now + chrono::Duration::days(7),
    }
}

fn build_sync_network_status(state: &LibraryState) -> SyncNetworkStatus {
    let pending_transfer_count = state
        .sync_transfers
        .iter()
        .filter(|transfer| transfer.status == SyncTransferStatus::Pending)
        .count();
    let active_transfer_count = state
        .sync_transfers
        .iter()
        .filter(|transfer| transfer.status == SyncTransferStatus::Running)
        .count();
    let completed_transfer_count = state
        .sync_transfers
        .iter()
        .filter(|transfer| transfer.status == SyncTransferStatus::Completed)
        .count();
    let failed_transfer_count = state
        .sync_transfers
        .iter()
        .filter(|transfer| {
            matches!(
                transfer.status,
                SyncTransferStatus::Failed | SyncTransferStatus::Aborted
            )
        })
        .count();
    let local_device_id = local_device_id(state);
    let relay_urls = state
        .relay_endpoints
        .iter()
        .filter(|endpoint| Some(endpoint.device_id) == local_device_id)
        .filter_map(|endpoint| endpoint.relay_url.clone())
        .collect::<Vec<_>>();
    let direct_addresses = state
        .relay_endpoints
        .iter()
        .filter(|endpoint| Some(endpoint.device_id) == local_device_id)
        .flat_map(|endpoint| endpoint.direct_addresses.clone())
        .collect::<Vec<_>>();

    SyncNetworkStatus {
        started: true,
        transport: "encrypted-local-vault-store; iroh-p2p-pending-runtime".to_string(),
        local_device_id,
        local_node_id: local_device_id.map(|id| format!("local-node-{id}")),
        direct_addresses,
        relay_urls,
        active_transfer_count,
        pending_transfer_count,
        completed_transfer_count,
        failed_transfer_count,
        detail: "Encrypted chunk storage and resumable transfer records are active; direct Iroh process networking is not required for local restore and remains the next runtime adapter.".to_string(),
    }
}

fn device_is_active(devices: &[DeviceIdentity], device_id: Uuid) -> bool {
    devices
        .iter()
        .any(|device| device.id == device_id && device.revoked_at.is_none())
}

fn device_is_reachable(devices: &[DeviceIdentity], device_id: Uuid) -> bool {
    devices
        .iter()
        .find(|device| device.id == device_id && device.revoked_at.is_none())
        .and_then(|device| device.last_seen_at)
        .map(|last_seen| Utc::now() - last_seen < chrono::Duration::minutes(15))
        .unwrap_or(false)
}

#[derive(Debug, Clone)]
struct BackupFileEntry {
    kind: &'static str,
    asset_id: Option<Uuid>,
    source_path: PathBuf,
    backup_relative_path: PathBuf,
    restore_relative_path: PathBuf,
}

fn collect_backup_file_entries(
    state: &LibraryState,
    library_root: &Path,
    include_models: bool,
    config: &AppConfig,
) -> Result<Vec<BackupFileEntry>, ServiceError> {
    let mut entries = Vec::new();
    for asset in &state.assets {
        let source_path = asset_file_path(asset, library_root);
        let (kind, relative_path) = match asset.import_mode {
            ImportMode::Reference => {
                let file_name = backup_file_name(&asset.original_filename, &source_path);
                (
                    "reference_original",
                    PathBuf::from("external-originals")
                        .join(asset.id.to_string())
                        .join(file_name),
                )
            }
            ImportMode::Copy | ImportMode::Move => (
                "managed_original",
                PathBuf::from("library").join(stored_relative_path(
                    &asset.relative_original_path,
                    &asset.original_filename,
                )),
            ),
        };
        entries.push(BackupFileEntry {
            kind,
            asset_id: Some(asset.id),
            source_path,
            backup_relative_path: relative_path.clone(),
            restore_relative_path: relative_path,
        });
    }

    for chunk in &state.blob_chunks {
        let Some(local_path) = &chunk.local_path else {
            continue;
        };
        let relative_path = PathBuf::from("library").join(stored_relative_path(
            local_path,
            &format!("{}.pgblob", chunk.id),
        ));
        entries.push(BackupFileEntry {
            kind: "vault_chunk",
            asset_id: None,
            source_path: library_root.join(local_path),
            backup_relative_path: relative_path.clone(),
            restore_relative_path: relative_path,
        });
    }

    if include_models {
        for model in model_registry::list_models(config).map_err(model_registry_error)? {
            let Some(installed_path) = model.installed_path else {
                continue;
            };
            let source_path = PathBuf::from(&installed_path);
            let file_name = backup_file_name(&model.id, &source_path);
            let relative_path = PathBuf::from("models").join(model.id).join(file_name);
            entries.push(BackupFileEntry {
                kind: "model_file",
                asset_id: None,
                source_path,
                backup_relative_path: relative_path.clone(),
                restore_relative_path: relative_path,
            });
        }
    }

    Ok(entries)
}

fn copy_file_creating_parent(source: &Path, destination: &Path) -> Result<u64, ServiceError> {
    let parent = destination
        .parent()
        .ok_or_else(|| ServiceError::Io("destination has no parent".to_string()))?;
    fs::create_dir_all(parent).map_err(|err| ServiceError::Io(err.to_string()))?;
    fs::copy(source, destination).map_err(|err| ServiceError::Io(err.to_string()))
}

fn build_restore_plan(
    export_root: &str,
    restore_root: &str,
    config: &AppConfig,
    active_library_root: Option<&Path>,
) -> Result<BackupRestorePlan, ServiceError> {
    if export_root.trim().is_empty() {
        return Err(ServiceError::Invalid(
            "export_root must not be empty".to_string(),
        ));
    }
    if restore_root.trim().is_empty() {
        return Err(ServiceError::Invalid(
            "restore_root must not be empty".to_string(),
        ));
    }

    let export_root = PathBuf::from(export_root);
    let restore_root = PathBuf::from(restore_root);
    let manifest_path = backup_manifest_path(&export_root);
    let mut missing_paths = Vec::new();
    let mut destination_conflicts = Vec::new();
    let mut media_files_available = 0_usize;
    let mut vault_chunks_available = 0_usize;

    let manifest = match read_backup_manifest(&export_root) {
        Ok(manifest) => Some(manifest),
        Err(err) => {
            missing_paths.push(format!("{manifest_path:?}: {err}"));
            None
        }
    };
    let database_source = find_database_copy(&export_root, config, manifest.as_ref());
    if !database_source.is_file() {
        missing_paths.push(database_source.to_string_lossy().to_string());
    }
    let database_name = database_source
        .file_name()
        .unwrap_or_else(|| std::ffi::OsStr::new(&config.database_filename));
    let database_target = restore_root.join("runtime").join("db").join(database_name);
    if database_target.exists() {
        destination_conflicts.push(database_target.to_string_lossy().to_string());
    }

    if let Some(manifest) = &manifest {
        let files = manifest
            .get("files")
            .and_then(|value| value.as_array())
            .cloned()
            .unwrap_or_default();
        for file in files {
            let Some(backup_relative_path) = file
                .get("backup_relative_path")
                .and_then(|value| value.as_str())
            else {
                missing_paths.push("manifest file entry missing backup_relative_path".to_string());
                continue;
            };
            let Some(backup_relative_path) = manifest_relative_path(backup_relative_path) else {
                missing_paths.push(format!(
                    "manifest file entry has unsafe backup path: {backup_relative_path}"
                ));
                continue;
            };
            let source = export_root.join(backup_relative_path);
            if !source.is_file() {
                missing_paths.push(source.to_string_lossy().to_string());
                continue;
            }

            match file.get("kind").and_then(|value| value.as_str()) {
                Some("vault_chunk") => vault_chunks_available += 1,
                Some("model_file") => {}
                _ => media_files_available += 1,
            }

            let Some(restore_relative_path) = file
                .get("restore_relative_path")
                .and_then(|value| value.as_str())
            else {
                missing_paths.push("manifest file entry missing restore_relative_path".to_string());
                continue;
            };
            let Some(restore_relative_path) = manifest_relative_path(restore_relative_path) else {
                destination_conflicts.push(format!(
                    "manifest file entry has unsafe restore path: {restore_relative_path}"
                ));
                continue;
            };
            let destination = restore_root.join(restore_relative_path);
            if destination.exists() {
                destination_conflicts.push(destination.to_string_lossy().to_string());
            }
        }
    }

    if restore_root.exists()
        && fs::read_dir(&restore_root)
            .map_err(|err| ServiceError::Io(err.to_string()))?
            .next()
            .is_some()
    {
        destination_conflicts.push(format!("{} is not empty", restore_root.to_string_lossy()));
    }
    for protected_path in [&config.runtime_root, &config.library_root] {
        if paths_overlap(&restore_root, protected_path) {
            destination_conflicts.push(format!(
                "{} overlaps active path {}",
                restore_root.to_string_lossy(),
                protected_path.to_string_lossy()
            ));
        }
    }
    if let Some(active_library_root) = active_library_root {
        if paths_overlap(&restore_root, active_library_root) {
            destination_conflicts.push(format!(
                "{} overlaps active library {}",
                restore_root.to_string_lossy(),
                active_library_root.to_string_lossy()
            ));
        }
    }
    destination_conflicts.sort();
    destination_conflicts.dedup();
    missing_paths.sort();
    missing_paths.dedup();

    let ok = missing_paths.is_empty() && destination_conflicts.is_empty();
    let detail = if ok {
        format!(
            "Restore can be staged with {media_files_available} media files and {vault_chunks_available} encrypted vault chunks."
        )
    } else {
        format!(
            "Restore blocked by {} missing paths and {} destination conflicts.",
            missing_paths.len(),
            destination_conflicts.len()
        )
    };

    Ok(BackupRestorePlan {
        checked_at: Utc::now(),
        export_root: export_root.to_string_lossy().to_string(),
        restore_root: restore_root.to_string_lossy().to_string(),
        manifest_path: manifest_path.to_string_lossy().to_string(),
        database_source_path: database_source.to_string_lossy().to_string(),
        database_target_path: database_target.to_string_lossy().to_string(),
        media_files_available,
        vault_chunks_available,
        missing_paths,
        destination_conflicts,
        requires_confirmation: true,
        ok,
        detail,
    })
}

fn read_backup_manifest(export_root: &Path) -> Result<serde_json::Value, ServiceError> {
    let manifest_path = backup_manifest_path(export_root);
    let bytes = fs::read(&manifest_path).map_err(|err| ServiceError::Io(err.to_string()))?;
    serde_json::from_slice(&bytes).map_err(|err| ServiceError::Storage(err.to_string()))
}

fn backup_manifest_path(export_root: &Path) -> PathBuf {
    export_root
        .join("manifests")
        .join("private-gallery-backup-manifest.json")
}

fn find_database_copy(
    export_root: &Path,
    config: &AppConfig,
    manifest: Option<&serde_json::Value>,
) -> PathBuf {
    let configured = export_root.join("database").join(&config.database_filename);
    if configured.is_file() {
        return configured;
    }

    if let Some(relative_path) = manifest
        .and_then(|manifest| manifest.get("database_copied_to"))
        .and_then(|value| value.as_str())
        .and_then(manifest_relative_path)
    {
        let candidate = export_root.join(relative_path);
        if candidate.is_file() {
            return candidate;
        }
    }

    if let Ok(entries) = fs::read_dir(export_root.join("database")) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_file() {
                return path;
            }
        }
    }

    configured
}

fn manifest_relative_path(value: &str) -> Option<PathBuf> {
    let mut path = PathBuf::new();
    for component in Path::new(value).components() {
        match component {
            std::path::Component::Normal(value) => path.push(value),
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir
            | std::path::Component::RootDir
            | std::path::Component::Prefix(_) => return None,
        }
    }
    (!path.as_os_str().is_empty()).then_some(path)
}

fn stored_relative_path(value: &str, fallback_file_name: &str) -> PathBuf {
    let mut path = PathBuf::new();
    for component in Path::new(value).components() {
        match component {
            std::path::Component::Normal(value) => path.push(value),
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir
            | std::path::Component::RootDir
            | std::path::Component::Prefix(_) => {}
        }
    }
    if path.as_os_str().is_empty() {
        path.push(imports::sanitize_filename(fallback_file_name));
    }
    path
}

fn backup_file_name(fallback_name: &str, source_path: &Path) -> String {
    let file_name = source_path
        .file_name()
        .map(|value| value.to_string_lossy().to_string())
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| fallback_name.to_string());
    imports::sanitize_filename(&file_name)
}

fn paths_overlap(left: &Path, right: &Path) -> bool {
    let left = comparable_path(left);
    let right = comparable_path(right);
    left == right || left.starts_with(&right) || right.starts_with(&left)
}

fn comparable_path(path: &Path) -> PathBuf {
    path.canonicalize().unwrap_or_else(|_| absolute_path(path))
}

fn absolute_path(path: &Path) -> PathBuf {
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(path)
    }
}

fn model_registry_error(error: model_registry::ModelRegistryError) -> ServiceError {
    match error {
        model_registry::ModelRegistryError::Invalid(message) => ServiceError::Invalid(message),
        model_registry::ModelRegistryError::Io(message) => ServiceError::Io(message),
    }
}

fn security_error(error: security::SecurityError) -> ServiceError {
    match error {
        security::SecurityError::Invalid(message)
        | security::SecurityError::Database(message)
        | security::SecurityError::KeyStorage(message) => ServiceError::Invalid(message),
        security::SecurityError::Io(message) => ServiceError::Io(message),
    }
}

fn vault_store_error(error: vault_store::VaultStoreError) -> ServiceError {
    match error {
        vault_store::VaultStoreError::Invalid(message)
        | vault_store::VaultStoreError::Crypto(message)
        | vault_store::VaultStoreError::KeyStorage(message) => ServiceError::Invalid(message),
        vault_store::VaultStoreError::Io(message) => ServiceError::Io(message),
    }
}

fn sensitive_index_blocker(config: &AppConfig, required_tasks: &[ModelTask]) -> String {
    let encryption = model_registry::encryption_status(config);
    if !encryption.sensitive_indexing_allowed {
        return encryption.warning;
    }

    let models = model_registry::list_models(config).unwrap_or_default();
    let missing_tasks = required_tasks
        .iter()
        .filter(|task| {
            !models.iter().any(|model| {
                model.task == **task
                    && model.install_status == crate::domain::ModelInstallStatus::Installed
                    && model.approved_for_personal_family_use
            })
        })
        .map(|task| format!("{task:?}"))
        .collect::<Vec<_>>();

    if missing_tasks.is_empty() {
        "local model files are installed, but the inference provider implementation is not enabled in this beta slice"
            .to_string()
    } else {
        format!(
            "encrypted storage is active, but approved local model(s) are missing for: {}",
            missing_tasks.join(", ")
        )
    }
}

fn validate_asset_ids(
    assets: &[crate::domain::Asset],
    requested_asset_ids: &[Uuid],
) -> Result<Vec<Uuid>, ServiceError> {
    let known_asset_ids = assets.iter().map(|asset| asset.id).collect::<BTreeSet<_>>();
    let mut asset_ids = requested_asset_ids
        .iter()
        .copied()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect::<Vec<_>>();
    for asset_id in &asset_ids {
        if !known_asset_ids.contains(asset_id) {
            return Err(ServiceError::NotFound(format!("asset {asset_id}")));
        }
    }
    asset_ids.sort();
    Ok(asset_ids)
}

fn assets_by_ids(
    assets: &[Asset],
    requested_asset_ids: &[Uuid],
) -> Result<Vec<Asset>, ServiceError> {
    let requested = requested_asset_ids.iter().copied().collect::<BTreeSet<_>>();
    Ok(assets
        .iter()
        .filter(|asset| requested.contains(&asset.id))
        .cloned()
        .collect())
}

fn sorted_assets(mut assets: Vec<Asset>) -> Vec<Asset> {
    assets.sort_by(|left, right| {
        right
            .captured_at
            .cmp(&left.captured_at)
            .then_with(|| right.id.cmp(&left.id))
    });
    assets
}

fn refresh_event_people_from_people(events: &mut [EventCluster], people: &[PersonCluster]) {
    for event in events {
        let event_asset_ids = event.asset_ids.iter().copied().collect::<BTreeSet<_>>();
        let mut people_ids = people
            .iter()
            .filter(|person| !person.hidden)
            .filter(|person| {
                person
                    .asset_ids
                    .iter()
                    .any(|asset_id| event_asset_ids.contains(asset_id))
            })
            .map(|person| person.id)
            .collect::<Vec<_>>();
        people_ids.sort();
        people_ids.dedup();
        event.people_ids = people_ids;
    }
}

fn default_import_mode(state: &LibraryState) -> ImportMode {
    state
        .library_settings
        .as_ref()
        .map(|settings| settings.default_import_mode)
        .unwrap_or(ImportMode::Move)
}

fn effective_library_root(state: &LibraryState, config: &AppConfig) -> String {
    state
        .library_settings
        .as_ref()
        .map(|settings| settings.library_root.clone())
        .unwrap_or_else(|| config.library_root.to_string_lossy().to_string())
}

fn refresh_import_session_summaries(state: &mut LibraryState, config: &AppConfig) {
    let library_root = PathBuf::from(effective_library_root(state, config));
    for session in &mut state.import_sessions {
        imports::refresh_import_session_summary(session, Some(&library_root));
    }
}

fn completed_job(kind: JobKind, detail: String) -> JobRecord {
    JobRecord {
        id: Uuid::new_v4(),
        kind,
        status: JobStatus::Completed,
        progress: 100,
        queued_at: Utc::now(),
        started_at: Some(Utc::now()),
        completed_at: Some(Utc::now()),
        detail: Some(detail),
        cancel_requested: false,
        retry_of_job_id: None,
        attempt: 1,
    }
}

fn queued_retry_job(source: &JobRecord) -> JobRecord {
    JobRecord {
        id: Uuid::new_v4(),
        kind: source.kind.clone(),
        status: JobStatus::Queued,
        progress: 0,
        queued_at: Utc::now(),
        started_at: None,
        completed_at: None,
        detail: Some(format!("retry queued for job {}", source.id)),
        cancel_requested: false,
        retry_of_job_id: Some(source.id),
        attempt: source.attempt.saturating_add(1),
    }
}

fn job_log(job_id: Uuid, level: impl Into<String>, message: impl Into<String>) -> JobLog {
    JobLog {
        id: Uuid::new_v4(),
        job_id,
        level: level.into(),
        message: message.into(),
        created_at: Utc::now(),
    }
}

fn asset_file_path(asset: &crate::domain::Asset, library_root: &Path) -> PathBuf {
    match asset.import_mode {
        ImportMode::Reference => PathBuf::from(&asset.source_path),
        ImportMode::Copy | ImportMode::Move => library_root.join(&asset.relative_original_path),
    }
}

fn upsert_watch_folder(state: &mut LibraryState, path: &str, import_mode: ImportMode) {
    if state.watch_folders.iter().any(|folder| folder.path == path) {
        return;
    }
    state.watch_folders.push(WatchFolder {
        id: Uuid::new_v4(),
        path: path.to_string(),
        recursive: true,
        import_mode,
        created_at: Utc::now(),
        last_scanned_at: Some(Utc::now()),
    });
}

fn attach_extracted_metadata(
    asset: &mut crate::domain::Asset,
    candidate: &crate::domain::ImportCandidate,
    source_path: &Path,
) {
    let extracted = metadata::extract_import_metadata(
        source_path,
        &candidate.sidecar_paths,
        candidate.captured_at.unwrap_or(asset.captured_at),
    );
    asset.captured_at = extracted.captured_at;
    if asset.place_hint.is_none() {
        asset.place_hint = metadata::coarse_place_label(&extracted);
    }
    asset.metadata = Some(extracted.into_asset_metadata(asset.id));
}

fn safely_move_candidate(
    candidate: &mut crate::domain::ImportCandidate,
    asset: &mut crate::domain::Asset,
    source_path: &Path,
    library_root_path: &Path,
) -> Result<usize, ServiceError> {
    if !source_path.exists() {
        return Err(ServiceError::Io("source file is missing".to_string()));
    }

    let source_hash = imports::derive_content_hash_from_file(source_path)
        .map_err(|err| ServiceError::Io(err.to_string()))?;
    if source_hash != candidate.content_hash {
        return Err(ServiceError::Invalid(
            "source hash changed since scan".to_string(),
        ));
    }

    let destination = library_root_path.join(&asset.relative_original_path);
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent).map_err(|err| ServiceError::Io(err.to_string()))?;
    }

    if destination.exists() {
        let destination_hash = imports::derive_content_hash_from_file(&destination)
            .map_err(|err| ServiceError::Io(err.to_string()))?;
        if destination_hash != source_hash {
            return Err(ServiceError::Invalid(
                "destination exists with different content".to_string(),
            ));
        }
        fs::remove_file(source_path).map_err(|err| ServiceError::Io(err.to_string()))?;
    } else {
        let temp_destination = destination.with_extension(format!(
            "{}.moving",
            destination
                .extension()
                .map(|value| value.to_string_lossy())
                .unwrap_or_default()
        ));
        if temp_destination.exists() {
            fs::remove_file(&temp_destination).map_err(|err| ServiceError::Io(err.to_string()))?;
        }
        fs::rename(source_path, &temp_destination)
            .or_else(|_| {
                fs::copy(source_path, &temp_destination)?;
                fs::remove_file(source_path)
            })
            .map_err(|err| ServiceError::Io(err.to_string()))?;

        let moved_hash = imports::derive_content_hash_from_file(&temp_destination)
            .map_err(|err| ServiceError::Io(err.to_string()))?;
        if moved_hash != source_hash {
            let _ = fs::rename(&temp_destination, source_path);
            return Err(ServiceError::Invalid(
                "moved file failed hash verification".to_string(),
            ));
        }
        if let Err(err) = fs::rename(&temp_destination, &destination) {
            let _ = fs::rename(&temp_destination, source_path);
            return Err(ServiceError::Io(err.to_string()));
        }
    }

    let mut moved_sidecars = 0_usize;
    let destination_parent = destination
        .parent()
        .ok_or_else(|| ServiceError::Io("destination has no parent".to_string()))?;
    for sidecar in &candidate.sidecar_paths {
        let sidecar_path = PathBuf::from(sidecar);
        if !sidecar_path.exists() {
            continue;
        }
        let sidecar_filename = sidecar_path
            .file_name()
            .map(|value| value.to_string_lossy().to_string())
            .unwrap_or_else(|| format!("{}.json", asset.original_filename));
        let sidecar_destination =
            destination_parent.join(imports::sanitize_filename(&sidecar_filename));
        if sidecar_destination.exists() {
            continue;
        }
        fs::rename(&sidecar_path, &sidecar_destination)
            .or_else(|_| {
                fs::copy(&sidecar_path, &sidecar_destination)?;
                fs::remove_file(&sidecar_path)
            })
            .map_err(|err| ServiceError::Io(err.to_string()))?;
        moved_sidecars += 1;
    }

    asset.source_path = destination.to_string_lossy().to_string();
    asset.is_available = destination.exists();
    candidate.destination_path = Some(destination.to_string_lossy().to_string());
    candidate.safety_status = "moved_verified".to_string();
    Ok(moved_sidecars)
}

fn refresh_derived_views(state: &mut LibraryState) {
    refresh_asset_availability(state);
    state.places = derive_places(&state.assets, &state.places);
    state.events = derive_events(&state.assets, &state.places, &state.events);
}

fn refresh_missing_derived_views(state: &mut LibraryState) {
    if state.assets.is_empty() {
        return;
    }
    if state.places.is_empty() || state.events.is_empty() {
        refresh_derived_views(state);
    }
}

fn compact_job_history(state: &mut LibraryState) -> bool {
    const MAX_COMPLETED_IMPORT_JOBS: usize = 200;

    let original_jobs = state.jobs.len();
    let original_logs = state.job_logs.len();
    let mut completed_import_jobs_seen = 0_usize;

    state.jobs.retain(|job| {
        let compactable = job.kind == JobKind::Import
            && job.status == JobStatus::Completed
            && job.retry_of_job_id.is_none()
            && !job.cancel_requested;
        if !compactable {
            return true;
        }
        completed_import_jobs_seen += 1;
        completed_import_jobs_seen <= MAX_COMPLETED_IMPORT_JOBS
    });

    let job_ids = state.jobs.iter().map(|job| job.id).collect::<BTreeSet<_>>();
    state.job_logs.retain(|log| job_ids.contains(&log.job_id));

    original_jobs != state.jobs.len() || original_logs != state.job_logs.len()
}

fn refresh_asset_availability(state: &mut LibraryState) {
    let root = state
        .library_settings
        .as_ref()
        .map(|settings| PathBuf::from(&settings.library_root))
        .unwrap_or_else(|| PathBuf::from("library"));
    for asset in &mut state.assets {
        asset.is_available = match asset.import_mode {
            ImportMode::Copy | ImportMode::Move => {
                root.join(&asset.relative_original_path).exists()
            }
            ImportMode::Reference => Path::new(&asset.source_path).exists(),
        };
    }
}

fn derive_places(assets: &[crate::domain::Asset], existing: &[PlaceCluster]) -> Vec<PlaceCluster> {
    let existing_ids = existing
        .iter()
        .map(|place| (place.label.clone(), place.id))
        .collect::<HashMap<_, _>>();
    let mut grouped = BTreeMap::<String, Vec<Uuid>>::new();
    let mut coords = HashMap::<String, Vec<(f64, f64)>>::new();
    for asset in assets {
        let place_hint = asset.place_hint.clone().or_else(|| {
            asset
                .metadata
                .as_ref()
                .and_then(metadata::coarse_place_label_for_asset)
        });
        if let Some(place_hint) = place_hint {
            grouped
                .entry(place_hint.trim().to_string())
                .or_default()
                .push(asset.id);
            if let Some(geo) = asset.metadata.as_ref().and_then(|value| value.geo.as_ref()) {
                coords
                    .entry(place_hint.trim().to_string())
                    .or_default()
                    .push((geo.latitude, geo.longitude));
            }
        }
    }

    grouped
        .into_iter()
        .filter(|(label, _)| !label.is_empty())
        .map(|(label, asset_ids)| {
            let centroid = coords.get(&label).and_then(|values| {
                if values.is_empty() {
                    return None;
                }
                let (lat_sum, lon_sum) = values
                    .iter()
                    .fold((0.0, 0.0), |acc, value| (acc.0 + value.0, acc.1 + value.1));
                Some((lat_sum / values.len() as f64, lon_sum / values.len() as f64))
            });
            PlaceCluster {
                id: existing_ids
                    .get(&label)
                    .copied()
                    .unwrap_or_else(Uuid::new_v4),
                label,
                country_code: None,
                region: None,
                asset_ids,
                centroid_latitude: centroid.map(|value| value.0),
                centroid_longitude: centroid.map(|value| value.1),
                derived: crate::domain::ModelProvenance::local("local-place-cluster", "v1"),
            }
        })
        .collect()
}

fn derive_events(
    assets: &[crate::domain::Asset],
    places: &[PlaceCluster],
    existing: &[EventCluster],
) -> Vec<EventCluster> {
    let place_ids_by_label = places
        .iter()
        .map(|place| (place.label.clone(), place.id))
        .collect::<HashMap<_, _>>();
    let mut events = events::cluster_assets(assets);
    for event in &mut events {
        let first_place = event.asset_ids.iter().find_map(|asset_id| {
            assets
                .iter()
                .find(|asset| asset.id == *asset_id)
                .and_then(|asset| asset.place_hint.clone())
        });
        if let Some(place_hint) = first_place {
            event.place_id = place_ids_by_label.get(&place_hint).copied();
        }
        if let Some(existing_event) = existing
            .iter()
            .find(|candidate| same_asset_set(&candidate.asset_ids, &event.asset_ids))
        {
            event.id = existing_event.id;
            if existing_event.title_source == crate::domain::EventTitleSource::User {
                event.title = existing_event.title.clone();
                event.title_source = existing_event.title_source.clone();
            }
        }
    }
    events
}

fn same_asset_set(left: &[Uuid], right: &[Uuid]) -> bool {
    let left = left.iter().copied().collect::<BTreeSet<_>>();
    let right = right.iter().copied().collect::<BTreeSet<_>>();
    left == right
}

fn ocr_no_text_marker(asset_id: Uuid, info: &ocr::OcrProviderInfo) -> OcrBlock {
    OcrBlock {
        id: Uuid::new_v4(),
        asset_id,
        text: String::new(),
        bounding_box: None,
        derived: crate::domain::ModelProvenance {
            model_name: "tesseract-cli".to_string(),
            model_version: info.version.clone(),
            model_hash: Some(info.hash.clone()),
            created_at: Utc::now(),
            rebuildable: true,
        },
    }
}

#[cfg(test)]
mod tests {
    use std::{fs, path::PathBuf};

    use chrono::{Datelike, Utc};

    use crate::{
        config::AppConfig,
        domain::{
            AssetAvailabilityState, CorrectDateRequest, CorrectPlaceRequest, CreateAlbumRequest,
            CreateDeviceRequest, CreateManualPersonRequest, DeviceRole, DeviceTrustLevel,
            EncryptionActivationRequest, ImportAssetRequest, ImportMode, ImportSourceKind,
            MediaKind, MetadataSource, ModelImportRequest, ModelInstallRequest, NetworkPolicy,
            RebuildRequest, RenameAlbumRequest, RunSyncRequest, ScanImportSourceRequest,
            SearchQuery, UpdateAlbumAssetsRequest, UpdateAssetFlagsRequest,
            UpdateAssetsFlagsRequest, UpdateLibrarySettingsRequest, UpdatePersonAssetsRequest,
        },
        imports,
    };

    use super::GalleryService;

    fn temp_root(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "private-gallery-service-{name}-{}",
            Utc::now().timestamp_nanos_opt().unwrap_or_default()
        ));
        fs::create_dir_all(&root).expect("create temp root");
        root
    }

    fn write_green_ppm_with_jpg_name(path: &std::path::Path) {
        let mut bytes = b"P6\n4 4\n255\n".to_vec();
        for _ in 0..16 {
            bytes.extend_from_slice(&[20, 210, 30]);
        }
        fs::write(path, bytes).expect("write PPM fixture");
    }

    fn fake_tesseract(root: &std::path::Path, text: &str) -> PathBuf {
        let path = root.join("fake-tesseract.sh");
        fs::write(
            &path,
            format!(
                "#!/usr/bin/env sh\nif [ \"$1\" = \"--version\" ]; then echo 'tesseract 5.5.2-test'; exit 0; fi\necho '{}'\n",
                text.replace('\'', "")
            ),
        )
        .expect("write fake tesseract");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut permissions = fs::metadata(&path).expect("metadata").permissions();
            permissions.set_mode(0o755);
            fs::set_permissions(&path, permissions).expect("chmod fake tesseract");
        }
        path
    }

    async fn count_ocr_blocks(service: &GalleryService) -> usize {
        let assets = service
            .timeline()
            .await
            .buckets
            .into_iter()
            .flat_map(|bucket| bucket.assets)
            .collect::<Vec<_>>();
        let mut count = 0;
        for asset in assets {
            count += service
                .ocr_blocks_for_asset(asset.id)
                .await
                .expect("OCR blocks")
                .len();
        }
        count
    }

    fn find_pgblob(root: &std::path::Path) -> Option<PathBuf> {
        for entry in fs::read_dir(root).ok()?.filter_map(Result::ok) {
            let path = entry.path();
            if path.is_dir() {
                if let Some(found) = find_pgblob(&path) {
                    return Some(found);
                }
            } else if path
                .extension()
                .is_some_and(|extension| extension == "pgblob")
            {
                return Some(path);
            }
        }
        None
    }

    #[tokio::test]
    async fn initializes_library_settings() {
        let runtime_root = temp_root("settings");
        let service = GalleryService::new(AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        })
        .expect("service");

        let settings = service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: runtime_root.join("library").to_string_lossy().to_string(),
                default_import_mode: ImportMode::Copy,
            })
            .await
            .expect("settings should save");

        assert_eq!(settings.default_import_mode, ImportMode::Copy);
    }

    #[tokio::test]
    async fn distributed_vault_defaults_track_imports_and_plan_replication() {
        let runtime_root = temp_root("distributed-vault");
        let library_root = runtime_root.join("library");
        let source = runtime_root.join("photo.jpg");
        fs::write(&source, b"family-photo").expect("write source");
        let config = AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        };
        let service = GalleryService::new(config.clone()).expect("service");
        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Reference,
            })
            .await
            .expect("settings");

        assert_eq!(service.vaults().await.len(), 1);
        assert_eq!(service.devices().await.len(), 1);

        let imported = service
            .import_asset(ImportAssetRequest {
                source_path: source.to_string_lossy().to_string(),
                original_filename: "photo.jpg".to_string(),
                media_kind: MediaKind::Photo,
                mime_type: "image/jpeg".to_string(),
                bytes: 12,
                content_hash: None,
                captured_at: None,
                place_hint: None,
                import_mode: Some(ImportMode::Reference),
            })
            .await
            .expect("import");
        let storage_device = service
            .create_device(CreateDeviceRequest {
                display_name: "NAS".to_string(),
                platform: "linux".to_string(),
                public_key: Some("nas-key".to_string()),
                trust_level: Some(DeviceTrustLevel::StorageOnly),
                role: Some(DeviceRole::StorageOnly),
                storage_profile: None,
            })
            .await
            .expect("device");

        let availability = service
            .asset_availability(imported.asset.id)
            .await
            .expect("availability");
        assert_eq!(availability.state, AssetAvailabilityState::UnderReplicated);
        assert!(availability.local_replica);
        assert_eq!(availability.replica_count, 1);
        assert_eq!(availability.required_replica_count, 2);

        let plan = service.sync_plan(None).await.expect("sync plan");
        assert!(!plan.policy_satisfied);
        assert_eq!(plan.under_replicated_blob_ids.len(), 1);
        assert_eq!(plan.transfers.len(), 1);
        assert_eq!(plan.transfers[0].to_device_id, storage_device.id);

        service
            .run_sync(RunSyncRequest {
                vault_id: None,
                dry_run: false,
            })
            .await
            .expect("run sync");
        assert_eq!(service.sync_transfers().await.len(), 1);

        let restarted = GalleryService::new(config).expect("restart");
        assert_eq!(restarted.vaults().await.len(), 1);
        assert_eq!(restarted.devices().await.len(), 2);
        assert_eq!(restarted.sync_transfers().await.len(), 1);
    }

    #[tokio::test]
    async fn copy_imports_are_sealed_into_encrypted_vault_chunks() {
        let runtime_root = temp_root("encrypted-vault-chunks");
        let library_root = runtime_root.join("library");
        let source = runtime_root.join("photo.jpg");
        let original_bytes = b"family-photo-private-original";
        fs::write(&source, original_bytes).expect("write source");
        let service = GalleryService::new(AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        })
        .expect("service");
        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Copy,
            })
            .await
            .expect("settings");

        let imported = service
            .import_asset(ImportAssetRequest {
                source_path: source.to_string_lossy().to_string(),
                original_filename: "photo.jpg".to_string(),
                media_kind: MediaKind::Photo,
                mime_type: "image/jpeg".to_string(),
                bytes: original_bytes.len() as u64,
                content_hash: None,
                captured_at: None,
                place_hint: None,
                import_mode: Some(ImportMode::Copy),
            })
            .await
            .expect("import");

        let vault_store_root = library_root.join("vaults");
        assert!(vault_store_root.exists());
        let original_path = library_root.join(&imported.asset.relative_original_path);
        fs::remove_file(&original_path).expect("remove plaintext original");

        let (mime_type, restored_bytes) = service
            .asset_original_bytes(imported.asset.id)
            .await
            .expect("decrypt original");
        assert_eq!(mime_type, "image/jpeg");
        assert_eq!(restored_bytes, original_bytes);
        let encrypted_file = find_pgblob(&vault_store_root).expect("sealed chunk");
        let encrypted_bytes = fs::read(encrypted_file).expect("read sealed chunk");
        assert_ne!(encrypted_bytes, original_bytes);
        assert!(
            !encrypted_bytes
                .windows(original_bytes.len())
                .any(|window| window == original_bytes)
        );
    }

    #[tokio::test]
    async fn backup_export_restore_preserves_encrypted_chunks_without_plaintext_original() {
        let runtime_root = temp_root("chunk-backup");
        let restore_root = temp_root("chunk-restore");
        let library_root = runtime_root.join("library");
        let source = runtime_root.join("photo.jpg");
        let original_bytes = b"family-photo-private-original";
        fs::write(&source, original_bytes).expect("write source");
        let config = AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        };
        let service = GalleryService::new(config).expect("service");
        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Copy,
            })
            .await
            .expect("settings");

        let imported = service
            .import_asset(ImportAssetRequest {
                source_path: source.to_string_lossy().to_string(),
                original_filename: "photo.jpg".to_string(),
                media_kind: MediaKind::Photo,
                mime_type: "image/jpeg".to_string(),
                bytes: original_bytes.len() as u64,
                content_hash: None,
                captured_at: None,
                place_hint: None,
                import_mode: Some(ImportMode::Copy),
            })
            .await
            .expect("import");
        let original_path = library_root.join(&imported.asset.relative_original_path);
        fs::remove_file(&original_path).expect("remove plaintext original");

        let verification = service
            .verify_backup(crate::domain::BackupVerifyRequest { export_root: None })
            .await
            .expect("verify backup");
        assert!(verification.ok);
        assert_eq!(verification.missing_asset_paths, Vec::<String>::new());
        assert!(verification.vault_chunks_checked >= 1);

        let export_root = runtime_root.join("backup-export");
        let export = service
            .export_backup(crate::domain::BackupExportRequest {
                export_root: export_root.to_string_lossy().to_string(),
                include_models: false,
            })
            .await
            .expect("export backup");
        assert!(export.ok);
        assert_eq!(export.media_files_copied, 0);
        assert!(export.vault_chunks_copied >= 1);
        assert!(find_pgblob(&export_root.join("library")).is_some());

        let blocked_plan = service
            .plan_restore_backup(crate::domain::BackupRestorePlanRequest {
                export_root: export_root.to_string_lossy().to_string(),
                restore_root: library_root.join("restore").to_string_lossy().to_string(),
            })
            .await
            .expect("blocked restore plan");
        assert!(!blocked_plan.ok);
        assert!(
            blocked_plan
                .destination_conflicts
                .iter()
                .any(|conflict| conflict.contains("active library"))
        );

        let plan = service
            .plan_restore_backup(crate::domain::BackupRestorePlanRequest {
                export_root: export_root.to_string_lossy().to_string(),
                restore_root: restore_root.to_string_lossy().to_string(),
            })
            .await
            .expect("restore plan");
        assert!(plan.ok, "{}", plan.detail);
        assert_eq!(plan.media_files_available, 0);
        assert!(plan.vault_chunks_available >= 1);

        let restored = service
            .run_restore_backup(crate::domain::BackupRestoreRunRequest {
                export_root: export_root.to_string_lossy().to_string(),
                restore_root: restore_root.to_string_lossy().to_string(),
                confirmed: true,
            })
            .await
            .expect("restore run");
        assert!(restored.ok);
        assert_eq!(restored.media_files_copied, 0);
        assert!(restored.vault_chunks_copied >= 1);
        assert!(PathBuf::from(restored.database_restored_to).exists());
        assert!(find_pgblob(&restore_root.join("library")).is_some());
    }

    #[tokio::test]
    async fn decrypting_chunks_requires_existing_vault_key() {
        let runtime_root = temp_root("missing-vault-key");
        let library_root = runtime_root.join("library");
        let source = runtime_root.join("photo.jpg");
        fs::write(&source, b"family-photo-private-original").expect("write source");
        let service = GalleryService::new(AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        })
        .expect("service");
        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Copy,
            })
            .await
            .expect("settings");

        let imported = service
            .import_asset(ImportAssetRequest {
                source_path: source.to_string_lossy().to_string(),
                original_filename: "photo.jpg".to_string(),
                media_kind: MediaKind::Photo,
                mime_type: "image/jpeg".to_string(),
                bytes: 29,
                content_hash: None,
                captured_at: None,
                place_hint: None,
                import_mode: Some(ImportMode::Copy),
            })
            .await
            .expect("import");
        let original_path = library_root.join(&imported.asset.relative_original_path);
        fs::remove_file(&original_path).expect("remove plaintext original");
        let vault = service.vaults().await.into_iter().next().expect("vault");
        let key_path = runtime_root
            .join("security")
            .join("vault-keys")
            .join(format!(
                "{}.key",
                crate::vault_store::key_reference(vault.id, vault.key_version)
            ));
        assert!(key_path.exists());
        fs::remove_file(&key_path).expect("remove vault key");

        let result = service.asset_original_bytes(imported.asset.id).await;
        assert!(result.is_err());
        assert!(!key_path.exists());
    }

    #[tokio::test]
    async fn backup_verification_reports_corrupt_vault_chunk() {
        let runtime_root = temp_root("corrupt-vault-chunk");
        let library_root = runtime_root.join("library");
        let source = runtime_root.join("photo.jpg");
        fs::write(&source, b"family-photo-private-original").expect("write source");
        let service = GalleryService::new(AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        })
        .expect("service");
        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Copy,
            })
            .await
            .expect("settings");

        let imported = service
            .import_asset(ImportAssetRequest {
                source_path: source.to_string_lossy().to_string(),
                original_filename: "photo.jpg".to_string(),
                media_kind: MediaKind::Photo,
                mime_type: "image/jpeg".to_string(),
                bytes: 29,
                content_hash: None,
                captured_at: None,
                place_hint: None,
                import_mode: Some(ImportMode::Copy),
            })
            .await
            .expect("import");
        let encrypted_file = find_pgblob(&library_root.join("vaults")).expect("sealed chunk");
        fs::write(&encrypted_file, b"corrupt chunk").expect("corrupt chunk");
        let original_path = library_root.join(&imported.asset.relative_original_path);
        fs::remove_file(&original_path).expect("remove plaintext original");

        let verification = service
            .verify_backup(crate::domain::BackupVerifyRequest { export_root: None })
            .await
            .expect("verify backup");
        assert!(!verification.ok);
        assert!(
            verification
                .missing_vault_chunk_paths
                .iter()
                .any(|path| path.contains("encrypted hash mismatch"))
        );
    }

    #[tokio::test]
    async fn scans_and_commits_reference_imports() {
        let runtime_root = temp_root("import");
        let library_root = runtime_root.join("library");
        let source_root = runtime_root.join("source");
        fs::create_dir_all(&source_root).expect("source dir");
        fs::write(source_root.join("a.jpg"), b"image").expect("write file");

        let service = GalleryService::new(AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        })
        .expect("service");

        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Copy,
            })
            .await
            .expect("settings");

        let session = service
            .scan_import_source(ScanImportSourceRequest {
                source_path: source_root.to_string_lossy().to_string(),
                source_kind: ImportSourceKind::Folder,
                recursive: false,
                import_mode: Some(ImportMode::Reference),
                add_as_watch_folder: false,
                place_hint: Some("Goa".to_string()),
            })
            .await
            .expect("scan");

        let committed = service
            .commit_import_session(session.id, vec![], Some(ImportMode::Reference), None)
            .await
            .expect("commit");

        assert_eq!(committed.imported_asset_ids.len(), 1);
        assert_eq!(service.timeline().await.buckets.len(), 1);
        assert_eq!(service.places().await.len(), 1);
        assert_eq!(service.events().await.len(), 1);
    }

    #[tokio::test]
    async fn timeline_can_return_a_capped_startup_slice() {
        let runtime_root = temp_root("timeline-limit");
        let library_root = runtime_root.join("library");
        let source_root = runtime_root.join("source");
        fs::create_dir_all(&source_root).expect("source dir");
        fs::write(source_root.join("a.jpg"), b"image-a").expect("write file");
        fs::write(source_root.join("b.jpg"), b"image-b").expect("write file");
        fs::write(source_root.join("c.jpg"), b"image-c").expect("write file");

        let service = GalleryService::new(AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        })
        .expect("service");

        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Reference,
            })
            .await
            .expect("settings");

        let session = service
            .scan_import_source(ScanImportSourceRequest {
                source_path: source_root.to_string_lossy().to_string(),
                source_kind: ImportSourceKind::Folder,
                recursive: false,
                import_mode: Some(ImportMode::Reference),
                add_as_watch_folder: false,
                place_hint: None,
            })
            .await
            .expect("scan");

        service
            .commit_import_session(session.id, vec![], Some(ImportMode::Reference), None)
            .await
            .expect("commit");

        let full = service.timeline().await;
        let capped = service.timeline_with_limit(Some(1), Some(1)).await;

        assert_eq!(full.total_assets, 3);
        assert_eq!(capped.total_assets, 3);
        assert_eq!(capped.returned_assets, 1);
        assert_eq!(capped.next_cursor.as_deref(), Some("1"));
        assert_eq!(full.buckets[0].assets.len(), 3);
        assert_eq!(capped.buckets[0].assets.len(), 1);
        assert_eq!(capped.buckets[0].asset_ids.len(), 1);
        assert_eq!(capped.buckets[0].total_assets, 3);

        let second_page = service.timeline_page(Some(1), Some(1), Some(1)).await;
        assert_eq!(second_page.returned_assets, 1);
        assert_eq!(second_page.next_cursor.as_deref(), Some("2"));
        assert_ne!(
            capped.buckets[0].assets[0].id,
            second_page.buckets[0].assets[0].id
        );
    }

    #[tokio::test]
    async fn asset_flags_persist_and_archived_assets_are_hidden_by_default() {
        let runtime_root = temp_root("asset-flags");
        let library_root = runtime_root.join("library");
        let source_root = runtime_root.join("source");
        fs::create_dir_all(&source_root).expect("source dir");
        fs::write(source_root.join("a.jpg"), b"image-a").expect("write file");
        fs::write(source_root.join("b.jpg"), b"image-b").expect("write file");

        let service = GalleryService::new(AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        })
        .expect("service");

        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Reference,
            })
            .await
            .expect("settings");

        let session = service
            .scan_import_source(ScanImportSourceRequest {
                source_path: source_root.to_string_lossy().to_string(),
                source_kind: ImportSourceKind::Folder,
                recursive: false,
                import_mode: Some(ImportMode::Reference),
                add_as_watch_folder: false,
                place_hint: None,
            })
            .await
            .expect("scan");

        service
            .commit_import_session(session.id, vec![], Some(ImportMode::Reference), None)
            .await
            .expect("commit");

        let all_assets = service
            .timeline()
            .await
            .buckets
            .into_iter()
            .flat_map(|bucket| bucket.assets)
            .collect::<Vec<_>>();
        assert_eq!(all_assets.len(), 2);
        let archived_id = all_assets[0].id;

        let updated = service
            .update_asset_flags(
                archived_id,
                UpdateAssetFlagsRequest {
                    favorite: Some(true),
                    archived: Some(true),
                },
            )
            .await
            .expect("flags updated");

        assert!(updated.favorite);
        assert!(updated.archived);
        assert_eq!(service.favorite_assets().await.len(), 1);
        assert_eq!(service.archived_assets().await.len(), 1);

        let bulk_updated = service
            .update_assets_flags(UpdateAssetsFlagsRequest {
                asset_ids: all_assets.iter().map(|asset| asset.id).collect(),
                favorite: Some(true),
                archived: None,
            })
            .await
            .expect("bulk flags updated");
        assert_eq!(bulk_updated.len(), 2);
        assert_eq!(service.favorite_assets().await.len(), 2);

        let visible = service.timeline().await;
        assert_eq!(visible.total_assets, 1);
        assert!(
            !visible.buckets[0]
                .assets
                .iter()
                .any(|asset| asset.id == archived_id)
        );

        let including_archived = service
            .timeline_page_filtered(None, None, None, true)
            .await
            .buckets
            .into_iter()
            .flat_map(|bucket| bucket.assets)
            .collect::<Vec<_>>();
        assert_eq!(including_archived.len(), 2);
        assert!(
            including_archived
                .iter()
                .any(|asset| asset.id == archived_id && asset.favorite && asset.archived)
        );

        let restarted = GalleryService::new(AppConfig {
            runtime_root,
            ..AppConfig::default()
        })
        .expect("restarted service");
        let restarted_assets = restarted
            .timeline_page_filtered(None, None, None, true)
            .await
            .buckets
            .into_iter()
            .flat_map(|bucket| bucket.assets)
            .collect::<Vec<_>>();
        assert!(
            restarted_assets
                .iter()
                .any(|asset| asset.id == archived_id && asset.favorite && asset.archived)
        );
        assert_eq!(restarted.timeline().await.total_assets, 1);
    }

    #[tokio::test]
    async fn manual_albums_persist_and_manage_membership_without_touching_files() {
        let runtime_root = temp_root("manual-albums");
        let library_root = runtime_root.join("library");
        let source_root = runtime_root.join("source");
        fs::create_dir_all(&source_root).expect("source dir");
        let first_path = source_root.join("a.jpg");
        let second_path = source_root.join("b.jpg");
        fs::write(&first_path, b"image-a").expect("write file");
        fs::write(&second_path, b"image-b").expect("write file");

        let service = GalleryService::new(AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        })
        .expect("service");

        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Reference,
            })
            .await
            .expect("settings");

        let session = service
            .scan_import_source(ScanImportSourceRequest {
                source_path: source_root.to_string_lossy().to_string(),
                source_kind: ImportSourceKind::Folder,
                recursive: false,
                import_mode: Some(ImportMode::Reference),
                add_as_watch_folder: false,
                place_hint: None,
            })
            .await
            .expect("scan");

        service
            .commit_import_session(session.id, vec![], Some(ImportMode::Reference), None)
            .await
            .expect("commit");

        let assets = service
            .timeline()
            .await
            .buckets
            .into_iter()
            .flat_map(|bucket| bucket.assets)
            .collect::<Vec<_>>();
        let first_id = assets[0].id;
        let second_id = assets[1].id;

        let album = service
            .create_album(CreateAlbumRequest {
                title: "Family trip".to_string(),
                asset_ids: vec![first_id],
            })
            .await
            .expect("create album");
        assert_eq!(album.asset_ids, vec![first_id]);
        assert_eq!(album.cover_asset_id, Some(first_id));

        let renamed = service
            .rename_album(
                album.id,
                RenameAlbumRequest {
                    title: "Goa family trip".to_string(),
                },
            )
            .await
            .expect("rename album");
        assert_eq!(renamed.title, "Goa family trip");

        let with_second = service
            .add_album_assets(
                album.id,
                UpdateAlbumAssetsRequest {
                    asset_ids: vec![second_id],
                },
            )
            .await
            .expect("add asset");
        assert_eq!(with_second.asset_ids.len(), 2);

        let assets_in_album = service.album_assets(album.id).await.expect("album assets");
        assert_eq!(assets_in_album.len(), 2);
        assert!(first_path.exists());
        assert!(second_path.exists());

        let removed_first = service
            .remove_album_assets(
                album.id,
                UpdateAlbumAssetsRequest {
                    asset_ids: vec![first_id],
                },
            )
            .await
            .expect("remove asset");
        assert_eq!(removed_first.asset_ids, vec![second_id]);
        assert_eq!(removed_first.cover_asset_id, Some(second_id));

        let restarted = GalleryService::new(AppConfig {
            runtime_root,
            ..AppConfig::default()
        })
        .expect("restarted service");
        let albums = restarted.albums().await;
        assert_eq!(albums.len(), 1);
        assert_eq!(albums[0].title, "Goa family trip");
        assert_eq!(albums[0].asset_ids, vec![second_id]);
    }

    #[tokio::test]
    async fn dedupes_copy_imports_after_first_commit() {
        let runtime_root = temp_root("dedupe");
        let library_root = runtime_root.join("library");
        let source_root = runtime_root.join("source");
        fs::create_dir_all(&source_root).expect("source dir");
        fs::write(source_root.join("a.jpg"), b"same-image-bytes").expect("write file");

        let service = GalleryService::new(AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        })
        .expect("service");

        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Copy,
            })
            .await
            .expect("settings");

        let first = service
            .scan_import_source(ScanImportSourceRequest {
                source_path: source_root.to_string_lossy().to_string(),
                source_kind: ImportSourceKind::Folder,
                recursive: false,
                import_mode: Some(ImportMode::Copy),
                add_as_watch_folder: false,
                place_hint: None,
            })
            .await
            .expect("first scan");
        service
            .commit_import_session(first.id, vec![], Some(ImportMode::Copy), None)
            .await
            .expect("first commit");

        let second = service
            .scan_import_source(ScanImportSourceRequest {
                source_path: source_root.to_string_lossy().to_string(),
                source_kind: ImportSourceKind::Folder,
                recursive: false,
                import_mode: Some(ImportMode::Copy),
                add_as_watch_folder: false,
                place_hint: None,
            })
            .await
            .expect("second scan");

        assert!(second.candidates[0].duplicate_asset_id.is_some());
    }

    #[tokio::test]
    async fn counts_duplicates_within_same_reference_commit() {
        let runtime_root = temp_root("same-commit-dedupe");
        let library_root = runtime_root.join("library");
        let source_root = runtime_root.join("source");
        fs::create_dir_all(&source_root).expect("source dir");
        fs::write(source_root.join("a.jpg"), b"same-image-bytes").expect("write a");
        fs::write(source_root.join("b.jpg"), b"same-image-bytes").expect("write b");

        let service = GalleryService::new(AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        })
        .expect("service");

        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Reference,
            })
            .await
            .expect("settings");

        let session = service
            .scan_import_source(ScanImportSourceRequest {
                source_path: source_root.to_string_lossy().to_string(),
                source_kind: ImportSourceKind::Folder,
                recursive: false,
                import_mode: Some(ImportMode::Reference),
                add_as_watch_folder: false,
                place_hint: None,
            })
            .await
            .expect("scan");
        let committed = service
            .commit_import_session(session.id, vec![], Some(ImportMode::Reference), None)
            .await
            .expect("commit");

        assert_eq!(committed.imported_asset_ids.len(), 1);
        assert_eq!(committed.skipped_duplicate_ids.len(), 1);
        assert_eq!(service.diagnostics().await["assets"].as_u64(), Some(1));
    }

    #[tokio::test]
    async fn safely_moves_media_and_sidecars_into_managed_library() {
        let runtime_root = temp_root("move");
        let library_root = runtime_root.join("source").join("PrivateGalleryLibrary");
        let source_root = runtime_root.join("source");
        fs::create_dir_all(&source_root).expect("source dir");
        let media_path = source_root.join("a.jpg");
        let sidecar_path = source_root.join("a.jpg.json");
        fs::write(&media_path, b"same-image-bytes").expect("write file");
        fs::write(&sidecar_path, b"{\"title\":\"a\"}").expect("write sidecar");

        let service = GalleryService::new(AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        })
        .expect("service");

        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Move,
            })
            .await
            .expect("settings");

        let session = service
            .scan_import_source(ScanImportSourceRequest {
                source_path: source_root.to_string_lossy().to_string(),
                source_kind: ImportSourceKind::Folder,
                recursive: true,
                import_mode: Some(ImportMode::Move),
                add_as_watch_folder: false,
                place_hint: None,
            })
            .await
            .expect("scan");
        assert_eq!(session.candidates.len(), 1);
        assert_eq!(session.candidates[0].sidecar_paths.len(), 1);
        assert_eq!(session.selected_candidate_count, 1);
        assert_eq!(session.sidecar_count, 1);
        assert_eq!(session.unsupported_count, 0);
        assert_eq!(
            session.destination_root,
            Some(library_root.to_string_lossy().to_string())
        );
        assert!(session.requires_move_confirmation);
        assert!(session.source_contains_managed_library);

        let committed = service
            .commit_import_session(session.id, vec![], Some(ImportMode::Move), None)
            .await
            .expect("commit");

        assert_eq!(committed.imported_asset_ids.len(), 1);
        assert_eq!(committed.moved_asset_ids.len(), 1);
        assert_eq!(committed.sidecars_moved, 1);
        assert!(!media_path.exists());
        assert!(!sidecar_path.exists());

        let asset = service.timeline().await.buckets[0].assets[0].clone();
        let destination = library_root.join(&asset.relative_original_path);
        assert!(destination.exists());
        assert_eq!(
            imports::derive_content_hash_from_file(&destination).expect("hash"),
            asset.content_hash
        );
        assert!(destination.with_file_name("a.jpg.json").exists());
    }

    #[tokio::test]
    async fn imports_takeout_sidecar_metadata_into_places_and_timeline() {
        let runtime_root = temp_root("takeout-metadata");
        let library_root = runtime_root.join("source").join("PrivateGalleryLibrary");
        let source_root = runtime_root.join("source");
        fs::create_dir_all(&source_root).expect("source dir");
        fs::write(source_root.join("a.jpg"), b"same-image-bytes").expect("write file");
        fs::write(
            source_root.join("a.jpg.json"),
            r#"{
              "title": "Goa beach",
              "photoTakenTime": {"timestamp": "1735689600"},
              "geoData": {"latitude": 15.2993, "longitude": 74.1240}
            }"#,
        )
        .expect("write sidecar");

        let service = GalleryService::new(AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        })
        .expect("service");
        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Move,
            })
            .await
            .expect("settings");

        let session = service
            .scan_import_source(ScanImportSourceRequest {
                source_path: source_root.to_string_lossy().to_string(),
                source_kind: ImportSourceKind::Folder,
                recursive: true,
                import_mode: Some(ImportMode::Move),
                add_as_watch_folder: false,
                place_hint: None,
            })
            .await
            .expect("scan");
        assert_eq!(session.candidates[0].captured_at.unwrap().year(), 2025);

        service
            .commit_import_session(session.id, vec![], Some(ImportMode::Move), None)
            .await
            .expect("commit");

        let timeline = service.timeline().await;
        let asset = &timeline.buckets[0].assets[0];
        let asset_id = asset.id;
        assert_eq!(asset.captured_at.year(), 2025);
        assert_eq!(
            asset
                .metadata
                .as_ref()
                .and_then(|metadata| metadata.sidecar_title.as_deref()),
            Some("Goa beach")
        );
        assert!(
            asset
                .metadata
                .as_ref()
                .and_then(|metadata| metadata.geo.as_ref())
                .is_some()
        );
        assert_eq!(service.places().await.len(), 1);
        let place_id = service.places().await[0].id;
        assert_eq!(
            service.place_assets(place_id).await.expect("place assets")[0].id,
            asset_id
        );
    }

    #[tokio::test]
    async fn event_user_title_survives_rebuild() {
        let runtime_root = temp_root("event-title");
        let library_root = runtime_root.join("library");
        let source_root = runtime_root.join("source");
        fs::create_dir_all(&source_root).expect("source dir");
        fs::write(source_root.join("a.jpg"), b"image-a").expect("write file");

        let service = GalleryService::new(AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        })
        .expect("service");
        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Reference,
            })
            .await
            .expect("settings");
        let session = service
            .scan_import_source(ScanImportSourceRequest {
                source_path: source_root.to_string_lossy().to_string(),
                source_kind: ImportSourceKind::Folder,
                recursive: false,
                import_mode: Some(ImportMode::Reference),
                add_as_watch_folder: false,
                place_hint: Some("Family".to_string()),
            })
            .await
            .expect("scan");
        service
            .commit_import_session(session.id, vec![], Some(ImportMode::Reference), None)
            .await
            .expect("commit");
        let event_id = service.events().await[0].id;
        service
            .title_event(event_id, "Birthday dinner".to_string())
            .await
            .expect("title event");
        service.rebuild_events().await.expect("rebuild events");

        assert_eq!(service.events().await[0].title, "Birthday dinner");
        assert_eq!(
            service.event_assets(event_id).await.expect("event assets")[0].original_filename,
            "a.jpg"
        );
    }

    #[tokio::test]
    async fn rejects_move_commit_when_only_duplicates_are_selected() {
        let runtime_root = temp_root("move-duplicates");
        let library_root = runtime_root.join("source").join("PrivateGalleryLibrary");
        let source_root = runtime_root.join("source");
        fs::create_dir_all(&source_root).expect("source dir");
        fs::write(source_root.join("a.jpg"), b"same-image-bytes").expect("write first file");

        let service = GalleryService::new(AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        })
        .expect("service");

        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Move,
            })
            .await
            .expect("settings");

        let first = service
            .scan_import_source(ScanImportSourceRequest {
                source_path: source_root.to_string_lossy().to_string(),
                source_kind: ImportSourceKind::Folder,
                recursive: true,
                import_mode: Some(ImportMode::Move),
                add_as_watch_folder: false,
                place_hint: None,
            })
            .await
            .expect("scan first");
        service
            .commit_import_session(first.id, vec![], Some(ImportMode::Move), None)
            .await
            .expect("commit first");

        fs::write(source_root.join("duplicate.jpg"), b"same-image-bytes").expect("write duplicate");
        let duplicate = service
            .scan_import_source(ScanImportSourceRequest {
                source_path: source_root.to_string_lossy().to_string(),
                source_kind: ImportSourceKind::Folder,
                recursive: true,
                import_mode: Some(ImportMode::Move),
                add_as_watch_folder: false,
                place_hint: None,
            })
            .await
            .expect("scan duplicate");
        assert_eq!(duplicate.duplicate_count, 1);

        let error = service
            .commit_import_session(duplicate.id, vec![], Some(ImportMode::Move), None)
            .await
            .expect_err("duplicate-only move should be rejected");
        assert!(
            error
                .to_string()
                .contains("at least one selected non-duplicate")
        );
        assert!(source_root.join("duplicate.jpg").exists());
    }

    #[tokio::test]
    async fn missing_source_after_scan_is_candidate_failure() {
        let runtime_root = temp_root("missing-source");
        let library_root = runtime_root.join("source").join("PrivateGalleryLibrary");
        let source_root = runtime_root.join("source");
        fs::create_dir_all(&source_root).expect("source dir");
        let media_path = source_root.join("a.jpg");
        fs::write(&media_path, b"same-image-bytes").expect("write file");

        let service = GalleryService::new(AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        })
        .expect("service");
        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Move,
            })
            .await
            .expect("settings");
        let session = service
            .scan_import_source(ScanImportSourceRequest {
                source_path: source_root.to_string_lossy().to_string(),
                source_kind: ImportSourceKind::Folder,
                recursive: true,
                import_mode: Some(ImportMode::Move),
                add_as_watch_folder: false,
                place_hint: None,
            })
            .await
            .expect("scan");
        fs::remove_file(&media_path).expect("remove source");

        let committed = service
            .commit_import_session(session.id, vec![], Some(ImportMode::Move), None)
            .await
            .expect("commit should preserve candidate-level failure");

        assert_eq!(committed.imported_asset_ids.len(), 0);
        assert_eq!(committed.failed_candidate_ids.len(), 1);
        assert!(
            committed.candidates[0]
                .safety_status
                .contains("source file")
        );
    }

    #[tokio::test]
    async fn import_sessions_survive_restart_with_summary() {
        let runtime_root = temp_root("session-history");
        let library_root = runtime_root.join("library");
        let source_root = runtime_root.join("source");
        fs::create_dir_all(&source_root).expect("source dir");
        fs::write(source_root.join("a.jpg"), b"image").expect("write file");

        let config = AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        };
        let service = GalleryService::new(config.clone()).expect("service");
        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Reference,
            })
            .await
            .expect("settings");
        let session = service
            .scan_import_source(ScanImportSourceRequest {
                source_path: source_root.to_string_lossy().to_string(),
                source_kind: ImportSourceKind::Folder,
                recursive: false,
                import_mode: Some(ImportMode::Reference),
                add_as_watch_folder: false,
                place_hint: None,
            })
            .await
            .expect("scan");
        service
            .commit_import_session(session.id, vec![], Some(ImportMode::Reference), None)
            .await
            .expect("commit");

        let restarted = GalleryService::new(config).expect("restart service");
        let sessions = restarted.import_sessions().await;
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].selected_candidate_count, 1);
        assert_eq!(
            sessions[0].destination_root,
            Some(library_root.to_string_lossy().to_string())
        );
    }

    #[tokio::test]
    async fn privacy_status_is_local_only_and_loopback_bound() {
        let runtime_root = temp_root("privacy-status");
        let service = GalleryService::new(AppConfig {
            runtime_root,
            ..AppConfig::default()
        })
        .expect("service");

        let status = service.privacy_status().await.expect("privacy status");

        assert_eq!(status.network_policy, NetworkPolicy::AskBeforeDownload);
        assert_eq!(status.daemon_bind_address, "127.0.0.1:4821");
        assert!(status.loopback_only);
        assert!(!status.photo_processing_network_allowed);
        assert!(!status.telemetry_enabled);
        assert!(!status.analytics_enabled);
        assert!(!status.cloud_ai_enabled);
        assert!(status.model_download_requires_confirmation);
        assert!(status.installed_models.is_empty());
        assert!(
            service
                .models()
                .await
                .expect("models")
                .iter()
                .any(|model| model.id == "scrfd-face-detector")
        );
    }

    #[test]
    fn rejects_non_loopback_bind_without_developer_mode() {
        let runtime_root = temp_root("non-loopback-bind");
        let result = GalleryService::new(AppConfig {
            runtime_root,
            bind_host: "0.0.0.0".to_string(),
            ..AppConfig::default()
        });

        let error = result.err().expect("non-loopback bind should be rejected");
        assert!(error.to_string().contains("non-loopback"));
    }

    #[tokio::test]
    async fn model_install_requires_explicit_confirmation() {
        let runtime_root = temp_root("model-install-confirmation");
        let service = GalleryService::new(AppConfig {
            runtime_root,
            ..AppConfig::default()
        })
        .expect("service");

        let error = service
            .install_model(ModelInstallRequest {
                id: "scrfd-face-detector".to_string(),
                confirmed: false,
                source_url: None,
                expected_sha256: None,
            })
            .await
            .expect_err("install without confirmation should fail");

        assert!(error.to_string().contains("explicit confirmation"));
    }

    #[tokio::test]
    async fn confirmed_model_download_requires_pinned_hash_and_approval() {
        let runtime_root = temp_root("model-install-hash");
        let service = GalleryService::new(AppConfig {
            runtime_root,
            ..AppConfig::default()
        })
        .expect("service");

        let missing_hash = service
            .install_model(ModelInstallRequest {
                id: "scrfd-face-detector".to_string(),
                confirmed: true,
                source_url: None,
                expected_sha256: None,
            })
            .await
            .expect_err("download without hash should fail");
        assert!(missing_hash.to_string().contains("expected_sha256"));

        let pending_review = service
            .install_model(ModelInstallRequest {
                id: "scrfd-face-detector".to_string(),
                confirmed: true,
                source_url: Some("https://github.com/deepinsight/insightface".to_string()),
                expected_sha256: Some(
                    "0000000000000000000000000000000000000000000000000000000000000000".to_string(),
                ),
            })
            .await
            .expect_err("unapproved candidate should fail before download");
        assert!(pending_review.to_string().contains("not approved"));
    }

    #[tokio::test]
    async fn sensitive_index_jobs_are_blocked_until_encryption_and_models() {
        let runtime_root = temp_root("sensitive-index-gate");
        let service = GalleryService::new(AppConfig {
            runtime_root,
            ..AppConfig::default()
        })
        .expect("service");

        let privacy = service.privacy_status().await.expect("privacy");
        assert!(!privacy.encryption.sensitive_indexing_allowed);

        let face_job = service.index_people().await.expect("face job");
        let ocr_job = service
            .rebuild_ocr(RebuildRequest::default())
            .await
            .expect("ocr job");
        let scene_job = service
            .rebuild_scenes(RebuildRequest::default())
            .await
            .expect("scene job");
        let semantic_job = service.rebuild_semantic().await.expect("semantic job");
        assert_eq!(face_job.status, crate::domain::JobStatus::Failed);
        assert_eq!(ocr_job.status, crate::domain::JobStatus::Failed);
        assert_eq!(scene_job.status, crate::domain::JobStatus::Failed);
        assert_eq!(semantic_job.status, crate::domain::JobStatus::Failed);

        let status = service.search_status().await.expect("search status");
        assert!(status.filename_ready);
        assert!(!status.ocr_ready);
        assert!(!status.scene_ready);
        assert!(!status.semantic_ready);
    }

    #[tokio::test]
    async fn model_runtime_status_reports_local_python_sidecar() {
        let runtime_root = temp_root("ml-sidecar");
        let service = GalleryService::new(AppConfig {
            runtime_root,
            ..AppConfig::default()
        })
        .expect("service");

        let status = service.model_runtime_status().await;

        assert_eq!(status.runtime, "python-sidecar");
        assert!(status.detail.contains("sidecar") || !status.ok);
        if status.ok {
            assert!(status.offline_ready);
            assert!(status.sidecar_path.is_some());
        }
    }

    #[tokio::test]
    async fn activates_sqlcipher_encryption_and_preserves_library_state() {
        let runtime_root = temp_root("encryption-activation");
        let library_root = runtime_root.join("library");
        let source_root = runtime_root.join("source");
        fs::create_dir_all(&source_root).expect("source dir");
        fs::write(source_root.join("a.jpg"), b"image-a").expect("write file");

        let config = AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        };
        let service = GalleryService::new(config.clone()).expect("service");
        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Reference,
            })
            .await
            .expect("settings");
        let session = service
            .scan_import_source(ScanImportSourceRequest {
                source_path: source_root.to_string_lossy().to_string(),
                source_kind: ImportSourceKind::Folder,
                recursive: false,
                import_mode: Some(ImportMode::Reference),
                add_as_watch_folder: false,
                place_hint: Some("Home".to_string()),
            })
            .await
            .expect("scan");
        service
            .commit_import_session(session.id, vec![], Some(ImportMode::Reference), None)
            .await
            .expect("commit");

        let result = service
            .activate_encryption(EncryptionActivationRequest {
                confirmed: true,
                backup_root: None,
            })
            .await
            .expect("activate encryption");

        assert!(result.status.database_encrypted);
        assert!(result.status.derived_data_encrypted);
        assert!(result.status.sensitive_indexing_allowed);
        assert!(result.row_counts_verified);
        assert_eq!(result.integrity_check, "ok");
        assert!(PathBuf::from(result.backup_path).exists());

        let restarted = GalleryService::new(config).expect("restart encrypted service");
        assert!(restarted.encryption_status().await.database_encrypted);
        assert_eq!(restarted.timeline().await.buckets[0].assets.len(), 1);
        assert_eq!(restarted.places().await[0].label, "Home");
        let people_job = restarted.index_people().await.expect("people job");
        assert_eq!(people_job.status, crate::domain::JobStatus::Failed);
        assert!(
            people_job
                .detail
                .as_deref()
                .unwrap_or_default()
                .contains("approved local model")
        );
    }

    #[tokio::test]
    async fn encryption_activation_requires_confirmation() {
        let runtime_root = temp_root("encryption-confirm");
        let service = GalleryService::new(AppConfig {
            runtime_root,
            ..AppConfig::default()
        })
        .expect("service");

        let error = service
            .activate_encryption(EncryptionActivationRequest {
                confirmed: false,
                backup_root: None,
            })
            .await
            .expect_err("activation without confirmation should fail");

        assert!(error.to_string().contains("explicit confirmation"));
    }

    #[tokio::test]
    async fn ocr_rebuild_requires_encrypted_storage() {
        let runtime_root = temp_root("ocr-encryption-gate");
        let service = GalleryService::new(AppConfig {
            runtime_root,
            ..AppConfig::default()
        })
        .expect("service");

        let job = service
            .rebuild_ocr(RebuildRequest::default())
            .await
            .expect("ocr job");
        assert_eq!(job.status, crate::domain::JobStatus::Failed);
        assert!(
            job.detail
                .as_deref()
                .unwrap_or_default()
                .contains("OCR indexing blocked")
        );
    }

    #[tokio::test]
    async fn ocr_rebuild_reports_missing_local_provider() {
        let runtime_root = temp_root("ocr-missing-provider");
        let config = AppConfig {
            runtime_root: runtime_root.clone(),
            tesseract_path: Some(runtime_root.join("missing-tesseract")),
            ..AppConfig::default()
        };
        let service = GalleryService::new(config).expect("service");
        service
            .activate_encryption(EncryptionActivationRequest {
                confirmed: true,
                backup_root: None,
            })
            .await
            .expect("activate encryption");

        let job = service
            .rebuild_ocr(RebuildRequest::default())
            .await
            .expect("ocr job");
        assert_eq!(job.status, crate::domain::JobStatus::Failed);
        assert!(
            job.detail
                .as_deref()
                .unwrap_or_default()
                .contains("local OCR provider missing")
        );
    }

    #[tokio::test]
    async fn ocr_rebuild_persists_text_and_searches_after_restart() {
        let runtime_root = temp_root("ocr-index");
        let library_root = runtime_root.join("library");
        let source_root = runtime_root.join("source");
        fs::create_dir_all(&source_root).expect("source dir");
        let media_path = source_root.join("receipt.jpg");
        fs::write(&media_path, b"fake-image-bytes").expect("write file");
        let original_hash = imports::derive_content_hash_from_file(&media_path).expect("hash");
        let tesseract = fake_tesseract(&runtime_root, "Family privacy receipt total");

        let config = AppConfig {
            runtime_root: runtime_root.clone(),
            tesseract_path: Some(tesseract),
            ..AppConfig::default()
        };
        let service = GalleryService::new(config.clone()).expect("service");
        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Reference,
            })
            .await
            .expect("settings");
        let session = service
            .scan_import_source(ScanImportSourceRequest {
                source_path: source_root.to_string_lossy().to_string(),
                source_kind: ImportSourceKind::Folder,
                recursive: false,
                import_mode: Some(ImportMode::Reference),
                add_as_watch_folder: false,
                place_hint: None,
            })
            .await
            .expect("scan");
        service
            .commit_import_session(session.id, vec![], Some(ImportMode::Reference), None)
            .await
            .expect("commit");
        service
            .activate_encryption(EncryptionActivationRequest {
                confirmed: true,
                backup_root: None,
            })
            .await
            .expect("activate encryption");

        let job = service
            .rebuild_ocr(RebuildRequest::default())
            .await
            .expect("ocr rebuild");
        assert_eq!(job.status, crate::domain::JobStatus::Completed);
        assert_eq!(
            imports::derive_content_hash_from_file(&media_path).expect("hash after"),
            original_hash
        );

        let asset = service.timeline().await.buckets[0].assets[0].clone();
        let blocks = service
            .ocr_blocks_for_asset(asset.id)
            .await
            .expect("ocr blocks");
        assert_eq!(blocks.len(), 1);
        assert!(blocks[0].text.contains("privacy receipt"));
        assert_eq!(blocks[0].derived.model_name, "tesseract-cli");
        assert!(blocks[0].derived.model_hash.is_some());

        let search = service
            .search(SearchQuery {
                text: Some("receipt".to_string()),
                people: None,
                places: None,
                from_date: None,
                to_date: None,
                include_archived: false,
                limit: None,
            })
            .await;
        assert_eq!(search.assets.len(), 1);
        assert!(service.search_status().await.expect("status").ocr_ready);

        let restarted = GalleryService::new(config).expect("restart");
        let restarted_blocks = restarted
            .ocr_blocks_for_asset(asset.id)
            .await
            .expect("restarted OCR blocks");
        assert_eq!(restarted_blocks.len(), 1);
        let restarted_search = restarted
            .search(SearchQuery {
                text: Some("privacy".to_string()),
                people: None,
                places: None,
                from_date: None,
                to_date: None,
                include_archived: false,
                limit: None,
            })
            .await;
        assert_eq!(restarted_search.assets.len(), 1);
    }

    #[tokio::test]
    async fn ocr_rebuild_can_run_in_small_batches_without_reindexing_existing_assets() {
        let runtime_root = temp_root("ocr-batch-limit");
        let library_root = runtime_root.join("library");
        let source_root = runtime_root.join("source");
        fs::create_dir_all(&source_root).expect("source dir");
        for index in 1..=3 {
            fs::write(
                source_root.join(format!("receipt-{index}.jpg")),
                format!("fake-image-bytes-{index}"),
            )
            .expect("write fixture");
        }
        let tesseract = fake_tesseract(&runtime_root, "Tiny batch receipt text");

        let service = GalleryService::new(AppConfig {
            runtime_root: runtime_root.clone(),
            tesseract_path: Some(tesseract),
            ..AppConfig::default()
        })
        .expect("service");
        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Reference,
            })
            .await
            .expect("settings");
        let session = service
            .scan_import_source(ScanImportSourceRequest {
                source_path: source_root.to_string_lossy().to_string(),
                source_kind: ImportSourceKind::Folder,
                recursive: false,
                import_mode: Some(ImportMode::Reference),
                add_as_watch_folder: false,
                place_hint: None,
            })
            .await
            .expect("scan");
        service
            .commit_import_session(session.id, vec![], Some(ImportMode::Reference), None)
            .await
            .expect("commit");
        service
            .activate_encryption(EncryptionActivationRequest {
                confirmed: true,
                backup_root: None,
            })
            .await
            .expect("activate encryption");

        let first = service
            .rebuild_ocr(RebuildRequest {
                limit: Some(1),
                ..RebuildRequest::default()
            })
            .await
            .expect("first OCR batch");
        assert_eq!(first.status, crate::domain::JobStatus::Completed);
        assert!(
            first
                .detail
                .as_deref()
                .unwrap_or_default()
                .contains("batch limit 1")
        );
        assert_eq!(count_ocr_blocks(&service).await, 1);

        service
            .rebuild_ocr(RebuildRequest {
                limit: Some(1),
                ..RebuildRequest::default()
            })
            .await
            .expect("second OCR batch");
        assert_eq!(count_ocr_blocks(&service).await, 2);
    }

    #[tokio::test]
    async fn ocr_rebuild_remembers_no_text_assets_between_batches() {
        let runtime_root = temp_root("ocr-no-text-marker");
        let library_root = runtime_root.join("library");
        let source_root = runtime_root.join("source");
        fs::create_dir_all(&source_root).expect("source dir");
        for index in 1..=2 {
            fs::write(
                source_root.join(format!("blank-{index}.jpg")),
                format!("fake-blank-image-bytes-{index}"),
            )
            .expect("write fixture");
        }
        let tesseract = fake_tesseract(&runtime_root, "");

        let service = GalleryService::new(AppConfig {
            runtime_root: runtime_root.clone(),
            tesseract_path: Some(tesseract),
            ..AppConfig::default()
        })
        .expect("service");
        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Reference,
            })
            .await
            .expect("settings");
        let session = service
            .scan_import_source(ScanImportSourceRequest {
                source_path: source_root.to_string_lossy().to_string(),
                source_kind: ImportSourceKind::Folder,
                recursive: false,
                import_mode: Some(ImportMode::Reference),
                add_as_watch_folder: false,
                place_hint: None,
            })
            .await
            .expect("scan");
        service
            .commit_import_session(session.id, vec![], Some(ImportMode::Reference), None)
            .await
            .expect("commit");
        service
            .activate_encryption(EncryptionActivationRequest {
                confirmed: true,
                backup_root: None,
            })
            .await
            .expect("activate encryption");

        let first = service
            .rebuild_ocr(RebuildRequest {
                limit: Some(1),
                ..RebuildRequest::default()
            })
            .await
            .expect("first OCR batch");
        assert!(
            first
                .detail
                .as_deref()
                .unwrap_or_default()
                .contains("confirmed 1 no-text asset")
        );
        let first_status = service.search_status().await.expect("status");
        assert_eq!(first_status.ocr_text_block_count, 0);
        assert_eq!(first_status.ocr_indexed_asset_count, 1);
        assert_eq!(first_status.ocr_remaining_photo_count, 1);

        service
            .rebuild_ocr(RebuildRequest {
                limit: Some(1),
                ..RebuildRequest::default()
            })
            .await
            .expect("second OCR batch");
        let second_status = service.search_status().await.expect("status");
        assert_eq!(second_status.ocr_text_block_count, 0);
        assert_eq!(second_status.ocr_indexed_asset_count, 2);
        assert_eq!(second_status.ocr_remaining_photo_count, 0);
    }

    #[tokio::test]
    async fn scene_rebuild_persists_local_tags_and_searches_after_restart() {
        let runtime_root = temp_root("scene-index");
        let library_root = runtime_root.join("library");
        let source_root = runtime_root.join("source");
        fs::create_dir_all(&source_root).expect("source dir");
        let media_path = source_root.join("garden.jpg");
        write_green_ppm_with_jpg_name(&media_path);

        let config = AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        };
        let service = GalleryService::new(config.clone()).expect("service");
        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Reference,
            })
            .await
            .expect("settings");
        let session = service
            .scan_import_source(ScanImportSourceRequest {
                source_path: source_root.to_string_lossy().to_string(),
                source_kind: ImportSourceKind::Folder,
                recursive: false,
                import_mode: Some(ImportMode::Reference),
                add_as_watch_folder: false,
                place_hint: None,
            })
            .await
            .expect("scan");
        service
            .commit_import_session(session.id, vec![], Some(ImportMode::Reference), None)
            .await
            .expect("commit");
        service
            .activate_encryption(EncryptionActivationRequest {
                confirmed: true,
                backup_root: None,
            })
            .await
            .expect("activate encryption");

        let job = service
            .rebuild_scenes(RebuildRequest::default())
            .await
            .expect("scene rebuild");
        if job.status == crate::domain::JobStatus::Failed
            && job.detail.as_deref().unwrap_or_default().contains("Pillow")
        {
            return;
        }
        assert_eq!(job.status, crate::domain::JobStatus::Completed);
        assert!(job.detail.as_deref().unwrap_or_default().contains("tag"));
        assert!(service.search_status().await.expect("status").scene_ready);

        let search = service
            .search(SearchQuery {
                text: Some("greenery".to_string()),
                people: None,
                places: None,
                from_date: None,
                to_date: None,
                include_archived: false,
                limit: None,
            })
            .await;
        assert_eq!(search.assets.len(), 1);

        let restarted = GalleryService::new(config).expect("restart");
        assert!(restarted.search_status().await.expect("status").scene_ready);
        let restarted_search = restarted
            .search(SearchQuery {
                text: Some("nature".to_string()),
                people: None,
                places: None,
                from_date: None,
                to_date: None,
                include_archived: false,
                limit: None,
            })
            .await;
        assert_eq!(restarted_search.assets.len(), 1);
    }

    #[tokio::test]
    async fn local_model_import_requires_pinned_hash_and_survives_restart() {
        let runtime_root = temp_root("local-model-import");
        let model_path = runtime_root.join("candidate.onnx");
        fs::write(&model_path, b"fake-model-bytes").expect("write model");
        let expected_hash =
            imports::derive_content_hash_from_file(&model_path).expect("hash model");

        let config = AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        };
        let service = GalleryService::new(config.clone()).expect("service");

        let mismatch = service
            .import_local_model(ModelImportRequest {
                id: "scrfd-face-detector".to_string(),
                local_path: model_path.to_string_lossy().to_string(),
                expected_sha256: Some("not-the-right-hash".to_string()),
                confirmed: true,
            })
            .await
            .expect_err("hash mismatch should be rejected");
        assert!(mismatch.to_string().contains("hash mismatch"));

        let imported = service
            .import_local_model(ModelImportRequest {
                id: "scrfd-face-detector".to_string(),
                local_path: model_path.to_string_lossy().to_string(),
                expected_sha256: Some(expected_hash.clone()),
                confirmed: true,
            })
            .await
            .expect("local import");
        assert_eq!(
            imported.installed_sha256.as_deref(),
            Some(expected_hash.as_str())
        );
        assert!(imported.installed_path.is_some());
        let installed_path = PathBuf::from(imported.installed_path.as_ref().expect("path"));
        assert!(installed_path.starts_with(runtime_root.join("models")));
        assert!(model_path.exists());
        assert!(service.verify_model("scrfd-face-detector").await.is_ok());

        let restarted = GalleryService::new(config).expect("restart service");
        let models = restarted.models().await.expect("models");
        let model = models
            .iter()
            .find(|model| model.id == "scrfd-face-detector")
            .expect("installed model");
        assert_eq!(
            model.installed_sha256.as_deref(),
            Some(expected_hash.as_str())
        );
    }

    #[tokio::test]
    async fn manual_date_and_place_corrections_apply_to_live_views() {
        let runtime_root = temp_root("manual-corrections");
        let library_root = runtime_root.join("library");
        let source_root = runtime_root.join("source");
        fs::create_dir_all(&source_root).expect("source dir");
        fs::write(source_root.join("a.jpg"), b"image-a").expect("write file");
        let corrected_at = chrono::DateTime::parse_from_rfc3339("2024-02-03T04:05:06Z")
            .expect("date")
            .with_timezone(&Utc);

        let service = GalleryService::new(AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        })
        .expect("service");
        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Reference,
            })
            .await
            .expect("settings");
        let session = service
            .scan_import_source(ScanImportSourceRequest {
                source_path: source_root.to_string_lossy().to_string(),
                source_kind: ImportSourceKind::Folder,
                recursive: false,
                import_mode: Some(ImportMode::Reference),
                add_as_watch_folder: false,
                place_hint: Some("Old place".to_string()),
            })
            .await
            .expect("scan");
        service
            .commit_import_session(session.id, vec![], Some(ImportMode::Reference), None)
            .await
            .expect("commit");

        let asset_id = service.timeline().await.buckets[0].assets[0].id;
        let metadata = service
            .correct_asset_date(
                asset_id,
                CorrectDateRequest {
                    captured_at: corrected_at,
                    timezone_offset_minutes: Some(330),
                    reason: Some("user correction".to_string()),
                },
            )
            .await
            .expect("correct date");
        assert_eq!(metadata.captured_at_source, MetadataSource::Manual);
        assert_eq!(
            service.timeline().await.buckets[0].assets[0].captured_at,
            corrected_at
        );

        let place_id = service.places().await[0].id;
        let place = service
            .correct_place(
                place_id,
                CorrectPlaceRequest {
                    label: "Home".to_string(),
                    latitude: Some(12.34),
                    longitude: Some(56.78),
                    hide_exact_gps: Some(true),
                    reason: None,
                },
            )
            .await
            .expect("correct place");
        assert_eq!(place.label, "Home");
        assert_eq!(service.places().await[0].label, "Home");
    }

    #[tokio::test]
    async fn manual_people_assignments_persist_and_search_by_name() {
        let runtime_root = temp_root("manual-people");
        let library_root = runtime_root.join("library");
        let source_root = runtime_root.join("source");
        fs::create_dir_all(&source_root).expect("source dir");
        fs::write(source_root.join("a.jpg"), b"image-mom").expect("write mom");
        fs::write(source_root.join("other.jpg"), b"image-other").expect("write other");

        let config = AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        };
        let service = GalleryService::new(config.clone()).expect("service");
        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Reference,
            })
            .await
            .expect("settings");
        let session = service
            .scan_import_source(ScanImportSourceRequest {
                source_path: source_root.to_string_lossy().to_string(),
                source_kind: ImportSourceKind::Folder,
                recursive: false,
                import_mode: Some(ImportMode::Reference),
                add_as_watch_folder: false,
                place_hint: None,
            })
            .await
            .expect("scan");
        service
            .commit_import_session(session.id, vec![], Some(ImportMode::Reference), None)
            .await
            .expect("commit");

        let timeline = service.timeline().await;
        let assets = &timeline.buckets[0].assets;
        let mom_asset = assets
            .iter()
            .find(|asset| asset.original_filename == "a.jpg")
            .expect("mom asset")
            .id;
        let other_asset = assets
            .iter()
            .find(|asset| asset.original_filename == "other.jpg")
            .expect("other asset")
            .id;

        let person = service
            .create_manual_person(CreateManualPersonRequest {
                display_name: "Mom".to_string(),
                asset_ids: vec![mom_asset],
            })
            .await
            .expect("create person");
        assert_eq!(person.asset_ids, vec![mom_asset]);
        assert_eq!(
            service
                .person_assets(person.id)
                .await
                .expect("person assets")[0]
                .id,
            mom_asset
        );
        assert!(
            service
                .events()
                .await
                .iter()
                .any(|event| event.people_ids.contains(&person.id))
        );

        let search = service
            .search(SearchQuery {
                text: Some("mom".to_string()),
                people: None,
                places: None,
                from_date: None,
                to_date: None,
                include_archived: false,
                limit: None,
            })
            .await;
        assert_eq!(search.assets.len(), 1);
        assert_eq!(search.assets[0].id, mom_asset);
        assert_eq!(search.people[0].display_name, "Mom");

        let updated = service
            .add_person_assets(
                person.id,
                UpdatePersonAssetsRequest {
                    asset_ids: vec![other_asset],
                },
            )
            .await
            .expect("add asset");
        assert_eq!(updated.asset_ids.len(), 2);

        let restarted = GalleryService::new(config).expect("restart");
        assert_eq!(restarted.people().await[0].asset_ids.len(), 2);
        let removed = restarted
            .remove_person_assets(
                person.id,
                UpdatePersonAssetsRequest {
                    asset_ids: vec![mom_asset],
                },
            )
            .await
            .expect("remove asset");
        assert_eq!(removed.asset_ids, vec![other_asset]);
    }

    #[tokio::test]
    async fn job_logs_retry_and_backup_verification_are_persistent() {
        let runtime_root = temp_root("jobs-backup");
        let config = AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        };
        let service = GalleryService::new(config.clone()).expect("service");
        let failed = service.index_people().await.expect("people job");
        assert_eq!(failed.status, crate::domain::JobStatus::Failed);
        assert_eq!(service.job_logs(failed.id).await.expect("logs").len(), 1);

        let retry = service.retry_job(failed.id).await.expect("retry job");
        assert_eq!(retry.status, crate::domain::JobStatus::Queued);
        assert_eq!(retry.retry_of_job_id, Some(failed.id));

        let verification = service
            .verify_backup(crate::domain::BackupVerifyRequest { export_root: None })
            .await
            .expect("backup verification");
        assert!(verification.ok);
        assert!(verification.database_sha256.is_some());

        let export_root = runtime_root.join("backup-export");
        let export = service
            .export_backup(crate::domain::BackupExportRequest {
                export_root: export_root.to_string_lossy().to_string(),
                include_models: false,
            })
            .await
            .expect("backup export");
        assert!(export.ok);
        assert!(PathBuf::from(export.manifest_path).exists());
        assert!(PathBuf::from(export.database_copied_to).exists());

        let restarted = GalleryService::new(config).expect("restart");
        assert_eq!(restarted.job_logs(failed.id).await.expect("logs").len(), 1);
        assert!(restarted.job(retry.id).await.is_ok());
    }

    #[tokio::test]
    async fn rebuild_jobs_remain_offline_only() {
        let runtime_root = temp_root("offline-rebuilds");
        let service = GalleryService::new(AppConfig {
            runtime_root,
            network_policy: NetworkPolicy::OfflineOnly,
            ..AppConfig::default()
        })
        .expect("service");

        assert!(
            !service
                .privacy_status()
                .await
                .expect("privacy status")
                .photo_processing_network_allowed
        );
        service.rebuild_metadata().await.expect("metadata rebuild");
        service.rebuild_places().await.expect("places rebuild");
        service.rebuild_events().await.expect("events rebuild");
        service.rebuild_search().await.expect("search rebuild");
        assert_eq!(
            service
                .rebuild_ocr(RebuildRequest::default())
                .await
                .expect("ocr rebuild")
                .status,
            crate::domain::JobStatus::Failed
        );
        assert_eq!(
            service
                .rebuild_scenes(RebuildRequest::default())
                .await
                .expect("scene rebuild")
                .status,
            crate::domain::JobStatus::Failed
        );
        let people_job = service.index_people().await.expect("people job");
        assert_eq!(people_job.status, crate::domain::JobStatus::Failed);
    }
}
