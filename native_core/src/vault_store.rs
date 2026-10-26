use std::{
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
};

use chacha20poly1305::{
    ChaCha20Poly1305, Key, Nonce,
    aead::{Aead, KeyInit, OsRng, rand_core::RngCore},
};
use sha2::{Digest, Sha256};
use thiserror::Error;
use uuid::Uuid;
use zeroize::Zeroizing;

use crate::{config::AppConfig, domain::Asset};

#[cfg(not(test))]
const KEYRING_SERVICE: &str = "private-gallery-vaults";
pub const CHUNK_BYTES: usize = 64 * 1024 * 1024;

#[derive(Debug, Error)]
pub enum VaultStoreError {
    #[error("vault store filesystem operation failed: {0}")]
    Io(String),
    #[error("vault key storage failed: {0}")]
    KeyStorage(String),
    #[error("vault encryption failed: {0}")]
    Crypto(String),
    #[error("vault blob metadata is invalid: {0}")]
    Invalid(String),
}

#[derive(Debug, Clone)]
pub struct SealedBlob {
    pub encrypted_hash: String,
    pub chunks: Vec<SealedChunk>,
}

#[derive(Debug, Clone)]
pub struct SealedChunk {
    pub chunk_index: u32,
    pub content_hash: String,
    pub encrypted_hash: String,
    pub bytes: u64,
    pub encrypted_bytes: u64,
    pub local_path: String,
    pub nonce_hex: String,
    pub aad: String,
}

pub fn seal_asset(
    config: &AppConfig,
    library_root: &Path,
    vault_id: Uuid,
    key_version: u32,
    blob_id: Uuid,
    asset: &Asset,
    source_path: &Path,
) -> Result<SealedBlob, VaultStoreError> {
    let key = load_existing_vault_key(config, vault_id, key_version)?;
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key.as_ref()));
    let mut source = fs::File::open(source_path).map_err(io_error)?;
    let mut buffer = vec![0_u8; CHUNK_BYTES];
    let mut chunks = Vec::new();

    loop {
        let read = source.read(&mut buffer).map_err(io_error)?;
        if read == 0 {
            break;
        }
        let chunk_index = chunks.len() as u32;
        let plaintext = &buffer[..read];
        let mut nonce = [0_u8; 12];
        OsRng.fill_bytes(&mut nonce);
        let aad = format!(
            "private-gallery:vault:{vault_id}:asset:{}:blob:{blob_id}:chunk:{chunk_index}:key:{key_version}",
            asset.id
        );
        let ciphertext = cipher
            .encrypt(
                Nonce::from_slice(&nonce),
                chacha20poly1305::aead::Payload {
                    msg: plaintext,
                    aad: aad.as_bytes(),
                },
            )
            .map_err(|err| VaultStoreError::Crypto(err.to_string()))?;
        let encrypted_hash = sha256_hex(&ciphertext);
        let relative_path = encrypted_chunk_relative_path(vault_id, blob_id, chunk_index);
        let absolute_path = library_root.join(&relative_path);
        write_atomic(&absolute_path, &ciphertext)?;
        chunks.push(SealedChunk {
            chunk_index,
            content_hash: sha256_hex(plaintext),
            encrypted_hash,
            bytes: read as u64,
            encrypted_bytes: ciphertext.len() as u64,
            local_path: relative_path,
            nonce_hex: hex_string(nonce),
            aad,
        });
    }

    if chunks.is_empty() {
        let mut nonce = [0_u8; 12];
        OsRng.fill_bytes(&mut nonce);
        let aad = format!(
            "private-gallery:vault:{vault_id}:asset:{}:blob:{blob_id}:chunk:0:key:{key_version}",
            asset.id
        );
        let ciphertext = cipher
            .encrypt(
                Nonce::from_slice(&nonce),
                chacha20poly1305::aead::Payload {
                    msg: &[],
                    aad: aad.as_bytes(),
                },
            )
            .map_err(|err| VaultStoreError::Crypto(err.to_string()))?;
        let encrypted_hash = sha256_hex(&ciphertext);
        let relative_path = encrypted_chunk_relative_path(vault_id, blob_id, 0);
        let absolute_path = library_root.join(&relative_path);
        write_atomic(&absolute_path, &ciphertext)?;
        chunks.push(SealedChunk {
            chunk_index: 0,
            content_hash: sha256_hex([]),
            encrypted_hash,
            bytes: 0,
            encrypted_bytes: ciphertext.len() as u64,
            local_path: relative_path,
            nonce_hex: hex_string(nonce),
            aad,
        });
    }

    let mut hash_input = Vec::new();
    for chunk in &chunks {
        hash_input.extend_from_slice(chunk.encrypted_hash.as_bytes());
    }
    Ok(SealedBlob {
        encrypted_hash: sha256_hex(hash_input),
        chunks,
    })
}

pub fn decrypt_chunks_to_bytes(
    config: &AppConfig,
    library_root: &Path,
    vault_id: Uuid,
    key_version: u32,
    chunks: &[crate::domain::BlobChunk],
) -> Result<Vec<u8>, VaultStoreError> {
    let key = load_existing_vault_key(config, vault_id, key_version)?;
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key.as_ref()));
    let mut sorted_chunks = chunks.to_vec();
    sorted_chunks.sort_by_key(|chunk| chunk.chunk_index);
    let mut plaintext = Vec::new();

    for chunk in sorted_chunks {
        let mut decrypted = decrypt_chunk_to_bytes(&cipher, library_root, &chunk)?;
        plaintext.append(&mut decrypted);
    }

    Ok(plaintext)
}

pub fn decrypt_chunks_range_to_bytes(
    config: &AppConfig,
    library_root: &Path,
    vault_id: Uuid,
    key_version: u32,
    chunks: &[crate::domain::BlobChunk],
    start: u64,
    end_inclusive: u64,
) -> Result<Vec<u8>, VaultStoreError> {
    if start > end_inclusive {
        return Err(VaultStoreError::Invalid(
            "range start must be before range end".to_string(),
        ));
    }

    let key = load_existing_vault_key(config, vault_id, key_version)?;
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key.as_ref()));
    let mut sorted_chunks = chunks.to_vec();
    sorted_chunks.sort_by_key(|chunk| chunk.chunk_index);
    let mut plaintext =
        Vec::with_capacity((end_inclusive - start + 1).min(usize::MAX as u64) as usize);
    let mut chunk_start = 0_u64;

    for chunk in sorted_chunks {
        let chunk_end = chunk_start.saturating_add(chunk.bytes);
        if chunk_end <= start {
            chunk_start = chunk_end;
            continue;
        }
        if chunk_start > end_inclusive {
            break;
        }

        let decrypted = decrypt_chunk_to_bytes(&cipher, library_root, &chunk)?;
        let slice_start = start.saturating_sub(chunk_start) as usize;
        let slice_end = (end_inclusive + 1)
            .min(chunk_end)
            .saturating_sub(chunk_start) as usize;
        plaintext.extend_from_slice(&decrypted[slice_start..slice_end]);
        chunk_start = chunk_end;
    }

    Ok(plaintext)
}

fn decrypt_chunk_to_bytes(
    cipher: &ChaCha20Poly1305,
    library_root: &Path,
    chunk: &crate::domain::BlobChunk,
) -> Result<Vec<u8>, VaultStoreError> {
    let local_path = chunk
        .local_path
        .as_ref()
        .ok_or_else(|| VaultStoreError::Invalid(format!("chunk {} has no local_path", chunk.id)))?;
    let nonce_hex = chunk
        .nonce_hex
        .as_ref()
        .ok_or_else(|| VaultStoreError::Invalid(format!("chunk {} has no nonce", chunk.id)))?;
    let aad = chunk.aad.as_deref().unwrap_or_default();
    let ciphertext = fs::read(library_root.join(local_path)).map_err(io_error)?;
    let encrypted_hash = sha256_hex(&ciphertext);
    if encrypted_hash != chunk.encrypted_hash {
        return Err(VaultStoreError::Invalid(format!(
            "encrypted hash mismatch for chunk {}",
            chunk.id
        )));
    }
    let nonce = decode_hex_12(nonce_hex)?;
    let decrypted = cipher
        .decrypt(
            Nonce::from_slice(&nonce),
            chacha20poly1305::aead::Payload {
                msg: &ciphertext,
                aad: aad.as_bytes(),
            },
        )
        .map_err(|err| VaultStoreError::Crypto(err.to_string()))?;
    let content_hash = sha256_hex(&decrypted);
    if content_hash != chunk.content_hash {
        return Err(VaultStoreError::Invalid(format!(
            "plaintext hash mismatch for chunk {}",
            chunk.id
        )));
    }
    if decrypted.len() as u64 != chunk.bytes {
        return Err(VaultStoreError::Invalid(format!(
            "plaintext byte count mismatch for chunk {}",
            chunk.id
        )));
    }
    Ok(decrypted)
}

pub fn restore_original_from_chunks(
    config: &AppConfig,
    library_root: &Path,
    vault_id: Uuid,
    key_version: u32,
    chunks: &[crate::domain::BlobChunk],
    destination: &Path,
) -> Result<(), VaultStoreError> {
    let plaintext = decrypt_chunks_to_bytes(config, library_root, vault_id, key_version, chunks)?;
    write_atomic(destination, &plaintext)
}

pub fn encrypted_chunk_files_exist(
    library_root: &Path,
    chunks: &[crate::domain::BlobChunk],
) -> bool {
    !chunks.is_empty()
        && chunks.iter().all(|chunk| {
            chunk
                .local_path
                .as_ref()
                .map(|path| {
                    let path = library_root.join(path);
                    let Ok(metadata) = fs::metadata(path) else {
                        return false;
                    };
                    metadata.is_file()
                        && (chunk.encrypted_bytes == 0 || metadata.len() == chunk.encrypted_bytes)
                })
                .unwrap_or(false)
        })
}

pub fn verify_encrypted_chunk_files(
    library_root: &Path,
    chunks: &[crate::domain::BlobChunk],
) -> Result<(), VaultStoreError> {
    if chunks.is_empty() {
        return Err(VaultStoreError::Invalid("blob has no chunks".to_string()));
    }
    for chunk in chunks {
        let local_path = chunk.local_path.as_ref().ok_or_else(|| {
            VaultStoreError::Invalid(format!("chunk {} has no local_path", chunk.id))
        })?;
        let ciphertext = fs::read(library_root.join(local_path)).map_err(io_error)?;
        let encrypted_hash = sha256_hex(&ciphertext);
        if encrypted_hash != chunk.encrypted_hash {
            return Err(VaultStoreError::Invalid(format!(
                "encrypted hash mismatch for chunk {}",
                chunk.id
            )));
        }
    }
    Ok(())
}

pub fn key_reference(vault_id: Uuid, key_version: u32) -> String {
    format!("vault-key:{vault_id}:v{key_version}")
}

/// Reject insecure production selection before opening or mutating the library.
pub fn validate_key_storage(config: &AppConfig) -> Result<(), VaultStoreError> {
    validate_backend_selection(std::env::var_os("PRIVATE_GALLERY_VAULT_KEY_STORAGE").as_deref())?;
    #[cfg(not(test))]
    if match config
        .runtime_root
        .join("security/vault-keys")
        .symlink_metadata()
    {
        Ok(_) => true,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
        Err(error) => return Err(io_error(error)),
    } {
        return Err(VaultStoreError::KeyStorage(
            "legacy plaintext vault keys detected; preserve the library and recover the exact keys into OS secure storage before starting; automatic migration is unavailable".into()));
    }
    #[cfg(test)]
    let _ = config;
    Ok(())
}

fn validate_backend_selection(value: Option<&std::ffi::OsStr>) -> Result<(), VaultStoreError> {
    match value {
        None => Ok(()),
        Some(value) if value == "keyring" => Ok(()),
        _ => Err(VaultStoreError::KeyStorage(
            "PRIVATE_GALLERY_VAULT_KEY_STORAGE only supports keyring; plaintext file storage is forbidden".into())),
    }
}

/// Provision only a never-initialized key version. The marker is durable before
/// touching the provider. An interrupted provisioning attempt may retry only
/// while the marker still says `Provisioning` and no encrypted-history evidence
/// exists; initialized or unknown states require exact-key recovery instead of
/// regeneration.
pub fn provision_vault_key_if_new(
    config: &AppConfig,
    library_root: &Path,
    vault_id: Uuid,
    key_version: u32,
    has_encrypted_history: bool,
) -> Result<(), VaultStoreError> {
    validate_key_storage(config)?;
    let key_id = key_reference(vault_id, key_version);
    let marker_root = config
        .runtime_root
        .join("security/vault-key-initialization");
    fs::create_dir_all(&marker_root).map_err(io_error)?;
    #[cfg(unix)]
    for directory in [
        &config.runtime_root,
        &config.runtime_root.join("security"),
        &marker_root,
    ] {
        fs::File::open(directory)
            .and_then(|file| file.sync_all())
            .map_err(io_error)?;
    }
    let stem = format!("{vault_id}-v{key_version}");
    let lock = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(marker_root.join(format!("{stem}.lock")))
        .map_err(io_error)?;
    fs2::FileExt::lock_exclusive(&lock).map_err(io_error)?;
    let marker = marker_root.join(format!("{stem}.initialized"));
    // Catalog evidence can be incomplete after an interrupted legacy seal.
    // Chunk paths are vault-scoped, not version-scoped: a marker for another
    // version cannot prove which key encrypted those bytes. Never create a
    // missing key while any ambiguous on-disk vault history remains. Existing
    // provider keys are still reused by prepare_key_version, including v2+.
    // Future rotation needs an explicit verified allocation/inventory protocol.
    let has_vault_ciphertext_directory = library_root
        .join("vaults")
        .join(vault_id.to_string())
        .try_exists()
        .map_err(io_error)?;
    let history = has_encrypted_history || has_vault_ciphertext_directory;
    #[cfg(test)]
    {
        let path = file_key_path(config, &key_id);
        let stored = match fs::read_to_string(&path) {
            Ok(value) => Ok(value),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                Err(keyring::Error::NoEntry)
            }
            Err(error) => Err(keyring::Error::NoStorageAccess(Box::new(error))),
        };
        prepare_key_version(&marker, history, &key_id, stored, |value| {
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent)
                    .map_err(|e| keyring::Error::NoStorageAccess(Box::new(e)))?;
            }
            let mut options = fs::OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let mut file = options
                .open(&path)
                .map_err(|e| keyring::Error::NoStorageAccess(Box::new(e)))?;
            file.write_all(value.as_bytes())
                .and_then(|_| file.sync_all())
                .map_err(|e| keyring::Error::NoStorageAccess(Box::new(e)))
        })?;
    }
    #[cfg(not(test))]
    {
        // OS credentials are shared across runtime roots. Serialize provider
        // read/create under the same per-user application lock, not only the
        // runtime-local lifecycle lock above.
        let provider_root = provider_lock_root()?;
        let _provider_lock = lock_provider_key_at(&provider_root, &stem)?;
        let provider_marker = provider_root.join(format!("{stem}.initialized"));
        let local_initialized = read_key_marker(&marker)? == Some(KeyMarkerState::Initialized);
        let entry = keyring::Entry::new(KEYRING_SERVICE, &key_id)
            .map_err(|error| VaultStoreError::KeyStorage(error.to_string()))?;
        // Share lifecycle history as well as serialization. A second runtime
        // with no local catalog must not regenerate a lost shared credential.
        prepare_key_version(
            &provider_marker,
            history || local_initialized,
            &key_id,
            entry.get_password(),
            |value| entry.set_password(value),
        )?;
        write_key_marker(&marker, KeyMarkerState::Initialized)?;
    }
    Ok(())
}

#[cfg(not(test))]
fn provider_lock_root() -> Result<PathBuf, VaultStoreError> {
    #[cfg(windows)]
    let base = std::env::var_os("LOCALAPPDATA").map(PathBuf::from);
    #[cfg(not(windows))]
    let base = std::env::var_os("HOME").map(PathBuf::from).map(|home| {
        if cfg!(target_vendor = "apple") {
            home.join("Library/Application Support")
        } else {
            home.join(".local/share")
        }
    });
    let base = base.filter(|path| path.is_absolute()).ok_or_else(|| {
        VaultStoreError::KeyStorage(
            "absolute per-user application directory is required for vault key locking".into(),
        )
    })?;
    Ok(base.join("photo-organizer/vault-key-provider-locks"))
}

fn lock_provider_key_at(root: &Path, stem: &str) -> Result<fs::File, VaultStoreError> {
    fs::create_dir_all(root).map_err(io_error)?;
    let mut options = fs::OpenOptions::new();
    options.create(true).truncate(false).read(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let lock = options
        .open(root.join(format!("{stem}.lock")))
        .map_err(io_error)?;
    fs2::FileExt::lock_exclusive(&lock).map_err(io_error)?;
    Ok(lock)
}

fn prepare_key_version(
    marker: &Path,
    has_history: bool,
    key_id: &str,
    stored: keyring::Result<String>,
    save: impl FnOnce(&str) -> keyring::Result<()>,
) -> Result<Zeroizing<[u8; 32]>, VaultStoreError> {
    let marker_state = read_key_marker(marker)?;
    let missing = matches!(&stored, Err(keyring::Error::NoEntry));
    let retryable_provisioning = marker_state == Some(KeyMarkerState::Provisioning);
    if missing && (has_history || (marker_state.is_some() && !retryable_provisioning)) {
        return Err(VaultStoreError::KeyStorage(format!(
            "vault key {key_id} requires recovery; restore the exact existing key in OS secure storage; refusing replacement"
        )));
    }
    // Validate provider reads before persisting any lifecycle change.
    if let Ok(value) = &stored {
        decode_hex_32(value)?;
    }
    if marker_state.is_none() {
        write_key_marker(marker, KeyMarkerState::Provisioning)?;
    }
    let key = load_or_create_key_from_keyring(key_id, stored, save)?;
    // The provisioning state is retryable only while there is no evidence that
    // ciphertext was ever written. Persisting Initialized before returning
    // closes the window before seal_asset can create the vault directory.
    write_key_marker(marker, KeyMarkerState::Initialized)?;
    Ok(key)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum KeyMarkerState {
    Provisioning,
    Initialized,
}

fn read_key_marker(marker: &Path) -> Result<Option<KeyMarkerState>, VaultStoreError> {
    if marker.try_exists().map_err(io_error)? {
        // Older marker formats did not distinguish an interrupted write from a
        // completed initialization. Any existing initialized marker is trusted
        // conservatively, regardless of its contents.
        return Ok(Some(KeyMarkerState::Initialized));
    }
    let provisioning = marker.with_extension("provisioning");
    if provisioning.try_exists().map_err(io_error)? {
        return Ok(Some(KeyMarkerState::Provisioning));
    }
    Ok(None)
}

fn write_key_marker(marker: &Path, state: KeyMarkerState) -> Result<(), VaultStoreError> {
    #[cfg(unix)]
    let parent = marker
        .parent()
        .ok_or_else(|| VaultStoreError::Invalid("key marker parent missing".into()))?;
    let (path, contents) = match state {
        KeyMarkerState::Provisioning => (
            marker.with_extension("provisioning"),
            b"provisioning-v1\n".as_slice(),
        ),
        KeyMarkerState::Initialized => (marker.to_path_buf(), b"initialized-v1\n".as_slice()),
    };
    let mut file = match fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
    {
        Ok(file) => file,
        Err(error)
            if error.kind() == std::io::ErrorKind::AlreadyExists
                && read_key_marker(marker)? == Some(state) =>
        {
            return Ok(());
        }
        Err(error) => return Err(io_error(error)),
    };
    file.write_all(contents).map_err(io_error)?;
    file.sync_all().map_err(io_error)?;
    #[cfg(unix)]
    fs::File::open(parent)
        .and_then(|directory| directory.sync_all())
        .map_err(io_error)?;
    if state == KeyMarkerState::Initialized {
        // The initialized marker is created durably before any caller can write
        // ciphertext. Keep the provisioning marker as an append-only history;
        // this avoids non-atomic replacement on Windows.
        #[cfg(unix)]
        fs::File::open(parent)
            .and_then(|directory| directory.sync_all())
            .map_err(io_error)?;
    }
    Ok(())
}

fn load_or_create_key_from_keyring(
    key_id: &str,
    stored: Result<String, keyring::Error>,
    save: impl FnOnce(&str) -> keyring::Result<()>,
) -> Result<Zeroizing<[u8; 32]>, VaultStoreError> {
    match stored {
        Ok(value) => decode_hex_32(&value),
        Err(keyring::Error::NoEntry) => {
            let key = random_key();
            let encoded = hex_string(key.as_ref());
            save(&encoded).map_err(|err| VaultStoreError::KeyStorage(err.to_string()))?;
            Ok(key)
        }
        Err(error) => Err(VaultStoreError::KeyStorage(format!(
            "failed to read vault key {key_id} from OS keychain: {error}"
        ))),
    }
}

fn load_existing_vault_key(
    config: &AppConfig,
    vault_id: Uuid,
    key_version: u32,
) -> Result<Zeroizing<[u8; 32]>, VaultStoreError> {
    validate_key_storage(config)?;
    let key_id = key_reference(vault_id, key_version);
    #[cfg(test)]
    return load_existing_file_key(config, &key_id);
    #[cfg(not(test))]
    {
        let entry = keyring::Entry::new(KEYRING_SERVICE, &key_id)
            .map_err(|err| VaultStoreError::KeyStorage(err.to_string()))?;
        match entry.get_password() {
            Ok(value) => decode_hex_32(&value),
            Err(_) => Err(VaultStoreError::KeyStorage(format!(
                "vault key {key_id} is missing or OS keychain is unavailable; exact-key recovery is required"
            ))),
        }
    }
}

#[cfg(test)]
fn load_existing_file_key(
    config: &AppConfig,
    key_id: &str,
) -> Result<Zeroizing<[u8; 32]>, VaultStoreError> {
    let path = file_key_path(config, key_id);
    if !path.exists() {
        return Err(VaultStoreError::KeyStorage(format!(
            "vault key {key_id} is missing"
        )));
    }
    let value = fs::read_to_string(path).map_err(io_error)?;
    decode_hex_32(value.trim())
}

#[cfg(test)]
fn file_key_path(config: &AppConfig, key_id: &str) -> PathBuf {
    config
        .runtime_root
        .join("security")
        .join("vault-keys")
        .join(format!("{key_id}.key"))
}

fn random_key() -> Zeroizing<[u8; 32]> {
    let mut key = Zeroizing::new([0_u8; 32]);
    OsRng.fill_bytes(key.as_mut());
    key
}

fn encrypted_chunk_relative_path(vault_id: Uuid, blob_id: Uuid, chunk_index: u32) -> String {
    format!("vaults/{vault_id}/blobs/{blob_id}/{chunk_index:08}.pgblob")
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), VaultStoreError> {
    let parent = path
        .parent()
        .ok_or_else(|| VaultStoreError::Io("destination has no parent".to_string()))?;
    fs::create_dir_all(parent).map_err(io_error)?;
    let tmp = temp_path(path);
    {
        let mut file = fs::File::create(&tmp).map_err(io_error)?;
        file.write_all(bytes).map_err(io_error)?;
        file.sync_all().map_err(io_error)?;
    }
    fs::rename(&tmp, path).map_err(io_error)
}

fn temp_path(path: &Path) -> PathBuf {
    let mut name = path
        .file_name()
        .map(|value| value.to_string_lossy().to_string())
        .unwrap_or_else(|| "chunk".to_string());
    name.push_str(".tmp");
    path.with_file_name(name)
}

fn sha256_hex(bytes: impl AsRef<[u8]>) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes.as_ref());
    format!("{:x}", hasher.finalize())
}

fn hex_string(bytes: impl AsRef<[u8]>) -> String {
    bytes
        .as_ref()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn decode_hex_32(value: &str) -> Result<Zeroizing<[u8; 32]>, VaultStoreError> {
    let bytes = decode_hex(value)?;
    let array: [u8; 32] = bytes
        .try_into()
        .map_err(|_| VaultStoreError::Invalid("expected 32-byte key".to_string()))?;
    Ok(Zeroizing::new(array))
}

fn decode_hex_12(value: &str) -> Result<[u8; 12], VaultStoreError> {
    let bytes = decode_hex(value)?;
    bytes
        .try_into()
        .map_err(|_| VaultStoreError::Invalid("expected 12-byte nonce".to_string()))
}

fn decode_hex(value: &str) -> Result<Vec<u8>, VaultStoreError> {
    if !value.len().is_multiple_of(2) {
        return Err(VaultStoreError::Invalid(
            "hex value has odd length".to_string(),
        ));
    }
    let mut bytes = Vec::with_capacity(value.len() / 2);
    for pair in value.as_bytes().chunks(2) {
        let hex =
            std::str::from_utf8(pair).map_err(|err| VaultStoreError::Invalid(err.to_string()))?;
        bytes.push(
            u8::from_str_radix(hex, 16).map_err(|err| VaultStoreError::Invalid(err.to_string()))?,
        );
    }
    Ok(bytes)
}

fn io_error(error: std::io::Error) -> VaultStoreError {
    VaultStoreError::Io(error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn marker_fixture() -> (PathBuf, PathBuf) {
        let root = std::env::temp_dir().join(format!("vault-key-lifecycle-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let marker = root.join("initialized");
        (root, marker)
    }

    #[test]
    fn production_backend_selection_rejects_plaintext_and_unknown_values() {
        use std::ffi::OsStr;
        assert!(validate_backend_selection(None).is_ok());
        assert!(validate_backend_selection(Some(OsStr::new("keyring"))).is_ok());
        for value in ["file", "FILE", "", "unknown"] {
            assert!(validate_backend_selection(Some(OsStr::new(value))).is_err());
        }
    }

    #[test]
    fn missing_initialized_or_historical_key_never_invokes_save() {
        let (root, marker) = marker_fixture();
        for history in [true, false] {
            if !history {
                fs::write(&marker, b"initialized").unwrap();
            }
            let result = prepare_key_version(
                &marker,
                history,
                "test",
                Err(keyring::Error::NoEntry),
                |_| panic!("must never replace an existing key"),
            );
            assert!(matches!(result, Err(VaultStoreError::KeyStorage(_))));
        }
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn failed_initial_provider_write_can_retry_before_ciphertext_exists() {
        let (root, marker) = marker_fixture();
        let failed =
            prepare_key_version(&marker, false, "test", Err(keyring::Error::NoEntry), |_| {
                assert_eq!(
                    read_key_marker(&marker).unwrap(),
                    Some(KeyMarkerState::Provisioning),
                    "retryable marker must precede provider mutation"
                );
                Err(keyring::Error::NoStorageAccess(Box::new(
                    std::io::Error::other("provider failed"),
                )))
            });
        assert!(failed.is_err());
        // No key or ciphertext was created, so a later successful provider
        // operation can safely provision this same key version.
        let mut saved = None;
        let provisioned = prepare_key_version(
            &marker,
            false,
            "test",
            Err(keyring::Error::NoEntry),
            |value| {
                saved = Some(value.to_string());
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(
            hex_string(provisioned.as_ref()),
            saved.expect("successful retry stores key")
        );
        assert_eq!(
            read_key_marker(&marker).unwrap(),
            Some(KeyMarkerState::Initialized)
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn provisioning_marker_cannot_retry_after_ciphertext_evidence() {
        let (root, marker) = marker_fixture();
        write_key_marker(&marker, KeyMarkerState::Provisioning).unwrap();
        assert!(
            prepare_key_version(
                &marker,
                true,
                "test",
                Err(keyring::Error::NoEntry),
                |_| panic!("encrypted history must prevent key replacement")
            )
            .is_err()
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn unrelated_version_markers_never_allow_missing_key_replacement() {
        for (requested_version, marker_name) in [
            (1, "v2.initialized"),
            (1, "v2.provisioning"),
            (2, "v1.initialized"),
        ] {
            let (root, _) = marker_fixture();
            let config = AppConfig {
                runtime_root: root.clone(),
                ..AppConfig::default()
            };
            let library = root.join("library");
            let vault_id = Uuid::new_v4();
            let ciphertext = library
                .join("vaults")
                .join(vault_id.to_string())
                .join("blobs/legacy/00000000.pgblob");
            fs::create_dir_all(ciphertext.parent().unwrap()).unwrap();
            fs::write(&ciphertext, b"preserve legacy ciphertext").unwrap();
            let marker = root
                .join("security/vault-key-initialization")
                .join(format!("{vault_id}-{marker_name}"));
            fs::create_dir_all(marker.parent().unwrap()).unwrap();
            fs::write(marker, b"marker for another version").unwrap();
            assert!(
                provision_vault_key_if_new(&config, &library, vault_id, requested_version, false)
                    .is_err(),
                "another version cannot prove the requested missing key is new"
            );
            assert!(load_existing_vault_key(&config, vault_id, requested_version).is_err());
            assert_eq!(fs::read(ciphertext).unwrap(), b"preserve legacy ciphertext");
            fs::remove_dir_all(root).unwrap();
        }
    }

    #[test]
    fn populated_vault_reuses_existing_key_of_another_version() {
        let (root, _) = marker_fixture();
        let config = AppConfig {
            runtime_root: root.clone(),
            ..AppConfig::default()
        };
        let library = root.join("library");
        let vault_id = Uuid::new_v4();
        fs::create_dir_all(library.join("vaults").join(vault_id.to_string())).unwrap();
        let key_path = file_key_path(&config, &key_reference(vault_id, 2));
        fs::create_dir_all(key_path.parent().unwrap()).unwrap();
        let existing_key = hex_string([42_u8; 32]);
        fs::write(&key_path, &existing_key).unwrap();
        provision_vault_key_if_new(&config, &library, vault_id, 2, false).unwrap();
        assert_eq!(
            hex_string(load_existing_vault_key(&config, vault_id, 2).unwrap()),
            existing_key
        );
        assert_eq!(fs::read_to_string(key_path).unwrap(), existing_key);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn unmarked_legacy_ciphertext_blocks_ambiguous_key_provisioning() {
        let (root, _) = marker_fixture();
        let config = AppConfig {
            runtime_root: root.clone(),
            ..AppConfig::default()
        };
        let library = root.join("library");
        let vault_id = Uuid::new_v4();
        fs::create_dir_all(library.join("vaults").join(vault_id.to_string())).unwrap();

        assert!(provision_vault_key_if_new(&config, &library, vault_id, 2, false).is_err());
        assert!(load_existing_vault_key(&config, vault_id, 2).is_err());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn new_provisioning_is_marked_and_provider_errors_do_not_initialize() {
        let (root, marker) = marker_fixture();
        let failed = prepare_key_version(
            &marker,
            false,
            "test",
            Err(keyring::Error::NoStorageAccess(Box::new(
                std::io::Error::other("locked"),
            ))),
            |_| panic!("provider reads must fail closed"),
        );
        assert!(failed.is_err());
        assert!(!marker.exists());
        let mut stored = None;
        let key = prepare_key_version(
            &marker,
            false,
            "test",
            Err(keyring::Error::NoEntry),
            |value| {
                assert_eq!(
                    read_key_marker(&marker).unwrap(),
                    Some(KeyMarkerState::Provisioning)
                );
                stored = Some(value.to_string());
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(stored.unwrap(), hex_string(key.as_ref()));
        assert_eq!(
            read_key_marker(&marker).unwrap(),
            Some(KeyMarkerState::Initialized)
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn concurrent_provisioning_reuses_one_key_version() {
        let (root, _) = marker_fixture();
        let config = AppConfig {
            runtime_root: root.clone(),
            ..AppConfig::default()
        };
        let library = root.join("library");
        let vault = Uuid::new_v4();
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
        let handles = (0..2)
            .map(|_| {
                let config = config.clone();
                let library = library.clone();
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    provision_vault_key_if_new(&config, &library, vault, 1, false).unwrap();
                    load_existing_vault_key(&config, vault, 1).unwrap()
                })
            })
            .collect::<Vec<_>>();
        let keys = handles
            .into_iter()
            .map(|handle| handle.join().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(keys[0].as_ref(), keys[1].as_ref());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn separate_runtime_roots_share_one_provider_key_creation() {
        use std::sync::{
            Arc, Barrier, Mutex,
            atomic::{AtomicUsize, Ordering},
        };
        let (root, _) = marker_fixture();
        let provider = Arc::new(Mutex::new(None::<String>));
        let writes = Arc::new(AtomicUsize::new(0));
        let ready = Arc::new(Barrier::new(2));
        let handles = (0..2)
            .map(|index| {
                let runtime = root.join(format!("runtime-{index}"));
                fs::create_dir_all(&runtime).unwrap();
                let locks = root.join("per-user-provider-locks");
                let provider = provider.clone();
                let writes = writes.clone();
                let ready = ready.clone();
                std::thread::spawn(move || {
                    ready.wait();
                    let _lock = lock_provider_key_at(&locks, "same-vault-v1").unwrap();
                    let stored = provider
                        .lock()
                        .unwrap()
                        .clone()
                        .ok_or(keyring::Error::NoEntry);
                    // Widen the absent-read/write race. The shared lock must cover
                    // both operations even though the lifecycle roots differ.
                    std::thread::sleep(std::time::Duration::from_millis(20));
                    prepare_key_version(
                        &runtime.join("initialized"),
                        false,
                        "same-vault-v1",
                        stored,
                        |value| {
                            writes.fetch_add(1, Ordering::SeqCst);
                            *provider.lock().unwrap() = Some(value.to_string());
                            Ok(())
                        },
                    )
                    .unwrap()
                })
            })
            .collect::<Vec<_>>();
        let keys = handles
            .into_iter()
            .map(|handle| handle.join().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(keys[0].as_ref(), keys[1].as_ref());
        assert_eq!(writes.load(Ordering::SeqCst), 1);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn missing_key_preserves_existing_ciphertext_and_refuses_further_seals() {
        let (root, _) = marker_fixture();
        let config = AppConfig {
            runtime_root: root.clone(),
            ..AppConfig::default()
        };
        let library = root.join("library");
        fs::create_dir_all(&library).unwrap();
        let source = root.join("source.jpg");
        fs::write(&source, b"original private bytes").unwrap();
        let (asset, _) = crate::imports::build_imported_asset(crate::domain::ImportAssetRequest {
            source_path: source.to_string_lossy().into_owned(),
            original_filename: "source.jpg".into(),
            media_kind: crate::domain::MediaKind::Photo,
            mime_type: "image/jpeg".into(),
            bytes: 22,
            captured_at: None,
            place_hint: None,
            import_mode: Some(crate::domain::ImportMode::Copy),
            content_hash: None,
        });
        let vault_id = Uuid::new_v4();
        let blob_id = Uuid::new_v4();
        provision_vault_key_if_new(&config, &library, vault_id, 1, false).unwrap();
        let sealed = seal_asset(&config, &library, vault_id, 1, blob_id, &asset, &source).unwrap();
        let chunk_path = library.join(&sealed.chunks[0].local_path);
        let before = fs::read(&chunk_path).unwrap();
        let key_path = file_key_path(&config, &key_reference(vault_id, 1));
        fs::remove_file(&key_path).unwrap();
        // Even an incorrect "no catalog history" hint cannot bypass the
        // durable marker or ciphertext-directory history.
        assert!(provision_vault_key_if_new(&config, &library, vault_id, 1, false).is_err());
        assert!(seal_asset(&config, &library, vault_id, 1, blob_id, &asset, &source).is_err());
        assert!(!key_path.exists());
        assert_eq!(fs::read(chunk_path).unwrap(), before);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn missing_keychain_entry_creates_and_persists_a_key() {
        let mut saved = None;
        let key = load_or_create_key_from_keyring(
            "vault-key:test",
            Err(keyring::Error::NoEntry),
            |value| {
                saved = Some(value.to_string());
                Ok(())
            },
        )
        .expect("missing key should be created");

        let saved = saved.expect("new key should be persisted");
        assert_eq!(saved.len(), 64);
        assert_eq!(
            decode_hex_32(&saved).expect("valid key").as_ref(),
            key.as_ref()
        );
    }

    #[test]
    fn keychain_access_error_does_not_replace_the_existing_key() {
        let mut save_called = false;
        let result = load_or_create_key_from_keyring(
            "vault-key:test",
            Err(keyring::Error::NoStorageAccess(Box::new(
                std::io::Error::other("keychain is locked"),
            ))),
            |_| {
                save_called = true;
                Ok(())
            },
        );

        assert!(matches!(result, Err(VaultStoreError::KeyStorage(_))));
        assert!(
            !save_called,
            "keychain failures must not replace vault keys"
        );
    }

    #[test]
    fn stored_key_is_returned_without_writing_a_replacement() {
        let existing = "ab".repeat(32);
        let key = load_or_create_key_from_keyring("vault-key:test", Ok(existing.clone()), |_| {
            panic!("an existing key must not be overwritten")
        })
        .expect("valid stored key");

        assert_eq!(hex_string(key.as_ref()), existing);
    }

    #[test]
    fn malformed_stored_key_fails_without_writing_a_replacement() {
        let result =
            load_or_create_key_from_keyring("vault-key:test", Ok("bad-key".to_string()), |_| {
                panic!("a malformed existing key must not be overwritten")
            });

        assert!(matches!(result, Err(VaultStoreError::Invalid(_))));
    }

    #[test]
    fn failed_keychain_write_propagates_without_returning_an_unstored_key() {
        let result =
            load_or_create_key_from_keyring("vault-key:test", Err(keyring::Error::NoEntry), |_| {
                Err(keyring::Error::NoStorageAccess(Box::new(
                    std::io::Error::other("keychain is locked"),
                )))
            });

        assert!(matches!(result, Err(VaultStoreError::KeyStorage(_))));
    }
}
