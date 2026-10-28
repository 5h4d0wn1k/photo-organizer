//! Authenticated, bounded, passphrase-protected portable recovery key material.
//! Callers must run the synchronous KDF on a blocking worker. This module does
//! not read credentials, install keys, access the network, or activate libraries.
//! The caller supplies the canonical full manifest digest, excluding only the
//! recovery envelope itself, so payload names, kinds, hashes and catalog binding
//! are authenticated together rather than trusting an unsigned file inventory.
use std::{
    collections::{BTreeMap, BTreeSet},
    fmt,
    sync::Mutex,
};

use argon2::{Algorithm, Argon2, Params, Version};
use chacha20poly1305::{
    ChaCha20Poly1305, Key, Nonce,
    aead::{AeadInPlace, KeyInit, OsRng, rand_core::RngCore},
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
use zeroize::Zeroizing;

use crate::recovery_inventory::{RecoveryKeyInventory, RequiredRecoveryKey};

const VERSION: u32 = 1;
const KDF_PROFILE: &str = "argon2id-v19-m262144-t3-p1";
const MAX_KEYS: usize = 4096;
const MAX_IDENTITY_BYTES: usize = 1024;
const MAX_PLAINTEXT_BYTES: usize = 4 + MAX_KEYS * (4 + MAX_IDENTITY_BYTES + 32);
const MAX_CIPHERTEXT_BYTES: usize = MAX_PLAINTEXT_BYTES + 16;
// The 256 MiB production profile must never be multiplied by concurrent callers.
static KDF_LOCK: Mutex<()> = Mutex::new(());

pub(crate) struct KeyMaterial {
    pub(crate) identity: RequiredRecoveryKey,
    pub(crate) key: Zeroizing<[u8; 32]>,
}

impl fmt::Debug for KeyMaterial {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("KeyMaterial")
            .field("identity", &self.identity)
            .field("key", &"[REDACTED]")
            .finish()
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RecoveryEnvelope {
    pub(crate) version: u32,
    pub(crate) kdf_profile: String,
    pub(crate) salt_hex: String,
    pub(crate) nonce_hex: String,
    pub(crate) backup_sha256: String,
    pub(crate) inventory_sha256: String,
    pub(crate) ciphertext_hex: String,
}

impl fmt::Debug for RecoveryEnvelope {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RecoveryEnvelope")
            .field("version", &self.version)
            .field("kdf_profile", &self.kdf_profile)
            .field("ciphertext", &"[REDACTED]")
            .finish_non_exhaustive()
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
pub(crate) enum RecoveryBundleError {
    #[error("recovery passphrase must contain 16 to 1024 UTF-8 bytes")]
    Passphrase,
    #[error("recovery key inventory is invalid or unsupported")]
    Inventory,
    #[error("recovery envelope is invalid or unsupported")]
    Envelope,
    #[error("recovery envelope does not match this backup")]
    Binding,
    #[error("recovery passphrase or authenticated backup material is incorrect")]
    Authentication,
    #[error("recovery key derivation is unavailable")]
    Derivation,
}

/// Structural and public commitment checks only. This does not authenticate the
/// envelope or establish that a passphrase is correct; only unwrap can do so.
pub(crate) fn validate_envelope(
    envelope: &RecoveryEnvelope,
    inventory: &RecoveryKeyInventory,
    backup_sha256: &str,
) -> Result<(), RecoveryBundleError> {
    let inventory_bytes = canonical_inventory(inventory)?;
    if envelope.version != VERSION || envelope.kdf_profile != KDF_PROFILE {
        return Err(RecoveryBundleError::Envelope);
    }
    if !valid_hex(&envelope.salt_hex, 16)
        || !valid_hex(&envelope.nonce_hex, 12)
        || !valid_hex(&envelope.backup_sha256, 32)
        || !valid_hex(&envelope.inventory_sha256, 32)
        || envelope.ciphertext_hex.len() < 2 * (4 + 16)
        || envelope.ciphertext_hex.len() > 2 * MAX_CIPHERTEXT_BYTES
        || !envelope.ciphertext_hex.len().is_multiple_of(2)
        || !envelope
            .ciphertext_hex
            .bytes()
            .all(|b| b.is_ascii_hexdigit())
    {
        return Err(RecoveryBundleError::Envelope);
    }
    if !valid_hex(backup_sha256, 32)
        || envelope.backup_sha256 != backup_sha256
        || envelope.inventory_sha256 != hex(&Sha256::digest(&inventory_bytes))
    {
        return Err(RecoveryBundleError::Binding);
    }
    Ok(())
}

pub(crate) fn wrap(
    keys: &[KeyMaterial],
    passphrase: &str,
    backup_sha256: &str,
    inventory: &RecoveryKeyInventory,
) -> Result<RecoveryEnvelope, RecoveryBundleError> {
    validate_passphrase(passphrase)?;
    let inventory_bytes = canonical_inventory(inventory)?;
    if !valid_hex(backup_sha256, 32) {
        return Err(RecoveryBundleError::Binding);
    }
    let mut sorted = BTreeMap::new();
    for key in keys {
        if sorted.insert(&key.identity, &key.key).is_some() {
            return Err(RecoveryBundleError::Inventory);
        }
    }
    if sorted.len() != inventory.required_keys.len()
        || sorted.keys().copied().ne(inventory.required_keys.iter())
    {
        return Err(RecoveryBundleError::Inventory);
    }
    // Determine the complete allocation before appending any secret bytes.
    // Zeroizing the final Vec cannot erase freed allocations from Vec growth.
    // Include the AEAD tag so encryption also cannot reallocate this buffer.
    let mut encoded = Vec::with_capacity(sorted.len());
    let mut payload_length = 4_usize;
    for (identity, key) in sorted {
        let identity_bytes =
            serde_json::to_vec(identity).map_err(|_| RecoveryBundleError::Inventory)?;
        if identity_bytes.len() > MAX_IDENTITY_BYTES {
            return Err(RecoveryBundleError::Inventory);
        }
        payload_length = payload_length
            .checked_add(4 + identity_bytes.len() + 32)
            .filter(|length| *length <= MAX_PLAINTEXT_BYTES)
            .ok_or(RecoveryBundleError::Inventory)?;
        encoded.push((identity_bytes, key));
    }
    let mut plaintext = Zeroizing::new(Vec::with_capacity(payload_length + 16));
    plaintext.extend_from_slice(&(keys.len() as u32).to_le_bytes());
    for (identity_bytes, key) in encoded {
        plaintext.extend_from_slice(&(identity_bytes.len() as u32).to_le_bytes());
        plaintext.extend_from_slice(&identity_bytes);
        plaintext.extend_from_slice(key.as_ref());
    }
    let mut salt = [0_u8; 16];
    let mut nonce = [0_u8; 12];
    OsRng.fill_bytes(&mut salt);
    OsRng.fill_bytes(&mut nonce);
    let mut envelope = RecoveryEnvelope {
        version: VERSION,
        kdf_profile: KDF_PROFILE.into(),
        salt_hex: hex(&salt),
        nonce_hex: hex(&nonce),
        backup_sha256: backup_sha256.into(),
        inventory_sha256: hex(&Sha256::digest(&inventory_bytes)),
        ciphertext_hex: String::new(),
    };
    let associated_data = aad(&envelope, &inventory_bytes)?;
    let derived = derive_key(passphrase, &salt)?;
    ChaCha20Poly1305::new(Key::from_slice(derived.as_ref()))
        .encrypt_in_place(Nonce::from_slice(&nonce), &associated_data, &mut *plaintext)
        .map_err(|_| RecoveryBundleError::Authentication)?;
    envelope.ciphertext_hex = hex(&plaintext);
    Ok(envelope)
}

pub(crate) fn unwrap(
    envelope: &RecoveryEnvelope,
    passphrase: &str,
    backup_sha256: &str,
    inventory: &RecoveryKeyInventory,
) -> Result<Vec<KeyMaterial>, RecoveryBundleError> {
    validate_passphrase(passphrase)?;
    validate_envelope(envelope, inventory, backup_sha256)?;
    let salt = decode_hex(&envelope.salt_hex)?;
    let nonce = decode_hex(&envelope.nonce_hex)?;
    let mut plaintext = Zeroizing::new(decode_hex(&envelope.ciphertext_hex)?);
    let inventory_bytes = canonical_inventory(inventory)?;
    let associated_data = aad(envelope, &inventory_bytes)?;
    let derived = derive_key(passphrase, &salt)?;
    ChaCha20Poly1305::new(Key::from_slice(derived.as_ref()))
        .decrypt_in_place(Nonce::from_slice(&nonce), &associated_data, &mut *plaintext)
        .map_err(|_| RecoveryBundleError::Authentication)?;
    decode_payload(&plaintext, inventory)
}

fn canonical_inventory(inventory: &RecoveryKeyInventory) -> Result<Vec<u8>, RecoveryBundleError> {
    if inventory.version != 1
        || inventory.required_keys.is_empty()
        || inventory.required_keys.len() > MAX_KEYS
    {
        return Err(RecoveryBundleError::Inventory);
    }
    let mut catalogs = 0;
    let mut quarantine_objects = BTreeSet::new();
    let mut quarantine_assets = BTreeSet::new();
    for identity in &inventory.required_keys {
        match identity {
            RequiredRecoveryKey::Catalog { source_key_id } => {
                catalogs += 1;
                if source_key_id.is_empty() || source_key_id.len() > 256 {
                    return Err(RecoveryBundleError::Inventory);
                }
            }
            RequiredRecoveryKey::Vault { key_version, .. } if *key_version == 0 => {
                return Err(RecoveryBundleError::Inventory);
            }
            RequiredRecoveryKey::Quarantine {
                object_id,
                asset_id,
                key_version,
            } if (*key_version != 1
                || !quarantine_objects.insert(*object_id)
                || !quarantine_assets.insert(*asset_id)) =>
            {
                return Err(RecoveryBundleError::Inventory);
            }
            _ => {}
        }
        if serde_json::to_vec(identity)
            .map_err(|_| RecoveryBundleError::Inventory)?
            .len()
            > MAX_IDENTITY_BYTES
        {
            return Err(RecoveryBundleError::Inventory);
        }
    }
    if catalogs > 1 {
        return Err(RecoveryBundleError::Inventory);
    }
    serde_json::to_vec(inventory).map_err(|_| RecoveryBundleError::Inventory)
}

fn validate_passphrase(passphrase: &str) -> Result<(), RecoveryBundleError> {
    if !(16..=1024).contains(&passphrase.len()) {
        return Err(RecoveryBundleError::Passphrase);
    }
    Ok(())
}

fn derive_key(passphrase: &str, salt: &[u8]) -> Result<Zeroizing<[u8; 32]>, RecoveryBundleError> {
    let _guard = KDF_LOCK
        .lock()
        .map_err(|_| RecoveryBundleError::Derivation)?;
    let params =
        Params::new(262_144, 3, 1, Some(32)).map_err(|_| RecoveryBundleError::Derivation)?;
    // argon2's alloc convenience buffer is deallocated without wiping even
    // with its zeroize feature. Own the complete workspace so derived state is
    // wiped before release, including error/panic unwinding paths.
    let mut blocks = Vec::<argon2::Block>::new();
    blocks
        .try_reserve_exact(params.block_count())
        .map_err(|_| RecoveryBundleError::Derivation)?;
    blocks.resize(params.block_count(), argon2::Block::new());
    let mut memory = Zeroizing::new(blocks);
    let mut key = Zeroizing::new([0_u8; 32]);
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
        .hash_password_into_with_memory(
            passphrase.as_bytes(),
            salt,
            key.as_mut(),
            memory.as_mut_slice(),
        )
        .map_err(|_| RecoveryBundleError::Derivation)?;
    Ok(key)
}

fn aad(envelope: &RecoveryEnvelope, inventory: &[u8]) -> Result<Vec<u8>, RecoveryBundleError> {
    serde_json::to_vec(&(
        "photo-organizer-portable-recovery",
        envelope.version,
        &envelope.kdf_profile,
        &envelope.salt_hex,
        &envelope.nonce_hex,
        &envelope.backup_sha256,
        &envelope.inventory_sha256,
        inventory,
    ))
    .map_err(|_| RecoveryBundleError::Envelope)
}

fn decode_payload(
    plaintext: &[u8],
    inventory: &RecoveryKeyInventory,
) -> Result<Vec<KeyMaterial>, RecoveryBundleError> {
    let mut cursor = 0;
    let count = take_u32(plaintext, &mut cursor)? as usize;
    if count != inventory.required_keys.len() || count > MAX_KEYS {
        return Err(RecoveryBundleError::Inventory);
    }
    let mut keys = BTreeMap::new();
    for _ in 0..count {
        let length = take_u32(plaintext, &mut cursor)? as usize;
        if length == 0 || length > MAX_IDENTITY_BYTES {
            return Err(RecoveryBundleError::Inventory);
        }
        let identity: RequiredRecoveryKey =
            serde_json::from_slice(take(plaintext, &mut cursor, length)?)
                .map_err(|_| RecoveryBundleError::Inventory)?;
        let mut key = Zeroizing::new([0_u8; 32]);
        key.copy_from_slice(take(plaintext, &mut cursor, 32)?);
        if !inventory.required_keys.contains(&identity) || keys.insert(identity, key).is_some() {
            return Err(RecoveryBundleError::Inventory);
        }
    }
    if cursor != plaintext.len() {
        return Err(RecoveryBundleError::Inventory);
    }
    Ok(keys
        .into_iter()
        .map(|(identity, key)| KeyMaterial { identity, key })
        .collect())
}

fn take_u32(bytes: &[u8], cursor: &mut usize) -> Result<u32, RecoveryBundleError> {
    let value: [u8; 4] = take(bytes, cursor, 4)?
        .try_into()
        .map_err(|_| RecoveryBundleError::Inventory)?;
    Ok(u32::from_le_bytes(value))
}
fn take<'a>(
    bytes: &'a [u8],
    cursor: &mut usize,
    count: usize,
) -> Result<&'a [u8], RecoveryBundleError> {
    let end = cursor
        .checked_add(count)
        .ok_or(RecoveryBundleError::Inventory)?;
    let value = bytes
        .get(*cursor..end)
        .ok_or(RecoveryBundleError::Inventory)?;
    *cursor = end;
    Ok(value)
}
fn valid_hex(value: &str, byte_length: usize) -> bool {
    value.len() == byte_length * 2 && value.bytes().all(|b| b.is_ascii_hexdigit())
}
fn decode_hex(value: &str) -> Result<Vec<u8>, RecoveryBundleError> {
    if !value.len().is_multiple_of(2) {
        return Err(RecoveryBundleError::Envelope);
    }
    value
        .as_bytes()
        .chunks_exact(2)
        .map(|pair| {
            let hi = (pair[0] as char)
                .to_digit(16)
                .ok_or(RecoveryBundleError::Envelope)?;
            let lo = (pair[1] as char)
                .to_digit(16)
                .ok_or(RecoveryBundleError::Envelope)?;
            Ok(((hi << 4) | lo) as u8)
        })
        .collect()
}
fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{collections::BTreeSet, sync::OnceLock};
    use uuid::Uuid;

    const PASSPHRASE: &str = "test recovery passphrase only";
    static FIXTURE: OnceLock<(RecoveryKeyInventory, RecoveryEnvelope)> = OnceLock::new();
    fn fixture() -> &'static (RecoveryKeyInventory, RecoveryEnvelope) {
        FIXTURE.get_or_init(|| {
            let identities = BTreeSet::from([
                RequiredRecoveryKey::Catalog {
                    source_key_id: "fixture-source-catalog".into(),
                },
                RequiredRecoveryKey::Vault {
                    vault_id: Uuid::from_u128(1),
                    key_version: 2,
                },
                RequiredRecoveryKey::Quarantine {
                    object_id: Uuid::from_u128(2),
                    asset_id: Uuid::from_u128(3),
                    key_version: 1,
                },
            ]);
            let inventory = RecoveryKeyInventory {
                version: 1,
                required_keys: identities,
            };
            let keys = inventory
                .required_keys
                .iter()
                .cloned()
                .map(|identity| KeyMaterial {
                    identity,
                    key: Zeroizing::new([42; 32]),
                })
                .collect::<Vec<_>>();
            let envelope = wrap(&keys, PASSPHRASE, &"ab".repeat(32), &inventory).unwrap();
            (inventory, envelope)
        })
    }
    #[test]
    fn production_profile_roundtrip_and_authenticated_failures() {
        let (inventory, envelope) = fixture();
        let keys = unwrap(envelope, PASSPHRASE, &"ab".repeat(32), inventory).unwrap();
        assert_eq!(keys.len(), 3);
        assert!(keys.iter().all(|key| key.key.as_slice() == [42; 32]));
        assert!(!format!("{:?}", keys[0]).contains("42, 42"));
        assert!(matches!(
            unwrap(
                envelope,
                "incorrect recovery passphrase",
                &"ab".repeat(32),
                inventory
            ),
            Err(RecoveryBundleError::Authentication)
        ));
        let mut altered = envelope.clone();
        altered.ciphertext_hex.replace_range(
            0..2,
            if &altered.ciphertext_hex[..2] == "00" {
                "01"
            } else {
                "00"
            },
        );
        assert!(matches!(
            unwrap(&altered, PASSPHRASE, &"ab".repeat(32), inventory),
            Err(RecoveryBundleError::Authentication)
        ));
        // Salt/nonce values are well-formed but tampered, so AEAD must reject.
        let mut altered_nonce = envelope.clone();
        altered_nonce.nonce_hex = "00".repeat(12);
        assert!(matches!(
            unwrap(&altered_nonce, PASSPHRASE, &"ab".repeat(32), inventory),
            Err(RecoveryBundleError::Authentication)
        ));
        let mut altered_salt = envelope.clone();
        altered_salt.salt_hex = "00".repeat(16);
        assert!(matches!(
            unwrap(&altered_salt, PASSPHRASE, &"ab".repeat(32), inventory),
            Err(RecoveryBundleError::Authentication)
        ));
    }
    #[test]
    fn rejects_profile_binding_and_bounds_before_key_derivation() {
        let (inventory, envelope) = fixture();
        let mut altered = envelope.clone();
        altered.kdf_profile = "argon2id-m999999999".into();
        assert_eq!(
            validate_envelope(&altered, inventory, &"ab".repeat(32)),
            Err(RecoveryBundleError::Envelope)
        );
        assert_eq!(
            validate_envelope(envelope, inventory, &"cd".repeat(32)),
            Err(RecoveryBundleError::Binding)
        );
        let mut missing = inventory.clone();
        missing.required_keys.pop_first();
        assert_eq!(
            validate_envelope(envelope, &missing, &"ab".repeat(32)),
            Err(RecoveryBundleError::Binding)
        );
        let mut excessive = envelope.clone();
        excessive.ciphertext_hex = "00".repeat(MAX_CIPHERTEXT_BYTES + 1);
        assert_eq!(
            validate_envelope(&excessive, inventory, &"ab".repeat(32)),
            Err(RecoveryBundleError::Envelope)
        );
        assert!(matches!(
            wrap(&[], "short", &"ab".repeat(32), inventory),
            Err(RecoveryBundleError::Passphrase)
        ));
        assert!(matches!(
            wrap(&[], PASSPHRASE, &"ab".repeat(32), inventory),
            Err(RecoveryBundleError::Inventory)
        ));
        let mut aliases = inventory.clone();
        aliases
            .required_keys
            .insert(RequiredRecoveryKey::Quarantine {
                object_id: Uuid::from_u128(2),
                asset_id: Uuid::from_u128(4),
                key_version: 1,
            });
        assert_eq!(
            validate_envelope(envelope, &aliases, &"ab".repeat(32)),
            Err(RecoveryBundleError::Inventory)
        );
    }
    #[test]
    fn payload_parser_rejects_truncation_duplicates_and_trailing_bytes() {
        let (inventory, _) = fixture();
        assert!(decode_payload(&[0; 3], inventory).is_err());
        assert!(decode_payload(&0_u32.to_le_bytes(), inventory).is_err());
        let mut payload = Zeroizing::new(Vec::new());
        payload.extend_from_slice(&3_u32.to_le_bytes());
        for _ in 0..3 {
            let identity = serde_json::to_vec(inventory.required_keys.first().unwrap()).unwrap();
            payload.extend_from_slice(&(identity.len() as u32).to_le_bytes());
            payload.extend_from_slice(&identity);
            payload.extend_from_slice(&[42; 32]);
        }
        assert!(decode_payload(&payload, inventory).is_err());
        let mut valid = Zeroizing::new(Vec::new());
        valid.extend_from_slice(&3_u32.to_le_bytes());
        for identity in &inventory.required_keys {
            let bytes = serde_json::to_vec(identity).unwrap();
            valid.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
            valid.extend_from_slice(&bytes);
            valid.extend_from_slice(&[42; 32]);
        }
        valid.push(0);
        assert!(decode_payload(&valid, inventory).is_err());
    }
}
