use std::{
    fs,
    net::SocketAddr,
    path::{Path, PathBuf},
    str::FromStr,
    sync::Arc,
    time::Duration,
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
        let result = self
            .accept_inner(&connection, remote_node_id)
            .await
            .map_err(AcceptError::from_err)?;
        connection.closed().await;
        Ok(result)
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
    }

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
        let relative_path = incoming_chunk_path(&envelope.blob, chunk)?;
        let destination = library_root.join(&relative_path);
        write_atomic(&destination, &ciphertext)?;
        let mut received = chunk.clone();
        received.local_path = Some(path_to_storage_string(&relative_path));
        received_chunks.push(received);
        bytes_received = bytes_received.saturating_add(chunk.bytes);
    }

    let mut state = state_lock.write().await;
    commit_received_blob(&mut state, envelope, received_chunks, bytes_received)?;
    storage::save_state(storage_report, &state.to_persisted())
        .map_err(|err| SyncTransportError::Storage(err.to_string()))?;
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

fn incoming_chunk_path(
    blob: &BlobRecord,
    chunk: &BlobChunk,
) -> Result<PathBuf, SyncTransportError> {
    if let Some(local_path) = chunk.local_path.as_deref()
        && let Some(path) = safe_relative_path(local_path)
    {
        return Ok(path);
    }
    Ok(PathBuf::from("vaults")
        .join(blob.vault_id.to_string())
        .join("blobs")
        .join(blob.id.to_string())
        .join(format!("{:08}.pgblob", chunk.chunk_index)))
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
    for (index, chunk) in value.as_bytes().chunks_exact(2).enumerate() {
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
