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
    if let Some(state) = read_state_for_database_path(path)? {
        let key_hex = load_key_for_state(path, &state)?;
        key_connection(&connection, &key_hex)?;
    }
    Ok(connection)
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
    backup_root: Option<&Path>,
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

    let stamp = Utc::now().format("%Y%m%d%H%M%S").to_string();
    let encrypted_temp = backup_root
        .map(|root| root.join(format!("gallery.sqlite3.sqlcipher-{stamp}.tmp")))
        .unwrap_or_else(|| database_path.with_extension(format!("sqlcipher-{stamp}.tmp")));
    if encrypted_temp.exists() {
        fs::remove_file(&encrypted_temp).map_err(io_error)?;
    }

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
    let path = state_path(config);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(io_error)?;
    }
    let raw = serde_json::to_string_pretty(state)
        .map_err(|error| SecurityError::Invalid(error.to_string()))?;
    fs::write(path, raw).map_err(io_error)
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
