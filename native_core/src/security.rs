use std::{
    collections::BTreeMap,
    fs,
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
    let state = match read_state_for_database_path(path) {
        Ok(state) => state,
        // A torn or otherwise unreadable state file is fatal -- unless the
        // database file itself proves it is encrypted, in which case this is
        // the #109 crash window (swap done, state never persisted) and the
        // recovery below rebuilds it. Unreadable state over a plaintext
        // database keeps the old error: ignoring corruption we cannot explain
        // would mask disk failure as a clean open.
        Err(_) if database_file_is_encrypted(path) => None,
        Err(error) => return Err(error),
    };
    if let Some(state) = state {
        let key_hex = load_key_for_state(path, &state)?;
        key_connection(&connection, &key_hex)?;
    } else if database_file_is_encrypted(path) {
        recover_interrupted_activation(path, &connection)?;
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
    match fs::read(path) {
        Ok(bytes) => !bytes.is_empty() && !bytes.starts_with(SQLITE_MAGIC),
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
    let mut recovered = None;
    // Production truth first, test file store second. In production the file
    // store is never written, so trying it is a harmless miss; under cfg(test)
    // the keyring may be absent, so the file store is the way back. One code
    // path for both: divergent recovery logic would itself need recovering.
    for key_storage in ["os_keychain", "test_file_key_store"] {
        let candidate = match key_storage {
            "os_keychain" => keyring::Entry::new(KEYRING_SERVICE, &key_id)
                .ok()
                .and_then(|entry| entry.get_password().ok()),
            _ => load_key_from_file(database_path, &key_id).ok(),
        };
        if let Some(key_hex) = candidate {
            recovered = Some((key_hex, key_storage.to_string()));
            break;
        }
    }
    let (key_hex, key_storage) = recovered.ok_or_else(|| {
        SecurityError::KeyStorage(format!(
            "database is encrypted but no key is available for key id {key_id}; \
             the keyring entry is missing and there is no fallback to try"
        ))
    })?;
    key_connection(connection, &key_hex)?;
    connection
        .query_row("SELECT count(*) FROM sqlite_master", [], |row| {
            row.get::<_, i64>(0)
        })
        .map_err(|_| {
            SecurityError::KeyStorage(
                "the stored key does not open the encrypted database; refusing to \
                 persist a state that cannot unlock it"
                    .to_string(),
            )
        })?;
    let raw = serde_json::to_string_pretty(&EncryptionStateFile {
        database_encrypted: true,
        derived_data_encrypted: true,
        key_id,
        key_storage,
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
    fs::write(&temp, bytes).map_err(io_error)?;
    fs::File::open(&temp)
        .and_then(|file| file.sync_all())
        .map_err(io_error)?;
    fs::rename(&temp, path).map_err(io_error)?;
    fs::File::open(parent)
        .and_then(|dir| dir.sync_all())
        .map_err(io_error)
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
    if stored_key_hex != key_hex {
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
        .map(|value| value.trim().to_string())
        .map_err(io_error)
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
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEST_COUNTER: AtomicU64 = AtomicU64::new(0);

    fn test_config(name: &str) -> (AppConfig, PathBuf) {
        let n = TEST_COUNTER.fetch_add(1, Ordering::SeqCst);
        let root =
            std::env::temp_dir().join(format!("pg-sec-test-{name}-{}-{n}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let config = AppConfig {
            runtime_root: root.clone(),
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
