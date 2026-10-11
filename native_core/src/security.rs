use std::{
    collections::BTreeMap,
    ffi::CStr,
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
};

use chrono::{DateTime, Utc};
use rusqlite::{Connection, ffi};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
use uuid::Uuid;
use zeroize::Zeroizing;

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

#[derive(Debug, Clone, Serialize, Deserialize)]
struct EncryptionRecoveryManifest {
    transaction_id: String,
    database_file: String,
    key_id: String,
    key_storage: String,
    database_sha256: String,
    user_version: i64,
    row_counts: BTreeMap<String, i64>,
}

pub fn open_database(path: &Path) -> Result<Connection, SecurityError> {
    match read_state_for_database_path(path) {
        Ok(Some(state)) => {
            if !path.exists() && !recover_missing_database(path, Some(&state))? {
                return Err(SecurityError::Database(format!(
                    "encrypted database {} is missing and no verified activation file is available for recovery",
                    path.display()
                )));
            }
            // The state file may reach storage before the database rename on
            // filesystems that do not promise persistence ordering for
            // directory entries. Never trust state alone: if the database is
            // still plaintext, finish the verified encryption transaction
            // before returning a connection to callers.
            if !database_file_is_encrypted(path) {
                if !database_file_is_plaintext(path) {
                    return Err(SecurityError::Database(format!(
                        "encryption state exists but the database at {} is neither a valid plaintext SQLite file nor an encrypted database",
                        path.display()
                    )));
                }
                recover_plaintext_database(path, &state)?;
            }
            let connection = Connection::open(path).map_err(database_error)?;
            let key_hex = load_key_for_state(path, &state)?;
            key_connection(&connection, &key_hex)?;
            if !key_unlocks_database(path, &key_hex) {
                return Err(SecurityError::KeyStorage(
                    "stored key does not unlock the encrypted database".to_string(),
                ));
            }
            remove_recovery_artifacts(path, Some(&key_hex))?;
            Ok(connection)
        }
        // No state file at all. Either a library that has not activated
        // encryption (nothing to do) or the #109 crash window, where the
        // database was swapped to SQLCipher but the state never landed. The
        // database header decides which, and it is read exactly once here.
        Ok(None) => {
            if !path.exists() && recover_missing_database(path, None)? {
                let state = read_state_for_database_path(path)?
                    .ok_or_else(|| SecurityError::Invalid("recovered state is missing".into()))?;
                let connection = Connection::open(path).map_err(database_error)?;
                let key_hex = load_key_for_state(path, &state)?;
                key_connection(&connection, &key_hex)?;
                return Ok(connection);
            }
            let connection = Connection::open(path).map_err(database_error)?;
            if database_file_is_encrypted(path) {
                recover_interrupted_activation(path, &connection)?;
            } else if database_file_is_plaintext(path)
                && connection
                    .query_row("SELECT count(*) FROM sqlite_master", [], |row| {
                        row.get::<_, i64>(0)
                    })
                    .is_ok()
            {
                // A verified live plaintext database is newer than any staged
                // encryption candidate left by a failed activation. Discard
                // those candidates rather than allowing a later missing-file
                // recovery to roll back writes made since staging.
                remove_recovery_artifacts(path, None)?;
            }
            Ok(connection)
        }
        // A torn or otherwise unreadable state file is fatal -- unless the
        // database file itself proves it is encrypted, in which case this is
        // the crash window and recovery rebuilds the state. Unreadable state
        // over a plaintext database keeps the original error: ignoring
        // corruption we cannot explain would disguise a disk failure as a
        // clean open.
        Err(error) => {
            if database_file_is_encrypted(path) {
                let connection = Connection::open(path).map_err(database_error)?;
                recover_interrupted_activation(path, &connection)?;
                Ok(connection)
            } else if !path.exists() && recover_missing_database(path, None)? {
                let state = read_state_for_database_path(path)?
                    .ok_or_else(|| SecurityError::Invalid("recovered state is missing".into()))?;
                let connection = Connection::open(path).map_err(database_error)?;
                let key_hex = load_key_for_state(path, &state)?;
                key_connection(&connection, &key_hex)?;
                Ok(connection)
            } else if path.exists() && database_file_is_plaintext(path) {
                // A crash may persist a torn state file before the database
                // replacement. Recover only when a stored key successfully
                // creates and verifies an encrypted copy; never ignore the
                // state error and return a plaintext connection.
                recover_plaintext_database_without_state(path).map_err(|recovery_error| {
                    match recovery_error {
                        SecurityError::KeyStorage(_) => error,
                        other => other,
                    }
                })?;
                let state = read_state_for_database_path(path)?
                    .ok_or_else(|| SecurityError::Invalid("recovered state is missing".into()))?;
                let connection = Connection::open(path).map_err(database_error)?;
                let key_hex = load_key_for_state(path, &state)?;
                key_connection(&connection, &key_hex)?;
                Ok(connection)
            } else {
                Err(error)
            }
        }
    }
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

fn database_file_is_plaintext(path: &Path) -> bool {
    const SQLITE_MAGIC: &[u8] = b"SQLite format 3\0";
    let mut header = [0_u8; SQLITE_MAGIC.len()];
    fs::File::open(path)
        .and_then(|mut file| file.read_exact(&mut header))
        .is_ok_and(|()| header.as_slice() == SQLITE_MAGIC)
}

fn promote_verified_candidate(
    database_path: &Path,
    source_path: &Path,
    partial_path: &Path,
    state: &EncryptionStateFile,
    key_hex: &str,
) -> Result<(PathBuf, PathBuf), SecurityError> {
    let parent = database_path.parent().ok_or_else(|| {
        SecurityError::Invalid("database path has no parent directory".to_string())
    })?;
    let database_name = database_path
        .file_name()
        .ok_or_else(|| SecurityError::Invalid("database path has no file name".to_string()))?
        .to_string_lossy();
    let source = Connection::open(source_path).map_err(database_error)?;
    let source_counts = user_table_row_counts(&source)?;
    let source_user_version = source
        .query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))
        .map_err(database_error)?;
    drop(source);
    let metadata = encrypted_candidate_metadata(partial_path, key_hex)?;
    if metadata.row_counts != source_counts || metadata.user_version != source_user_version {
        return Err(SecurityError::Database(
            "encrypted staging database does not match the source schema version and row counts"
                .to_string(),
        ));
    }

    sync_file_contents(partial_path)?;
    let transaction_id = Uuid::new_v4().to_string();
    let committed_database = parent.join(format!("{database_name}.ready-{transaction_id}.db"));
    let manifest_path = parent.join(format!("{database_name}.ready-{transaction_id}.json"));
    atomic_rename_file(partial_path, &committed_database)?;
    sync_directory(parent)?;
    let manifest = EncryptionRecoveryManifest {
        transaction_id,
        database_file: database_name.to_string(),
        key_id: state.key_id.clone(),
        key_storage: state.key_storage.clone(),
        database_sha256: metadata.sha256,
        user_version: metadata.user_version,
        row_counts: metadata.row_counts,
    };
    let manifest_bytes =
        serde_json::to_vec(&manifest).map_err(|error| SecurityError::Invalid(error.to_string()))?;
    atomic_write_file(&manifest_path, &manifest_bytes)?;
    Ok((committed_database, manifest_path))
}

struct EncryptedCandidateMetadata {
    sha256: String,
    user_version: i64,
    row_counts: BTreeMap<String, i64>,
}

fn encrypted_candidate_metadata(
    path: &Path,
    key_hex: &str,
) -> Result<EncryptedCandidateMetadata, SecurityError> {
    use rusqlite::OpenFlags;

    let connection = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_WRITE)
        .map_err(database_error)?;
    key_connection(&connection, key_hex)?;
    let integrity = connection
        .query_row("PRAGMA integrity_check", [], |row| row.get::<_, String>(0))
        .map_err(database_error)?;
    if integrity != "ok" {
        return Err(SecurityError::Database(format!(
            "encrypted staging database integrity check failed: {integrity}"
        )));
    }
    let row_counts = user_table_row_counts(&connection)?;
    let user_version = connection
        .query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))
        .map_err(database_error)?;
    drop(connection);
    let sha256 = database_sha256(path).ok_or_else(|| {
        SecurityError::Io("could not hash verified encrypted staging database".to_string())
    })?;
    Ok(EncryptedCandidateMetadata {
        sha256,
        user_version,
        row_counts,
    })
}

fn recover_missing_database(
    database_path: &Path,
    recorded_state: Option<&EncryptionStateFile>,
) -> Result<bool, SecurityError> {
    let parent = database_path.parent().ok_or_else(|| {
        SecurityError::Invalid("database path has no parent directory".to_string())
    })?;
    let database_name = database_path
        .file_name()
        .ok_or_else(|| SecurityError::Invalid("database path has no file name".to_string()))?
        .to_string_lossy();
    let manifest_prefix = format!("{database_name}.ready-");
    let ready_suffix = ".db";
    let manifest_suffix = ".json";
    let mut manifests = Vec::new();
    let mut orphan_ready_files = Vec::new();
    let mut unverified_partials = Vec::new();
    for entry in fs::read_dir(parent).map_err(io_error)? {
        let entry = entry.map_err(io_error)?;
        if !entry.file_type().map_err(io_error)?.is_file() {
            continue;
        }
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.starts_with(&manifest_prefix) && name.ends_with(manifest_suffix) {
            manifests.push(entry.path());
        } else if name.starts_with(&manifest_prefix) && name.ends_with(ready_suffix) {
            orphan_ready_files.push(entry.path());
        } else if name.starts_with(database_name.as_ref())
            && (name.ends_with(".partial") || name.ends_with(".tmp"))
        {
            unverified_partials.push(entry.path());
        }
    }
    if manifests.is_empty() {
        if orphan_ready_files.is_empty() {
            if !database_path.exists() && !unverified_partials.is_empty() {
                return Err(SecurityError::Database(format!(
                    "database {} is missing and only unverified partial encryption files remain",
                    database_path.display()
                )));
            }
            return Ok(false);
        }
        return Err(SecurityError::Database(format!(
            "database {} has a staged recovery file without its verification manifest",
            database_path.display()
        )));
    }
    if manifests.len() != 1 {
        return Err(SecurityError::Database(format!(
            "database {} has multiple staged recovery manifests; refusing an ambiguous restore",
            database_path.display()
        )));
    }
    let manifest_path = &manifests[0];
    let manifest: EncryptionRecoveryManifest =
        serde_json::from_slice(&fs::read(manifest_path).map_err(io_error)?).map_err(|error| {
            SecurityError::Invalid(format!("invalid recovery manifest: {error}"))
        })?;
    if manifest.database_file != database_name
        || manifest.key_id != key_id_for_path(database_path)
        || manifest.transaction_id.is_empty()
        || !manifest
            .transaction_id
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() || byte == b'-')
    {
        return Err(SecurityError::Database(
            "recovery manifest does not match this database".to_string(),
        ));
    }
    let expected_manifest_name = format!("{database_name}.ready-{}.json", manifest.transaction_id);
    if manifest_path.file_name().and_then(|name| name.to_str()) != Some(&expected_manifest_name) {
        return Err(SecurityError::Database(
            "recovery manifest transaction identifier does not match its file name".to_string(),
        ));
    }
    let committed_database = parent.join(format!(
        "{database_name}.ready-{}.db",
        manifest.transaction_id
    ));
    if orphan_ready_files.len() != 1
        || orphan_ready_files[0].file_name() != committed_database.file_name()
    {
        return Err(SecurityError::Database(format!(
            "database {} has ambiguous staged recovery files",
            database_path.display()
        )));
    }
    if !committed_database.is_file() {
        return Err(SecurityError::Database(
            "verified recovery manifest has no staged database file".to_string(),
        ));
    }

    let state = if let Some(state) = recorded_state {
        if state.key_id != manifest.key_id || state.key_storage != manifest.key_storage {
            return Err(SecurityError::Database(
                "recovery manifest key identity does not match encryption state".to_string(),
            ));
        }
        state.clone()
    } else {
        if !CANDIDATE_KEY_STORES.contains(&manifest.key_storage.as_str()) {
            return Err(SecurityError::KeyStorage(
                "recovery manifest names an unavailable key store".to_string(),
            ));
        }
        EncryptionStateFile {
            database_encrypted: true,
            derived_data_encrypted: true,
            key_id: manifest.key_id.clone(),
            key_storage: manifest.key_storage.clone(),
            activated_at: Utc::now(),
            backup_path: String::new(),
        }
    };
    let key_hex = load_key_for_state(database_path, &state)?;
    let metadata = encrypted_candidate_metadata(&committed_database, &key_hex)?;
    if metadata.sha256 != manifest.database_sha256
        || metadata.user_version != manifest.user_version
        || metadata.row_counts != manifest.row_counts
    {
        return Err(SecurityError::Database(
            "staged recovery database does not match its verified manifest".to_string(),
        ));
    }

    replace_database_with_encrypted_then(database_path, &committed_database, || {
        persist_state_for_database_path(database_path, &state)
    })?;
    remove_recovery_artifacts(database_path, Some(&key_hex))?;
    Ok(true)
}

/// Remove staged files only after the live database has been verified and the
/// matching state has been persisted. Keeping an old, valid encrypted stage
/// beside an actively writable database could otherwise roll back later
/// writes if the live database name disappeared in a future failure.
fn remove_recovery_artifacts(
    database_path: &Path,
    key_hex: Option<&str>,
) -> Result<(), SecurityError> {
    let parent = database_path.parent().ok_or_else(|| {
        SecurityError::Invalid("database path has no parent directory".to_string())
    })?;
    let database_name = database_path
        .file_name()
        .ok_or_else(|| SecurityError::Invalid("database path has no file name".to_string()))?
        .to_string_lossy();
    let ready_prefix = format!("{database_name}.ready-");
    let partial_prefix = format!("{database_name}.");
    let mut artifacts = Vec::new();
    let mut has_ready_artifact = false;
    for entry in fs::read_dir(parent).map_err(io_error)? {
        let entry = entry.map_err(io_error)?;
        if !entry.file_type().map_err(io_error)?.is_file() {
            continue;
        }
        let name = entry.file_name();
        let name = name.to_string_lossy();
        let ready_artifact =
            name.starts_with(&ready_prefix) && (name.ends_with(".db") || name.ends_with(".json"));
        let partial_artifact = name.starts_with(partial_prefix.as_str())
            && (name.ends_with(".partial") || name.ends_with(".tmp"));
        if ready_artifact || partial_artifact {
            has_ready_artifact |= ready_artifact;
            artifacts.push(entry.path());
        }
    }
    if has_ready_artifact {
        use rusqlite::OpenFlags;

        let connection =
            Connection::open_with_flags(database_path, OpenFlags::SQLITE_OPEN_READ_WRITE)
                .map_err(database_error)?;
        if let Some(key_hex) = key_hex {
            key_connection(&connection, key_hex)?;
        }
        let integrity = connection
            .query_row("PRAGMA integrity_check", [], |row| row.get::<_, String>(0))
            .map_err(database_error)?;
        if integrity != "ok" {
            return Err(SecurityError::Database(format!(
                "live database integrity check failed; retaining staged recovery files: {integrity}"
            )));
        }
    }
    for artifact in &artifacts {
        fs::remove_file(artifact).map_err(io_error)?;
    }
    if !artifacts.is_empty() {
        sync_directory(parent)?;
    }
    Ok(())
}

/// Recover the state-ahead-of-database observation by exporting the intact
/// plaintext database again with the already-persisted key. State is
/// rewritten only after the verified encrypted replacement and its platform
/// durability barriers complete. If a barrier fails, the next startup can
/// retry from the still-plaintext database or recognize the encrypted one.
fn recover_plaintext_database(
    database_path: &Path,
    state: &EncryptionStateFile,
) -> Result<(), SecurityError> {
    let key_hex = load_key_for_state(database_path, state)?;
    recover_plaintext_database_with_key(database_path, state, &key_hex)
}

fn recover_plaintext_database_without_state(database_path: &Path) -> Result<(), SecurityError> {
    let key_id = key_id_for_path(database_path);
    let mut candidate_error = None;
    for key_storage in CANDIDATE_KEY_STORES {
        let candidate = load_key_candidate(database_path, &key_id, key_storage);
        let Some(key_hex) = candidate else {
            continue;
        };
        let state = EncryptionStateFile {
            database_encrypted: true,
            derived_data_encrypted: true,
            key_id: key_id.clone(),
            key_storage: key_storage.to_string(),
            activated_at: Utc::now(),
            backup_path: String::new(),
        };
        match recover_plaintext_database_with_key(database_path, &state, &key_hex) {
            Ok(()) => return Ok(()),
            Err(error) => candidate_error = Some(error),
        }
    }
    Err(candidate_error.unwrap_or_else(|| {
        SecurityError::KeyStorage(format!(
            "state is unreadable and no stored encryption key is available to recover database {key_id}"
        ))
    }))
}

fn recover_plaintext_database_with_key(
    database_path: &Path,
    state: &EncryptionStateFile,
    key_hex: &str,
) -> Result<(), SecurityError> {
    let parent = database_path.parent().ok_or_else(|| {
        SecurityError::Invalid("database path has no parent directory".to_string())
    })?;
    let file_name = database_path
        .file_name()
        .ok_or_else(|| SecurityError::Invalid("database path has no file name".to_string()))?
        .to_string_lossy();
    let temp = parent.join(format!("{file_name}.recovery-{}.partial", Uuid::new_v4()));
    let verification = (|| {
        export_plaintext_to_encrypted(database_path, &temp, key_hex)?;
        verify_encrypted_database(database_path, &temp, key_hex)
    })();
    let (rows_match, integrity) = match verification {
        Ok(result) => result,
        Err(error) => return Err(cleanup_candidate_after_error(&temp, error)),
    };
    if !rows_match || integrity != "ok" {
        let error = SecurityError::Database(format!(
            "plaintext database recovery verification failed: rows={rows_match}, integrity={integrity}"
        ));
        return Err(cleanup_candidate_after_error(&temp, error));
    }
    let (ready_database, _manifest_path) =
        promote_verified_candidate(database_path, database_path, &temp, state, key_hex)?;
    replace_database_with_encrypted_then(database_path, &ready_database, || {
        persist_state_for_database_path(database_path, state)?;
        remove_recovery_artifacts(database_path, Some(key_hex))
    })
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
        let candidate = load_key_candidate(database_path, &key_id, key_storage);
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
#[cfg(test)]
const CANDIDATE_KEY_STORES: [&str; 2] = ["os_keychain", "test_file_key_store"];
#[cfg(not(test))]
const CANDIDATE_KEY_STORES: [&str; 1] = ["os_keychain"];

fn load_key_candidate(_database_path: &Path, key_id: &str, key_storage: &str) -> Option<String> {
    match key_storage {
        "os_keychain" => keyring::Entry::new(KEYRING_SERVICE, key_id)
            .ok()
            .and_then(|entry| entry.get_password().ok())
            .filter(|key| validate_key_hex(key).is_ok()),
        #[cfg(test)]
        "test_file_key_store" => load_key_from_file(_database_path, key_id).ok(),
        _ => None,
    }
}

/// Whether `key_hex` actually unlocks the database at `path`.
///
/// This has to run on its own connection. A SQLCipher key cannot be unset, so a
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
    let state = EncryptionStateFile {
        database_encrypted: true,
        derived_data_encrypted: true,
        key_id,
        key_storage: key_storage.to_string(),
        activated_at: Utc::now(),
        backup_path: String::new(),
    };
    persist_state_for_database_path(database_path, &state)?;
    let key_hex = load_key_for_state(database_path, &state)?;
    remove_recovery_artifacts(database_path, Some(&key_hex))
}

fn persist_state_for_database_path(
    database_path: &Path,
    state: &EncryptionStateFile,
) -> Result<(), SecurityError> {
    let raw = serde_json::to_vec_pretty(state)
        .map_err(|error| SecurityError::Invalid(error.to_string()))?;
    atomic_write_file(&state_path_for_database_path(database_path)?, &raw)
}

/// Write through a same-directory temp file, synchronize its contents, rename
/// it over the destination, and synchronize the parent directory where the
/// platform supports that operation. Rename prevents readers from seeing a
/// partially written destination; startup reconciliation handles platform
/// differences in which side of the rename survives a sudden shutdown. This
/// replaces the bare `fs::write` that bricked the daemon in #109 variant B (a
/// 40-byte prefix of a 219-byte state file).
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
    let written = file
        .write_all(bytes)
        .map_err(io_error)
        .and_then(|()| sync_file(&file));
    // Every failure past this point must remove the temp file. It is named
    // like the destination and sits in the same security directory, so leaving
    // one behind means leaving a stray copy of the state next to the state --
    // and the old code did exactly that on both the write and the rename path.
    if let Err(error) = written {
        let _ = fs::remove_file(&temp);
        return Err(error);
    }
    // Closed before the rename: on Windows a rename cannot replace a file that
    // is still open.
    drop(file);
    if let Err(error) = atomic_rename_file(&temp, path) {
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
    let file_name = database_path
        .file_name()
        .ok_or_else(|| SecurityError::Invalid("database path has no file name".to_string()))?
        .to_string_lossy();
    let temp_name = format!("{file_name}.sqlcipher-{}.partial", Uuid::new_v4());
    let encrypted_temp = db_dir.join(temp_name);

    let verification = (|| {
        export_plaintext_to_encrypted(&database_path, &encrypted_temp, &key_hex)?;
        verify_encrypted_database(&database_path, &encrypted_temp, &key_hex)
    })();
    let (row_counts_verified, integrity_check) = match verification {
        Ok(result) => result,
        Err(error) => return Err(cleanup_candidate_after_error(&encrypted_temp, error)),
    };
    if !row_counts_verified || integrity_check != "ok" {
        let error = SecurityError::Database(format!(
            "encrypted migration verification failed: rows={row_counts_verified}, integrity={integrity_check}"
        ));
        return Err(cleanup_candidate_after_error(&encrypted_temp, error));
    }

    let activated_at = Utc::now();
    let state = EncryptionStateFile {
        database_encrypted: true,
        derived_data_encrypted: true,
        key_id,
        key_storage,
        activated_at,
        backup_path: String::new(),
    };
    let (ready_database, _manifest_path) = promote_verified_candidate(
        &database_path,
        &database_path,
        &encrypted_temp,
        &state,
        &key_hex,
    )?;
    replace_database_with_encrypted_then(&database_path, &ready_database, || {
        write_state(config, &state)?;
        remove_recovery_artifacts(&database_path, Some(&key_hex))
    })?;
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
    validate_key_hex(key_hex)?;
    // Reserve a genuinely new, empty destination. SQLCipher initializes an
    // attached schema before a later key_v2 call, so keying after ATTACH is
    // safe here only because this is a fresh staging database. create_new
    // turns that invariant into an enforced precondition and prevents a UUID
    // collision or stale path from being treated as an existing database.
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let reservation = options.open(encrypted_temp).map_err(io_error)?;
    drop(reservation);

    let export_result = (|| {
        let connection = Connection::open(database_path).map_err(database_error)?;
        let user_version = connection
            .query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))
            .map_err(database_error)?;
        let encrypted_path = encrypted_temp.to_string_lossy();
        connection
            .execute("ATTACH DATABASE ?1 AS encrypted", [encrypted_path.as_ref()])
            .map_err(database_error)?;
        key_database_connection(&connection, b"encrypted\0", key_hex)?;
        connection
            .execute_batch("SELECT sqlcipher_export('encrypted');")
            .map_err(database_error)?;
        connection
            .execute_batch(&format!("PRAGMA encrypted.user_version = {user_version};"))
            .map_err(database_error)?;
        connection
            .execute_batch("DETACH DATABASE encrypted;")
            .map_err(database_error)
    })();
    match export_result {
        Ok(()) => Ok(()),
        Err(error) => Err(cleanup_candidate_after_error(encrypted_temp, error)),
    }
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

fn replace_database_with_encrypted_then(
    database_path: &Path,
    encrypted_temp: &Path,
    publish_state: impl FnOnce() -> Result<(), SecurityError>,
) -> Result<(), SecurityError> {
    let parent = database_path.parent().ok_or_else(|| {
        SecurityError::Invalid("database path has no parent directory".to_string())
    })?;
    let file_name = database_path
        .file_name()
        .ok_or_else(|| SecurityError::Invalid("database path has no file name".to_string()))?
        .to_string_lossy();
    // Never consume the verified recovery candidate during the live swap. On
    // filesystems that can lose the destination directory entry after a power
    // failure, the separate manifest-backed copy is what lets startup restore
    // the database name. The replacement copy is disposable until published.
    let replacement = parent.join(format!(
        "{file_name}.replacement-{}.partial",
        Uuid::new_v4()
    ));
    fs::copy(encrypted_temp, &replacement).map_err(io_error)?;
    let result = replace_file_then(
        &replacement,
        database_path,
        sync_file_contents,
        || {
            remove_sidecar(database_path, "wal")?;
            remove_sidecar(database_path, "shm")
        },
        atomic_rename_file,
        sync_directory,
        publish_state,
    );
    if replacement.exists() {
        fs::remove_file(&replacement).map_err(io_error)?;
    }
    result
}

/// Perform a file replacement in a fixed order: sync the candidate contents,
/// prepare the live path, rename the candidate, request a parent-directory
/// sync where available, and only then publish encryption state. Startup
/// reconciliation handles interrupted-process outcomes if the state and
/// database replacement are observed in a different order. These APIs cannot
/// promise against physical storage failure or power loss beyond each OS's
/// documented sync semantics.
fn replace_file_then(
    source: &Path,
    destination: &Path,
    sync_source: impl FnOnce(&Path) -> Result<(), SecurityError>,
    prepare: impl FnOnce() -> Result<(), SecurityError>,
    rename: impl FnOnce(&Path, &Path) -> Result<(), SecurityError>,
    sync_parent: impl FnOnce(&Path) -> Result<(), SecurityError>,
    publish: impl FnOnce() -> Result<(), SecurityError>,
) -> Result<(), SecurityError> {
    let parent = destination.parent().ok_or_else(|| {
        SecurityError::Invalid("replacement destination has no parent directory".to_string())
    })?;
    sync_source(source)?;
    prepare()?;
    rename(source, destination)?;
    sync_parent(parent)?;
    publish()
}

fn sync_file_contents(path: &Path) -> Result<(), SecurityError> {
    let file = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .map_err(io_error)?;
    sync_file(&file)
}

#[cfg(target_vendor = "apple")]
fn sync_file(file: &fs::File) -> Result<(), SecurityError> {
    use std::os::fd::AsRawFd;

    // Apple documents that fsync alone may leave writes in volatile device
    // cache and reorder them across a power loss. F_FULLFSYNC also asks the
    // device to flush those buffers. Require it rather than silently falling
    // back to fsync; Apple still documents this as best effort.
    let result = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_FULLFSYNC) };
    if result == -1 {
        Err(io_error(std::io::Error::last_os_error()))
    } else {
        Ok(())
    }
}

#[cfg(not(target_vendor = "apple"))]
fn sync_file(file: &fs::File) -> Result<(), SecurityError> {
    file.sync_all().map_err(io_error)
}

#[cfg(unix)]
fn atomic_rename_file(source: &Path, destination: &Path) -> Result<(), SecurityError> {
    fs::rename(source, destination).map_err(io_error)
}

#[cfg(windows)]
fn atomic_rename_file(source: &Path, destination: &Path) -> Result<(), SecurityError> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH, MoveFileExW,
    };

    let source: Vec<u16> = source.as_os_str().encode_wide().chain(Some(0)).collect();
    let destination: Vec<u16> = destination
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect();
    // The temp and destination are in the same directory. WRITE_THROUGH
    // requests write-through handling for this same-volume replacement;
    // REPLACE_EXISTING is required because activation replaces the live
    // plaintext database. Startup reconciliation still verifies the actual
    // database and key before trusting the published state.
    let moved = unsafe {
        MoveFileExW(
            source.as_ptr(),
            destination.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if moved == 0 {
        Err(io_error(std::io::Error::last_os_error()))
    } else {
        Ok(())
    }
}

#[cfg(not(any(unix, windows)))]
fn atomic_rename_file(_source: &Path, _destination: &Path) -> Result<(), SecurityError> {
    Err(SecurityError::Io(
        "durable database replacement is unsupported on this platform".to_string(),
    ))
}

#[cfg(all(unix, not(target_vendor = "apple")))]
fn sync_directory(parent: &Path) -> Result<(), SecurityError> {
    fs::File::open(parent)
        .and_then(|dir| dir.sync_all())
        .map_err(io_error)
}

#[cfg(target_vendor = "apple")]
fn sync_directory(parent: &Path) -> Result<(), SecurityError> {
    let directory = fs::File::open(parent).map_err(io_error)?;
    // Apple documents F_FULLFSYNC for file contents, but does not promise that
    // it commits directory-entry changes. Use the available directory fsync;
    // startup reconciliation treats the actual database header as authority
    // if a power loss exposes the state and replacement in a different order.
    directory.sync_all().map_err(io_error)
}

#[cfg(windows)]
fn sync_directory(_parent: &Path) -> Result<(), SecurityError> {
    // atomic_rename_file requests MOVEFILE_WRITE_THROUGH. Windows exposes no
    // portable directory-handle flush here; startup reconciliation verifies
    // the database contents against the stored key and state.
    Ok(())
}

#[cfg(not(any(unix, windows)))]
fn sync_directory(_parent: &Path) -> Result<(), SecurityError> {
    Err(SecurityError::Io(
        "durable directory synchronization is unsupported on this platform".to_string(),
    ))
}

fn checkpoint_plaintext_database(database_path: &Path) -> Result<(), SecurityError> {
    let connection = Connection::open(database_path).map_err(database_error)?;
    let (busy, log_frames, checkpointed_frames) = connection
        .query_row("PRAGMA wal_checkpoint(FULL)", [], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, i64>(2)?,
            ))
        })
        .map_err(database_error)?;
    let checkpoint_complete = (log_frames == -1 && checkpointed_frames == -1)
        || (log_frames >= 0 && checkpointed_frames == log_frames);
    if busy != 0 || !checkpoint_complete {
        return Err(SecurityError::Database(format!(
            "plaintext database WAL checkpoint did not complete (busy={busy}, log_frames={log_frames}, checkpointed_frames={checkpointed_frames}); retry after database readers release their snapshots"
        )));
    }
    Ok(())
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

// Apply SQLCipher key material from secure storage (test file store only in
// tests). The validated raw-key specification is passed to SQLCipher's C API,
// never embedded in SQL text or persisted by this function.
fn key_connection(connection: &Connection, key_hex: &str) -> Result<(), SecurityError> {
    key_database_connection(connection, b"main\0", key_hex)
}

fn key_database_connection(
    connection: &Connection,
    database_name: &'static [u8],
    key_hex: &str,
) -> Result<(), SecurityError> {
    validate_key_hex(key_hex)?;
    let database_name = CStr::from_bytes_with_nul(database_name).map_err(|error| {
        SecurityError::Invalid(format!("invalid SQLCipher database name: {error}"))
    })?;
    let key = sqlcipher_key_spec(key_hex)?;
    // SQLCipher's C key API is equivalent to PRAGMA key, but avoids copying
    // key material into SQL source text, trace output, or SQL error context.
    // The pointer is used only for this call; SQLCipher retains its internal
    // codec key for the lifetime of the connection.
    let result = unsafe {
        ffi::sqlite3_key_v2(
            connection.handle(),
            database_name.as_ptr(),
            key.as_ptr().cast(),
            key.len() as i32,
        )
    };
    if result == ffi::SQLITE_OK {
        Ok(())
    } else {
        Err(database_error(rusqlite::Error::SqliteFailure(
            ffi::Error::new(result),
            None,
        )))
    }
}

fn sqlcipher_key_spec(key_hex: &str) -> Result<Zeroizing<Vec<u8>>, SecurityError> {
    validate_key_hex(key_hex)?;
    // Preserve the exact raw-key syntax previously passed through `PRAGMA
    // key = "x'…'"`. SQLCipher's C API treats arbitrary bytes as a passphrase,
    // so passing only the decoded 32-byte value would derive a different key.
    // Keeping this validated keyspec in zeroizing memory preserves existing
    // vault compatibility without embedding secret material in SQL text.
    let mut key = Zeroizing::new(Vec::with_capacity(key_hex.len() + 3));
    key.extend_from_slice(b"x'");
    key.extend_from_slice(key_hex.as_bytes());
    key.push(b'\'');
    Ok(key)
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
    validate_key_hex(key_hex)?;
    #[cfg(test)]
    {
        store_key_in_file(config, key_id, key_hex)
    }
    #[cfg(not(test))]
    {
        let _ = config;
        let entry = keyring::Entry::new(KEYRING_SERVICE, key_id)
            .map_err(|error| SecurityError::KeyStorage(error.to_string()))?;
        entry
            .set_password(key_hex)
            .map_err(|error| SecurityError::KeyStorage(error.to_string()))?;
        Ok("os_keychain".to_string())
    }
}

fn load_key_for_state(
    _database_path: &Path,
    state: &EncryptionStateFile,
) -> Result<String, SecurityError> {
    if state.key_storage == "test_file_key_store" {
        #[cfg(test)]
        return load_key_from_file(_database_path, &state.key_id);
        #[cfg(not(test))]
        return Err(SecurityError::KeyStorage(
            "test-only key storage is unavailable in production builds".to_string(),
        ));
    }

    let entry = keyring::Entry::new(KEYRING_SERVICE, &state.key_id)
        .map_err(|error| SecurityError::KeyStorage(error.to_string()))?;
    let key = entry
        .get_password()
        .map_err(|error| SecurityError::KeyStorage(error.to_string()))?;
    validate_key_hex(&key)?;
    Ok(key)
}

fn validate_key_hex(key_hex: &str) -> Result<(), SecurityError> {
    if key_hex.len() == 64 && key_hex.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        Ok(())
    } else {
        Err(SecurityError::KeyStorage(
            "SQLCipher key must be exactly 32 bytes encoded as 64 hexadecimal characters"
                .to_string(),
        ))
    }
}

#[cfg(test)]
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

#[cfg(test)]
fn load_key_from_file(database_path: &Path, key_id: &str) -> Result<String, SecurityError> {
    let runtime_root = database_path
        .parent()
        .and_then(Path::parent)
        .ok_or_else(|| SecurityError::Invalid("database path has no runtime root".to_string()))?;
    fs::read_to_string(key_file_path(runtime_root, key_id))
        .map_err(io_error)
        .and_then(|value| {
            let trimmed = value.trim();
            validate_key_hex(trimmed)?;
            Ok(trimmed.to_string())
        })
}

#[cfg(test)]
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

fn cleanup_candidate_after_error(path: &Path, primary_error: SecurityError) -> SecurityError {
    match fs::remove_file(path) {
        Ok(()) => primary_error,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => primary_error,
        Err(cleanup_error) => SecurityError::Io(format!(
            "{primary_error}; failed to remove temporary candidate {}: {cleanup_error}",
            path.display()
        )),
    }
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

    fn stage_verified_copy_for_test(database_path: &Path, state: &EncryptionStateFile, key: &str) {
        let metadata = encrypted_candidate_metadata(database_path, key)
            .expect("source encrypted database must validate");
        let parent = database_path.parent().unwrap();
        let database_name = database_path.file_name().unwrap().to_string_lossy();
        let transaction_id = Uuid::new_v4().to_string();
        let staged_database = parent.join(format!("{database_name}.ready-{transaction_id}.db"));
        let manifest_path = parent.join(format!("{database_name}.ready-{transaction_id}.json"));
        fs::copy(database_path, &staged_database).expect("copy encrypted database");
        let manifest = EncryptionRecoveryManifest {
            transaction_id,
            database_file: database_name.to_string(),
            key_id: state.key_id.clone(),
            key_storage: state.key_storage.clone(),
            database_sha256: metadata.sha256,
            user_version: metadata.user_version,
            row_counts: metadata.row_counts,
        };
        let raw = serde_json::to_vec(&manifest).expect("serialize recovery manifest");
        atomic_write_file(&manifest_path, &raw).expect("persist recovery manifest");
    }

    fn cleanup(root: &Path) {
        let _ = fs::remove_dir_all(root);
    }

    /// Peak resident set size of this process, in bytes, from the kernel.
    #[cfg(target_os = "linux")]
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
    /// This measurement uses Linux procfs; the behavior is also exercised by
    /// the portable header-classification tests on every target.
    #[cfg(target_os = "linux")]
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

    /// Replacing existing state must work on every supported platform.
    /// On Unix, permissions are also a security property: a file an operator
    /// has tightened keeps its mode, and a new file is created 0600 rather
    /// than inheriting the process umask.
    #[test]
    fn atomic_write_replaces_existing_state_and_preserves_unix_mode() {
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
        }

        atomic_write_file(&target, b"{\"second\":true}").expect("rewrite must succeed");

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

    #[test]
    fn activation_preserves_committed_wal_frames_when_a_reader_blocks_checkpoint() {
        let (config, root) = test_config("blocked-wal-checkpoint");
        seed_db(&config);
        let database_path = config.database_path();

        let writer = Connection::open(&database_path).expect("writer must open");
        writer
            .pragma_update(None, "wal_autocheckpoint", 0_i64)
            .expect("automatic checkpoint must be disabled for this fixture");
        let reader = Connection::open(&database_path).expect("reader must open");
        reader
            .execute_batch("BEGIN DEFERRED;")
            .expect("reader transaction must begin");
        let initial_rows: i64 = reader
            .query_row("SELECT COUNT(*) FROM recovery_canary", [], |row| row.get(0))
            .expect("reader must establish a WAL snapshot");
        assert_eq!(initial_rows, 1);

        writer
            .execute(
                "INSERT INTO recovery_canary (note) VALUES ('committed-in-wal')",
                [],
            )
            .expect("new row must commit to the WAL");
        let mut wal_path = database_path.as_os_str().to_os_string();
        wal_path.push("-wal");
        let wal_path = PathBuf::from(wal_path);
        assert!(wal_path.exists(), "committed row must remain in the WAL");

        let error = activate_encryption(&config)
            .expect_err("activation must stop before staging if FULL checkpoint is blocked");
        assert!(
            error
                .to_string()
                .contains("WAL checkpoint did not complete"),
            "the failure must identify the incomplete checkpoint: {error}"
        );
        assert!(
            !state_path(&config).exists(),
            "activation must not persist a key state before checkpoint completion"
        );
        assert!(wal_path.exists(), "activation must preserve the live WAL");

        let live = Connection::open(&database_path).expect("live database must still open");
        let committed_rows: i64 = live
            .query_row("SELECT COUNT(*) FROM recovery_canary", [], |row| row.get(0))
            .expect("committed WAL data must remain readable");
        assert_eq!(committed_rows, 2);
        drop(live);

        reader
            .execute_batch("ROLLBACK;")
            .expect("reader snapshot must be released");
        drop(reader);
        drop(writer);

        checkpoint_plaintext_database(&database_path)
            .expect("checkpoint must complete after the reader releases its snapshot");
        let replacement = root.join("injected-replacement.partial");
        fs::write(&replacement, b"replacement candidate")
            .expect("replacement fixture must be written");
        let publish_called = std::cell::Cell::new(false);
        let prepare_called = std::cell::Cell::new(false);
        let rename_called = std::cell::Cell::new(false);
        let failed_replacement = replace_file_then(
            &replacement,
            &database_path,
            sync_file_contents,
            || {
                prepare_called.set(true);
                remove_sidecar(&database_path, "wal")?;
                remove_sidecar(&database_path, "shm")
            },
            |_, _| {
                rename_called.set(true);
                Err(SecurityError::Io(
                    "injected database replacement rename failure".to_string(),
                ))
            },
            sync_directory,
            || {
                publish_called.set(true);
                Ok(())
            },
        );
        assert!(
            failed_replacement.is_err(),
            "injected replacement failure must stop activation"
        );
        assert!(
            prepare_called.get(),
            "replacement failure must occur after the production sidecar preparation step"
        );
        assert!(
            rename_called.get(),
            "replacement failure must reach the injected rename operation"
        );
        assert!(
            !publish_called.get(),
            "state must not publish after the injected replacement failure"
        );
        fs::remove_file(&replacement).expect("failed replacement fixture must be removed");
        let after_rename_failure =
            Connection::open(&database_path).expect("checkpointed plaintext database must open");
        let rows_after_rename_failure: i64 = after_rename_failure
            .query_row("SELECT COUNT(*) FROM recovery_canary", [], |row| row.get(0))
            .expect("all committed rows must survive a failed replacement");
        assert_eq!(rows_after_rename_failure, 2);
        drop(after_rename_failure);

        activate_encryption(&config)
            .expect("activation must converge after the reader releases its snapshot");
        let encrypted = open_database(&database_path).expect("encrypted database must reopen");
        let recovered_rows: i64 = encrypted
            .query_row("SELECT COUNT(*) FROM recovery_canary", [], |row| row.get(0))
            .expect("encrypted database must retain the WAL-committed row");
        assert_eq!(recovered_rows, 2);
        drop(encrypted);
        cleanup(&root);
    }

    #[test]
    fn database_replacement_publishes_state_only_after_both_durability_barriers() {
        use std::cell::RefCell;

        let expected = [
            "sync_source",
            "prepare",
            "rename",
            "sync_parent",
            "publish_state",
        ];
        for (failure, expected_events) in [
            (Some("sync_source"), &expected[..1]),
            (Some("prepare"), &expected[..2]),
            (Some("rename"), &expected[..3]),
            (Some("sync_parent"), &expected[..4]),
            (None, &expected[..]),
        ] {
            let events = RefCell::new(Vec::new());
            let record = |name: &'static str| {
                events.borrow_mut().push(name);
                if failure == Some(name) {
                    Err(SecurityError::Io(format!("injected {name} failure")))
                } else {
                    Ok(())
                }
            };
            let result = replace_file_then(
                Path::new("db/encrypted.tmp"),
                Path::new("db/library.sqlite3"),
                |_| record("sync_source"),
                || record("prepare"),
                |_, _| record("rename"),
                |_| record("sync_parent"),
                || {
                    events.borrow_mut().push("publish_state");
                    Ok(())
                },
            );

            assert_eq!(
                events.borrow().as_slice(),
                expected_events,
                "failure at {failure:?} must not publish state before durable database replacement"
            );
            assert_eq!(
                result.is_ok(),
                failure.is_none(),
                "the sequence should fail closed at injected barrier {failure:?}"
            );
        }
    }

    #[test]
    fn failed_database_barrier_or_state_write_recovers_through_startup() {
        use std::cell::Cell;

        for failure in ["sync_parent", "publish_state"] {
            let (config, root) = test_config(&format!("replace-failure-{failure}"));
            seed_db(&config);
            activate_encryption(&config).expect("initial activation must succeed");
            let database_path = config.database_path();
            let state = read_state(&config)
                .expect("state must be readable")
                .expect("state must exist");
            let candidate = root.join("encrypted-replacement.tmp");
            fs::copy(&database_path, &candidate).expect("make encrypted replacement fixture");
            fs::remove_file(state_path(&config)).expect("simulate missing state after crash");
            let published = Cell::new(false);

            let result = replace_file_then(
                &candidate,
                &database_path,
                sync_file_contents,
                || {
                    remove_sidecar(&database_path, "wal")?;
                    remove_sidecar(&database_path, "shm")
                },
                atomic_rename_file,
                |parent| {
                    if failure == "sync_parent" {
                        Err(SecurityError::Io(
                            "injected parent sync failure".to_string(),
                        ))
                    } else {
                        sync_directory(parent)
                    }
                },
                || {
                    published.set(true);
                    if failure == "publish_state" {
                        Err(SecurityError::Io(
                            "injected state write failure".to_string(),
                        ))
                    } else {
                        persist_state_for_database_path(&database_path, &state)
                    }
                },
            );

            assert!(result.is_err(), "injected {failure} must fail activation");
            assert_eq!(
                published.get(),
                failure == "publish_state",
                "state publication must not run before the database barrier"
            );
            assert!(
                !state_path(&config).exists(),
                "failed activation must leave startup recovery authoritative"
            );

            let connection = open_database(&database_path)
                .expect("startup must recover the actual replacement after injected failure");
            let note: String = connection
                .query_row("SELECT note FROM recovery_canary", [], |row| row.get(0))
                .expect("recovered database must retain the original data");
            assert_eq!(note, "before-activation");
            assert!(state_path(&config).exists(), "startup must rebuild state");
            drop(connection);
            cleanup(&root);
        }
    }

    #[test]
    fn missing_database_recovers_from_verified_staging_file() {
        for keep_state in [true, false] {
            let (config, root) = test_config(if keep_state {
                "missing-db-with-state"
            } else {
                "missing-db-without-state"
            });
            seed_db(&config);
            let database_path = config.database_path();
            activate_encryption(&config).expect("initial activation must succeed");
            let state_path = state_path(&config);
            let state = read_state(&config)
                .expect("state must be readable")
                .expect("state must exist");
            let key_hex = load_key_for_state(&database_path, &state).expect("key must load");
            stage_verified_copy_for_test(&database_path, &state, &key_hex);
            let stale_partial = database_path.parent().unwrap().join(format!(
                "{}.stale.partial",
                database_path.file_name().unwrap().to_string_lossy()
            ));
            fs::write(&stale_partial, b"incomplete previous export")
                .expect("create unrelated stale partial");
            fs::remove_file(&database_path).expect("simulate a missing destination name");
            if !keep_state {
                fs::remove_file(&state_path).expect("simulate missing state");
            }

            let connection = open_database(&database_path)
                .expect("startup must install a verified staged encrypted database");
            let note: String = connection
                .query_row("SELECT note FROM recovery_canary", [], |row| row.get(0))
                .expect("recovered database must retain its data");
            assert_eq!(note, "before-activation");
            assert!(database_file_is_encrypted(&database_path));
            assert!(
                !stale_partial.exists(),
                "stale partial should be cleaned after verified restore"
            );
            if !keep_state {
                let recovered = read_state(&config)
                    .expect("recovered state must parse")
                    .expect("recovered state must exist");
                assert_eq!(recovered.key_id, state.key_id);
            }
            drop(connection);
            cleanup(&root);
        }
    }

    #[test]
    fn missing_live_name_after_replacement_restores_from_preserved_candidate() {
        let (config, root) = test_config("missing-live-name-after-replacement");
        seed_db(&config);
        let database_path = config.database_path();
        activate_encryption(&config).expect("initial activation must succeed");
        let state = read_state(&config)
            .expect("state must be readable")
            .expect("state must exist");
        let key_hex = load_key_for_state(&database_path, &state).expect("key must load");
        stage_verified_copy_for_test(&database_path, &state, &key_hex);
        let ready_prefix = format!(
            "{}.ready-",
            database_path.file_name().unwrap().to_string_lossy()
        );
        let ready_database = fs::read_dir(database_path.parent().unwrap())
            .expect("database directory must be readable")
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .find(|path| {
                path.file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.starts_with(&ready_prefix) && name.ends_with(".db"))
            })
            .expect("verified recovery candidate must exist");

        let interrupted =
            replace_database_with_encrypted_then(&database_path, &ready_database, || {
                // Model a platform power-loss observation where the target
                // name is absent after the replacement rename, before state
                // publication completes.
                fs::remove_file(&database_path).map_err(io_error)?;
                Err(SecurityError::Io(
                    "injected lost destination name".to_string(),
                ))
            });
        assert!(
            interrupted.is_err(),
            "injected interruption must fail closed"
        );
        assert!(
            !database_path.exists(),
            "fixture must model a missing live name"
        );
        assert!(
            ready_database.exists(),
            "replacement must preserve the verified recovery candidate"
        );

        assert!(
            recover_missing_database(&database_path, Some(&state))
                .expect("startup must restore from the retained candidate"),
            "a missing live name must be recovered"
        );
        let connection =
            open_database(&database_path).expect("restored encrypted database must open");
        let note: String = connection
            .query_row("SELECT note FROM recovery_canary", [], |row| row.get(0))
            .expect("restored database must preserve the canary row");
        assert_eq!(note, "before-activation");
        drop(connection);
        cleanup(&root);
    }

    #[test]
    fn existing_plaintext_database_wins_over_an_older_verified_stage() {
        let (config, root) = test_config("stale-stage-does-not-roll-back");
        seed_db(&config);
        let database_path = config.database_path();
        let plaintext_source = database_path.with_extension("plaintext-fixture");
        fs::copy(&database_path, &plaintext_source).expect("preserve initial plaintext database");
        activate_encryption(&config).expect("initial activation must succeed");

        let state = read_state(&config)
            .expect("state must be readable")
            .expect("state must exist");
        let key_hex = load_key_for_state(&database_path, &state).expect("key must load");
        stage_verified_copy_for_test(&database_path, &state, &key_hex);

        fs::copy(&plaintext_source, &database_path).expect("simulate state-ahead plaintext");
        let newer = Connection::open(&database_path).expect("plaintext database must open");
        newer
            .execute(
                "INSERT INTO recovery_canary (note) VALUES (?1)",
                ["written-after-the-stage"],
            )
            .expect("write newer row");
        drop(newer);

        let recovered = open_database(&database_path)
            .expect("startup must encrypt the current plaintext database");
        let row_count: i64 = recovered
            .query_row(
                "SELECT count(*) FROM recovery_canary WHERE note = 'written-after-the-stage'",
                [],
                |row| row.get(0),
            )
            .expect("newer row must survive encryption recovery");
        assert_eq!(row_count, 1, "recovery must not install the older stage");
        assert!(database_file_is_encrypted(&database_path));
        assert!(
            !fs::read_dir(database_path.parent().unwrap())
                .unwrap()
                .any(|entry| entry
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .contains(".ready-")),
            "stale stages must be removed after the live database is recovered"
        );
        drop(recovered);
        cleanup(&root);
    }

    #[test]
    fn missing_database_refuses_unverified_partial_instead_of_creating_empty_database() {
        let (config, root) = test_config("missing-db-partial");
        seed_db(&config);
        let database_path = config.database_path();
        let partial = database_path.parent().unwrap().join(format!(
            "{}.crash.partial",
            database_path.file_name().unwrap().to_string_lossy()
        ));
        fs::write(&partial, b"incomplete SQLCipher export").expect("write partial fixture");
        fs::remove_file(&database_path).expect("simulate lost database name");

        assert!(open_database(&database_path).is_err());
        assert!(
            !database_path.exists(),
            "recovery must not create an empty replacement"
        );
        cleanup(&root);
    }

    #[test]
    fn verified_but_empty_encrypted_candidate_cannot_replace_populated_database() {
        let (config, root) = test_config("empty-encrypted-candidate");
        seed_db(&config);
        let database_path = config.database_path();
        let key_hex = "ab".repeat(32);
        let key_id = key_id_for_path(&database_path);
        let state = EncryptionStateFile {
            database_encrypted: true,
            derived_data_encrypted: true,
            key_id,
            key_storage: "test_file_key_store".to_string(),
            activated_at: Utc::now(),
            backup_path: String::new(),
        };
        let partial = database_path.with_extension("empty-candidate.partial");
        let empty = Connection::open(&partial).expect("create empty candidate");
        key_connection(&empty, &key_hex).expect("apply candidate encryption key");
        empty
            .execute_batch("CREATE TABLE empty_canary (id INTEGER PRIMARY KEY);")
            .expect("write a valid encrypted but empty database");
        drop(empty);

        assert!(
            promote_verified_candidate(&database_path, &database_path, &partial, &state, &key_hex)
                .is_err()
        );
        assert!(
            !fs::read_dir(database_path.parent().unwrap())
                .unwrap()
                .any(|entry| entry
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .contains(".ready-")),
            "a candidate that omits live rows must never become recoverable"
        );
        cleanup(&root);
    }

    #[test]
    fn corrupt_live_database_keeps_verified_recovery_copy() {
        use std::io::{Seek, SeekFrom};

        let (config, root) = test_config("corrupt-live-retains-stage");
        seed_db(&config);
        activate_encryption(&config).expect("activation must succeed");
        let database_path = config.database_path();
        let state = read_state(&config)
            .expect("state must be readable")
            .expect("state must exist");
        let key_hex = load_key_for_state(&database_path, &state).expect("key must load");
        stage_verified_copy_for_test(&database_path, &state, &key_hex);

        let connection = Connection::open(&database_path).expect("encrypted file opens");
        key_connection(&connection, &key_hex).expect("key applies");
        let page_size = connection
            .query_row("PRAGMA cipher_page_size", [], |row| row.get::<_, String>(0))
            .expect("read database page size")
            .parse::<u64>()
            .expect("page size must be numeric");
        drop(connection);
        let mut file = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&database_path)
            .expect("open live database for corruption fixture");
        let offset = page_size + 64;
        file.seek(SeekFrom::Start(offset))
            .expect("seek into data page");
        let mut byte = [0_u8; 1];
        std::io::Read::read_exact(&mut file, &mut byte).expect("read data page byte");
        byte[0] ^= 0x80;
        file.seek(SeekFrom::Start(offset))
            .expect("seek back into data page");
        std::io::Write::write_all(&mut file, &byte).expect("corrupt data page");
        file.sync_all().expect("persist corruption fixture");
        drop(file);

        assert!(open_database(&database_path).is_err());
        assert!(
            fs::read_dir(database_path.parent().unwrap())
                .unwrap()
                .any(|entry| entry
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .contains(".ready-")),
            "integrity failure must retain the verified recovery copy"
        );
        cleanup(&root);
    }

    #[test]
    fn missing_database_rejects_ambiguous_verified_manifests() {
        let (config, root) = test_config("missing-db-ambiguous");
        seed_db(&config);
        let database_path = config.database_path();
        activate_encryption(&config).expect("activation must succeed");
        let state = read_state(&config)
            .expect("state must be readable")
            .unwrap();
        let key_hex = load_key_for_state(&database_path, &state).expect("key must load");
        for _ in 0..2 {
            stage_verified_copy_for_test(&database_path, &state, &key_hex);
        }
        fs::remove_file(&database_path).expect("simulate missing database");

        assert!(open_database(&database_path).is_err());
        assert!(
            !database_path.exists(),
            "ambiguous candidates must not be selected"
        );
        cleanup(&root);
    }

    #[test]
    fn sqlcipher_key_input_requires_exact_hex_encoding() {
        assert!(validate_key_hex(&"ab".repeat(32)).is_ok());
        let expected = (0_u8..32).collect::<Vec<_>>();
        let encoded = hex_string(&expected);
        assert_eq!(
            sqlcipher_key_spec(&encoded).unwrap().as_slice(),
            format!("x'{encoded}'").as_bytes()
        );
        let uppercase = encoded.to_uppercase();
        assert_eq!(
            sqlcipher_key_spec(&uppercase).unwrap().as_slice(),
            format!("x'{uppercase}'").as_bytes()
        );
        assert!(validate_key_hex(&"a".repeat(63)).is_err());
        assert!(validate_key_hex(&"a".repeat(65)).is_err());
        assert!(sqlcipher_key_spec(&"a".repeat(63)).is_err());
        assert!(validate_key_hex(&format!("{}' OR 1=1 --", "a".repeat(56))).is_err());
        assert!(validate_key_hex(&format!("{}é", "a".repeat(62))).is_err());
    }

    #[test]
    fn failed_candidate_cleanup_preserves_the_cause_and_reports_cleanup_failure() {
        let (_config, root) = test_config("candidate-cleanup-errors");
        let candidate = root.join("candidate.partial");
        fs::write(&candidate, b"partial candidate").expect("candidate fixture must exist");

        let error = cleanup_candidate_after_error(
            &candidate,
            SecurityError::Database("verification failed".to_string()),
        );
        assert_eq!(
            error.to_string(),
            "encrypted database operation failed: verification failed"
        );
        assert!(!candidate.exists(), "failed candidate must be removed");

        let directory = root.join("not-a-file");
        fs::create_dir(&directory).expect("directory fixture must exist");
        let error = cleanup_candidate_after_error(
            &directory,
            SecurityError::Database("export failed".to_string()),
        );
        let message = error.to_string();
        assert!(message.contains("export failed"));
        assert!(message.contains("failed to remove temporary candidate"));
        cleanup(&root);
    }

    #[test]
    fn key_api_remains_compatible_with_legacy_pragma_and_attached_export() {
        let (_config, root) = test_config("legacy-key-api-compatibility");
        let source_path = root.join("legacy.db");
        let plaintext_path = root.join("plaintext.db");
        let encrypted_path = root.join("exported.db");
        let key_hex = "ab".repeat(32);

        let legacy = Connection::open(&source_path).expect("legacy fixture must open");
        legacy
            .execute_batch(&format!(
                "PRAGMA key = \"x'{key_hex}'\"; \
                 CREATE TABLE secret(value TEXT NOT NULL); \
                 INSERT INTO secret VALUES ('legacy-ciphertext');"
            ))
            .expect("legacy PRAGMA format must create encrypted data");
        drop(legacy);

        let migrated = Connection::open(&source_path).expect("legacy db handle must open");
        key_connection(&migrated, &key_hex)
            .expect("C key API must open databases written with the old PRAGMA format");
        let value: String = migrated
            .query_row("SELECT value FROM secret", [], |row| row.get(0))
            .expect("legacy rows must remain readable");
        assert_eq!(value, "legacy-ciphertext");
        let integrity: String = migrated
            .query_row("PRAGMA integrity_check", [], |row| row.get(0))
            .expect("legacy integrity check must run");
        assert_eq!(integrity, "ok");
        drop(migrated);

        let plaintext = Connection::open(&plaintext_path).expect("plaintext fixture must open");
        plaintext
            .execute_batch(
                "CREATE TABLE secret(value TEXT NOT NULL); \
                 INSERT INTO secret VALUES ('legacy-ciphertext');",
            )
            .expect("plaintext fixture data must be created");
        drop(plaintext);

        export_plaintext_to_encrypted(&plaintext_path, &encrypted_path, &key_hex)
            .expect("attach then key then export must succeed");
        assert!(database_file_is_encrypted(&encrypted_path));
        assert_ne!(
            &fs::read(&encrypted_path).expect("exported database must exist")[..16],
            b"SQLite format 3\0"
        );

        let exported = Connection::open(&encrypted_path).expect("exported db handle must open");
        exported
            .execute_batch(&format!("PRAGMA key = \"x'{key_hex}'\";"))
            .expect("old PRAGMA key format must reopen exported database");
        let value: String = exported
            .query_row("SELECT value FROM secret", [], |row| row.get(0))
            .expect("exported row must be readable with the old key format");
        assert_eq!(value, "legacy-ciphertext");
        let integrity: String = exported
            .query_row("PRAGMA integrity_check", [], |row| row.get(0))
            .expect("exported integrity check must run");
        assert_eq!(integrity, "ok");
        drop(exported);

        let existing_path = root.join("existing-target.db");
        fs::write(&existing_path, b"preserve existing target")
            .expect("existing target fixture must be created");
        assert!(export_plaintext_to_encrypted(&plaintext_path, &existing_path, &key_hex).is_err());
        assert_eq!(
            fs::read(&existing_path).expect("existing target must remain"),
            b"preserve existing target"
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

    /// Filesystems can expose the state-file rename before the database
    /// rename survives interruption. Startup must compare the database
    /// header with the state and complete encryption before returning it.
    #[test]
    fn state_ahead_of_plaintext_database_reencrypts_before_open() {
        let (config, root) = test_config("state-ahead-of-database");
        seed_db(&config);
        let plaintext = root.join("plaintext-before-activation.sqlite3");
        fs::copy(config.database_path(), &plaintext).expect("save plaintext recovery fixture");
        activate_encryption(&config).expect("activation must succeed");

        // Model a possible filesystem outcome where encryption state is
        // present but the database directory entry reverted to plaintext.
        fs::copy(&plaintext, config.database_path()).expect("restore plaintext observation");
        let connection = open_database(&config.database_path())
            .expect("startup must finish encryption before opening the library");
        let note: String = connection
            .query_row("SELECT note FROM recovery_canary", [], |row| row.get(0))
            .expect("the verified encrypted database must retain its data");
        assert_eq!(note, "before-activation");
        assert!(
            database_file_is_encrypted(&config.database_path()),
            "startup must not return while the library remains plaintext"
        );
        drop(connection);
        cleanup(&root);
    }

    #[test]
    fn torn_state_with_plaintext_database_recovers_from_verified_key() {
        let (config, root) = test_config("torn-state-plaintext-database");
        seed_db(&config);
        let plaintext = root.join("plaintext-before-activation.sqlite3");
        fs::copy(config.database_path(), &plaintext).expect("save plaintext recovery fixture");
        activate_encryption(&config).expect("activation must succeed");

        fs::copy(&plaintext, config.database_path()).expect("restore plaintext observation");
        fs::write(state_path(&config), "{\"database_encrypted\": tru")
            .expect("model a torn state rename");
        let connection = open_database(&config.database_path())
            .expect("startup must recover a torn state using a verified stored key");
        let note: String = connection
            .query_row("SELECT note FROM recovery_canary", [], |row| row.get(0))
            .expect("recovered database must retain its data");
        assert_eq!(note, "before-activation");
        let recovered_state = read_state(&config)
            .expect("recovered state must parse")
            .expect("recovered state must exist");
        assert!(recovered_state.database_encrypted);
        assert!(database_file_is_encrypted(&config.database_path()));
        drop(connection);
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
