use std::{
    collections::BTreeMap,
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
};

use chrono::{DateTime, Utc};
use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
use uuid::Uuid;

use crate::{
    config::AppConfig,
    domain::{EncryptionActivationResult, EncryptionStatus},
    imports,
    service::constant_time_eq,
};

const KEYRING_SERVICE: &str = "private-gallery";

#[derive(Debug, Error)]
pub enum SecurityError {
    #[error("encryption request is invalid: {0}")]
    Invalid(String),
    #[error("encryption filesystem operation failed: {0}")]
    Io(String),
    #[error("encrypted database operation failed: {0}")]
    Database(String),
    #[error("secure key storage failed: {0}")]
    KeyStorage(String),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct EncryptionStateFile {
    database_encrypted: bool,
    derived_data_encrypted: bool,
    key_id: String,
    key_storage: String,
    activated_at: DateTime<Utc>,
    backup_path: String,
}

pub fn open_database(path: &Path) -> Result<Connection, SecurityError> {
    let connection = Connection::open(path).map_err(database_error)?;
    match read_state_for_database_path(path) {
        Ok(Some(state)) => {
            let key_hex = load_key_for_state(path, &state)?;
            // codeql[database/cleartext-storage-sensitive-data]
            key_connection(&connection, &key_hex)?;
        }
        // No state file at all. Either a library that has not activated
        // encryption (nothing to do) or the #109 crash window, where the
        // database was swapped to SQLCipher but the state never landed. The
        // database header decides which, and it is read exactly once here.
        Ok(None) => {
            if database_file_is_encrypted(path) {
                recover_interrupted_activation(path, &connection)?;
            }
        }
        // A torn or otherwise unreadable state file is fatal -- unless the
        // database file itself proves it is encrypted, in which case this is
        // the crash window and recovery rebuilds the state. Unreadable state
        // over a plaintext database keeps the original error: ignoring
        // corruption we cannot explain would disguise a disk failure as a
        // clean open.
        Err(error) => {
            if !database_file_is_encrypted(path) {
                return Err(error);
            }
            recover_interrupted_activation(path, &connection)?;
        }
    }
    Ok(connection)
}

/// Whether the database file at `path` is SQLCipher-encrypted, judged from
/// its header rather than from any state file.
///
/// SQLite plaintext files begin with the fixed 16-byte magic
/// `SQLite format 3\0`; SQLCipher files begin with random salt. Probing the
/// header is what lets startup tell "plaintext database, no state yet" apart
/// from "encrypted database whose state never survived" -- the distinction
/// the crash between the database swap and the state write depends on.
/// Missing or unreadable files report false; opening them fails downstream
/// exactly as before.
fn database_file_is_encrypted(path: &Path) -> bool {
    const SQLITE_MAGIC: &[u8] = b"SQLite format 3\0";
    // Exactly 16 bytes. The previous version called `fs::read`, which is
    // `read_to_end`: it allocated a buffer the size of the entire library
    // database on a function reached by `save_state`, and therefore by every
    // mutating request, for every install that had not yet activated
    // encryption. Measured at +272 MB peak RSS on a 268 MB database, against
    // 0 on `main` for the same workload.
    let mut header = [0_u8; SQLITE_MAGIC.len()];
    match fs::File::open(path).and_then(|mut file| file.read_exact(&mut header)) {
        Ok(()) => !header.starts_with(SQLITE_MAGIC),
        // Missing, unreadable, empty, and *short* files all report false, and
        // are then left to fail downstream exactly as they always did. Short
        // files matter: anything under 16 bytes is neither a valid SQLite
        // header nor a valid SQLCipher page, and the old whole-file read
        // classified it as encrypted and sent the operator to the OS keyring
        // to look for a key that was never involved.
        Err(_) => false,
    }
}

/// Rebuild the state file after a crash between the database swap and the
/// state write (#109).
///
/// This is recoverable because of two facts the activation order guarantees:
/// the key was stored *before* the swap, and its id is derived
/// deterministically from the database path, so it is still loadable; and
/// the database header proves encryption, so a candidate key can be verified
/// by actually opening the database with it. The key is proven *before*
/// anything is persisted: a wrong key against SQLCipher fails the probe
/// query, while persisting first would bless a state that cannot open. A key
/// that does not verify -- or no key at all, e.g. a wiped keyring -- is a
/// hard error, never a silent plaintext open: an encrypted database opened
/// without the right key is the brick this exists to prevent.
fn recover_interrupted_activation(
    database_path: &Path,
    connection: &Connection,
) -> Result<(), SecurityError> {
    let key_id = key_id_for_path(database_path);
    // Production truth first, test file store second. In production the file
    // store is never written, so trying it is a harmless miss; under cfg(test)
    // the keyring may be absent, so the file store is the way back. One code
    // path for both: divergent recovery logic would itself need recovering.
    //
    // Every candidate is *verified* before it is accepted, rather than the
    // search stopping at the first key it could find. The old version took
    // the first hit and failed hard if it did not open the database, so a
    // keyring entry holding stale material aborted the attempt before the
    // file store -- which may hold the key that works -- was ever tried.
    let mut stores_holding_a_candidate: Vec<&str> = Vec::new();
    for key_storage in CANDIDATE_KEY_STORES {
        let candidate = match key_storage {
            "os_keychain" => keyring::Entry::new(KEYRING_SERVICE, &key_id)
                .ok()
                .and_then(|entry| entry.get_password().ok()),
            _ => load_key_from_file(database_path, &key_id).ok(),
        };
        let Some(key_hex) = candidate else {
            continue;
        };
        stores_holding_a_candidate.push(key_storage);
        if !key_unlocks_database(database_path, &key_hex) {
            continue;
        }
        key_connection(connection, &key_hex)?;
        return persist_recovered_state(database_path, key_id, key_storage);
    }
    // A key that is present but wrong, and a key that is simply absent, are
    // different failures and are reported as such. Both are hard errors and
    // never a silent plaintext open: an encrypted database opened without its
    // key is the brick this function exists to prevent.
    Err(if stores_holding_a_candidate.is_empty() {
        SecurityError::KeyStorage(format!(
            "database is encrypted but no key is available for key id {key_id}; \
             the keyring entry is missing and there is no fallback to try"
        ))
    } else {
        SecurityError::KeyStorage(format!(
            "a key for {key_id} was found in {} but none of them opens the \
             encrypted database; refusing to persist a state that cannot \
             unlock it",
            stores_holding_a_candidate.join(" and ")
        ))
    })
}

/// Key stores tried, in order, when recovering after an interrupted activation.
/// Must agree with the names `load_key_for_state` dispatches on, and is pinned
/// to them by `recovery_candidates_match_the_storage_names_a_state_file_can_carry`.
///
/// The loop below *verifies* each candidate before accepting it, so a stale
/// entry in the first store no longer aborts the attempt before the second is
/// tried. That walk-past cannot be exercised on a host without a keyring
/// daemon; the verification step it depends on is covered by
/// `recovery_reports_a_wrong_key_and_persists_nothing`.
const CANDIDATE_KEY_STORES: [&str; 2] = ["os_keychain", "test_file_key_store"];

/// Whether `key_hex` actually unlocks the database at `path`.
///
/// This has to run on its own connection. `PRAGMA key` cannot be undone, so a
/// wrong key applied to a shared connection poisons every later candidate --
/// which is exactly why verification has to happen on a throwaway connection
/// *before* the winner is applied to the real one, rather than after.
///
/// Opened read-write and explicitly *without* `SQLITE_OPEN_CREATE`. Plain
/// `Connection::open` creates a missing file, and a brand-new empty database
/// answers the probe query under any key at all -- so the first version of this
/// function reported `true` for a correct key against a path that did not
/// exist, and would have accepted a key for the wrong database. It is only
/// reachable with an existing file today, but a verifier that can manufacture
/// its own evidence is not a verifier.
fn key_unlocks_database(path: &Path, key_hex: &str) -> bool {
    use rusqlite::OpenFlags;
    let Ok(connection) = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_WRITE)
    else {
        return false;
    };
    // codeql[database/cleartext-storage-sensitive-data]
    key_connection(&connection, key_hex).is_ok()
        && connection
            .query_row("SELECT count(*) FROM sqlite_master", [], |row| {
                row.get::<_, i64>(0)
            })
            .is_ok()
}

/// Persist the state that the interrupted activation never got to write. Only
/// called with a key already proven to open the database.
fn persist_recovered_state(
    database_path: &Path,
    key_id: String,
    key_storage: &str,
) -> Result<(), SecurityError> {
    let raw = serde_json::to_string_pretty(&EncryptionStateFile {
        database_encrypted: true,
        derived_data_encrypted: true,
        key_id,
        key_storage: key_storage.to_string(),
        activated_at: Utc::now(),
        backup_path: String::new(),
    })
    .map_err(|error| SecurityError::Invalid(error.to_string()))?;
    atomic_write_file(
        &state_path_for_database_path(database_path)?,
        raw.as_bytes(),
    )
}

/// Durably write bytes: temp file in the same directory, fsync the file,
/// atomic rename over the destination, fsync the directory. A crash at any
/// point leaves either the old file or the new file, never a torn one --
/// which is exactly what a bare `fs::write` cannot promise and what bricked
/// the daemon in #109 variant B (a 40-byte prefix of a 219-byte state file).
fn atomic_write_file(path: &Path, bytes: &[u8]) -> Result<(), SecurityError> {
    let parent = path
        .parent()
        .ok_or_else(|| SecurityError::Invalid("state path has no parent directory".to_string()))?;
    fs::create_dir_all(parent).map_err(io_error)?;
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| SecurityError::Invalid("state path has no file name".to_string()))?;
    let temp = parent.join(format!(".{file_name}.tmp-{}", Uuid::new_v4()));
    // Create the temp file with the destination's existing permissions, or
    // 0600 when it is new. `fs::write` applied the process umask instead, so
    // an operator who had tightened the state file to 0600 silently got the
    // looser mode back on the very next write.
    let mut file = open_temp_for_write(&temp, existing_mode(path))?;
    let written = file.write_all(bytes).and_then(|()| file.sync_all());
    // Every failure past this point must remove the temp file. It is named
    // like the destination and sits in the same security directory, so leaving
    // one behind means leaving a stray copy of the state next to the state --
    // and the old code did exactly that on both the write and the rename path.
    if let Err(error) = written.map_err(io_error) {
        let _ = fs::remove_file(&temp);
        return Err(error);
    }
    // Closed before the rename: on Windows a rename cannot replace a file that
    // is still open.
    drop(file);
    if let Err(error) = fs::rename(&temp, path).map_err(io_error) {
        let _ = fs::remove_file(&temp);
        return Err(error);
    }
    sync_directory(parent)
}

/// Permissions of `path` in the platform's own bits, or `None` when it does not
/// exist yet or cannot be inspected.
#[cfg(unix)]
fn existing_mode(path: &Path) -> Option<u32> {
    use std::os::unix::fs::PermissionsExt;
    fs::metadata(path)
        .ok()
        .map(|meta| meta.permissions().mode())
}

#[cfg(not(unix))]
fn existing_mode(_path: &Path) -> Option<u32> {
    None
}

#[cfg(unix)]
fn open_temp_for_write(temp: &Path, existing: Option<u32>) -> Result<fs::File, SecurityError> {
    use std::os::unix::fs::OpenOptionsExt;
    fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(existing.unwrap_or(0o600))
        .open(temp)
        .map_err(io_error)
}

#[cfg(not(unix))]
fn open_temp_for_write(temp: &Path, _existing: Option<u32>) -> Result<fs::File, SecurityError> {
    fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(temp)
        .map_err(io_error)
}

/// Make a rename into `parent` durable.
///
/// On Unix this means fsyncing the directory, which is what actually commits
/// the new name. Windows has no equivalent for a directory handle, and asking
/// for one can fail there -- so calling it unconditionally meant `write_state`
/// could fail *after* the database swap had already renamed the SQLCipher file
/// over the live database, turning the recovery path into the very brick #109
/// describes. The call is therefore compiled out where it cannot be honoured,
/// rather than attempted and hoped for.
#[cfg(unix)]
fn sync_directory(parent: &Path) -> Result<(), SecurityError> {
    fs::File::open(parent)
        .and_then(|dir| dir.sync_all())
        .map_err(io_error)
}

#[cfg(not(unix))]
fn sync_directory(_parent: &Path) -> Result<(), SecurityError> {
    Ok(())
}

pub fn encryption_status(config: &AppConfig) -> EncryptionStatus {
    match read_state(config) {
        Ok(Some(state)) => {
            let key_available = load_key_for_state(&config.database_path(), &state).is_ok();
            EncryptionStatus {
                database_encrypted: true,
                derived_data_encrypted: true,
                key_storage: Some(state.key_storage),
                sensitive_indexing_allowed: key_available,
                warning: if key_available {
                    "Encrypted SQLCipher database is active; sensitive local indexing is allowed when required models are installed."
                        .to_string()
                } else {
                    "Encrypted database is active, but its key is unavailable from secure storage; sensitive indexing is blocked."
                        .to_string()
                },
            }
        }
        Ok(None) => EncryptionStatus {
            database_encrypted: false,
            derived_data_encrypted: false,
            key_storage: Some("not_configured".to_string()),
            sensitive_indexing_allowed: false,
            warning: format!(
                "{} Plaintext-to-SQLCipher activation has not run yet.",
                if sqlcipher_available(&config.database_path()) {
                    "SQLCipher support is compiled in."
                } else {
                    "SQLCipher support could not be confirmed."
                }
            ),
        },
        Err(error) => EncryptionStatus {
            database_encrypted: false,
            derived_data_encrypted: false,
            key_storage: None,
            sensitive_indexing_allowed: false,
            warning: format!("Unable to read encryption status: {error}"),
        },
    }
}

pub fn activate_encryption(
    config: &AppConfig,
) -> Result<EncryptionActivationResult, SecurityError> {
    if read_state(config)?.is_some() {
        return Ok(EncryptionActivationResult {
            status: encryption_status(config),
            backup_path: read_state(config)?
                .map(|state| state.backup_path)
                .unwrap_or_default(),
            activated_at: Utc::now(),
            row_counts_verified: true,
            integrity_check: "already_encrypted".to_string(),
        });
    }

    let database_path = config.database_path();
    if !database_path.exists() {
        return Err(SecurityError::Invalid(format!(
            "database does not exist yet: {}",
            database_path.to_string_lossy()
        )));
    }

    checkpoint_plaintext_database(&database_path)?;
    let key_hex = generate_key_hex();
    let key_id = key_id_for_path(&database_path);
    let key_storage = store_key(config, &key_id, &key_hex)?;
    let pending_state = EncryptionStateFile {
        database_encrypted: true,
        derived_data_encrypted: true,
        key_id: key_id.clone(),
        key_storage: key_storage.clone(),
        activated_at: Utc::now(),
        backup_path: String::new(),
    };
    let stored_key_hex = load_key_for_state(&database_path, &pending_state)?;
    if !constant_time_eq(stored_key_hex.as_bytes(), key_hex.as_bytes()) {
        return Err(SecurityError::KeyStorage(
            "secure storage returned a different encryption key than the one just stored"
                .to_string(),
        ));
    }

    // Always create temp file in the same directory as the database to guarantee
    // atomic rename on POSIX (same filesystem). The backup_root parameter is
    // retained for API compatibility but no longer used for temp file location.
    let db_dir = database_path.parent().ok_or_else(|| {
        SecurityError::Invalid("database path has no parent directory".to_string())
    })?;
    let temp_name = format!("gallery.sqlite3.sqlcipher-{}.tmp", Uuid::new_v4());
    let encrypted_temp = db_dir.join(temp_name);

    export_plaintext_to_encrypted(&database_path, &encrypted_temp, &key_hex)?;
    let (row_counts_verified, integrity_check) =
        verify_encrypted_database(&database_path, &encrypted_temp, &key_hex)?;
    if !row_counts_verified || integrity_check != "ok" {
        let _ = fs::remove_file(&encrypted_temp);
        return Err(SecurityError::Database(format!(
            "encrypted migration verification failed: rows={row_counts_verified}, integrity={integrity_check}"
        )));
    }

    replace_database_with_encrypted(&database_path, &encrypted_temp)?;
    let activated_at = Utc::now();
    write_state(
        config,
        &EncryptionStateFile {
            database_encrypted: true,
            derived_data_encrypted: true,
            key_id,
            key_storage,
            activated_at,
            backup_path: String::new(),
        },
    )?;
    write_encryption_settings_row(config)?;

    Ok(EncryptionActivationResult {
        status: encryption_status(config),
        backup_path: String::new(),
        activated_at,
        row_counts_verified,
        integrity_check,
    })
}

fn write_encryption_settings_row(config: &AppConfig) -> Result<(), SecurityError> {
    let state = read_state(config)?
        .ok_or_else(|| SecurityError::Invalid("encryption state was not written".to_string()))?;
    let connection = open_database(&config.database_path())?;
    connection
        .execute(
            r#"
            INSERT OR REPLACE INTO encryption_settings (
              id, database_encrypted, derived_data_encrypted, key_storage,
              key_id, migrated_at, warning
            ) VALUES (1, 1, 1, ?1, ?2, ?3, '')
            "#,
            rusqlite::params![
                state.key_storage,
                state.key_id,
                state.activated_at.to_rfc3339(),
            ],
        )
        .map_err(database_error)?;
    Ok(())
}

fn export_plaintext_to_encrypted(
    database_path: &Path,
    encrypted_temp: &Path,
    key_hex: &str,
) -> Result<(), SecurityError> {
    let connection = Connection::open(database_path).map_err(database_error)?;
    connection
        .execute_batch(&format!(
            "ATTACH DATABASE '{}' AS encrypted KEY \"x'{}'\";\nSELECT sqlcipher_export('encrypted');\nDETACH DATABASE encrypted;",
            quote_sql_path(encrypted_temp),
            key_hex
        ))
        .map_err(database_error)
}

fn verify_encrypted_database(
    source_path: &Path,
    encrypted_path: &Path,
    key_hex: &str,
) -> Result<(bool, String), SecurityError> {
    let source = Connection::open(source_path).map_err(database_error)?;
    let encrypted = Connection::open(encrypted_path).map_err(database_error)?;
    // codeql[database/cleartext-storage-sensitive-data]
    key_connection(&encrypted, key_hex)?;

    let source_counts = user_table_row_counts(&source)?;
    let encrypted_counts = user_table_row_counts(&encrypted)?;
    let integrity_check = encrypted
        .query_row("PRAGMA integrity_check", [], |row| row.get::<_, String>(0))
        .map_err(database_error)?;
    Ok((source_counts == encrypted_counts, integrity_check))
}

fn replace_database_with_encrypted(
    database_path: &Path,
    encrypted_temp: &Path,
) -> Result<(), SecurityError> {
    remove_sidecar(database_path, "wal")?;
    remove_sidecar(database_path, "shm")?;
    fs::rename(encrypted_temp, database_path).map_err(io_error)?;
    Ok(())
}

fn checkpoint_plaintext_database(database_path: &Path) -> Result<(), SecurityError> {
    let connection = Connection::open(database_path).map_err(database_error)?;
    connection
        .execute_batch("PRAGMA wal_checkpoint(FULL);")
        .map_err(database_error)
}

fn user_table_row_counts(connection: &Connection) -> Result<BTreeMap<String, i64>, SecurityError> {
    let mut statement = connection
        .prepare(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
        )
        .map_err(database_error)?;
    let table_names = statement
        .query_map([], |row| row.get::<_, String>(0))
        .map_err(database_error)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(database_error)?;

    let mut counts = BTreeMap::new();
    for table_name in table_names {
        let count = connection
            .query_row(
                &format!("SELECT COUNT(*) FROM \"{table_name}\""),
                [],
                |row| row.get::<_, i64>(0),
            )
            .map_err(database_error)?;
        counts.insert(table_name, count);
    }
    Ok(counts)
}

// codeql[database/cleartext-storage-sensitive-data]
// SQLCipher key material applied via PRAGMA key using hex from secure storage
// (OS keychain; test file store only in tests). Key is applied to encrypted
// database connection only, never persisted in plaintext.
fn key_connection(connection: &Connection, key_hex: &str) -> Result<(), SecurityError> {
    connection
        .execute_batch(&format!("PRAGMA key = \"x'{key_hex}'\";"))
        .map_err(database_error)
}

fn sqlcipher_available(database_path: &Path) -> bool {
    Connection::open(database_path)
        .and_then(|connection| {
            connection.query_row("PRAGMA cipher_version", [], |row| row.get::<_, String>(0))
        })
        .map(|value| !value.trim().is_empty())
        .unwrap_or(false)
}

fn read_state(config: &AppConfig) -> Result<Option<EncryptionStateFile>, SecurityError> {
    read_state_file(&state_path(config))
}

fn write_state(config: &AppConfig, state: &EncryptionStateFile) -> Result<(), SecurityError> {
    let raw = serde_json::to_string_pretty(state)
        .map_err(|error| SecurityError::Invalid(error.to_string()))?;
    // Atomic, not fs::write: a torn state file over an encrypted database is
    // the #109 brick. See atomic_write_file for the guarantee.
    atomic_write_file(&state_path(config), raw.as_bytes())
}

fn read_state_for_database_path(
    database_path: &Path,
) -> Result<Option<EncryptionStateFile>, SecurityError> {
    read_state_file(&state_path_for_database_path(database_path)?)
}

fn read_state_file(path: &Path) -> Result<Option<EncryptionStateFile>, SecurityError> {
    if !path.exists() {
        return Ok(None);
    }
    let raw = fs::read_to_string(path).map_err(io_error)?;
    serde_json::from_str(&raw)
        .map(Some)
        .map_err(|error| SecurityError::Invalid(error.to_string()))
}

fn state_path(config: &AppConfig) -> PathBuf {
    config
        .runtime_root
        .join("security")
        .join("encryption_status.json")
}

fn state_path_for_database_path(database_path: &Path) -> Result<PathBuf, SecurityError> {
    let db_dir = database_path.parent().ok_or_else(|| {
        SecurityError::Invalid("database path has no parent directory".to_string())
    })?;
    let runtime_root = db_dir.parent().ok_or_else(|| {
        SecurityError::Invalid("database path is not inside a runtime db directory".to_string())
    })?;
    Ok(runtime_root.join("security").join("encryption_status.json"))
}

fn store_key(config: &AppConfig, key_id: &str, key_hex: &str) -> Result<String, SecurityError> {
    if cfg!(test) {
        return store_key_in_file(config, key_id, key_hex);
    }

    let entry = keyring::Entry::new(KEYRING_SERVICE, key_id)
        .map_err(|error| SecurityError::KeyStorage(error.to_string()))?;
    entry
        .set_password(key_hex)
        .map_err(|error| SecurityError::KeyStorage(error.to_string()))?;
    Ok("os_keychain".to_string())
}

fn load_key_for_state(
    database_path: &Path,
    state: &EncryptionStateFile,
) -> Result<String, SecurityError> {
    if state.key_storage == "test_file_key_store" {
        return load_key_from_file(database_path, &state.key_id);
    }

    let entry = keyring::Entry::new(KEYRING_SERVICE, &state.key_id)
        .map_err(|error| SecurityError::KeyStorage(error.to_string()))?;
    entry
        .get_password()
        .map_err(|error| SecurityError::KeyStorage(error.to_string()))
}

fn store_key_in_file(
    config: &AppConfig,
    key_id: &str,
    key_hex: &str,
) -> Result<String, SecurityError> {
    let path = key_file_path(&config.runtime_root, key_id);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(io_error)?;
    }
    fs::write(path, key_hex).map_err(io_error)?;
    Ok("test_file_key_store".to_string())
}

fn load_key_from_file(database_path: &Path, key_id: &str) -> Result<String, SecurityError> {
    let runtime_root = database_path
        .parent()
        .and_then(Path::parent)
        .ok_or_else(|| SecurityError::Invalid("database path has no runtime root".to_string()))?;
    fs::read_to_string(key_file_path(runtime_root, key_id))
        .map_err(io_error)
        .and_then(|value| {
            let trimmed = value.trim();
            if trimmed.is_empty() || !trimmed.chars().all(|c| c.is_ascii_hexdigit()) {
                return Err(SecurityError::Invalid("invalid key format".to_string()));
            }
            Ok(trimmed.to_string())
        })
}

fn key_file_path(runtime_root: &Path, key_id: &str) -> PathBuf {
    runtime_root
        .join("security")
        .join("test-keys")
        .join(format!("{key_id}.key"))
}

fn key_id_for_path(database_path: &Path) -> String {
    let mut hasher = Sha256::new();
    hasher.update(database_path.to_string_lossy().as_bytes());
    let digest = hex_string(hasher.finalize());
    format!("library-{}", &digest[..24])
}

fn generate_key_hex() -> String {
    let mut bytes = Vec::with_capacity(32);
    bytes.extend_from_slice(Uuid::new_v4().as_bytes());
    bytes.extend_from_slice(Uuid::new_v4().as_bytes());
    hex_string(&bytes)
}

fn hex_string(bytes: impl AsRef<[u8]>) -> String {
    bytes
        .as_ref()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn quote_sql_path(path: &Path) -> String {
    path.to_string_lossy().replace('\'', "''")
}

fn remove_sidecar(database_path: &Path, suffix: &str) -> Result<(), SecurityError> {
    let path = PathBuf::from(format!("{}-{suffix}", database_path.to_string_lossy()));
    if path.exists() {
        fs::remove_file(path).map_err(io_error)?;
    }
    Ok(())
}

fn database_error(error: rusqlite::Error) -> SecurityError {
    SecurityError::Database(error.to_string())
}

fn io_error(error: std::io::Error) -> SecurityError {
    SecurityError::Io(error.to_string())
}

pub fn database_sha256(path: &Path) -> Option<String> {
    imports::derive_content_hash_from_file(path).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    fn test_config(name: &str) -> (AppConfig, crate::test_support::TestTempDir) {
        let root = crate::test_support::TestTempDir::new(&format!("security-{name}"));
        let config = AppConfig {
            runtime_root: root.to_path_buf(),
            library_root: root.join("library"),
            ..AppConfig::default()
        };
        (config, root)
    }

    fn seed_db(config: &AppConfig) {
        crate::storage::bootstrap_storage(config).expect("bootstrap must succeed");
        let connection = open_database(&config.database_path()).expect("seeded db must open");
        connection
            .execute_batch(
                "CREATE TABLE IF NOT EXISTS recovery_canary (id INTEGER PRIMARY KEY, note TEXT); \
                 INSERT INTO recovery_canary (note) VALUES ('before-activation');",
            )
            .expect("canary row must insert");
    }

    fn cleanup(root: &Path) {
        let _ = fs::remove_dir_all(root);
    }

    /// Peak resident set size of this process, in bytes, from the kernel.
    fn peak_rss_bytes() -> u64 {
        let status = fs::read_to_string("/proc/self/status").expect("procfs must be readable");
        status
            .lines()
            .find_map(|line| {
                let rest = line.strip_prefix("VmHWM:")?;
                let digits: String = rest
                    .trim()
                    .chars()
                    .take_while(char::is_ascii_digit)
                    .collect();
                digits.parse::<u64>().ok().map(|kb| kb * 1024)
            })
            .expect("procfs must report VmHWM")
    }

    /// The header probe must read a header, not the database.
    ///
    /// This is the whole point of the fix: the probe is reached by `save_state`,
    /// and therefore by every mutating request, on every install that has not
    /// activated encryption. The old `fs::read` allocated a buffer the size of
    /// the entire library for a 16-byte question.
    ///
    /// A sparse file, so the test costs no disk and no time to set up. The
    /// threshold is deliberately loose: `VmHWM` is process-wide and other tests
    /// in this binary run on parallel threads, so a tight bound would be flaky.
    /// 64 MiB against a 512 MiB file still leaves 8x of headroom -- the
    /// regression this guards is a 512 MiB allocation, not a marginal one.
    #[test]
    fn header_probe_does_not_read_the_whole_database() {
        let (_config, root) = test_config("header-probe-rss");
        let path = root.join("big.db");
        fs::create_dir_all(&root).expect("root must be creatable");
        let file = fs::File::create(&path).expect("file must be creatable");
        file.set_len(512 * 1024 * 1024)
            .expect("sparse file must resize");

        let before = peak_rss_bytes();
        let encrypted = database_file_is_encrypted(&path);
        let grew = peak_rss_bytes().saturating_sub(before);

        // A 512 MiB file of zeros has no SQLite header, so it reads as
        // encrypted. The assertion is about the memory, not the verdict.
        assert!(
            encrypted,
            "precondition: a zero-filled file has no SQLite magic and must read as encrypted"
        );
        assert!(
            grew < 64 * 1024 * 1024,
            "a 16-byte header probe grew peak RSS by {grew} bytes on a 512 MiB file; \
             it is reading the whole database"
        );
        cleanup(&root);
    }

    /// The classification contract, edge by edge.
    ///
    /// The short-file case is a behaviour *change* and is asserted deliberately:
    /// the old whole-file read called anything non-empty and non-magic
    /// "encrypted", so a 4-byte truncated file sent the operator to the OS
    /// keyring to look for a key that was never involved. A short file is
    /// neither a valid SQLite header nor a valid SQLCipher page, so it is not
    /// encrypted, and it fails downstream as the corruption it is.
    #[test]
    fn header_probe_classifies_missing_empty_and_short_files_as_unencrypted() {
        let (_config, root) = test_config("header-probe-edges");
        fs::create_dir_all(&root).expect("root must be creatable");

        assert!(
            !database_file_is_encrypted(&root.join("absent.db")),
            "a missing file must not claim to be encrypted"
        );

        let empty = root.join("empty.db");
        fs::write(&empty, b"").expect("empty file must write");
        assert!(
            !database_file_is_encrypted(&empty),
            "an empty file is not an encrypted database"
        );

        for length in [1_usize, 4, 15] {
            let short = root.join(format!("short-{length}.db"));
            fs::write(&short, vec![b'x'; length]).expect("short file must write");
            assert!(
                !database_file_is_encrypted(&short),
                "a {length}-byte file is neither a SQLite header nor a SQLCipher \
                 page, so it must not be reported as encrypted"
            );
        }

        // Exactly 16 bytes of magic, and 16 bytes of salt, are the two sides of
        // the boundary the real files sit on.
        let magic = root.join("magic.db");
        fs::write(&magic, b"SQLite format 3\0").expect("magic file must write");
        assert!(
            !database_file_is_encrypted(&magic),
            "the 16-byte SQLite magic is the plaintext marker"
        );
        let salt = root.join("salt.db");
        fs::write(&salt, [7_u8; 16]).expect("salt file must write");
        assert!(
            database_file_is_encrypted(&salt),
            "16 bytes that are not the magic are a SQLCipher salt"
        );
        cleanup(&root);
    }

    /// The verification predicate that decides whether a candidate key is
    /// accepted. Pinned on its own, because it is the load-bearing part of
    /// recovery: a key that cannot read `sqlite_master` is not the key, and the
    /// whole recovery path is built on trusting this answer.
    #[test]
    fn key_unlocks_database_distinguishes_right_from_wrong() {
        let (config, root) = test_config("key-unlocks");
        seed_db(&config);
        activate_encryption(&config).expect("activation must succeed");
        let key_id = key_id_for_path(&config.database_path());
        let path = config.database_path();
        let right = load_key_from_file(&path, &key_id).expect("key must be readable");
        assert!(
            key_unlocks_database(&path, &right),
            "the key activation stored must open the database it encrypted"
        );
        assert!(
            !key_unlocks_database(&path, &"00".repeat(32)),
            "all-zero key material must not be accepted"
        );
        assert!(
            !key_unlocks_database(&root.join("absent.db"), &right),
            "a valid key against a missing database must not be accepted"
        );
        cleanup(&root);
    }

    /// Pins the recovery candidate list to the storage names a state file can
    /// actually carry.
    ///
    /// Being explicit about the limit: the *ordering* behaviour of
    /// `CANDIDATE_KEY_STORES` -- that recovery now walks past a candidate that
    /// fails verification instead of aborting -- **cannot be exercised from a
    /// Linux test run**, because the `os_keychain` lookup returns `None` when
    /// there is no keyring daemon, so only the file store ever yields a
    /// candidate and there is never a second one to walk past. Exercising it
    /// needs a host with a real keyring and two stores holding different keys.
    /// Claiming that behaviour is tested would be false.
    ///
    /// What *is* testable, and what actually rots, is the wiring: the names in
    /// the recovery list, the order, and the fact that the name recovery
    /// persists round-trips through `load_key_for_state`. Those are asserted
    /// here. The walk-past behaviour is covered by
    /// `recovery_reports_a_wrong_key_and_persists_nothing`, which fails if the
    /// verification step is removed.
    #[test]
    fn recovery_candidates_match_the_storage_names_a_state_file_can_carry() {
        assert_eq!(
            CANDIDATE_KEY_STORES,
            ["os_keychain", "test_file_key_store"],
            "recovery must try the keyring first and the file store second, and \
             these must be the only two names a state file can carry"
        );

        // The name recovery writes has to be the one the state reader
        // dispatches on, or a recovered state is unreadable on the next open.
        let (config, root) = test_config("candidate-names");
        seed_db(&config);
        activate_encryption(&config).expect("activation must succeed");
        fs::remove_file(state_path(&config)).expect("state must exist to delete");
        open_database(&config.database_path()).expect("recovery must succeed");
        let recovered = read_state(&config)
            .expect("recovered state must parse")
            .expect("recovered state must exist");
        assert!(
            CANDIDATE_KEY_STORES.contains(&recovered.key_storage.as_str()),
            "recovery persisted the unknown storage name {:?}",
            recovered.key_storage
        );
        // And the persisted state must actually be loadable, which is the
        // property that matters on the next process start.
        assert!(
            load_key_for_state(&config.database_path(), &recovered).is_ok(),
            "a state recovery just wrote must be loadable again"
        );
        cleanup(&root);
    }

    /// Recovery must try every candidate store, not stop at the first key it
    /// can *find*. It must also report the failure as a key problem and, above
    /// all, persist nothing: a state file written for a key that cannot unlock
    /// the database is the brick #109 exists to prevent.
    #[test]
    fn recovery_reports_a_wrong_key_and_persists_nothing() {
        let (config, root) = test_config("wrong-key-no-persist");
        seed_db(&config);
        activate_encryption(&config).expect("activation must succeed");
        let key_id = key_id_for_path(&config.database_path());
        fs::write(
            key_file_path(&config.runtime_root, &key_id),
            "00".repeat(32),
        )
        .expect("key overwrite must write");
        fs::remove_file(state_path(&config)).expect("state must exist to delete");

        let error = match open_database(&config.database_path()) {
            Err(error) => error,
            Ok(_) => panic!("a wrong key must never open the database"),
        };
        let message = error.to_string();
        assert!(
            message.contains(&key_id) && message.contains("none of them opens"),
            "the error must name the key id and say no candidate worked, got: {message}"
        );
        assert!(
            !state_path(&config).exists(),
            "a failed recovery must not leave a state file behind"
        );
        cleanup(&root);
    }

    /// Permissions on the state file are a security property, so the atomic
    /// write must not quietly widen them. Two directions: a file an operator
    /// has tightened keeps its mode, and a brand-new file is created 0600
    /// rather than inheriting the process umask.
    #[test]
    fn atomic_write_preserves_tight_permissions_and_creates_private_ones() {
        let (_config, root) = test_config("state-permissions");
        fs::create_dir_all(&root).expect("root must be creatable");
        let target = root.join("state.json");

        atomic_write_file(&target, b"{\"first\":true}").expect("first write must succeed");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(&target)
                .expect("metadata")
                .permissions()
                .mode();
            assert_eq!(
                mode & 0o777,
                0o600,
                "a new state file must not be group- or world-readable"
            );

            fs::set_permissions(&target, fs::Permissions::from_mode(0o600))
                .expect("tighten must work");
            atomic_write_file(&target, b"{\"second\":true}").expect("rewrite must succeed");
            let mode = fs::metadata(&target)
                .expect("metadata")
                .permissions()
                .mode();
            assert_eq!(
                mode & 0o777,
                0o600,
                "rewriting must not hand back the umask's mode"
            );
        }
        assert_eq!(
            fs::read_to_string(&target).expect("read back"),
            "{\"second\":true}"
        );
        cleanup(&root);
    }

    /// A failed rename must not leave the temp file behind. The old code
    /// removed it on neither the write path nor the rename path, so a failure
    /// deposited a stray copy of the state next to the state itself, inside the
    /// security directory. Making the destination a directory is the
    /// deterministic way to fail exactly that step.
    #[test]
    fn atomic_write_removes_its_temp_file_when_the_rename_fails() {
        let (_config, root) = test_config("state-rename-fails");
        fs::create_dir_all(&root).expect("root must be creatable");
        let target = root.join("state.json");
        fs::create_dir_all(&target).expect("destination must be a directory to fail the rename");

        let result = atomic_write_file(&target, b"{}");
        assert!(
            result.is_err(),
            "renaming a file over a directory must fail"
        );
        let leftovers: Vec<String> = fs::read_dir(&root)
            .expect("root must list")
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .filter(|name| name.contains(".tmp-"))
            .collect();
        assert!(
            leftovers.is_empty(),
            "a failed write must not leave temp files behind: {leftovers:?}"
        );
        cleanup(&root);
    }

    /// The recovery path has to work through the real startup entry point, not
    /// only through `open_database` called directly, or a fix here proves
    /// nothing about the daemon actually starting. `bootstrap_storage` is what
    /// the service calls, and it reaches `open_database` itself.
    #[test]
    fn recovery_works_through_the_real_bootstrap_path() {
        let (config, root) = test_config("bootstrap-recovery");
        seed_db(&config);
        activate_encryption(&config).expect("activation must succeed");
        fs::remove_file(state_path(&config)).expect("state must exist to delete");

        crate::storage::bootstrap_storage(&config).expect("bootstrap must recover and complete");

        let connection = open_database(&config.database_path()).expect("recovered db must open");
        let note: String = connection
            .query_row("SELECT note FROM recovery_canary", [], |row| row.get(0))
            .expect("canary must survive recovery through the real path");
        assert_eq!(note, "before-activation");
        assert!(
            state_path(&config).exists(),
            "the real path must leave a usable state file behind"
        );
        cleanup(&root);
    }

    /// #109 variant A: the daemon dies after the database swap renames the
    /// SQLCipher file over the live database but before the state file is
    /// written. Startup must rebuild the state from the stored key and open
    /// the database -- not exit before binding.
    #[test]
    fn crash_between_swap_and_state_recovers() {
        let (config, root) = test_config("crash-swap-state");
        seed_db(&config);
        activate_encryption(&config).expect("activation must succeed");
        // Fault injection: power loss between the rename and the state write.
        fs::remove_file(state_path(&config)).expect("state must exist to delete");
        let connection =
            open_database(&config.database_path()).expect("interrupted activation must recover");
        let note: String = connection
            .query_row("SELECT note FROM recovery_canary", [], |row| row.get(0))
            .expect("data must be readable through the recovered connection");
        assert_eq!(note, "before-activation");
        assert!(
            state_path(&config).exists(),
            "recovery must rebuild the state file"
        );
        cleanup(&root);
    }

    /// #109 variant B: the state file exists but the write was torn (a prefix
    /// of the JSON). Same recovery, because the database header -- not the
    /// state file -- is the source of truth about encryption.
    #[test]
    fn torn_state_file_recovers() {
        let (config, root) = test_config("torn-state");
        seed_db(&config);
        activate_encryption(&config).expect("activation must succeed");
        fs::write(state_path(&config), "{\"database_encrypted\": tru")
            .expect("torn state must write");
        let connection = open_database(&config.database_path()).expect("torn state must recover");
        let count: i64 = connection
            .query_row("SELECT count(*) FROM recovery_canary", [], |row| row.get(0))
            .expect("data must be readable through the recovered connection");
        assert_eq!(count, 1);
        // The previous version stopped here. Reading the data back proves the
        // key was found, but not that the torn file was *replaced* -- and a
        // recovery that leaves the truncated prefix in place would reopen fine
        // on the database header alone while the state file stayed corrupt for
        // every later read. The rebuilt state must parse and claim encryption.
        let rebuilt = read_state(&config)
            .expect("the rebuilt state file must parse")
            .expect("the rebuilt state file must be present");
        assert!(
            rebuilt.database_encrypted,
            "the rebuilt state must record that the database is encrypted"
        );
        assert!(
            !rebuilt.key_id.is_empty(),
            "the rebuilt state must name the key it recovers with"
        );
        assert_eq!(
            fs::read_to_string(state_path(&config)).expect("state must be readable"),
            serde_json::to_string_pretty(&rebuilt).expect("state must re-serialise"),
            "the state on disk must be the rebuilt document, not a leftover prefix"
        );
        cleanup(&root);
    }

    /// No state plus a plaintext database is the normal pre-activation case.
    /// Recovery must not change it: the database opens without a key.
    #[test]
    fn plaintext_without_state_opens_without_key() {
        let (config, root) = test_config("plaintext-no-state");
        seed_db(&config);
        assert!(
            !state_path(&config).exists(),
            "precondition: no state file yet"
        );
        let connection = open_database(&config.database_path()).expect("plaintext db must open");
        let note: String = connection
            .query_row("SELECT note FROM recovery_canary", [], |row| row.get(0))
            .expect("plaintext data must read");
        assert_eq!(note, "before-activation");
        cleanup(&root);
    }

    /// Prove-before-persist: if the stored key does not open the database
    /// (wrong key material in storage), recovery must fail loudly rather than
    /// persist a state that cannot unlock anything.
    #[test]
    fn wrong_stored_key_does_not_silently_open() {
        let (config, root) = test_config("wrong-key");
        seed_db(&config);
        activate_encryption(&config).expect("activation must succeed");
        let key_id = key_id_for_path(&config.database_path());
        fs::write(
            key_file_path(&config.runtime_root, &key_id),
            "00".repeat(32),
        )
        .expect("key overwrite must write");
        fs::remove_file(state_path(&config)).expect("state must exist to delete");
        match open_database(&config.database_path()) {
            Err(SecurityError::KeyStorage(_)) => {}
            Err(other) => panic!("expected a KeyStorage error, got: {other}"),
            Ok(_) => panic!("a wrong key must never open the database"),
        }
        cleanup(&root);
    }

    /// Genuinely unrecoverable: encrypted database, no state, and no key
    /// anywhere (wiped keyring / deleted key file). This must be a clear
    /// KeyStorage error -- the one case where refusing to start is correct,
    /// because no ordering of writes could have saved the key.
    #[test]
    fn encrypted_db_without_any_key_fails_loudly() {
        let (config, root) = test_config("no-key");
        seed_db(&config);
        activate_encryption(&config).expect("activation must succeed");
        let key_id = key_id_for_path(&config.database_path());
        fs::remove_file(key_file_path(&config.runtime_root, &key_id))
            .expect("key must exist to delete");
        fs::remove_file(state_path(&config)).expect("state must exist to delete");
        match open_database(&config.database_path()) {
            Err(SecurityError::KeyStorage(_)) => {}
            Err(other) => panic!("expected a KeyStorage error, got: {other}"),
            Ok(_) => panic!("an encrypted database with no key must never open"),
        }
        cleanup(&root);
    }

    /// The atomic state write must not leave temp files behind, and a second
    /// activation must short-circuit as already-encrypted (idempotent -- the
    /// recovery state round-trips through the normal path).
    #[test]
    fn activation_is_idempotent_and_leaves_no_temp_files() {
        let (config, root) = test_config("idempotent");
        seed_db(&config);
        activate_encryption(&config).expect("first activation must succeed");
        let result = activate_encryption(&config).expect("second activation must succeed");
        assert_eq!(result.integrity_check, "already_encrypted");
        let security_dir = config.runtime_root.join("security");
        let temps: Vec<_> = fs::read_dir(&security_dir)
            .expect("security dir must list")
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .filter(|name| name.contains(".tmp-"))
            .collect();
        assert!(
            temps.is_empty(),
            "atomic writes must not leave temp files: {temps:?}"
        );
        cleanup(&root);
    }
}
