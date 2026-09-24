use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MediaKind {
    Photo,
    Video,
    Document,
    Audio,
    Archive,
    Text,
    Other,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum VaultFileKind {
    Folder,
    File,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ImportMode {
    Copy,
    Reference,
    Move,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ImportSourceKind {
    Folder,
    RemovableDrive,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ImportSessionStatus {
    Scanned,
    Committed,
    Failed,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum VariantKind {
    Original,
    Preview,
    Thumbnail,
    FaceCrop,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum FeedbackKind {
    CreatePerson,
    MergePerson,
    SplitPerson,
    RenamePerson,
    AssignPersonAssets,
    RemovePersonAssets,
    UpdateAssetFlags,
    CreateAlbum,
    RenameAlbum,
    AddAlbumAssets,
    RemoveAlbumAssets,
    DeleteAlbum,
    HideFace,
    FixDate,
    FixPlace,
    TitleEvent,
    RejectMatch,
    SearchClick,
    UpdateAssetTags,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum JobKind {
    Import,
    MetadataExtraction,
    ThumbnailGeneration,
    OcrIndex,
    SceneIndex,
    SemanticIndex,
    FaceDetection,
    FaceClustering,
    EventClustering,
    SearchReindex,
    MobileSync,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum JobStatus {
    Queued,
    Running,
    Completed,
    Failed,
    Canceled,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SyncStatus {
    Pending,
    Active,
    Completed,
    Failed,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DeviceRole {
    Admin,
    Contributor,
    Viewer,
    StorageOnly,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DeviceTrustLevel {
    Trusted,
    StorageOnly,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum StoragePolicyMode {
    MaxPoolSingleCopy,
    ProtectedMin2,
    Custom,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct StoragePolicy {
    pub mode: StoragePolicyMode,
    pub min_replicas: u8,
    #[serde(default)]
    pub preferred_device_ids: Vec<Uuid>,
    #[serde(default)]
    pub excluded_device_ids: Vec<Uuid>,
    pub min_free_space_bytes: u64,
    pub allow_metered_network: bool,
    pub pause_on_low_battery: bool,
}

impl StoragePolicy {
    pub fn protected_min_2() -> Self {
        Self {
            mode: StoragePolicyMode::ProtectedMin2,
            min_replicas: 2,
            preferred_device_ids: Vec::new(),
            excluded_device_ids: Vec::new(),
            min_free_space_bytes: 10 * 1024 * 1024 * 1024,
            allow_metered_network: false,
            pause_on_low_battery: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeviceStorageProfile {
    pub device_id: Option<Uuid>,
    pub total_bytes: Option<u64>,
    pub available_bytes: Option<u64>,
    pub reserved_bytes: u64,
    pub accepts_storage: bool,
    pub battery_powered: bool,
    pub metered_network: bool,
    pub low_battery: bool,
}

impl Default for DeviceStorageProfile {
    fn default() -> Self {
        Self {
            device_id: None,
            total_bytes: None,
            available_bytes: None,
            reserved_bytes: 10 * 1024 * 1024 * 1024,
            accepts_storage: true,
            battery_powered: false,
            metered_network: false,
            low_battery: false,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Vault {
    pub id: Uuid,
    pub name: String,
    pub storage_policy: StoragePolicy,
    pub key_version: u32,
    pub deletion_grace_days: u32,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DeviceIdentity {
    pub id: Uuid,
    pub display_name: String,
    pub platform: String,
    pub public_key: String,
    pub trust_level: DeviceTrustLevel,
    pub storage_profile: DeviceStorageProfile,
    pub enrolled_at: DateTime<Utc>,
    pub last_seen_at: Option<DateTime<Utc>>,
    pub revoked_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct VaultMember {
    pub id: Uuid,
    pub vault_id: Uuid,
    pub device_id: Uuid,
    pub role: DeviceRole,
    pub trust_level: DeviceTrustLevel,
    pub display_name: String,
    pub added_at: DateTime<Utc>,
    pub revoked_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BlobRecord {
    pub id: Uuid,
    pub vault_id: Uuid,
    pub asset_id: Uuid,
    pub content_hash: String,
    pub encrypted_hash: String,
    pub bytes: u64,
    pub chunk_count: u32,
    pub encryption_key_version: u32,
    pub created_at: DateTime<Utc>,
    pub tombstoned_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BlobChunk {
    pub id: Uuid,
    pub blob_id: Uuid,
    pub chunk_index: u32,
    pub content_hash: String,
    pub encrypted_hash: String,
    pub bytes: u64,
    #[serde(default)]
    pub encrypted_bytes: u64,
    #[serde(default)]
    pub local_path: Option<String>,
    #[serde(default)]
    pub nonce_hex: Option<String>,
    #[serde(default)]
    pub aad: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ReplicaHealth {
    Healthy,
    Unverified,
    Offline,
    Corrupt,
    Missing,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BlobReplica {
    pub id: Uuid,
    pub blob_id: Uuid,
    pub device_id: Uuid,
    pub health: ReplicaHealth,
    pub bytes_present: u64,
    pub verified_at: Option<DateTime<Utc>>,
    pub transfer_id: Option<Uuid>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SyncTransferStatus {
    Pending,
    Running,
    Completed,
    Failed,
    Aborted,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SyncTransfer {
    pub id: Uuid,
    pub vault_id: Uuid,
    pub blob_id: Uuid,
    pub from_device_id: Option<Uuid>,
    pub to_device_id: Uuid,
    pub status: SyncTransferStatus,
    pub bytes_total: u64,
    pub bytes_completed: u64,
    pub started_at: Option<DateTime<Utc>>,
    pub updated_at: DateTime<Utc>,
    pub resumable_until: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PeerEndpointDescriptor {
    pub device_id: Option<Uuid>,
    pub device_name: String,
    pub platform: String,
    pub node_id: String,
    #[serde(default)]
    pub relay_urls: Vec<String>,
    #[serde(default)]
    pub direct_addresses: Vec<String>,
    pub expires_at: DateTime<Utc>,
    pub trust_level: DeviceTrustLevel,
    pub role: DeviceRole,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LocalEndpointPayload {
    pub descriptor: PeerEndpointDescriptor,
    pub pairing_payload: String,
    pub detail: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SyncTransferExecutionStatus {
    Completed,
    Failed,
    Skipped,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SyncTransferExecutionResult {
    pub transfer_id: Uuid,
    pub blob_id: Uuid,
    pub from_device_id: Option<Uuid>,
    pub to_device_id: Uuid,
    pub status: SyncTransferExecutionStatus,
    pub bytes_transferred: u64,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SyncConflict {
    pub id: Uuid,
    pub vault_id: Uuid,
    pub asset_id: Option<Uuid>,
    pub field: String,
    pub actor_device_ids: Vec<Uuid>,
    pub detected_at: DateTime<Utc>,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SyncPlan {
    pub generated_at: DateTime<Utc>,
    pub vault_ids: Vec<Uuid>,
    pub transfers: Vec<SyncTransfer>,
    pub conflicts: Vec<SyncConflict>,
    pub under_replicated_blob_ids: Vec<Uuid>,
    pub policy_satisfied: bool,
    pub detail: String,
    #[serde(default)]
    pub execution_results: Vec<SyncTransferExecutionResult>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct VaultInvite {
    pub id: Uuid,
    pub vault_id: Uuid,
    pub invited_device_name: String,
    pub role: DeviceRole,
    pub trust_level: DeviceTrustLevel,
    pub invite_code: String,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    pub accepted_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RelayEndpoint {
    pub id: Uuid,
    pub device_id: Uuid,
    pub node_id: String,
    pub relay_url: Option<String>,
    pub direct_addresses: Vec<String>,
    pub last_seen_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CapabilityGrant {
    pub id: Uuid,
    pub vault_id: Uuid,
    pub device_id: Uuid,
    pub capability: String,
    pub granted_by_device_id: Option<Uuid>,
    pub granted_at: DateTime<Utc>,
    pub expires_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct VaultKeyEnvelope {
    pub id: Uuid,
    pub vault_id: Uuid,
    pub device_id: Uuid,
    pub key_version: u32,
    pub algorithm: String,
    pub encrypted_vault_key: String,
    pub created_at: DateTime<Utc>,
    pub revoked_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SyncNetworkStatus {
    pub started: bool,
    pub transport: String,
    pub local_device_id: Option<Uuid>,
    pub local_node_id: Option<String>,
    pub direct_addresses: Vec<String>,
    pub relay_urls: Vec<String>,
    pub active_transfer_count: usize,
    pub pending_transfer_count: usize,
    pub completed_transfer_count: usize,
    pub failed_transfer_count: usize,
    pub detail: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AssetAvailabilityState {
    LocalAvailable,
    RemoteAvailable,
    RemoteOffline,
    UnderReplicated,
    Missing,
    Corrupt,
    TransferPending,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AssetAvailability {
    pub asset_id: Uuid,
    pub vault_id: Option<Uuid>,
    pub state: AssetAvailabilityState,
    pub local_replica: bool,
    pub reachable_replica_device_ids: Vec<Uuid>,
    pub offline_replica_device_ids: Vec<Uuid>,
    pub replica_count: usize,
    pub required_replica_count: usize,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct VaultStatus {
    pub vault: Vault,
    pub members: Vec<VaultMember>,
    pub devices: Vec<DeviceIdentity>,
    pub assets_total: usize,
    pub blobs_total: usize,
    pub local_available_assets: usize,
    pub remote_available_assets: usize,
    pub under_replicated_blobs: usize,
    pub missing_blobs: usize,
    pub policy_satisfied: bool,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum P2PProtocolMessage {
    Hello {
        device_id: Uuid,
        vault_ids: Vec<Uuid>,
        protocol_version: u16,
    },
    VaultManifest {
        vault_id: Uuid,
        manifest_hash: String,
        latest_oplog_position: u64,
    },
    OplogSince {
        vault_id: Uuid,
        after_position: u64,
    },
    BlobOffer {
        vault_id: Uuid,
        blob_id: Uuid,
        bytes: u64,
        encrypted_hash: String,
    },
    BlobRequest {
        vault_id: Uuid,
        blob_id: Uuid,
        missing_chunk_indexes: Vec<u32>,
    },
    BlobChunk {
        vault_id: Uuid,
        blob_id: Uuid,
        chunk_index: u32,
        encrypted_hash: String,
        bytes: u64,
    },
    TransferCommit {
        transfer_id: Uuid,
        blob_id: Uuid,
        encrypted_hash: String,
    },
    TransferAbort {
        transfer_id: Uuid,
        reason: String,
    },
    AvailabilityHeartbeat {
        device_id: Uuid,
        blob_ids: Vec<Uuid>,
        observed_at: DateTime<Utc>,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum EventTitleSource {
    Generated,
    User,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "snake_case")]
pub enum MetadataSource {
    Manual,
    TakeoutSidecar,
    Embedded,
    Filesystem,
    Unknown,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct FileOrganizationHints {
    pub source_folder: Option<String>,
    pub workspace: Option<String>,
    pub client: Option<String>,
    pub project: Option<String>,
    pub topic: Option<String>,
    pub path_segments: Vec<String>,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum NetworkPolicy {
    OfflineOnly,
    #[default]
    AskBeforeDownload,
    DeveloperFetch,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ModelTask {
    FaceDetection,
    FaceEmbedding,
    SceneTagging,
    Ocr,
    SemanticEmbedding,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ModelInstallStatus {
    NotInstalled,
    Installed,
    PendingReview,
    DownloadBlocked,
    HashMismatch,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BoundingBox {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ModelProvenance {
    pub model_name: String,
    pub model_version: String,
    #[serde(default)]
    pub model_hash: Option<String>,
    pub created_at: DateTime<Utc>,
    pub rebuildable: bool,
}

impl ModelProvenance {
    pub fn local(model_name: impl Into<String>, model_version: impl Into<String>) -> Self {
        Self {
            model_name: model_name.into(),
            model_version: model_version.into(),
            model_hash: None,
            created_at: Utc::now(),
            rebuildable: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LibrarySettings {
    pub library_root: String,
    pub default_import_mode: ImportMode,
    #[serde(default)]
    pub original_storage_policy: OriginalStoragePolicy,
    pub initialized_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum OriginalStoragePolicy {
    #[default]
    EncryptedOnly,
    KeepPlaintextCopy,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct WatchFolder {
    pub id: Uuid,
    pub path: String,
    pub recursive: bool,
    pub import_mode: ImportMode,
    pub created_at: DateTime<Utc>,
    pub last_scanned_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AssetVariant {
    pub id: Uuid,
    pub kind: VariantKind,
    pub relative_path: String,
    pub mime_type: String,
    pub bytes: u64,
    pub width: Option<u32>,
    pub height: Option<u32>,
    #[serde(flatten)]
    pub derived: ModelProvenance,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Asset {
    pub id: Uuid,
    pub original_filename: String,
    pub relative_original_path: String,
    pub source_path: String,
    pub content_hash: String,
    pub media_kind: MediaKind,
    pub import_mode: ImportMode,
    pub bytes: u64,
    pub mime_type: String,
    pub captured_at: DateTime<Utc>,
    pub imported_at: DateTime<Utc>,
    pub archived: bool,
    pub favorite: bool,
    pub is_available: bool,
    pub place_hint: Option<String>,
    #[serde(default)]
    pub manual_tags: Vec<String>,
    pub metadata: Option<AssetMetadata>,
    pub variants: Vec<AssetVariant>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct VaultFileEntry {
    pub id: Uuid,
    pub vault_id: Uuid,
    pub parent_id: Option<Uuid>,
    pub asset_id: Option<Uuid>,
    pub name: String,
    pub kind: VaultFileKind,
    pub media_kind: Option<MediaKind>,
    pub mime_type: Option<String>,
    pub bytes: u64,
    pub content_hash: Option<String>,
    pub origin_device_id: Option<Uuid>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub trashed_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub organization: FileOrganizationHints,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct VaultFileDeviceSummary {
    pub id: Uuid,
    pub display_name: String,
    pub platform: String,
    pub revoked_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct VaultFileTreeResponse {
    pub vault_id: Option<Uuid>,
    pub root_entry_ids: Vec<Uuid>,
    pub entries: Vec<VaultFileEntry>,
    #[serde(default)]
    pub devices: Vec<VaultFileDeviceSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct GeoTag {
    pub latitude: f64,
    pub longitude: f64,
    pub altitude_meters: Option<f64>,
    pub source: MetadataSource,
    pub exact_hidden: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CameraInfo {
    pub make: Option<String>,
    pub model: Option<String>,
    pub lens_model: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AssetMetadata {
    pub asset_id: Uuid,
    pub captured_at: DateTime<Utc>,
    pub captured_at_source: MetadataSource,
    pub timezone_offset_minutes: Option<i32>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub camera: Option<CameraInfo>,
    pub geo: Option<GeoTag>,
    pub sidecar_title: Option<String>,
    pub sidecar_description: Option<String>,
    pub folder_hint: Option<String>,
    #[serde(default)]
    pub organization: FileOrganizationHints,
    #[serde(flatten)]
    pub derived: ModelProvenance,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Album {
    pub id: Uuid,
    pub title: String,
    pub asset_ids: Vec<Uuid>,
    pub cover_asset_id: Option<Uuid>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SmartFolder {
    pub id: Uuid,
    pub title: String,
    pub query: SearchQuery,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PersonCluster {
    pub id: Uuid,
    pub display_name: String,
    pub asset_ids: Vec<Uuid>,
    pub face_template_ids: Vec<Uuid>,
    pub representative_asset_id: Option<Uuid>,
    pub hidden: bool,
    #[serde(flatten)]
    pub derived: ModelProvenance,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PlaceCluster {
    pub id: Uuid,
    pub label: String,
    pub country_code: Option<String>,
    pub region: Option<String>,
    pub asset_ids: Vec<Uuid>,
    pub centroid_latitude: Option<f64>,
    pub centroid_longitude: Option<f64>,
    #[serde(flatten)]
    pub derived: ModelProvenance,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct EventCluster {
    pub id: Uuid,
    pub title: String,
    pub title_source: EventTitleSource,
    pub asset_ids: Vec<Uuid>,
    pub start_at: DateTime<Utc>,
    pub end_at: DateTime<Utc>,
    pub place_id: Option<Uuid>,
    pub people_ids: Vec<Uuid>,
    #[serde(flatten)]
    pub derived: ModelProvenance,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FaceTemplate {
    pub id: Uuid,
    pub asset_id: Uuid,
    pub person_cluster_id: Option<Uuid>,
    pub preview_variant_id: Option<Uuid>,
    pub bounding_box: BoundingBox,
    #[serde(flatten)]
    pub derived: ModelProvenance,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FeedbackEvent {
    pub id: Uuid,
    pub kind: FeedbackKind,
    pub payload: Value,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AuditEvent {
    pub id: Uuid,
    pub action: String,
    pub target_kind: String,
    pub target_id: Option<Uuid>,
    pub actor_device_id: Option<Uuid>,
    pub actor_label: Option<String>,
    pub summary: String,
    #[serde(default)]
    pub payload: Value,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CorrectionKind {
    CorrectDate,
    CorrectPlace,
    TitleEvent,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CorrectionRecord {
    pub id: Uuid,
    pub kind: CorrectionKind,
    pub asset_id: Option<Uuid>,
    pub place_id: Option<Uuid>,
    pub event_id: Option<Uuid>,
    pub previous_json: Value,
    pub applied_json: Value,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DevicePairing {
    pub id: Uuid,
    pub device_name: String,
    pub platform: String,
    pub vault_id: Option<Uuid>,
    /// Plaintext pairing secret, returned to the desktop for the invite QR and
    /// otherwise kept only in memory once the pairing is persisted.
    pub pairing_token: String,
    /// SHA-256 hex of `pairing_token`. This is what is stored at rest and what
    /// mobile pairing requests are matched against.
    pub pairing_token_hash: String,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    pub approved_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SyncSession {
    pub id: Uuid,
    pub pairing_id: Uuid,
    pub status: SyncStatus,
    pub started_at: DateTime<Utc>,
    pub last_seen_at: Option<DateTime<Utc>>,
    pub uploaded_asset_ids: Vec<Uuid>,
    pub rejected_asset_ids: Vec<Uuid>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MobileSession {
    pub id: Uuid,
    pub device_id: Uuid,
    pub vault_id: Uuid,
    #[serde(skip_serializing)]
    pub token_hash: String,
    pub display_name: String,
    pub platform: String,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    pub last_seen_at: Option<DateTime<Utc>>,
    pub revoked_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MobileSessionRefreshResponse {
    pub session: MobileSession,
    pub bearer_token: String,
    pub previous_session_id: Uuid,
    pub detail: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MobileUploadStatus {
    Pending,
    Running,
    Completed,
    Failed,
    Canceled,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MobileUpload {
    pub id: Uuid,
    pub session_id: Uuid,
    pub device_id: Uuid,
    pub vault_id: Uuid,
    pub asset_id: Option<Uuid>,
    pub original_filename: String,
    pub media_kind: MediaKind,
    pub mime_type: String,
    pub bytes_total: u64,
    pub bytes_received: u64,
    pub content_hash: Option<String>,
    pub captured_at: Option<DateTime<Utc>>,
    pub place_hint: Option<String>,
    pub status: MobileUploadStatus,
    pub error_detail: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MobilePairResponse {
    pub session: MobileSession,
    pub device: DeviceIdentity,
    pub bearer_token: String,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MobileAssetSummary {
    pub asset_id: Uuid,
    pub original_filename: String,
    pub media_kind: MediaKind,
    pub mime_type: String,
    pub bytes: u64,
    pub content_hash: String,
    pub captured_at: DateTime<Utc>,
    pub available: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MobileWorkspaceCapabilities {
    pub can_browse_library: bool,
    pub can_search: bool,
    pub can_upload_camera_roll: bool,
    pub can_download_originals: bool,
    pub can_manage_storage: bool,
    pub can_import_desktop_folders: bool,
    pub can_run_models: bool,
    pub role_detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MobileWorkspaceResponse {
    pub session: MobileSession,
    #[serde(default)]
    pub sessions: Vec<MobileSession>,
    pub timeline: TimelineResponse,
    pub albums: Vec<Album>,
    pub people: Vec<PersonCluster>,
    pub places: Vec<PlaceCluster>,
    pub events: Vec<EventCluster>,
    pub jobs: Vec<JobRecord>,
    pub vault_status: VaultStatus,
    pub devices: Vec<DeviceIdentity>,
    pub sync_network: SyncNetworkStatus,
    pub capabilities: MobileWorkspaceCapabilities,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MobileStorageProfileUpdateRequest {
    pub storage_profile: DeviceStorageProfile,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MobileReplicaChunkDescriptor {
    pub chunk_id: Uuid,
    pub chunk_index: u32,
    pub encrypted_hash: String,
    pub encrypted_bytes: u64,
    pub plaintext_bytes: u64,
    pub proof_challenge: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MobileReplicaAssignment {
    pub transfer_id: Uuid,
    pub vault_id: Uuid,
    pub blob_id: Uuid,
    pub asset_id: Uuid,
    pub encrypted_hash: String,
    pub bytes_total: u64,
    pub chunks: Vec<MobileReplicaChunkDescriptor>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MobileStoragePlan {
    pub generated_at: DateTime<Utc>,
    pub device: DeviceIdentity,
    pub assignments: Vec<MobileReplicaAssignment>,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MobileReplicaChunkReport {
    pub chunk_index: u32,
    pub encrypted_hash: String,
    pub encrypted_bytes: u64,
    pub proof: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MobileReplicaReportRequest {
    pub transfer_id: Uuid,
    #[serde(default)]
    pub chunks: Vec<MobileReplicaChunkReport>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MobileReplicaReport {
    pub blob_id: Uuid,
    pub device_id: Uuid,
    pub health: ReplicaHealth,
    pub bytes_present: u64,
    pub verified_at: Option<DateTime<Utc>>,
    pub transfer_id: Uuid,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MobileReplicaRestoreResult {
    pub blob_id: Uuid,
    pub chunk_index: u32,
    pub encrypted_hash: String,
    pub encrypted_bytes: u64,
    pub restored_local_chunk: bool,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ImportCandidate {
    pub id: Uuid,
    pub session_id: Uuid,
    pub source_path: String,
    pub original_filename: String,
    pub media_kind: MediaKind,
    pub mime_type: String,
    pub bytes: u64,
    pub captured_at: Option<DateTime<Utc>>,
    pub place_hint: Option<String>,
    pub content_hash: String,
    pub duplicate_asset_id: Option<Uuid>,
    pub selected: bool,
    pub import_mode: ImportMode,
    pub destination_path: Option<String>,
    pub sidecar_paths: Vec<String>,
    pub safety_status: String,
    #[serde(default)]
    pub organization: FileOrganizationHints,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ImportSession {
    pub id: Uuid,
    pub source_kind: ImportSourceKind,
    pub source_path: String,
    pub import_mode: ImportMode,
    pub add_as_watch_folder: bool,
    pub status: ImportSessionStatus,
    pub created_at: DateTime<Utc>,
    pub completed_at: Option<DateTime<Utc>>,
    pub place_hint: Option<String>,
    pub candidates: Vec<ImportCandidate>,
    pub imported_asset_ids: Vec<Uuid>,
    pub duplicate_asset_ids: Vec<Uuid>,
    pub moved_asset_ids: Vec<Uuid>,
    pub skipped_duplicate_ids: Vec<Uuid>,
    pub failed_candidate_ids: Vec<Uuid>,
    pub sidecars_moved: usize,
    pub unsupported_file_paths: Vec<String>,
    #[serde(default)]
    pub selected_candidate_count: usize,
    #[serde(default)]
    pub selected_bytes: u64,
    #[serde(default)]
    pub duplicate_count: usize,
    #[serde(default)]
    pub unsupported_count: usize,
    #[serde(default)]
    pub sidecar_count: usize,
    #[serde(default)]
    pub destination_root: Option<String>,
    #[serde(default)]
    pub requires_move_confirmation: bool,
    #[serde(default)]
    pub source_contains_managed_library: bool,
    #[serde(default)]
    pub selected_outside_source_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DuplicateReviewEntry {
    pub asset_id: Uuid,
    pub media_kind: MediaKind,
    pub original_bytes: u64,
    pub duplicate_candidates: usize,
    pub protected_bytes: u64,
    pub first_seen_at: DateTime<Utc>,
    pub last_seen_at: DateTime<Utc>,
    pub import_session_ids: Vec<Uuid>,
    pub source_kinds: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DuplicateReviewSummary {
    pub generated_at: DateTime<Utc>,
    pub duplicate_assets: usize,
    pub duplicate_candidates: usize,
    pub protected_bytes: u64,
    pub sessions_with_duplicates: usize,
    pub entries: Vec<DuplicateReviewEntry>,
    pub privacy_detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SearchQuery {
    pub text: Option<String>,
    pub people: Option<String>,
    pub places: Option<String>,
    #[serde(default)]
    pub events: Option<String>,
    #[serde(default)]
    pub workspace: Option<String>,
    #[serde(default)]
    pub client: Option<String>,
    #[serde(default)]
    pub project: Option<String>,
    #[serde(default)]
    pub topic: Option<String>,
    #[serde(default)]
    pub source_folder: Option<String>,
    #[serde(default)]
    pub device: Option<String>,
    #[serde(default)]
    pub media_kind: Option<String>,
    #[serde(default)]
    pub tags: Option<String>,
    #[serde(default)]
    pub favorite: Option<bool>,
    pub from_date: Option<String>,
    pub to_date: Option<String>,
    pub include_archived: bool,
    pub limit: Option<usize>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct UpdateAssetFlagsRequest {
    #[serde(default)]
    pub favorite: Option<bool>,
    #[serde(default)]
    pub archived: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct UpdateAssetsFlagsRequest {
    #[serde(default)]
    pub asset_ids: Vec<Uuid>,
    #[serde(default)]
    pub favorite: Option<bool>,
    #[serde(default)]
    pub archived: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct UpdateAssetTagsRequest {
    #[serde(default)]
    pub tags: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct JobRecord {
    pub id: Uuid,
    pub kind: JobKind,
    pub status: JobStatus,
    pub progress: u8,
    pub queued_at: DateTime<Utc>,
    pub started_at: Option<DateTime<Utc>>,
    pub completed_at: Option<DateTime<Utc>>,
    pub detail: Option<String>,
    #[serde(default)]
    pub cancel_requested: bool,
    #[serde(default)]
    pub retry_of_job_id: Option<Uuid>,
    #[serde(default = "default_job_attempt")]
    pub attempt: u32,
}

fn default_job_attempt() -> u32 {
    1
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct IndexJob {
    #[serde(flatten)]
    pub job: JobRecord,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct JobLog {
    pub id: Uuid,
    pub job_id: Uuid,
    pub level: String,
    pub message: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SchemaMigration {
    pub version: i64,
    pub name: String,
    pub applied_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FaceDetectionRecord {
    pub id: Uuid,
    pub asset_id: Uuid,
    pub bounding_box: BoundingBox,
    #[serde(flatten)]
    pub derived: ModelProvenance,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct OcrBlock {
    pub id: Uuid,
    pub asset_id: Uuid,
    pub text: String,
    pub bounding_box: Option<BoundingBox>,
    #[serde(flatten)]
    pub derived: ModelProvenance,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SceneTag {
    pub id: Uuid,
    pub asset_id: Uuid,
    pub label: String,
    pub confidence: f32,
    #[serde(flatten)]
    pub derived: ModelProvenance,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct EmbeddingRecord {
    pub id: Uuid,
    pub asset_id: Uuid,
    pub task: ModelTask,
    pub vector_path: String,
    #[serde(flatten)]
    pub derived: ModelProvenance,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SearchIndexStatus {
    pub filename_ready: bool,
    pub metadata_ready: bool,
    pub ocr_ready: bool,
    #[serde(default)]
    pub ocr_text_block_count: usize,
    #[serde(default)]
    pub ocr_indexed_asset_count: usize,
    #[serde(default)]
    pub ocr_total_photo_count: usize,
    #[serde(default)]
    pub ocr_remaining_photo_count: usize,
    pub scene_ready: bool,
    pub semantic_ready: bool,
    pub updated_at: DateTime<Utc>,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TimelineBucket {
    pub label: String,
    pub asset_ids: Vec<Uuid>,
    pub assets: Vec<Asset>,
    pub total_assets: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TimelineResponse {
    pub buckets: Vec<TimelineBucket>,
    #[serde(default)]
    pub next_cursor: Option<String>,
    #[serde(default)]
    pub total_assets: usize,
    #[serde(default)]
    pub returned_assets: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SearchResponse {
    pub query: SearchQuery,
    pub assets: Vec<Asset>,
    pub people: Vec<PersonCluster>,
    pub places: Vec<PlaceCluster>,
    pub events: Vec<EventCluster>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LibraryStatusResponse {
    pub settings: Option<LibrarySettings>,
    pub watch_folders: Vec<WatchFolder>,
    pub is_initialized: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct RebuildRequest {
    #[serde(default)]
    pub force: Option<bool>,
    #[serde(default)]
    pub limit: Option<usize>,
    #[serde(default)]
    pub asset_ids: Option<Vec<Uuid>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ModelArtifact {
    pub id: String,
    pub name: String,
    pub version: String,
    pub task: ModelTask,
    pub license: Option<String>,
    pub source_url: Option<String>,
    pub expected_sha256: Option<String>,
    pub installed_path: Option<String>,
    pub installed_sha256: Option<String>,
    pub install_status: ModelInstallStatus,
    pub review_notes: String,
    pub approved_for_personal_family_use: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ModelRuntimeDependency {
    pub name: String,
    pub available: bool,
    pub version: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ModelRuntimeStatus {
    pub ok: bool,
    pub runtime: String,
    pub sidecar_path: Option<String>,
    pub python_executable: String,
    pub python_version: Option<String>,
    pub offline_ready: bool,
    pub dependencies: Vec<ModelRuntimeDependency>,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ModelInstallRequest {
    pub id: String,
    pub confirmed: bool,
    #[serde(default)]
    pub source_url: Option<String>,
    #[serde(default)]
    pub expected_sha256: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ModelImportRequest {
    pub id: String,
    pub local_path: String,
    pub expected_sha256: Option<String>,
    pub confirmed: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PrivacyStatus {
    pub network_policy: NetworkPolicy,
    pub daemon_bind_address: String,
    pub loopback_only: bool,
    pub developer_mode: bool,
    pub remote_mobile_access_enabled: bool,
    pub photo_processing_network_allowed: bool,
    pub model_download_requires_confirmation: bool,
    pub telemetry_enabled: bool,
    pub analytics_enabled: bool,
    pub cloud_ai_enabled: bool,
    pub installed_models: Vec<ModelArtifact>,
    pub local_only_disclosure: String,
    pub encryption: EncryptionStatus,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum EntitlementTier {
    PersonalCore,
    FamilyRemote,
    PowerWorkspace,
    Business,
}

impl EntitlementTier {
    pub fn default_limits(self) -> EntitlementLimits {
        match self {
            EntitlementTier::PersonalCore => EntitlementLimits {
                device_limit: 3,
                member_limit: 1,
                workspace_limit: 1,
                monthly_ocr_limit: 1_000,
                relay_priority: EntitlementRelayPriority::None,
                advanced_admin_controls: false,
            },
            EntitlementTier::FamilyRemote => EntitlementLimits {
                device_limit: 8,
                member_limit: 6,
                workspace_limit: 2,
                monthly_ocr_limit: 5_000,
                relay_priority: EntitlementRelayPriority::Standard,
                advanced_admin_controls: false,
            },
            EntitlementTier::PowerWorkspace => EntitlementLimits {
                device_limit: 20,
                member_limit: 12,
                workspace_limit: 5,
                monthly_ocr_limit: 20_000,
                relay_priority: EntitlementRelayPriority::Priority,
                advanced_admin_controls: true,
            },
            EntitlementTier::Business => EntitlementLimits {
                device_limit: 100,
                member_limit: 100,
                workspace_limit: 25,
                monthly_ocr_limit: 100_000,
                relay_priority: EntitlementRelayPriority::Priority,
                advanced_admin_controls: true,
            },
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum EntitlementRelayPriority {
    None,
    Standard,
    Priority,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum EntitlementCacheStatus {
    Active,
    PastDue,
    Canceled,
    Expired,
    Unavailable,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum EntitlementEffectiveStatus {
    Active,
    OfflineGrace,
    Expired,
    Unavailable,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EntitlementLimits {
    pub device_limit: u32,
    pub member_limit: u32,
    pub workspace_limit: u32,
    pub monthly_ocr_limit: u32,
    pub relay_priority: EntitlementRelayPriority,
    pub advanced_admin_controls: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct EntitlementCache {
    pub tier: EntitlementTier,
    pub status: EntitlementCacheStatus,
    pub account_id_hash: Option<String>,
    pub plan_code: Option<String>,
    pub limits: EntitlementLimits,
    pub checked_at: DateTime<Utc>,
    pub expires_at: Option<DateTime<Utc>>,
    pub offline_grace_expires_at: Option<DateTime<Utc>>,
    pub source: String,
    pub detail: String,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct EntitlementStatusResponse {
    pub tier: EntitlementTier,
    pub effective_status: EntitlementEffectiveStatus,
    pub limits: EntitlementLimits,
    pub cache: Option<EntitlementCache>,
    pub offline_grace_active: bool,
    pub paid_features_available: bool,
    pub safe_local_access_allowed: bool,
    pub content_exposure_prevented: bool,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct UpdateEntitlementCacheRequest {
    pub tier: EntitlementTier,
    pub status: EntitlementCacheStatus,
    #[serde(default)]
    pub account_id_hash: Option<String>,
    #[serde(default)]
    pub plan_code: Option<String>,
    #[serde(default)]
    pub limits: Option<EntitlementLimits>,
    #[serde(default)]
    pub checked_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub expires_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub offline_grace_expires_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub source: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PlatformReleaseSurface {
    LinuxDesktop,
    WindowsDesktop,
    MacosDesktop,
    AndroidPlayStore,
    IosAppStore,
    WebBrowser,
    LocalWebUi,
    DirectDesktopDistribution,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PlatformReleaseReadinessStatus {
    Planned,
    InProgress,
    Blocked,
    Ready,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PlatformReleaseEvidenceStatus {
    Missing,
    Partial,
    Passed,
    NotApplicable,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PlatformReleaseEvidence {
    pub key: String,
    pub label: String,
    pub status: PlatformReleaseEvidenceStatus,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PlatformReleaseSurfaceReadiness {
    pub surface: PlatformReleaseSurface,
    pub label: String,
    pub status: PlatformReleaseReadinessStatus,
    pub distribution: String,
    pub evidence: Vec<PlatformReleaseEvidence>,
    pub blockers: Vec<String>,
    pub next_step: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PlatformReleaseReadinessResponse {
    pub generated_at: DateTime<Utc>,
    pub overall_status: PlatformReleaseReadinessStatus,
    pub surfaces: Vec<PlatformReleaseSurfaceReadiness>,
    pub required_surface_count: usize,
    pub ready_surface_count: usize,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct EncryptionStatus {
    pub database_encrypted: bool,
    pub derived_data_encrypted: bool,
    pub key_storage: Option<String>,
    pub sensitive_indexing_allowed: bool,
    pub warning: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct EncryptionActivationRequest {
    pub confirmed: bool,
    pub backup_root: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct EncryptionActivationResult {
    pub status: EncryptionStatus,
    pub backup_path: String,
    pub activated_at: DateTime<Utc>,
    pub row_counts_verified: bool,
    pub integrity_check: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ModelInstallAuditRecord {
    pub id: Uuid,
    pub model_id: String,
    pub action: String,
    pub source_url: Option<String>,
    pub expected_sha256: Option<String>,
    pub actual_sha256: Option<String>,
    pub status: String,
    pub message: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RenamePersonRequest {
    pub display_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CreateManualPersonRequest {
    pub display_name: String,
    #[serde(default)]
    pub asset_ids: Vec<Uuid>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct UpdatePersonAssetsRequest {
    pub asset_ids: Vec<Uuid>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CreateAlbumRequest {
    pub title: String,
    #[serde(default)]
    pub asset_ids: Vec<Uuid>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RenameAlbumRequest {
    pub title: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct UpdateAlbumAssetsRequest {
    #[serde(default)]
    pub asset_ids: Vec<Uuid>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CreateSmartFolderRequest {
    pub title: String,
    pub query: SearchQuery,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HidePersonRequest {
    #[serde(default = "default_true")]
    pub hidden: bool,
    pub reason: Option<String>,
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RejectPersonMatchRequest {
    pub face_template_id: Option<Uuid>,
    pub asset_id: Option<Uuid>,
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CorrectDateRequest {
    pub captured_at: DateTime<Utc>,
    pub timezone_offset_minutes: Option<i32>,
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CorrectPlaceRequest {
    pub label: String,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    pub hide_exact_gps: Option<bool>,
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BackupVerifyRequest {
    pub export_root: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BackupExportRequest {
    pub export_root: String,
    #[serde(default)]
    pub include_models: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BackupVerification {
    pub checked_at: DateTime<Utc>,
    pub database_path: String,
    pub library_root: String,
    pub database_sha256: Option<String>,
    pub assets_checked: usize,
    pub missing_asset_paths: Vec<String>,
    #[serde(default)]
    pub vault_chunks_checked: usize,
    #[serde(default)]
    pub missing_vault_chunk_paths: Vec<String>,
    pub model_files_checked: usize,
    pub missing_model_paths: Vec<String>,
    pub ok: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BackupExportResult {
    pub exported_at: DateTime<Utc>,
    pub export_root: String,
    pub manifest_path: String,
    pub database_copied_to: String,
    pub database_sha256: Option<String>,
    pub assets_checked: usize,
    pub missing_asset_paths: Vec<String>,
    #[serde(default)]
    pub media_files_copied: usize,
    #[serde(default)]
    pub vault_chunks_copied: usize,
    #[serde(default)]
    pub bytes_copied: u64,
    pub model_files_checked: usize,
    pub missing_model_paths: Vec<String>,
    pub ok: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SupportBundleExportRequest {
    pub export_root: String,
    #[serde(default = "default_support_bundle_include_release_readiness")]
    pub include_release_readiness: bool,
}

fn default_support_bundle_include_release_readiness() -> bool {
    true
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SupportBundleExportResult {
    pub exported_at: DateTime<Utc>,
    pub export_root: String,
    pub bundle_path: String,
    pub sections: Vec<String>,
    pub redacted_fields: Vec<String>,
    pub private_data_excluded: bool,
    pub ok: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BackupRestorePlanRequest {
    pub export_root: String,
    pub restore_root: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BackupRestorePlan {
    pub checked_at: DateTime<Utc>,
    pub export_root: String,
    pub restore_root: String,
    pub manifest_path: String,
    pub database_source_path: String,
    pub database_target_path: String,
    pub media_files_available: usize,
    pub vault_chunks_available: usize,
    pub missing_paths: Vec<String>,
    pub destination_conflicts: Vec<String>,
    pub requires_confirmation: bool,
    pub ok: bool,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BackupRestoreRunRequest {
    pub export_root: String,
    pub restore_root: String,
    pub confirmed: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BackupRestoreRunResult {
    pub restored_at: DateTime<Utc>,
    pub restore_root: String,
    pub database_restored_to: String,
    pub media_files_copied: usize,
    pub vault_chunks_copied: usize,
    pub bytes_copied: u64,
    pub ok: bool,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CreatePairingSessionRequest {
    pub device_name: String,
    pub platform: String,
    pub vault_id: Option<Uuid>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MobilePairRequest {
    pub pairing_token: String,
    pub device_name: String,
    pub platform: String,
    pub vault_id: Option<Uuid>,
    #[serde(default)]
    pub storage_profile: Option<DeviceStorageProfile>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MobileUploadRequest {
    pub original_filename: String,
    pub media_kind: MediaKind,
    pub mime_type: String,
    pub bytes: u64,
    pub content_hash: Option<String>,
    pub captured_at: Option<DateTime<Utc>>,
    pub place_hint: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CreateFileFolderRequest {
    pub vault_id: Option<Uuid>,
    pub parent_id: Option<Uuid>,
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RenameFileEntryRequest {
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MoveFileEntryRequest {
    pub parent_id: Option<Uuid>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CreateVaultRequest {
    pub id: Option<Uuid>,
    pub name: String,
    pub storage_policy: Option<StoragePolicy>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct UpdateVaultStoragePolicyRequest {
    pub policy: StoragePolicy,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CreateDeviceRequest {
    pub display_name: String,
    pub platform: String,
    pub public_key: Option<String>,
    pub trust_level: Option<DeviceTrustLevel>,
    pub role: Option<DeviceRole>,
    pub storage_profile: Option<DeviceStorageProfile>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EnrollDeviceRequest {
    pub display_name: String,
    pub platform: String,
    pub public_key: Option<String>,
    pub vault_id: Option<Uuid>,
    pub role: Option<DeviceRole>,
    pub trust_level: Option<DeviceTrustLevel>,
    pub storage_profile: Option<DeviceStorageProfile>,
    pub endpoint: Option<PeerEndpointDescriptor>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct RevokeDeviceRequest {
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct RunSyncRequest {
    pub vault_id: Option<Uuid>,
    #[serde(default)]
    pub dry_run: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct UpdateLibrarySettingsRequest {
    pub library_root: String,
    pub default_import_mode: ImportMode,
    #[serde(default)]
    pub original_storage_policy: Option<OriginalStoragePolicy>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CreateWatchFolderRequest {
    pub path: String,
    pub recursive: bool,
    pub import_mode: Option<ImportMode>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ScanImportSourceRequest {
    pub source_path: String,
    pub source_kind: ImportSourceKind,
    pub recursive: bool,
    pub import_mode: Option<ImportMode>,
    pub add_as_watch_folder: bool,
    pub place_hint: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CommitImportSessionRequest {
    pub session_id: Uuid,
    #[serde(alias = "candidate_ids")]
    pub selected_candidate_ids: Vec<Uuid>,
    pub import_mode: Option<ImportMode>,
    pub add_as_watch_folder: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ImportAssetRequest {
    pub source_path: String,
    pub original_filename: String,
    pub media_kind: MediaKind,
    pub mime_type: String,
    pub bytes: u64,
    pub content_hash: Option<String>,
    pub captured_at: Option<DateTime<Utc>>,
    pub place_hint: Option<String>,
    pub import_mode: Option<ImportMode>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ImportAssetResponse {
    pub asset: Asset,
    pub job: JobRecord,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MergePersonRequest {
    pub source_person_ids: Vec<Uuid>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SplitPersonRequest {
    pub new_display_name: Option<String>,
    pub face_template_ids: Vec<Uuid>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TitleEventRequest {
    pub title: String,
}
