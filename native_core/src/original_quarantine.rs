//! Device-local encryption for managed originals awaiting explicit vault repair.
//!
//! Quarantine objects are deliberately independent of vault membership. This module
//! stores ciphertext and key material only; callers own all authorization and metadata.

use std::{
    fs::{self, OpenOptions},
    io::{self, Read, Write},
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

use crate::config::AppConfig;

const KEYRING_SERVICE: &str = "private-gallery-vaults";
const KEY_ID_PREFIX: &str = "managed-original-quarantine:v1:";
const CHUNK_BYTES: usize = 8 * 1024 * 1024;
const AEAD_TAG_BYTES: u64 = 16;

#[derive(Debug, Error)]
pub enum QuarantineError {
    #[error("quarantine filesystem operation failed: {0}")]
    Io(String),
    #[error("quarantine key storage failed: {0}")]
    KeyStorage(String),
    #[error("quarantine encryption failed: {0}")]
    Crypto(String),
    #[error("quarantine metadata is invalid: {0}")]
    Invalid(String),
}

/// Persistable chunk descriptor. `local_path` is always relative to `library_root`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuarantineChunk {
    pub index: u32,
    pub plaintext_bytes: u64,
    pub encrypted_bytes: u64,
    pub local_path: String,
    pub nonce_hex: String,
    pub aad: String,
    pub plaintext_hash: String,
    pub encrypted_hash: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuarantinedOriginal {
    pub object_id: Uuid,
    pub asset_id: Uuid,
    pub content_hash: String,
    pub encrypted_hash: String,
    pub plaintext_bytes: u64,
    pub chunks: Vec<QuarantineChunk>,
}

/// A bounded-memory reader that validates each quarantine chunk as it is decrypted and
/// validates the complete original before reporting EOF. Consumers must discard any
/// partially written destination when `read` returns an error.
pub struct VerifiedQuarantineReader {
    cipher: ChaCha20Poly1305,
    library_root: PathBuf,
    expected_content_hash: String,
    expected_plaintext_bytes: u64,
    chunks: Vec<QuarantineChunk>,
    next_chunk: usize,
    clear: Zeroizing<Vec<u8>>,
    clear_offset: usize,
    overall_hash: Sha256,
    total_bytes: u64,
    verified: bool,
}

impl VerifiedQuarantineReader {
    pub fn open(
        config: &AppConfig,
        library_root: &Path,
        original: &QuarantinedOriginal,
    ) -> Result<Self, QuarantineError> {
        validate_hash(&original.content_hash)?;
        if original.chunks.is_empty() {
            return Err(QuarantineError::Invalid("object has no chunks".to_string()));
        }
        let mut chunks = original.chunks.clone();
        chunks.sort_by_key(|chunk| chunk.index);
        for (position, chunk) in chunks.iter().enumerate() {
            let expected_index = u32::try_from(position)
                .map_err(|_| QuarantineError::Invalid("too many chunks".to_string()))?;
            if chunk.index != expected_index {
                return Err(QuarantineError::Invalid(
                    "chunk indexes must be unique and contiguous from zero".to_string(),
                ));
            }
            if chunk.local_path
                != format!(
                    "{}/{:08}.qblob",
                    object_relative_root(original.object_id),
                    chunk.index
                )
                || chunk.aad != associated_data(original.object_id, original.asset_id, chunk.index)
                || chunk.plaintext_bytes > CHUNK_BYTES as u64
                || chunk.encrypted_bytes > CHUNK_BYTES as u64 + AEAD_TAG_BYTES
                || chunk.encrypted_bytes != chunk.plaintext_bytes.saturating_add(AEAD_TAG_BYTES)
            {
                return Err(QuarantineError::Invalid(format!(
                    "chunk {} metadata is invalid",
                    chunk.index
                )));
            }
            decode_nonce(&chunk.nonce_hex)?;
            validate_hash(&chunk.plaintext_hash)?;
            validate_hash(&chunk.encrypted_hash)?;
        }
        let key = load_existing_object_key(config, original.object_id)?;
        Ok(Self {
            cipher: ChaCha20Poly1305::new(Key::from_slice(key.as_ref())),
            library_root: library_root.to_path_buf(),
            expected_content_hash: original.content_hash.clone(),
            expected_plaintext_bytes: original.plaintext_bytes,
            chunks,
            next_chunk: 0,
            clear: Zeroizing::new(Vec::new()),
            clear_offset: 0,
            overall_hash: Sha256::new(),
            total_bytes: 0,
            verified: false,
        })
    }

    fn load_next_chunk(&mut self) -> Result<bool, QuarantineError> {
        let Some(chunk) = self.chunks.get(self.next_chunk) else {
            let actual_hash = format!("{:x}", self.overall_hash.clone().finalize());
            if self.total_bytes != self.expected_plaintext_bytes
                || !actual_hash.eq_ignore_ascii_case(&self.expected_content_hash)
            {
                return Err(QuarantineError::Invalid(format!(
                    "original hash or length mismatch (hash {actual_hash}, bytes {})",
                    self.total_bytes
                )));
            }
            self.verified = true;
            return Ok(false);
        };
        let chunk = chunk.clone();
        let path = self.library_root.join(&chunk.local_path);
        let mut file = fs::File::open(path).map_err(io_error)?;
        let mut ciphertext = Vec::with_capacity(chunk.encrypted_bytes as usize);
        Read::by_ref(&mut file)
            .take(CHUNK_BYTES as u64 + AEAD_TAG_BYTES + 1)
            .read_to_end(&mut ciphertext)
            .map_err(io_error)?;
        if ciphertext.len() as u64 != chunk.encrypted_bytes
            || sha256_hex(&ciphertext) != chunk.encrypted_hash
        {
            return Err(QuarantineError::Invalid(format!(
                "chunk {} ciphertext size or hash mismatch",
                chunk.index
            )));
        }
        let nonce = decode_nonce(&chunk.nonce_hex)?;
        let clear = Zeroizing::new(
            self.cipher
                .decrypt(
                    Nonce::from_slice(&nonce),
                    chacha20poly1305::aead::Payload {
                        msg: &ciphertext,
                        aad: chunk.aad.as_bytes(),
                    },
                )
                .map_err(|error| QuarantineError::Crypto(error.to_string()))?,
        );
        if clear.len() as u64 != chunk.plaintext_bytes || sha256_hex(&clear) != chunk.plaintext_hash
        {
            return Err(QuarantineError::Invalid(format!(
                "chunk {} plaintext size or hash mismatch",
                chunk.index
            )));
        }
        self.total_bytes = self
            .total_bytes
            .checked_add(clear.len() as u64)
            .ok_or_else(|| QuarantineError::Invalid("original size overflow".to_string()))?;
        self.overall_hash.update(&clear);
        self.clear = clear;
        self.clear_offset = 0;
        self.next_chunk += 1;
        Ok(true)
    }
}

impl Read for VerifiedQuarantineReader {
    fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
        if output.is_empty() {
            return Ok(0);
        }
        if self.clear_offset == self.clear.len() && !self.verified {
            self.clear.clear();
            self.clear_offset = 0;
            match self.load_next_chunk().map_err(quarantine_io_error)? {
                true => {}
                false => return Ok(0),
            }
        }
        if self.verified {
            return Ok(0);
        }
        let count = output.len().min(self.clear.len() - self.clear_offset);
        output[..count].copy_from_slice(&self.clear[self.clear_offset..self.clear_offset + count]);
        self.clear_offset += count;
        Ok(count)
    }
}

fn quarantine_io_error(error: QuarantineError) -> io::Error {
    io::Error::other(error)
}

struct OriginalVerification<'a> {
    object_id: Uuid,
    asset_id: Uuid,
    content_hash: &'a str,
    plaintext_bytes: u64,
    chunks: &'a [QuarantineChunk],
}

/// Encrypt a source original into an atomically-published, library-local quarantine object.
///
/// The expected SHA-256 is checked while reading the same byte stream that is encrypted.
/// A mismatch, IO error, or crypto error removes the unique staging directory. Existing
/// objects are never overwritten.
pub fn seal_managed_original(
    config: &AppConfig,
    library_root: &Path,
    object_id: Uuid,
    asset_id: Uuid,
    source_path: &Path,
    expected_content_hash: &str,
) -> Result<QuarantinedOriginal, QuarantineError> {
    validate_hash(expected_content_hash)?;
    let key = load_or_create_object_key(config, object_id)?;
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key.as_ref()));

    let quarantine_root = library_root.join("quarantine").join("managed-originals");
    create_durable_dir_all(&quarantine_root)?;
    set_private_dir_permissions(&library_root.join("quarantine"))?;
    set_private_dir_permissions(&quarantine_root)?;
    let stage_root = quarantine_root.join(format!(".staging-{}", Uuid::new_v4()));
    create_private_directory(&stage_root)?;
    let mut stage_guard = StageGuard(Some(stage_root.clone()));

    let mut source = fs::File::open(source_path).map_err(io_error)?;
    let mut chunks = Vec::new();
    let mut overall_hash = Sha256::new();
    let mut total_bytes = 0_u64;
    let mut buffer = Zeroizing::new(vec![0_u8; CHUNK_BYTES]);

    loop {
        let read = source.read(buffer.as_mut_slice()).map_err(io_error)?;
        if read == 0 {
            break;
        }
        let index = u32::try_from(chunks.len())
            .map_err(|_| QuarantineError::Invalid("too many chunks".to_string()))?;
        let plaintext = &buffer[..read];
        overall_hash.update(plaintext);
        total_bytes = total_bytes
            .checked_add(read as u64)
            .ok_or_else(|| QuarantineError::Invalid("original size overflow".to_string()))?;
        chunks.push(encrypt_chunk(
            &cipher,
            &stage_root,
            object_id,
            asset_id,
            index,
            plaintext,
        )?);
    }

    if chunks.is_empty() {
        chunks.push(encrypt_chunk(
            &cipher,
            &stage_root,
            object_id,
            asset_id,
            0,
            &[],
        )?);
    }

    let content_hash = format!("{:x}", overall_hash.finalize());
    if !content_hash.eq_ignore_ascii_case(expected_content_hash) {
        return Err(QuarantineError::Invalid(format!(
            "source content hash mismatch: expected {expected_content_hash}, got {content_hash}"
        )));
    }

    let final_root = object_root(library_root, object_id);
    if final_root.exists() {
        return Err(QuarantineError::Invalid(format!(
            "quarantine object {object_id} already exists"
        )));
    }
    sync_directory(&stage_root)?;
    publish_directory(&stage_root, &final_root)?;
    sync_directory(&quarantine_root)?;
    stage_guard.0 = None;

    let prefix = object_relative_root(object_id);
    for chunk in &mut chunks {
        chunk.local_path = format!("{prefix}/{:08}.qblob", chunk.index);
    }
    Ok(QuarantinedOriginal {
        object_id,
        asset_id,
        content_hash,
        encrypted_hash: combined_encrypted_hash(&chunks),
        plaintext_bytes: total_bytes,
        chunks,
    })
}

/// Decrypt and verify a quarantined original in memory.
///
/// All descriptor paths must point to the exact expected object/chunk location; indexes,
/// ciphertext hashes/sizes, per-chunk plaintext hashes/sizes, and the overall hash/length
/// are checked before bytes are returned.
#[cfg(test)]
pub fn decrypt_managed_original(
    config: &AppConfig,
    library_root: &Path,
    object_id: Uuid,
    asset_id: Uuid,
    expected_content_hash: &str,
    expected_plaintext_bytes: u64,
    chunks: &[QuarantineChunk],
) -> Result<Vec<u8>, QuarantineError> {
    let mut plaintext = Vec::new();
    decrypt_managed_original_to_writer(
        config,
        library_root,
        OriginalVerification {
            object_id,
            asset_id,
            content_hash: expected_content_hash,
            plaintext_bytes: expected_plaintext_bytes,
            chunks,
        },
        &mut plaintext,
    )?;
    Ok(plaintext)
}

/// Verify a quarantined original without ever creating a plaintext file.
pub fn verify_managed_original(
    config: &AppConfig,
    library_root: &Path,
    object_id: Uuid,
    asset_id: Uuid,
    expected_content_hash: &str,
    expected_plaintext_bytes: u64,
    chunks: &[QuarantineChunk],
) -> Result<(), QuarantineError> {
    decrypt_managed_original_to_writer(
        config,
        library_root,
        OriginalVerification {
            object_id,
            asset_id,
            content_hash: expected_content_hash,
            plaintext_bytes: expected_plaintext_bytes,
            chunks,
        },
        &mut std::io::sink(),
    )
}

/// Decrypt an original into a private, create-new staging file and verify it before
/// returning. The caller must remove the plaintext file on every exit path.
pub fn restore_managed_original_to_file(
    config: &AppConfig,
    library_root: &Path,
    original: &QuarantinedOriginal,
    destination: &Path,
) -> Result<(), QuarantineError> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    set_private_file_options(&mut options);
    let mut file = options.open(destination).map_err(io_error)?;
    if let Err(error) = set_private_file_permissions(destination) {
        drop(file);
        let _ = fs::remove_file(destination);
        return Err(error);
    }
    let result = decrypt_managed_original_to_writer(
        config,
        library_root,
        OriginalVerification {
            object_id: original.object_id,
            asset_id: original.asset_id,
            content_hash: &original.content_hash,
            plaintext_bytes: original.plaintext_bytes,
            chunks: &original.chunks,
        },
        &mut file,
    );
    if let Err(error) = result {
        drop(file);
        let _ = fs::remove_file(destination);
        return Err(error);
    }
    if let Err(error) = file.sync_all() {
        drop(file);
        let _ = fs::remove_file(destination);
        return Err(io_error(error));
    }
    Ok(())
}

/// Remove the device-local key only after the caller has verified and durably
/// installed the repaired vault copy.
pub fn retire_managed_original_key(
    config: &AppConfig,
    object_id: Uuid,
) -> Result<(), QuarantineError> {
    let key_id = format!("{KEY_ID_PREFIX}{object_id}");
    if file_key_override() {
        match fs::remove_file(file_key_path(config, &key_id)) {
            Ok(()) => return Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(error) => return Err(io_error(error)),
        }
    }
    let entry = keyring::Entry::new(KEYRING_SERVICE, &key_id)
        .map_err(|error| QuarantineError::KeyStorage(error.to_string()))?;
    match entry.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(error) => Err(QuarantineError::KeyStorage(error.to_string())),
    }
}

fn decrypt_managed_original_to_writer<W: Write>(
    config: &AppConfig,
    library_root: &Path,
    verification: OriginalVerification<'_>,
    output: &mut W,
) -> Result<(), QuarantineError> {
    let OriginalVerification {
        object_id,
        asset_id,
        content_hash: expected_content_hash,
        plaintext_bytes: expected_plaintext_bytes,
        chunks,
    } = verification;
    validate_hash(expected_content_hash)?;
    if chunks.is_empty() {
        return Err(QuarantineError::Invalid("object has no chunks".to_string()));
    }
    let key = load_existing_object_key(config, object_id)?;
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key.as_ref()));
    let mut sorted = chunks.to_vec();
    sorted.sort_by_key(|chunk| chunk.index);
    let mut overall_hash = Sha256::new();
    let mut total_bytes = 0_u64;

    for (position, chunk) in sorted.iter().enumerate() {
        let expected_index = u32::try_from(position)
            .map_err(|_| QuarantineError::Invalid("too many chunks".to_string()))?;
        if chunk.index != expected_index {
            return Err(QuarantineError::Invalid(
                "chunk indexes must be unique and contiguous from zero".to_string(),
            ));
        }
        let expected_path = format!(
            "{}/{:08}.qblob",
            object_relative_root(object_id),
            chunk.index
        );
        if chunk.local_path != expected_path {
            return Err(QuarantineError::Invalid(format!(
                "chunk {} has an unexpected local path",
                chunk.index
            )));
        }
        let expected_aad = associated_data(object_id, asset_id, chunk.index);
        if chunk.aad != expected_aad {
            return Err(QuarantineError::Invalid(format!(
                "chunk {} associated data mismatch",
                chunk.index
            )));
        }
        if chunk.plaintext_bytes > CHUNK_BYTES as u64
            || chunk.encrypted_bytes > CHUNK_BYTES as u64 + AEAD_TAG_BYTES
            || chunk.encrypted_bytes != chunk.plaintext_bytes.saturating_add(AEAD_TAG_BYTES)
        {
            return Err(QuarantineError::Invalid(format!(
                "chunk {} exceeds supported size bounds",
                chunk.index
            )));
        }
        let chunk_path = library_root.join(&chunk.local_path);
        let mut file = fs::File::open(&chunk_path).map_err(io_error)?;
        let mut ciphertext = Vec::with_capacity(chunk.encrypted_bytes as usize);
        Read::by_ref(&mut file)
            .take(CHUNK_BYTES as u64 + AEAD_TAG_BYTES + 1)
            .read_to_end(&mut ciphertext)
            .map_err(io_error)?;
        if ciphertext.len() as u64 > CHUNK_BYTES as u64 + AEAD_TAG_BYTES {
            return Err(QuarantineError::Invalid(format!(
                "chunk {} exceeds supported size bounds",
                chunk.index
            )));
        }
        if ciphertext.len() as u64 != chunk.encrypted_bytes
            || sha256_hex(&ciphertext) != chunk.encrypted_hash
        {
            return Err(QuarantineError::Invalid(format!(
                "chunk {} ciphertext size or hash mismatch",
                chunk.index
            )));
        }
        let nonce = decode_nonce(&chunk.nonce_hex)?;
        let clear = Zeroizing::new(
            cipher
                .decrypt(
                    Nonce::from_slice(&nonce),
                    chacha20poly1305::aead::Payload {
                        msg: &ciphertext,
                        aad: chunk.aad.as_bytes(),
                    },
                )
                .map_err(|error| QuarantineError::Crypto(error.to_string()))?,
        );
        if clear.len() as u64 != chunk.plaintext_bytes || sha256_hex(&clear) != chunk.plaintext_hash
        {
            return Err(QuarantineError::Invalid(format!(
                "chunk {} plaintext size or hash mismatch",
                chunk.index
            )));
        }
        total_bytes = total_bytes
            .checked_add(clear.len() as u64)
            .ok_or_else(|| QuarantineError::Invalid("original size overflow".to_string()))?;
        overall_hash.update(&clear);
        output.write_all(&clear).map_err(io_error)?;
    }

    let actual_hash = format!("{:x}", overall_hash.finalize());
    if total_bytes != expected_plaintext_bytes
        || !actual_hash.eq_ignore_ascii_case(expected_content_hash)
    {
        return Err(QuarantineError::Invalid(format!(
            "original hash or length mismatch (hash {actual_hash}, bytes {total_bytes})"
        )));
    }
    Ok(())
}

fn encrypt_chunk(
    cipher: &ChaCha20Poly1305,
    stage_root: &Path,
    object_id: Uuid,
    asset_id: Uuid,
    index: u32,
    plaintext: &[u8],
) -> Result<QuarantineChunk, QuarantineError> {
    let mut nonce = [0_u8; 12];
    OsRng.fill_bytes(&mut nonce);
    let aad = associated_data(object_id, asset_id, index);
    let ciphertext = cipher
        .encrypt(
            Nonce::from_slice(&nonce),
            chacha20poly1305::aead::Payload {
                msg: plaintext,
                aad: aad.as_bytes(),
            },
        )
        .map_err(|error| QuarantineError::Crypto(error.to_string()))?;
    let stage_path = stage_root.join(format!("{index:08}.qblob"));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    set_private_file_options(&mut options);
    let mut file = options.open(&stage_path).map_err(io_error)?;
    set_private_file_permissions(&stage_path)?;
    file.write_all(&ciphertext).map_err(io_error)?;
    file.sync_all().map_err(io_error)?;
    Ok(QuarantineChunk {
        index,
        plaintext_bytes: plaintext.len() as u64,
        encrypted_bytes: ciphertext.len() as u64,
        local_path: String::new(),
        nonce_hex: hex_string(nonce),
        aad,
        plaintext_hash: sha256_hex(plaintext),
        encrypted_hash: sha256_hex(&ciphertext),
    })
}

fn load_or_create_object_key(
    config: &AppConfig,
    object_id: Uuid,
) -> Result<Zeroizing<[u8; 32]>, QuarantineError> {
    let key_id = format!("{KEY_ID_PREFIX}{object_id}");
    if file_key_override() {
        return load_or_create_file_key(config, &key_id);
    }
    let entry = keyring::Entry::new(KEYRING_SERVICE, &key_id)
        .map_err(|error| QuarantineError::KeyStorage(error.to_string()))?;
    match entry.get_password() {
        Ok(value) => decode_key(&value),
        Err(keyring::Error::NoEntry) => {
            let key = random_key();
            entry
                .set_password(&hex_string(key.as_ref()))
                .map_err(|error| QuarantineError::KeyStorage(error.to_string()))?;
            Ok(key)
        }
        Err(error) => Err(QuarantineError::KeyStorage(error.to_string())),
    }
}

fn load_existing_object_key(
    config: &AppConfig,
    object_id: Uuid,
) -> Result<Zeroizing<[u8; 32]>, QuarantineError> {
    let key_id = format!("{KEY_ID_PREFIX}{object_id}");
    if file_key_override() {
        let path = file_key_path(config, &key_id);
        let value = fs::read_to_string(path).map_err(io_error)?;
        return decode_key(value.trim());
    }
    let entry = keyring::Entry::new(KEYRING_SERVICE, &key_id)
        .map_err(|error| QuarantineError::KeyStorage(error.to_string()))?;
    let value = entry
        .get_password()
        .map_err(|error| QuarantineError::KeyStorage(error.to_string()))?;
    decode_key(&value)
}

fn load_or_create_file_key(
    config: &AppConfig,
    key_id: &str,
) -> Result<Zeroizing<[u8; 32]>, QuarantineError> {
    let path = file_key_path(config, key_id);
    match fs::read_to_string(&path) {
        Ok(value) => return decode_key(value.trim()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(io_error(error)),
    }
    let key = random_key();
    let parent = path
        .parent()
        .ok_or_else(|| QuarantineError::Io("key path has no parent".to_string()))?;
    fs::create_dir_all(parent).map_err(io_error)?;
    set_private_dir_permissions(parent)?;
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    set_private_file_options(&mut options);
    let mut file = options.open(&path).map_err(io_error)?;
    file.write_all(hex_string(key.as_ref()).as_bytes())
        .map_err(io_error)?;
    file.sync_all().map_err(io_error)?;
    set_private_file_permissions(&path)?;
    Ok(key)
}

fn file_key_path(config: &AppConfig, key_id: &str) -> PathBuf {
    config
        .runtime_root
        .join("security")
        .join("quarantine-keys")
        .join(format!("{key_id}.key"))
}

fn file_key_override() -> bool {
    cfg!(test)
        || (cfg!(unix)
            && std::env::var("PRIVATE_GALLERY_VAULT_KEY_STORAGE")
                .map(|value| value == "file")
                .unwrap_or(false))
}

fn object_root(library_root: &Path, object_id: Uuid) -> PathBuf {
    library_root.join(object_relative_root(object_id))
}

fn object_relative_root(object_id: Uuid) -> String {
    format!("quarantine/managed-originals/{object_id}")
}

fn associated_data(object_id: Uuid, asset_id: Uuid, index: u32) -> String {
    format!(
        "photo-organizer:managed-original-quarantine:v1:object:{object_id}:asset:{asset_id}:chunk:{index}"
    )
}

fn combined_encrypted_hash(chunks: &[QuarantineChunk]) -> String {
    let mut hasher = Sha256::new();
    for chunk in chunks {
        hasher.update(chunk.encrypted_hash.as_bytes());
    }
    format!("{:x}", hasher.finalize())
}

fn validate_hash(value: &str) -> Result<(), QuarantineError> {
    if value.len() != 64 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(QuarantineError::Invalid(
            "expected a 64-character SHA-256 hex digest".to_string(),
        ));
    }
    Ok(())
}

fn decode_key(value: &str) -> Result<Zeroizing<[u8; 32]>, QuarantineError> {
    let bytes = decode_hex(value)?;
    let array: [u8; 32] = bytes
        .try_into()
        .map_err(|_| QuarantineError::Invalid("expected 32-byte key".to_string()))?;
    Ok(Zeroizing::new(array))
}

fn random_key() -> Zeroizing<[u8; 32]> {
    let mut key = Zeroizing::new([0_u8; 32]);
    OsRng.fill_bytes(key.as_mut());
    key
}

fn decode_nonce(value: &str) -> Result<[u8; 12], QuarantineError> {
    let bytes = decode_hex(value)?;
    bytes
        .try_into()
        .map_err(|_| QuarantineError::Invalid("expected 12-byte nonce".to_string()))
}

fn decode_hex(value: &str) -> Result<Vec<u8>, QuarantineError> {
    let (chunks, remainder) = value.as_bytes().as_chunks::<2>();
    if !remainder.is_empty() {
        return Err(QuarantineError::Invalid("odd-length hex value".to_string()));
    }
    chunks
        .iter()
        .map(|pair| {
            let pair = std::str::from_utf8(pair)
                .map_err(|error| QuarantineError::Invalid(error.to_string()))?;
            u8::from_str_radix(pair, 16)
                .map_err(|error| QuarantineError::Invalid(error.to_string()))
        })
        .collect()
}

fn hex_string(bytes: impl AsRef<[u8]>) -> String {
    bytes
        .as_ref()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn sha256_hex(bytes: impl AsRef<[u8]>) -> String {
    format!("{:x}", Sha256::digest(bytes.as_ref()))
}

fn io_error(error: std::io::Error) -> QuarantineError {
    QuarantineError::Io(error.to_string())
}

#[cfg(unix)]
fn set_private_dir_permissions(path: &Path) -> Result<(), QuarantineError> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(io_error)
}

#[cfg(unix)]
fn create_private_directory(path: &Path) -> Result<(), QuarantineError> {
    use std::os::unix::fs::DirBuilderExt;
    let mut builder = fs::DirBuilder::new();
    builder.mode(0o700);
    builder.create(path).map_err(io_error)
}

#[cfg(not(unix))]
fn create_private_directory(path: &Path) -> Result<(), QuarantineError> {
    fs::create_dir(path).map_err(io_error)
}

#[cfg(not(unix))]
fn set_private_dir_permissions(_path: &Path) -> Result<(), QuarantineError> {
    Ok(())
}

#[cfg(unix)]
fn set_private_file_permissions(path: &Path) -> Result<(), QuarantineError> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).map_err(io_error)
}

#[cfg(not(unix))]
fn set_private_file_permissions(_path: &Path) -> Result<(), QuarantineError> {
    Ok(())
}

#[cfg(unix)]
fn set_private_file_options(options: &mut OpenOptions) {
    use std::os::unix::fs::OpenOptionsExt;
    options.mode(0o600);
}

#[cfg(not(unix))]
fn set_private_file_options(_options: &mut OpenOptions) {}

#[cfg(unix)]
fn sync_directory(path: &Path) -> Result<(), QuarantineError> {
    fs::File::open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(io_error)
}

fn create_durable_dir_all(path: &Path) -> Result<(), QuarantineError> {
    let mut missing = Vec::new();
    let mut current = path;
    while !current.exists() {
        missing.push(current.to_path_buf());
        current = current
            .parent()
            .ok_or_else(|| QuarantineError::Io("directory path has no parent".to_string()))?;
    }
    fs::create_dir_all(path).map_err(io_error)?;
    for created in missing.into_iter().rev() {
        if let Some(parent) = created.parent() {
            sync_directory(parent)?;
        }
        sync_directory(&created)?;
    }
    Ok(())
}

#[cfg(windows)]
fn sync_directory(_path: &Path) -> Result<(), QuarantineError> {
    // MoveFileExW with MOVEFILE_WRITE_THROUGH durably publishes the directory entry.
    Ok(())
}

fn publish_directory(stage: &Path, destination: &Path) -> Result<(), QuarantineError> {
    // Reserving the object directory with create_dir gives no-replace semantics
    // on every supported filesystem. Metadata is not persisted until every
    // encrypted chunk is moved and the completed directory is made durable.
    create_private_directory(destination)?;
    if let Some(parent) = destination.parent() {
        sync_directory(parent)?;
    }
    let result = (|| {
        for entry in fs::read_dir(stage).map_err(io_error)? {
            let entry = entry.map_err(io_error)?;
            let name = entry.file_name();
            let destination_chunk = destination.join(name);
            publish_file(&entry.path(), &destination_chunk)?;
        }
        sync_directory(destination)?;
        Ok(())
    })();
    if let Err(error) = result {
        let _ = fs::remove_dir_all(destination);
        return Err(error);
    }
    fs::remove_dir(stage).map_err(io_error)?;
    if let Some(parent) = destination.parent() {
        sync_directory(parent)?;
    }
    Ok(())
}

#[cfg(not(windows))]
fn publish_file(stage: &Path, destination: &Path) -> Result<(), QuarantineError> {
    fs::rename(stage, destination).map_err(io_error)
}

#[cfg(windows)]
fn publish_file(stage: &Path, destination: &Path) -> Result<(), QuarantineError> {
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        let stage: Vec<u16> = stage.as_os_str().encode_wide().chain(Some(0)).collect();
        let destination: Vec<u16> = destination
            .as_os_str()
            .encode_wide()
            .chain(Some(0))
            .collect();
        let moved = unsafe {
            windows_sys::Win32::Storage::FileSystem::MoveFileExW(
                stage.as_ptr(),
                destination.as_ptr(),
                windows_sys::Win32::Storage::FileSystem::MOVEFILE_WRITE_THROUGH,
            )
        };
        if moved == 0 {
            return Err(io_error(std::io::Error::last_os_error()));
        }
        Ok(())
    }
}

struct StageGuard(Option<PathBuf>);

impl Drop for StageGuard {
    fn drop(&mut self) {
        if let Some(path) = self.0.take() {
            if path.is_dir() {
                let _ = fs::remove_dir_all(path);
            } else {
                let _ = fs::remove_file(path);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_root(label: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "photo-organizer-quarantine-{label}-{}",
            Uuid::new_v4()
        ))
    }

    fn test_config(root: &Path) -> AppConfig {
        AppConfig {
            runtime_root: root.join("runtime"),
            ..AppConfig::default()
        }
    }

    fn hash(bytes: &[u8]) -> String {
        sha256_hex(bytes)
    }

    #[test]
    fn seals_and_decrypts_without_a_vault_association() {
        let root = test_root("roundtrip");
        let library = root.join("library");
        fs::create_dir_all(&library).expect("library root");
        let source = root.join("original.jpg");
        let bytes = b"original bytes stay encrypted in quarantine";
        fs::write(&source, bytes).expect("write source");
        let config = test_config(&root);
        let object_id = Uuid::new_v4();
        let asset_id = Uuid::new_v4();

        let sealed = seal_managed_original(
            &config,
            &library,
            object_id,
            asset_id,
            &source,
            &hash(bytes),
        )
        .expect("seal source");
        assert_eq!(sealed.plaintext_bytes, bytes.len() as u64);
        assert!(sealed.chunks.iter().all(|chunk| {
            let path = library.join(&chunk.local_path);
            path.is_file() && fs::read(path).expect("ciphertext").as_slice() != bytes
        }));
        let restored = decrypt_managed_original(
            &config,
            &library,
            object_id,
            asset_id,
            &hash(bytes),
            bytes.len() as u64,
            &sealed.chunks,
        )
        .expect("decrypt");
        assert_eq!(restored, bytes);
        fs::remove_dir_all(root).expect("cleanup test root");
    }

    #[test]
    fn quarantine_remains_verifiable_after_library_relocation_on_the_same_device() {
        let root = test_root("relocation");
        let library = root.join("library-before");
        let relocated_library = root.join("library-after");
        fs::create_dir_all(&library).expect("library root");
        fs::create_dir_all(&relocated_library).expect("relocated library root");
        let source = root.join("original.jpg");
        let bytes = b"device-local quarantine follows its object identity";
        fs::write(&source, bytes).expect("write source");
        let config = test_config(&root);
        let object_id = Uuid::new_v4();
        let asset_id = Uuid::new_v4();
        let sealed = seal_managed_original(
            &config,
            &library,
            object_id,
            asset_id,
            &source,
            &hash(bytes),
        )
        .expect("seal source");

        fs::rename(
            library.join("quarantine"),
            relocated_library.join("quarantine"),
        )
        .expect("relocate quarantine files");
        verify_managed_original(
            &config,
            &relocated_library,
            object_id,
            asset_id,
            &hash(bytes),
            bytes.len() as u64,
            &sealed.chunks,
        )
        .expect("verify relocated quarantine");
        fs::remove_dir_all(root).expect("cleanup test root");
    }

    #[test]
    fn hash_mismatch_cleans_staging_and_publishes_nothing() {
        let root = test_root("hash-mismatch");
        let library = root.join("library");
        fs::create_dir_all(&library).expect("library root");
        let source = root.join("original.jpg");
        fs::write(&source, b"actual bytes").expect("write source");
        let result = seal_managed_original(
            &test_config(&root),
            &library,
            Uuid::new_v4(),
            Uuid::new_v4(),
            &source,
            &hash(b"different bytes"),
        );
        assert!(matches!(result, Err(QuarantineError::Invalid(_))));
        let quarantine = library.join("quarantine/managed-originals");
        assert_eq!(fs::read_dir(quarantine).expect("staging dir").count(), 0);
        fs::remove_dir_all(root).expect("cleanup test root");
    }

    #[test]
    fn decrypt_rejects_wrong_expected_length() {
        let root = test_root("wrong-length");
        let library = root.join("library");
        fs::create_dir_all(&library).expect("library root");
        let source = root.join("original.jpg");
        let bytes = b"verified length";
        fs::write(&source, bytes).expect("write source");
        let config = test_config(&root);
        let object_id = Uuid::new_v4();
        let asset_id = Uuid::new_v4();
        let sealed = seal_managed_original(
            &config,
            &library,
            object_id,
            asset_id,
            &source,
            &hash(bytes),
        )
        .expect("seal");
        let result = decrypt_managed_original(
            &config,
            &library,
            object_id,
            asset_id,
            &hash(bytes),
            bytes.len() as u64 + 1,
            &sealed.chunks,
        );
        assert!(matches!(result, Err(QuarantineError::Invalid(_))));
        fs::remove_dir_all(root).expect("cleanup test root");
    }

    #[test]
    fn verifier_rejects_oversized_persisted_chunk_metadata_before_reading() {
        let root = test_root("oversized-chunk");
        let library = root.join("library");
        fs::create_dir_all(&library).expect("library root");
        let source = root.join("original.jpg");
        let bytes = b"small source";
        fs::write(&source, bytes).expect("write source");
        let config = test_config(&root);
        let object_id = Uuid::new_v4();
        let asset_id = Uuid::new_v4();
        let mut sealed = seal_managed_original(
            &config,
            &library,
            object_id,
            asset_id,
            &source,
            &hash(bytes),
        )
        .expect("seal");
        sealed.chunks[0].encrypted_bytes = u64::MAX;
        let result = verify_managed_original(
            &config,
            &library,
            object_id,
            asset_id,
            &hash(bytes),
            bytes.len() as u64,
            &sealed.chunks,
        );
        assert!(matches!(result, Err(QuarantineError::Invalid(_))));
        fs::remove_dir_all(root).expect("cleanup test root");
    }
}
