use std::{
    env,
    error::Error,
    fs,
    net::SocketAddr,
    path::{Path, PathBuf},
    str::FromStr,
    time::Duration,
};

use chrono::{DateTime, Utc};
use iroh::{
    Endpoint, EndpointAddr, EndpointId, RelayMode, SecretKey, TransportAddr, endpoint::presets,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    time::timeout,
};
use uuid::Uuid;

const ALPN: &[u8] = b"private-gallery/vault-sync/1";
const IROH_VERSION: &str = "0.98.2";
const APP_PROTOCOL_VERSION: u16 = 1;
const MAX_METADATA_BYTES: usize = 4 * 1024 * 1024;
const MAX_CHUNK_BYTES: usize = 128 * 1024 * 1024;
const MAX_CHUNKS: usize = 4096;
const IO_TIMEOUT: Duration = Duration::from_secs(15);

type Result<T> = std::result::Result<T, Box<dyn Error + Send + Sync>>;

#[derive(Debug, Clone, Serialize, Deserialize)]
struct BlobRecord {
    id: Uuid,
    vault_id: Uuid,
    asset_id: Uuid,
    content_hash: String,
    encrypted_hash: String,
    bytes: u64,
    chunk_count: u32,
    encryption_key_version: u32,
    created_at: DateTime<Utc>,
    tombstoned_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct BlobChunk {
    id: Uuid,
    blob_id: Uuid,
    chunk_index: u32,
    content_hash: String,
    encrypted_hash: String,
    bytes: u64,
    #[serde(default)]
    encrypted_bytes: u64,
    #[serde(default)]
    local_path: Option<String>,
    #[serde(default)]
    nonce_hex: Option<String>,
    #[serde(default)]
    aad: Option<String>,
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

#[derive(Debug, Serialize)]
struct Ready {
    event: &'static str,
    iroh_version: &'static str,
    alpn: String,
    node_id: String,
    direct_addresses: Vec<String>,
    relay_urls: Vec<String>,
}

#[derive(Debug, Serialize)]
struct Completed {
    event: &'static str,
    operation: &'static str,
    verified: bool,
    bytes_verified: u64,
    chunk_count: usize,
    hashes: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct Cli {
    mode: String,
    operation: String,
    key_file: PathBuf,
    node_id: Option<String>,
    direct_address: Option<String>,
    manifest: Option<PathBuf>,
    chunks_dir: Option<PathBuf>,
    request: Option<PathBuf>,
    output_dir: Option<PathBuf>,
}

fn usage() -> &'static str {
    "usage:\n  iroh-098-interop-peer server --key-file FILE --operation receive-push --output-dir DIR\n  iroh-098-interop-peer server --key-file FILE --operation serve-pull --manifest FILE --chunks-dir DIR\n  iroh-098-interop-peer client --key-file FILE --operation push --node-id ID --direct-address LOOPBACK:PORT --manifest FILE --chunks-dir DIR\n  iroh-098-interop-peer client --key-file FILE --operation pull --node-id ID --direct-address LOOPBACK:PORT --request FILE --output-dir DIR\n\nJSON stdout: server first emits {event:ready,node_id,direct_addresses,relay_urls,alpn,iroh_version}; then both modes emit {event:complete,operation,verified,bytes_verified,chunk_count,hashes}. Chunk files are named 00000000.pgblob, 00000001.pgblob, ... ."
}

fn parse_args() -> Result<Cli> {
    let mut args = env::args().skip(1);
    let mode = args.next().ok_or_else(|| usage().to_string())?;
    if mode == "--help" || mode == "-h" || mode == "help" {
        println!("{}", usage());
        std::process::exit(0);
    }
    if mode != "server" && mode != "client" {
        return Err(usage().into());
    }
    let mut values = std::collections::BTreeMap::<String, String>::new();
    while let Some(flag) = args.next() {
        if !flag.starts_with("--") {
            return Err(format!("expected an option, got {flag:?}\n{}", usage()).into());
        }
        let value = args
            .next()
            .ok_or_else(|| format!("missing value for {flag}\n{}", usage()))?;
        if values.insert(flag.clone(), value).is_some() {
            return Err(format!("duplicate option {flag}").into());
        }
    }
    let take =
        |values: &mut std::collections::BTreeMap<String, String>, key: &str| values.remove(key);
    let operation = take(&mut values, "--operation").ok_or_else(|| usage().to_string())?;
    let key_file =
        PathBuf::from(take(&mut values, "--key-file").ok_or_else(|| usage().to_string())?);
    let node_id = take(&mut values, "--node-id");
    let direct_address = take(&mut values, "--direct-address");
    let manifest = take(&mut values, "--manifest").map(PathBuf::from);
    let chunks_dir = take(&mut values, "--chunks-dir").map(PathBuf::from);
    let request = take(&mut values, "--request").map(PathBuf::from);
    let output_dir = take(&mut values, "--output-dir").map(PathBuf::from);
    if let Some(unknown) = values.keys().next() {
        return Err(format!("unknown option {unknown}\n{}", usage()).into());
    }
    match (mode.as_str(), operation.as_str()) {
        ("server", "receive-push") => {
            ensure_present(output_dir.is_some(), "--output-dir")?;
        }
        ("server", "serve-pull") => {
            ensure_present(manifest.is_some(), "--manifest")?;
            ensure_present(chunks_dir.is_some(), "--chunks-dir")?;
        }
        ("client", "push") => {
            ensure_present(node_id.is_some(), "--node-id")?;
            ensure_present(direct_address.is_some(), "--direct-address")?;
            ensure_present(manifest.is_some(), "--manifest")?;
            ensure_present(chunks_dir.is_some(), "--chunks-dir")?;
        }
        ("client", "pull") => {
            ensure_present(node_id.is_some(), "--node-id")?;
            ensure_present(direct_address.is_some(), "--direct-address")?;
            ensure_present(request.is_some(), "--request")?;
            ensure_present(output_dir.is_some(), "--output-dir")?;
        }
        _ => {
            return Err(format!(
                "unsupported mode/operation combination: {mode}/{operation}\n{}",
                usage()
            )
            .into());
        }
    }
    Ok(Cli {
        mode,
        operation,
        key_file,
        node_id,
        direct_address,
        manifest,
        chunks_dir,
        request,
        output_dir,
    })
}

fn ensure_present(present: bool, flag: &str) -> Result<()> {
    if !present {
        return Err(format!("missing {flag}\n{}", usage()).into());
    }
    Ok(())
}

fn load_secret_key(path: &Path) -> Result<SecretKey> {
    let bytes = fs::read(path)?;
    let text = std::str::from_utf8(&bytes)?.trim();
    if text.len() != 64 || !text.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err("key file must contain exactly 32 bytes as 64 hex characters".into());
    }
    let mut key = [0_u8; 32];
    for (index, pair) in text.as_bytes().chunks_exact(2).enumerate() {
        key[index] = u8::from_str_radix(std::str::from_utf8(pair)?, 16)?;
    }
    Ok(SecretKey::from_bytes(&key))
}

async fn bind_endpoint(key_file: &Path) -> Result<Endpoint> {
    let endpoint = Endpoint::builder(presets::N0)
        .secret_key(load_secret_key(key_file)?)
        .alpns(vec![ALPN.to_vec()])
        .relay_mode(RelayMode::Disabled)
        .clear_ip_transports()
        .bind_addr("127.0.0.1:0")?
        .bind()
        .await?;
    let addresses = direct_addresses(&endpoint);
    if addresses.is_empty()
        || addresses
            .iter()
            .any(|address| !address.starts_with("127.0.0.1:"))
    {
        endpoint.close().await;
        return Err("endpoint did not bind exclusively to IPv4 loopback".into());
    }
    Ok(endpoint)
}

fn direct_addresses(endpoint: &Endpoint) -> Vec<String> {
    endpoint
        .addr()
        .ip_addrs()
        .map(|addr| addr.to_string())
        .collect()
}

fn emit_ready(endpoint: &Endpoint) -> Result<()> {
    let ready = Ready {
        event: "ready",
        iroh_version: IROH_VERSION,
        alpn: std::str::from_utf8(ALPN)?.to_string(),
        node_id: endpoint.id().to_string(),
        direct_addresses: direct_addresses(endpoint),
        relay_urls: endpoint
            .addr()
            .relay_urls()
            .map(|url| url.to_string())
            .collect(),
    };
    println!("{}", serde_json::to_string(&ready)?);
    Ok(())
}

fn chunk_path(dir: &Path, index: u32) -> PathBuf {
    dir.join(format!("{index:08}.pgblob"))
}

fn read_manifest(path: &Path) -> Result<TransferEnvelope> {
    let envelope: TransferEnvelope = serde_json::from_slice(&fs::read(path)?)?;
    validate_envelope(&envelope)?;
    Ok(envelope)
}

fn validate_envelope(envelope: &TransferEnvelope) -> Result<()> {
    if envelope.protocol_version != APP_PROTOCOL_VERSION {
        return Err(format!(
            "unsupported Photo Organizer protocol version {}",
            envelope.protocol_version
        )
        .into());
    }
    if envelope.chunks.is_empty() || envelope.chunks.len() > MAX_CHUNKS {
        return Err("manifest chunk count is empty or exceeds the fixture limit".into());
    }
    if envelope.blob.chunk_count as usize != envelope.chunks.len() {
        return Err("manifest chunk count does not match blob metadata".into());
    }
    let mut seen_indexes = std::collections::BTreeSet::new();
    let mut seen_ids = std::collections::BTreeSet::new();
    let mut plaintext_bytes = 0_u64;
    let mut encrypted_bytes = 0_u64;
    for chunk in &envelope.chunks {
        if chunk.blob_id != envelope.blob.id
            || !seen_indexes.insert(chunk.chunk_index)
            || !seen_ids.insert(chunk.id)
        {
            return Err("manifest has a foreign or duplicate chunk".into());
        }
        if chunk.encrypted_bytes == 0 || chunk.encrypted_bytes > MAX_CHUNK_BYTES as u64 {
            return Err(format!("chunk {} has invalid encrypted length", chunk.chunk_index).into());
        }
        plaintext_bytes = plaintext_bytes
            .checked_add(chunk.bytes)
            .ok_or("manifest plaintext size overflow")?;
        encrypted_bytes = encrypted_bytes
            .checked_add(chunk.encrypted_bytes)
            .ok_or("manifest encrypted size overflow")?;
    }
    for expected in 0..envelope.chunks.len() as u32 {
        if !seen_indexes.contains(&expected) {
            return Err("manifest chunk indexes are not contiguous".into());
        }
    }
    if plaintext_bytes != envelope.blob.bytes || encrypted_bytes < plaintext_bytes {
        return Err("manifest chunk sizes do not match the blob metadata".into());
    }
    let mut ordered = envelope.chunks.iter().collect::<Vec<_>>();
    ordered.sort_by_key(|chunk| chunk.chunk_index);
    let mut hash_input = Vec::new();
    for chunk in ordered {
        hash_input.extend_from_slice(chunk.encrypted_hash.as_bytes());
    }
    if sha256_hex(&hash_input) != envelope.blob.encrypted_hash {
        return Err("manifest chunk hashes do not match the blob hash".into());
    }
    Ok(())
}

fn read_ciphertexts(envelope: &TransferEnvelope, dir: &Path) -> Result<Vec<Vec<u8>>> {
    let mut chunks = Vec::with_capacity(envelope.chunks.len());
    for chunk in &envelope.chunks {
        let bytes = fs::read(chunk_path(dir, chunk.chunk_index))?;
        verify_chunk(chunk, &bytes)?;
        chunks.push(bytes);
    }
    Ok(chunks)
}

fn verify_chunk(chunk: &BlobChunk, bytes: &[u8]) -> Result<()> {
    if bytes.len() as u64 != chunk.encrypted_bytes {
        return Err(format!("chunk {} byte length mismatch", chunk.chunk_index).into());
    }
    let hash = sha256_hex(bytes);
    if hash != chunk.encrypted_hash {
        return Err(format!("chunk {} encrypted hash mismatch", chunk.chunk_index).into());
    }
    Ok(())
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut output = String::with_capacity(64);
    for byte in Sha256::digest(bytes) {
        use std::fmt::Write as _;
        let _ = write!(output, "{byte:02x}");
    }
    output
}

async fn write_frame<W: AsyncWrite + Unpin>(writer: &mut W, bytes: &[u8]) -> Result<()> {
    if bytes.len() > MAX_CHUNK_BYTES {
        return Err("frame exceeds fixture size limit".into());
    }
    writer.write_u64(bytes.len() as u64).await?;
    writer.write_all(bytes).await?;
    Ok(())
}

async fn read_frame<R: AsyncRead + Unpin>(reader: &mut R, maximum: usize) -> Result<Vec<u8>> {
    let length = reader.read_u64().await?;
    if length > maximum as u64 {
        return Err(format!("frame length {length} exceeds limit {maximum}").into());
    }
    let mut bytes = vec![0; length as usize];
    reader.read_exact(&mut bytes).await?;
    Ok(bytes)
}

async fn server(cli: Cli) -> Result<()> {
    let endpoint = bind_endpoint(&cli.key_file).await?;
    emit_ready(&endpoint)?;
    let incoming = timeout(IO_TIMEOUT, endpoint.accept())
        .await?
        .ok_or("endpoint closed before receiving a connection")?;
    let connection = timeout(IO_TIMEOUT, incoming).await??;
    let operation: Result<Completed> = timeout(IO_TIMEOUT, async {
        let (mut send, mut recv) = connection.accept_bi().await?;
        let metadata = read_frame(&mut recv, MAX_METADATA_BYTES).await?;
        let request: WireRequest = serde_json::from_slice(&metadata)?;
        match (cli.operation.as_str(), request) {
            ("receive-push", WireRequest::Push { envelope }) => {
                validate_envelope(&envelope)?;
                let mut received = Vec::with_capacity(envelope.chunks.len());
                let mut total = 0_u64;
                for chunk in &envelope.chunks {
                    let bytes = read_frame(&mut recv, MAX_CHUNK_BYTES).await?;
                    verify_chunk(chunk, &bytes)?;
                    total = total
                        .checked_add(bytes.len() as u64)
                        .ok_or("transfer byte count overflow")?;
                    received.push(bytes);
                }
                let output_dir = cli
                    .output_dir
                    .as_deref()
                    .ok_or("missing output directory")?;
                fs::create_dir_all(output_dir)?;
                for (chunk, bytes) in envelope.chunks.iter().zip(&received) {
                    fs::write(chunk_path(output_dir, chunk.chunk_index), bytes)?;
                }
                let response = TransferResponse {
                    ok: true,
                    bytes_received: envelope.blob.bytes,
                    detail: "fixture verified and stored ciphertext chunks".into(),
                };
                write_frame(&mut send, &serde_json::to_vec(&response)?).await?;
                send.finish()?;
                Ok(completed("push", &envelope, &received, total))
            }
            ("serve-pull", WireRequest::Pull { request }) => {
                let envelope = read_manifest(cli.manifest.as_deref().ok_or("missing manifest")?)?;
                validate_pull_request(&request, &envelope)?;
                let chunks_dir = cli
                    .chunks_dir
                    .as_deref()
                    .ok_or("missing chunks directory")?;
                let chunks = read_ciphertexts(&envelope, chunks_dir)?;
                write_frame(&mut send, &serde_json::to_vec(&envelope)?).await?;
                for bytes in &chunks {
                    write_frame(&mut send, bytes).await?;
                }
                send.finish()?;
                let total = chunks.iter().map(|bytes| bytes.len() as u64).sum();
                Ok(completed("pull", &envelope, &chunks, total))
            }
            (expected, _) => {
                Err(format!("unexpected request for server operation {expected}").into())
            }
        }
    })
    .await?;
    let result = operation?;
    println!("{}", serde_json::to_string(&result)?);
    timeout(IO_TIMEOUT, connection.closed()).await?;
    endpoint.close().await;
    Ok(())
}

async fn client(cli: Cli) -> Result<()> {
    let endpoint = bind_endpoint(&cli.key_file).await?;
    let node_id = EndpointId::from_str(cli.node_id.as_deref().ok_or("missing node id")?)?;
    let direct_address: SocketAddr = cli
        .direct_address
        .as_deref()
        .ok_or("missing direct address")?
        .parse()?;
    if !direct_address.ip().is_loopback() {
        return Err("client refuses non-loopback direct addresses".into());
    }
    let target = EndpointAddr::from_parts(node_id, [TransportAddr::Ip(direct_address)]);
    let connection = timeout(IO_TIMEOUT, endpoint.connect(target, ALPN)).await??;
    let operation: Result<Completed> = timeout(IO_TIMEOUT, async {
        let (mut send, mut recv) = connection.open_bi().await?;
        match cli.operation.as_str() {
            "push" => {
                let envelope = read_manifest(cli.manifest.as_deref().ok_or("missing manifest")?)?;
                let chunks = read_ciphertexts(&envelope, cli.chunks_dir.as_deref().ok_or("missing chunks directory")?)?;
                write_frame(&mut send, &serde_json::to_vec(&WireRequest::Push { envelope: envelope.clone() })?).await?;
                for bytes in &chunks { write_frame(&mut send, bytes).await?; }
                send.finish()?;
                let response: TransferResponse = serde_json::from_slice(&read_frame(&mut recv, MAX_METADATA_BYTES).await?)?;
                let total = chunks.iter().map(|bytes| bytes.len() as u64).sum::<u64>();
                if !response.ok || response.bytes_received != envelope.blob.bytes {
                    return Err(format!("peer did not verify the complete push: {response:?}; expected {} plaintext bytes", envelope.blob.bytes).into());
                }
                Ok(completed("push", &envelope, &chunks, total))
            }
            "pull" => {
                let request: PullRequest = serde_json::from_slice(&fs::read(cli.request.as_deref().ok_or("missing pull request")?)?)?;
                if request.protocol_version != APP_PROTOCOL_VERSION { return Err("unsupported pull request protocol version".into()); }
                write_frame(&mut send, &serde_json::to_vec(&WireRequest::Pull { request: request.clone() })?).await?;
                send.finish()?;
                let envelope: TransferEnvelope = serde_json::from_slice(&read_frame(&mut recv, MAX_METADATA_BYTES).await?)?;
                validate_envelope(&envelope)?;
                validate_pull_request(&request, &envelope)?;
                let mut chunks = Vec::with_capacity(envelope.chunks.len());
                let mut total = 0_u64;
                let output_dir = cli.output_dir.as_deref().ok_or("missing output directory")?;
                fs::create_dir_all(output_dir)?;
                for chunk in &envelope.chunks {
                    let bytes = read_frame(&mut recv, MAX_CHUNK_BYTES).await?;
                    verify_chunk(chunk, &bytes)?;
                    total = total.checked_add(bytes.len() as u64).ok_or("transfer byte count overflow")?;
                    fs::write(chunk_path(output_dir, chunk.chunk_index), &bytes)?;
                    chunks.push(bytes);
                }
                Ok(completed("pull", &envelope, &chunks, total))
            }
            _ => Err("unsupported client operation".into()),
        }
    }).await?;
    let result = operation?;
    connection.close(0_u32.into(), b"fixture complete");
    println!("{}", serde_json::to_string(&result)?);
    endpoint.close().await;
    Ok(())
}

fn validate_pull_request(request: &PullRequest, envelope: &TransferEnvelope) -> Result<()> {
    if request.protocol_version != APP_PROTOCOL_VERSION
        || request.transfer_id != envelope.transfer_id
        || request.from_device_id != envelope.from_device_id
        || request.to_device_id != envelope.to_device_id
        || request.vault_id != envelope.blob.vault_id
        || request.blob_id != envelope.blob.id
    {
        return Err("pull request does not match the served transfer manifest".into());
    }
    Ok(())
}

fn completed(
    operation: &'static str,
    envelope: &TransferEnvelope,
    chunks: &[Vec<u8>],
    total: u64,
) -> Completed {
    Completed {
        event: "complete",
        operation,
        verified: true,
        bytes_verified: total,
        chunk_count: chunks.len(),
        hashes: envelope
            .chunks
            .iter()
            .map(|chunk| chunk.encrypted_hash.clone())
            .collect(),
    }
}

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("iroh-098-interop-peer: {error}");
        std::process::exit(1);
    }
}

async fn run() -> Result<()> {
    let cli = parse_args()?;
    match cli.mode.as_str() {
        "server" => server(cli).await,
        "client" => client(cli).await,
        _ => Err(usage().into()),
    }
}
