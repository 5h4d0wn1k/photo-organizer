use std::{
    fs,
    net::SocketAddr,
    path::{Path, PathBuf},
    str::FromStr,
    sync::Arc,
    time::Duration,
};

use cap_std::{
    ambient_authority,
    fs::{Dir, Metadata as CapMetadata, OpenOptions as CapOpenOptions},
};
use chrono::Utc;
use iroh::{
    Endpoint, EndpointAddr, EndpointId, RelayMode, RelayUrl, SecretKey, TransportAddr,
    endpoint::{Connection, presets},
    protocol::{AcceptError, ProtocolHandler, Router},
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    sync::{Mutex, RwLock},
};
use uuid::Uuid;

use crate::{
    config::AppConfig,
    domain::{
        BlobChunk, BlobRecord, BlobReplica, DeviceIdentity, DeviceRole, DeviceTrustLevel,
        LocalEndpointPayload, PeerEndpointDescriptor, RelayEndpoint, ReplicaHealth, SyncTransfer,
        SyncTransferStatus,
    },
    service::{LibraryState, effective_library_root, local_device_id},
    storage::{self, StorageBootstrapReport},
};

const ALPN: &[u8] = b"private-gallery/vault-sync/1";
const PROTOCOL_VERSION: u16 = 1;
const MAX_METADATA_FRAME_BYTES: usize = 4 * 1024 * 1024;
const MAX_CHUNK_FRAME_BYTES: usize = 128 * 1024 * 1024;
static RESERVED_RECEIVE_BYTES: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
static RECEIVE_SLOTS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(2);

#[derive(Debug, Error)]
pub enum SyncTransportError {
    #[error("sync transport is not started")]
    NotStarted,
    #[error("sync transport request is invalid: {0}")]
    Invalid(String),
    #[error("sync transport filesystem operation failed: {0}")]
    Io(String),
    #[error("sync transport failed: {0}")]
    Transport(String),
    #[error("sync transport storage update failed: {0}")]
    Storage(String),
}

#[derive(Debug, Clone)]
pub(crate) struct RuntimeStatus {
    pub started: bool,
    pub local_node_id: Option<String>,
    pub direct_addresses: Vec<String>,
    pub relay_urls: Vec<String>,
    pub detail: String,
}

impl RuntimeStatus {
    pub fn stopped() -> Self {
        Self {
            started: false,
            local_node_id: None,
            direct_addresses: Vec::new(),
            relay_urls: Vec::new(),
            detail: "P2P vault sync is stopped.".to_string(),
        }
    }
}

#[derive(Debug, Clone)]
pub(crate) struct OutboundBlobTransfer {
    pub direction: TransferDirection,
    pub transfer: SyncTransfer,
    pub blob: BlobRecord,
    pub chunks: Vec<BlobChunk>,
    pub target: PeerEndpointDescriptor,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TransferDirection {
    Push,
    Pull,
}

pub struct SyncRuntime {
    config: AppConfig,
    storage: StorageBootstrapReport,
    state: Arc<RwLock<LibraryState>>,
    active: Mutex<Option<ActiveRuntime>>,
}

struct ActiveRuntime {
    router: Router,
    payload: LocalEndpointPayload,
}

#[derive(Debug, Clone)]
struct VaultSyncHandler {
    config: AppConfig,
    storage: StorageBootstrapReport,
    state: Arc<RwLock<LibraryState>>,
    local_node_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct TransferEnvelope {
    protocol_version: u16,
    transfer_id: Uuid,
    from_device_id: Uuid,
    to_device_id: Uuid,
    blob: BlobRecord,
    chunks: Vec<BlobChunk>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PullRequest {
    protocol_version: u16,
    transfer_id: Uuid,
    from_device_id: Uuid,
    to_device_id: Uuid,
    vault_id: Uuid,
    blob_id: Uuid,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum WireRequest {
    Push { envelope: TransferEnvelope },
    Pull { request: PullRequest },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct TransferResponse {
    ok: bool,
    bytes_received: u64,
    detail: String,
}

impl SyncRuntime {
    pub(crate) fn new(
        config: AppConfig,
        storage: StorageBootstrapReport,
        state: Arc<RwLock<LibraryState>>,
    ) -> Self {
        Self {
            config,
            storage,
            state,
            active: Mutex::new(None),
        }
    }

    pub(crate) async fn start(&self) -> Result<LocalEndpointPayload, SyncTransportError> {
        let mut active = self.active.lock().await;
        if let Some(active) = active.as_ref() {
            return Ok(active.payload.clone());
        }

        let secret_key = load_or_create_secret_key(&self.config)?;
        let local_node_id = secret_key.public().to_string();
        let relay_mode = relay_mode_for_config(&self.config);
        let relay_enabled = !matches!(relay_mode, RelayMode::Disabled);
        let builder = Endpoint::builder(presets::N0)
            .secret_key(secret_key)
            .alpns(vec![ALPN.to_vec()])
            .relay_mode(relay_mode);
        #[cfg(test)]
        let builder = builder
            .clear_ip_transports()
            .bind_addr("127.0.0.1:0")
            .map_err(|err| SyncTransportError::Transport(err.to_string()))?;
        let endpoint = builder
            .bind()
            .await
            .map_err(|err| SyncTransportError::Transport(err.to_string()))?;

        if relay_enabled {
            let _ = tokio::time::timeout(Duration::from_secs(2), endpoint.online()).await;
        }

        let payload = self
            .refresh_local_endpoint_payload(&endpoint, local_node_id.clone())
            .await?;
        let handler = VaultSyncHandler {
            config: self.config.clone(),
            storage: self.storage.clone(),
            state: Arc::clone(&self.state),
            local_node_id,
        };
        let router = Router::builder(endpoint).accept(ALPN, handler).spawn();
        *active = Some(ActiveRuntime {
            router,
            payload: payload.clone(),
        });
        Ok(payload)
    }

    pub(crate) async fn stop(&self) -> Result<(), SyncTransportError> {
        let active = self.active.lock().await.take();
        if let Some(active) = active {
            active
                .router
                .shutdown()
                .await
                .map_err(|err| SyncTransportError::Transport(err.to_string()))?;
        }
        Ok(())
    }

    pub(crate) async fn status(&self) -> RuntimeStatus {
        let active = self.active.lock().await;
        let Some(active) = active.as_ref() else {
            return RuntimeStatus::stopped();
        };
        RuntimeStatus {
            started: !active.router.is_shutdown(),
            local_node_id: Some(active.payload.descriptor.node_id.clone()),
            direct_addresses: active.payload.descriptor.direct_addresses.clone(),
            relay_urls: active.payload.descriptor.relay_urls.clone(),
            detail: active.payload.detail.clone(),
        }
    }

    pub(crate) async fn local_endpoint_payload(
        &self,
    ) -> Result<LocalEndpointPayload, SyncTransportError> {
        self.start().await
    }

    pub(crate) async fn send_blob(
        &self,
        job: &OutboundBlobTransfer,
        library_root: &Path,
    ) -> Result<u64, SyncTransportError> {
        let active = self.active.lock().await;
        let Some(active) = active.as_ref() else {
            return Err(SyncTransportError::NotStarted);
        };
        let endpoint_addr = endpoint_addr_from_descriptor(&job.target)?;
        let conn = active
            .router
            .endpoint()
            .connect(endpoint_addr, ALPN)
            .await
            .map_err(|err| SyncTransportError::Transport(err.to_string()))?;
        let (mut send, mut recv) = conn
            .open_bi()
            .await
            .map_err(|err| SyncTransportError::Transport(err.to_string()))?;
        let from_device_id = job.transfer.from_device_id.ok_or_else(|| {
            SyncTransportError::Invalid("outbound transfer has no source device".to_string())
        })?;
        let envelope = TransferEnvelope {
            protocol_version: PROTOCOL_VERSION,
            transfer_id: job.transfer.id,
            from_device_id,
            to_device_id: job.transfer.to_device_id,
            blob: job.blob.clone(),
            chunks: job.chunks.clone(),
        };
        let metadata = serde_json::to_vec(&WireRequest::Push { envelope })
            .map_err(|err| SyncTransportError::Invalid(err.to_string()))?;
        write_frame(&mut send, &metadata).await?;

        let mut bytes_sent = 0_u64;
        for chunk in &job.chunks {
            let local_path = chunk.local_path.as_deref().ok_or_else(|| {
                SyncTransportError::Invalid(format!("chunk {} has no local path", chunk.id))
            })?;
            let path = library_root.join(safe_relative_path(local_path).ok_or_else(|| {
                SyncTransportError::Invalid(format!("chunk {} has an unsafe local path", chunk.id))
            })?);
            let ciphertext = fs::read(&path).map_err(io_error)?;
            let encrypted_hash = sha256_hex(&ciphertext);
            if encrypted_hash != chunk.encrypted_hash {
                return Err(SyncTransportError::Invalid(format!(
                    "encrypted hash mismatch before sending chunk {}",
                    chunk.id
                )));
            }
            write_frame(&mut send, &ciphertext).await?;
            bytes_sent = bytes_sent.saturating_add(chunk.bytes);
        }
        send.finish()
            .map_err(|err| SyncTransportError::Transport(err.to_string()))?;

        let response_bytes = read_frame(&mut recv, MAX_METADATA_FRAME_BYTES).await?;
        let response: TransferResponse = serde_json::from_slice(&response_bytes)
            .map_err(|err| SyncTransportError::Invalid(err.to_string()))?;
        conn.close(0_u32.into(), b"done");
        if response.ok {
            Ok(response.bytes_received.max(bytes_sent))
        } else {
            Err(SyncTransportError::Transport(response.detail))
        }
    }

    pub(crate) async fn request_blob(
        &self,
        job: &OutboundBlobTransfer,
        library_root: &Path,
    ) -> Result<u64, SyncTransportError> {
        let active = self.active.lock().await;
        let Some(active) = active.as_ref() else {
            return Err(SyncTransportError::NotStarted);
        };
        let from_device_id = job.transfer.from_device_id.ok_or_else(|| {
            SyncTransportError::Invalid("pull transfer has no source device".to_string())
        })?;
        let endpoint_addr = endpoint_addr_from_descriptor(&job.target)?;
        let conn = active
            .router
            .endpoint()
            .connect(endpoint_addr, ALPN)
            .await
            .map_err(|err| SyncTransportError::Transport(err.to_string()))?;
        let (mut send, mut recv) = conn
            .open_bi()
            .await
            .map_err(|err| SyncTransportError::Transport(err.to_string()))?;
        let request = PullRequest {
            protocol_version: PROTOCOL_VERSION,
            transfer_id: job.transfer.id,
            from_device_id,
            to_device_id: job.transfer.to_device_id,
            vault_id: job.blob.vault_id,
            blob_id: job.blob.id,
        };
        let metadata = serde_json::to_vec(&WireRequest::Pull { request })
            .map_err(|err| SyncTransportError::Invalid(err.to_string()))?;
        write_frame(&mut send, &metadata).await?;
        send.finish()
            .map_err(|err| SyncTransportError::Transport(err.to_string()))?;

        let response_metadata = read_frame(&mut recv, MAX_METADATA_FRAME_BYTES).await?;
        let envelope: TransferEnvelope = serde_json::from_slice(&response_metadata)
            .map_err(|err| SyncTransportError::Invalid(err.to_string()))?;
        let local_node_id = active.payload.descriptor.node_id.clone();
        let bytes_received = receive_envelope(
            &self.storage,
            &self.state,
            &mut recv,
            &envelope,
            &job.target.node_id,
            &local_node_id,
            library_root,
        )
        .await?;
        conn.close(0_u32.into(), b"done");
        Ok(bytes_received)
    }

    async fn refresh_local_endpoint_payload(
        &self,
        endpoint: &Endpoint,
        local_node_id: String,
    ) -> Result<LocalEndpointPayload, SyncTransportError> {
        let addr = endpoint.addr();
        let direct_addresses = addr.ip_addrs().map(ToString::to_string).collect::<Vec<_>>();
        let relay_urls = addr
            .relay_urls()
            .map(ToString::to_string)
            .collect::<Vec<_>>();
        let now = Utc::now();
        let expires_at = now + chrono::Duration::minutes(10);
        let mut state = self.state.write().await;
        let local_device_id = local_device_id(&state).ok_or_else(|| {
            SyncTransportError::Invalid("local device is not initialized".to_string())
        })?;
        let local_device = state
            .devices
            .iter_mut()
            .find(|device| device.id == local_device_id)
            .ok_or_else(|| SyncTransportError::Invalid("local device is missing".to_string()))?;
        if local_device.public_key != local_node_id {
            if public_key_is_pending(&local_device.public_key) {
                local_device.public_key = local_node_id.clone();
            } else {
                return Err(SyncTransportError::Invalid(
                    "stored Iroh endpoint key does not match the enrolled local device identity"
                        .to_string(),
                ));
            }
        }
        local_device.last_seen_at = Some(now);
        let descriptor = PeerEndpointDescriptor {
            device_id: Some(local_device_id),
            device_name: local_device.display_name.clone(),
            platform: local_device.platform.clone(),
            node_id: local_node_id.clone(),
            relay_urls: relay_urls.clone(),
            direct_addresses: direct_addresses.clone(),
            expires_at,
            trust_level: local_device.trust_level,
            role: default_role_for_trust(local_device.trust_level),
        };
        upsert_relay_endpoint(
            &mut state,
            local_device_id,
            local_node_id,
            relay_urls.first().cloned(),
            direct_addresses,
            expires_at,
        );
        storage::save_state(&self.storage, &state.to_persisted())
            .map_err(|err| SyncTransportError::Storage(err.to_string()))?;
        let pairing_payload = serde_json::to_string_pretty(&descriptor)
            .map_err(|err| SyncTransportError::Invalid(err.to_string()))?;
        Ok(LocalEndpointPayload {
            descriptor,
            pairing_payload,
            detail:
                "P2P vault sync is listening with Iroh QUIC; direct paths are tried before relay fallback."
                    .to_string(),
        })
    }
}

impl ProtocolHandler for VaultSyncHandler {
    async fn accept(&self, connection: Connection) -> Result<(), AcceptError> {
        let remote_node_id = connection.remote_id().to_string();
        self.accept_inner(&connection, remote_node_id)
            .await
            .map_err(AcceptError::from_err)?;
        connection.closed().await;
        Ok(())
    }
}

impl VaultSyncHandler {
    async fn accept_inner(
        &self,
        connection: &Connection,
        remote_node_id: String,
    ) -> Result<(), SyncTransportError> {
        let (mut send, mut recv) = connection
            .accept_bi()
            .await
            .map_err(|err| SyncTransportError::Transport(err.to_string()))?;
        let metadata = read_frame(&mut recv, MAX_METADATA_FRAME_BYTES).await?;
        let library_root = {
            let state = self.state.read().await;
            PathBuf::from(effective_library_root(&state, &self.config))
        };
        let request = serde_json::from_slice::<WireRequest>(&metadata)
            .or_else(|_| {
                serde_json::from_slice::<TransferEnvelope>(&metadata)
                    .map(|envelope| WireRequest::Push { envelope })
            })
            .map_err(|err| SyncTransportError::Invalid(err.to_string()))?;
        match request {
            WireRequest::Push { envelope } => {
                let response = match self
                    .receive_envelope(&mut recv, &envelope, &remote_node_id, &library_root)
                    .await
                {
                    Ok(bytes_received) => TransferResponse {
                        ok: true,
                        bytes_received,
                        detail: "transfer committed".to_string(),
                    },
                    Err(err) => TransferResponse {
                        ok: false,
                        bytes_received: 0,
                        detail: err.to_string(),
                    },
                };
                let response = serde_json::to_vec(&response)
                    .map_err(|err| SyncTransportError::Invalid(err.to_string()))?;
                write_frame(&mut send, &response).await?;
                send.finish()
                    .map_err(|err| SyncTransportError::Transport(err.to_string()))?;
            }
            WireRequest::Pull { request } => {
                self.send_requested_blob(&mut send, request, &remote_node_id, &library_root)
                    .await?;
                send.finish()
                    .map_err(|err| SyncTransportError::Transport(err.to_string()))?;
            }
        }
        Ok(())
    }

    async fn send_requested_blob<W>(
        &self,
        send: &mut W,
        request: PullRequest,
        remote_node_id: &str,
        library_root: &Path,
    ) -> Result<u64, SyncTransportError>
    where
        W: AsyncWrite + Unpin,
    {
        let (envelope, chunks) = {
            let state = self.state.read().await;
            build_pull_envelope(
                &state,
                request,
                remote_node_id,
                &self.local_node_id,
                library_root,
            )?
        };
        let metadata = serde_json::to_vec(&envelope)
            .map_err(|err| SyncTransportError::Invalid(err.to_string()))?;
        write_frame(send, &metadata).await?;

        let mut bytes_sent = 0_u64;
        for chunk in chunks {
            let local_path = chunk.local_path.as_deref().ok_or_else(|| {
                SyncTransportError::Invalid(format!("chunk {} has no local path", chunk.id))
            })?;
            let path = library_root.join(safe_relative_path(local_path).ok_or_else(|| {
                SyncTransportError::Invalid(format!("chunk {} has an unsafe local path", chunk.id))
            })?);
            let ciphertext = fs::read(&path).map_err(io_error)?;
            let encrypted_hash = sha256_hex(&ciphertext);
            if encrypted_hash != chunk.encrypted_hash {
                return Err(SyncTransportError::Invalid(format!(
                    "encrypted hash mismatch before serving chunk {}",
                    chunk.id
                )));
            }
            write_frame(send, &ciphertext).await?;
            bytes_sent = bytes_sent.saturating_add(chunk.bytes);
        }
        Ok(bytes_sent)
    }

    async fn receive_envelope<R>(
        &self,
        recv: &mut R,
        envelope: &TransferEnvelope,
        remote_node_id: &str,
        library_root: &Path,
    ) -> Result<u64, SyncTransportError>
    where
        R: AsyncRead + Unpin,
    {
        receive_envelope(
            &self.storage,
            &self.state,
            recv,
            envelope,
            remote_node_id,
            &self.local_node_id,
            library_root,
        )
        .await
    }
}

impl TransferEnvelope {
    fn transfer_blob_id(&self) -> Uuid {
        self.blob.id
    }
}

async fn receive_envelope<R>(
    storage_report: &StorageBootstrapReport,
    state_lock: &Arc<RwLock<LibraryState>>,
    recv: &mut R,
    envelope: &TransferEnvelope,
    remote_node_id: &str,
    local_node_id: &str,
    library_root: &Path,
) -> Result<u64, SyncTransportError>
where
    R: AsyncRead + Unpin,
{
    let _receive_slot = RECEIVE_SLOTS
        .acquire()
        .await
        .map_err(|error| SyncTransportError::Transport(error.to_string()))?;
    if envelope.protocol_version != PROTOCOL_VERSION {
        return Err(SyncTransportError::Invalid(format!(
            "unsupported sync protocol version {}",
            envelope.protocol_version
        )));
    }
    if envelope.blob.id != envelope.transfer_blob_id() {
        return Err(SyncTransportError::Invalid(
            "transfer envelope blob id mismatch".to_string(),
        ));
    }
    {
        let state = state_lock.read().await;
        validate_envelope_authorization(&state, envelope, remote_node_id, local_node_id)?;
        validate_incoming_manifest(&state, envelope)?;
    }

    let (root, canonical_root) = open_receive_root(library_root)?;
    let reservation = {
        let state = state_lock.read().await;
        reserve_receive_capacity(&canonical_root, &state, envelope)?
    };
    let (blob_dir, _directory_anchors) = open_or_create_blob_dir(
        &root,
        &canonical_root,
        envelope.blob.vault_id,
        envelope.blob.id,
    )?;
    cleanup_stale_incoming(&blob_dir)?;
    let created_at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let stage_name = format!(".incoming-{created_at}-{}", Uuid::new_v4());
    blob_dir.create_dir(&stage_name).map_err(io_error)?;
    let stage_dir = blob_dir.open_dir(&stage_name).map_err(io_error)?;
    let stage = IncomingStageGuard::new(stage_dir);
    let blob_path = canonical_root
        .join("vaults")
        .join(envelope.blob.vault_id.to_string())
        .join("blobs")
        .join(envelope.blob.id.to_string());
    let stage_path = blob_path.join(&stage_name);

    let mut received_chunks = Vec::with_capacity(envelope.chunks.len());
    let mut bytes_received = 0_u64;
    for chunk in &envelope.chunks {
        let ciphertext = read_frame(recv, MAX_CHUNK_FRAME_BYTES).await?;
        let encrypted_hash = sha256_hex(&ciphertext);
        if encrypted_hash != chunk.encrypted_hash {
            return Err(SyncTransportError::Invalid(format!(
                "encrypted hash mismatch for incoming chunk {}",
                chunk.id
            )));
        }
        if ciphertext.len() as u64 != chunk.encrypted_bytes {
            return Err(SyncTransportError::Invalid(format!(
                "incoming chunk {} byte count mismatch",
                chunk.id
            )));
        }
        let staged_name = chunk_filename(chunk.chunk_index);
        write_staged_chunk(stage.dir(), &staged_name, &ciphertext)?;
        let mut received = chunk.clone();
        let relative_path = incoming_chunk_path(&envelope.blob, chunk);
        received.local_path = Some(path_to_storage_string(&relative_path));
        received_chunks.push(received);
        bytes_received = bytes_received.saturating_add(chunk.bytes);
    }

    for chunk in &envelope.chunks {
        let name = chunk_filename(chunk.chunk_index);
        publish_staged_chunk(
            stage.dir(),
            &stage_path,
            &name,
            &blob_dir,
            &blob_path,
            &name,
            (&chunk.encrypted_hash, chunk.encrypted_bytes),
        )?;
    }
    sync_directory(&blob_path)?;

    let mut state = state_lock.write().await;
    validate_envelope_authorization(&state, envelope, remote_node_id, local_node_id)?;
    validate_incoming_manifest(&state, envelope)?;
    let previous_records = state.blob_records.clone();
    let previous_chunks = state.blob_chunks.clone();
    let previous_replicas = state.blob_replicas.clone();
    let previous_transfers = state.sync_transfers.clone();
    if let Err(error) = commit_received_blob(&mut state, envelope, received_chunks, bytes_received)
    {
        state.blob_records = previous_records;
        state.blob_chunks = previous_chunks;
        state.blob_replicas = previous_replicas;
        state.sync_transfers = previous_transfers;
        return Err(error);
    }
    if let Err(error) = storage::save_state(storage_report, &state.to_persisted()) {
        state.blob_records = previous_records;
        state.blob_chunks = previous_chunks;
        state.blob_replicas = previous_replicas;
        state.sync_transfers = previous_transfers;
        return Err(SyncTransportError::Storage(error.to_string()));
    }
    drop(reservation);
    Ok(bytes_received)
}

fn build_pull_envelope(
    state: &LibraryState,
    request: PullRequest,
    remote_node_id: &str,
    local_node_id: &str,
    library_root: &Path,
) -> Result<(TransferEnvelope, Vec<BlobChunk>), SyncTransportError> {
    validate_pull_authorization(state, &request, remote_node_id, local_node_id)?;
    let blob = state
        .blob_records
        .iter()
        .find(|blob| {
            blob.id == request.blob_id
                && blob.vault_id == request.vault_id
                && blob.tombstoned_at.is_none()
        })
        .cloned()
        .ok_or_else(|| {
            SyncTransportError::Invalid("requested blob is not available on this device".into())
        })?;
    let mut chunks = state
        .blob_chunks
        .iter()
        .filter(|chunk| chunk.blob_id == blob.id)
        .cloned()
        .collect::<Vec<_>>();
    chunks.sort_by_key(|chunk| chunk.chunk_index);
    if chunks.is_empty() {
        return Err(SyncTransportError::Invalid(
            "requested blob has no encrypted chunks".to_string(),
        ));
    }
    for chunk in &chunks {
        let local_path = chunk.local_path.as_deref().ok_or_else(|| {
            SyncTransportError::Invalid(format!("requested chunk {} has no local path", chunk.id))
        })?;
        let relative_path = safe_relative_path(local_path).ok_or_else(|| {
            SyncTransportError::Invalid(format!("requested chunk {} has an unsafe path", chunk.id))
        })?;
        if !library_root.join(relative_path).is_file() {
            return Err(SyncTransportError::Invalid(format!(
                "requested chunk {} is missing from local storage",
                chunk.id
            )));
        }
    }
    let envelope = TransferEnvelope {
        protocol_version: PROTOCOL_VERSION,
        transfer_id: request.transfer_id,
        from_device_id: request.from_device_id,
        to_device_id: request.to_device_id,
        blob,
        chunks: chunks.clone(),
    };
    Ok((envelope, chunks))
}

fn validate_envelope_authorization(
    state: &LibraryState,
    envelope: &TransferEnvelope,
    remote_node_id: &str,
    local_node_id: &str,
) -> Result<(), SyncTransportError> {
    let local_device = state
        .devices
        .iter()
        .find(|device| {
            device.id == envelope.to_device_id
                && device.revoked_at.is_none()
                && device.public_key == local_node_id
        })
        .ok_or_else(|| {
            SyncTransportError::Invalid("incoming transfer is not addressed to this device".into())
        })?;
    if !local_device.storage_profile.accepts_storage {
        return Err(SyncTransportError::Invalid(
            "this device is not configured to accept vault storage".to_string(),
        ));
    }
    let _from_device = state
        .devices
        .iter()
        .find(|device| {
            device.id == envelope.from_device_id
                && device.revoked_at.is_none()
                && device.public_key == remote_node_id
        })
        .ok_or_else(|| {
            SyncTransportError::Invalid(
                "incoming transfer source does not match the authenticated Iroh peer".into(),
            )
        })?;
    validate_active_vault_membership(state, envelope.blob.vault_id, envelope.from_device_id)?;
    validate_active_vault_membership(state, envelope.blob.vault_id, envelope.to_device_id)?;
    validate_transfer_state_if_present(
        state,
        envelope.transfer_id,
        envelope.blob.vault_id,
        envelope.blob.id,
        envelope.from_device_id,
        envelope.to_device_id,
    )?;
    if envelope
        .chunks
        .iter()
        .any(|chunk| chunk.blob_id != envelope.blob.id)
    {
        return Err(SyncTransportError::Invalid(
            "incoming transfer chunk does not belong to envelope blob".into(),
        ));
    }
    Ok(())
}

fn validate_pull_authorization(
    state: &LibraryState,
    request: &PullRequest,
    remote_node_id: &str,
    local_node_id: &str,
) -> Result<(), SyncTransportError> {
    if request.protocol_version != PROTOCOL_VERSION {
        return Err(SyncTransportError::Invalid(format!(
            "unsupported sync protocol version {}",
            request.protocol_version
        )));
    }
    state
        .devices
        .iter()
        .find(|device| {
            device.id == request.from_device_id
                && device.revoked_at.is_none()
                && device.public_key == local_node_id
        })
        .ok_or_else(|| {
            SyncTransportError::Invalid(
                "pull request is not addressed to this source device".into(),
            )
        })?;
    state
        .devices
        .iter()
        .find(|device| {
            device.id == request.to_device_id
                && device.revoked_at.is_none()
                && device.public_key == remote_node_id
        })
        .ok_or_else(|| {
            SyncTransportError::Invalid(
                "pull requester does not match the authenticated Iroh peer".into(),
            )
        })?;
    validate_active_vault_membership(state, request.vault_id, request.from_device_id)?;
    validate_active_vault_membership(state, request.vault_id, request.to_device_id)?;
    validate_transfer_state_if_present(
        state,
        request.transfer_id,
        request.vault_id,
        request.blob_id,
        request.from_device_id,
        request.to_device_id,
    )?;
    Ok(())
}

fn validate_active_vault_membership(
    state: &LibraryState,
    vault_id: Uuid,
    device_id: Uuid,
) -> Result<(), SyncTransportError> {
    if !state.vaults.iter().any(|vault| vault.id == vault_id) {
        return Err(SyncTransportError::Invalid(format!(
            "vault {vault_id} is not enrolled on this device"
        )));
    }
    if !state.vault_members.iter().any(|member| {
        member.vault_id == vault_id && member.device_id == device_id && member.revoked_at.is_none()
    }) {
        return Err(SyncTransportError::Invalid(format!(
            "device {device_id} is not an active member of vault {vault_id}"
        )));
    }
    Ok(())
}

fn validate_transfer_state_if_present(
    state: &LibraryState,
    transfer_id: Uuid,
    vault_id: Uuid,
    blob_id: Uuid,
    from_device_id: Uuid,
    to_device_id: Uuid,
) -> Result<(), SyncTransportError> {
    let Some(transfer) = state
        .sync_transfers
        .iter()
        .find(|transfer| transfer.id == transfer_id)
    else {
        return Ok(());
    };
    if transfer.vault_id != vault_id
        || transfer.blob_id != blob_id
        || transfer.from_device_id != Some(from_device_id)
        || transfer.to_device_id != to_device_id
    {
        return Err(SyncTransportError::Invalid(
            "transfer envelope does not match persisted transfer state".into(),
        ));
    }
    Ok(())
}

fn commit_received_blob(
    state: &mut LibraryState,
    envelope: &TransferEnvelope,
    chunks: Vec<BlobChunk>,
    bytes_received: u64,
) -> Result<(), SyncTransportError> {
    let storage_only_receiver = state
        .devices
        .iter()
        .find(|device| device.id == envelope.to_device_id)
        .map(|device| device.trust_level == DeviceTrustLevel::StorageOnly)
        .unwrap_or(false);
    let incoming_blob = if storage_only_receiver {
        opaque_blob_record(&envelope.blob)
    } else {
        envelope.blob.clone()
    };

    if let Some(existing) = state
        .blob_records
        .iter_mut()
        .find(|blob| blob.id == envelope.blob.id)
    {
        merge_blob_record(existing, incoming_blob);
    } else {
        state.blob_records.push(incoming_blob);
    }

    for chunk in chunks {
        let chunk = if storage_only_receiver {
            opaque_blob_chunk(chunk)
        } else {
            chunk
        };
        if let Some(existing) = state.blob_chunks.iter_mut().find(|existing| {
            existing.blob_id == chunk.blob_id && existing.chunk_index == chunk.chunk_index
        }) {
            merge_blob_chunk(existing, chunk);
        } else {
            state.blob_chunks.push(chunk);
        }
    }

    upsert_blob_replica(
        state,
        envelope.blob.id,
        envelope.to_device_id,
        envelope.blob.bytes,
        Some(envelope.transfer_id),
    );
    upsert_completed_transfer(state, envelope, bytes_received);
    Ok(())
}

fn merge_blob_record(existing: &mut BlobRecord, incoming: BlobRecord) {
    let existing_content_hash = existing.content_hash.clone();
    *existing = incoming;
    if !is_opaque_hash(&existing_content_hash) && is_opaque_hash(&existing.content_hash) {
        existing.content_hash = existing_content_hash;
    }
}

fn merge_blob_chunk(existing: &mut BlobChunk, incoming: BlobChunk) {
    let existing_content_hash = existing.content_hash.clone();
    let existing_nonce_hex = existing.nonce_hex.clone();
    let existing_aad = existing.aad.clone();
    *existing = incoming;
    if !is_opaque_hash(&existing_content_hash) && is_opaque_hash(&existing.content_hash) {
        existing.content_hash = existing_content_hash;
    }
    if existing.nonce_hex.is_none() {
        existing.nonce_hex = existing_nonce_hex;
    }
    if existing.aad.is_none() {
        existing.aad = existing_aad;
    }
}

fn opaque_blob_record(blob: &BlobRecord) -> BlobRecord {
    let mut opaque = blob.clone();
    opaque.content_hash = opaque_hash(&blob.encrypted_hash);
    opaque
}

fn opaque_blob_chunk(mut chunk: BlobChunk) -> BlobChunk {
    chunk.content_hash = opaque_hash(&chunk.encrypted_hash);
    chunk.nonce_hex = None;
    chunk.aad = None;
    chunk
}

fn opaque_hash(encrypted_hash: &str) -> String {
    format!("opaque:{encrypted_hash}")
}

fn is_opaque_hash(value: &str) -> bool {
    value.starts_with("opaque:")
}

pub(crate) fn peer_descriptor_for_device(
    device: &DeviceIdentity,
    relay_endpoint: Option<&RelayEndpoint>,
) -> PeerEndpointDescriptor {
    PeerEndpointDescriptor {
        device_id: Some(device.id),
        device_name: device.display_name.clone(),
        platform: device.platform.clone(),
        node_id: relay_endpoint
            .map(|endpoint| endpoint.node_id.clone())
            .unwrap_or_else(|| device.public_key.clone()),
        relay_urls: relay_endpoint
            .and_then(|endpoint| endpoint.relay_url.clone().map(|url| vec![url]))
            .unwrap_or_default(),
        direct_addresses: relay_endpoint
            .map(|endpoint| endpoint.direct_addresses.clone())
            .unwrap_or_default(),
        expires_at: relay_endpoint
            .map(|endpoint| endpoint.expires_at)
            .unwrap_or_else(|| Utc::now() + chrono::Duration::minutes(10)),
        trust_level: device.trust_level,
        role: default_role_for_trust(device.trust_level),
    }
}

pub(crate) fn upsert_relay_endpoint(
    state: &mut LibraryState,
    device_id: Uuid,
    node_id: String,
    relay_url: Option<String>,
    direct_addresses: Vec<String>,
    expires_at: chrono::DateTime<Utc>,
) {
    let now = Utc::now();
    if let Some(endpoint) = state
        .relay_endpoints
        .iter_mut()
        .find(|endpoint| endpoint.device_id == device_id)
    {
        endpoint.node_id = node_id;
        endpoint.relay_url = relay_url;
        endpoint.direct_addresses = direct_addresses;
        endpoint.last_seen_at = now;
        endpoint.expires_at = expires_at;
    } else {
        state.relay_endpoints.push(RelayEndpoint {
            id: Uuid::new_v4(),
            device_id,
            node_id,
            relay_url,
            direct_addresses,
            last_seen_at: now,
            expires_at,
        });
    }
}

pub(crate) fn upsert_blob_replica(
    state: &mut LibraryState,
    blob_id: Uuid,
    device_id: Uuid,
    bytes_present: u64,
    transfer_id: Option<Uuid>,
) {
    let now = Utc::now();
    if let Some(replica) = state
        .blob_replicas
        .iter_mut()
        .find(|replica| replica.blob_id == blob_id && replica.device_id == device_id)
    {
        replica.health = ReplicaHealth::Healthy;
        replica.bytes_present = bytes_present;
        replica.verified_at = Some(now);
        replica.transfer_id = transfer_id.or(replica.transfer_id);
    } else {
        state.blob_replicas.push(BlobReplica {
            id: Uuid::new_v4(),
            blob_id,
            device_id,
            health: ReplicaHealth::Healthy,
            bytes_present,
            verified_at: Some(now),
            transfer_id,
        });
    }
}

fn upsert_completed_transfer(state: &mut LibraryState, envelope: &TransferEnvelope, bytes: u64) {
    let now = Utc::now();
    if let Some(transfer) = state
        .sync_transfers
        .iter_mut()
        .find(|transfer| transfer.id == envelope.transfer_id)
    {
        transfer.status = SyncTransferStatus::Completed;
        transfer.bytes_completed = bytes;
        transfer.updated_at = now;
        transfer.started_at = transfer.started_at.or(Some(now));
    } else {
        state.sync_transfers.push(SyncTransfer {
            id: envelope.transfer_id,
            vault_id: envelope.blob.vault_id,
            blob_id: envelope.blob.id,
            from_device_id: Some(envelope.from_device_id),
            to_device_id: envelope.to_device_id,
            status: SyncTransferStatus::Completed,
            bytes_total: envelope.blob.bytes,
            bytes_completed: bytes,
            started_at: Some(now),
            updated_at: now,
            resumable_until: now + chrono::Duration::days(7),
        });
    }
}

fn endpoint_addr_from_descriptor(
    descriptor: &PeerEndpointDescriptor,
) -> Result<EndpointAddr, SyncTransportError> {
    let endpoint_id = EndpointId::from_str(&descriptor.node_id)
        .map_err(|err| SyncTransportError::Invalid(err.to_string()))?;
    let mut addrs = Vec::new();
    for addr in &descriptor.direct_addresses {
        let addr = addr
            .parse::<SocketAddr>()
            .map_err(|err| SyncTransportError::Invalid(err.to_string()))?;
        addrs.push(TransportAddr::Ip(addr));
    }
    for relay in &descriptor.relay_urls {
        let relay = relay
            .parse::<RelayUrl>()
            .map_err(|err| SyncTransportError::Invalid(err.to_string()))?;
        addrs.push(TransportAddr::Relay(relay));
    }
    Ok(EndpointAddr::from_parts(endpoint_id, addrs))
}

fn incoming_chunk_path(blob: &BlobRecord, chunk: &BlobChunk) -> PathBuf {
    PathBuf::from("vaults")
        .join(blob.vault_id.to_string())
        .join("blobs")
        .join(blob.id.to_string())
        .join(chunk_filename(chunk.chunk_index))
}

fn chunk_filename(index: u32) -> String {
    format!("{index:08}.pgblob")
}

fn validate_incoming_manifest(
    state: &LibraryState,
    envelope: &TransferEnvelope,
) -> Result<(), SyncTransportError> {
    let blob = &envelope.blob;
    let chunks = &envelope.chunks;
    if blob.tombstoned_at.is_some() || blob.chunk_count == 0 {
        return Err(SyncTransportError::Invalid(
            "incoming blob is tombstoned or has no chunks".to_string(),
        ));
    }
    if usize::try_from(blob.chunk_count).ok() != Some(chunks.len()) {
        return Err(SyncTransportError::Invalid(
            "incoming chunk count does not match the blob manifest".to_string(),
        ));
    }

    let mut chunk_ids = std::collections::HashSet::with_capacity(chunks.len());
    let mut chunk_indexes = std::collections::HashSet::with_capacity(chunks.len());
    let mut bytes = 0_u64;
    let mut encrypted_bytes = 0_u64;
    for chunk in chunks {
        if chunk.blob_id != blob.id
            || chunk.chunk_index >= blob.chunk_count
            || chunk.encrypted_bytes == 0
            || chunk.encrypted_bytes > MAX_CHUNK_FRAME_BYTES as u64
            || !chunk_ids.insert(chunk.id)
            || !chunk_indexes.insert(chunk.chunk_index)
        {
            return Err(SyncTransportError::Invalid(
                "incoming chunk manifest has duplicate, missing, or invalid entries".to_string(),
            ));
        }
        bytes = bytes.checked_add(chunk.bytes).ok_or_else(|| {
            SyncTransportError::Invalid("incoming chunk byte count overflowed".to_string())
        })?;
        encrypted_bytes = encrypted_bytes
            .checked_add(chunk.encrypted_bytes)
            .ok_or_else(|| {
                SyncTransportError::Invalid(
                    "incoming encrypted chunk byte count overflowed".to_string(),
                )
            })?;
        let identity_conflict = state
            .blob_chunks
            .iter()
            .find(|existing| {
                existing.id == chunk.id
                    && (existing.blob_id != chunk.blob_id
                        || existing.chunk_index != chunk.chunk_index
                        || existing.encrypted_hash != chunk.encrypted_hash
                        || existing.encrypted_bytes != chunk.encrypted_bytes
                        || existing.bytes != chunk.bytes
                        || !compatible_chunk_content_hash(existing, chunk)
                        || (existing.nonce_hex.is_some()
                            && chunk.nonce_hex.is_some()
                            && existing.nonce_hex != chunk.nonce_hex)
                        || (existing.aad.is_some()
                            && chunk.aad.is_some()
                            && existing.aad != chunk.aad))
            })
            .or_else(|| {
                state.blob_chunks.iter().find(|existing| {
                    existing.blob_id == chunk.blob_id
                        && existing.chunk_index == chunk.chunk_index
                        && (existing.id != chunk.id
                            || existing.encrypted_hash != chunk.encrypted_hash
                            || existing.encrypted_bytes != chunk.encrypted_bytes
                            || existing.bytes != chunk.bytes
                            || !compatible_chunk_content_hash(existing, chunk)
                            || (existing.nonce_hex.is_some()
                                && chunk.nonce_hex.is_some()
                                && existing.nonce_hex != chunk.nonce_hex)
                            || (existing.aad.is_some()
                                && chunk.aad.is_some()
                                && existing.aad != chunk.aad))
                })
            });
        if identity_conflict.is_some() {
            return Err(SyncTransportError::Invalid(
                "incoming chunk conflicts with an existing local chunk identity".to_string(),
            ));
        }
    }
    if bytes != blob.bytes {
        return Err(SyncTransportError::Invalid(
            "incoming chunk sizes do not match the blob size".to_string(),
        ));
    }
    if encrypted_bytes < bytes {
        return Err(SyncTransportError::Invalid(
            "encrypted chunk sizes are smaller than the plaintext manifest".to_string(),
        ));
    }
    let mut ordered_chunks = chunks.iter().collect::<Vec<_>>();
    ordered_chunks.sort_by_key(|chunk| chunk.chunk_index);
    let mut encrypted_hash_input = Vec::new();
    for chunk in ordered_chunks {
        encrypted_hash_input.extend_from_slice(chunk.encrypted_hash.as_bytes());
    }
    if sha256_hex(&encrypted_hash_input) != blob.encrypted_hash {
        return Err(SyncTransportError::Invalid(
            "incoming chunk hashes do not match the blob manifest hash".to_string(),
        ));
    }

    if let Some(existing) = state
        .blob_records
        .iter()
        .find(|existing| existing.id == blob.id)
        && (existing.tombstoned_at.is_some()
            || existing.vault_id != blob.vault_id
            || existing.asset_id != blob.asset_id
            || existing.encrypted_hash != blob.encrypted_hash
            || existing.bytes != blob.bytes
            || existing.chunk_count != blob.chunk_count
            || existing.encryption_key_version != blob.encryption_key_version
            || !(existing.content_hash == blob.content_hash
                || compatible_hash_projection(
                    &existing.content_hash,
                    &blob.content_hash,
                    &blob.encrypted_hash,
                )))
    {
        return Err(SyncTransportError::Invalid(
            "incoming blob conflicts with an existing local blob identity".to_string(),
        ));
    }
    Ok(())
}

fn compatible_chunk_content_hash(existing: &BlobChunk, incoming: &BlobChunk) -> bool {
    compatible_hash_projection(
        &existing.content_hash,
        &incoming.content_hash,
        &existing.encrypted_hash,
    )
}

fn compatible_hash_projection(existing: &str, incoming: &str, encrypted_hash: &str) -> bool {
    existing == incoming
        || (existing == opaque_hash(encrypted_hash) && is_opaque_hash(existing))
        || (incoming == opaque_hash(encrypted_hash) && is_opaque_hash(incoming))
}

fn reserve_receive_capacity(
    library_root: &Path,
    state: &LibraryState,
    envelope: &TransferEnvelope,
) -> Result<ReceiveReservation, SyncTransportError> {
    let transfer_bytes = envelope.chunks.iter().try_fold(0_u64, |total, chunk| {
        total.checked_add(chunk.encrypted_bytes).ok_or_else(|| {
            SyncTransportError::Invalid("incoming transfer size overflowed".to_string())
        })
    })?;
    let vault = state
        .vaults
        .iter()
        .find(|vault| vault.id == envelope.blob.vault_id)
        .ok_or_else(|| SyncTransportError::Invalid("incoming vault is unavailable".to_string()))?;
    let device = state
        .devices
        .iter()
        .find(|device| device.id == envelope.to_device_id)
        .ok_or_else(|| SyncTransportError::Invalid("receiver device is unavailable".to_string()))?;
    let required_reserve = vault
        .storage_policy
        .min_free_space_bytes
        .checked_add(device.storage_profile.reserved_bytes)
        .ok_or_else(|| {
            SyncTransportError::Invalid("configured storage reserve overflowed".to_string())
        })?;
    let available = available_receive_space(library_root)?;
    let required = transfer_bytes
        .checked_add(required_reserve)
        .ok_or_else(|| {
            SyncTransportError::Invalid("incoming transfer capacity overflowed".to_string())
        })?;
    loop {
        let already_reserved = RESERVED_RECEIVE_BYTES.load(std::sync::atomic::Ordering::Acquire);
        let required_with_inflight = required.checked_add(already_reserved).ok_or_else(|| {
            SyncTransportError::Invalid("incoming transfer reservation overflowed".to_string())
        })?;
        if available < required_with_inflight {
            return Err(SyncTransportError::Invalid(format!(
                "insufficient free space for encrypted transfer to vault {}: need {transfer_bytes} bytes plus {required_reserve} bytes reserved and {already_reserved} bytes for active transfers, have {available} bytes",
                envelope.blob.vault_id
            )));
        }
        let next_reserved = already_reserved
            .checked_add(transfer_bytes)
            .ok_or_else(|| {
                SyncTransportError::Invalid("active transfer reservation overflowed".to_string())
            })?;
        if RESERVED_RECEIVE_BYTES
            .compare_exchange_weak(
                already_reserved,
                next_reserved,
                std::sync::atomic::Ordering::AcqRel,
                std::sync::atomic::Ordering::Acquire,
            )
            .is_ok()
        {
            return Ok(ReceiveReservation(transfer_bytes));
        }
    }
}

#[cfg(not(windows))]
fn available_receive_space(path: &Path) -> Result<u64, SyncTransportError> {
    fs2::available_space(path).map_err(io_error)
}

#[cfg(windows)]
fn available_receive_space(path: &Path) -> Result<u64, SyncTransportError> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;

    let path: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
    let mut available_to_caller = 0_u64;
    let result = unsafe {
        GetDiskFreeSpaceExW(
            path.as_ptr(),
            &mut available_to_caller,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    if result == 0 {
        Err(io_error(std::io::Error::last_os_error()))
    } else {
        Ok(available_to_caller)
    }
}

struct ReceiveReservation(u64);

impl Drop for ReceiveReservation {
    fn drop(&mut self) {
        RESERVED_RECEIVE_BYTES.fetch_sub(self.0, std::sync::atomic::Ordering::AcqRel);
    }
}

#[cfg(unix)]
fn sync_directory(path: &Path) -> Result<(), SyncTransportError> {
    std::fs::File::open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(io_error)
}

#[cfg(windows)]
fn sync_directory(_path: &Path) -> Result<(), SyncTransportError> {
    // File publication on Windows uses MOVEFILE_WRITE_THROUGH. The standard
    // library cannot flush directory handles portably on Windows.
    Ok(())
}

fn open_receive_root(library_root: &Path) -> Result<(Dir, PathBuf), SyncTransportError> {
    fs::create_dir_all(library_root).map_err(io_error)?;
    let root = fs::canonicalize(library_root).map_err(io_error)?;
    let directory = Dir::open_ambient_dir(&root, ambient_authority()).map_err(io_error)?;
    Ok((directory, root))
}

fn open_or_create_blob_dir(
    root: &Dir,
    root_path: &Path,
    vault_id: Uuid,
    blob_id: Uuid,
) -> Result<(Dir, Vec<Dir>), SyncTransportError> {
    let vaults = open_or_create_directory(root, "vaults", &root_path.join("vaults"))?;
    let vault_path = root_path.join("vaults").join(vault_id.to_string());
    let vault = open_or_create_directory(&vaults, &vault_id.to_string(), &vault_path)?;
    let blobs_path = vault_path.join("blobs");
    let blobs = open_or_create_directory(&vault, "blobs", &blobs_path)?;
    let blob = open_or_create_directory(
        &blobs,
        &blob_id.to_string(),
        &blobs_path.join(blob_id.to_string()),
    )?;
    // Keep every directory handle alive while Windows publication uses the
    // canonical path API. cap-std opens directory handles without
    // FILE_SHARE_DELETE on Windows, preventing an ancestor from being
    // replaced by a junction or symlink during the transfer.
    Ok((blob, vec![vaults, vault, blobs]))
}

fn open_or_create_directory(
    parent: &Dir,
    name: &str,
    path: &Path,
) -> Result<Dir, SyncTransportError> {
    let mut created = false;
    match parent.symlink_metadata(name) {
        Ok(metadata) => validate_storage_directory(&metadata, name)?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            match create_storage_directory(parent, name, path) {
                Ok(()) => created = true,
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
                Err(error) => return Err(io_error(error)),
            }
        }
        Err(error) => return Err(io_error(error)),
    }
    let metadata = parent.symlink_metadata(name).map_err(io_error)?;
    validate_storage_directory(&metadata, name)?;
    if created {
        let parent_path = path.parent().ok_or_else(|| {
            SyncTransportError::Invalid("managed directory has no parent".to_string())
        })?;
        sync_directory(parent_path)?;
    }
    parent.open_dir(name).map_err(io_error)
}

#[cfg(windows)]
fn create_storage_directory(parent: &Dir, _name: &str, path: &Path) -> std::io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{MOVEFILE_WRITE_THROUGH, MoveFileExW};

    let parent_path = path
        .parent()
        .ok_or_else(|| std::io::Error::other("managed directory has no parent"))?;
    let staging_name = format!(".po-dir-stage-{}", Uuid::new_v4());
    parent.create_dir(&staging_name)?;
    let source: Vec<u16> = parent_path
        .join(&staging_name)
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect();
    let destination: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
    let moved = unsafe {
        MoveFileExW(
            source.as_ptr(),
            destination.as_ptr(),
            MOVEFILE_WRITE_THROUGH,
        )
    };
    if moved != 0 {
        Ok(())
    } else {
        let error = std::io::Error::last_os_error();
        let _ = parent.remove_dir(&staging_name);
        Err(error)
    }
}

#[cfg(not(windows))]
fn create_storage_directory(parent: &Dir, name: &str, _path: &Path) -> std::io::Result<()> {
    parent.create_dir(name)
}

fn validate_storage_directory(
    metadata: &CapMetadata,
    name: &str,
) -> Result<(), SyncTransportError> {
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(SyncTransportError::Invalid(format!(
            "managed storage component {name:?} is not a real directory"
        )));
    }
    Ok(())
}

fn write_staged_chunk(dir: &Dir, name: &str, bytes: &[u8]) -> Result<(), SyncTransportError> {
    let mut options = CapOpenOptions::new();
    options.write(true).create_new(true);
    let mut file = dir.open_with(name, &options).map_err(io_error)?;
    use std::io::Write;
    file.write_all(bytes).map_err(io_error)?;
    file.sync_all().map_err(io_error)
}

fn publish_staged_chunk(
    stage: &Dir,
    stage_path: &Path,
    staged_name: &str,
    destination: &Dir,
    destination_path: &Path,
    destination_name: &str,
    expected: (&str, u64),
) -> Result<(), SyncTransportError> {
    if storage_file_matches(destination, destination_name, expected.0, expected.1)? {
        return Ok(());
    }
    match publish_noreplace(
        stage,
        stage_path,
        staged_name,
        destination,
        destination_path,
        destination_name,
    ) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            if storage_file_matches(destination, destination_name, expected.0, expected.1)? {
                Ok(())
            } else {
                Err(SyncTransportError::Invalid(
                    "incoming chunk conflicts with different existing bytes".to_string(),
                ))
            }
        }
        Err(error) => Err(io_error(error)),
    }
}

#[cfg(unix)]
fn publish_noreplace(
    stage: &Dir,
    _stage_path: &Path,
    staged_name: &str,
    destination: &Dir,
    _destination_path: &Path,
    destination_name: &str,
) -> std::io::Result<()> {
    rustix::fs::renameat_with(
        stage,
        staged_name,
        destination,
        destination_name,
        rustix::fs::RenameFlags::NOREPLACE,
    )
    .map_err(std::io::Error::from)
}

#[cfg(windows)]
fn publish_noreplace(
    _stage: &Dir,
    stage_path: &Path,
    staged_name: &str,
    _destination: &Dir,
    destination_path: &Path,
    destination_name: &str,
) -> std::io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{MOVEFILE_WRITE_THROUGH, MoveFileExW};

    let source: Vec<u16> = stage_path
        .join(staged_name)
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect();
    let destination: Vec<u16> = destination_path
        .join(destination_name)
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect();
    let moved = unsafe {
        MoveFileExW(
            source.as_ptr(),
            destination.as_ptr(),
            MOVEFILE_WRITE_THROUGH,
        )
    };
    if moved == 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(not(any(unix, windows)))]
fn publish_noreplace(
    _stage: &Dir,
    _stage_path: &Path,
    _staged_name: &str,
    _destination: &Dir,
    _destination_path: &Path,
    _destination_name: &str,
) -> std::io::Result<()> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "durable no-replace chunk publication is unsupported on this platform",
    ))
}

fn storage_file_matches(
    dir: &Dir,
    name: &str,
    expected_hash: &str,
    expected_bytes: u64,
) -> Result<bool, SyncTransportError> {
    let metadata = match dir.symlink_metadata(name) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(io_error(error)),
    };
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(SyncTransportError::Invalid(format!(
            "managed chunk destination {name:?} is not a regular file"
        )));
    }
    if metadata.len() != expected_bytes {
        return Ok(false);
    }
    let bytes = dir.read(name).map_err(io_error)?;
    Ok(sha256_hex(&bytes) == expected_hash)
}

fn cleanup_stale_incoming(blob_dir: &Dir) -> Result<(), SyncTransportError> {
    const STALE_AFTER: Duration = Duration::from_secs(7 * 24 * 60 * 60);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let entries = blob_dir.entries().map_err(io_error)?;
    for entry in entries {
        let entry = entry.map_err(io_error)?;
        let name = entry.file_name();
        let Some(name_text) = name.to_str() else {
            continue;
        };
        let Some((created_at, _nonce)) = name_text
            .strip_prefix(".incoming-")
            .and_then(|value| value.split_once('-'))
        else {
            continue;
        };
        let Ok(created_at) = created_at.parse::<u64>() else {
            continue;
        };
        let metadata = match blob_dir.symlink_metadata(&name) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(io_error(error)),
        };
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            continue;
        }
        let stale = now.saturating_sub(created_at) >= STALE_AFTER.as_secs();
        if stale {
            blob_dir.remove_dir_all(&name).map_err(io_error)?;
        }
    }
    Ok(())
}

struct IncomingStageGuard(Option<Dir>);

impl IncomingStageGuard {
    fn new(dir: Dir) -> Self {
        Self(Some(dir))
    }

    fn dir(&self) -> &Dir {
        self.0
            .as_ref()
            .expect("receive staging directory is present")
    }
}

impl Drop for IncomingStageGuard {
    fn drop(&mut self) {
        if let Some(dir) = self.0.take() {
            let _ = dir.remove_open_dir_all();
        }
    }
}

fn safe_relative_path(value: &str) -> Option<PathBuf> {
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

fn path_to_storage_string(path: &Path) -> String {
    path.components()
        .filter_map(|component| match component {
            std::path::Component::Normal(value) => Some(value.to_string_lossy().to_string()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("/")
}

async fn write_frame<W>(writer: &mut W, bytes: &[u8]) -> Result<(), SyncTransportError>
where
    W: AsyncWrite + Unpin,
{
    writer
        .write_u64(bytes.len() as u64)
        .await
        .map_err(io_error)?;
    writer.write_all(bytes).await.map_err(io_error)
}

async fn read_frame<R>(reader: &mut R, max_len: usize) -> Result<Vec<u8>, SyncTransportError>
where
    R: AsyncRead + Unpin,
{
    let len = reader.read_u64().await.map_err(io_error)? as usize;
    if len > max_len {
        return Err(SyncTransportError::Invalid(format!(
            "frame exceeds maximum size: {len} > {max_len}"
        )));
    }
    let mut bytes = vec![0_u8; len];
    reader.read_exact(&mut bytes).await.map_err(io_error)?;
    Ok(bytes)
}

fn load_or_create_secret_key(config: &AppConfig) -> Result<SecretKey, SyncTransportError> {
    let path = secret_key_path(config);
    if path.exists() {
        let value = fs::read_to_string(&path).map_err(io_error)?;
        let bytes = decode_hex_32(value.trim())?;
        return Ok(SecretKey::from_bytes(&bytes));
    }
    let secret = SecretKey::generate();
    let encoded = hex_string(&secret.to_bytes());
    write_atomic(&path, encoded.as_bytes())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).map_err(io_error)?;
    }
    Ok(secret)
}

fn secret_key_path(config: &AppConfig) -> PathBuf {
    config
        .runtime_root
        .join("identity")
        .join("iroh_endpoint.key")
}

fn relay_mode_for_config(config: &AppConfig) -> RelayMode {
    if cfg!(test)
        || matches!(
            config.network_policy,
            crate::domain::NetworkPolicy::OfflineOnly
        )
    {
        RelayMode::Disabled
    } else {
        RelayMode::Default
    }
}

fn public_key_is_pending(value: &str) -> bool {
    value.starts_with("local-device-key-pending-iroh-")
        || value.starts_with("device-key-pending-iroh-")
}

fn default_role_for_trust(trust_level: DeviceTrustLevel) -> DeviceRole {
    match trust_level {
        DeviceTrustLevel::Trusted => DeviceRole::Contributor,
        DeviceTrustLevel::StorageOnly => DeviceRole::StorageOnly,
    }
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), SyncTransportError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(io_error)?;
    }
    let temporary = path.with_extension(format!(
        "{}.tmp",
        path.extension()
            .map(|value| value.to_string_lossy())
            .unwrap_or_default()
    ));
    fs::write(&temporary, bytes).map_err(io_error)?;
    fs::rename(&temporary, path).map_err(io_error)
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex_string(&hasher.finalize())
}

fn hex_string(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn decode_hex_32(value: &str) -> Result<[u8; 32], SyncTransportError> {
    let mut bytes = [0_u8; 32];
    if value.len() != 64 {
        return Err(SyncTransportError::Invalid(
            "stored Iroh secret key must be 32 bytes of hex".to_string(),
        ));
    }
    let (chunks, _remainder) = value.as_bytes().as_chunks::<2>();
    for (index, chunk) in chunks.iter().enumerate() {
        let text = std::str::from_utf8(chunk)
            .map_err(|err| SyncTransportError::Invalid(err.to_string()))?;
        bytes[index] = u8::from_str_radix(text, 16)
            .map_err(|err| SyncTransportError::Invalid(err.to_string()))?;
    }
    Ok(bytes)
}

fn io_error(error: std::io::Error) -> SyncTransportError {
    SyncTransportError::Io(error.to_string())
}

#[cfg(test)]
mod tests {
    use super::{
        IncomingStageGuard, TransferEnvelope, chunk_filename, incoming_chunk_path,
        open_or_create_blob_dir, open_receive_root, publish_staged_chunk, sha256_hex,
        validate_incoming_manifest, write_staged_chunk,
    };
    use crate::{
        config::AppConfig,
        domain::{
            BlobChunk, BlobRecord, DeviceIdentity, DeviceRole, DeviceStorageProfile,
            DeviceTrustLevel, ImportMode, LibrarySettings, OriginalStoragePolicy,
            PeerEndpointDescriptor, StoragePolicy, SyncTransfer, SyncTransferStatus, Vault,
            VaultMember,
        },
        service::LibraryState,
        storage::{self, StorageBootstrapReport},
    };
    use chrono::Utc;
    use std::{
        io::{BufRead, BufReader},
        path::PathBuf,
        process::{Child, Command, Stdio},
        sync::mpsc::{self, Receiver},
        time::{Duration, Instant},
    };
    use uuid::Uuid;

    struct TestRoot(PathBuf);

    impl TestRoot {
        fn new() -> Self {
            let path =
                std::env::temp_dir().join(format!("photo-organizer-sync-{}", Uuid::new_v4()));
            std::fs::create_dir_all(&path).expect("create test root");
            Self(path)
        }
    }

    impl Drop for TestRoot {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn existing_iroh_identity_file_loads_unchanged_after_transport_upgrade() {
        let root = TestRoot::new();
        let config = AppConfig {
            runtime_root: root.0.clone(),
            ..AppConfig::default()
        };
        let identity_dir = root.0.join("identity");
        std::fs::create_dir_all(&identity_dir).expect("create identity directory");
        // This is the persisted 32-byte hex format used by the 0.98 app.
        let saved_key = [7_u8; 32];
        let saved_text = saved_key
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        let identity_path = identity_dir.join("iroh_endpoint.key");
        std::fs::write(&identity_path, &saved_text).expect("write prior-version identity");

        let loaded = super::load_or_create_secret_key(&config).expect("load prior identity");
        let expected = iroh::SecretKey::from_bytes(&saved_key);
        assert_eq!(loaded.public(), expected.public());
        assert_eq!(std::fs::read_to_string(identity_path).unwrap(), saved_text);
    }

    struct FixtureProcess {
        child: Child,
        lines: Receiver<String>,
    }

    impl FixtureProcess {
        fn start(binary: &std::path::Path, arguments: &[String]) -> Self {
            let mut child = Command::new(binary)
                .args(arguments)
                .stdout(Stdio::piped())
                .stderr(Stdio::inherit())
                .spawn()
                .expect("start isolated Iroh 0.98.2 fixture");
            let stdout = child.stdout.take().expect("fixture stdout");
            let (sender, lines) = mpsc::channel();
            std::thread::spawn(move || {
                for line in BufReader::new(stdout).lines() {
                    match line {
                        Ok(line) => {
                            if sender.send(line).is_err() {
                                break;
                            }
                        }
                        Err(_) => break,
                    }
                }
            });
            Self { child, lines }
        }

        fn next_json(&self) -> serde_json::Value {
            let line = self
                .lines
                .recv_timeout(Duration::from_secs(20))
                .expect("fixture must emit its next JSON result before the timeout");
            serde_json::from_str(&line).expect("fixture must emit valid JSON")
        }

        fn finish(mut self) -> serde_json::Value {
            let result = self.next_json();
            assert_eq!(result["event"], "complete", "{result}");
            assert_eq!(result["verified"], true, "{result}");
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                if let Some(status) = self.child.try_wait().expect("poll fixture process") {
                    assert!(status.success(), "fixture exited with {status}");
                    return result;
                }
                assert!(
                    Instant::now() < deadline,
                    "fixture did not exit after completion"
                );
                std::thread::sleep(Duration::from_millis(50));
            }
        }
    }

    impl Drop for FixtureProcess {
        fn drop(&mut self) {
            if self.child.try_wait().ok().flatten().is_none() {
                let _ = self.child.kill();
                let _ = self.child.wait();
            }
        }
    }

    fn write_legacy_key(root: &std::path::Path, bytes: &[u8; 32]) -> PathBuf {
        let path = root.join("iroh-098-test.key");
        let encoded = bytes
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        std::fs::write(&path, encoded).expect("write test-only fixture key");
        path
    }

    fn legacy_node_id(key: &[u8; 32]) -> String {
        iroh::SecretKey::from_bytes(key).public().to_string()
    }

    fn write_manifest(root: &std::path::Path, envelope: &TransferEnvelope) -> PathBuf {
        let path = root.join("transfer-manifest.json");
        std::fs::write(
            &path,
            serde_json::to_vec(envelope).expect("serialize transfer envelope"),
        )
        .expect("write transfer manifest");
        path
    }

    fn write_chunk_files(
        library_root: &std::path::Path,
        chunks: &[BlobChunk],
        ciphertexts: &[Vec<u8>],
    ) -> Vec<BlobChunk> {
        chunks
            .iter()
            .zip(ciphertexts)
            .map(|(chunk, ciphertext)| {
                let mut stored = chunk.clone();
                let relative = format!("outgoing/{:08}.pgblob", chunk.chunk_index);
                let path = library_root.join(&relative);
                std::fs::create_dir_all(path.parent().unwrap())
                    .expect("create local encrypted chunk directory");
                std::fs::write(path, ciphertext).expect("write encrypted chunk bytes");
                stored.local_path = Some(relative);
                stored
            })
            .collect()
    }

    fn write_fixture_ciphertexts(
        root: &std::path::Path,
        chunks: &[BlobChunk],
        ciphertexts: &[Vec<u8>],
    ) -> PathBuf {
        let dir = root.join("fixture-chunks");
        std::fs::create_dir_all(&dir).expect("create fixture chunk directory");
        for (chunk, ciphertext) in chunks.iter().zip(ciphertexts) {
            std::fs::write(
                dir.join(format!("{:08}.pgblob", chunk.chunk_index)),
                ciphertext,
            )
            .expect("write fixture ciphertext");
        }
        dir
    }

    fn decode_hex_array<const N: usize>(encoded: &str) -> [u8; N] {
        assert_eq!(encoded.len(), N * 2, "hex value has the expected length");
        let mut decoded = [0_u8; N];
        let (pairs, remainder) = encoded.as_bytes().as_chunks::<2>();
        assert!(remainder.is_empty(), "hex input has complete byte pairs");
        for (index, pair) in pairs.iter().enumerate() {
            decoded[index] =
                u8::from_str_radix(std::str::from_utf8(pair).expect("hex is ASCII"), 16)
                    .expect("valid hex");
        }
        decoded
    }

    fn fixture_arguments(
        mode: &str,
        key_file: &std::path::Path,
        operation: &str,
        extra: &[(&str, &std::path::Path)],
    ) -> Vec<String> {
        let mut arguments = vec![
            mode.to_string(),
            "--key-file".to_string(),
            key_file.to_string_lossy().to_string(),
            "--operation".to_string(),
            operation.to_string(),
        ];
        for (flag, path) in extra {
            arguments.push((*flag).to_string());
            arguments.push(path.to_string_lossy().to_string());
        }
        arguments
    }

    fn fixture_descriptor(ready: &serde_json::Value, device_id: Uuid) -> PeerEndpointDescriptor {
        let node_id = ready["node_id"].as_str().expect("fixture node id");
        let direct_addresses = ready["direct_addresses"]
            .as_array()
            .expect("fixture direct addresses")
            .iter()
            .map(|address| address.as_str().expect("address string").to_string())
            .collect::<Vec<_>>();
        assert_eq!(ready["iroh_version"], "0.98.2");
        assert_eq!(ready["alpn"], "private-gallery/vault-sync/1");
        assert!(ready["relay_urls"].as_array().is_some_and(Vec::is_empty));
        assert!(!direct_addresses.is_empty());
        assert!(
            direct_addresses
                .iter()
                .all(|address| address.starts_with("127.0.0.1:"))
        );
        PeerEndpointDescriptor {
            device_id: Some(device_id),
            device_name: "Iroh 0.98 fixture".to_string(),
            platform: "test".to_string(),
            node_id: node_id.to_string(),
            relay_urls: Vec::new(),
            direct_addresses,
            expires_at: Utc::now() + chrono::Duration::minutes(1),
            trust_level: DeviceTrustLevel::Trusted,
            role: DeviceRole::Contributor,
        }
    }

    struct RuntimeFixtureSpec<'a> {
        root: &'a std::path::Path,
        local_device: Uuid,
        remote_device: Uuid,
        local_key: &'a [u8; 32],
        remote_node_id: &'a str,
        initial_blobs: bool,
        chunks: &'a [BlobChunk],
        ciphertexts: &'a [Vec<u8>],
    }

    fn runtime_for_fixture(
        spec: RuntimeFixtureSpec<'_>,
    ) -> (
        super::SyncRuntime,
        std::sync::Arc<tokio::sync::RwLock<LibraryState>>,
        StorageBootstrapReport,
        PathBuf,
    ) {
        let library_root = spec.root.join("library");
        let config = AppConfig {
            library_root: library_root.clone(),
            runtime_root: spec.root.join("runtime"),
            network_policy: crate::domain::NetworkPolicy::OfflineOnly,
            ..AppConfig::default()
        };
        std::fs::create_dir_all(&library_root).expect("create isolated library root");
        let identity_path = config.runtime_root.join("identity/iroh_endpoint.key");
        std::fs::create_dir_all(identity_path.parent().unwrap()).expect("create identity root");
        let encoded_key = spec
            .local_key
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        std::fs::write(&identity_path, encoded_key).expect("write app-format identity");
        let report = storage::bootstrap_storage(&config).expect("bootstrap test database");

        let mut state = authorized_state();
        let local = state
            .devices
            .iter_mut()
            .find(|device| device.id == spec.local_device)
            .expect("local test device");
        local.public_key = format!("local-device-key-pending-iroh-{}", spec.local_device);
        let remote = state
            .devices
            .iter_mut()
            .find(|device| device.id == spec.remote_device)
            .expect("remote test device");
        remote.public_key = spec.remote_node_id.to_string();
        state.library_settings = Some(LibrarySettings {
            library_root: library_root.to_string_lossy().to_string(),
            default_import_mode: ImportMode::Copy,
            original_storage_policy: OriginalStoragePolicy::EncryptedOnly,
            initialized_at: Utc::now(),
            updated_at: Utc::now(),
        });

        if spec.initial_blobs {
            let mut stored_blob = blob();
            stored_blob.bytes = spec.chunks.iter().map(|chunk| chunk.bytes).sum();
            stored_blob.chunk_count = spec.chunks.len() as u32;
            let mut hash_input = Vec::new();
            for chunk in spec.chunks {
                hash_input.extend_from_slice(chunk.encrypted_hash.as_bytes());
            }
            stored_blob.encrypted_hash = sha256_hex(&hash_input);
            state.blob_records.push(stored_blob);
            state.blob_chunks.extend_from_slice(spec.chunks);
            for (chunk, ciphertext) in spec.chunks.iter().zip(spec.ciphertexts) {
                let path = library_root.join(chunk.local_path.as_deref().expect("chunk path"));
                if let Some(parent) = path.parent() {
                    std::fs::create_dir_all(parent).expect("create outgoing chunk directory");
                }
                std::fs::write(path, ciphertext).expect("write app-encrypted chunk");
            }
        }

        let state = std::sync::Arc::new(tokio::sync::RwLock::new(state));
        let runtime = super::SyncRuntime::new(config, report.clone(), state.clone());
        (runtime, state, report, library_root)
    }

    fn transfer_job(
        direction: super::TransferDirection,
        from_device_id: Uuid,
        to_device_id: Uuid,
        blob: BlobRecord,
        chunks: Vec<BlobChunk>,
        target: PeerEndpointDescriptor,
    ) -> super::OutboundBlobTransfer {
        super::OutboundBlobTransfer {
            direction,
            transfer: SyncTransfer {
                id: Uuid::from_u128(6),
                vault_id: blob.vault_id,
                blob_id: blob.id,
                from_device_id: Some(from_device_id),
                to_device_id,
                status: SyncTransferStatus::Pending,
                bytes_total: blob.bytes,
                bytes_completed: 0,
                started_at: None,
                updated_at: Utc::now(),
                resumable_until: Utc::now() + chrono::Duration::minutes(1),
            },
            blob,
            chunks,
            target,
        }
    }

    fn assert_persisted_completed_transfer(
        transfers: &[SyncTransfer],
        envelope: &TransferEnvelope,
    ) {
        let transfer = transfers
            .iter()
            .find(|transfer| transfer.id == envelope.transfer_id)
            .expect("completed transfer persisted");
        assert_eq!(transfer.vault_id, envelope.blob.vault_id);
        assert_eq!(transfer.blob_id, envelope.blob.id);
        assert_eq!(transfer.from_device_id, Some(envelope.from_device_id));
        assert_eq!(transfer.to_device_id, envelope.to_device_id);
        assert_eq!(transfer.status, SyncTransferStatus::Completed);
        assert_eq!(transfer.bytes_total, envelope.blob.bytes);
        assert_eq!(transfer.bytes_completed, envelope.blob.bytes);
        assert!(transfer.started_at.is_some());
    }

    fn assert_persisted_healthy_replica(
        replicas: &[super::BlobReplica],
        envelope: &TransferEnvelope,
        device_id: Uuid,
    ) {
        let replica = replicas
            .iter()
            .find(|replica| replica.blob_id == envelope.blob.id)
            .expect("replica persisted");
        assert_eq!(replica.device_id, device_id);
        assert_eq!(replica.health, super::ReplicaHealth::Healthy);
        assert_eq!(replica.bytes_present, envelope.blob.bytes);
        assert_eq!(replica.transfer_id, Some(envelope.transfer_id));
        assert!(replica.verified_at.is_some());
    }

    async fn stop_fixture_runtime(runtime: &super::SyncRuntime) {
        tokio::time::timeout(Duration::from_secs(5), runtime.stop())
            .await
            .expect("production endpoint stops before the 5 second test deadline")
            .expect("stop production test endpoint");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    #[ignore = "run through scripts/tests/iroh_mixed_version_sync_test.sh"]
    async fn mixed_version_iroh_chunk_push_pull() {
        const LEGACY_KEY: [u8; 32] = [7; 32];
        const CURRENT_KEY: [u8; 32] = [8; 32];
        let fixture = std::path::PathBuf::from(
            std::env::var_os("IROH_098_PEER_BIN")
                .expect("set IROH_098_PEER_BIN via the mixed-version test script"),
        );
        let legacy_node = legacy_node_id(&LEGACY_KEY);
        let current_node = legacy_node_id(&CURRENT_KEY);
        let source_id = Uuid::from_u128(7);
        let receiver_id = Uuid::from_u128(8);

        // Current 1.x production sender -> real 0.98.2 endpoint receiver.
        {
            eprintln!("interop case: 1.x sender to 0.98.2 receiver");
            let root = TestRoot::new();
            let legacy_key = write_legacy_key(&root.0, &LEGACY_KEY);
            let output = root.0.join("legacy-received-push");
            let server_args = fixture_arguments(
                "server",
                &legacy_key,
                "receive-push",
                &[("--output-dir", &output)],
            );
            let legacy = FixtureProcess::start(&fixture, &server_args);
            let legacy_endpoint = fixture_descriptor(&legacy.next_json(), source_id);
            assert_eq!(legacy_endpoint.node_id, legacy_node);

            let (key, mut envelope, ciphertexts) = aead_encrypted_envelope();
            envelope.from_device_id = receiver_id;
            envelope.to_device_id = source_id;
            let root_library = root.0.join("library");
            let chunks = write_chunk_files(&root_library, &envelope.chunks, &ciphertexts);
            let (runtime, _, report, library_root) = runtime_for_fixture(RuntimeFixtureSpec {
                root: &root.0,
                local_device: receiver_id,
                remote_device: source_id,
                local_key: &CURRENT_KEY,
                remote_node_id: &legacy_node,
                initial_blobs: false,
                chunks: &chunks,
                ciphertexts: &ciphertexts,
            });
            let local = runtime.start().await.expect("start production 1.x sender");
            assert_eq!(local.descriptor.node_id, current_node);
            let job = transfer_job(
                super::TransferDirection::Push,
                receiver_id,
                source_id,
                envelope.blob.clone(),
                chunks.clone(),
                legacy_endpoint,
            );
            let transfer_result = tokio::time::timeout(
                Duration::from_secs(20),
                runtime.send_blob(&job, &library_root),
            )
            .await;
            stop_fixture_runtime(&runtime).await;
            assert_eq!(
                transfer_result
                    .expect("production Push completes before the 20 second test deadline")
                    .expect("send production Push to Iroh 0.98.2"),
                envelope.blob.bytes
            );
            let result = legacy.finish();
            assert_eq!(result["chunk_count"], chunks.len());
            for chunk in &chunks {
                let bytes = std::fs::read(output.join(chunk_filename(chunk.chunk_index)))
                    .expect("read legacy-verified ciphertext");
                assert_eq!(bytes, ciphertexts[chunk.chunk_index as usize]);
                assert_eq!(sha256_hex(&bytes), chunk.encrypted_hash);
            }
            assert_aead_chunks_match_manifest(&key, &chunks, &ciphertexts);
            let persisted = storage::load_state(&report).expect("reload sender app state");
            assert!(persisted.blob_records.is_empty());
            assert!(persisted.blob_chunks.is_empty());
            assert!(persisted.sync_transfers.is_empty());
        }

        // A real 0.98.2 endpoint client -> current 1.x production receiver.
        {
            eprintln!("interop case: 0.98.2 sender to 1.x receiver");
            let root = TestRoot::new();
            let legacy_key = write_legacy_key(&root.0, &LEGACY_KEY);
            let (key, envelope, ciphertexts) = aead_encrypted_envelope();
            let manifest = write_manifest(&root.0, &envelope);
            let fixture_chunks = write_fixture_ciphertexts(&root.0, &envelope.chunks, &ciphertexts);
            let (runtime, _, report, library_root) = runtime_for_fixture(RuntimeFixtureSpec {
                root: &root.0,
                local_device: receiver_id,
                remote_device: source_id,
                local_key: &CURRENT_KEY,
                remote_node_id: &legacy_node,
                initial_blobs: false,
                chunks: &envelope.chunks,
                ciphertexts: &ciphertexts,
            });
            let local = runtime
                .start()
                .await
                .expect("start production 1.x receiver");
            assert_eq!(local.descriptor.node_id, current_node);
            assert_ne!(local.descriptor.node_id, legacy_node);
            let mut args = fixture_arguments(
                "client",
                &legacy_key,
                "push",
                &[("--manifest", &manifest), ("--chunks-dir", &fixture_chunks)],
            );
            args.extend([
                "--node-id".to_string(),
                local.descriptor.node_id.clone(),
                "--direct-address".to_string(),
                local.descriptor.direct_addresses[0].clone(),
            ]);
            let client = FixtureProcess::start(&fixture, &args);
            let result = client.finish();
            assert_eq!(result["chunk_count"], envelope.chunks.len());
            let persisted = storage::load_state(&report).expect("reload received app state");
            assert_eq!(persisted.blob_records.len(), 1);
            assert_eq!(persisted.blob_chunks.len(), envelope.chunks.len());
            assert_eq!(persisted.blob_replicas.len(), 1);
            assert_eq!(persisted.sync_transfers.len(), 1);
            assert_persisted_completed_transfer(&persisted.sync_transfers, &envelope);
            assert_persisted_healthy_replica(&persisted.blob_replicas, &envelope, receiver_id);
            for (chunk, ciphertext) in persisted.blob_chunks.iter().zip(&ciphertexts) {
                let relative = chunk.local_path.as_deref().expect("receiver-owned path");
                let bytes = std::fs::read(library_root.join(relative))
                    .expect("read committed production replica");
                assert_eq!(&bytes, ciphertext);
                assert_eq!(sha256_hex(&bytes), chunk.encrypted_hash);
            }
            assert_aead_chunks_match_manifest(&key, &persisted.blob_chunks, &ciphertexts);
            stop_fixture_runtime(&runtime).await;
        }

        // Current 1.x production Pull client <- real 0.98.2 endpoint server.
        {
            eprintln!("interop case: 1.x Pull client from 0.98.2 server");
            let root = TestRoot::new();
            let legacy_key = write_legacy_key(&root.0, &LEGACY_KEY);
            let (key, envelope, ciphertexts) = aead_encrypted_envelope();
            let manifest = write_manifest(&root.0, &envelope);
            let fixture_chunks = write_fixture_ciphertexts(&root.0, &envelope.chunks, &ciphertexts);
            let server_args = fixture_arguments(
                "server",
                &legacy_key,
                "serve-pull",
                &[("--manifest", &manifest), ("--chunks-dir", &fixture_chunks)],
            );
            let legacy = FixtureProcess::start(&fixture, &server_args);
            let legacy_endpoint = fixture_descriptor(&legacy.next_json(), source_id);
            assert_eq!(legacy_endpoint.node_id, legacy_node);
            let (runtime, _, report, library_root) = runtime_for_fixture(RuntimeFixtureSpec {
                root: &root.0,
                local_device: receiver_id,
                remote_device: source_id,
                local_key: &CURRENT_KEY,
                remote_node_id: &legacy_node,
                initial_blobs: false,
                chunks: &envelope.chunks,
                ciphertexts: &ciphertexts,
            });
            let local = runtime
                .start()
                .await
                .expect("start production 1.x receiver");
            let job = transfer_job(
                super::TransferDirection::Pull,
                source_id,
                receiver_id,
                envelope.blob.clone(),
                envelope.chunks.clone(),
                legacy_endpoint,
            );
            let transfer_result = tokio::time::timeout(
                Duration::from_secs(20),
                runtime.request_blob(&job, &library_root),
            )
            .await;
            stop_fixture_runtime(&runtime).await;
            assert_eq!(
                transfer_result
                    .expect("production Pull completes before the 20 second test deadline")
                    .expect("request production Pull from Iroh 0.98.2"),
                envelope.blob.bytes
            );
            let result = legacy.finish();
            assert_eq!(result["chunk_count"], envelope.chunks.len());
            let persisted = storage::load_state(&report).expect("reload pulled app state");
            assert_eq!(persisted.blob_records.len(), 1);
            assert_eq!(persisted.blob_chunks.len(), envelope.chunks.len());
            assert_eq!(persisted.blob_replicas.len(), 1);
            assert_persisted_completed_transfer(&persisted.sync_transfers, &envelope);
            assert_persisted_healthy_replica(&persisted.blob_replicas, &envelope, receiver_id);
            for (chunk, ciphertext) in persisted.blob_chunks.iter().zip(&ciphertexts) {
                let relative = chunk.local_path.as_deref().expect("receiver-owned path");
                let bytes = std::fs::read(library_root.join(relative))
                    .expect("read pulled production replica");
                assert_eq!(&bytes, ciphertext);
                assert_eq!(sha256_hex(&bytes), chunk.encrypted_hash);
            }
            assert_aead_chunks_match_manifest(&key, &persisted.blob_chunks, &ciphertexts);
            assert_eq!(local.descriptor.node_id, current_node);
        }

        // A real 0.98.2 endpoint client <- current 1.x production Pull server.
        {
            eprintln!("interop case: 0.98.2 Pull client from 1.x server");
            let root = TestRoot::new();
            let legacy_key = write_legacy_key(&root.0, &LEGACY_KEY);
            let (key, envelope, ciphertexts) = aead_encrypted_envelope();
            let request = super::PullRequest {
                protocol_version: super::PROTOCOL_VERSION,
                transfer_id: envelope.transfer_id,
                from_device_id: source_id,
                to_device_id: receiver_id,
                vault_id: envelope.blob.vault_id,
                blob_id: envelope.blob.id,
            };
            let request_path = root.0.join("pull-request.json");
            std::fs::write(
                &request_path,
                serde_json::to_vec(&request).expect("serialize pull request"),
            )
            .expect("write pull request");
            let server_chunks =
                write_chunk_files(&root.0.join("library"), &envelope.chunks, &ciphertexts);
            let (runtime, _, report, library_root) = runtime_for_fixture(RuntimeFixtureSpec {
                root: &root.0,
                local_device: source_id,
                remote_device: receiver_id,
                local_key: &CURRENT_KEY,
                remote_node_id: &legacy_node,
                initial_blobs: true,
                chunks: &server_chunks,
                ciphertexts: &ciphertexts,
            });
            let local = runtime.start().await.expect("start production 1.x source");
            assert_eq!(local.descriptor.node_id, current_node);
            let output = root.0.join("legacy-pulled");
            let mut args = fixture_arguments(
                "client",
                &legacy_key,
                "pull",
                &[("--request", &request_path), ("--output-dir", &output)],
            );
            args.extend([
                "--node-id".to_string(),
                local.descriptor.node_id.clone(),
                "--direct-address".to_string(),
                local.descriptor.direct_addresses[0].clone(),
            ]);
            let client = FixtureProcess::start(&fixture, &args);
            let result = client.finish();
            assert_eq!(result["chunk_count"], envelope.chunks.len());
            for (chunk, ciphertext) in envelope.chunks.iter().zip(&ciphertexts) {
                let bytes = std::fs::read(output.join(chunk_filename(chunk.chunk_index)))
                    .expect("read old-client verified ciphertext");
                assert_eq!(&bytes, ciphertext);
                assert_eq!(sha256_hex(&bytes), chunk.encrypted_hash);
            }
            assert_aead_chunks_match_manifest(&key, &envelope.chunks, &ciphertexts);
            let source_paths_exist = server_chunks.iter().all(|chunk| {
                chunk
                    .local_path
                    .as_deref()
                    .is_some_and(|path| library_root.join(path).is_file())
            });
            assert!(
                source_paths_exist,
                "production source retains its encrypted originals"
            );
            stop_fixture_runtime(&runtime).await;
            let persisted = storage::load_state(&report).expect("reload source app state");
            assert_eq!(persisted.blob_records.len(), 1);
            assert_eq!(persisted.blob_chunks.len(), envelope.chunks.len());
            let persisted_blob = persisted
                .blob_records
                .iter()
                .find(|blob| blob.id == envelope.blob.id)
                .expect("source blob remains persisted");
            assert_eq!(persisted_blob.encrypted_hash, envelope.blob.encrypted_hash);
            for (chunk, ciphertext) in persisted.blob_chunks.iter().zip(&ciphertexts) {
                let relative = chunk.local_path.as_deref().expect("source-owned path");
                let bytes = std::fs::read(library_root.join(relative))
                    .expect("read retained production source chunk");
                assert_eq!(&bytes, ciphertext);
                assert_eq!(sha256_hex(&bytes), chunk.encrypted_hash);
            }
        }
    }

    fn blob() -> BlobRecord {
        BlobRecord {
            id: Uuid::from_u128(2),
            vault_id: Uuid::from_u128(1),
            asset_id: Uuid::from_u128(3),
            content_hash: "asset-hash".to_string(),
            encrypted_hash: super::sha256_hex(b"cipher-0cipher-1"),
            bytes: 11,
            chunk_count: 2,
            encryption_key_version: 1,
            created_at: Utc::now(),
            tombstoned_at: None,
        }
    }

    fn chunk(index: u32, id: u128, bytes: u64) -> BlobChunk {
        BlobChunk {
            id: Uuid::from_u128(id),
            blob_id: Uuid::from_u128(2),
            chunk_index: index,
            content_hash: format!("chunk-{index}"),
            encrypted_hash: format!("cipher-{index}"),
            bytes,
            encrypted_bytes: 32,
            local_path: Some("db/library.sqlite".to_string()),
            nonce_hex: None,
            aad: None,
        }
    }

    fn envelope(chunks: Vec<BlobChunk>) -> TransferEnvelope {
        TransferEnvelope {
            protocol_version: super::PROTOCOL_VERSION,
            transfer_id: Uuid::from_u128(6),
            from_device_id: Uuid::from_u128(7),
            to_device_id: Uuid::from_u128(8),
            blob: blob(),
            chunks,
        }
    }

    fn authorized_state() -> LibraryState {
        let now = Utc::now();
        let vault_id = Uuid::from_u128(1);
        let source_id = Uuid::from_u128(7);
        let receiver_id = Uuid::from_u128(8);
        let receiver_profile = DeviceStorageProfile {
            device_id: Some(receiver_id),
            reserved_bytes: 0,
            accepts_storage: true,
            ..DeviceStorageProfile::default()
        };
        let mut storage_policy = StoragePolicy::protected_min_2();
        storage_policy.min_free_space_bytes = 0;
        LibraryState {
            vaults: vec![Vault {
                id: vault_id,
                name: "Test vault".to_string(),
                storage_policy,
                key_version: 1,
                deletion_grace_days: 7,
                created_at: now,
                updated_at: now,
            }],
            devices: vec![
                DeviceIdentity {
                    id: source_id,
                    display_name: "Source".to_string(),
                    platform: "linux".to_string(),
                    public_key: "remote-node".to_string(),
                    trust_level: DeviceTrustLevel::Trusted,
                    storage_profile: DeviceStorageProfile::default(),
                    enrolled_at: now,
                    last_seen_at: Some(now),
                    revoked_at: None,
                },
                DeviceIdentity {
                    id: receiver_id,
                    display_name: "Receiver".to_string(),
                    platform: "linux".to_string(),
                    public_key: "local-node".to_string(),
                    trust_level: DeviceTrustLevel::Trusted,
                    storage_profile: receiver_profile,
                    enrolled_at: now,
                    last_seen_at: Some(now),
                    revoked_at: None,
                },
            ],
            vault_members: vec![
                VaultMember {
                    id: Uuid::from_u128(9),
                    vault_id,
                    device_id: source_id,
                    role: DeviceRole::Contributor,
                    trust_level: DeviceTrustLevel::Trusted,
                    display_name: "Source".to_string(),
                    added_at: now,
                    revoked_at: None,
                },
                VaultMember {
                    id: Uuid::from_u128(10),
                    vault_id,
                    device_id: receiver_id,
                    role: DeviceRole::Contributor,
                    trust_level: DeviceTrustLevel::Trusted,
                    display_name: "Receiver".to_string(),
                    added_at: now,
                    revoked_at: None,
                },
            ],
            ..LibraryState::default()
        }
    }

    fn encrypted_envelope() -> (TransferEnvelope, Vec<Vec<u8>>) {
        let ciphertexts = vec![
            b"encrypted chunk zero".to_vec(),
            b"encrypted chunk one".to_vec(),
        ];
        let mut chunks = vec![chunk(0, 4, 5), chunk(1, 5, 6)];
        for (chunk, ciphertext) in chunks.iter_mut().zip(&ciphertexts) {
            chunk.encrypted_hash = sha256_hex(ciphertext);
            chunk.encrypted_bytes = ciphertext.len() as u64;
        }
        let mut envelope = envelope(chunks);
        let mut hash_input = Vec::new();
        for chunk in &envelope.chunks {
            hash_input.extend_from_slice(chunk.encrypted_hash.as_bytes());
        }
        envelope.blob.encrypted_hash = sha256_hex(&hash_input);
        (envelope, ciphertexts)
    }

    fn aead_encrypted_envelope() -> (chacha20poly1305::Key, TransferEnvelope, Vec<Vec<u8>>) {
        use chacha20poly1305::{
            XChaCha20Poly1305, XNonce,
            aead::{Aead, KeyInit, OsRng, Payload},
        };

        let key = XChaCha20Poly1305::generate_key(&mut OsRng);
        let cipher = XChaCha20Poly1305::new(&key);
        let plaintexts = [
            b"first verified original".as_slice(),
            b"second verified original".as_slice(),
        ];
        let mut chunks = vec![chunk(0, 4, 0), chunk(1, 5, 0)];
        let mut ciphertexts = Vec::with_capacity(plaintexts.len());
        for (index, (chunk, plaintext)) in chunks.iter_mut().zip(plaintexts).enumerate() {
            let nonce = [index as u8 + 1; 24];
            let aad = format!("mixed-version-transfer-chunk-{index}");
            let ciphertext = cipher
                .encrypt(
                    XNonce::from_slice(&nonce),
                    Payload {
                        msg: plaintext,
                        aad: aad.as_bytes(),
                    },
                )
                .expect("seal interoperability test chunk");
            chunk.bytes = plaintext.len() as u64;
            chunk.content_hash = sha256_hex(plaintext);
            chunk.encrypted_hash = sha256_hex(&ciphertext);
            chunk.encrypted_bytes = ciphertext.len() as u64;
            chunk.nonce_hex = Some(super::hex_string(&nonce));
            chunk.aad = Some(aad);
            ciphertexts.push(ciphertext);
        }
        let mut envelope = envelope(chunks);
        envelope.blob.bytes = plaintexts.iter().map(|bytes| bytes.len() as u64).sum();
        envelope.blob.chunk_count = ciphertexts.len() as u32;
        let mut hash_input = Vec::new();
        for chunk in &envelope.chunks {
            hash_input.extend_from_slice(chunk.encrypted_hash.as_bytes());
        }
        envelope.blob.encrypted_hash = sha256_hex(&hash_input);
        (key, envelope, ciphertexts)
    }

    fn assert_aead_chunks_match_manifest(
        key: &chacha20poly1305::Key,
        chunks: &[BlobChunk],
        ciphertexts: &[Vec<u8>],
    ) {
        use chacha20poly1305::{
            XChaCha20Poly1305, XNonce,
            aead::{Aead, KeyInit, Payload},
        };

        let cipher = XChaCha20Poly1305::new(key);
        assert_eq!(chunks.len(), ciphertexts.len());
        for (chunk, ciphertext) in chunks.iter().zip(ciphertexts) {
            assert_eq!(sha256_hex(ciphertext), chunk.encrypted_hash);
            assert_eq!(ciphertext.len() as u64, chunk.encrypted_bytes);
            let nonce_bytes = decode_hex_array::<24>(
                chunk
                    .nonce_hex
                    .as_deref()
                    .expect("authenticated chunk nonce"),
            );
            let aad = chunk.aad.as_deref().expect("authenticated chunk AAD");
            let plaintext = cipher
                .decrypt(
                    XNonce::from_slice(&nonce_bytes),
                    Payload {
                        msg: ciphertext,
                        aad: aad.as_bytes(),
                    },
                )
                .expect("stored bytes must remain valid authenticated ciphertext");
            assert_eq!(plaintext.len() as u64, chunk.bytes);
            assert_eq!(sha256_hex(&plaintext), chunk.content_hash);
        }
    }

    async fn invoke_receive(
        report: &StorageBootstrapReport,
        library_root: &std::path::Path,
        state: std::sync::Arc<tokio::sync::RwLock<LibraryState>>,
        envelope: &TransferEnvelope,
        ciphertexts: &[Vec<u8>],
    ) -> Result<u64, super::SyncTransportError> {
        use tokio::io::AsyncWriteExt;

        let (mut writer, mut reader) = tokio::io::duplex(4096);
        for ciphertext in ciphertexts {
            writer
                .write_u64(ciphertext.len() as u64)
                .await
                .expect("write frame length");
            writer
                .write_all(ciphertext)
                .await
                .expect("write frame body");
        }
        drop(writer);
        super::receive_envelope(
            report,
            &state,
            &mut reader,
            envelope,
            "remote-node",
            "local-node",
            library_root,
        )
        .await
    }

    #[test]
    fn sender_local_paths_never_choose_receive_destinations() {
        let blob = blob();
        let mut chunk = chunk(0, 4, 5);
        let expected = PathBuf::from("vaults")
            .join(blob.vault_id.to_string())
            .join("blobs")
            .join(blob.id.to_string())
            .join("00000000.pgblob");

        for untrusted_path in ["db/library.sqlite", "../../outside", "/etc/passwd"] {
            chunk.local_path = Some(untrusted_path.to_string());
            assert_eq!(incoming_chunk_path(&blob, &chunk), expected);
        }
    }

    #[test]
    fn manifest_requires_each_declared_chunk_exactly_once() {
        let state = LibraryState::default();
        let valid = envelope(vec![chunk(1, 5, 6), chunk(0, 4, 5)]);
        assert!(validate_incoming_manifest(&state, &valid).is_ok());

        let duplicate_index = envelope(vec![chunk(0, 4, 5), chunk(0, 5, 6)]);
        assert!(validate_incoming_manifest(&state, &duplicate_index).is_err());

        let missing_index = envelope(vec![chunk(0, 4, 5)]);
        assert!(validate_incoming_manifest(&state, &missing_index).is_err());

        let duplicate_id = envelope(vec![chunk(0, 4, 5), chunk(1, 4, 6)]);
        assert!(validate_incoming_manifest(&state, &duplicate_id).is_err());

        let mut oversized_chunk = valid;
        oversized_chunk.chunks[0].encrypted_bytes = super::MAX_CHUNK_FRAME_BYTES as u64 + 1;
        assert!(validate_incoming_manifest(&state, &oversized_chunk).is_err());

        let mut changed_plaintext_size = envelope(vec![chunk(0, 4, 5), chunk(1, 5, 6)]);
        let mut existing_state = LibraryState::default();
        existing_state.blob_chunks.push(chunk(0, 4, 4));
        assert!(validate_incoming_manifest(&existing_state, &changed_plaintext_size).is_err());
        changed_plaintext_size.chunks[0].bytes = 5;
        assert!(validate_incoming_manifest(&state, &changed_plaintext_size).is_ok());
    }

    #[test]
    fn manifest_rejects_blob_identity_rebinding() {
        let incoming = envelope(vec![chunk(0, 4, 5), chunk(1, 5, 6)]);
        let mut existing = blob();
        existing.vault_id = Uuid::from_u128(99);
        let mut state = LibraryState::default();
        state.blob_records.push(existing);

        assert!(validate_incoming_manifest(&state, &incoming).is_err());
    }

    #[test]
    fn failed_stage_is_removed_on_scope_exit() {
        let root = TestRoot::new();
        let (root_dir, _canonical_root) = open_receive_root(&root.0).expect("open capability root");
        let (blob_dir, _directory_anchors) =
            open_or_create_blob_dir(&root_dir, &root.0, Uuid::from_u128(1), Uuid::from_u128(2))
                .expect("create blob directory");
        let stage_name = ".incoming-test";
        blob_dir.create_dir(stage_name).expect("create stage");
        let stage = IncomingStageGuard::new(blob_dir.open_dir(stage_name).expect("open stage"));
        write_staged_chunk(stage.dir(), &chunk_filename(0), b"ciphertext")
            .expect("write staged bytes");
        drop(stage);

        assert!(
            !blob_dir
                .try_exists(stage_name)
                .expect("check stage cleanup")
        );
    }

    #[test]
    fn receive_capacity_enforces_configured_reserve_and_checked_sum() {
        let root = TestRoot::new();
        let state = authorized_state();
        let (valid, _) = encrypted_envelope();
        let mut reserve_state = authorized_state();
        reserve_state.vaults[0].storage_policy.min_free_space_bytes = u64::MAX;
        assert!(super::reserve_receive_capacity(&root.0, &reserve_state, &valid).is_err());

        let mut overflowing = valid;
        overflowing.chunks[0].encrypted_bytes = u64::MAX;
        overflowing.chunks[1].encrypted_bytes = 1;
        assert!(super::reserve_receive_capacity(&root.0, &state, &overflowing).is_err());
        assert!(
            std::fs::read_dir(&root.0)
                .expect("list untouched library root")
                .next()
                .is_none()
        );
    }

    #[test]
    fn conflicting_destination_preserves_existing_bytes() {
        let root = TestRoot::new();
        let (root_dir, _canonical_root) = open_receive_root(&root.0).expect("open capability root");
        let (blob_dir, _directory_anchors) =
            open_or_create_blob_dir(&root_dir, &root.0, Uuid::from_u128(1), Uuid::from_u128(2))
                .expect("create blob directory");
        let stage_name = ".incoming-test";
        blob_dir.create_dir(stage_name).expect("create stage");
        let stage = blob_dir.open_dir(stage_name).expect("open stage");
        let blob_path = root
            .0
            .join("vaults")
            .join(Uuid::from_u128(1).to_string())
            .join("blobs")
            .join(Uuid::from_u128(2).to_string());
        let stage_path = blob_path.join(stage_name);
        let name = chunk_filename(0);
        write_staged_chunk(&stage, &name, b"new-ciphertext").expect("stage new bytes");
        blob_dir
            .write(&name, b"known-good-ciphertext")
            .expect("write old bytes");

        assert!(
            publish_staged_chunk(
                &stage,
                &stage_path,
                &name,
                &blob_dir,
                &blob_path,
                &name,
                (
                    &sha256_hex(b"new-ciphertext"),
                    b"new-ciphertext".len() as u64,
                ),
            )
            .is_err()
        );
        assert_eq!(
            blob_dir.read(&name).expect("read preserved file"),
            b"known-good-ciphertext"
        );
    }

    #[tokio::test]
    async fn receive_ignores_peer_path_and_persists_only_verified_receiver_paths() {
        let root = TestRoot::new();
        let library = root.0.join("library");
        let runtime = root.0.join("runtime");
        let config = AppConfig {
            library_root: library.clone(),
            runtime_root: runtime,
            ..AppConfig::default()
        };
        let report = storage::bootstrap_storage(&config).expect("bootstrap test database");
        let unrelated = library.join("db/library.sqlite");
        std::fs::create_dir_all(unrelated.parent().expect("unrelated parent"))
            .expect("create unrelated parent");
        std::fs::write(&unrelated, b"preserve me").expect("write unrelated file");

        let (envelope, ciphertexts) = encrypted_envelope();
        let state = std::sync::Arc::new(tokio::sync::RwLock::new(authorized_state()));
        let result =
            invoke_receive(&report, &library, state.clone(), &envelope, &ciphertexts).await;

        assert_eq!(result.expect("receive and persist verified chunks"), 11);
        assert_eq!(
            std::fs::read(&unrelated).expect("read unrelated file"),
            b"preserve me"
        );
        let persisted = storage::load_state(&report).expect("reload persisted state");
        assert_eq!(persisted.blob_records.len(), 1);
        assert_eq!(persisted.blob_chunks.len(), 2);
        for (chunk, ciphertext) in persisted.blob_chunks.iter().zip(ciphertexts) {
            let local_path = chunk.local_path.as_ref().expect("receiver-owned path");
            assert!(!local_path.contains("db/library.sqlite"));
            let bytes = std::fs::read(library.join(local_path)).expect("read stored replica");
            assert_eq!(sha256_hex(&bytes), chunk.encrypted_hash);
            assert_eq!(bytes, ciphertext);
        }
    }

    #[tokio::test]
    async fn failed_metadata_commit_does_not_leave_a_healthy_replica_claim() {
        let root = TestRoot::new();
        let library = root.0.join("library");
        std::fs::create_dir_all(&library).expect("create library root");
        let database_path = root.0.join("not-a-database");
        std::fs::create_dir_all(&database_path).expect("block database file creation");
        let report = StorageBootstrapReport { database_path };
        let (envelope, ciphertexts) = encrypted_envelope();
        let state = std::sync::Arc::new(tokio::sync::RwLock::new(authorized_state()));

        assert!(
            invoke_receive(&report, &library, state.clone(), &envelope, &ciphertexts)
                .await
                .is_err()
        );
        let state = state.read().await;
        assert!(state.blob_records.is_empty());
        assert!(state.blob_chunks.is_empty());
        assert!(state.blob_replicas.is_empty());
        assert!(state.sync_transfers.is_empty());
        let final_path = library.join(incoming_chunk_path(&envelope.blob, &envelope.chunks[0]));
        assert_eq!(
            std::fs::read(final_path).expect("verified orphan can be retried"),
            ciphertexts[0]
        );
    }

    #[cfg(unix)]
    #[test]
    fn receive_refuses_symlinked_vault_directory() {
        use std::os::unix::fs::symlink;

        let root = TestRoot::new();
        let outside = root.0.join("outside");
        std::fs::create_dir_all(&outside).expect("create outside target");
        let library = root.0.join("library");
        std::fs::create_dir_all(library.join("vaults")).expect("create storage root");
        symlink(
            &outside,
            library.join("vaults").join(Uuid::from_u128(1).to_string()),
        )
        .expect("create symlink fixture");

        let (root_dir, _canonical_root) =
            open_receive_root(&library).expect("open capability root");
        assert!(
            open_or_create_blob_dir(&root_dir, &root.0, Uuid::from_u128(1), Uuid::from_u128(2),)
                .is_err()
        );
        assert_eq!(
            std::fs::read_dir(&outside)
                .expect("list outside target")
                .count(),
            0
        );
    }

    #[cfg(windows)]
    #[test]
    fn receive_refuses_symlinked_vault_directory() {
        use std::os::windows::fs::symlink_dir;

        let root = TestRoot::new();
        let outside = root.0.join("outside");
        std::fs::create_dir_all(&outside).expect("create outside target");
        let library = root.0.join("library");
        std::fs::create_dir_all(library.join("vaults")).expect("create storage root");
        symlink_dir(
            &outside,
            library.join("vaults").join(Uuid::from_u128(1).to_string()),
        )
        .expect("create symlink fixture");

        let (root_dir, _canonical_root) =
            open_receive_root(&library).expect("open capability root");
        assert!(
            open_or_create_blob_dir(&root_dir, &root.0, Uuid::from_u128(1), Uuid::from_u128(2),)
                .is_err()
        );
        assert_eq!(
            std::fs::read_dir(&outside)
                .expect("list outside target")
                .count(),
            0
        );
    }
}
