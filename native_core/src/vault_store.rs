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
    let key = load_or_create_vault_key(config, vault_id, key_version)?;
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
        let local_path = chunk.local_path.as_ref().ok_or_else(|| {
            VaultStoreError::Invalid(format!("chunk {} has no local_path", chunk.id))
        })?;
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
        let mut decrypted = cipher
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
        plaintext.append(&mut decrypted);
    }

    Ok(plaintext)
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

fn load_or_create_vault_key(
    config: &AppConfig,
    vault_id: Uuid,
    key_version: u32,
) -> Result<Zeroizing<[u8; 32]>, VaultStoreError> {
    let key_id = key_reference(vault_id, key_version);
    if cfg!(test)
        || std::env::var("PRIVATE_GALLERY_VAULT_KEY_STORAGE")
            .map(|value| value == "file")
            .unwrap_or(false)
    {
        return load_or_create_file_key(config, &key_id);
    }

    let entry = keyring::Entry::new(KEYRING_SERVICE, &key_id)
        .map_err(|err| VaultStoreError::KeyStorage(err.to_string()))?;
    match entry.get_password() {
        Ok(value) => decode_hex_32(&value),
        Err(_) => {
            let key = random_key();
            let encoded = hex_string(key.as_ref());
            entry
                .set_password(&encoded)
                .map_err(|err| VaultStoreError::KeyStorage(err.to_string()))?;
            Ok(key)
        }
    }
}

fn load_existing_vault_key(
    config: &AppConfig,
    vault_id: Uuid,
    key_version: u32,
) -> Result<Zeroizing<[u8; 32]>, VaultStoreError> {
    let key_id = key_reference(vault_id, key_version);
    if cfg!(test)
        || std::env::var("PRIVATE_GALLERY_VAULT_KEY_STORAGE")
            .map(|value| value == "file")
            .unwrap_or(false)
    {
        return load_existing_file_key(config, &key_id);
    }

    let entry = keyring::Entry::new(KEYRING_SERVICE, &key_id)
        .map_err(|err| VaultStoreError::KeyStorage(err.to_string()))?;
    match entry.get_password() {
        Ok(value) => decode_hex_32(&value),
        Err(_) => Err(VaultStoreError::KeyStorage(format!(
            "vault key {key_id} is missing"
        ))),
    }
}

fn load_or_create_file_key(
    config: &AppConfig,
    key_id: &str,
) -> Result<Zeroizing<[u8; 32]>, VaultStoreError> {
    let path = file_key_path(config, key_id);
    if path.exists() {
        let value = fs::read_to_string(path).map_err(io_error)?;
        return decode_hex_32(value.trim());
    }
    let key = random_key();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(io_error)?;
    }
    fs::write(&path, hex_string(key.as_ref())).map_err(io_error)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut permissions = fs::metadata(&path).map_err(io_error)?.permissions();
        permissions.set_mode(0o600);
        fs::set_permissions(&path, permissions).map_err(io_error)?;
    }
    Ok(key)
}

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
