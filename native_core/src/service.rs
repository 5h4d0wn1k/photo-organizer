use std::{
    collections::{BTreeMap, BTreeSet, HashMap},
    fs,
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    sync::Arc,
};

use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::json;
use sha2::{Digest, Sha256};
use thiserror::Error;
use tokio::sync::RwLock;
use uuid::Uuid;

use crate::{
    config::AppConfig,
    domain::{
        Album, Asset, AssetAvailability, AssetAvailabilityState, AuditEvent, BackupExportRequest,
        BackupExportResult, BackupRestorePlan, BackupRestorePlanRequest, BackupRestoreRunRequest,
        BackupRestoreRunResult, BackupVerification, BackupVerifyRequest, BlobChunk, BlobRecord,
        BlobReplica, CapabilityGrant, CorrectDateRequest, CorrectPlaceRequest, CorrectionKind,
        CorrectionRecord, CreateAlbumRequest, CreateDeviceRequest, CreateFileFolderRequest,
        CreateManualPersonRequest, CreatePairingSessionRequest, CreateSmartFolderRequest,
        CreateVaultRequest, CreateWatchFolderRequest, DeviceIdentity, DevicePairing, DeviceRole,
        DeviceStorageProfile, DeviceTrustLevel, DuplicateReviewEntry, DuplicateReviewSummary,
        EncryptionActivationRequest, EncryptionActivationResult, EnrollDeviceRequest,
        EntitlementCache, EntitlementCacheStatus, EntitlementEffectiveStatus,
        EntitlementStatusResponse, EntitlementTier, EventCluster, FeedbackEvent, HidePersonRequest,
        ImportAssetRequest, ImportAssetResponse, ImportMode, ImportSession, ImportSessionStatus,
        JobKind, JobLog, JobRecord, JobStatus, LibrarySettings, LibraryStatusResponse, MediaKind,
        MergePersonRequest, MetadataSource, MobileAssetSummary, MobilePairRequest,
        MobilePairResponse, MobileReplicaAssignment, MobileReplicaChunkDescriptor,
        MobileReplicaReport, MobileReplicaReportRequest, MobileReplicaRestoreResult, MobileSession,
        MobileSessionRefreshResponse, MobileStoragePlan, MobileStorageProfileUpdateRequest,
        MobileUpload, MobileUploadRequest, MobileUploadStatus, MobileWorkspaceCapabilities,
        MobileWorkspaceResponse, ModelArtifact, ModelImportRequest, ModelInstallRequest, ModelTask,
        MoveFileEntryRequest, OcrBlock, OriginalStoragePolicy, PersonCluster, PlaceCluster,
        PlatformReleaseEvidence, PlatformReleaseEvidenceStatus, PlatformReleaseReadinessResponse,
        PlatformReleaseReadinessStatus, PlatformReleaseSurface, PlatformReleaseSurfaceReadiness,
        PrivacyStatus, RebuildRequest, RejectPersonMatchRequest, RelayEndpoint, RenameAlbumRequest,
        RenameFileEntryRequest, RenamePersonRequest, ReplicaHealth, RevokeDeviceRequest,
        RunSyncRequest, ScanImportSourceRequest, SceneTag, SearchIndexStatus, SearchQuery,
        SearchResponse, SmartFolder, SplitPersonRequest, StoragePolicy, StoragePolicyMode,
        SupportBundleExportRequest, SupportBundleExportResult, SyncConflict, SyncNetworkStatus,
        SyncPlan, SyncSession, SyncTransfer, SyncTransferExecutionResult,
        SyncTransferExecutionStatus, SyncTransferStatus, TimelineBucket, TimelineResponse,
        UpdateAlbumAssetsRequest, UpdateAssetFlagsRequest, UpdateAssetTagsRequest,
        UpdateAssetsFlagsRequest, UpdateEntitlementCacheRequest, UpdateLibrarySettingsRequest,
        UpdatePersonAssetsRequest, UpdateVaultStoragePolicyRequest, VariantKind, Vault,
        VaultFileDeviceSummary, VaultFileEntry, VaultFileKind, VaultFileTreeResponse, VaultInvite,
        VaultKeyEnvelope, VaultMember, VaultStatus, WatchFolder,
    },
    events, imports, metadata, ml_sidecar, model_registry, ocr, people, search, security,
    storage::{self, PersistedLibraryState, StorageBootstrapReport},
    sync_transport::{self, OutboundBlobTransfer, TransferDirection},
    vault_store,
};

const MOBILE_SESSION_TTL_DAYS: i64 = 30;
const MOBILE_UPLOAD_MAX_BYTES: u64 = 512 * 1024 * 1024;
const MOBILE_UPLOAD_CHUNK_MAX_BYTES: u64 = 8 * 1024 * 1024;
const ORIGINAL_DOWNLOAD_RANGE_MAX_BYTES: u64 = 8 * 1024 * 1024;

#[derive(Debug, Default)]
pub(crate) struct LibraryState {
    pub(crate) library_settings: Option<LibrarySettings>,
    pub(crate) watch_folders: Vec<WatchFolder>,
    pub(crate) assets: Vec<crate::domain::Asset>,
    pub(crate) file_entries: Vec<VaultFileEntry>,
    pub(crate) albums: Vec<Album>,
    pub(crate) smart_folders: Vec<SmartFolder>,
    pub(crate) people: Vec<PersonCluster>,
    pub(crate) places: Vec<PlaceCluster>,
    pub(crate) events: Vec<EventCluster>,
    pub(crate) faces: Vec<crate::domain::FaceTemplate>,
    pub(crate) feedback: Vec<FeedbackEvent>,
    pub(crate) audit_events: Vec<AuditEvent>,
    pub(crate) entitlement_cache: Option<EntitlementCache>,
    pub(crate) vaults: Vec<Vault>,
    pub(crate) devices: Vec<DeviceIdentity>,
    pub(crate) vault_members: Vec<VaultMember>,
    pub(crate) blob_records: Vec<BlobRecord>,
    pub(crate) blob_chunks: Vec<BlobChunk>,
    pub(crate) blob_replicas: Vec<BlobReplica>,
    pub(crate) sync_transfers: Vec<SyncTransfer>,
    pub(crate) sync_conflicts: Vec<SyncConflict>,
    pub(crate) vault_invites: Vec<VaultInvite>,
    pub(crate) vault_key_envelopes: Vec<VaultKeyEnvelope>,
    pub(crate) relay_endpoints: Vec<RelayEndpoint>,
    pub(crate) capability_grants: Vec<CapabilityGrant>,
    pub(crate) pairings: Vec<DevicePairing>,
    pub(crate) sync_sessions: Vec<SyncSession>,
    pub(crate) mobile_sessions: Vec<MobileSession>,
    pub(crate) mobile_uploads: Vec<MobileUpload>,
    pub(crate) import_sessions: Vec<ImportSession>,
    pub(crate) jobs: Vec<JobRecord>,
    pub(crate) job_logs: Vec<JobLog>,
    pub(crate) corrections: Vec<CorrectionRecord>,
    pub(crate) ocr_blocks: Vec<OcrBlock>,
    pub(crate) scene_tags: Vec<SceneTag>,
}

#[derive(Debug, Clone)]
struct DuplicateReviewAccumulator {
    asset_id: Uuid,
    media_kind: MediaKind,
    original_bytes: u64,
    duplicate_candidates: usize,
    protected_bytes: u64,
    first_seen_at: DateTime<Utc>,
    last_seen_at: DateTime<Utc>,
    import_session_ids: BTreeSet<Uuid>,
    source_kinds: BTreeSet<String>,
}

impl From<PersistedLibraryState> for LibraryState {
    fn from(state: PersistedLibraryState) -> Self {
        Self {
            library_settings: state.library_settings,
            watch_folders: state.watch_folders,
            assets: state.assets,
            file_entries: state.file_entries,
            albums: state.albums,
            smart_folders: state.smart_folders,
            people: state.people,
            places: state.places,
            events: state.events,
            faces: state.faces,
            feedback: state.feedback,
            audit_events: state.audit_events,
            entitlement_cache: state.entitlement_cache,
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
            mobile_sessions: state.mobile_sessions,
            mobile_uploads: state.mobile_uploads,
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
    pub(crate) fn to_persisted(&self) -> PersistedLibraryState {
        PersistedLibraryState {
            library_settings: self.library_settings.clone(),
            watch_folders: self.watch_folders.clone(),
            assets: self.assets.clone(),
            file_entries: self.file_entries.clone(),
            albums: self.albums.clone(),
            smart_folders: self.smart_folders.clone(),
            people: self.people.clone(),
            places: self.places.clone(),
            events: self.events.clone(),
            faces: self.faces.clone(),
            feedback: self.feedback.clone(),
            audit_events: self.audit_events.clone(),
            entitlement_cache: self.entitlement_cache.clone(),
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
            mobile_sessions: self.mobile_sessions.clone(),
            mobile_uploads: self.mobile_uploads.clone(),
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

#[derive(Debug, Clone, Copy)]
pub enum ByteRangeRequest {
    Start { start: u64, end: Option<u64> },
    Suffix { length: u64 },
}

#[derive(Debug, Clone)]
pub struct OriginalBytesRange {
    pub mime_type: String,
    pub total_bytes: u64,
    pub start: u64,
    pub end: u64,
    pub bytes: Vec<u8>,
}

#[derive(Clone)]
pub struct GalleryService {
    config: AppConfig,
    pub storage: StorageBootstrapReport,
    state: Arc<RwLock<LibraryState>>,
    sync_runtime: Arc<sync_transport::SyncRuntime>,
}

impl GalleryService {
    pub fn new(config: AppConfig) -> Result<Self, ServiceError> {
        if !config.developer_mode
            && !config.allow_remote_mobile
            && !model_registry::is_loopback_host(&config.bind_host)
        {
            return Err(ServiceError::Invalid(format!(
                "refusing to bind daemon to non-loopback host {} without explicit developer mode or PRIVATE_GALLERY_ALLOW_REMOTE_MOBILE=1",
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
        let mut startup_changed = ensure_distributed_defaults(&mut state);
        startup_changed |= refresh_blob_records(&config, &mut state);
        startup_changed |= ensure_file_namespace_defaults(&mut state);
        if compacted_history || startup_changed {
            storage::save_state(&storage, &state.to_persisted())
                .map_err(|err| ServiceError::Storage(err.to_string()))?;
        }

        let state = Arc::new(RwLock::new(state));
        let sync_runtime = Arc::new(sync_transport::SyncRuntime::new(
            config.clone(),
            storage.clone(),
            Arc::clone(&state),
        ));

        Ok(Self {
            config,
            storage,
            state,
            sync_runtime,
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
        let original_storage_policy = request
            .original_storage_policy
            .or_else(|| {
                state
                    .library_settings
                    .as_ref()
                    .map(|settings| settings.original_storage_policy)
            })
            .unwrap_or_default();
        let settings = LibrarySettings {
            library_root: request.library_root,
            default_import_mode: request.default_import_mode,
            original_storage_policy,
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
        ensure_file_namespace_defaults(&mut state);
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
        let mut state = self.state.write().await;
        ensure_distributed_defaults(&mut state);
        if let Some(vault_id) = request.vault_id
            && !state.vaults.iter().any(|vault| vault.id == vault_id)
        {
            return Err(ServiceError::NotFound(format!("vault {vault_id}")));
        }

        let pairing = DevicePairing {
            id: Uuid::new_v4(),
            device_name: request.device_name,
            platform: request.platform,
            vault_id: request.vault_id,
            pairing_token: Uuid::new_v4().to_string(),
            created_at: Utc::now(),
            expires_at: Utc::now() + chrono::Duration::minutes(10),
            approved_at: None,
        };

        state.pairings.push(pairing.clone());
        let (actor_device_id, actor_label) = local_actor(&state);
        push_audit_event(
            &mut state,
            "pairing.create",
            ("pairing", Some(pairing.id)),
            (actor_device_id, actor_label),
            format!("Created pairing invite for {}", pairing.device_name),
            json!({
                "pairing_id": pairing.id,
                "vault_id": pairing.vault_id,
                "platform": pairing.platform,
                "expires_at": pairing.expires_at,
            }),
        );
        self.persist_locked_state(&state)?;
        Ok(pairing)
    }

    pub async fn pair_mobile_device(
        &self,
        request: MobilePairRequest,
    ) -> Result<MobilePairResponse, ServiceError> {
        let pairing_token = request.pairing_token.trim();
        let display_name = request.device_name.trim();
        let platform = request.platform.trim();
        if pairing_token.is_empty() || display_name.is_empty() || platform.is_empty() {
            return Err(ServiceError::Invalid(
                "pairing_token, device_name, and platform are required".to_string(),
            ));
        }

        let mut state = self.state.write().await;
        ensure_distributed_defaults(&mut state);
        let now = Utc::now();
        let pairing_index = state
            .pairings
            .iter()
            .position(|pairing| pairing.pairing_token == pairing_token)
            .ok_or_else(|| ServiceError::Invalid("pairing token was not found".to_string()))?;
        if state.pairings[pairing_index].expires_at < now {
            return Err(ServiceError::Invalid(
                "pairing token has expired".to_string(),
            ));
        }
        if state.pairings[pairing_index].approved_at.is_some() {
            return Err(ServiceError::Invalid(
                "pairing token has already been used".to_string(),
            ));
        }

        let pairing_vault_id = state.pairings[pairing_index].vault_id;
        if let (Some(bound_vault_id), Some(requested_vault_id)) =
            (pairing_vault_id, request.vault_id)
            && bound_vault_id != requested_vault_id
        {
            return Err(ServiceError::Invalid(
                "pairing token does not belong to the requested vault".to_string(),
            ));
        }

        let vault_id = pairing_vault_id
            .or(request.vault_id)
            .or_else(|| state.vaults.first().map(|vault| vault.id))
            .ok_or_else(|| ServiceError::NotFound("vault".to_string()))?;
        if !state.vaults.iter().any(|vault| vault.id == vault_id) {
            return Err(ServiceError::NotFound(format!("vault {vault_id}")));
        }

        let mut storage_profile = request.storage_profile.unwrap_or_else(|| {
            let mut profile = DeviceStorageProfile {
                battery_powered: true,
                reserved_bytes: 2 * 1024 * 1024 * 1024,
                ..DeviceStorageProfile::default()
            };
            profile.accepts_storage = false;
            profile
        });
        storage_profile.device_id = None;
        storage_profile.battery_powered = true;
        if storage_profile.accepts_storage && storage_profile.reserved_bytes == 0 {
            storage_profile.reserved_bytes = 2 * 1024 * 1024 * 1024;
        }
        let device = build_device_identity(
            None,
            display_name.to_string(),
            platform.to_string(),
            Some(format!("mobile-device-key-{}", Uuid::new_v4())),
            Some(DeviceTrustLevel::Trusted),
            Some(storage_profile),
        )?;
        let device =
            add_device_to_state(&mut state, device, DeviceRole::Contributor, Some(vault_id))?;
        state.pairings[pairing_index].approved_at = Some(now);

        let bearer_token = new_mobile_bearer_token();
        let session = MobileSession {
            id: Uuid::new_v4(),
            device_id: device.id,
            vault_id,
            token_hash: hash_mobile_token(&bearer_token),
            display_name: device.display_name.clone(),
            platform: device.platform.clone(),
            created_at: now,
            expires_at: now + chrono::Duration::days(MOBILE_SESSION_TTL_DAYS),
            last_seen_at: Some(now),
            revoked_at: None,
        };
        state.mobile_sessions.push(session.clone());
        push_audit_event(
            &mut state,
            "device.mobile_pair",
            ("device", Some(device.id)),
            (Some(device.id), Some(device.display_name.clone())),
            format!("Paired mobile device {}", device.display_name),
            json!({
                "device_id": device.id,
                "session_id": session.id,
                "vault_id": vault_id,
                "platform": device.platform,
                "accepts_storage": device.storage_profile.accepts_storage,
            }),
        );
        self.persist_locked_state(&state)?;

        Ok(MobilePairResponse {
            session,
            device,
            bearer_token,
            detail: "mobile device paired for local vault sync".to_string(),
        })
    }

    pub async fn mobile_session_status(
        &self,
        bearer_token: &str,
    ) -> Result<MobileSession, ServiceError> {
        let mut state = self.state.write().await;
        let session = active_mobile_session_from_state(&mut state, bearer_token)?;
        self.persist_locked_state(&state)?;
        Ok(session)
    }

    pub async fn refresh_mobile_session(
        &self,
        bearer_token: &str,
    ) -> Result<MobileSessionRefreshResponse, ServiceError> {
        let mut state = self.state.write().await;
        let session = active_mobile_session_from_state(&mut state, bearer_token)?;
        let now = Utc::now();
        let new_bearer_token = new_mobile_bearer_token();
        let refreshed = MobileSession {
            id: Uuid::new_v4(),
            device_id: session.device_id,
            vault_id: session.vault_id,
            token_hash: hash_mobile_token(&new_bearer_token),
            display_name: session.display_name.clone(),
            platform: session.platform.clone(),
            created_at: now,
            expires_at: now + chrono::Duration::days(MOBILE_SESSION_TTL_DAYS),
            last_seen_at: Some(now),
            revoked_at: None,
        };
        let previous = state
            .mobile_sessions
            .iter_mut()
            .find(|candidate| candidate.id == session.id)
            .ok_or_else(|| ServiceError::NotFound(format!("mobile session {}", session.id)))?;
        previous.revoked_at = Some(now);
        previous.last_seen_at = Some(now);
        state.mobile_sessions.push(refreshed.clone());
        self.persist_locked_state(&state)?;
        Ok(MobileSessionRefreshResponse {
            session: refreshed,
            bearer_token: new_bearer_token,
            previous_session_id: session.id,
            detail: "mobile session refreshed; replace the stored bearer token immediately"
                .to_string(),
        })
    }

    pub async fn mobile_sessions(
        &self,
        bearer_token: &str,
    ) -> Result<Vec<MobileSession>, ServiceError> {
        let mut state = self.state.write().await;
        let session = active_mobile_session_from_state(&mut state, bearer_token)?;
        let now = Utc::now();
        let role = mobile_session_role(&state, &session)?;
        let can_view_all_sessions = matches!(role, DeviceRole::Admin);
        let mut sessions = state
            .mobile_sessions
            .iter()
            .filter(|candidate| {
                candidate.vault_id == session.vault_id
                    && candidate.revoked_at.is_none()
                    && candidate.expires_at >= now
                    && (can_view_all_sessions || candidate.device_id == session.device_id)
            })
            .cloned()
            .collect::<Vec<_>>();
        sessions.sort_by_key(|session| std::cmp::Reverse(session.last_seen_at));
        self.persist_locked_state(&state)?;
        Ok(sessions)
    }

    pub async fn revoke_current_mobile_session(
        &self,
        bearer_token: &str,
    ) -> Result<MobileSession, ServiceError> {
        let mut state = self.state.write().await;
        let session = active_mobile_session_from_state(&mut state, bearer_token)?;
        let now = Utc::now();
        let updated = state
            .mobile_sessions
            .iter_mut()
            .find(|candidate| candidate.id == session.id)
            .ok_or_else(|| ServiceError::NotFound(format!("mobile session {}", session.id)))?;
        updated.revoked_at = Some(now);
        updated.last_seen_at = Some(now);
        let updated = updated.clone();
        self.persist_locked_state(&state)?;
        Ok(updated)
    }

    pub async fn revoke_mobile_device_sessions(
        &self,
        bearer_token: &str,
        device_id: Uuid,
    ) -> Result<Vec<MobileSession>, ServiceError> {
        let mut state = self.state.write().await;
        let session = active_mobile_session_from_state(&mut state, bearer_token)?;
        let requester_can_manage =
            matches!(mobile_session_role(&state, &session)?, DeviceRole::Admin);
        if session.device_id != device_id && !requester_can_manage {
            return Err(ServiceError::Invalid(
                "mobile devices can only revoke their own sessions unless they are vault admins"
                    .to_string(),
            ));
        }
        let now = Utc::now();
        let mut revoked = Vec::new();
        for candidate in state.mobile_sessions.iter_mut().filter(|candidate| {
            candidate.vault_id == session.vault_id
                && candidate.device_id == device_id
                && candidate.revoked_at.is_none()
        }) {
            candidate.revoked_at = Some(now);
            candidate.last_seen_at = Some(now);
            revoked.push(candidate.clone());
        }
        if revoked.is_empty() {
            return Err(ServiceError::NotFound(format!(
                "active mobile sessions for device {device_id}"
            )));
        }
        self.persist_locked_state(&state)?;
        Ok(revoked)
    }

    pub async fn reserve_mobile_upload(
        &self,
        bearer_token: &str,
        request: MobileUploadRequest,
    ) -> Result<MobileUpload, ServiceError> {
        let original_filename = sanitize_mobile_filename(&request.original_filename)?;
        if request.bytes == 0 {
            return Err(ServiceError::Invalid(
                "mobile upload must include at least one byte".to_string(),
            ));
        }
        if request.bytes > MOBILE_UPLOAD_MAX_BYTES {
            return Err(ServiceError::Invalid(format!(
                "mobile upload exceeds beta limit of {} bytes",
                MOBILE_UPLOAD_MAX_BYTES
            )));
        }
        let mime_type = if request.mime_type.trim().is_empty() {
            "application/octet-stream".to_string()
        } else {
            request.mime_type.trim().to_string()
        };
        let content_hash = request
            .content_hash
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToString::to_string);

        let mut state = self.state.write().await;
        let session = active_mobile_session_from_state(&mut state, bearer_token)?;
        ensure_mobile_can_contribute(&state, &session, "upload originals")?;
        let now = Utc::now();
        let upload = MobileUpload {
            id: Uuid::new_v4(),
            session_id: session.id,
            device_id: session.device_id,
            vault_id: session.vault_id,
            asset_id: None,
            original_filename,
            media_kind: request.media_kind,
            mime_type,
            bytes_total: request.bytes,
            bytes_received: 0,
            content_hash,
            captured_at: request.captured_at,
            place_hint: request
                .place_hint
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToString::to_string),
            status: MobileUploadStatus::Pending,
            error_detail: None,
            created_at: now,
            updated_at: now,
        };
        state.mobile_uploads.push(upload.clone());
        self.persist_locked_state(&state)?;
        Ok(upload)
    }

    pub async fn receive_mobile_upload(
        &self,
        bearer_token: &str,
        upload_id: Uuid,
        bytes: Vec<u8>,
    ) -> Result<MobileUpload, ServiceError> {
        if bytes.len() as u64 > MOBILE_UPLOAD_MAX_BYTES {
            return Err(ServiceError::Invalid(format!(
                "mobile upload exceeds beta limit of {} bytes",
                MOBILE_UPLOAD_MAX_BYTES
            )));
        }
        let mut state = self.state.write().await;
        let session = active_mobile_session_from_state(&mut state, bearer_token)?;
        ensure_mobile_can_contribute(&state, &session, "upload originals")?;
        let upload_index = mobile_upload_index_for_session(&state, &session, upload_id)?;
        let upload = state.mobile_uploads[upload_index].clone();
        if upload.status == MobileUploadStatus::Completed {
            self.persist_locked_state(&state)?;
            return Ok(upload);
        }
        ensure_mobile_upload_accepts_bytes(&upload)?;
        if bytes.len() as u64 != upload.bytes_total {
            let detail = format!(
                "upload byte count mismatch: expected {}, received {}",
                upload.bytes_total,
                bytes.len()
            );
            state.mobile_uploads[upload_index].status = MobileUploadStatus::Failed;
            state.mobile_uploads[upload_index].error_detail = Some(detail.clone());
            state.mobile_uploads[upload_index].updated_at = Utc::now();
            self.persist_locked_state(&state)?;
            return Err(ServiceError::Invalid(detail));
        }

        let now = Utc::now();
        state.mobile_uploads[upload_index].status = MobileUploadStatus::Running;
        state.mobile_uploads[upload_index].bytes_received = bytes.len() as u64;
        state.mobile_uploads[upload_index].updated_at = now;
        state.mobile_uploads[upload_index].error_detail = None;
        let upload = state.mobile_uploads[upload_index].clone();

        let upload_dir = mobile_upload_dir(&self.config, upload.id);
        fs::create_dir_all(&upload_dir).map_err(|err| ServiceError::Io(err.to_string()))?;
        let upload_path = mobile_upload_path(&self.config, &upload);
        fs::write(&upload_path, &bytes).map_err(|err| {
            ServiceError::Io(format!("failed to write mobile upload staging file: {err}"))
        })?;

        let completed = self.complete_mobile_upload_from_staging(
            &mut state,
            upload_index,
            &upload_path,
            &upload_dir,
        )?;
        self.persist_locked_state(&state)?;
        Ok(completed)
    }

    pub async fn mobile_upload_status(
        &self,
        bearer_token: &str,
        upload_id: Uuid,
    ) -> Result<MobileUpload, ServiceError> {
        let mut state = self.state.write().await;
        let session = active_mobile_session_from_state(&mut state, bearer_token)?;
        let upload_index = mobile_upload_index_for_session(&state, &session, upload_id)?;
        let upload_path = mobile_upload_path(&self.config, &state.mobile_uploads[upload_index]);
        reconcile_mobile_upload_progress(&mut state.mobile_uploads[upload_index], &upload_path)?;
        let upload = state.mobile_uploads[upload_index].clone();
        self.persist_locked_state(&state)?;
        Ok(upload)
    }

    pub async fn cancel_mobile_upload(
        &self,
        bearer_token: &str,
        upload_id: Uuid,
    ) -> Result<MobileUpload, ServiceError> {
        let mut state = self.state.write().await;
        let session = active_mobile_session_from_state(&mut state, bearer_token)?;
        let upload_index = mobile_upload_index_for_session(&state, &session, upload_id)?;
        let upload_path = mobile_upload_path(&self.config, &state.mobile_uploads[upload_index]);
        let upload_dir = mobile_upload_dir(&self.config, upload_id);
        reconcile_mobile_upload_progress(&mut state.mobile_uploads[upload_index], &upload_path)?;
        let upload = state.mobile_uploads[upload_index].clone();
        if upload.status == MobileUploadStatus::Completed {
            return Err(ServiceError::Invalid(
                "completed mobile uploads cannot be canceled".to_string(),
            ));
        }
        if upload.status != MobileUploadStatus::Canceled {
            state.mobile_uploads[upload_index].status = MobileUploadStatus::Canceled;
            state.mobile_uploads[upload_index].error_detail =
                Some("canceled by paired mobile device".to_string());
            state.mobile_uploads[upload_index].updated_at = Utc::now();
        }
        let _ = fs::remove_dir_all(upload_dir);
        let upload = state.mobile_uploads[upload_index].clone();
        self.persist_locked_state(&state)?;
        Ok(upload)
    }

    pub async fn receive_mobile_upload_chunk(
        &self,
        bearer_token: &str,
        upload_id: Uuid,
        offset: u64,
        bytes: Vec<u8>,
    ) -> Result<MobileUpload, ServiceError> {
        if bytes.is_empty() {
            return Err(ServiceError::Invalid(
                "mobile upload chunk must include at least one byte".to_string(),
            ));
        }
        if bytes.len() as u64 > MOBILE_UPLOAD_CHUNK_MAX_BYTES {
            return Err(ServiceError::Invalid(format!(
                "mobile upload chunk exceeds beta limit of {} bytes",
                MOBILE_UPLOAD_CHUNK_MAX_BYTES
            )));
        }

        let mut state = self.state.write().await;
        let session = active_mobile_session_from_state(&mut state, bearer_token)?;
        ensure_mobile_can_contribute(&state, &session, "upload originals")?;
        let upload_index = mobile_upload_index_for_session(&state, &session, upload_id)?;
        let upload_path = mobile_upload_path(&self.config, &state.mobile_uploads[upload_index]);
        reconcile_mobile_upload_progress(&mut state.mobile_uploads[upload_index], &upload_path)?;
        let upload = state.mobile_uploads[upload_index].clone();
        if upload.status == MobileUploadStatus::Completed {
            self.persist_locked_state(&state)?;
            return Ok(upload);
        }
        ensure_mobile_upload_accepts_bytes(&upload)?;

        let chunk_len = bytes.len() as u64;
        let end_offset = offset.checked_add(chunk_len).ok_or_else(|| {
            ServiceError::Invalid("mobile upload chunk offset overflowed".to_string())
        })?;
        if end_offset > upload.bytes_total {
            return Err(ServiceError::Invalid(format!(
                "mobile upload chunk exceeds reserved size: reserved {}, requested end {}",
                upload.bytes_total, end_offset
            )));
        }
        if offset < upload.bytes_received {
            if end_offset == upload.bytes_received {
                self.persist_locked_state(&state)?;
                return Ok(upload);
            }
            return Err(ServiceError::Invalid(format!(
                "mobile upload chunk overlaps already received bytes; resume from {}",
                upload.bytes_received
            )));
        }
        if offset != upload.bytes_received {
            return Err(ServiceError::Invalid(format!(
                "mobile upload offset mismatch: expected {}, received {}",
                upload.bytes_received, offset
            )));
        }

        let upload_dir = mobile_upload_dir(&self.config, upload.id);
        fs::create_dir_all(&upload_dir).map_err(|err| ServiceError::Io(err.to_string()))?;
        append_mobile_upload_chunk(&upload_path, offset, &bytes)?;

        let now = Utc::now();
        state.mobile_uploads[upload_index].status = MobileUploadStatus::Running;
        state.mobile_uploads[upload_index].bytes_received = end_offset;
        state.mobile_uploads[upload_index].error_detail = None;
        state.mobile_uploads[upload_index].updated_at = now;
        let upload = state.mobile_uploads[upload_index].clone();
        self.persist_locked_state(&state)?;
        Ok(upload)
    }

    pub async fn complete_mobile_upload(
        &self,
        bearer_token: &str,
        upload_id: Uuid,
    ) -> Result<MobileUpload, ServiceError> {
        let mut state = self.state.write().await;
        let session = active_mobile_session_from_state(&mut state, bearer_token)?;
        ensure_mobile_can_contribute(&state, &session, "upload originals")?;
        let upload_index = mobile_upload_index_for_session(&state, &session, upload_id)?;
        let upload = state.mobile_uploads[upload_index].clone();
        if upload.status == MobileUploadStatus::Completed {
            self.persist_locked_state(&state)?;
            return Ok(upload);
        }
        ensure_mobile_upload_accepts_bytes(&upload)?;

        let upload_dir = mobile_upload_dir(&self.config, upload.id);
        let upload_path = mobile_upload_path(&self.config, &upload);
        reconcile_mobile_upload_progress(&mut state.mobile_uploads[upload_index], &upload_path)?;
        let received = state.mobile_uploads[upload_index].bytes_received;
        if received != upload.bytes_total {
            let detail = format!(
                "mobile upload is incomplete: expected {}, received {}",
                upload.bytes_total, received
            );
            state.mobile_uploads[upload_index].status = if received == 0 {
                MobileUploadStatus::Pending
            } else {
                MobileUploadStatus::Running
            };
            state.mobile_uploads[upload_index].error_detail = Some(detail.clone());
            state.mobile_uploads[upload_index].updated_at = Utc::now();
            self.persist_locked_state(&state)?;
            return Err(ServiceError::Invalid(detail));
        }

        let completed = self.complete_mobile_upload_from_staging(
            &mut state,
            upload_index,
            &upload_path,
            &upload_dir,
        )?;
        self.persist_locked_state(&state)?;
        Ok(completed)
    }

    fn complete_mobile_upload_from_staging(
        &self,
        state: &mut LibraryState,
        upload_index: usize,
        upload_path: &Path,
        upload_dir: &Path,
    ) -> Result<MobileUpload, ServiceError> {
        let upload = state.mobile_uploads[upload_index].clone();
        let actual_len = fs::metadata(upload_path)
            .map_err(|err| {
                ServiceError::Io(format!("failed to read mobile upload staging file: {err}"))
            })?
            .len();
        if actual_len != upload.bytes_total {
            let detail = format!(
                "upload byte count mismatch: expected {}, received {}",
                upload.bytes_total, actual_len
            );
            state.mobile_uploads[upload_index].status = if actual_len == 0 {
                MobileUploadStatus::Pending
            } else {
                MobileUploadStatus::Running
            };
            state.mobile_uploads[upload_index].bytes_received = actual_len;
            state.mobile_uploads[upload_index].error_detail = Some(detail.clone());
            state.mobile_uploads[upload_index].updated_at = Utc::now();
            self.persist_locked_state(state)?;
            return Err(ServiceError::Invalid(detail));
        }

        let actual_hash = imports::derive_content_hash_from_file(upload_path)
            .map_err(|err| ServiceError::Io(err.to_string()))?;
        if let Some(expected_hash) = upload.content_hash.as_deref()
            && !expected_hash.eq_ignore_ascii_case(&actual_hash)
        {
            let detail = "mobile upload content_hash did not match received bytes".to_string();
            state.mobile_uploads[upload_index].status = MobileUploadStatus::Failed;
            state.mobile_uploads[upload_index].content_hash = Some(actual_hash);
            state.mobile_uploads[upload_index].error_detail = Some(detail.clone());
            state.mobile_uploads[upload_index].updated_at = Utc::now();
            let _ = fs::remove_dir_all(upload_dir);
            self.persist_locked_state(state)?;
            return Err(ServiceError::Invalid(detail));
        }

        if let Some(existing) = state
            .assets
            .iter()
            .find(|asset| asset.content_hash == actual_hash)
            .cloned()
        {
            state.mobile_uploads[upload_index].status = MobileUploadStatus::Completed;
            state.mobile_uploads[upload_index].asset_id = Some(existing.id);
            state.mobile_uploads[upload_index].content_hash = Some(actual_hash);
            state.mobile_uploads[upload_index].error_detail = None;
            state.mobile_uploads[upload_index].updated_at = Utc::now();
            let completed = state.mobile_uploads[upload_index].clone();
            let _ = fs::remove_dir_all(upload_dir);
            return Ok(completed);
        }

        let library_root = effective_library_root(state, &self.config);
        let library_root_path = PathBuf::from(&library_root);
        storage::ensure_library_layout(&library_root_path)
            .map_err(|err| ServiceError::Storage(err.to_string()))?;
        let now = Utc::now();
        let captured_at = upload.captured_at.unwrap_or(now);
        let (mut asset, mut job) = imports::build_imported_asset(ImportAssetRequest {
            source_path: upload_path.to_string_lossy().to_string(),
            original_filename: upload.original_filename.clone(),
            media_kind: upload.media_kind,
            mime_type: upload.mime_type.clone(),
            bytes: upload.bytes_total,
            captured_at: Some(captured_at),
            place_hint: upload.place_hint.clone(),
            import_mode: Some(ImportMode::Copy),
            content_hash: Some(actual_hash.clone()),
        });
        let extracted = metadata::extract_media_metadata(upload_path, &[], asset.captured_at);
        asset.captured_at = extracted.captured_at;
        if asset.place_hint.is_none() {
            asset.place_hint = metadata::coarse_place_label(&extracted);
        }
        asset.metadata = Some(extracted.into_asset_metadata(asset.id));

        let destination = library_root_path.join(&asset.relative_original_path);
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent).map_err(|err| ServiceError::Io(err.to_string()))?;
        }
        fs::copy(upload_path, &destination).map_err(|err| ServiceError::Io(err.to_string()))?;
        asset.is_available = destination.exists();

        job.status = JobStatus::Completed;
        job.progress = 100;
        job.started_at = Some(Utc::now());
        job.completed_at = Some(Utc::now());
        job.detail = Some(format!(
            "imported mobile upload {}",
            asset.original_filename
        ));

        let asset_id = asset.id;
        state.assets.push(asset);
        state.jobs.insert(0, job);
        state.mobile_uploads[upload_index].status = MobileUploadStatus::Completed;
        state.mobile_uploads[upload_index].asset_id = Some(asset_id);
        state.mobile_uploads[upload_index].content_hash = Some(actual_hash);
        state.mobile_uploads[upload_index].error_detail = None;
        state.mobile_uploads[upload_index].updated_at = Utc::now();
        refresh_derived_views(state);
        ensure_distributed_defaults(state);
        refresh_blob_records(&self.config, state);
        ensure_file_namespace_defaults(state);
        if let Some(entry) = state
            .file_entries
            .iter_mut()
            .find(|entry| entry.vault_id == upload.vault_id && entry.asset_id == Some(asset_id))
        {
            entry.origin_device_id = Some(upload.device_id);
            entry.updated_at = Utc::now();
        }
        let completed = state.mobile_uploads[upload_index].clone();
        let _ = fs::remove_dir_all(upload_dir);
        Ok(completed)
    }

    pub async fn mobile_assets(
        &self,
        bearer_token: &str,
    ) -> Result<Vec<MobileAssetSummary>, ServiceError> {
        let mut state = self.state.write().await;
        let session = active_mobile_session_from_state(&mut state, bearer_token)?;
        ensure_mobile_can_browse(&state, &session)?;
        ensure_distributed_defaults(&mut state);
        refresh_blob_records(&self.config, &mut state);
        let library_root = PathBuf::from(effective_library_root(&state, &self.config));
        let summaries = state
            .assets
            .iter()
            .filter(|asset| {
                state.blob_records.iter().any(|blob| {
                    blob.asset_id == asset.id
                        && blob.vault_id == session.vault_id
                        && blob.tombstoned_at.is_none()
                })
            })
            .map(|asset| MobileAssetSummary {
                asset_id: asset.id,
                original_filename: asset.original_filename.clone(),
                media_kind: asset.media_kind.clone(),
                mime_type: asset.mime_type.clone(),
                bytes: asset.bytes,
                content_hash: asset.content_hash.clone(),
                captured_at: asset.captured_at,
                available: asset.is_available
                    || state.blob_records.iter().any(|blob| {
                        blob.asset_id == asset.id
                            && blob.vault_id == session.vault_id
                            && blob.tombstoned_at.is_none()
                            && encrypted_chunks_available(&state, blob.id, &library_root)
                    }),
            })
            .collect::<Vec<_>>();
        self.persist_locked_state(&state)?;
        Ok(summaries)
    }

    pub async fn mobile_workspace(
        &self,
        bearer_token: &str,
    ) -> Result<MobileWorkspaceResponse, ServiceError> {
        let runtime = self.sync_runtime.status().await;
        let mut state = self.state.write().await;
        let session = active_mobile_session_from_state(&mut state, bearer_token)?;
        ensure_distributed_defaults(&mut state);
        refresh_blob_records(&self.config, &mut state);
        let role = mobile_session_role(&state, &session)?;

        let can_browse = mobile_role_can_browse(&role);
        let visible_asset_ids = if can_browse {
            asset_ids_for_vault(&state, session.vault_id)
        } else {
            BTreeSet::new()
        };
        let visible_assets = state
            .assets
            .iter()
            .filter(|asset| visible_asset_ids.contains(&asset.id))
            .cloned()
            .collect::<Vec<_>>();
        let timeline =
            timeline_response_for_assets(visible_assets, Some(500), Some(120), None, false);
        let albums = filter_albums_for_assets(&state.albums, &visible_asset_ids);
        let people = filter_people_for_assets(&state.people, &visible_asset_ids);
        let places = filter_places_for_assets(&state.places, &visible_asset_ids);
        let events = filter_events_for_assets(&state.events, &visible_asset_ids);
        let jobs = if can_browse {
            state.jobs.iter().take(25).cloned().collect::<Vec<_>>()
        } else {
            Vec::new()
        };
        let vault_status = build_vault_status(&state, session.vault_id)?;
        let devices = vault_status.devices.clone();
        let mobile_device_accepts_storage = devices
            .iter()
            .find(|device| device.id == session.device_id)
            .map(|device| device.storage_profile.accepts_storage)
            .unwrap_or(false);
        let now = Utc::now();
        let sessions = state
            .mobile_sessions
            .iter()
            .filter(|candidate| {
                candidate.vault_id == session.vault_id
                    && candidate.revoked_at.is_none()
                    && candidate.expires_at >= now
            })
            .cloned()
            .collect::<Vec<_>>();
        let sync_network = build_sync_network_status(&state, runtime);
        let capabilities = mobile_workspace_capabilities(&role, mobile_device_accepts_storage);
        self.persist_locked_state(&state)?;
        Ok(MobileWorkspaceResponse {
            session,
            sessions,
            timeline,
            albums,
            people,
            places,
            events,
            jobs,
            vault_status,
            devices,
            sync_network,
            capabilities,
        })
    }

    pub async fn update_mobile_storage_profile(
        &self,
        bearer_token: &str,
        request: MobileStorageProfileUpdateRequest,
    ) -> Result<DeviceIdentity, ServiceError> {
        let mut state = self.state.write().await;
        let session = active_mobile_session_from_state(&mut state, bearer_token)?;
        ensure_mobile_can_manage_storage(&state, &session)?;
        let device_index = state
            .devices
            .iter()
            .position(|device| device.id == session.device_id)
            .ok_or_else(|| ServiceError::NotFound(format!("device {}", session.device_id)))?;
        let mut storage_profile = request.storage_profile;
        storage_profile.device_id = Some(session.device_id);
        storage_profile.battery_powered = true;
        let accepts_storage = storage_profile.accepts_storage;
        state.devices[device_index].storage_profile = storage_profile;
        if !accepts_storage {
            for replica in state.blob_replicas.iter_mut().filter(|replica| {
                replica.device_id == session.device_id && replica.health == ReplicaHealth::Healthy
            }) {
                replica.health = ReplicaHealth::Offline;
            }
        }
        let device = state.devices[device_index].clone();
        self.persist_locked_state(&state)?;
        Ok(device)
    }

    pub async fn mobile_storage_plan(
        &self,
        bearer_token: &str,
    ) -> Result<MobileStoragePlan, ServiceError> {
        let mut state = self.state.write().await;
        let session = active_mobile_session_from_state(&mut state, bearer_token)?;
        ensure_distributed_defaults(&mut state);
        refresh_blob_records(&self.config, &mut state);
        let role = mobile_session_role(&state, &session)?;
        let library_root = PathBuf::from(effective_library_root(&state, &self.config));
        let device = state
            .devices
            .iter()
            .find(|device| device.id == session.device_id)
            .cloned()
            .ok_or_else(|| ServiceError::NotFound(format!("device {}", session.device_id)))?;
        let vault = state
            .vaults
            .iter()
            .find(|vault| vault.id == session.vault_id)
            .cloned()
            .ok_or_else(|| ServiceError::NotFound(format!("vault {}", session.vault_id)))?;

        if !mobile_role_can_manage_storage(&role) {
            self.persist_locked_state(&state)?;
            return Ok(MobileStoragePlan {
                generated_at: Utc::now(),
                device,
                assignments: Vec::new(),
                detail: format!(
                    "The {} role cannot receive encrypted vault chunks as a storage node.",
                    mobile_role_label(&role)
                ),
            });
        }
        if !device.storage_profile.accepts_storage {
            self.persist_locked_state(&state)?;
            return Ok(MobileStoragePlan {
                generated_at: Utc::now(),
                device,
                assignments: Vec::new(),
                detail:
                    "This phone is paired for browse/upload/download only. Enable storage contribution to receive encrypted chunks."
                        .to_string(),
            });
        }
        if !storage_policy_allows_device(&vault.storage_policy, &device)
            || vault
                .storage_policy
                .excluded_device_ids
                .contains(&device.id)
        {
            self.persist_locked_state(&state)?;
            return Ok(MobileStoragePlan {
                generated_at: Utc::now(),
                device,
                assignments: Vec::new(),
                detail:
                    "Storage contribution is paused by vault policy because this phone is low on battery, metered, or below the free-space reserve."
                        .to_string(),
            });
        }

        let required = vault.storage_policy.min_replicas.max(1) as usize;
        let source_device = local_device_id(&state);
        let now = Utc::now();
        let mut assignments = Vec::new();
        let candidate_blobs = state
            .blob_records
            .iter()
            .filter(|blob| blob.vault_id == session.vault_id && blob.tombstoned_at.is_none())
            .cloned()
            .collect::<Vec<_>>();
        for blob in candidate_blobs {
            if assignments.len() >= 25 {
                break;
            }
            if state.blob_replicas.iter().any(|replica| {
                replica.blob_id == blob.id
                    && replica.device_id == session.device_id
                    && replica.health == ReplicaHealth::Healthy
            }) {
                continue;
            }
            let healthy_replica_count = state
                .blob_replicas
                .iter()
                .filter(|replica| {
                    replica.blob_id == blob.id
                        && replica.health == ReplicaHealth::Healthy
                        && device_is_active(&state.devices, replica.device_id)
                })
                .count();
            if healthy_replica_count >= required {
                continue;
            }
            if !encrypted_chunks_available(&state, blob.id, &library_root) {
                continue;
            }
            let transfer_id = if let Some(existing) = state.sync_transfers.iter().find(|transfer| {
                transfer.vault_id == blob.vault_id
                    && transfer.blob_id == blob.id
                    && transfer.from_device_id == source_device
                    && transfer.to_device_id == session.device_id
                    && matches!(
                        transfer.status,
                        SyncTransferStatus::Pending | SyncTransferStatus::Running
                    )
                    && transfer.resumable_until >= now
            }) {
                existing.id
            } else {
                let transfer = pending_transfer(
                    blob.vault_id,
                    blob.id,
                    source_device,
                    session.device_id,
                    blob.bytes,
                );
                let id = transfer.id;
                state.sync_transfers.push(transfer);
                id
            };
            let chunks = encrypted_chunk_descriptors_for_blob(&state, blob.id, transfer_id)?;
            assignments.push(MobileReplicaAssignment {
                transfer_id,
                vault_id: blob.vault_id,
                blob_id: blob.id,
                asset_id: blob.asset_id,
                encrypted_hash: blob.encrypted_hash.clone(),
                bytes_total: blob.bytes,
                chunks,
            });
        }
        self.persist_locked_state(&state)?;
        let detail = if assignments.is_empty() {
            "No encrypted chunks are currently assigned to this phone; the vault policy is already satisfied or local chunks are unavailable.".to_string()
        } else {
            format!(
                "{} encrypted blob replica assignment(s) are ready for this phone.",
                assignments.len()
            )
        };
        Ok(MobileStoragePlan {
            generated_at: Utc::now(),
            device,
            assignments,
            detail,
        })
    }

    pub async fn mobile_replica_chunk_bytes(
        &self,
        bearer_token: &str,
        blob_id: Uuid,
        chunk_index: u32,
    ) -> Result<Vec<u8>, ServiceError> {
        let mut state = self.state.write().await;
        let session = active_mobile_session_from_state(&mut state, bearer_token)?;
        ensure_mobile_storage_device(&state, &session)?;
        let blob = blob_for_mobile_session(&state, &session, blob_id)?.clone();
        let transfer_index =
            mobile_storage_transfer_index(&state, &session, blob.vault_id, blob.id, None, false)?;
        let chunk = chunk_for_blob(&state, blob.id, chunk_index)?.clone();
        let library_root = PathBuf::from(effective_library_root(&state, &self.config));
        let local_path = chunk.local_path.as_deref().ok_or_else(|| {
            ServiceError::Invalid(format!("chunk {} has no local encrypted path", chunk.id))
        })?;
        let bytes = fs::read(library_root.join(local_path))
            .map_err(|err| ServiceError::Io(format!("failed to read encrypted chunk: {err}")))?;
        verify_encrypted_chunk_bytes(&chunk, &bytes)?;
        let now = Utc::now();
        let transfer = &mut state.sync_transfers[transfer_index];
        transfer.status = SyncTransferStatus::Running;
        transfer.started_at = transfer.started_at.or(Some(now));
        transfer.updated_at = now;
        self.persist_locked_state(&state)?;
        Ok(bytes)
    }

    pub async fn report_mobile_replica(
        &self,
        bearer_token: &str,
        blob_id: Uuid,
        request: MobileReplicaReportRequest,
    ) -> Result<MobileReplicaReport, ServiceError> {
        let mut state = self.state.write().await;
        let session = active_mobile_session_from_state(&mut state, bearer_token)?;
        ensure_mobile_storage_device(&state, &session)?;
        let blob = blob_for_mobile_session(&state, &session, blob_id)?.clone();
        let expected_chunks =
            encrypted_chunk_descriptors_for_blob(&state, blob.id, request.transfer_id)?;
        if expected_chunks.len() != request.chunks.len() {
            return Err(ServiceError::Invalid(format!(
                "replica report must include {} chunk(s), got {}",
                expected_chunks.len(),
                request.chunks.len()
            )));
        }
        let library_root = PathBuf::from(effective_library_root(&state, &self.config));
        for expected in &expected_chunks {
            let Some(report) = request
                .chunks
                .iter()
                .find(|report| report.chunk_index == expected.chunk_index)
            else {
                return Err(ServiceError::Invalid(format!(
                    "replica report is missing chunk {}",
                    expected.chunk_index
                )));
            };
            if report.encrypted_hash != expected.encrypted_hash
                || report.encrypted_bytes != expected.encrypted_bytes
            {
                return Err(ServiceError::Invalid(format!(
                    "replica report for chunk {} did not match encrypted hash/size",
                    expected.chunk_index
                )));
            }
            let chunk = chunk_for_blob(&state, blob.id, expected.chunk_index)?;
            let expected_proof = mobile_replica_chunk_proof_from_local(
                &library_root,
                chunk,
                &expected.proof_challenge,
            )?;
            if report.proof != expected_proof {
                return Err(ServiceError::Invalid(format!(
                    "replica report for chunk {} did not prove possession",
                    expected.chunk_index
                )));
            }
        }
        let transfer_index = mobile_storage_transfer_index(
            &state,
            &session,
            blob.vault_id,
            blob.id,
            Some(request.transfer_id),
            true,
        )?;
        let now = Utc::now();
        let transfer = &mut state.sync_transfers[transfer_index];
        transfer.status = SyncTransferStatus::Completed;
        transfer.bytes_completed = blob.bytes;
        transfer.updated_at = now;
        transfer.started_at = transfer.started_at.or(Some(now));
        sync_transport::upsert_blob_replica(
            &mut state,
            blob.id,
            session.device_id,
            blob.bytes,
            Some(request.transfer_id),
        );
        let replica = state
            .blob_replicas
            .iter()
            .find(|replica| replica.blob_id == blob.id && replica.device_id == session.device_id)
            .cloned()
            .ok_or_else(|| ServiceError::NotFound("mobile replica".to_string()))?;
        self.persist_locked_state(&state)?;
        Ok(MobileReplicaReport {
            blob_id: blob.id,
            device_id: session.device_id,
            health: replica.health,
            bytes_present: replica.bytes_present,
            verified_at: replica.verified_at,
            transfer_id: request.transfer_id,
            detail: "phone reported encrypted chunk replica and the daemon verified the assignment hashes".to_string(),
        })
    }

    pub async fn restore_mobile_replica_chunk(
        &self,
        bearer_token: &str,
        blob_id: Uuid,
        chunk_index: u32,
        bytes: Vec<u8>,
    ) -> Result<MobileReplicaRestoreResult, ServiceError> {
        let mut state = self.state.write().await;
        let session = active_mobile_session_from_state(&mut state, bearer_token)?;
        ensure_mobile_storage_device(&state, &session)?;
        let blob = blob_for_mobile_session(&state, &session, blob_id)?.clone();
        if !state.blob_replicas.iter().any(|replica| {
            replica.blob_id == blob.id
                && replica.device_id == session.device_id
                && replica.health == ReplicaHealth::Healthy
        }) {
            return Err(ServiceError::Invalid(
                "this phone has not reported a healthy replica for the requested blob".to_string(),
            ));
        }
        let chunk = chunk_for_blob(&state, blob.id, chunk_index)?.clone();
        verify_encrypted_chunk_bytes(&chunk, &bytes)?;
        let local_path = chunk.local_path.as_deref().ok_or_else(|| {
            ServiceError::Invalid(format!("chunk {} has no local encrypted path", chunk.id))
        })?;
        let library_root = PathBuf::from(effective_library_root(&state, &self.config));
        let destination = library_root.join(local_path);
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent).map_err(|err| {
                ServiceError::Io(format!("failed to create encrypted chunk directory: {err}"))
            })?;
        }
        fs::write(&destination, &bytes).map_err(|err| {
            ServiceError::Io(format!(
                "failed to restore encrypted chunk from phone: {err}"
            ))
        })?;
        if encrypted_chunks_available(&state, blob.id, &library_root)
            && let Some(local_device) = local_device_id(&state)
        {
            sync_transport::upsert_blob_replica(
                &mut state,
                blob.id,
                local_device,
                blob.bytes,
                None,
            );
        }
        self.persist_locked_state(&state)?;
        Ok(MobileReplicaRestoreResult {
            blob_id: blob.id,
            chunk_index,
            encrypted_hash: chunk.encrypted_hash,
            encrypted_bytes: bytes.len() as u64,
            restored_local_chunk: true,
            detail: "encrypted chunk restored from phone storage and verified by hash".to_string(),
        })
    }

    pub async fn mobile_search(
        &self,
        bearer_token: &str,
        query: SearchQuery,
    ) -> Result<SearchResponse, ServiceError> {
        let mut state = self.state.write().await;
        let session = active_mobile_session_from_state(&mut state, bearer_token)?;
        ensure_mobile_can_search(&state, &session)?;
        let visible_asset_ids = asset_ids_for_vault(&state, session.vault_id);
        self.persist_locked_state(&state)?;
        drop(state);

        let mut response = self.search(query).await;
        response
            .assets
            .retain(|asset| visible_asset_ids.contains(&asset.id));
        response.people = filter_people_for_assets(&response.people, &visible_asset_ids);
        response.places = filter_places_for_assets(&response.places, &visible_asset_ids);
        response.events = filter_events_for_assets(&response.events, &visible_asset_ids);
        Ok(response)
    }

    pub async fn mobile_asset_availability(
        &self,
        bearer_token: &str,
        asset_id: Uuid,
    ) -> Result<AssetAvailability, ServiceError> {
        let mut state = self.state.write().await;
        let session = active_mobile_session_from_state(&mut state, bearer_token)?;
        ensure_mobile_can_browse(&state, &session)?;
        ensure_distributed_defaults(&mut state);
        refresh_blob_records(&self.config, &mut state);
        ensure_asset_belongs_to_vault(&state, session.vault_id, asset_id)?;
        let availability = build_asset_availability(&state, asset_id)?;
        self.persist_locked_state(&state)?;
        Ok(availability)
    }

    pub async fn update_mobile_asset_flags(
        &self,
        bearer_token: &str,
        asset_id: Uuid,
        request: UpdateAssetFlagsRequest,
    ) -> Result<Asset, ServiceError> {
        {
            let mut state = self.state.write().await;
            let session = active_mobile_session_from_state(&mut state, bearer_token)?;
            ensure_mobile_can_contribute(&state, &session, "update library curation")?;
            ensure_asset_belongs_to_vault(&state, session.vault_id, asset_id)?;
            self.persist_locked_state(&state)?;
        }
        self.update_asset_flags(asset_id, request).await
    }

    pub async fn update_mobile_asset_tags(
        &self,
        bearer_token: &str,
        asset_id: Uuid,
        request: UpdateAssetTagsRequest,
    ) -> Result<Asset, ServiceError> {
        {
            let mut state = self.state.write().await;
            let session = active_mobile_session_from_state(&mut state, bearer_token)?;
            ensure_mobile_can_contribute(&state, &session, "update library curation")?;
            ensure_asset_belongs_to_vault(&state, session.vault_id, asset_id)?;
            self.persist_locked_state(&state)?;
        }
        self.update_asset_tags(asset_id, request).await
    }

    pub async fn mobile_original_bytes(
        &self,
        bearer_token: &str,
        asset_id: Uuid,
    ) -> Result<(String, Vec<u8>), ServiceError> {
        {
            let mut state = self.state.write().await;
            let session = active_mobile_session_from_state(&mut state, bearer_token)?;
            ensure_mobile_can_download_originals(&state, &session)?;
            ensure_distributed_defaults(&mut state);
            refresh_blob_records(&self.config, &mut state);
            let belongs_to_session_vault = state.blob_records.iter().any(|blob| {
                blob.asset_id == asset_id
                    && blob.vault_id == session.vault_id
                    && blob.tombstoned_at.is_none()
            });
            if !belongs_to_session_vault {
                return Err(ServiceError::NotFound(format!("asset {asset_id}")));
            }
            self.persist_locked_state(&state)?;
        }
        self.asset_original_bytes(asset_id).await
    }

    pub async fn mobile_original_range_bytes(
        &self,
        bearer_token: &str,
        asset_id: Uuid,
        range: ByteRangeRequest,
    ) -> Result<OriginalBytesRange, ServiceError> {
        {
            let mut state = self.state.write().await;
            let session = active_mobile_session_from_state(&mut state, bearer_token)?;
            ensure_mobile_can_download_originals(&state, &session)?;
            ensure_distributed_defaults(&mut state);
            refresh_blob_records(&self.config, &mut state);
            let belongs_to_session_vault = state.blob_records.iter().any(|blob| {
                blob.asset_id == asset_id
                    && blob.vault_id == session.vault_id
                    && blob.tombstoned_at.is_none()
            });
            if !belongs_to_session_vault {
                return Err(ServiceError::NotFound(format!("asset {asset_id}")));
            }
            self.persist_locked_state(&state)?;
        }
        self.asset_original_range_bytes(asset_id, range).await
    }

    pub async fn mobile_preview_bytes(
        &self,
        bearer_token: &str,
        asset_id: Uuid,
    ) -> Result<(String, Vec<u8>), ServiceError> {
        {
            let mut state = self.state.write().await;
            let session = active_mobile_session_from_state(&mut state, bearer_token)?;
            ensure_mobile_can_download_originals(&state, &session)?;
            ensure_distributed_defaults(&mut state);
            refresh_blob_records(&self.config, &mut state);
            let belongs_to_session_vault = state.blob_records.iter().any(|blob| {
                blob.asset_id == asset_id
                    && blob.vault_id == session.vault_id
                    && blob.tombstoned_at.is_none()
            });
            if !belongs_to_session_vault {
                return Err(ServiceError::NotFound(format!("asset {asset_id}")));
            }
            self.persist_locked_state(&state)?;
        }
        self.asset_preview_bytes(asset_id).await
    }

    pub async fn asset_preview_bytes(
        &self,
        asset_id: Uuid,
    ) -> Result<(String, Vec<u8>), ServiceError> {
        let fallback_to_original = {
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
            let variant = asset
                .variants
                .iter()
                .find(|variant| variant.kind == VariantKind::Thumbnail)
                .or_else(|| {
                    asset
                        .variants
                        .iter()
                        .find(|variant| variant.kind == VariantKind::Preview)
                })
                .cloned();
            if let Some(variant) = variant {
                let path = library_root.join(&variant.relative_path);
                if path.is_file() {
                    return fs::read(&path)
                        .map(|bytes| (variant.mime_type, bytes))
                        .map_err(|err| ServiceError::Io(err.to_string()));
                }
            }
            self.persist_locked_state(&state)?;
            matches!(asset.media_kind, MediaKind::Photo)
        };
        if fallback_to_original {
            self.asset_original_bytes(asset_id).await
        } else {
            Err(ServiceError::NotFound(format!(
                "preview for asset {asset_id}"
            )))
        }
    }

    pub async fn file_tree(
        &self,
        vault_id: Option<Uuid>,
        include_trashed: bool,
    ) -> Result<VaultFileTreeResponse, ServiceError> {
        let mut state = self.state.write().await;
        ensure_distributed_defaults(&mut state);
        let mut changed = refresh_blob_records(&self.config, &mut state);
        changed |= ensure_file_namespace_defaults(&mut state);
        if let Some(vault_id) = vault_id {
            ensure_vault_exists(&state, vault_id)?;
        }
        let response = build_file_tree_response(&state, vault_id, include_trashed);
        if changed {
            self.persist_locked_state(&state)?;
        }
        Ok(response)
    }

    pub async fn mobile_file_tree(
        &self,
        bearer_token: &str,
        include_trashed: bool,
    ) -> Result<VaultFileTreeResponse, ServiceError> {
        let mut state = self.state.write().await;
        let session = active_mobile_session_from_state(&mut state, bearer_token)?;
        ensure_mobile_can_browse(&state, &session)?;
        ensure_distributed_defaults(&mut state);
        refresh_blob_records(&self.config, &mut state);
        ensure_file_namespace_defaults(&mut state);
        let response = build_file_tree_response(&state, Some(session.vault_id), include_trashed);
        self.persist_locked_state(&state)?;
        Ok(response)
    }

    pub async fn create_file_folder(
        &self,
        request: CreateFileFolderRequest,
    ) -> Result<VaultFileEntry, ServiceError> {
        let mut state = self.state.write().await;
        ensure_distributed_defaults(&mut state);
        refresh_blob_records(&self.config, &mut state);
        ensure_file_namespace_defaults(&mut state);
        let vault_id = request
            .vault_id
            .or_else(|| state.vaults.first().map(|vault| vault.id))
            .ok_or_else(|| ServiceError::NotFound("vault".to_string()))?;
        ensure_vault_exists(&state, vault_id)?;
        let parent_id = active_file_parent_or_root(&state, vault_id, request.parent_id)?;
        let name = sanitize_file_entry_name(&request.name)?;
        ensure_file_child_name_available(&state, vault_id, Some(parent_id), None, &name)?;

        let now = Utc::now();
        let entry = VaultFileEntry {
            id: Uuid::new_v4(),
            vault_id,
            parent_id: Some(parent_id),
            asset_id: None,
            name,
            kind: VaultFileKind::Folder,
            media_kind: None,
            mime_type: None,
            bytes: 0,
            content_hash: None,
            origin_device_id: local_device_id(&state),
            created_at: now,
            updated_at: now,
            trashed_at: None,
            organization: Default::default(),
        };
        state.file_entries.push(entry.clone());
        self.persist_locked_state(&state)?;
        Ok(entry)
    }

    pub async fn rename_file_entry(
        &self,
        entry_id: Uuid,
        request: RenameFileEntryRequest,
    ) -> Result<VaultFileEntry, ServiceError> {
        let mut state = self.state.write().await;
        ensure_distributed_defaults(&mut state);
        refresh_blob_records(&self.config, &mut state);
        ensure_file_namespace_defaults(&mut state);
        let name = sanitize_file_entry_name(&request.name)?;
        let (vault_id, parent_id) = {
            let entry = file_entry_by_id(&state, entry_id)?;
            ensure_not_file_root(entry)?;
            (entry.vault_id, entry.parent_id)
        };
        ensure_file_child_name_available(&state, vault_id, parent_id, Some(entry_id), &name)?;
        let now = Utc::now();
        let entry = state
            .file_entries
            .iter_mut()
            .find(|entry| entry.id == entry_id)
            .ok_or_else(|| ServiceError::NotFound(format!("file entry {entry_id}")))?;
        entry.name = name;
        entry.updated_at = now;
        let entry = entry.clone();
        self.persist_locked_state(&state)?;
        Ok(entry)
    }

    pub async fn move_file_entry(
        &self,
        entry_id: Uuid,
        request: MoveFileEntryRequest,
    ) -> Result<VaultFileEntry, ServiceError> {
        let mut state = self.state.write().await;
        ensure_distributed_defaults(&mut state);
        refresh_blob_records(&self.config, &mut state);
        ensure_file_namespace_defaults(&mut state);
        let entry = file_entry_by_id(&state, entry_id)?.clone();
        ensure_not_file_root(&entry)?;
        let parent_id = active_file_parent_or_root(&state, entry.vault_id, request.parent_id)?;
        if entry.kind == VaultFileKind::Folder {
            let descendants = descendant_file_entry_ids(&state, entry_id);
            if parent_id == entry_id || descendants.contains(&parent_id) {
                return Err(ServiceError::Invalid(
                    "folder cannot be moved into itself or one of its descendants".to_string(),
                ));
            }
        }
        ensure_file_child_name_available(
            &state,
            entry.vault_id,
            Some(parent_id),
            Some(entry_id),
            &entry.name,
        )?;
        let now = Utc::now();
        let updated = state
            .file_entries
            .iter_mut()
            .find(|entry| entry.id == entry_id)
            .ok_or_else(|| ServiceError::NotFound(format!("file entry {entry_id}")))?;
        updated.parent_id = Some(parent_id);
        updated.updated_at = now;
        let updated = updated.clone();
        self.persist_locked_state(&state)?;
        Ok(updated)
    }

    pub async fn trash_file_entry(&self, entry_id: Uuid) -> Result<VaultFileEntry, ServiceError> {
        let mut state = self.state.write().await;
        ensure_distributed_defaults(&mut state);
        refresh_blob_records(&self.config, &mut state);
        ensure_file_namespace_defaults(&mut state);
        let entry = file_entry_by_id(&state, entry_id)?.clone();
        ensure_not_file_root(&entry)?;
        let mut affected = descendant_file_entry_ids(&state, entry_id);
        affected.insert(entry_id);
        let now = Utc::now();
        for candidate in state
            .file_entries
            .iter_mut()
            .filter(|candidate| affected.contains(&candidate.id))
        {
            candidate.trashed_at = Some(now);
            candidate.updated_at = now;
        }
        let updated = file_entry_by_id(&state, entry_id)?.clone();
        self.persist_locked_state(&state)?;
        Ok(updated)
    }

    pub async fn restore_file_entry(&self, entry_id: Uuid) -> Result<VaultFileEntry, ServiceError> {
        let mut state = self.state.write().await;
        ensure_distributed_defaults(&mut state);
        refresh_blob_records(&self.config, &mut state);
        ensure_file_namespace_defaults(&mut state);
        let entry = file_entry_by_id(&state, entry_id)?.clone();
        ensure_not_file_root(&entry)?;
        let mut affected = descendant_file_entry_ids(&state, entry_id);
        affected.insert(entry_id);
        affected.extend(ancestor_file_entry_ids(&state, entry_id));
        let now = Utc::now();
        for candidate in state
            .file_entries
            .iter_mut()
            .filter(|candidate| affected.contains(&candidate.id))
        {
            candidate.trashed_at = None;
            candidate.updated_at = now;
        }
        let updated = file_entry_by_id(&state, entry_id)?.clone();
        self.persist_locked_state(&state)?;
        Ok(updated)
    }

    pub async fn file_original_bytes(
        &self,
        entry_id: Uuid,
    ) -> Result<(String, Vec<u8>), ServiceError> {
        let asset_id = {
            let mut state = self.state.write().await;
            ensure_distributed_defaults(&mut state);
            refresh_blob_records(&self.config, &mut state);
            ensure_file_namespace_defaults(&mut state);
            let entry = file_entry_by_id(&state, entry_id)?;
            if entry.trashed_at.is_some() || entry.kind != VaultFileKind::File {
                return Err(ServiceError::NotFound(format!("file entry {entry_id}")));
            }
            let asset_id = entry.asset_id.ok_or_else(|| {
                ServiceError::NotFound(format!("asset for file entry {entry_id}"))
            })?;
            self.persist_locked_state(&state)?;
            asset_id
        };
        self.asset_original_bytes(asset_id).await
    }

    pub async fn file_original_range_bytes(
        &self,
        entry_id: Uuid,
        range: ByteRangeRequest,
    ) -> Result<OriginalBytesRange, ServiceError> {
        let asset_id = {
            let mut state = self.state.write().await;
            ensure_distributed_defaults(&mut state);
            refresh_blob_records(&self.config, &mut state);
            ensure_file_namespace_defaults(&mut state);
            let entry = file_entry_by_id(&state, entry_id)?;
            if entry.trashed_at.is_some() || entry.kind != VaultFileKind::File {
                return Err(ServiceError::NotFound(format!("file entry {entry_id}")));
            }
            let asset_id = entry.asset_id.ok_or_else(|| {
                ServiceError::NotFound(format!("asset for file entry {entry_id}"))
            })?;
            self.persist_locked_state(&state)?;
            asset_id
        };
        self.asset_original_range_bytes(asset_id, range).await
    }

    pub async fn mobile_file_original_bytes(
        &self,
        bearer_token: &str,
        entry_id: Uuid,
    ) -> Result<(String, Vec<u8>), ServiceError> {
        let asset_id = self
            .mobile_file_asset_id_for_download(bearer_token, entry_id)
            .await?;
        self.asset_original_bytes(asset_id).await
    }

    pub async fn mobile_file_original_range_bytes(
        &self,
        bearer_token: &str,
        entry_id: Uuid,
        range: ByteRangeRequest,
    ) -> Result<OriginalBytesRange, ServiceError> {
        let asset_id = self
            .mobile_file_asset_id_for_download(bearer_token, entry_id)
            .await?;
        self.asset_original_range_bytes(asset_id, range).await
    }

    async fn mobile_file_asset_id_for_download(
        &self,
        bearer_token: &str,
        entry_id: Uuid,
    ) -> Result<Uuid, ServiceError> {
        let mut state = self.state.write().await;
        let session = active_mobile_session_from_state(&mut state, bearer_token)?;
        ensure_mobile_can_download_originals(&state, &session)?;
        ensure_distributed_defaults(&mut state);
        refresh_blob_records(&self.config, &mut state);
        ensure_file_namespace_defaults(&mut state);
        let entry = file_entry_by_id(&state, entry_id)?;
        if entry.vault_id != session.vault_id
            || entry.trashed_at.is_some()
            || entry.kind != VaultFileKind::File
        {
            return Err(ServiceError::NotFound(format!("file entry {entry_id}")));
        }
        let asset_id = entry
            .asset_id
            .ok_or_else(|| ServiceError::NotFound(format!("asset for file entry {entry_id}")))?;
        ensure_asset_belongs_to_vault(&state, session.vault_id, asset_id)?;
        self.persist_locked_state(&state)?;
        Ok(asset_id)
    }

    pub async fn vaults(&self) -> Vec<Vault> {
        self.state.read().await.vaults.clone()
    }

    pub async fn create_vault(&self, request: CreateVaultRequest) -> Result<Vault, ServiceError> {
        let name = request.name.trim();
        if name.is_empty() {
            return Err(ServiceError::Invalid(
                "vault name must not be empty".to_string(),
            ));
        }

        let mut state = self.state.write().await;
        let requested_id = request.id.unwrap_or_else(Uuid::new_v4);
        if let Some(existing) = state.vaults.iter().find(|vault| vault.id == requested_id)
            && existing.name != name
        {
            return Err(ServiceError::Invalid(format!(
                "vault {requested_id} already exists with name {}",
                existing.name
            )));
        }

        let mut changed = ensure_local_device_defaults(&mut state);
        let local_device = local_device_id(&state).ok_or_else(|| {
            ServiceError::Invalid("local admin device could not be initialized".to_string())
        })?;
        if let Some(existing) = state
            .vaults
            .iter()
            .find(|vault| vault.id == requested_id)
            .cloned()
        {
            changed |= ensure_local_vault_member(&mut state, existing.id, Utc::now());
            if changed {
                self.persist_locked_state(&state)?;
            }
            return Ok(existing);
        }
        let now = Utc::now();
        if let Some(index) = replaceable_bootstrap_vault_index(&state) {
            let previous_id = state.vaults[index].id;
            let created_at = state.vaults[index].created_at;
            state.vaults[index] = Vault {
                id: requested_id,
                name: name.to_string(),
                storage_policy: normalize_storage_policy(request.storage_policy),
                key_version: 1,
                deletion_grace_days: 30,
                created_at,
                updated_at: now,
            };
            for member in state
                .vault_members
                .iter_mut()
                .filter(|member| member.vault_id == previous_id)
            {
                member.vault_id = requested_id;
            }
            for envelope in state
                .vault_key_envelopes
                .iter_mut()
                .filter(|envelope| envelope.vault_id == previous_id)
            {
                envelope.vault_id = requested_id;
                envelope.encrypted_vault_key = vault_store::key_reference(requested_id, 1);
            }
            for grant in state
                .capability_grants
                .iter_mut()
                .filter(|grant| grant.vault_id == previous_id)
            {
                grant.vault_id = requested_id;
            }
            for entry in state
                .file_entries
                .iter_mut()
                .filter(|entry| entry.vault_id == previous_id)
            {
                entry.vault_id = requested_id;
                if entry.parent_id.is_none() && entry.asset_id.is_none() {
                    entry.name = name.to_string();
                    entry.updated_at = now;
                }
            }
            ensure_local_vault_member(&mut state, requested_id, now);
            refresh_blob_records(&self.config, &mut state);
            ensure_file_namespace_defaults(&mut state);
            let vault = state.vaults[index].clone();
            let actor_label = local_device_name(&state);
            push_audit_event(
                &mut state,
                "vault.create",
                ("vault", Some(vault.id)),
                (Some(local_device), actor_label),
                format!("Created device group {}", vault.name),
                json!({
                    "vault_id": vault.id,
                    "storage_policy": vault.storage_policy,
                    "replaced_bootstrap_vault": true,
                }),
            );
            self.persist_locked_state(&state)?;
            return Ok(vault);
        }
        let vault = Vault {
            id: requested_id,
            name: name.to_string(),
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
        ensure_file_namespace_defaults(&mut state);
        let actor_label = local_device_name(&state);
        push_audit_event(
            &mut state,
            "vault.create",
            ("vault", Some(vault.id)),
            (Some(local_device), actor_label),
            format!("Created device group {}", vault.name),
            json!({
                "vault_id": vault.id,
                "storage_policy": vault.storage_policy,
                "replaced_bootstrap_vault": false,
            }),
        );
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
        let (actor_device_id, actor_label) = local_actor(&state);
        push_audit_event(
            &mut state,
            "vault.storage_policy.update",
            ("vault", Some(vault.id)),
            (actor_device_id, actor_label),
            format!("Updated storage policy for {}", vault.name),
            json!({
                "vault_id": vault.id,
                "storage_policy": vault.storage_policy,
            }),
        );
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
            None,
            request.display_name,
            request.platform,
            request.public_key,
            request.trust_level,
            request.storage_profile,
        )?;
        let role = request
            .role
            .unwrap_or_else(|| default_role_for_trust(device.trust_level));
        let audit_role = role.clone();
        let device = add_device_to_state(&mut state, device, role, None)?;
        let (actor_device_id, actor_label) = local_actor(&state);
        push_audit_event(
            &mut state,
            "device.create",
            ("device", Some(device.id)),
            (actor_device_id, actor_label),
            format!("Added device {}", device.display_name),
            json!({
                "device_id": device.id,
                "platform": device.platform,
                "trust_level": device.trust_level,
                "role": audit_role,
                "accepts_storage": device.storage_profile.accepts_storage,
            }),
        );
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

        let endpoint = request.endpoint.clone();
        let device = build_device_identity(
            endpoint.as_ref().and_then(|value| value.device_id),
            request.display_name,
            request.platform,
            request
                .public_key
                .or_else(|| endpoint.as_ref().map(|value| value.node_id.clone())),
            request.trust_level,
            request.storage_profile,
        )?;
        let role = request
            .role
            .unwrap_or_else(|| default_role_for_trust(device.trust_level));
        let audit_role = role.clone();
        let device = add_device_to_state(&mut state, device, role, vault_id)?;
        let endpoint_present = endpoint.is_some();
        if let Some(endpoint) = endpoint {
            sync_transport::upsert_relay_endpoint(
                &mut state,
                device.id,
                endpoint.node_id,
                endpoint.relay_urls.first().cloned(),
                endpoint.direct_addresses,
                endpoint.expires_at,
            );
        }
        let (actor_device_id, actor_label) = local_actor(&state);
        push_audit_event(
            &mut state,
            "device.enroll",
            ("device", Some(device.id)),
            (actor_device_id, actor_label),
            format!("Enrolled device {}", device.display_name),
            json!({
                "device_id": device.id,
                "vault_id": vault_id,
                "platform": device.platform,
                "trust_level": device.trust_level,
                "role": audit_role,
                "accepts_storage": device.storage_profile.accepts_storage,
                "endpoint_present": endpoint_present,
            }),
        );
        self.persist_locked_state(&state)?;
        Ok(device)
    }

    pub async fn revoke_device(
        &self,
        device_id: Uuid,
        request: RevokeDeviceRequest,
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
        for session in state
            .mobile_sessions
            .iter_mut()
            .filter(|session| session.device_id == device_id && session.revoked_at.is_none())
        {
            session.revoked_at = Some(now);
            session.last_seen_at = Some(now);
        }
        for replica in state.blob_replicas.iter_mut().filter(|replica| {
            replica.device_id == device_id && replica.health == ReplicaHealth::Healthy
        }) {
            replica.health = ReplicaHealth::Offline;
        }
        let (actor_device_id, actor_label) = local_actor(&state);
        push_audit_event(
            &mut state,
            "device.revoke",
            ("device", Some(updated.id)),
            (actor_device_id, actor_label),
            format!("Revoked device {}", updated.display_name),
            json!({
                "device_id": updated.id,
                "platform": updated.platform,
                "reason_present": request.reason.as_ref().is_some_and(|value| !value.trim().is_empty()),
            }),
        );
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
        let mut plan = {
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
            plan
        };
        if !request.dry_run {
            plan.execution_results = self
                .execute_pending_sync_transfers(request.vault_id)
                .await?;
            let completed_results = plan
                .execution_results
                .iter()
                .filter(|result| result.status == SyncTransferExecutionStatus::Completed)
                .count();
            let failed_results = plan
                .execution_results
                .iter()
                .filter(|result| result.status == SyncTransferExecutionStatus::Failed)
                .count();
            let mut state = self.state.write().await;
            let (actor_device_id, actor_label) = local_actor(&state);
            push_audit_event(
                &mut state,
                "sync.run",
                ("sync", request.vault_id),
                (actor_device_id, actor_label),
                "Ran sync planner".to_string(),
                json!({
                    "vault_id": request.vault_id,
                    "planned_transfers": plan.transfers.len(),
                    "execution_results": plan.execution_results.len(),
                    "completed_results": completed_results,
                    "failed_results": failed_results,
                    "under_replicated_blobs": plan.under_replicated_blob_ids.len(),
                }),
            );
            self.persist_locked_state(&state)?;
        }
        Ok(plan)
    }

    pub async fn sync_transfers(&self) -> Vec<SyncTransfer> {
        self.state.read().await.sync_transfers.clone()
    }

    pub async fn sync_network_status(&self) -> SyncNetworkStatus {
        let state = self.state.read().await;
        let runtime = self.sync_runtime.status().await;
        build_sync_network_status(&state, runtime)
    }

    pub async fn start_sync_network(&self) -> Result<SyncNetworkStatus, ServiceError> {
        {
            let mut state = self.state.write().await;
            ensure_distributed_defaults(&mut state);
            self.persist_locked_state(&state)?;
        }
        self.sync_runtime
            .start()
            .await
            .map_err(sync_transport_error)?;
        {
            let mut state = self.state.write().await;
            let (actor_device_id, actor_label) = local_actor(&state);
            push_audit_event(
                &mut state,
                "sync.network.start",
                ("sync_network", None),
                (actor_device_id, actor_label),
                "Started encrypted sync network".to_string(),
                json!({ "transport": "encrypted_p2p" }),
            );
            self.persist_locked_state(&state)?;
        }
        Ok(self.sync_network_status().await)
    }

    pub async fn stop_sync_network(&self) -> Result<SyncNetworkStatus, ServiceError> {
        self.sync_runtime
            .stop()
            .await
            .map_err(sync_transport_error)?;
        {
            let mut state = self.state.write().await;
            let (actor_device_id, actor_label) = local_actor(&state);
            push_audit_event(
                &mut state,
                "sync.network.stop",
                ("sync_network", None),
                (actor_device_id, actor_label),
                "Stopped encrypted sync network".to_string(),
                json!({ "transport": "encrypted_p2p" }),
            );
            self.persist_locked_state(&state)?;
        }
        Ok(self.sync_network_status().await)
    }

    pub async fn sync_network_local_endpoint(
        &self,
    ) -> Result<crate::domain::LocalEndpointPayload, ServiceError> {
        {
            let mut state = self.state.write().await;
            ensure_distributed_defaults(&mut state);
            self.persist_locked_state(&state)?;
        }
        self.sync_runtime
            .local_endpoint_payload()
            .await
            .map_err(sync_transport_error)
    }

    async fn execute_pending_sync_transfers(
        &self,
        vault_id: Option<Uuid>,
    ) -> Result<Vec<SyncTransferExecutionResult>, ServiceError> {
        let (library_root, jobs, mut results) = {
            let mut state = self.state.write().await;
            ensure_distributed_defaults(&mut state);
            refresh_blob_records(&self.config, &mut state);
            let local_device = local_device_id(&state).ok_or_else(|| {
                ServiceError::Invalid("local device could not be initialized".to_string())
            })?;
            let library_root = PathBuf::from(effective_library_root(&state, &self.config));
            let now = Utc::now();
            let transfer_ids = state
                .sync_transfers
                .iter()
                .filter(|transfer| {
                    transfer.status == SyncTransferStatus::Pending
                        && (transfer.from_device_id == Some(local_device)
                            || transfer.to_device_id == local_device)
                        && vault_id
                            .map(|vault_id| transfer.vault_id == vault_id)
                            .unwrap_or(true)
                })
                .map(|transfer| transfer.id)
                .collect::<Vec<_>>();
            let mut jobs = Vec::new();
            let mut results = Vec::new();

            for transfer_id in transfer_ids {
                let Some(index) = state
                    .sync_transfers
                    .iter()
                    .position(|transfer| transfer.id == transfer_id)
                else {
                    continue;
                };
                let transfer = state.sync_transfers[index].clone();
                let direction = if transfer.from_device_id == Some(local_device) {
                    TransferDirection::Push
                } else if transfer.to_device_id == local_device {
                    TransferDirection::Pull
                } else {
                    continue;
                };
                let Some(blob) = state
                    .blob_records
                    .iter()
                    .find(|blob| blob.id == transfer.blob_id && blob.tombstoned_at.is_none())
                    .cloned()
                else {
                    state.sync_transfers[index].status = SyncTransferStatus::Failed;
                    state.sync_transfers[index].updated_at = now;
                    results.push(execution_result(
                        &transfer,
                        SyncTransferExecutionStatus::Failed,
                        0,
                        "blob metadata is missing".to_string(),
                    ));
                    continue;
                };
                let chunks = state
                    .blob_chunks
                    .iter()
                    .filter(|chunk| chunk.blob_id == blob.id)
                    .cloned()
                    .collect::<Vec<_>>();
                if direction == TransferDirection::Push
                    && (chunks.is_empty()
                        || !vault_store::encrypted_chunk_files_exist(&library_root, &chunks))
                {
                    state.sync_transfers[index].status = SyncTransferStatus::Failed;
                    state.sync_transfers[index].updated_at = now;
                    results.push(execution_result(
                        &transfer,
                        SyncTransferExecutionStatus::Failed,
                        0,
                        "local encrypted chunks are missing or corrupt".to_string(),
                    ));
                    continue;
                }
                let peer_device_id = match direction {
                    TransferDirection::Push => transfer.to_device_id,
                    TransferDirection::Pull => {
                        if let Some(from_device_id) = transfer.from_device_id {
                            from_device_id
                        } else {
                            state.sync_transfers[index].status = SyncTransferStatus::Failed;
                            state.sync_transfers[index].updated_at = now;
                            results.push(execution_result(
                                &transfer,
                                SyncTransferExecutionStatus::Failed,
                                0,
                                "pull transfer has no source device".to_string(),
                            ));
                            continue;
                        }
                    }
                };
                let Some(peer_device) = state
                    .devices
                    .iter()
                    .find(|device| {
                        device.id == peer_device_id
                            && device.revoked_at.is_none()
                            && (direction == TransferDirection::Pull
                                || device.storage_profile.accepts_storage)
                    })
                    .cloned()
                else {
                    state.sync_transfers[index].status = SyncTransferStatus::Failed;
                    state.sync_transfers[index].updated_at = now;
                    results.push(execution_result(
                        &transfer,
                        SyncTransferExecutionStatus::Failed,
                        0,
                        if direction == TransferDirection::Pull {
                            "source device is not active".to_string()
                        } else {
                            "target device is not active or does not accept storage".to_string()
                        },
                    ));
                    continue;
                };
                let Some(relay_endpoint) = state
                    .relay_endpoints
                    .iter()
                    .find(|endpoint| endpoint.device_id == peer_device.id)
                    .cloned()
                else {
                    state.sync_transfers[index].status = SyncTransferStatus::Failed;
                    state.sync_transfers[index].updated_at = now;
                    results.push(execution_result(
                        &transfer,
                        SyncTransferExecutionStatus::Skipped,
                        0,
                        if direction == TransferDirection::Pull {
                            "source device has no known P2P endpoint; paste its endpoint first"
                                .to_string()
                        } else {
                            "target device has no known P2P endpoint; paste its endpoint first"
                                .to_string()
                        },
                    ));
                    continue;
                };
                if relay_endpoint.expires_at < now {
                    state.sync_transfers[index].status = SyncTransferStatus::Failed;
                    state.sync_transfers[index].updated_at = now;
                    results.push(execution_result(
                        &transfer,
                        SyncTransferExecutionStatus::Skipped,
                        0,
                        if direction == TransferDirection::Pull {
                            "source device endpoint expired; paste a fresh endpoint".to_string()
                        } else {
                            "target device endpoint expired; paste a fresh endpoint".to_string()
                        },
                    ));
                    continue;
                }

                state.sync_transfers[index].status = SyncTransferStatus::Running;
                state.sync_transfers[index].started_at = Some(now);
                state.sync_transfers[index].updated_at = now;
                jobs.push(OutboundBlobTransfer {
                    direction,
                    transfer,
                    blob,
                    chunks,
                    target: sync_transport::peer_descriptor_for_device(
                        &peer_device,
                        Some(&relay_endpoint),
                    ),
                });
            }
            self.persist_locked_state(&state)?;
            (library_root, jobs, results)
        };

        if jobs.is_empty() {
            return Ok(results);
        }
        if let Err(err) = self.sync_runtime.start().await {
            let detail = err.to_string();
            let mut state = self.state.write().await;
            for job in jobs {
                if let Some(transfer) = state
                    .sync_transfers
                    .iter_mut()
                    .find(|transfer| transfer.id == job.transfer.id)
                {
                    transfer.status = SyncTransferStatus::Failed;
                    transfer.updated_at = Utc::now();
                }
                results.push(execution_result(
                    &job.transfer,
                    SyncTransferExecutionStatus::Failed,
                    0,
                    detail.clone(),
                ));
            }
            self.persist_locked_state(&state)?;
            return Ok(results);
        }

        for job in jobs {
            let result = match job.direction {
                TransferDirection::Push => self.sync_runtime.send_blob(&job, &library_root).await,
                TransferDirection::Pull => {
                    self.sync_runtime.request_blob(&job, &library_root).await
                }
            };
            let mut state = self.state.write().await;
            let now = Utc::now();
            let transfer_index = state
                .sync_transfers
                .iter()
                .position(|transfer| transfer.id == job.transfer.id);
            match result {
                Ok(bytes_transferred) => {
                    if let Some(index) = transfer_index {
                        state.sync_transfers[index].status = SyncTransferStatus::Completed;
                        state.sync_transfers[index].bytes_completed = bytes_transferred;
                        state.sync_transfers[index].updated_at = now;
                    }
                    sync_transport::upsert_blob_replica(
                        &mut state,
                        job.blob.id,
                        job.transfer.to_device_id,
                        job.blob.bytes,
                        Some(job.transfer.id),
                    );
                    results.push(execution_result(
                        &job.transfer,
                        SyncTransferExecutionStatus::Completed,
                        bytes_transferred,
                        if job.direction == TransferDirection::Pull {
                            "encrypted chunks fetched and verified from remote peer".to_string()
                        } else {
                            "encrypted chunks verified by remote peer".to_string()
                        },
                    ));
                }
                Err(err) => {
                    if let Some(index) = transfer_index {
                        state.sync_transfers[index].status = SyncTransferStatus::Failed;
                        state.sync_transfers[index].updated_at = now;
                    }
                    results.push(execution_result(
                        &job.transfer,
                        SyncTransferExecutionStatus::Failed,
                        0,
                        err.to_string(),
                    ));
                }
            }
            self.persist_locked_state(&state)?;
        }

        Ok(results)
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
                let actor_label = local_device_name(&state);
                push_audit_event(
                    &mut state,
                    "asset.pin_local",
                    ("asset", Some(asset_id)),
                    (Some(local_device), actor_label),
                    "Pinned asset from local encrypted chunks".to_string(),
                    json!({
                        "asset_id": asset_id,
                        "method": "local_encrypted_chunks",
                    }),
                );
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
        let transfer_id = transfer.id;
        let from_device_id = transfer.from_device_id;
        state.sync_transfers.push(transfer);
        let actor_label = local_device_name(&state);
        push_audit_event(
            &mut state,
            "asset.pin_local",
            ("asset", Some(asset_id)),
            (Some(local_device), actor_label),
            "Queued local pin transfer for asset".to_string(),
            json!({
                "asset_id": asset_id,
                "vault_id": blob.vault_id,
                "blob_id": blob.id,
                "transfer_id": transfer_id,
                "from_device_id": from_device_id,
                "to_device_id": local_device,
            }),
        );
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
        let storage_policy = vault.storage_policy.clone();
        if storage_policy.mode == StoragePolicyMode::MaxPoolSingleCopy {
            return Err(ServiceError::Invalid(
                "local eviction for only-copy vaults requires an explicit risk confirmation UI"
                    .to_string(),
            ));
        }
        let remote_verified = verified_remote_replica_count(&state, &blob, local_device);
        if remote_verified < storage_policy.min_replicas as usize {
            return Err(ServiceError::Invalid(format!(
                "local eviction blocked until {} verified P2P remote replicas exist",
                storage_policy.min_replicas
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
        let actor_label = local_device_name(&state);
        push_audit_event(
            &mut state,
            "asset.evict_local",
            ("asset", Some(asset_id)),
            (Some(local_device), actor_label),
            "Evicted local managed copy after replica verification".to_string(),
            json!({
                "asset_id": asset_id,
                "vault_id": blob.vault_id,
                "blob_id": blob.id,
                "verified_remote_replicas": remote_verified,
                "required_remote_replicas": storage_policy.min_replicas,
            }),
        );
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

    pub async fn asset_original_range_bytes(
        &self,
        asset_id: Uuid,
        range: ByteRangeRequest,
    ) -> Result<OriginalBytesRange, ServiceError> {
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
        let (start, end) = normalize_original_range(asset.bytes, range)?;
        let original_path = asset_file_path(&asset, &library_root);
        if original_path.is_file() {
            let bytes = read_file_range(&original_path, start, end)?;
            return Ok(OriginalBytesRange {
                mime_type: asset.mime_type,
                total_bytes: asset.bytes,
                start,
                end,
                bytes,
            });
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
        let bytes = vault_store::decrypt_chunks_range_to_bytes(
            &self.config,
            &library_root,
            blob.vault_id,
            blob.encryption_key_version,
            &chunks,
            start,
            end,
        )
        .map_err(vault_store_error)?;
        Ok(OriginalBytesRange {
            mime_type: asset.mime_type,
            total_bytes: asset.bytes,
            start,
            end,
            bytes,
        })
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

    pub async fn duplicate_review_summary(&self) -> DuplicateReviewSummary {
        let state = self.state.read().await;
        let generated_at = Utc::now();
        let assets_by_id = state
            .assets
            .iter()
            .map(|asset| (asset.id, (asset.media_kind.clone(), asset.bytes)))
            .collect::<BTreeMap<_, _>>();
        let mut entries = BTreeMap::<Uuid, DuplicateReviewAccumulator>::new();
        let mut sessions_with_duplicates = BTreeSet::<Uuid>::new();

        for session in state
            .import_sessions
            .iter()
            .filter(|session| session.status == ImportSessionStatus::Committed)
        {
            let seen_at = session.completed_at.unwrap_or(session.created_at);
            let source_kind = enum_label(&session.source_kind, "folder");
            let mut session_had_duplicate = false;

            for candidate in session
                .candidates
                .iter()
                .filter(|candidate| candidate.selected && candidate.duplicate_asset_id.is_some())
            {
                let Some(asset_id) = candidate.duplicate_asset_id else {
                    continue;
                };
                let (media_kind, original_bytes) = assets_by_id
                    .get(&asset_id)
                    .cloned()
                    .unwrap_or_else(|| (candidate.media_kind.clone(), candidate.bytes));
                let entry = entries
                    .entry(asset_id)
                    .or_insert_with(|| DuplicateReviewAccumulator {
                        asset_id,
                        media_kind,
                        original_bytes,
                        duplicate_candidates: 0,
                        protected_bytes: 0,
                        first_seen_at: seen_at,
                        last_seen_at: seen_at,
                        import_session_ids: BTreeSet::new(),
                        source_kinds: BTreeSet::new(),
                    });
                entry.duplicate_candidates += 1;
                entry.protected_bytes += candidate.bytes;
                entry.first_seen_at = entry.first_seen_at.min(seen_at);
                entry.last_seen_at = entry.last_seen_at.max(seen_at);
                entry.import_session_ids.insert(session.id);
                entry.source_kinds.insert(source_kind.clone());
                session_had_duplicate = true;
            }

            if session_had_duplicate {
                sessions_with_duplicates.insert(session.id);
            }
        }

        let mut entries = entries
            .into_values()
            .map(|entry| DuplicateReviewEntry {
                asset_id: entry.asset_id,
                media_kind: entry.media_kind,
                original_bytes: entry.original_bytes,
                duplicate_candidates: entry.duplicate_candidates,
                protected_bytes: entry.protected_bytes,
                first_seen_at: entry.first_seen_at,
                last_seen_at: entry.last_seen_at,
                import_session_ids: entry.import_session_ids.into_iter().collect(),
                source_kinds: entry.source_kinds.into_iter().collect(),
            })
            .collect::<Vec<_>>();
        entries.sort_by(|left, right| {
            right
                .protected_bytes
                .cmp(&left.protected_bytes)
                .then_with(|| right.duplicate_candidates.cmp(&left.duplicate_candidates))
                .then_with(|| left.asset_id.cmp(&right.asset_id))
        });
        let duplicate_candidates = entries.iter().map(|entry| entry.duplicate_candidates).sum();
        let protected_bytes = entries.iter().map(|entry| entry.protected_bytes).sum();

        DuplicateReviewSummary {
            generated_at,
            duplicate_assets: entries.len(),
            duplicate_candidates,
            protected_bytes,
            sessions_with_duplicates: sessions_with_duplicates.len(),
            entries,
            privacy_detail: "Computed locally from committed import-session checksums; source paths, filenames, OCR text, faces, tags, embeddings, and exact metadata are excluded.".to_string(),
        }
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
        ensure_file_namespace_defaults(&mut state);
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
        ensure_file_namespace_defaults(&mut state);
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
                    organization: Default::default(),
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
        timeline_response_for_assets(
            state.assets.clone(),
            asset_limit,
            per_bucket_limit,
            cursor_offset,
            include_archived,
        )
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

    pub async fn update_asset_tags(
        &self,
        asset_id: Uuid,
        request: UpdateAssetTagsRequest,
    ) -> Result<Asset, ServiceError> {
        let tags = normalize_manual_tags(request.tags)?;
        let mut state = self.state.write().await;
        let (previous_tags, updated) = {
            let asset = state
                .assets
                .iter_mut()
                .find(|asset| asset.id == asset_id)
                .ok_or_else(|| ServiceError::NotFound(format!("asset {asset_id}")))?;
            let previous_tags = asset.manual_tags.clone();
            asset.manual_tags = tags;
            (previous_tags, asset.clone())
        };

        state.feedback.push(FeedbackEvent {
            id: Uuid::new_v4(),
            kind: crate::domain::FeedbackKind::UpdateAssetTags,
            payload: json!({
                "asset_id": asset_id,
                "previous": {
                    "manual_tags": previous_tags,
                },
                "applied": {
                    "manual_tags": updated.manual_tags,
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

    pub async fn smart_folders(&self) -> Vec<SmartFolder> {
        self.state.read().await.smart_folders.clone()
    }

    pub async fn create_smart_folder(
        &self,
        request: CreateSmartFolderRequest,
    ) -> Result<SmartFolder, ServiceError> {
        let title = request.title.trim();
        if title.is_empty() {
            return Err(ServiceError::Invalid("title must not be empty".to_string()));
        }
        if !search_query_has_filters(&request.query) {
            return Err(ServiceError::Invalid(
                "smart folder query must include at least one filter".to_string(),
            ));
        }

        let mut state = self.state.write().await;
        let now = Utc::now();
        let folder = SmartFolder {
            id: Uuid::new_v4(),
            title: title.to_string(),
            query: request.query,
            created_at: now,
            updated_at: now,
        };
        state.smart_folders.insert(0, folder.clone());
        self.persist_locked_state(&state)?;
        Ok(folder)
    }

    pub async fn delete_smart_folder(&self, folder_id: Uuid) -> Result<(), ServiceError> {
        let mut state = self.state.write().await;
        let before = state.smart_folders.len();
        state.smart_folders.retain(|folder| folder.id != folder_id);
        if state.smart_folders.len() == before {
            return Err(ServiceError::NotFound(format!("smart folder {folder_id}")));
        }
        self.persist_locked_state(&state)?;
        Ok(())
    }

    pub async fn run_smart_folder(&self, folder_id: Uuid) -> Result<SearchResponse, ServiceError> {
        let query = self
            .state
            .read()
            .await
            .smart_folders
            .iter()
            .find(|folder| folder.id == folder_id)
            .map(|folder| folder.query.clone())
            .ok_or_else(|| ServiceError::NotFound(format!("smart folder {folder_id}")))?;
        Ok(self.search(query).await)
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
            search::SearchCorpus {
                assets: &state.assets,
                people: &state.people,
                places: &state.places,
                events: &state.events,
                ocr_blocks: &state.ocr_blocks,
                scene_tags: &state.scene_tags,
                file_entries: &state.file_entries,
                devices: &state.devices,
            },
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

    pub async fn audit_events(&self, limit: Option<usize>) -> Vec<AuditEvent> {
        let mut events = self.state.read().await.audit_events.clone();
        events.sort_by(|left, right| {
            right
                .created_at
                .cmp(&left.created_at)
                .then_with(|| right.id.cmp(&left.id))
        });
        if let Some(limit) = limit {
            events.truncate(limit);
        }
        events
    }

    pub async fn entitlement_status(&self) -> EntitlementStatusResponse {
        let state = self.state.read().await;
        build_entitlement_status(state.entitlement_cache.as_ref(), Utc::now())
    }

    pub async fn update_entitlement_cache(
        &self,
        request: UpdateEntitlementCacheRequest,
    ) -> Result<EntitlementStatusResponse, ServiceError> {
        let mut state = self.state.write().await;
        let now = Utc::now();
        let tier = request.tier;
        let account_id_hash = normalize_account_id_hash(request.account_id_hash.as_deref())?;
        let plan_code = normalize_public_code(request.plan_code.as_deref(), "plan_code")?;
        let source = normalize_public_code(request.source.as_deref(), "source")?
            .unwrap_or_else(|| "local_entitlement_cache".to_string());
        let limits = request.limits.unwrap_or_else(|| tier.default_limits());
        let cache = EntitlementCache {
            tier,
            status: request.status,
            account_id_hash,
            plan_code,
            limits,
            checked_at: request.checked_at.unwrap_or(now),
            expires_at: request.expires_at,
            offline_grace_expires_at: request.offline_grace_expires_at,
            source,
            detail: entitlement_cache_detail(request.status).to_string(),
            updated_at: now,
        };
        state.entitlement_cache = Some(cache);
        let response = build_entitlement_status(state.entitlement_cache.as_ref(), now);
        let has_account_hash = state
            .entitlement_cache
            .as_ref()
            .and_then(|cache| cache.account_id_hash.as_ref())
            .is_some();
        push_audit_event(
            &mut state,
            "entitlement.cache.update",
            ("entitlement", None),
            (None, Some("local entitlement cache".to_string())),
            format!(
                "Updated {:?} entitlement cache with {:?} effective status",
                response.tier, response.effective_status
            ),
            json!({
                "tier": response.tier,
                "effective_status": response.effective_status,
                "has_account_hash": has_account_hash,
                "content_exposure_prevented": response.content_exposure_prevented,
                "safe_local_access_allowed": response.safe_local_access_allowed,
                "device_limit": response.limits.device_limit,
                "member_limit": response.limits.member_limit,
                "workspace_limit": response.limits.workspace_limit,
            }),
        );
        self.persist_locked_state(&state)?;
        Ok(response)
    }

    pub async fn platform_release_readiness(&self) -> PlatformReleaseReadinessResponse {
        build_platform_release_readiness(Utc::now())
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
        let mut first_failure: Option<String> = None;

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
                    if first_failure.is_none() {
                        first_failure = Some(err);
                    }
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
            job.detail = Some(format!(
                "Scene indexing failed: 0 of {} asset(s) tagged, skipped {skipped}, failed {failed}. First failure: {}",
                assets.len(),
                first_failure.unwrap_or_else(|| "unknown".to_string())
            ));
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

    pub async fn export_support_bundle(
        &self,
        request: SupportBundleExportRequest,
    ) -> Result<SupportBundleExportResult, ServiceError> {
        if request.export_root.trim().is_empty() {
            return Err(ServiceError::Invalid(
                "export_root must not be empty".to_string(),
            ));
        }

        let export_root = PathBuf::from(&request.export_root);
        let support_dir = export_root.join("support");
        fs::create_dir_all(&support_dir).map_err(|err| ServiceError::Io(err.to_string()))?;
        let bundle_path = support_dir.join("private-gallery-support-bundle.json");
        let exported_at = Utc::now();
        let verification = self
            .verify_backup(BackupVerifyRequest { export_root: None })
            .await?;
        let release_readiness = if request.include_release_readiness {
            Some(self.platform_release_readiness().await)
        } else {
            None
        };
        let redacted_fields = support_bundle_redacted_fields();
        let sections = vec![
            "summary".to_string(),
            "privacy".to_string(),
            "entitlements".to_string(),
            "backup_health".to_string(),
            "release_readiness".to_string(),
            "redaction".to_string(),
        ];
        let bundle = {
            let state = self.state.read().await;
            let privacy =
                model_registry::privacy_status(&self.config).map_err(model_registry_error)?;
            let entitlement =
                build_entitlement_status(state.entitlement_cache.as_ref(), exported_at);
            let mut media_kind_counts = BTreeMap::<String, usize>::new();
            for asset in &state.assets {
                let kind = serde_json::to_value(&asset.media_kind)
                    .ok()
                    .and_then(|value| value.as_str().map(ToString::to_string))
                    .unwrap_or_else(|| "other".to_string());
                *media_kind_counts.entry(kind).or_default() += 1;
            }
            let mut device_platform_counts = BTreeMap::<String, usize>::new();
            for device in &state.devices {
                *device_platform_counts
                    .entry(device.platform.trim().to_ascii_lowercase())
                    .or_default() += 1;
            }
            let mut recent_audit_actions = BTreeMap::<String, usize>::new();
            for event in state.audit_events.iter().take(50) {
                *recent_audit_actions
                    .entry(event.action.clone())
                    .or_default() += 1;
            }
            json!({
                "exported_at": exported_at,
                "local_only": true,
                "private_data_excluded": true,
                "summary": {
                    "asset_count": state.assets.len(),
                    "media_kind_counts": media_kind_counts,
                    "album_count": state.albums.len(),
                    "smart_folder_count": state.smart_folders.len(),
                    "people_cluster_count": state.people.len(),
                    "place_cluster_count": state.places.len(),
                    "event_cluster_count": state.events.len(),
                    "vault_count": state.vaults.len(),
                    "device_count": state.devices.len(),
                    "device_platform_counts": device_platform_counts,
                    "mobile_session_count": state.mobile_sessions.len(),
                    "sync_transfer_count": state.sync_transfers.len(),
                    "job_count": state.jobs.len(),
                    "audit_event_count": state.audit_events.len(),
                    "recent_audit_action_counts": recent_audit_actions,
                },
                "privacy": {
                    "network_policy": privacy.network_policy,
                    "loopback_only": privacy.loopback_only,
                    "developer_mode": privacy.developer_mode,
                    "remote_mobile_access_enabled": privacy.remote_mobile_access_enabled,
                    "photo_processing_network_allowed": privacy.photo_processing_network_allowed,
                    "model_download_requires_confirmation": privacy.model_download_requires_confirmation,
                    "telemetry_enabled": privacy.telemetry_enabled,
                    "analytics_enabled": privacy.analytics_enabled,
                    "cloud_ai_enabled": privacy.cloud_ai_enabled,
                    "database_encrypted": privacy.encryption.database_encrypted,
                    "derived_data_encrypted": privacy.encryption.derived_data_encrypted,
                    "sensitive_indexing_allowed": privacy.encryption.sensitive_indexing_allowed,
                    "installed_model_count": privacy.installed_models.len(),
                },
                "entitlements": {
                    "tier": entitlement.tier,
                    "effective_status": entitlement.effective_status,
                    "offline_grace_active": entitlement.offline_grace_active,
                    "paid_features_available": entitlement.paid_features_available,
                    "safe_local_access_allowed": entitlement.safe_local_access_allowed,
                    "content_exposure_prevented": entitlement.content_exposure_prevented,
                    "limits": entitlement.limits,
                    "account_identifier_redacted": entitlement
                        .cache
                        .as_ref()
                        .and_then(|cache| cache.account_id_hash.as_ref())
                        .is_some(),
                },
                "backup_health": {
                    "checked_at": verification.checked_at,
                    "assets_checked": verification.assets_checked,
                    "missing_asset_count": verification.missing_asset_paths.len(),
                    "vault_chunks_checked": verification.vault_chunks_checked,
                    "missing_vault_chunk_count": verification.missing_vault_chunk_paths.len(),
                    "model_files_checked": verification.model_files_checked,
                    "missing_model_count": verification.missing_model_paths.len(),
                    "database_hash_present": verification.database_sha256.is_some(),
                    "ok": verification.ok,
                },
                "release_readiness": release_readiness,
                "redaction": {
                    "redacted_fields": redacted_fields,
                    "excluded_private_data": [
                        "media files",
                        "vault chunks",
                        "database copy",
                        "absolute paths",
                        "file names",
                        "folder names",
                        "OCR text",
                        "face templates",
                        "embeddings",
                        "manual tags",
                        "exact GPS/capture metadata",
                        "vault keys",
                        "bearer tokens",
                        "pairing tokens",
                        "account hashes"
                    ]
                }
            })
        };
        fs::write(
            &bundle_path,
            serde_json::to_string_pretty(&bundle)
                .map_err(|err| ServiceError::Storage(err.to_string()))?,
        )
        .map_err(|err| ServiceError::Io(err.to_string()))?;

        Ok(SupportBundleExportResult {
            exported_at,
            export_root: export_root.to_string_lossy().to_string(),
            bundle_path: bundle_path.to_string_lossy().to_string(),
            sections,
            redacted_fields,
            private_data_excluded: true,
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
                if let Err(err) = vault_store::verify_encrypted_chunk_files(
                    &library_root,
                    std::slice::from_ref(chunk),
                ) {
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
            } else if file
                .get("kind")
                .and_then(|value| value.as_str())
                .is_none_or(|kind| kind != "model_file")
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

fn ensure_vault_exists(state: &LibraryState, vault_id: Uuid) -> Result<(), ServiceError> {
    if state.vaults.iter().any(|vault| vault.id == vault_id) {
        Ok(())
    } else {
        Err(ServiceError::NotFound(format!("vault {vault_id}")))
    }
}

fn ensure_file_namespace_defaults(state: &mut LibraryState) -> bool {
    if state.library_settings.is_none() {
        return false;
    }

    let now = Utc::now();
    let mut changed = false;
    for vault in state.vaults.clone() {
        let root_index = state.file_entries.iter().position(|entry| {
            entry.vault_id == vault.id
                && entry.parent_id.is_none()
                && entry.asset_id.is_none()
                && entry.kind == VaultFileKind::Folder
        });
        match root_index {
            Some(index) => {
                if state.file_entries[index].name != vault.name {
                    state.file_entries[index].name = vault.name.clone();
                    state.file_entries[index].updated_at = now;
                    changed = true;
                }
            }
            None => {
                state.file_entries.push(VaultFileEntry {
                    id: Uuid::new_v4(),
                    vault_id: vault.id,
                    parent_id: None,
                    asset_id: None,
                    name: vault.name.clone(),
                    kind: VaultFileKind::Folder,
                    media_kind: None,
                    mime_type: None,
                    bytes: 0,
                    content_hash: None,
                    origin_device_id: local_device_id(state),
                    created_at: now,
                    updated_at: now,
                    trashed_at: None,
                    organization: Default::default(),
                });
                changed = true;
            }
        }
    }

    let asset_by_id = state
        .assets
        .iter()
        .map(|asset| (asset.id, asset.clone()))
        .collect::<HashMap<_, _>>();
    let active_blobs = state
        .blob_records
        .iter()
        .filter(|blob| blob.tombstoned_at.is_none())
        .cloned()
        .collect::<Vec<_>>();
    for blob in active_blobs {
        let Some(asset) = asset_by_id.get(&blob.asset_id) else {
            continue;
        };
        let Some(root_id) = root_file_entry_id(state, blob.vault_id) else {
            continue;
        };
        if let Some(index) = state
            .file_entries
            .iter()
            .position(|entry| entry.vault_id == blob.vault_id && entry.asset_id == Some(asset.id))
        {
            let parent_missing = state.file_entries[index]
                .parent_id
                .is_some_and(|parent_id| {
                    !state.file_entries.iter().any(|entry| entry.id == parent_id)
                });
            let entry = &mut state.file_entries[index];
            let mut entry_changed = false;
            if entry.kind != VaultFileKind::File {
                entry.kind = VaultFileKind::File;
                entry_changed = true;
            }
            if entry.media_kind.as_ref() != Some(&asset.media_kind) {
                entry.media_kind = Some(asset.media_kind.clone());
                entry_changed = true;
            }
            if entry.mime_type.as_deref() != Some(asset.mime_type.as_str()) {
                entry.mime_type = Some(asset.mime_type.clone());
                entry_changed = true;
            }
            if entry.bytes != asset.bytes {
                entry.bytes = asset.bytes;
                entry_changed = true;
            }
            if entry.content_hash.as_deref() != Some(asset.content_hash.as_str()) {
                entry.content_hash = Some(asset.content_hash.clone());
                entry_changed = true;
            }
            if entry.parent_id.is_none() || parent_missing {
                entry.parent_id = Some(root_id);
                entry_changed = true;
            }
            if entry_changed {
                entry.updated_at = now;
                changed = true;
            }
        } else {
            state.file_entries.push(VaultFileEntry {
                id: Uuid::new_v4(),
                vault_id: blob.vault_id,
                parent_id: Some(root_id),
                asset_id: Some(asset.id),
                name: asset.original_filename.clone(),
                kind: VaultFileKind::File,
                media_kind: Some(asset.media_kind.clone()),
                mime_type: Some(asset.mime_type.clone()),
                bytes: asset.bytes,
                content_hash: Some(asset.content_hash.clone()),
                origin_device_id: local_device_id(state),
                created_at: asset.imported_at,
                updated_at: now,
                trashed_at: None,
                organization: asset
                    .metadata
                    .as_ref()
                    .map(|metadata| metadata.organization.clone())
                    .unwrap_or_default(),
            });
            changed = true;
        }
    }

    changed
}

fn root_file_entry_id(state: &LibraryState, vault_id: Uuid) -> Option<Uuid> {
    state
        .file_entries
        .iter()
        .find(|entry| {
            entry.vault_id == vault_id
                && entry.parent_id.is_none()
                && entry.asset_id.is_none()
                && entry.kind == VaultFileKind::Folder
        })
        .map(|entry| entry.id)
}

fn build_file_tree_response(
    state: &LibraryState,
    vault_id: Option<Uuid>,
    include_trashed: bool,
) -> VaultFileTreeResponse {
    let organization_by_asset_id = state
        .assets
        .iter()
        .filter_map(|asset| {
            asset
                .metadata
                .as_ref()
                .map(|metadata| (asset.id, metadata.organization.clone()))
        })
        .collect::<HashMap<_, _>>();
    let mut entries = state
        .file_entries
        .iter()
        .filter(|entry| {
            vault_id
                .map(|vault_id| entry.vault_id == vault_id)
                .unwrap_or(true)
        })
        .filter(|entry| include_trashed || entry.trashed_at.is_none())
        .map(|entry| {
            let mut entry = entry.clone();
            if let Some(asset_id) = entry.asset_id
                && let Some(organization) = organization_by_asset_id.get(&asset_id)
            {
                entry.organization = organization.clone();
            }
            entry
        })
        .collect::<Vec<_>>();
    entries.sort_by(|left, right| {
        left.vault_id
            .cmp(&right.vault_id)
            .then(left.parent_id.cmp(&right.parent_id))
            .then((left.kind != VaultFileKind::Folder).cmp(&(right.kind != VaultFileKind::Folder)))
            .then(left.name.to_lowercase().cmp(&right.name.to_lowercase()))
            .then(left.id.cmp(&right.id))
    });
    let root_entry_ids = entries
        .iter()
        .filter(|entry| entry.parent_id.is_none())
        .map(|entry| entry.id)
        .collect::<Vec<_>>();
    let origin_device_ids = entries
        .iter()
        .filter_map(|entry| entry.origin_device_id)
        .collect::<BTreeSet<_>>();
    let mut devices = state
        .devices
        .iter()
        .filter(|device| origin_device_ids.contains(&device.id))
        .map(|device| VaultFileDeviceSummary {
            id: device.id,
            display_name: device.display_name.clone(),
            platform: device.platform.clone(),
            revoked_at: device.revoked_at,
        })
        .collect::<Vec<_>>();
    devices.sort_by(|left, right| {
        left.display_name
            .to_lowercase()
            .cmp(&right.display_name.to_lowercase())
            .then(left.id.cmp(&right.id))
    });
    VaultFileTreeResponse {
        vault_id,
        root_entry_ids,
        entries,
        devices,
    }
}

fn sanitize_file_entry_name(raw: &str) -> Result<String, ServiceError> {
    let name = raw.trim();
    if name.is_empty() {
        return Err(ServiceError::Invalid(
            "file name must not be empty".to_string(),
        ));
    }
    if matches!(name, "." | "..")
        || name.contains('/')
        || name.contains('\\')
        || name.contains('\0')
    {
        return Err(ServiceError::Invalid(
            "file name must not contain path separators or traversal segments".to_string(),
        ));
    }
    Ok(name.to_string())
}

fn active_file_parent_or_root(
    state: &LibraryState,
    vault_id: Uuid,
    parent_id: Option<Uuid>,
) -> Result<Uuid, ServiceError> {
    if let Some(parent_id) = parent_id {
        let parent = file_entry_by_id(state, parent_id)?;
        if parent.vault_id != vault_id
            || parent.kind != VaultFileKind::Folder
            || parent.trashed_at.is_some()
        {
            return Err(ServiceError::Invalid(
                "parent_id must reference an active folder in the same vault".to_string(),
            ));
        }
        return Ok(parent_id);
    }
    root_file_entry_id(state, vault_id)
        .ok_or_else(|| ServiceError::NotFound(format!("root file entry for vault {vault_id}")))
}

fn ensure_file_child_name_available(
    state: &LibraryState,
    vault_id: Uuid,
    parent_id: Option<Uuid>,
    exclude_entry_id: Option<Uuid>,
    name: &str,
) -> Result<(), ServiceError> {
    let lower_name = name.to_lowercase();
    if state.file_entries.iter().any(|entry| {
        entry.vault_id == vault_id
            && entry.parent_id == parent_id
            && entry.id != exclude_entry_id.unwrap_or(Uuid::nil())
            && entry.trashed_at.is_none()
            && entry.name.to_lowercase() == lower_name
    }) {
        return Err(ServiceError::Invalid(format!(
            "an active file entry named {name} already exists in this folder"
        )));
    }
    Ok(())
}

fn file_entry_by_id(state: &LibraryState, entry_id: Uuid) -> Result<&VaultFileEntry, ServiceError> {
    state
        .file_entries
        .iter()
        .find(|entry| entry.id == entry_id)
        .ok_or_else(|| ServiceError::NotFound(format!("file entry {entry_id}")))
}

fn ensure_not_file_root(entry: &VaultFileEntry) -> Result<(), ServiceError> {
    if entry.parent_id.is_none() && entry.asset_id.is_none() && entry.kind == VaultFileKind::Folder
    {
        return Err(ServiceError::Invalid(
            "vault root folders cannot be renamed, moved, or trashed".to_string(),
        ));
    }
    Ok(())
}

fn descendant_file_entry_ids(state: &LibraryState, entry_id: Uuid) -> BTreeSet<Uuid> {
    let mut descendants = BTreeSet::new();
    let mut frontier = vec![entry_id];
    while let Some(parent_id) = frontier.pop() {
        for child in state
            .file_entries
            .iter()
            .filter(|entry| entry.parent_id == Some(parent_id))
        {
            if descendants.insert(child.id) {
                frontier.push(child.id);
            }
        }
    }
    descendants
}

fn ancestor_file_entry_ids(state: &LibraryState, entry_id: Uuid) -> BTreeSet<Uuid> {
    let mut ancestors = BTreeSet::new();
    let mut current = file_entry_by_id(state, entry_id)
        .ok()
        .and_then(|entry| entry.parent_id);
    while let Some(parent_id) = current {
        if !ancestors.insert(parent_id) {
            break;
        }
        current = state
            .file_entries
            .iter()
            .find(|entry| entry.id == parent_id)
            .and_then(|entry| entry.parent_id);
    }
    ancestors
}

fn ensure_distributed_defaults(state: &mut LibraryState) -> bool {
    if state.library_settings.is_none() {
        return false;
    }

    let now = Utc::now();
    let mut changed = ensure_local_device_defaults(state);

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

    if let Some(vault_id) = state.vaults.first().map(|vault| vault.id) {
        changed |= ensure_local_vault_member(state, vault_id, now);
    }

    changed
}

fn ensure_local_vault_member(
    state: &mut LibraryState,
    vault_id: Uuid,
    now: chrono::DateTime<Utc>,
) -> bool {
    let Some(device_id) = local_device_id(state) else {
        return false;
    };
    let has_local_member = state.vault_members.iter().any(|member| {
        member.vault_id == vault_id && member.device_id == device_id && member.revoked_at.is_none()
    });
    if has_local_member {
        return false;
    }

    let (role, trust_level) = state
        .devices
        .iter()
        .find(|device| device.id == device_id)
        .map(|device| {
            (
                if device.trust_level == DeviceTrustLevel::StorageOnly {
                    DeviceRole::StorageOnly
                } else {
                    DeviceRole::Admin
                },
                device.trust_level,
            )
        })
        .unwrap_or((DeviceRole::Admin, DeviceTrustLevel::Trusted));
    state.vault_members.push(VaultMember {
        id: Uuid::new_v4(),
        vault_id,
        device_id,
        role,
        trust_level,
        display_name: local_device_name(state).unwrap_or_else(|| "This device".to_string()),
        added_at: now,
        revoked_at: None,
    });
    true
}

fn ensure_local_device_defaults(state: &mut LibraryState) -> bool {
    if state.library_settings.is_none() || !state.devices.is_empty() {
        return false;
    }

    let now = Utc::now();
    let id = Uuid::new_v4();
    let storage_profile = DeviceStorageProfile {
        device_id: Some(id),
        ..DeviceStorageProfile::default()
    };
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
    true
}

fn replaceable_bootstrap_vault_index(state: &LibraryState) -> Option<usize> {
    if state.vaults.len() != 1 {
        return None;
    }
    let vault = state.vaults.first()?;
    if vault.name != "Personal vault" {
        return None;
    }
    let vault_id = vault.id;
    let has_stateful_records = state
        .blob_records
        .iter()
        .any(|blob| blob.vault_id == vault_id)
        || state
            .mobile_sessions
            .iter()
            .any(|session| session.vault_id == vault_id)
        || state
            .pairings
            .iter()
            .any(|pairing| pairing.vault_id == Some(vault_id));
    if has_stateful_records {
        return None;
    }
    Some(0)
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
                    changed |= enforce_original_storage_policy(
                        config,
                        state,
                        asset.id,
                        blob_id,
                        &library_root,
                        vault.id,
                        vault.key_version,
                    );
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

        changed |= enforce_original_storage_policy(
            config,
            state,
            asset.id,
            blob_id,
            &library_root,
            vault.id,
            vault.key_version,
        );
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

fn blob_for_mobile_session<'a>(
    state: &'a LibraryState,
    session: &MobileSession,
    blob_id: Uuid,
) -> Result<&'a BlobRecord, ServiceError> {
    state
        .blob_records
        .iter()
        .find(|blob| {
            blob.id == blob_id && blob.vault_id == session.vault_id && blob.tombstoned_at.is_none()
        })
        .ok_or_else(|| ServiceError::NotFound(format!("blob {blob_id}")))
}

fn chunk_for_blob(
    state: &LibraryState,
    blob_id: Uuid,
    chunk_index: u32,
) -> Result<&BlobChunk, ServiceError> {
    state
        .blob_chunks
        .iter()
        .find(|chunk| chunk.blob_id == blob_id && chunk.chunk_index == chunk_index)
        .ok_or_else(|| ServiceError::NotFound(format!("chunk {chunk_index} for blob {blob_id}")))
}

fn encrypted_chunk_descriptors_for_blob(
    state: &LibraryState,
    blob_id: Uuid,
    transfer_id: Uuid,
) -> Result<Vec<MobileReplicaChunkDescriptor>, ServiceError> {
    let mut chunks = state
        .blob_chunks
        .iter()
        .filter(|chunk| chunk.blob_id == blob_id)
        .cloned()
        .collect::<Vec<_>>();
    chunks.sort_by_key(|chunk| chunk.chunk_index);
    if chunks.is_empty() {
        return Err(ServiceError::Invalid(format!(
            "blob {blob_id} has no encrypted chunks"
        )));
    }
    Ok(chunks
        .into_iter()
        .map(|chunk| {
            let proof_challenge = mobile_replica_chunk_proof_challenge(transfer_id, &chunk);
            MobileReplicaChunkDescriptor {
                chunk_id: chunk.id,
                chunk_index: chunk.chunk_index,
                encrypted_hash: chunk.encrypted_hash,
                encrypted_bytes: chunk.encrypted_bytes,
                plaintext_bytes: chunk.bytes,
                proof_challenge,
            }
        })
        .collect())
}

fn ensure_mobile_storage_device(
    state: &LibraryState,
    session: &MobileSession,
) -> Result<(), ServiceError> {
    ensure_mobile_can_manage_storage(state, session)?;
    let device = state
        .devices
        .iter()
        .find(|device| device.id == session.device_id)
        .ok_or_else(|| ServiceError::NotFound(format!("device {}", session.device_id)))?;
    if !device.storage_profile.accepts_storage {
        return Err(ServiceError::Invalid(
            "mobile device has not enabled encrypted storage contribution".to_string(),
        ));
    }
    Ok(())
}

fn mobile_storage_transfer_index(
    state: &LibraryState,
    session: &MobileSession,
    vault_id: Uuid,
    blob_id: Uuid,
    transfer_id: Option<Uuid>,
    allow_completed: bool,
) -> Result<usize, ServiceError> {
    let source_device = local_device_id(state);
    let now = Utc::now();
    state
        .sync_transfers
        .iter()
        .position(|transfer| {
            transfer_id
                .map(|requested| transfer.id == requested)
                .unwrap_or(true)
                && transfer.vault_id == vault_id
                && transfer.blob_id == blob_id
                && transfer.from_device_id == source_device
                && transfer.to_device_id == session.device_id
                && match transfer.status {
                    SyncTransferStatus::Pending | SyncTransferStatus::Running => {
                        transfer.resumable_until >= now
                    }
                    SyncTransferStatus::Completed => allow_completed,
                    SyncTransferStatus::Failed | SyncTransferStatus::Aborted => false,
                }
        })
        .ok_or_else(|| {
            let detail = transfer_id
                .map(|id| format!("transfer {id}"))
                .unwrap_or_else(|| format!("blob {blob_id}"));
            ServiceError::Invalid(format!(
                "mobile storage assignment for {detail} does not match this active device session"
            ))
        })
}

fn mobile_replica_chunk_proof_challenge(transfer_id: Uuid, chunk: &BlobChunk) -> String {
    sha256_hex_bytes(
        format!(
            "private-gallery:mobile-replica-proof:{transfer_id}:{}:{}:{}:{}",
            chunk.id, chunk.chunk_index, chunk.encrypted_hash, chunk.encrypted_bytes
        )
        .as_bytes(),
    )
}

fn mobile_replica_chunk_proof_hex(proof_challenge: &str, bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(proof_challenge.as_bytes());
    hasher.update([0]);
    hasher.update(bytes);
    hex_string(&hasher.finalize())
}

fn mobile_replica_chunk_proof_from_local(
    library_root: &Path,
    chunk: &BlobChunk,
    proof_challenge: &str,
) -> Result<String, ServiceError> {
    let local_path = chunk.local_path.as_deref().ok_or_else(|| {
        ServiceError::Invalid(format!("chunk {} has no local encrypted path", chunk.id))
    })?;
    let bytes = fs::read(library_root.join(local_path))
        .map_err(|err| ServiceError::Io(format!("failed to read encrypted chunk: {err}")))?;
    verify_encrypted_chunk_bytes(chunk, &bytes)?;
    Ok(mobile_replica_chunk_proof_hex(proof_challenge, &bytes))
}

fn verify_encrypted_chunk_bytes(chunk: &BlobChunk, bytes: &[u8]) -> Result<(), ServiceError> {
    let encrypted_hash = sha256_hex_bytes(bytes);
    if encrypted_hash != chunk.encrypted_hash {
        return Err(ServiceError::Invalid(format!(
            "encrypted hash mismatch for chunk {}",
            chunk.chunk_index
        )));
    }
    if chunk.encrypted_bytes != 0 && bytes.len() as u64 != chunk.encrypted_bytes {
        return Err(ServiceError::Invalid(format!(
            "encrypted size mismatch for chunk {}",
            chunk.chunk_index
        )));
    }
    Ok(())
}

fn enforce_original_storage_policy(
    config: &AppConfig,
    state: &mut LibraryState,
    asset_id: Uuid,
    blob_id: Uuid,
    library_root: &Path,
    vault_id: Uuid,
    key_version: u32,
) -> bool {
    let Some(settings) = &state.library_settings else {
        return false;
    };
    if settings.original_storage_policy != OriginalStoragePolicy::EncryptedOnly {
        return false;
    }

    let Some(asset) = state
        .assets
        .iter()
        .find(|asset| asset.id == asset_id)
        .cloned()
    else {
        return false;
    };
    if asset.import_mode == ImportMode::Reference {
        return false;
    }

    let original_path = asset_file_path(&asset, library_root);
    if !original_path.is_file() {
        return false;
    }

    let chunks = state
        .blob_chunks
        .iter()
        .filter(|chunk| chunk.blob_id == blob_id)
        .cloned()
        .collect::<Vec<_>>();
    if !vault_store::encrypted_chunk_files_exist(library_root, &chunks) {
        return false;
    }
    let Ok(plaintext) =
        vault_store::decrypt_chunks_to_bytes(config, library_root, vault_id, key_version, &chunks)
    else {
        return false;
    };
    if plaintext.len() as u64 != asset.bytes || sha256_hex_bytes(&plaintext) != asset.content_hash {
        return false;
    }
    if fs::remove_file(&original_path).is_err() {
        return false;
    }
    if let Some(asset) = state.assets.iter_mut().find(|asset| asset.id == asset_id) {
        asset.is_available = false;
    }
    true
}

fn sha256_hex_bytes(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex_string(&hasher.finalize())
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

pub(crate) fn local_device_id(state: &LibraryState) -> Option<Uuid> {
    state
        .devices
        .iter()
        .find(|device| {
            device.revoked_at.is_none()
                && device
                    .public_key
                    .starts_with("local-device-key-pending-iroh-")
        })
        .or_else(|| {
            state
                .devices
                .iter()
                .find(|device| device.revoked_at.is_none())
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

fn local_actor(state: &LibraryState) -> (Option<Uuid>, Option<String>) {
    (local_device_id(state), local_device_name(state))
}

fn active_mobile_session_from_state(
    state: &mut LibraryState,
    bearer_token: &str,
) -> Result<MobileSession, ServiceError> {
    let token = bearer_token.trim();
    if token.is_empty() {
        return Err(ServiceError::Invalid(
            "mobile authorization bearer token is required".to_string(),
        ));
    }
    let token_hash = hash_mobile_token(token);
    let now = Utc::now();
    let session_index = state
        .mobile_sessions
        .iter()
        .position(|session| session.token_hash == token_hash)
        .ok_or_else(|| ServiceError::Invalid("mobile session was not found".to_string()))?;
    let session = state.mobile_sessions[session_index].clone();
    if session.revoked_at.is_some() {
        return Err(ServiceError::Invalid(
            "mobile session has been revoked".to_string(),
        ));
    }
    if session.expires_at < now {
        return Err(ServiceError::Invalid(
            "mobile session has expired".to_string(),
        ));
    }
    let device_index = state
        .devices
        .iter()
        .position(|device| device.id == session.device_id)
        .ok_or_else(|| ServiceError::NotFound(format!("device {}", session.device_id)))?;
    if state.devices[device_index].revoked_at.is_some() {
        return Err(ServiceError::Invalid(
            "mobile device has been revoked".to_string(),
        ));
    }
    if !state
        .vaults
        .iter()
        .any(|vault| vault.id == session.vault_id)
    {
        return Err(ServiceError::NotFound(format!(
            "vault {}",
            session.vault_id
        )));
    }
    if !state.vault_members.iter().any(|member| {
        member.vault_id == session.vault_id
            && member.device_id == session.device_id
            && member.revoked_at.is_none()
    }) {
        return Err(ServiceError::Invalid(
            "mobile session device is not an active vault member".to_string(),
        ));
    }
    state.mobile_sessions[session_index].last_seen_at = Some(now);
    state.devices[device_index].last_seen_at = Some(now);
    Ok(state.mobile_sessions[session_index].clone())
}

fn mobile_session_role(
    state: &LibraryState,
    session: &MobileSession,
) -> Result<DeviceRole, ServiceError> {
    state
        .vault_members
        .iter()
        .find(|member| {
            member.vault_id == session.vault_id
                && member.device_id == session.device_id
                && member.revoked_at.is_none()
        })
        .map(|member| member.role.clone())
        .ok_or_else(|| {
            ServiceError::Invalid("mobile session device is not an active vault member".to_string())
        })
}

fn mobile_role_can_browse(role: &DeviceRole) -> bool {
    matches!(
        role,
        DeviceRole::Admin | DeviceRole::Contributor | DeviceRole::Viewer
    )
}

fn mobile_role_can_search(role: &DeviceRole) -> bool {
    mobile_role_can_browse(role)
}

fn mobile_role_can_download_originals(role: &DeviceRole) -> bool {
    mobile_role_can_browse(role)
}

fn mobile_role_can_contribute(role: &DeviceRole) -> bool {
    matches!(role, DeviceRole::Admin | DeviceRole::Contributor)
}

fn mobile_role_can_manage_storage(role: &DeviceRole) -> bool {
    matches!(
        role,
        DeviceRole::Admin | DeviceRole::Contributor | DeviceRole::StorageOnly
    )
}

fn mobile_role_denied(action: &str, role: &DeviceRole) -> ServiceError {
    ServiceError::Invalid(format!(
        "mobile role {} cannot {action}",
        mobile_role_label(role)
    ))
}

fn mobile_role_label(role: &DeviceRole) -> &'static str {
    match role {
        DeviceRole::Admin => "admin",
        DeviceRole::Contributor => "contributor",
        DeviceRole::Viewer => "viewer",
        DeviceRole::StorageOnly => "storage-only",
    }
}

fn ensure_mobile_can_browse(
    state: &LibraryState,
    session: &MobileSession,
) -> Result<(), ServiceError> {
    let role = mobile_session_role(state, session)?;
    if mobile_role_can_browse(&role) {
        Ok(())
    } else {
        Err(mobile_role_denied("browse library content", &role))
    }
}

fn ensure_mobile_can_search(
    state: &LibraryState,
    session: &MobileSession,
) -> Result<(), ServiceError> {
    let role = mobile_session_role(state, session)?;
    if mobile_role_can_search(&role) {
        Ok(())
    } else {
        Err(mobile_role_denied("search library content", &role))
    }
}

fn ensure_mobile_can_download_originals(
    state: &LibraryState,
    session: &MobileSession,
) -> Result<(), ServiceError> {
    let role = mobile_session_role(state, session)?;
    if mobile_role_can_download_originals(&role) {
        Ok(())
    } else {
        Err(mobile_role_denied("download originals", &role))
    }
}

fn ensure_mobile_can_contribute(
    state: &LibraryState,
    session: &MobileSession,
    action: &str,
) -> Result<(), ServiceError> {
    let role = mobile_session_role(state, session)?;
    if mobile_role_can_contribute(&role) {
        Ok(())
    } else {
        Err(mobile_role_denied(action, &role))
    }
}

fn ensure_mobile_can_manage_storage(
    state: &LibraryState,
    session: &MobileSession,
) -> Result<(), ServiceError> {
    let role = mobile_session_role(state, session)?;
    if mobile_role_can_manage_storage(&role) {
        Ok(())
    } else {
        Err(mobile_role_denied("contribute encrypted storage", &role))
    }
}

fn mobile_workspace_capabilities(
    role: &DeviceRole,
    accepts_storage: bool,
) -> MobileWorkspaceCapabilities {
    let can_browse = mobile_role_can_browse(role);
    let can_search = mobile_role_can_search(role);
    let can_upload = mobile_role_can_contribute(role);
    let can_download = mobile_role_can_download_originals(role);
    let can_manage_storage = mobile_role_can_manage_storage(role) && accepts_storage;
    let role_detail = match role {
        DeviceRole::Admin => {
            if accepts_storage {
                "Admin mobile access can browse, search, upload, download, manage sessions, and contribute encrypted vault chunks."
            } else {
                "Admin mobile access can browse, search, upload, download, and manage sessions. Enable storage contribution before this device receives encrypted chunks."
            }
        }
        DeviceRole::Contributor => {
            if accepts_storage {
                "Contributor mobile access can browse, search, upload, download, curate tags/favorites, and contribute encrypted vault chunks."
            } else {
                "Contributor mobile access can browse, search, upload camera-roll media, download originals, and curate tags/favorites."
            }
        }
        DeviceRole::Viewer => {
            "Viewer mobile access is read-only: browse, search, and download are allowed; uploads, curation changes, and storage contribution are blocked."
        }
        DeviceRole::StorageOnly => {
            if accepts_storage {
                "Storage-only mobile access cannot browse or download content; it can receive and prove encrypted vault chunks for protection."
            } else {
                "Storage-only mobile access cannot browse or download content. Enable storage contribution before it receives encrypted vault chunks."
            }
        }
    };
    MobileWorkspaceCapabilities {
        can_browse_library: can_browse,
        can_search,
        can_upload_camera_roll: can_upload,
        can_download_originals: can_download,
        can_manage_storage,
        can_import_desktop_folders: false,
        can_run_models: false,
        role_detail: role_detail.to_string(),
    }
}

fn new_mobile_bearer_token() -> String {
    format!(
        "pgm_{}_{}",
        Uuid::new_v4().simple(),
        Uuid::new_v4().simple()
    )
}

fn hash_mobile_token(token: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(token.trim().as_bytes());
    hex_string(&hasher.finalize())
}

fn hex_string(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut value = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        value.push(HEX[(byte >> 4) as usize] as char);
        value.push(HEX[(byte & 0x0f) as usize] as char);
    }
    value
}

fn mobile_upload_index_for_session(
    state: &LibraryState,
    session: &MobileSession,
    upload_id: Uuid,
) -> Result<usize, ServiceError> {
    let upload_index = state
        .mobile_uploads
        .iter()
        .position(|upload| upload.id == upload_id)
        .ok_or_else(|| ServiceError::NotFound(format!("mobile upload {upload_id}")))?;
    if state.mobile_uploads[upload_index].session_id != session.id {
        return Err(ServiceError::Invalid(
            "mobile upload does not belong to this session".to_string(),
        ));
    }
    Ok(upload_index)
}

fn ensure_mobile_upload_accepts_bytes(upload: &MobileUpload) -> Result<(), ServiceError> {
    if matches!(
        upload.status,
        MobileUploadStatus::Failed | MobileUploadStatus::Canceled
    ) {
        return Err(ServiceError::Invalid(
            "mobile upload is no longer accepting bytes".to_string(),
        ));
    }
    Ok(())
}

fn mobile_upload_dir(config: &AppConfig, upload_id: Uuid) -> PathBuf {
    config
        .runtime_root
        .join("mobile_uploads")
        .join(upload_id.to_string())
}

fn mobile_upload_path(config: &AppConfig, upload: &MobileUpload) -> PathBuf {
    mobile_upload_dir(config, upload.id).join(format!("{}.part", upload.original_filename))
}

fn reconcile_mobile_upload_progress(
    upload: &mut MobileUpload,
    upload_path: &Path,
) -> Result<bool, ServiceError> {
    if matches!(
        upload.status,
        MobileUploadStatus::Completed | MobileUploadStatus::Failed | MobileUploadStatus::Canceled
    ) {
        return Ok(false);
    }

    let staged_len = match fs::metadata(upload_path) {
        Ok(metadata) => metadata.len(),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => 0,
        Err(err) => {
            return Err(ServiceError::Io(format!(
                "failed to inspect mobile upload staging file: {err}"
            )));
        }
    };
    if staged_len > upload.bytes_total {
        let detail = format!(
            "mobile upload staging file exceeds reserved size: reserved {}, staged {}",
            upload.bytes_total, staged_len
        );
        upload.status = MobileUploadStatus::Failed;
        upload.error_detail = Some(detail.clone());
        upload.updated_at = Utc::now();
        return Err(ServiceError::Invalid(detail));
    }
    if staged_len != upload.bytes_received {
        upload.bytes_received = staged_len;
        upload.status = if staged_len == 0 {
            MobileUploadStatus::Pending
        } else {
            MobileUploadStatus::Running
        };
        upload.updated_at = Utc::now();
        return Ok(true);
    }
    Ok(false)
}

fn append_mobile_upload_chunk(
    upload_path: &Path,
    offset: u64,
    bytes: &[u8],
) -> Result<(), ServiceError> {
    let mut file = fs::OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(upload_path)
        .map_err(|err| ServiceError::Io(format!("failed to open mobile upload chunk: {err}")))?;
    let staged_len = file
        .metadata()
        .map_err(|err| {
            ServiceError::Io(format!("failed to inspect mobile upload chunk file: {err}"))
        })?
        .len();
    if staged_len != offset {
        return Err(ServiceError::Invalid(format!(
            "mobile upload staging length mismatch: expected offset {}, found {}",
            offset, staged_len
        )));
    }
    file.seek(SeekFrom::Start(offset))
        .map_err(|err| ServiceError::Io(format!("failed to seek mobile upload chunk: {err}")))?;
    file.write_all(bytes)
        .map_err(|err| ServiceError::Io(format!("failed to write mobile upload chunk: {err}")))?;
    file.sync_data()
        .map_err(|err| ServiceError::Io(format!("failed to sync mobile upload chunk: {err}")))?;
    Ok(())
}

fn normalize_original_range(
    total_bytes: u64,
    range: ByteRangeRequest,
) -> Result<(u64, u64), ServiceError> {
    if total_bytes == 0 {
        return Err(ServiceError::Invalid(
            "cannot range-read an empty original".to_string(),
        ));
    }
    let max_end = total_bytes - 1;
    match range {
        ByteRangeRequest::Start { start, end } => {
            if start >= total_bytes {
                return Err(ServiceError::Invalid(format!(
                    "range start {start} is outside original size {total_bytes}"
                )));
            }
            let requested_end = end.unwrap_or(max_end).min(max_end);
            if requested_end < start {
                return Err(ServiceError::Invalid(
                    "range end must be greater than or equal to range start".to_string(),
                ));
            }
            let capped_end = requested_end.min(
                start
                    .saturating_add(ORIGINAL_DOWNLOAD_RANGE_MAX_BYTES)
                    .saturating_sub(1),
            );
            Ok((start, capped_end))
        }
        ByteRangeRequest::Suffix { length } => {
            if length == 0 {
                return Err(ServiceError::Invalid(
                    "suffix byte range length must be greater than zero".to_string(),
                ));
            }
            let capped_length = length
                .min(ORIGINAL_DOWNLOAD_RANGE_MAX_BYTES)
                .min(total_bytes);
            let start = total_bytes - capped_length;
            Ok((start, max_end))
        }
    }
}

fn read_file_range(path: &Path, start: u64, end: u64) -> Result<Vec<u8>, ServiceError> {
    let len = end
        .checked_sub(start)
        .and_then(|value| value.checked_add(1))
        .ok_or_else(|| ServiceError::Invalid("invalid original byte range".to_string()))?;
    let mut file = fs::File::open(path).map_err(|err| ServiceError::Io(err.to_string()))?;
    file.seek(SeekFrom::Start(start))
        .map_err(|err| ServiceError::Io(err.to_string()))?;
    let mut bytes = Vec::with_capacity(len.min(usize::MAX as u64) as usize);
    file.take(len)
        .read_to_end(&mut bytes)
        .map_err(|err| ServiceError::Io(err.to_string()))?;
    if bytes.len() as u64 != len {
        return Err(ServiceError::Io(format!(
            "original file ended before byte range {start}-{end} was read"
        )));
    }
    Ok(bytes)
}

fn sanitize_mobile_filename(raw: &str) -> Result<String, ServiceError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(ServiceError::Invalid(
            "original_filename is required".to_string(),
        ));
    }
    let name = Path::new(trimmed)
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or(trimmed)
        .trim();
    let sanitized = name
        .chars()
        .map(|value| {
            if value.is_ascii_alphanumeric() || matches!(value, '.' | '-' | '_' | ' ') {
                value
            } else {
                '_'
            }
        })
        .collect::<String>();
    let sanitized = sanitized.trim_matches([' ', '.']).to_string();
    if sanitized.is_empty() {
        return Err(ServiceError::Invalid(
            "original_filename must include a usable file name".to_string(),
        ));
    }
    Ok(sanitized)
}

fn build_device_identity(
    device_id: Option<Uuid>,
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
    let id = device_id.unwrap_or_else(Uuid::new_v4);
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
        .any(|existing| existing.id == device.id)
    {
        return Err(ServiceError::Invalid(
            "device id is already enrolled".to_string(),
        ));
    }
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
            "No runnable transfers are available locally; start P2P sync and enroll peer endpoints to move encrypted originals.".to_string()
        } else {
            format!(
                "{} transfer(s) are ready for the P2P transport; originals stay off hosted services.",
                transfers.len()
            )
        },
        transfers,
        under_replicated_blob_ids,
        execution_results: Vec::new(),
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

fn execution_result(
    transfer: &SyncTransfer,
    status: SyncTransferExecutionStatus,
    bytes_transferred: u64,
    detail: String,
) -> SyncTransferExecutionResult {
    SyncTransferExecutionResult {
        transfer_id: transfer.id,
        blob_id: transfer.blob_id,
        from_device_id: transfer.from_device_id,
        to_device_id: transfer.to_device_id,
        status,
        bytes_transferred,
        detail,
    }
}

fn build_sync_network_status(
    state: &LibraryState,
    runtime: sync_transport::RuntimeStatus,
) -> SyncNetworkStatus {
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
    let persisted_relay_urls = state
        .relay_endpoints
        .iter()
        .filter(|endpoint| Some(endpoint.device_id) == local_device_id)
        .filter_map(|endpoint| endpoint.relay_url.clone())
        .collect::<Vec<_>>();
    let persisted_direct_addresses = state
        .relay_endpoints
        .iter()
        .filter(|endpoint| Some(endpoint.device_id) == local_device_id)
        .flat_map(|endpoint| endpoint.direct_addresses.clone())
        .collect::<Vec<_>>();

    SyncNetworkStatus {
        started: runtime.started,
        transport: "iroh-quic-v1; encrypted-content-addressed-vault-chunks".to_string(),
        local_device_id,
        local_node_id: runtime.local_node_id.or_else(|| {
            local_device_id.and_then(|id| {
                state
                    .devices
                    .iter()
                    .find(|device| device.id == id)
                    .map(|device| device.public_key.clone())
            })
        }),
        direct_addresses: if runtime.direct_addresses.is_empty() {
            persisted_direct_addresses
        } else {
            runtime.direct_addresses
        },
        relay_urls: if runtime.relay_urls.is_empty() {
            persisted_relay_urls
        } else {
            runtime.relay_urls
        },
        active_transfer_count,
        pending_transfer_count,
        completed_transfer_count,
        failed_transfer_count,
        detail: runtime.detail,
    }
}

fn device_is_active(devices: &[DeviceIdentity], device_id: Uuid) -> bool {
    devices
        .iter()
        .any(|device| device.id == device_id && device.revoked_at.is_none())
}

fn verified_remote_replica_count(
    state: &LibraryState,
    blob: &BlobRecord,
    local_device: Uuid,
) -> usize {
    state
        .blob_replicas
        .iter()
        .filter(|replica| {
            replica.blob_id == blob.id
                && replica.device_id != local_device
                && replica.health == ReplicaHealth::Healthy
                && device_is_active(&state.devices, replica.device_id)
                && replica.transfer_id.is_some_and(|transfer_id| {
                    state.sync_transfers.iter().any(|transfer| {
                        transfer.id == transfer_id
                            && transfer.blob_id == blob.id
                            && transfer.to_device_id == replica.device_id
                            && transfer.status == SyncTransferStatus::Completed
                            && transfer.bytes_completed >= blob.bytes
                    })
                })
        })
        .count()
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
    let encrypted_only_originals = state
        .library_settings
        .as_ref()
        .map(|settings| settings.original_storage_policy == OriginalStoragePolicy::EncryptedOnly)
        .unwrap_or(true);
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
        if encrypted_only_originals
            && matches!(asset.import_mode, ImportMode::Copy | ImportMode::Move)
        {
            continue;
        }
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
    if let Some(active_library_root) = active_library_root
        && paths_overlap(&restore_root, active_library_root)
    {
        destination_conflicts.push(format!(
            "{} overlaps active library {}",
            restore_root.to_string_lossy(),
            active_library_root.to_string_lossy()
        ));
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

fn sync_transport_error(error: sync_transport::SyncTransportError) -> ServiceError {
    match error {
        sync_transport::SyncTransportError::Invalid(message)
        | sync_transport::SyncTransportError::Transport(message) => ServiceError::Invalid(message),
        sync_transport::SyncTransportError::Io(message) => ServiceError::Io(message),
        sync_transport::SyncTransportError::Storage(message) => ServiceError::Storage(message),
        sync_transport::SyncTransportError::NotStarted => {
            ServiceError::Invalid("P2P sync network is not started".to_string())
        }
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

fn search_query_has_filters(query: &SearchQuery) -> bool {
    string_filter_present(query.text.as_deref())
        || string_filter_present(query.people.as_deref())
        || string_filter_present(query.places.as_deref())
        || string_filter_present(query.events.as_deref())
        || string_filter_present(query.workspace.as_deref())
        || string_filter_present(query.client.as_deref())
        || string_filter_present(query.project.as_deref())
        || string_filter_present(query.topic.as_deref())
        || string_filter_present(query.source_folder.as_deref())
        || string_filter_present(query.device.as_deref())
        || string_filter_present(query.media_kind.as_deref())
        || string_filter_present(query.tags.as_deref())
        || query.favorite.is_some()
        || string_filter_present(query.from_date.as_deref())
        || string_filter_present(query.to_date.as_deref())
}

fn string_filter_present(value: Option<&str>) -> bool {
    value.map(str::trim).is_some_and(|value| !value.is_empty())
}

fn normalize_manual_tags(tags: Vec<String>) -> Result<Vec<String>, ServiceError> {
    const MAX_TAGS: usize = 50;
    const MAX_TAG_CHARS: usize = 64;

    let mut normalized = Vec::new();
    let mut seen = BTreeSet::<String>::new();
    for raw in tags {
        let tag = raw.trim();
        if tag.is_empty() {
            continue;
        }
        if tag.chars().count() > MAX_TAG_CHARS {
            return Err(ServiceError::Invalid(format!(
                "manual tag '{tag}' exceeds {MAX_TAG_CHARS} characters"
            )));
        }
        let key = tag.to_lowercase();
        if seen.insert(key) {
            normalized.push(tag.to_string());
        }
    }
    if normalized.len() > MAX_TAGS {
        return Err(ServiceError::Invalid(format!(
            "manual tags cannot exceed {MAX_TAGS} entries"
        )));
    }
    Ok(normalized)
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

fn timeline_response_for_assets(
    mut assets: Vec<Asset>,
    asset_limit: Option<usize>,
    per_bucket_limit: Option<usize>,
    cursor_offset: Option<usize>,
    include_archived: bool,
) -> TimelineResponse {
    assets.retain(|asset| include_archived || !asset.archived);
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

fn asset_ids_for_vault(state: &LibraryState, vault_id: Uuid) -> BTreeSet<Uuid> {
    state
        .blob_records
        .iter()
        .filter(|blob| blob.vault_id == vault_id && blob.tombstoned_at.is_none())
        .map(|blob| blob.asset_id)
        .collect()
}

fn ensure_asset_belongs_to_vault(
    state: &LibraryState,
    vault_id: Uuid,
    asset_id: Uuid,
) -> Result<(), ServiceError> {
    if state.blob_records.iter().any(|blob| {
        blob.vault_id == vault_id && blob.asset_id == asset_id && blob.tombstoned_at.is_none()
    }) {
        Ok(())
    } else {
        Err(ServiceError::NotFound(format!("asset {asset_id}")))
    }
}

fn filter_albums_for_assets(albums: &[Album], visible_asset_ids: &BTreeSet<Uuid>) -> Vec<Album> {
    albums
        .iter()
        .filter_map(|album| {
            let asset_ids = album
                .asset_ids
                .iter()
                .copied()
                .filter(|id| visible_asset_ids.contains(id))
                .collect::<Vec<_>>();
            if asset_ids.is_empty() {
                return None;
            }
            let mut album = album.clone();
            album.cover_asset_id = album
                .cover_asset_id
                .filter(|id| visible_asset_ids.contains(id))
                .or_else(|| asset_ids.first().copied());
            album.asset_ids = asset_ids;
            Some(album)
        })
        .collect()
}

fn filter_people_for_assets(
    people: &[PersonCluster],
    visible_asset_ids: &BTreeSet<Uuid>,
) -> Vec<PersonCluster> {
    people
        .iter()
        .filter(|person| !person.hidden)
        .filter_map(|person| {
            let asset_ids = person
                .asset_ids
                .iter()
                .copied()
                .filter(|id| visible_asset_ids.contains(id))
                .collect::<Vec<_>>();
            if asset_ids.is_empty() {
                return None;
            }
            let mut person = person.clone();
            person.asset_ids = asset_ids;
            person.representative_asset_id = person
                .representative_asset_id
                .filter(|id| visible_asset_ids.contains(id))
                .or_else(|| person.asset_ids.first().copied());
            Some(person)
        })
        .collect()
}

fn filter_places_for_assets(
    places: &[PlaceCluster],
    visible_asset_ids: &BTreeSet<Uuid>,
) -> Vec<PlaceCluster> {
    places
        .iter()
        .filter_map(|place| {
            let asset_ids = place
                .asset_ids
                .iter()
                .copied()
                .filter(|id| visible_asset_ids.contains(id))
                .collect::<Vec<_>>();
            if asset_ids.is_empty() {
                return None;
            }
            let mut place = place.clone();
            place.asset_ids = asset_ids;
            Some(place)
        })
        .collect()
}

fn filter_events_for_assets(
    events: &[EventCluster],
    visible_asset_ids: &BTreeSet<Uuid>,
) -> Vec<EventCluster> {
    events
        .iter()
        .filter_map(|event| {
            let asset_ids = event
                .asset_ids
                .iter()
                .copied()
                .filter(|id| visible_asset_ids.contains(id))
                .collect::<Vec<_>>();
            if asset_ids.is_empty() {
                return None;
            }
            let mut event = event.clone();
            event.asset_ids = asset_ids;
            Some(event)
        })
        .collect()
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

pub(crate) fn effective_library_root(state: &LibraryState, config: &AppConfig) -> String {
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

fn enum_label<T: Serialize>(value: &T, fallback: &str) -> String {
    serde_json::to_value(value)
        .ok()
        .and_then(|value| value.as_str().map(ToString::to_string))
        .unwrap_or_else(|| fallback.to_string())
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

fn build_entitlement_status(
    cache: Option<&EntitlementCache>,
    now: chrono::DateTime<Utc>,
) -> EntitlementStatusResponse {
    let Some(cache) = cache else {
        let tier = EntitlementTier::PersonalCore;
        return EntitlementStatusResponse {
            tier,
            effective_status: EntitlementEffectiveStatus::Active,
            limits: tier.default_limits(),
            cache: None,
            offline_grace_active: false,
            paid_features_available: true,
            safe_local_access_allowed: true,
            content_exposure_prevented: true,
            detail: "Personal core local access is available without sending content or metadata to a billing service.".to_string(),
        };
    };

    let active_window = cache
        .expires_at
        .as_ref()
        .map(|expires_at| expires_at > &now)
        .unwrap_or(true);
    let cache_is_active = cache.status == EntitlementCacheStatus::Active && active_window;
    let offline_grace_active = !cache_is_active
        && cache
            .offline_grace_expires_at
            .as_ref()
            .map(|expires_at| expires_at > &now)
            .unwrap_or(false);
    let effective_status = if cache_is_active {
        EntitlementEffectiveStatus::Active
    } else if offline_grace_active {
        EntitlementEffectiveStatus::OfflineGrace
    } else {
        match cache.status {
            EntitlementCacheStatus::Unavailable => EntitlementEffectiveStatus::Unavailable,
            EntitlementCacheStatus::Active
            | EntitlementCacheStatus::PastDue
            | EntitlementCacheStatus::Canceled
            | EntitlementCacheStatus::Expired => EntitlementEffectiveStatus::Expired,
        }
    };

    let paid_features_available = matches!(
        effective_status,
        EntitlementEffectiveStatus::Active | EntitlementEffectiveStatus::OfflineGrace
    );
    let detail = match effective_status {
        EntitlementEffectiveStatus::Active => {
            "Entitlement is active. Checks use only privacy-preserving billing identifiers and coarse limits."
        }
        EntitlementEffectiveStatus::OfflineGrace => {
            "Billing is unavailable or stale, so offline grace is preserving paid features without exposing content."
        }
        EntitlementEffectiveStatus::Expired => {
            "Paid features are outside the entitlement window. Already-local access, export, restore, and revocation remain available."
        }
        EntitlementEffectiveStatus::Unavailable => {
            "Entitlement state is unavailable. Already-local access, export, restore, and revocation remain available."
        }
    };

    EntitlementStatusResponse {
        tier: cache.tier,
        effective_status,
        limits: cache.limits.clone(),
        cache: Some(cache.clone()),
        offline_grace_active,
        paid_features_available,
        safe_local_access_allowed: true,
        content_exposure_prevented: true,
        detail: detail.to_string(),
    }
}

fn build_platform_release_readiness(
    now: chrono::DateTime<Utc>,
) -> PlatformReleaseReadinessResponse {
    let surfaces = vec![
        platform_surface(
            PlatformReleaseSurface::LinuxDesktop,
            "Linux desktop",
            PlatformReleaseReadinessStatus::InProgress,
            "Direct Linux bundle/package",
            vec![
                evidence(
                    "linux_runner",
                    "Flutter Linux runner",
                    PlatformReleaseEvidenceStatus::Passed,
                    "Linux desktop runner exists and is part of the current desktop MVP.",
                ),
                evidence(
                    "linux_release_script",
                    "Linux release bundle script",
                    PlatformReleaseEvidenceStatus::Partial,
                    "A local bundle script exists, but final release still needs immutable artifact, checksum/signing, and smoke evidence.",
                ),
                evidence(
                    "linux_release_smoke",
                    "Daemon/import/search/vault/backup smoke",
                    PlatformReleaseEvidenceStatus::Missing,
                    "Run and record the release-bundle smoke on a clean Linux machine before publishing.",
                ),
            ],
            vec![
                "Missing signed or checksummed release artifact evidence.",
                "Missing clean-machine Linux release smoke evidence.",
            ],
            "Produce a checksummed Linux bundle from a tag and record daemon startup, import, search, vault, backup, and rollback evidence.",
        ),
        platform_surface(
            PlatformReleaseSurface::WindowsDesktop,
            "Windows desktop",
            PlatformReleaseReadinessStatus::InProgress,
            "Signed Windows installer/package",
            vec![
                evidence(
                    "windows_runner",
                    "Flutter Windows runner",
                    PlatformReleaseEvidenceStatus::Passed,
                    "Windows desktop runner exists.",
                ),
                evidence(
                    "windows_installer",
                    "Installer/update/uninstall flow",
                    PlatformReleaseEvidenceStatus::Missing,
                    "No signed Windows installer, update, uninstall, or rollback evidence is recorded.",
                ),
                evidence(
                    "windows_secure_storage",
                    "Windows secure-storage validation",
                    PlatformReleaseEvidenceStatus::Missing,
                    "Validate key/token storage behavior on Windows before release.",
                ),
            ],
            vec![
                "Missing signed installer/package.",
                "Missing Windows secure-storage and lifecycle smoke evidence.",
            ],
            "Add a Windows packaging pipeline and run daemon launch, secure storage, import/vault, update, and uninstall smokes.",
        ),
        platform_surface(
            PlatformReleaseSurface::MacosDesktop,
            "macOS desktop",
            PlatformReleaseReadinessStatus::InProgress,
            "Signed and notarized macOS app",
            vec![
                evidence(
                    "macos_runner",
                    "Flutter macOS runner",
                    PlatformReleaseEvidenceStatus::Passed,
                    "macOS desktop runner exists.",
                ),
                evidence(
                    "macos_sign_notarize",
                    "Signing and notarization",
                    PlatformReleaseEvidenceStatus::Missing,
                    "No signing, notarization, Gatekeeper, or rollback evidence is recorded.",
                ),
                evidence(
                    "macos_keychain_privacy",
                    "Keychain and privacy prompt review",
                    PlatformReleaseEvidenceStatus::Missing,
                    "Validate keychain storage and file/media permission prompts before release.",
                ),
            ],
            vec![
                "Missing signing/notarization pipeline.",
                "Missing macOS keychain and privacy prompt evidence.",
            ],
            "Build a signed/notarized macOS artifact and record keychain, sandbox/privacy prompt, import, vault, update, and rollback evidence.",
        ),
        platform_surface(
            PlatformReleaseSurface::AndroidPlayStore,
            "Android / Play Store",
            PlatformReleaseReadinessStatus::InProgress,
            "Release-signed APK/AAB through Play Store",
            vec![
                evidence(
                    "android_runner",
                    "Flutter Android runner",
                    PlatformReleaseEvidenceStatus::Passed,
                    "Android runner exists with pairing, upload, download, and storage contribution flows.",
                ),
                evidence(
                    "android_smoke_scripts",
                    "Android API and app smoke scripts",
                    PlatformReleaseEvidenceStatus::Partial,
                    "Two-phone API/app smoke scripts exist; release evidence must run them with real devices and signing enabled.",
                ),
                evidence(
                    "play_store_policy",
                    "Play Store signing and privacy declarations",
                    PlatformReleaseEvidenceStatus::Missing,
                    "Release signing, Play declarations, staged rollout, and store privacy evidence are not yet recorded.",
                ),
            ],
            vec![
                "Missing release-signed APK/AAB evidence.",
                "Missing Play policy/privacy declaration evidence.",
                "Native Android chunk transport remains future work.",
            ],
            "Run release signing readiness, two-phone pairing/upload/download/storage-node smokes, and prepare Play privacy/staged rollout evidence.",
        ),
        platform_surface(
            PlatformReleaseSurface::IosAppStore,
            "iOS / App Store",
            PlatformReleaseReadinessStatus::InProgress,
            "Signed iOS app through App Store",
            vec![
                evidence(
                    "ios_runner",
                    "Flutter iOS runner",
                    PlatformReleaseEvidenceStatus::Passed,
                    "Flutter iOS runner exists with Private Gallery app identity.",
                ),
                evidence(
                    "ios_permissions",
                    "iOS media/files permissions and secure storage",
                    PlatformReleaseEvidenceStatus::Partial,
                    "iOS camera and photo-library privacy prompts are declared; secure storage, file access, and background transfer behavior still need device tests.",
                ),
                evidence(
                    "app_store_privacy",
                    "App Store privacy labels and review evidence",
                    PlatformReleaseEvidenceStatus::Missing,
                    "App Store signing, privacy labels, and review evidence are not recorded.",
                ),
            ],
            vec![
                "Missing App Store signing/privacy label evidence.",
                "Missing iOS secure-storage, file access, and transfer smoke evidence.",
            ],
            "Build and sign the iOS target on macOS, then record pairing, upload/download, secure storage, file permission, privacy label, and review evidence.",
        ),
        platform_surface(
            PlatformReleaseSurface::WebBrowser,
            "Web/browser",
            PlatformReleaseReadinessStatus::InProgress,
            "Browser client with no default company-hosted content",
            vec![
                evidence(
                    "web_runner",
                    "Flutter/web browser target",
                    PlatformReleaseEvidenceStatus::Passed,
                    "Flutter web runner exists and builds to build/web.",
                ),
                evidence(
                    "web_privacy_boundary",
                    "No-content web boundary",
                    PlatformReleaseEvidenceStatus::Partial,
                    "Browser client points at a user-supplied trusted device URL and has no default company-hosted content path; auth/session, storage limits, CORS/CSRF, and local-web exposure still need smoke evidence.",
                ),
                evidence(
                    "web_upload_download_smoke",
                    "Browser upload/download smoke",
                    PlatformReleaseEvidenceStatus::Missing,
                    "Browser upload/download behavior is not implemented or tested.",
                ),
            ],
            vec![
                "Missing browser upload/download smoke evidence.",
                "Missing browser auth/session, CORS/CSRF, and storage-boundary evidence.",
            ],
            "Run browser upload/download, session, storage-limit, CORS/CSRF, and no-hosted-content smokes against the web build.",
        ),
        platform_surface(
            PlatformReleaseSurface::LocalWebUi,
            "Local web UI",
            PlatformReleaseReadinessStatus::InProgress,
            "Browser UI served from a trusted local device",
            vec![
                evidence(
                    "desktop_route_boundary",
                    "Remote desktop/admin route isolation",
                    PlatformReleaseEvidenceStatus::Passed,
                    "Daemon route-boundary tests keep desktop/admin APIs blocked for remote clients while allowing static local-web assets.",
                ),
                evidence(
                    "local_web_serving",
                    "Trusted-device local web serving",
                    PlatformReleaseEvidenceStatus::Partial,
                    "The daemon can serve a built Flutter web bundle from PRIVATE_GALLERY_LOCAL_WEB_ROOT at /local-web; release still needs packaged bundle and browser smoke evidence.",
                ),
                evidence(
                    "tailscale_lan_rules",
                    "LAN/Tailscale exposure rules",
                    PlatformReleaseEvidenceStatus::Partial,
                    "Remote clients may receive /local-web static assets, /health, and paired /mobile/* routes; desktop/admin APIs remain blocked, but final CSRF/CORS and exposure review is still required.",
                ),
            ],
            vec![
                "Missing packaged local-web bundle smoke evidence.",
                "Missing CSRF/CORS and browser route-exposure review.",
            ],
            "Package the web bundle for local serving, then run browser, CSRF/CORS, and remote route-boundary smokes against /local-web.",
        ),
        platform_surface(
            PlatformReleaseSurface::DirectDesktopDistribution,
            "Direct desktop distribution",
            PlatformReleaseReadinessStatus::InProgress,
            "Direct installers/packages outside app stores",
            vec![
                evidence(
                    "desktop_runners",
                    "Desktop runners",
                    PlatformReleaseEvidenceStatus::Passed,
                    "Linux, Windows, and macOS desktop runners exist.",
                ),
                evidence(
                    "checksums_signing",
                    "Checksums, signing, and update channel",
                    PlatformReleaseEvidenceStatus::Missing,
                    "Release checksums/signing, update strategy, and rollback evidence are not recorded.",
                ),
                evidence(
                    "support_diagnostics",
                    "Support diagnostics",
                    PlatformReleaseEvidenceStatus::Passed,
                    "Redacted local support bundle export exists and excludes content, paths, metadata, keys, tokens, and account hashes.",
                ),
            ],
            vec![
                "Missing cross-desktop packaging/signing evidence.",
                "Missing update and rollback path.",
            ],
            "Create repeatable desktop packaging jobs with checksums/signing, update/rollback notes, and release-machine support-bundle evidence.",
        ),
    ];
    let ready_surface_count = surfaces
        .iter()
        .filter(|surface| surface.status == PlatformReleaseReadinessStatus::Ready)
        .count();
    PlatformReleaseReadinessResponse {
        generated_at: now,
        overall_status: PlatformReleaseReadinessStatus::InProgress,
        required_surface_count: surfaces.len(),
        ready_surface_count,
        surfaces,
        detail: "Cross-platform release is not complete until every required surface has repeatable signing, packaging/store, privacy, smoke-test, update, and rollback evidence.".to_string(),
    }
}

fn platform_surface(
    surface: PlatformReleaseSurface,
    label: &str,
    status: PlatformReleaseReadinessStatus,
    distribution: &str,
    evidence: Vec<PlatformReleaseEvidence>,
    blockers: Vec<&str>,
    next_step: &str,
) -> PlatformReleaseSurfaceReadiness {
    PlatformReleaseSurfaceReadiness {
        surface,
        label: label.to_string(),
        status,
        distribution: distribution.to_string(),
        evidence,
        blockers: blockers.into_iter().map(ToString::to_string).collect(),
        next_step: next_step.to_string(),
    }
}

fn evidence(
    key: &str,
    label: &str,
    status: PlatformReleaseEvidenceStatus,
    detail: &str,
) -> PlatformReleaseEvidence {
    PlatformReleaseEvidence {
        key: key.to_string(),
        label: label.to_string(),
        status,
        detail: detail.to_string(),
    }
}

fn support_bundle_redacted_fields() -> Vec<String> {
    [
        "library_root",
        "database_path",
        "source_path",
        "relative_original_path",
        "original_filename",
        "sidecar_title",
        "sidecar_description",
        "folder_hint",
        "manual_tags",
        "ocr_text",
        "face_templates",
        "embeddings",
        "exact_gps",
        "captured_at",
        "vault_keys",
        "bearer_tokens",
        "pairing_tokens",
        "account_id_hash",
        "device_display_names",
        "audit_summaries",
    ]
    .into_iter()
    .map(ToString::to_string)
    .collect()
}

fn entitlement_cache_detail(status: EntitlementCacheStatus) -> &'static str {
    match status {
        EntitlementCacheStatus::Active => "Cached active entitlement; no content metadata stored.",
        EntitlementCacheStatus::PastDue => {
            "Cached past-due entitlement; offline grace decides paid feature availability."
        }
        EntitlementCacheStatus::Canceled => {
            "Cached canceled entitlement; safe local access remains available."
        }
        EntitlementCacheStatus::Expired => {
            "Cached expired entitlement; safe local access remains available."
        }
        EntitlementCacheStatus::Unavailable => {
            "Cached unavailable entitlement; safe local access remains available."
        }
    }
}

fn trim_optional_string(raw: Option<&str>) -> Option<String> {
    raw.map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
}

fn normalize_public_code(raw: Option<&str>, field: &str) -> Result<Option<String>, ServiceError> {
    let Some(value) = trim_optional_string(raw) else {
        return Ok(None);
    };
    if value.len() > 80 {
        return Err(ServiceError::Invalid(format!(
            "{field} must be 80 characters or fewer"
        )));
    }
    if !value
        .chars()
        .all(|value| value.is_ascii_alphanumeric() || matches!(value, '_' | '-' | '.'))
    {
        return Err(ServiceError::Invalid(format!(
            "{field} must use only letters, numbers, dots, dashes, or underscores"
        )));
    }
    Ok(Some(value))
}

fn normalize_account_id_hash(raw: Option<&str>) -> Result<Option<String>, ServiceError> {
    let Some(value) = trim_optional_string(raw) else {
        return Ok(None);
    };
    if value.len() < 32 || value.len() > 128 || !value.chars().all(|item| item.is_ascii_hexdigit())
    {
        return Err(ServiceError::Invalid(
            "account_id_hash must be a hash-like hexadecimal identifier and must not contain email, device, file, or path data".to_string(),
        ));
    }
    Ok(Some(value.to_ascii_lowercase()))
}

fn push_audit_event<Action, TargetKind, Summary>(
    state: &mut LibraryState,
    action: Action,
    target: (TargetKind, Option<Uuid>),
    actor: (Option<Uuid>, Option<String>),
    summary: Summary,
    payload: serde_json::Value,
) where
    Action: Into<String>,
    TargetKind: Into<String>,
    Summary: Into<String>,
{
    state.audit_events.insert(
        0,
        AuditEvent {
            id: Uuid::new_v4(),
            action: action.into(),
            target_kind: target.0.into(),
            target_id: target.1,
            actor_device_id: actor.0,
            actor_label: actor.1,
            summary: summary.into(),
            payload,
            created_at: Utc::now(),
        },
    );
    if state.audit_events.len() > 1000 {
        state.audit_events.truncate(1000);
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
    let mut extracted = metadata::extract_import_metadata(
        source_path,
        &candidate.sidecar_paths,
        candidate.captured_at.unwrap_or(asset.captured_at),
    );
    extracted.organization = candidate.organization.clone();
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

    use chrono::{Datelike, Duration, Utc};

    use crate::{
        config::AppConfig,
        domain::{
            AssetAvailabilityState, BlobReplica, CorrectDateRequest, CorrectPlaceRequest,
            CreateAlbumRequest, CreateDeviceRequest, CreateFileFolderRequest,
            CreateManualPersonRequest, CreatePairingSessionRequest, CreateSmartFolderRequest,
            CreateVaultRequest, DeviceRole, DeviceStorageProfile, DeviceTrustLevel,
            EncryptionActivationRequest, EnrollDeviceRequest, EntitlementCacheStatus,
            EntitlementEffectiveStatus, EntitlementLimits, EntitlementRelayPriority,
            EntitlementTier, FileOrganizationHints, ImportAssetRequest, ImportMode,
            ImportSourceKind, MediaKind, MetadataSource, MobilePairRequest,
            MobileReplicaChunkReport, MobileReplicaReportRequest,
            MobileStorageProfileUpdateRequest, MobileUploadRequest, MobileUploadStatus,
            ModelImportRequest, ModelInstallRequest, MoveFileEntryRequest, NetworkPolicy,
            PlatformReleaseEvidenceStatus, PlatformReleaseReadinessStatus, PlatformReleaseSurface,
            RebuildRequest, RenameAlbumRequest, RenameFileEntryRequest, ReplicaHealth,
            RevokeDeviceRequest, RunSyncRequest, ScanImportSourceRequest, SearchQuery,
            StoragePolicy, StoragePolicyMode, SupportBundleExportRequest, SyncTransfer,
            SyncTransferExecutionStatus, SyncTransferStatus, UpdateAlbumAssetsRequest,
            UpdateAssetFlagsRequest, UpdateAssetTagsRequest, UpdateAssetsFlagsRequest,
            UpdateEntitlementCacheRequest, UpdateLibrarySettingsRequest, UpdatePersonAssetsRequest,
            UpdateVaultStoragePolicyRequest, VaultFileKind,
        },
        imports,
    };

    use super::{
        ByteRangeRequest, GalleryService, effective_library_root, local_device_id,
        mobile_replica_chunk_proof_hex, mobile_upload_dir, sha256_hex_bytes,
    };

    fn temp_root(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "private-gallery-service-{name}-{}",
            Utc::now().timestamp_nanos_opt().unwrap_or_default()
        ));
        fs::create_dir_all(&root).expect("create temp root");
        root
    }

    async fn set_mobile_member_role(
        service: &GalleryService,
        device_id: uuid::Uuid,
        role: DeviceRole,
        accepts_storage: bool,
    ) {
        let mut state = service.state.write().await;
        let trust_level = if role == DeviceRole::StorageOnly {
            DeviceTrustLevel::StorageOnly
        } else {
            DeviceTrustLevel::Trusted
        };
        let device = state
            .devices
            .iter_mut()
            .find(|device| device.id == device_id)
            .expect("mobile device");
        device.trust_level = trust_level;
        device.storage_profile.accepts_storage = accepts_storage;
        device.storage_profile.device_id = Some(device_id);
        for member in state
            .vault_members
            .iter_mut()
            .filter(|member| member.device_id == device_id && member.revoked_at.is_none())
        {
            member.role = role.clone();
            member.trust_level = trust_level;
        }
        service.persist_locked_state(&state).expect("persist role");
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
                original_storage_policy: None,
            })
            .await
            .expect("settings should save");

        assert_eq!(settings.default_import_mode, ImportMode::Copy);
    }

    #[tokio::test]
    async fn entitlement_cache_preserves_core_access_and_offline_grace() {
        let runtime_root = temp_root("entitlements");
        let config = AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        };
        let service = GalleryService::new(config.clone()).expect("service");

        let default_status = service.entitlement_status().await;
        assert_eq!(default_status.tier, EntitlementTier::PersonalCore);
        assert_eq!(
            default_status.effective_status,
            EntitlementEffectiveStatus::Active
        );
        assert!(default_status.safe_local_access_allowed);
        assert!(default_status.content_exposure_prevented);
        assert!(default_status.cache.is_none());

        let now = Utc::now();
        let response = service
            .update_entitlement_cache(UpdateEntitlementCacheRequest {
                tier: EntitlementTier::FamilyRemote,
                status: EntitlementCacheStatus::PastDue,
                account_id_hash: Some(
                    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef".to_string(),
                ),
                plan_code: Some("family_remote.monthly".to_string()),
                limits: Some(EntitlementLimits {
                    device_limit: 8,
                    member_limit: 6,
                    workspace_limit: 2,
                    monthly_ocr_limit: 5_000,
                    relay_priority: EntitlementRelayPriority::Standard,
                    advanced_admin_controls: false,
                }),
                checked_at: Some(now - Duration::days(2)),
                expires_at: Some(now - Duration::days(1)),
                offline_grace_expires_at: Some(now + Duration::days(14)),
                source: Some("unit_test".to_string()),
            })
            .await
            .expect("entitlement cache update");

        assert_eq!(response.tier, EntitlementTier::FamilyRemote);
        assert_eq!(
            response.effective_status,
            EntitlementEffectiveStatus::OfflineGrace
        );
        assert!(response.offline_grace_active);
        assert!(response.paid_features_available);
        assert!(response.safe_local_access_allowed);
        assert_eq!(response.limits.device_limit, 8);

        let events = service.audit_events(Some(1)).await;
        assert_eq!(events[0].action, "entitlement.cache.update");
        assert!(!events[0].payload.to_string().contains("0123456789abcdef"));

        let restarted = GalleryService::new(config).expect("restarted service");
        let persisted = restarted.entitlement_status().await;
        assert_eq!(
            persisted.effective_status,
            EntitlementEffectiveStatus::OfflineGrace
        );
        assert!(persisted.cache.is_some());
    }

    #[tokio::test]
    async fn entitlement_cache_rejects_raw_account_identifiers() {
        let runtime_root = temp_root("entitlement-privacy");
        let service = GalleryService::new(AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        })
        .expect("service");

        let error = service
            .update_entitlement_cache(UpdateEntitlementCacheRequest {
                tier: EntitlementTier::PersonalCore,
                status: EntitlementCacheStatus::Active,
                account_id_hash: Some("alex@example.com".to_string()),
                plan_code: Some("personal_core.monthly".to_string()),
                limits: None,
                checked_at: None,
                expires_at: None,
                offline_grace_expires_at: None,
                source: Some("unit_test".to_string()),
            })
            .await
            .expect_err("raw account identifiers must be rejected");

        assert!(error.to_string().contains("account_id_hash"));
    }

    #[tokio::test]
    async fn platform_release_readiness_tracks_all_required_surfaces() {
        let runtime_root = temp_root("platform-release-readiness");
        let service = GalleryService::new(AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        })
        .expect("service");

        let readiness = service.platform_release_readiness().await;
        assert_eq!(readiness.required_surface_count, 8);
        assert_eq!(readiness.surfaces.len(), 8);
        assert_eq!(
            readiness.overall_status,
            PlatformReleaseReadinessStatus::InProgress
        );
        assert_eq!(readiness.ready_surface_count, 0);

        let surfaces = readiness
            .surfaces
            .iter()
            .map(|surface| surface.surface)
            .collect::<Vec<_>>();
        for required in [
            PlatformReleaseSurface::LinuxDesktop,
            PlatformReleaseSurface::WindowsDesktop,
            PlatformReleaseSurface::MacosDesktop,
            PlatformReleaseSurface::AndroidPlayStore,
            PlatformReleaseSurface::IosAppStore,
            PlatformReleaseSurface::WebBrowser,
            PlatformReleaseSurface::LocalWebUi,
            PlatformReleaseSurface::DirectDesktopDistribution,
        ] {
            assert!(surfaces.contains(&required), "missing {required:?}");
        }

        let ios = readiness
            .surfaces
            .iter()
            .find(|surface| surface.surface == PlatformReleaseSurface::IosAppStore)
            .expect("iOS surface");
        assert_eq!(ios.status, PlatformReleaseReadinessStatus::InProgress);
        assert!(
            ios.evidence.iter().any(|item| item.key == "ios_runner"
                && item.status == PlatformReleaseEvidenceStatus::Passed)
        );

        let web = readiness
            .surfaces
            .iter()
            .find(|surface| surface.surface == PlatformReleaseSurface::WebBrowser)
            .expect("web surface");
        assert_eq!(web.status, PlatformReleaseReadinessStatus::InProgress);
        assert!(
            web.evidence.iter().any(|item| item.key == "web_runner"
                && item.status == PlatformReleaseEvidenceStatus::Passed)
        );
        assert!(web.next_step.contains("browser upload/download"));

        let local_web = readiness
            .surfaces
            .iter()
            .find(|surface| surface.surface == PlatformReleaseSurface::LocalWebUi)
            .expect("local web surface");
        assert_eq!(local_web.status, PlatformReleaseReadinessStatus::InProgress);
        assert!(
            local_web
                .evidence
                .iter()
                .any(|item| item.key == "desktop_route_boundary"
                    && item.status == PlatformReleaseEvidenceStatus::Passed)
        );
    }

    #[tokio::test]
    async fn support_bundle_exports_redacted_local_diagnostics() {
        let runtime_root = temp_root("support-bundle");
        let sensitive_library_root = runtime_root.join("library-alex-private-tax-photos");
        let support_root = runtime_root.join("support-export");
        let account_hash =
            "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789".to_string();
        let service = GalleryService::new(AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        })
        .expect("service");
        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: sensitive_library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Copy,
                original_storage_policy: None,
            })
            .await
            .expect("settings");
        service
            .update_entitlement_cache(UpdateEntitlementCacheRequest {
                tier: EntitlementTier::FamilyRemote,
                status: EntitlementCacheStatus::Active,
                account_id_hash: Some(account_hash.clone()),
                plan_code: Some("family_remote.monthly".to_string()),
                limits: None,
                checked_at: None,
                expires_at: None,
                offline_grace_expires_at: None,
                source: Some("unit_test".to_string()),
            })
            .await
            .expect("entitlement");

        let result = service
            .export_support_bundle(SupportBundleExportRequest {
                export_root: support_root.to_string_lossy().to_string(),
                include_release_readiness: true,
            })
            .await
            .expect("support bundle");

        assert!(result.private_data_excluded);
        assert!(
            result
                .redacted_fields
                .iter()
                .any(|field| field == "account_id_hash")
        );
        assert!(result.sections.iter().any(|section| section == "redaction"));

        let bundle_text = fs::read_to_string(&result.bundle_path).expect("bundle text");
        assert!(!bundle_text.contains(&account_hash));
        assert!(!bundle_text.contains(sensitive_library_root.to_string_lossy().as_ref()));
        assert!(!bundle_text.contains("library-alex-private-tax-photos"));
        assert!(!bundle_text.contains("\"database_path\":"));
        assert!(bundle_text.contains("private_data_excluded"));
        assert!(bundle_text.contains("account_identifier_redacted"));
        assert!(bundle_text.contains("release_readiness"));

        let bundle: serde_json::Value = serde_json::from_str(&bundle_text).expect("bundle json");
        assert_eq!(bundle["private_data_excluded"], true);
        assert_eq!(bundle["entitlements"]["account_identifier_redacted"], true);
        assert!(bundle["backup_health"]["missing_asset_count"].is_number());
    }

    #[tokio::test]
    async fn mobile_pair_upload_download_round_trip_persists() {
        let runtime_root = temp_root("mobile-sync");
        let library_root = runtime_root.join("library");
        let config = AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        };
        let service = GalleryService::new(config.clone()).expect("service");
        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Copy,
                original_storage_policy: None,
            })
            .await
            .expect("settings");

        let pairing = service
            .create_pairing_session(CreatePairingSessionRequest {
                device_name: "Moto G".to_string(),
                platform: "android".to_string(),
                vault_id: None,
            })
            .await
            .expect("pairing session");
        let paired = service
            .pair_mobile_device(MobilePairRequest {
                pairing_token: pairing.pairing_token.clone(),
                device_name: "Moto G".to_string(),
                platform: "android".to_string(),
                vault_id: None,
                storage_profile: None,
            })
            .await
            .expect("pair mobile");
        assert!(paired.bearer_token.starts_with("pgm_"));
        assert!(paired.session.expires_at <= Utc::now() + chrono::Duration::days(31));
        assert!(
            !paired.device.storage_profile.accepts_storage,
            "paired Android clients must not be sync storage targets until native chunk storage exists"
        );
        assert!(service.mobile_session_status("wrong-token").await.is_err());

        let bytes = b"mobile original bytes".to_vec();
        let reserved = service
            .reserve_mobile_upload(
                &paired.bearer_token,
                MobileUploadRequest {
                    original_filename: "../camera/photo.jpg".to_string(),
                    media_kind: MediaKind::Photo,
                    mime_type: "image/jpeg".to_string(),
                    bytes: bytes.len() as u64,
                    content_hash: None,
                    captured_at: Some(Utc::now()),
                    place_hint: Some("Home".to_string()),
                },
            )
            .await
            .expect("reserve upload");
        assert_eq!(reserved.original_filename, "photo.jpg");

        let completed = service
            .receive_mobile_upload(&paired.bearer_token, reserved.id, bytes.clone())
            .await
            .expect("receive upload");
        assert_eq!(completed.status, MobileUploadStatus::Completed);
        let asset_id = completed.asset_id.expect("asset id");

        let duplicate_reserved = service
            .reserve_mobile_upload(
                &paired.bearer_token,
                MobileUploadRequest {
                    original_filename: "duplicate.jpg".to_string(),
                    media_kind: MediaKind::Photo,
                    mime_type: "image/jpeg".to_string(),
                    bytes: bytes.len() as u64,
                    content_hash: None,
                    captured_at: None,
                    place_hint: None,
                },
            )
            .await
            .expect("reserve duplicate");
        let duplicate = service
            .receive_mobile_upload(&paired.bearer_token, duplicate_reserved.id, bytes.clone())
            .await
            .expect("receive duplicate");
        assert_eq!(duplicate.asset_id, Some(asset_id));

        let mobile_tree = service
            .mobile_file_tree(&paired.bearer_token, false)
            .await
            .expect("mobile file tree");
        let uploaded_file = mobile_tree
            .entries
            .iter()
            .find(|entry| entry.asset_id == Some(asset_id))
            .expect("uploaded file entry");
        assert_eq!(uploaded_file.origin_device_id, Some(paired.device.id));
        assert!(
            mobile_tree
                .devices
                .iter()
                .any(|device| { device.id == paired.device.id && device.display_name == "Moto G" })
        );

        let assets = service
            .mobile_assets(&paired.bearer_token)
            .await
            .expect("mobile assets");
        assert_eq!(assets.len(), 1);
        assert_eq!(assets[0].asset_id, asset_id);

        let workspace = service
            .mobile_workspace(&paired.bearer_token)
            .await
            .expect("mobile workspace");
        assert_eq!(workspace.timeline.total_assets, 1);
        assert_eq!(workspace.timeline.returned_assets, 1);
        assert_eq!(workspace.timeline.buckets[0].asset_ids, vec![asset_id]);
        assert_eq!(workspace.vault_status.assets_total, 1);
        assert!(!workspace.devices.is_empty());
        assert!(workspace.capabilities.can_browse_library);
        assert!(workspace.capabilities.can_search);
        assert!(workspace.capabilities.can_upload_camera_roll);
        assert!(workspace.capabilities.can_download_originals);
        assert!(!workspace.capabilities.can_manage_storage);

        let search = service
            .mobile_search(
                &paired.bearer_token,
                SearchQuery {
                    text: Some("photo".to_string()),
                    people: None,
                    places: None,
                    events: None,
                    workspace: None,
                    client: None,
                    project: None,
                    topic: None,
                    source_folder: None,
                    device: None,
                    media_kind: None,
                    tags: None,
                    favorite: None,
                    from_date: None,
                    to_date: None,
                    include_archived: false,
                    limit: Some(10),
                },
            )
            .await
            .expect("mobile search");
        assert_eq!(search.assets.len(), 1);
        assert_eq!(search.assets[0].id, asset_id);

        let device_search = service
            .mobile_search(
                &paired.bearer_token,
                SearchQuery {
                    text: None,
                    people: None,
                    places: None,
                    events: None,
                    workspace: None,
                    client: None,
                    project: None,
                    topic: None,
                    source_folder: None,
                    device: Some("Moto".to_string()),
                    media_kind: None,
                    tags: None,
                    favorite: None,
                    from_date: None,
                    to_date: None,
                    include_archived: false,
                    limit: Some(10),
                },
            )
            .await
            .expect("mobile device search");
        assert_eq!(device_search.assets.len(), 1);
        assert_eq!(device_search.assets[0].id, asset_id);

        let availability = service
            .mobile_asset_availability(&paired.bearer_token, asset_id)
            .await
            .expect("mobile asset availability");
        assert_eq!(availability.asset_id, asset_id);

        let flagged = service
            .update_mobile_asset_flags(
                &paired.bearer_token,
                asset_id,
                UpdateAssetFlagsRequest {
                    favorite: Some(true),
                    archived: None,
                },
            )
            .await
            .expect("update mobile asset flags");
        assert!(flagged.favorite);

        let (mime_type, downloaded) = service
            .mobile_original_bytes(&paired.bearer_token, asset_id)
            .await
            .expect("download original");
        assert_eq!(mime_type, "image/jpeg");
        assert_eq!(downloaded, bytes);

        let (preview_mime_type, preview) = service
            .mobile_preview_bytes(&paired.bearer_token, asset_id)
            .await
            .expect("download preview");
        assert_eq!(preview_mime_type, "image/jpeg");
        assert_eq!(preview, bytes);

        let reopened = GalleryService::new(config).expect("reopen service");
        let active_sessions = reopened
            .mobile_sessions(&paired.bearer_token)
            .await
            .expect("list mobile sessions");
        assert_eq!(active_sessions.len(), 1);
        let refreshed = reopened
            .refresh_mobile_session(&paired.bearer_token)
            .await
            .expect("refresh mobile session");
        assert_ne!(refreshed.bearer_token, paired.bearer_token);
        assert_eq!(refreshed.previous_session_id, paired.session.id);
        assert!(refreshed.session.expires_at <= Utc::now() + chrono::Duration::days(31));
        assert!(
            reopened
                .mobile_session_status(&paired.bearer_token)
                .await
                .is_err(),
            "refresh must revoke the previous bearer token"
        );
        let refreshed_status = reopened
            .mobile_session_status(&refreshed.bearer_token)
            .await
            .expect("refreshed token works");
        assert_eq!(refreshed_status.id, refreshed.session.id);
        let refreshed_device = reopened
            .devices()
            .await
            .into_iter()
            .find(|device| device.id == refreshed.session.device_id)
            .expect("refreshed mobile device");
        assert!(refreshed_device.last_seen_at.is_some());
        let (reopened_mime_type, reopened_downloaded) = reopened
            .mobile_original_bytes(&refreshed.bearer_token, asset_id)
            .await
            .expect("download after reopen");
        assert_eq!(reopened_mime_type, "image/jpeg");
        assert_eq!(reopened_downloaded, bytes);
        let revoked = reopened
            .revoke_current_mobile_session(&refreshed.bearer_token)
            .await
            .expect("revoke current mobile session");
        assert!(revoked.revoked_at.is_some());
        assert!(
            reopened
                .mobile_session_status(&refreshed.bearer_token)
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn mobile_document_upload_is_vault_asset_and_searchable() {
        let runtime_root = temp_root("mobile-document");
        let library_root = runtime_root.join("library");
        let service = GalleryService::new(AppConfig {
            runtime_root,
            ..AppConfig::default()
        })
        .expect("service");
        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Copy,
                original_storage_policy: None,
            })
            .await
            .expect("settings");

        let pairing = service
            .create_pairing_session(CreatePairingSessionRequest {
                device_name: "Moto G".to_string(),
                platform: "android".to_string(),
                vault_id: None,
            })
            .await
            .expect("pairing session");
        let paired = service
            .pair_mobile_device(MobilePairRequest {
                pairing_token: pairing.pairing_token,
                device_name: "Moto G".to_string(),
                platform: "android".to_string(),
                vault_id: None,
                storage_profile: None,
            })
            .await
            .expect("pair mobile");

        let bytes = b"%PDF-1.7 private gallery test document".to_vec();
        let reserved = service
            .reserve_mobile_upload(
                &paired.bearer_token,
                MobileUploadRequest {
                    original_filename: "medical-report.pdf".to_string(),
                    media_kind: MediaKind::Document,
                    mime_type: "application/pdf".to_string(),
                    bytes: bytes.len() as u64,
                    content_hash: Some(sha256_hex_bytes(&bytes)),
                    captured_at: Some(Utc::now()),
                    place_hint: None,
                },
            )
            .await
            .expect("reserve document upload");
        let completed = service
            .receive_mobile_upload(&paired.bearer_token, reserved.id, bytes.clone())
            .await
            .expect("receive document upload");
        assert_eq!(completed.status, MobileUploadStatus::Completed);
        let asset_id = completed.asset_id.expect("asset id");

        let assets = service
            .mobile_assets(&paired.bearer_token)
            .await
            .expect("mobile assets");
        assert_eq!(assets.len(), 1);
        assert_eq!(assets[0].media_kind, MediaKind::Document);
        assert_eq!(assets[0].mime_type, "application/pdf");

        let search = service
            .mobile_search(
                &paired.bearer_token,
                SearchQuery {
                    text: Some("medical".to_string()),
                    people: None,
                    places: None,
                    events: None,
                    workspace: None,
                    client: None,
                    project: None,
                    topic: None,
                    source_folder: None,
                    device: None,
                    media_kind: Some("documents".to_string()),
                    tags: None,
                    favorite: None,
                    from_date: None,
                    to_date: None,
                    include_archived: false,
                    limit: Some(10),
                },
            )
            .await
            .expect("mobile document search");
        assert_eq!(search.assets.len(), 1);
        assert_eq!(search.assets[0].id, asset_id);
        assert_eq!(search.assets[0].media_kind, MediaKind::Document);

        let range = service
            .mobile_original_range_bytes(
                &paired.bearer_token,
                asset_id,
                ByteRangeRequest::Start {
                    start: 0,
                    end: Some(7),
                },
            )
            .await
            .expect("range download");
        assert_eq!(range.mime_type, "application/pdf");
        assert_eq!(range.bytes, b"%PDF-1.7");
    }

    #[tokio::test]
    async fn mobile_roles_enforce_viewer_contributor_and_storage_only_boundaries() {
        let runtime_root = temp_root("mobile-role-boundaries");
        let library_root = runtime_root.join("library");
        let source = runtime_root.join("desktop-photo.jpg");
        let original_bytes = b"desktop imported family photo".to_vec();
        fs::write(&source, &original_bytes).expect("write source");
        let service = GalleryService::new(AppConfig {
            runtime_root,
            ..AppConfig::default()
        })
        .expect("service");
        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Copy,
                original_storage_policy: None,
            })
            .await
            .expect("settings");
        let imported = service
            .import_asset(ImportAssetRequest {
                source_path: source.to_string_lossy().to_string(),
                original_filename: "desktop-photo.jpg".to_string(),
                media_kind: MediaKind::Photo,
                mime_type: "image/jpeg".to_string(),
                bytes: original_bytes.len() as u64,
                content_hash: Some(sha256_hex_bytes(&original_bytes)),
                captured_at: Some(Utc::now()),
                place_hint: None,
                import_mode: Some(ImportMode::Copy),
            })
            .await
            .expect("desktop import");
        let pairing = service
            .create_pairing_session(CreatePairingSessionRequest {
                device_name: "Role phone".to_string(),
                platform: "android".to_string(),
                vault_id: None,
            })
            .await
            .expect("pairing");
        let paired = service
            .pair_mobile_device(MobilePairRequest {
                pairing_token: pairing.pairing_token,
                device_name: "Role phone".to_string(),
                platform: "android".to_string(),
                vault_id: None,
                storage_profile: Some(DeviceStorageProfile {
                    device_id: None,
                    total_bytes: Some(64 * 1024 * 1024 * 1024),
                    available_bytes: Some(32 * 1024 * 1024 * 1024),
                    reserved_bytes: 1024 * 1024,
                    accepts_storage: true,
                    battery_powered: true,
                    metered_network: false,
                    low_battery: false,
                }),
            })
            .await
            .expect("pair phone");

        set_mobile_member_role(&service, paired.device.id, DeviceRole::Viewer, true).await;
        let viewer_workspace = service
            .mobile_workspace(&paired.bearer_token)
            .await
            .expect("viewer workspace");
        assert!(viewer_workspace.capabilities.can_browse_library);
        assert!(viewer_workspace.capabilities.can_search);
        assert!(viewer_workspace.capabilities.can_download_originals);
        assert!(!viewer_workspace.capabilities.can_upload_camera_roll);
        assert!(!viewer_workspace.capabilities.can_manage_storage);
        assert!(
            viewer_workspace
                .capabilities
                .role_detail
                .contains("read-only")
        );
        assert_eq!(viewer_workspace.timeline.total_assets, 1);
        service
            .mobile_original_bytes(&paired.bearer_token, imported.asset.id)
            .await
            .expect("viewer download");
        assert!(
            service
                .reserve_mobile_upload(
                    &paired.bearer_token,
                    MobileUploadRequest {
                        original_filename: "viewer-upload.jpg".to_string(),
                        media_kind: MediaKind::Photo,
                        mime_type: "image/jpeg".to_string(),
                        bytes: 1,
                        content_hash: None,
                        captured_at: None,
                        place_hint: None,
                    },
                )
                .await
                .is_err(),
            "viewer role must not upload originals"
        );
        assert!(
            service
                .update_mobile_asset_tags(
                    &paired.bearer_token,
                    imported.asset.id,
                    UpdateAssetTagsRequest {
                        tags: vec!["viewer".to_string()],
                    },
                )
                .await
                .is_err(),
            "viewer role must not curate tags"
        );
        assert!(
            service
                .update_mobile_storage_profile(
                    &paired.bearer_token,
                    MobileStorageProfileUpdateRequest {
                        storage_profile: DeviceStorageProfile {
                            device_id: None,
                            total_bytes: None,
                            available_bytes: None,
                            reserved_bytes: 0,
                            accepts_storage: true,
                            battery_powered: true,
                            metered_network: false,
                            low_battery: false,
                        },
                    },
                )
                .await
                .is_err(),
            "viewer role must not become a storage node without an admin role change"
        );
        let viewer_storage_plan = service
            .mobile_storage_plan(&paired.bearer_token)
            .await
            .expect("viewer storage plan");
        assert!(viewer_storage_plan.assignments.is_empty());
        assert!(viewer_storage_plan.detail.contains("viewer role"));

        set_mobile_member_role(&service, paired.device.id, DeviceRole::StorageOnly, true).await;
        let storage_workspace = service
            .mobile_workspace(&paired.bearer_token)
            .await
            .expect("storage-only workspace");
        assert!(!storage_workspace.capabilities.can_browse_library);
        assert!(!storage_workspace.capabilities.can_search);
        assert!(!storage_workspace.capabilities.can_upload_camera_roll);
        assert!(!storage_workspace.capabilities.can_download_originals);
        assert!(storage_workspace.capabilities.can_manage_storage);
        assert_eq!(storage_workspace.timeline.total_assets, 0);
        assert!(
            service.mobile_assets(&paired.bearer_token).await.is_err(),
            "storage-only role must not list content"
        );
        assert!(
            service
                .mobile_original_bytes(&paired.bearer_token, imported.asset.id)
                .await
                .is_err(),
            "storage-only role must not download originals"
        );
        let storage_plan = service
            .mobile_storage_plan(&paired.bearer_token)
            .await
            .expect("storage-only plan");
        assert_eq!(storage_plan.assignments.len(), 1);
        let assignment = storage_plan.assignments[0].clone();
        let chunk = assignment.chunks[0].clone();
        let encrypted_chunk = service
            .mobile_replica_chunk_bytes(&paired.bearer_token, assignment.blob_id, chunk.chunk_index)
            .await
            .expect("storage-only encrypted chunk");
        assert_eq!(sha256_hex_bytes(&encrypted_chunk), chunk.encrypted_hash);

        set_mobile_member_role(&service, paired.device.id, DeviceRole::Contributor, false).await;
        let contributor_workspace = service
            .mobile_workspace(&paired.bearer_token)
            .await
            .expect("contributor workspace");
        assert!(contributor_workspace.capabilities.can_upload_camera_roll);
        assert!(!contributor_workspace.capabilities.can_manage_storage);
    }

    #[tokio::test]
    async fn mobile_storage_node_receives_reports_and_restores_encrypted_chunks() {
        let runtime_root = temp_root("mobile-storage-node");
        let library_root = runtime_root.join("library");
        let service = GalleryService::new(AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        })
        .expect("service");
        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Copy,
                original_storage_policy: None,
            })
            .await
            .expect("settings");

        let pairing = service
            .create_pairing_session(CreatePairingSessionRequest {
                device_name: "Android storage phone".to_string(),
                platform: "android".to_string(),
                vault_id: None,
            })
            .await
            .expect("pairing session");
        let paired = service
            .pair_mobile_device(MobilePairRequest {
                pairing_token: pairing.pairing_token,
                device_name: "Android storage phone".to_string(),
                platform: "android".to_string(),
                vault_id: None,
                storage_profile: Some(DeviceStorageProfile {
                    device_id: None,
                    total_bytes: Some(128 * 1024 * 1024 * 1024),
                    available_bytes: Some(64 * 1024 * 1024 * 1024),
                    reserved_bytes: 1024 * 1024 * 1024,
                    accepts_storage: true,
                    battery_powered: true,
                    metered_network: false,
                    low_battery: false,
                }),
            })
            .await
            .expect("pair storage mobile");
        assert!(paired.device.storage_profile.accepts_storage);

        let workspace = service
            .mobile_workspace(&paired.bearer_token)
            .await
            .expect("workspace");
        assert!(workspace.capabilities.can_manage_storage);

        let bytes = b"encrypted chunks should be restorable from a phone".to_vec();
        let reserved = service
            .reserve_mobile_upload(
                &paired.bearer_token,
                MobileUploadRequest {
                    original_filename: "phone-storage.jpg".to_string(),
                    media_kind: MediaKind::Photo,
                    mime_type: "image/jpeg".to_string(),
                    bytes: bytes.len() as u64,
                    content_hash: Some(sha256_hex_bytes(&bytes)),
                    captured_at: Some(Utc::now()),
                    place_hint: Some("Home".to_string()),
                },
            )
            .await
            .expect("reserve upload");
        let completed = service
            .receive_mobile_upload(&paired.bearer_token, reserved.id, bytes)
            .await
            .expect("complete upload");
        assert_eq!(completed.status, MobileUploadStatus::Completed);

        let plan = service
            .mobile_storage_plan(&paired.bearer_token)
            .await
            .expect("storage plan");
        assert_eq!(plan.assignments.len(), 1);
        let assignment = plan.assignments[0].clone();
        let first_chunk = assignment.chunks[0].clone();
        let encrypted_chunk = service
            .mobile_replica_chunk_bytes(
                &paired.bearer_token,
                assignment.blob_id,
                first_chunk.chunk_index,
            )
            .await
            .expect("download encrypted chunk");
        assert_eq!(
            sha256_hex_bytes(&encrypted_chunk),
            first_chunk.encrypted_hash
        );

        let metadata_only_report = service
            .report_mobile_replica(
                &paired.bearer_token,
                assignment.blob_id,
                MobileReplicaReportRequest {
                    transfer_id: assignment.transfer_id,
                    chunks: assignment
                        .chunks
                        .iter()
                        .map(|chunk| MobileReplicaChunkReport {
                            chunk_index: chunk.chunk_index,
                            encrypted_hash: chunk.encrypted_hash.clone(),
                            encrypted_bytes: chunk.encrypted_bytes,
                            proof: sha256_hex_bytes(chunk.encrypted_hash.as_bytes()),
                        })
                        .collect(),
                },
            )
            .await;
        assert!(
            metadata_only_report.is_err(),
            "storage reports must prove possession of encrypted bytes, not just echo assignment metadata"
        );

        let report = service
            .report_mobile_replica(
                &paired.bearer_token,
                assignment.blob_id,
                MobileReplicaReportRequest {
                    transfer_id: assignment.transfer_id,
                    chunks: assignment
                        .chunks
                        .iter()
                        .map(|chunk| MobileReplicaChunkReport {
                            chunk_index: chunk.chunk_index,
                            encrypted_hash: chunk.encrypted_hash.clone(),
                            encrypted_bytes: chunk.encrypted_bytes,
                            proof: mobile_replica_chunk_proof_hex(
                                &chunk.proof_challenge,
                                &encrypted_chunk,
                            ),
                        })
                        .collect(),
                },
            )
            .await
            .expect("report replica");
        assert_eq!(report.health, ReplicaHealth::Healthy);
        assert_eq!(report.device_id, paired.device.id);

        let second_pairing = service
            .create_pairing_session(CreatePairingSessionRequest {
                device_name: "Second storage phone".to_string(),
                platform: "android".to_string(),
                vault_id: None,
            })
            .await
            .expect("second pairing session");
        let second_paired = service
            .pair_mobile_device(MobilePairRequest {
                pairing_token: second_pairing.pairing_token,
                device_name: "Second storage phone".to_string(),
                platform: "android".to_string(),
                vault_id: None,
                storage_profile: Some(DeviceStorageProfile {
                    device_id: None,
                    total_bytes: Some(128 * 1024 * 1024 * 1024),
                    available_bytes: Some(64 * 1024 * 1024 * 1024),
                    reserved_bytes: 1024 * 1024 * 1024,
                    accepts_storage: true,
                    battery_powered: true,
                    metered_network: false,
                    low_battery: false,
                }),
            })
            .await
            .expect("pair second storage mobile");
        service
            .update_vault_storage_policy(
                paired.session.vault_id,
                UpdateVaultStoragePolicyRequest {
                    policy: StoragePolicy {
                        mode: StoragePolicyMode::Custom,
                        min_replicas: 3,
                        preferred_device_ids: Vec::new(),
                        excluded_device_ids: vec![second_paired.device.id],
                        min_free_space_bytes: 0,
                        allow_metered_network: true,
                        pause_on_low_battery: false,
                    },
                },
            )
            .await
            .expect("exclude second phone from storage policy");
        let second_plan = service
            .mobile_storage_plan(&second_paired.bearer_token)
            .await
            .expect("second storage plan");
        assert!(
            second_plan.assignments.is_empty(),
            "vault storage policy exclusions must block mobile storage assignments"
        );
        assert!(
            service
                .mobile_replica_chunk_bytes(
                    &second_paired.bearer_token,
                    assignment.blob_id,
                    first_chunk.chunk_index,
                )
                .await
                .is_err(),
            "storage phones must not fetch encrypted chunks without a matching transfer assignment"
        );

        let local_chunk_path = {
            let state = service.state.read().await;
            let local_path = state
                .blob_chunks
                .iter()
                .find(|chunk| {
                    chunk.blob_id == assignment.blob_id
                        && chunk.chunk_index == first_chunk.chunk_index
                })
                .and_then(|chunk| chunk.local_path.clone())
                .expect("local chunk path");
            PathBuf::from(effective_library_root(&state, &service.config)).join(local_path)
        };
        fs::remove_file(&local_chunk_path).expect("remove local encrypted chunk");
        assert!(!local_chunk_path.exists());

        let restored = service
            .restore_mobile_replica_chunk(
                &paired.bearer_token,
                assignment.blob_id,
                first_chunk.chunk_index,
                encrypted_chunk,
            )
            .await
            .expect("restore encrypted chunk");
        assert!(restored.restored_local_chunk);
        assert!(local_chunk_path.exists());

        let disabled = service
            .update_mobile_storage_profile(
                &paired.bearer_token,
                MobileStorageProfileUpdateRequest {
                    storage_profile: DeviceStorageProfile {
                        device_id: None,
                        total_bytes: None,
                        available_bytes: None,
                        reserved_bytes: 0,
                        accepts_storage: false,
                        battery_powered: true,
                        metered_network: false,
                        low_battery: false,
                    },
                },
            )
            .await
            .expect("disable storage");
        assert!(!disabled.storage_profile.accepts_storage);
        assert!(
            service
                .mobile_replica_chunk_bytes(
                    &paired.bearer_token,
                    assignment.blob_id,
                    first_chunk.chunk_index,
                )
                .await
                .is_err(),
            "phones that opt out of storage must not receive encrypted chunk assignments"
        );
    }

    #[tokio::test]
    async fn vault_file_namespace_manages_folders_trash_and_mobile_listing() {
        let runtime_root = temp_root("vault-file-namespace");
        let library_root = runtime_root.join("library");
        let source_dir = runtime_root.join("project-renewal");
        fs::create_dir_all(&source_dir).expect("source dir");
        let document_path = source_dir.join("report.pdf");
        let bytes = b"%PDF-1.7 private gallery file namespace".to_vec();
        fs::write(&document_path, &bytes).expect("write document");

        let config = AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        };
        let service = GalleryService::new(config.clone()).expect("service");
        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Copy,
                original_storage_policy: None,
            })
            .await
            .expect("settings");

        let imported = service
            .import_asset(ImportAssetRequest {
                source_path: document_path.to_string_lossy().to_string(),
                original_filename: "report.pdf".to_string(),
                media_kind: MediaKind::Document,
                mime_type: "application/pdf".to_string(),
                bytes: bytes.len() as u64,
                content_hash: Some(sha256_hex_bytes(&bytes)),
                captured_at: Some(Utc::now()),
                place_hint: None,
                import_mode: Some(ImportMode::Copy),
            })
            .await
            .expect("import document");
        let asset_id = imported.asset.id;

        let tree = service.file_tree(None, false).await.expect("file tree");
        let root = tree
            .entries
            .iter()
            .find(|entry| entry.parent_id.is_none())
            .expect("root")
            .clone();
        assert_eq!(root.kind, VaultFileKind::Folder);
        let file = tree
            .entries
            .iter()
            .find(|entry| entry.asset_id == Some(asset_id))
            .expect("asset file")
            .clone();
        assert_eq!(file.parent_id, Some(root.id));
        assert_eq!(file.media_kind, Some(MediaKind::Document));
        assert_eq!(
            file.content_hash.as_deref(),
            Some(imported.asset.content_hash.as_str())
        );
        assert_eq!(file.organization.project.as_deref(), Some("renewal"));
        let file_origin_device_id = file.origin_device_id.expect("file origin device");
        let origin_device = tree
            .devices
            .iter()
            .find(|device| device.id == file_origin_device_id)
            .expect("file tree origin device summary");
        assert!(!origin_device.display_name.trim().is_empty());
        assert!(!origin_device.platform.trim().is_empty());

        let folder = service
            .create_file_folder(CreateFileFolderRequest {
                vault_id: Some(root.vault_id),
                parent_id: None,
                name: "Documents".to_string(),
            })
            .await
            .expect("create folder");
        assert_eq!(folder.parent_id, Some(root.id));
        assert!(
            service
                .create_file_folder(CreateFileFolderRequest {
                    vault_id: Some(root.vault_id),
                    parent_id: None,
                    name: "documents".to_string(),
                })
                .await
                .is_err(),
            "active sibling names are case-insensitive"
        );

        let moved = service
            .move_file_entry(
                file.id,
                MoveFileEntryRequest {
                    parent_id: Some(folder.id),
                },
            )
            .await
            .expect("move file");
        assert_eq!(moved.parent_id, Some(folder.id));
        let renamed = service
            .rename_file_entry(
                file.id,
                RenameFileEntryRequest {
                    name: "renamed-report.pdf".to_string(),
                },
            )
            .await
            .expect("rename file");
        assert_eq!(renamed.name, "renamed-report.pdf");

        let range = service
            .file_original_range_bytes(
                renamed.id,
                ByteRangeRequest::Start {
                    start: 0,
                    end: Some(7),
                },
            )
            .await
            .expect("file range");
        assert_eq!(range.bytes, b"%PDF-1.7");

        let trashed = service
            .trash_file_entry(folder.id)
            .await
            .expect("trash folder");
        assert!(trashed.trashed_at.is_some());
        let active_tree = service
            .file_tree(Some(root.vault_id), false)
            .await
            .expect("active tree");
        assert!(
            active_tree
                .entries
                .iter()
                .all(|entry| entry.id != folder.id && entry.id != renamed.id)
        );
        let trash_tree = service
            .file_tree(Some(root.vault_id), true)
            .await
            .expect("trash tree");
        assert!(
            trash_tree
                .entries
                .iter()
                .any(|entry| entry.id == renamed.id && entry.trashed_at.is_some())
        );

        let restored = service
            .restore_file_entry(folder.id)
            .await
            .expect("restore folder");
        assert!(restored.trashed_at.is_none());

        let pairing = service
            .create_pairing_session(CreatePairingSessionRequest {
                device_name: "Pixel".to_string(),
                platform: "android".to_string(),
                vault_id: Some(root.vault_id),
            })
            .await
            .expect("pairing");
        let paired = service
            .pair_mobile_device(MobilePairRequest {
                pairing_token: pairing.pairing_token,
                device_name: "Pixel".to_string(),
                platform: "android".to_string(),
                vault_id: None,
                storage_profile: None,
            })
            .await
            .expect("paired");
        let mobile_tree = service
            .mobile_file_tree(&paired.bearer_token, false)
            .await
            .expect("mobile tree");
        assert_eq!(mobile_tree.vault_id, Some(root.vault_id));
        assert!(
            mobile_tree
                .entries
                .iter()
                .any(|entry| entry.id == renamed.id && entry.name == "renamed-report.pdf")
        );
        let (mobile_mime, mobile_bytes) = service
            .mobile_file_original_bytes(&paired.bearer_token, renamed.id)
            .await
            .expect("mobile file download");
        assert_eq!(mobile_mime, "application/pdf");
        assert_eq!(mobile_bytes, bytes);

        let reopened = GalleryService::new(config).expect("reopen");
        let reopened_tree = reopened
            .file_tree(Some(root.vault_id), false)
            .await
            .expect("reopened tree");
        assert_eq!(
            reopened_tree
                .entries
                .iter()
                .filter(|entry| entry.asset_id == Some(asset_id))
                .count(),
            1,
            "startup backfill must not duplicate asset file entries"
        );
        let reopened_file = reopened_tree
            .entries
            .iter()
            .find(|entry| entry.asset_id == Some(asset_id))
            .expect("reopened asset file");
        assert_eq!(
            reopened_file.organization.project.as_deref(),
            Some("renewal")
        );
    }

    #[tokio::test]
    async fn mobile_chunk_upload_resumes_and_verifies_hash() {
        let runtime_root = temp_root("mobile-chunk-upload");
        let library_root = runtime_root.join("library");
        let service = GalleryService::new(AppConfig {
            runtime_root,
            ..AppConfig::default()
        })
        .expect("service");
        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Copy,
                original_storage_policy: None,
            })
            .await
            .expect("settings");

        let pairing = service
            .create_pairing_session(CreatePairingSessionRequest {
                device_name: "Pixel".to_string(),
                platform: "android".to_string(),
                vault_id: None,
            })
            .await
            .expect("pairing session");
        let paired = service
            .pair_mobile_device(MobilePairRequest {
                pairing_token: pairing.pairing_token,
                device_name: "Pixel".to_string(),
                platform: "android".to_string(),
                vault_id: None,
                storage_profile: None,
            })
            .await
            .expect("pair mobile");

        let bytes = b"chunked mobile original bytes".to_vec();
        let reserved = service
            .reserve_mobile_upload(
                &paired.bearer_token,
                MobileUploadRequest {
                    original_filename: "chunked.jpg".to_string(),
                    media_kind: MediaKind::Photo,
                    mime_type: "image/jpeg".to_string(),
                    bytes: bytes.len() as u64,
                    content_hash: Some(sha256_hex_bytes(&bytes)),
                    captured_at: Some(Utc::now()),
                    place_hint: None,
                },
            )
            .await
            .expect("reserve upload");
        assert!(
            service
                .complete_mobile_upload(&paired.bearer_token, reserved.id)
                .await
                .is_err(),
            "incomplete uploads must not be finalized"
        );

        let first = service
            .receive_mobile_upload_chunk(&paired.bearer_token, reserved.id, 0, bytes[..8].to_vec())
            .await
            .expect("first chunk");
        assert_eq!(first.status, MobileUploadStatus::Running);
        assert_eq!(first.bytes_received, 8);
        let retry = service
            .receive_mobile_upload_chunk(&paired.bearer_token, reserved.id, 0, bytes[..8].to_vec())
            .await
            .expect("retry first chunk");
        assert_eq!(retry.bytes_received, 8);
        assert!(
            service
                .receive_mobile_upload_chunk(&paired.bearer_token, reserved.id, 3, b"bad".to_vec())
                .await
                .is_err(),
            "overlapping chunks must be rejected without corrupting the upload"
        );
        service
            .receive_mobile_upload_chunk(&paired.bearer_token, reserved.id, 8, bytes[8..].to_vec())
            .await
            .expect("remaining chunk");
        let completed = service
            .complete_mobile_upload(&paired.bearer_token, reserved.id)
            .await
            .expect("complete upload");
        assert_eq!(completed.status, MobileUploadStatus::Completed);
        let asset_id = completed.asset_id.expect("asset id");
        let (_, downloaded) = service
            .mobile_original_bytes(&paired.bearer_token, asset_id)
            .await
            .expect("download chunked original");
        assert_eq!(downloaded, bytes);
        let ranged = service
            .mobile_original_range_bytes(
                &paired.bearer_token,
                asset_id,
                ByteRangeRequest::Start {
                    start: 8,
                    end: Some(13),
                },
            )
            .await
            .expect("download chunked original range");
        assert_eq!(ranged.total_bytes, bytes.len() as u64);
        assert_eq!(ranged.start, 8);
        assert_eq!(ranged.end, 13);
        assert_eq!(ranged.bytes, bytes[8..=13]);

        let bad_bytes = b"wrong hash body".to_vec();
        let bad_reserved = service
            .reserve_mobile_upload(
                &paired.bearer_token,
                MobileUploadRequest {
                    original_filename: "bad-hash.jpg".to_string(),
                    media_kind: MediaKind::Photo,
                    mime_type: "image/jpeg".to_string(),
                    bytes: bad_bytes.len() as u64,
                    content_hash: Some("0000".to_string()),
                    captured_at: None,
                    place_hint: None,
                },
            )
            .await
            .expect("reserve bad hash upload");
        service
            .receive_mobile_upload_chunk(&paired.bearer_token, bad_reserved.id, 0, bad_bytes)
            .await
            .expect("bad hash bytes");
        assert!(
            service
                .complete_mobile_upload(&paired.bearer_token, bad_reserved.id)
                .await
                .is_err(),
            "hash mismatches must fail completion"
        );
        let failed = service
            .mobile_upload_status(&paired.bearer_token, bad_reserved.id)
            .await
            .expect("bad hash status");
        assert_eq!(failed.status, MobileUploadStatus::Failed);

        let cancel_reserved = service
            .reserve_mobile_upload(
                &paired.bearer_token,
                MobileUploadRequest {
                    original_filename: "cancel-me.jpg".to_string(),
                    media_kind: MediaKind::Photo,
                    mime_type: "image/jpeg".to_string(),
                    bytes: bytes.len() as u64,
                    content_hash: None,
                    captured_at: None,
                    place_hint: None,
                },
            )
            .await
            .expect("reserve cancel upload");
        service
            .receive_mobile_upload_chunk(
                &paired.bearer_token,
                cancel_reserved.id,
                0,
                bytes[..8].to_vec(),
            )
            .await
            .expect("cancel upload first chunk");
        let cancel_dir = mobile_upload_dir(&service.config, cancel_reserved.id);
        assert!(cancel_dir.exists());
        let canceled = service
            .cancel_mobile_upload(&paired.bearer_token, cancel_reserved.id)
            .await
            .expect("cancel upload");
        assert_eq!(canceled.status, MobileUploadStatus::Canceled);
        assert!(!cancel_dir.exists());
        assert!(
            service
                .receive_mobile_upload_chunk(
                    &paired.bearer_token,
                    cancel_reserved.id,
                    8,
                    bytes[8..].to_vec(),
                )
                .await
                .is_err(),
            "canceled uploads must reject new chunks"
        );
    }

    #[tokio::test]
    async fn mobile_pairing_token_can_be_bound_to_a_vault() {
        let runtime_root = temp_root("mobile-vault-bound-pairing");
        let library_root = runtime_root.join("library");
        let service = GalleryService::new(AppConfig {
            runtime_root,
            ..AppConfig::default()
        })
        .expect("service");
        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Copy,
                original_storage_policy: None,
            })
            .await
            .expect("settings");
        let vault = service
            .create_vault(CreateVaultRequest {
                id: None,
                name: "Phone group".to_string(),
                storage_policy: None,
            })
            .await
            .expect("vault");

        let pairing = service
            .create_pairing_session(CreatePairingSessionRequest {
                device_name: "Moto G".to_string(),
                platform: "android".to_string(),
                vault_id: Some(vault.id),
            })
            .await
            .expect("pairing session");
        assert_eq!(pairing.vault_id, Some(vault.id));

        let paired = service
            .pair_mobile_device(MobilePairRequest {
                pairing_token: pairing.pairing_token,
                device_name: "Moto G".to_string(),
                platform: "android".to_string(),
                vault_id: None,
                storage_profile: None,
            })
            .await
            .expect("pair mobile");

        assert_eq!(paired.session.vault_id, vault.id);
    }

    #[tokio::test]
    async fn audit_events_track_admin_actions_and_persist_locally() {
        let runtime_root = temp_root("admin-audit-events");
        let library_root = runtime_root.join("library");
        let config = AppConfig {
            runtime_root,
            ..AppConfig::default()
        };
        let service = GalleryService::new(config.clone()).expect("service");
        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Copy,
                original_storage_policy: None,
            })
            .await
            .expect("settings");
        let vault = service
            .create_vault(CreateVaultRequest {
                id: None,
                name: "Family group".to_string(),
                storage_policy: None,
            })
            .await
            .expect("vault");
        let pairing = service
            .create_pairing_session(CreatePairingSessionRequest {
                device_name: "Phone".to_string(),
                platform: "android".to_string(),
                vault_id: Some(vault.id),
            })
            .await
            .expect("pairing");
        let paired = service
            .pair_mobile_device(MobilePairRequest {
                pairing_token: pairing.pairing_token.clone(),
                device_name: "Phone".to_string(),
                platform: "android".to_string(),
                vault_id: Some(vault.id),
                storage_profile: None,
            })
            .await
            .expect("pair mobile");
        let storage_device = service
            .create_device(CreateDeviceRequest {
                display_name: "NAS".to_string(),
                platform: "linux".to_string(),
                public_key: Some("nas-audit-key".to_string()),
                trust_level: Some(DeviceTrustLevel::StorageOnly),
                role: Some(DeviceRole::StorageOnly),
                storage_profile: None,
            })
            .await
            .expect("device");
        service
            .revoke_device(
                storage_device.id,
                RevokeDeviceRequest {
                    reason: Some("lost".to_string()),
                },
            )
            .await
            .expect("revoke");

        let events = service.audit_events(None).await;
        let actions = events
            .iter()
            .map(|event| event.action.as_str())
            .collect::<Vec<_>>();
        assert!(actions.contains(&"vault.create"));
        assert!(actions.contains(&"pairing.create"));
        assert!(actions.contains(&"device.mobile_pair"));
        assert!(actions.contains(&"device.create"));
        assert!(actions.contains(&"device.revoke"));
        assert!(
            events
                .iter()
                .any(|event| event.actor_label.as_deref() == Some("Phone"))
        );
        let serialized_events = serde_json::to_string(&events).expect("serialize events");
        assert!(!serialized_events.contains(&pairing.pairing_token));
        assert!(!serialized_events.contains(&paired.bearer_token));

        let restarted = GalleryService::new(config).expect("restart");
        let persisted = restarted.audit_events(Some(3)).await;
        assert_eq!(persisted.len(), 3);
        assert!(
            persisted
                .iter()
                .any(|event| event.action == "device.revoke")
        );
    }

    #[tokio::test]
    async fn explicit_first_vault_create_does_not_create_personal_vault() {
        let runtime_root = temp_root("explicit-first-vault");
        let library_root = runtime_root.join("library");
        let service = GalleryService::new(AppConfig {
            runtime_root,
            ..AppConfig::default()
        })
        .expect("service");
        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Copy,
                original_storage_policy: None,
            })
            .await
            .expect("settings");

        let vault = service
            .create_vault(CreateVaultRequest {
                id: None,
                name: "Family group".to_string(),
                storage_policy: None,
            })
            .await
            .expect("vault");
        let vaults = service.vaults().await;

        assert_eq!(vault.name, "Family group");
        assert_eq!(vaults.len(), 1);
        assert_eq!(vaults[0].id, vault.id);
    }

    #[tokio::test]
    async fn create_vault_is_idempotent_for_supplied_group_id() {
        let runtime_root = temp_root("cloud-group-idempotent-vault");
        let library_root = runtime_root.join("library");
        let service = GalleryService::new(AppConfig {
            runtime_root,
            ..AppConfig::default()
        })
        .expect("service");
        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Copy,
                original_storage_policy: None,
            })
            .await
            .expect("settings");
        let group_id = uuid::Uuid::new_v4();

        let first = service
            .create_vault(CreateVaultRequest {
                id: Some(group_id),
                name: "Cloud group".to_string(),
                storage_policy: None,
            })
            .await
            .expect("first vault");
        let second = service
            .create_vault(CreateVaultRequest {
                id: Some(group_id),
                name: "Cloud group".to_string(),
                storage_policy: None,
            })
            .await
            .expect("idempotent vault");
        let conflict = service
            .create_vault(CreateVaultRequest {
                id: Some(group_id),
                name: "Other group".to_string(),
                storage_policy: None,
            })
            .await;

        assert_eq!(first.id, group_id);
        assert_eq!(second.id, group_id);
        assert_eq!(service.vaults().await.len(), 1);
        assert!(conflict.is_err());
    }

    #[tokio::test]
    async fn mobile_pairing_rejects_wrong_expired_used_and_revoked_paths() {
        let runtime_root = temp_root("mobile-pairing-rejections");
        let library_root = runtime_root.join("library");
        let service = GalleryService::new(AppConfig {
            runtime_root,
            ..AppConfig::default()
        })
        .expect("service");
        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Copy,
                original_storage_policy: None,
            })
            .await
            .expect("settings");
        let first_vault = service
            .create_vault(CreateVaultRequest {
                id: None,
                name: "First group".to_string(),
                storage_policy: None,
            })
            .await
            .expect("first vault");
        let second_vault = service
            .create_vault(CreateVaultRequest {
                id: None,
                name: "Second group".to_string(),
                storage_policy: None,
            })
            .await
            .expect("second vault");

        let wrong_vault_pairing = service
            .create_pairing_session(CreatePairingSessionRequest {
                device_name: "Moto G".to_string(),
                platform: "android".to_string(),
                vault_id: Some(first_vault.id),
            })
            .await
            .expect("wrong-vault pairing");
        let wrong_vault = service
            .pair_mobile_device(MobilePairRequest {
                pairing_token: wrong_vault_pairing.pairing_token,
                device_name: "Moto G".to_string(),
                platform: "android".to_string(),
                vault_id: Some(second_vault.id),
                storage_profile: None,
            })
            .await;
        assert!(wrong_vault.is_err());

        let expired_pairing = service
            .create_pairing_session(CreatePairingSessionRequest {
                device_name: "Old phone".to_string(),
                platform: "android".to_string(),
                vault_id: Some(first_vault.id),
            })
            .await
            .expect("expired pairing");
        {
            let mut state = service.state.write().await;
            let pairing = state
                .pairings
                .iter_mut()
                .find(|pairing| pairing.id == expired_pairing.id)
                .expect("stored pairing");
            pairing.expires_at = Utc::now() - chrono::Duration::minutes(1);
        }
        let expired = service
            .pair_mobile_device(MobilePairRequest {
                pairing_token: expired_pairing.pairing_token,
                device_name: "Old phone".to_string(),
                platform: "android".to_string(),
                vault_id: Some(first_vault.id),
                storage_profile: None,
            })
            .await;
        assert!(expired.is_err());

        let used_pairing = service
            .create_pairing_session(CreatePairingSessionRequest {
                device_name: "Revoked phone".to_string(),
                platform: "android".to_string(),
                vault_id: Some(first_vault.id),
            })
            .await
            .expect("used pairing");
        let paired = service
            .pair_mobile_device(MobilePairRequest {
                pairing_token: used_pairing.pairing_token.clone(),
                device_name: "Revoked phone".to_string(),
                platform: "android".to_string(),
                vault_id: Some(first_vault.id),
                storage_profile: None,
            })
            .await
            .expect("pair mobile");
        let reused = service
            .pair_mobile_device(MobilePairRequest {
                pairing_token: used_pairing.pairing_token,
                device_name: "Second phone".to_string(),
                platform: "android".to_string(),
                vault_id: Some(first_vault.id),
                storage_profile: None,
            })
            .await;
        assert!(reused.is_err());

        service
            .revoke_device(
                paired.device.id,
                RevokeDeviceRequest {
                    reason: Some("lost".to_string()),
                },
            )
            .await
            .expect("revoke device");
        assert!(
            service
                .mobile_session_status(&paired.bearer_token)
                .await
                .is_err()
        );
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
                original_storage_policy: None,
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
                original_storage_policy: None,
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
        assert!(
            !original_path.exists(),
            "encrypted-only policy should remove managed plaintext originals after sealing"
        );

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
    async fn local_eviction_requires_completed_p2p_transfer_proof() {
        let runtime_root = temp_root("eviction-transfer-proof");
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
                original_storage_policy: None,
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
        let vault = service.vaults().await[0].clone();
        service
            .update_vault_storage_policy(
                vault.id,
                UpdateVaultStoragePolicyRequest {
                    policy: StoragePolicy {
                        mode: StoragePolicyMode::Custom,
                        min_replicas: 1,
                        preferred_device_ids: Vec::new(),
                        excluded_device_ids: Vec::new(),
                        min_free_space_bytes: 0,
                        allow_metered_network: true,
                        pause_on_low_battery: false,
                    },
                },
            )
            .await
            .expect("policy");
        let storage_device = service
            .create_device(CreateDeviceRequest {
                display_name: "Storage".to_string(),
                platform: "linux".to_string(),
                public_key: Some("storage-node".to_string()),
                trust_level: Some(DeviceTrustLevel::StorageOnly),
                role: Some(DeviceRole::StorageOnly),
                storage_profile: None,
            })
            .await
            .expect("device");

        let (blob_id, blob_bytes) = {
            let mut state = service.state.write().await;
            let blob = state.blob_records[0].clone();
            state.blob_replicas.push(BlobReplica {
                id: uuid::Uuid::new_v4(),
                blob_id: blob.id,
                device_id: storage_device.id,
                health: ReplicaHealth::Healthy,
                bytes_present: blob.bytes,
                verified_at: Some(Utc::now()),
                transfer_id: None,
            });
            service.persist_locked_state(&state).expect("persist");
            (blob.id, blob.bytes)
        };

        let blocked = service
            .evict_local_asset(imported.asset.id)
            .await
            .expect_err("unproven replica must block eviction");
        assert!(blocked.to_string().contains("verified P2P remote replicas"));

        {
            let mut state = service.state.write().await;
            let transfer_id = uuid::Uuid::new_v4();
            let from_device_id = local_device_id(&state);
            state.sync_transfers.push(SyncTransfer {
                id: transfer_id,
                vault_id: vault.id,
                blob_id,
                from_device_id,
                to_device_id: storage_device.id,
                status: SyncTransferStatus::Completed,
                bytes_total: blob_bytes,
                bytes_completed: blob_bytes,
                started_at: Some(Utc::now()),
                updated_at: Utc::now(),
                resumable_until: Utc::now() + chrono::Duration::days(7),
            });
            let replica = state
                .blob_replicas
                .iter_mut()
                .find(|replica| {
                    replica.blob_id == blob_id && replica.device_id == storage_device.id
                })
                .expect("replica");
            replica.transfer_id = Some(transfer_id);
            service.persist_locked_state(&state).expect("persist");
        }

        let availability = service
            .evict_local_asset(imported.asset.id)
            .await
            .expect("evict after proof");
        assert!(!availability.local_replica);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn p2p_sync_pushes_remote_replica_and_pulls_after_eviction() {
        let runtime_a = temp_root("p2p-device-a");
        let runtime_b = temp_root("p2p-device-b");
        let library_a = runtime_a.join("library");
        let library_b = runtime_b.join("library");
        let source = runtime_a.join("photo.jpg");
        let original_bytes = b"private-gallery-p2p-original-round-trip";
        fs::write(&source, original_bytes).expect("write source");

        let service_a = GalleryService::new(AppConfig {
            runtime_root: runtime_a.clone(),
            network_policy: NetworkPolicy::OfflineOnly,
            ..AppConfig::default()
        })
        .expect("service a");
        let service_b = GalleryService::new(AppConfig {
            runtime_root: runtime_b.clone(),
            network_policy: NetworkPolicy::OfflineOnly,
            ..AppConfig::default()
        })
        .expect("service b");
        service_a
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_a.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Copy,
                original_storage_policy: None,
            })
            .await
            .expect("settings a");
        service_b
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_b.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Copy,
                original_storage_policy: None,
            })
            .await
            .expect("settings b");

        let imported = service_a
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
        let source_vault = service_a.vaults().await[0].clone();
        service_b
            .create_vault(CreateVaultRequest {
                id: Some(source_vault.id),
                name: source_vault.name.clone(),
                storage_policy: Some(source_vault.storage_policy.clone()),
            })
            .await
            .expect("mirror source vault on storage peer");

        {
            let mut state_b = service_b.state.write().await;
            let local_b = local_device_id(&state_b).expect("local b before endpoint");
            let device = state_b
                .devices
                .iter_mut()
                .find(|device| device.id == local_b)
                .expect("local b device");
            device.trust_level = DeviceTrustLevel::StorageOnly;
            device.storage_profile.accepts_storage = true;
            for member in state_b
                .vault_members
                .iter_mut()
                .filter(|member| member.device_id == local_b)
            {
                member.role = DeviceRole::StorageOnly;
                member.trust_level = DeviceTrustLevel::StorageOnly;
            }
            service_b.persist_locked_state(&state_b).expect("persist b");
        }

        let endpoint_b = service_b
            .sync_network_local_endpoint()
            .await
            .expect("endpoint b");
        let endpoint_a = service_a
            .sync_network_local_endpoint()
            .await
            .expect("endpoint a");
        assert_eq!(
            endpoint_b.descriptor.trust_level,
            DeviceTrustLevel::StorageOnly
        );
        assert_eq!(endpoint_b.descriptor.role, DeviceRole::StorageOnly);
        let storage_profile = DeviceStorageProfile {
            reserved_bytes: 0,
            ..DeviceStorageProfile::default()
        };
        let device_b = service_a
            .enroll_device(EnrollDeviceRequest {
                display_name: endpoint_b.descriptor.device_name.clone(),
                platform: endpoint_b.descriptor.platform.clone(),
                public_key: Some(endpoint_b.descriptor.node_id.clone()),
                vault_id: None,
                role: Some(endpoint_b.descriptor.role.clone()),
                trust_level: Some(endpoint_b.descriptor.trust_level),
                storage_profile: Some(storage_profile.clone()),
                endpoint: Some(endpoint_b.descriptor.clone()),
            })
            .await
            .expect("enroll b on a");
        service_b
            .enroll_device(EnrollDeviceRequest {
                display_name: endpoint_a.descriptor.device_name.clone(),
                platform: endpoint_a.descriptor.platform.clone(),
                public_key: Some(endpoint_a.descriptor.node_id.clone()),
                vault_id: Some(source_vault.id),
                role: Some(DeviceRole::Contributor),
                trust_level: Some(DeviceTrustLevel::Trusted),
                storage_profile: Some(storage_profile),
                endpoint: Some(endpoint_a.descriptor.clone()),
            })
            .await
            .expect("enroll a on b");
        assert_eq!(endpoint_b.descriptor.device_id, Some(device_b.id));

        let push_plan = service_a
            .run_sync(RunSyncRequest {
                vault_id: None,
                dry_run: false,
            })
            .await
            .expect("push sync");
        assert_eq!(
            push_plan
                .execution_results
                .iter()
                .filter(|result| result.status == SyncTransferExecutionStatus::Completed)
                .count(),
            1,
            "{:?}",
            push_plan.execution_results
        );
        {
            let state_b = service_b.state.read().await;
            let local_b = local_device_id(&state_b).expect("local b");
            assert!(state_b.assets.is_empty());
            assert_eq!(state_b.blob_records.len(), 1);
            assert_eq!(state_b.blob_records[0].bytes, original_bytes.len() as u64);
            assert!(state_b.blob_records[0].content_hash.starts_with("opaque:"));
            assert!(
                state_b
                    .blob_chunks
                    .iter()
                    .all(|chunk| chunk.local_path.is_some()),
                "remote encrypted chunks should be stored locally on device b"
            );
            assert!(
                state_b
                    .blob_chunks
                    .iter()
                    .all(|chunk| chunk.content_hash.starts_with("opaque:")
                        && chunk.nonce_hex.is_none()
                        && chunk.aad.is_none()),
                "storage-only device should not retain plaintext hashes or decrypt metadata"
            );
            assert!(state_b.blob_replicas.iter().any(|replica| {
                replica.blob_id == state_b.blob_records[0].id
                    && replica.device_id == local_b
                    && replica.health == ReplicaHealth::Healthy
            }));
        }
        assert!(find_pgblob(&library_b.join("vaults")).is_some());

        let vault = service_a.vaults().await[0].clone();
        service_a
            .update_vault_storage_policy(
                vault.id,
                UpdateVaultStoragePolicyRequest {
                    policy: StoragePolicy {
                        mode: StoragePolicyMode::Custom,
                        min_replicas: 1,
                        preferred_device_ids: Vec::new(),
                        excluded_device_ids: Vec::new(),
                        min_free_space_bytes: 0,
                        allow_metered_network: true,
                        pause_on_low_battery: false,
                    },
                },
            )
            .await
            .expect("single remote replica policy");
        let evicted = service_a
            .evict_local_asset(imported.asset.id)
            .await
            .expect("evict local");
        assert_eq!(evicted.state, AssetAvailabilityState::RemoteAvailable);
        assert!(!evicted.local_replica);

        let pinning = service_a
            .pin_local_asset(imported.asset.id)
            .await
            .expect("queue pin");
        assert_eq!(pinning.state, AssetAvailabilityState::TransferPending);
        let pull_plan = service_a
            .run_sync(RunSyncRequest {
                vault_id: None,
                dry_run: false,
            })
            .await
            .expect("pull sync");
        assert_eq!(
            pull_plan
                .execution_results
                .iter()
                .filter(|result| result.status == SyncTransferExecutionStatus::Completed)
                .count(),
            1,
            "{:?}",
            pull_plan.execution_results
        );
        let availability = service_a
            .asset_availability(imported.asset.id)
            .await
            .expect("availability after pull");
        assert_eq!(availability.state, AssetAvailabilityState::LocalAvailable);
        let (mime_type, restored_bytes) = service_a
            .asset_original_bytes(imported.asset.id)
            .await
            .expect("restored original");
        assert_eq!(mime_type, "image/jpeg");
        assert_eq!(restored_bytes, original_bytes);

        let _ = service_a.stop_sync_network().await;
        let _ = service_b.stop_sync_network().await;
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
                original_storage_policy: None,
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
        assert!(!original_path.exists());

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
                original_storage_policy: None,
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
        assert!(!original_path.exists());
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
                original_storage_policy: None,
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
        assert!(!original_path.exists());

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
                original_storage_policy: None,
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
                original_storage_policy: None,
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
                original_storage_policy: None,
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
    async fn manual_tags_persist_and_search_locally() {
        let runtime_root = temp_root("manual-tags");
        let library_root = runtime_root.join("library");
        let source_root = runtime_root.join("source");
        fs::create_dir_all(&source_root).expect("source dir");
        let invoice_path = source_root.join("invoice.pdf");
        fs::write(&invoice_path, b"invoice-bytes").expect("write file");

        let service = GalleryService::new(AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        })
        .expect("service");

        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Reference,
                original_storage_policy: None,
            })
            .await
            .expect("settings");

        let imported = service
            .import_asset(ImportAssetRequest {
                source_path: invoice_path.to_string_lossy().to_string(),
                original_filename: "invoice.pdf".to_string(),
                media_kind: MediaKind::Document,
                mime_type: "application/pdf".to_string(),
                bytes: 13,
                content_hash: Some(sha256_hex_bytes(b"invoice-bytes")),
                captured_at: Some(Utc::now()),
                place_hint: None,
                import_mode: Some(ImportMode::Reference),
            })
            .await
            .expect("import invoice");

        let tagged = service
            .update_asset_tags(
                imported.asset.id,
                UpdateAssetTagsRequest {
                    tags: vec![
                        " invoice ".to_string(),
                        "Client Acme".to_string(),
                        "invoice".to_string(),
                    ],
                },
            )
            .await
            .expect("update tags");
        assert_eq!(tagged.manual_tags, vec!["invoice", "Client Acme"]);

        let tag_result = service
            .search(SearchQuery {
                text: None,
                people: None,
                places: None,
                events: None,
                workspace: None,
                client: None,
                project: None,
                topic: None,
                source_folder: None,
                device: None,
                media_kind: Some("documents".to_string()),
                tags: Some("invoice, acme".to_string()),
                favorite: None,
                from_date: None,
                to_date: None,
                include_archived: false,
                limit: None,
            })
            .await;
        assert_eq!(tag_result.assets.len(), 1);
        assert_eq!(tag_result.assets[0].id, imported.asset.id);

        let text_result = service
            .search(SearchQuery {
                text: Some("acme".to_string()),
                people: None,
                places: None,
                events: None,
                workspace: None,
                client: None,
                project: None,
                topic: None,
                source_folder: None,
                device: None,
                media_kind: None,
                tags: None,
                favorite: None,
                from_date: None,
                to_date: None,
                include_archived: false,
                limit: None,
            })
            .await;
        assert_eq!(text_result.assets.len(), 1);

        let restarted = GalleryService::new(AppConfig {
            runtime_root,
            ..AppConfig::default()
        })
        .expect("restarted service");
        let visible = restarted.timeline().await;
        let restarted_asset = visible
            .buckets
            .iter()
            .flat_map(|bucket| bucket.assets.iter())
            .find(|asset| asset.id == imported.asset.id)
            .expect("restarted tagged asset");
        assert_eq!(restarted_asset.manual_tags, vec!["invoice", "Client Acme"]);
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
                original_storage_policy: None,
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
    async fn smart_folders_persist_and_run_local_search_filters() {
        let runtime_root = temp_root("smart-folders");
        let library_root = runtime_root.join("library");
        let source_root = runtime_root.join("source");
        fs::create_dir_all(&source_root).expect("source dir");
        let proposal_path = source_root.join("proposal.pdf");
        fs::write(&proposal_path, b"private proposal").expect("write proposal");

        let service = GalleryService::new(AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        })
        .expect("service");

        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Reference,
                original_storage_policy: None,
            })
            .await
            .expect("settings");

        let imported = service
            .import_asset(ImportAssetRequest {
                source_path: proposal_path.to_string_lossy().to_string(),
                original_filename: "proposal.pdf".to_string(),
                media_kind: MediaKind::Document,
                mime_type: "application/pdf".to_string(),
                bytes: 16,
                content_hash: Some(sha256_hex_bytes(b"private proposal")),
                captured_at: Some(Utc::now()),
                place_hint: None,
                import_mode: Some(ImportMode::Reference),
            })
            .await
            .expect("import proposal");

        {
            let mut state = service.state.write().await;
            let asset = state
                .assets
                .iter_mut()
                .find(|asset| asset.id == imported.asset.id)
                .expect("asset");
            let metadata = asset.metadata.as_mut().expect("metadata");
            metadata.folder_hint = Some("Project Launch".to_string());
            metadata.organization = FileOrganizationHints {
                source_folder: Some("Project Launch".to_string()),
                workspace: Some("Office".to_string()),
                client: Some("Client Acme".to_string()),
                project: Some("Project Launch".to_string()),
                topic: Some("Reports".to_string()),
                path_segments: vec![
                    "Office".to_string(),
                    "Client Acme".to_string(),
                    "Project Launch".to_string(),
                ],
            };
            service.persist_locked_state(&state).expect("persist hints");
        }

        let folder = service
            .create_smart_folder(CreateSmartFolderRequest {
                title: "Acme launch reports".to_string(),
                query: SearchQuery {
                    text: None,
                    people: None,
                    places: None,
                    events: None,
                    workspace: Some("office".to_string()),
                    client: Some("acme".to_string()),
                    project: Some("launch".to_string()),
                    topic: Some("reports".to_string()),
                    source_folder: Some("project launch".to_string()),
                    device: None,
                    media_kind: Some("documents".to_string()),
                    tags: None,
                    favorite: None,
                    from_date: None,
                    to_date: None,
                    include_archived: false,
                    limit: None,
                },
            })
            .await
            .expect("create smart folder");

        let result = service
            .run_smart_folder(folder.id)
            .await
            .expect("run smart folder");
        assert_eq!(result.assets.len(), 1);
        assert_eq!(result.assets[0].id, imported.asset.id);

        let restarted = GalleryService::new(AppConfig {
            runtime_root,
            ..AppConfig::default()
        })
        .expect("restarted service");
        let folders = restarted.smart_folders().await;
        assert_eq!(folders.len(), 1);
        assert_eq!(folders[0].title, "Acme launch reports");
        let restarted_result = restarted
            .run_smart_folder(folders[0].id)
            .await
            .expect("run restarted smart folder");
        assert_eq!(restarted_result.assets.len(), 1);
        assert_eq!(restarted_result.assets[0].id, imported.asset.id);
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
                original_storage_policy: None,
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
    async fn duplicate_review_summarizes_committed_skipped_imports() {
        let runtime_root = temp_root("duplicate-review");
        let library_root = runtime_root.join("library");
        let first_source = runtime_root.join("first-source");
        let second_source = runtime_root.join("second-source");
        fs::create_dir_all(&first_source).expect("first source dir");
        fs::create_dir_all(&second_source).expect("second source dir");
        let bytes = b"same-private-file-bytes";
        fs::write(first_source.join("a.jpg"), bytes).expect("write first");
        fs::write(second_source.join("b.jpg"), bytes).expect("write duplicate");

        let service = GalleryService::new(AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        })
        .expect("service");

        service
            .update_library_settings(UpdateLibrarySettingsRequest {
                library_root: library_root.to_string_lossy().to_string(),
                default_import_mode: ImportMode::Copy,
                original_storage_policy: None,
            })
            .await
            .expect("settings");

        let first = service
            .scan_import_source(ScanImportSourceRequest {
                source_path: first_source.to_string_lossy().to_string(),
                source_kind: ImportSourceKind::Folder,
                recursive: false,
                import_mode: Some(ImportMode::Copy),
                add_as_watch_folder: false,
                place_hint: None,
            })
            .await
            .expect("first scan");
        let first = service
            .commit_import_session(first.id, vec![], Some(ImportMode::Copy), None)
            .await
            .expect("first commit");
        let original_asset_id = first.imported_asset_ids[0];

        let duplicate = service
            .scan_import_source(ScanImportSourceRequest {
                source_path: second_source.to_string_lossy().to_string(),
                source_kind: ImportSourceKind::Folder,
                recursive: false,
                import_mode: Some(ImportMode::Copy),
                add_as_watch_folder: false,
                place_hint: None,
            })
            .await
            .expect("duplicate scan");
        service
            .commit_import_session(duplicate.id, vec![], Some(ImportMode::Copy), None)
            .await
            .expect("duplicate commit");

        let summary = service.duplicate_review_summary().await;

        assert_eq!(summary.duplicate_assets, 1);
        assert_eq!(summary.duplicate_candidates, 1);
        assert_eq!(summary.sessions_with_duplicates, 1);
        assert_eq!(summary.protected_bytes, bytes.len() as u64);
        assert!(summary.privacy_detail.contains("source paths"));
        let entry = summary.entries.first().expect("duplicate entry");
        assert_eq!(entry.asset_id, original_asset_id);
        assert_eq!(entry.media_kind, MediaKind::Photo);
        assert_eq!(entry.original_bytes, bytes.len() as u64);
        assert_eq!(entry.protected_bytes, bytes.len() as u64);
        assert_eq!(entry.source_kinds, vec!["folder".to_string()]);
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
                original_storage_policy: None,
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
                original_storage_policy: None,
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
        assert!(!destination.exists());
        let (_, restored) = service
            .asset_original_bytes(asset.id)
            .await
            .expect("decrypt moved original");
        assert_eq!(sha256_hex_bytes(&restored), asset.content_hash);
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
                original_storage_policy: None,
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
                original_storage_policy: None,
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
                original_storage_policy: None,
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
                original_storage_policy: None,
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
                original_storage_policy: None,
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
        assert!(!status.remote_mobile_access_enabled);
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
    async fn allows_non_loopback_bind_for_remote_mobile_mode() {
        let runtime_root = temp_root("remote-mobile-bind");
        let service = GalleryService::new(AppConfig {
            runtime_root,
            bind_host: "100.64.0.10".to_string(),
            allow_remote_mobile: true,
            ..AppConfig::default()
        })
        .expect("remote mobile bind should be allowed");

        let status = service.privacy_status().await.expect("privacy status");
        assert_eq!(status.daemon_bind_address, "100.64.0.10:4821");
        assert!(!status.loopback_only);
        assert!(status.remote_mobile_access_enabled);
        assert!(!status.developer_mode);
        assert!(!status.photo_processing_network_allowed);
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
                original_storage_policy: None,
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
                original_storage_policy: None,
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
                events: None,
                workspace: None,
                client: None,
                project: None,
                topic: None,
                source_folder: None,
                device: None,
                media_kind: None,
                tags: None,
                favorite: None,
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
                events: None,
                workspace: None,
                client: None,
                project: None,
                topic: None,
                source_folder: None,
                device: None,
                media_kind: None,
                tags: None,
                favorite: None,
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
                original_storage_policy: None,
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
                original_storage_policy: None,
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
                original_storage_policy: None,
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
            && job
                .detail
                .as_deref()
                .unwrap_or_default()
                .to_lowercase()
                .contains("pillow")
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
                events: None,
                workspace: None,
                client: None,
                project: None,
                topic: None,
                source_folder: None,
                device: None,
                media_kind: None,
                tags: None,
                favorite: None,
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
                events: None,
                workspace: None,
                client: None,
                project: None,
                topic: None,
                source_folder: None,
                device: None,
                media_kind: None,
                tags: None,
                favorite: None,
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
                original_storage_policy: None,
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
                original_storage_policy: None,
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
                events: None,
                workspace: None,
                client: None,
                project: None,
                topic: None,
                source_folder: None,
                device: None,
                media_kind: None,
                tags: None,
                favorite: None,
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
