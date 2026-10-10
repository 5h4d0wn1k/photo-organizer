use std::fs;

use native_core::security;
use rusqlite::Connection;
use sha2::{Digest, Sha256};
use uuid::Uuid;

#[test]
fn production_library_ignores_test_file_key_store() {
    let root = std::env::temp_dir().join(format!("photo-organizer-key-store-{}", Uuid::new_v4()));
    let db_dir = root.join("db");
    let key_dir = root.join("security").join("test-keys");
    fs::create_dir_all(&db_dir).expect("create database fixture directory");
    fs::create_dir_all(&key_dir).expect("create fake test-key directory");

    let database_path = db_dir.join("gallery.sqlite3");
    let database_path_text = database_path.to_string_lossy();
    let digest = Sha256::digest(database_path_text.as_bytes());
    let digest_hex = digest
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    let key_id = format!("library-{}", &digest_hex[..24]);
    let key = "ab".repeat(32);
    let connection = Connection::open(&database_path).expect("create encrypted fixture");
    connection
        .execute_batch(&format!(
            "PRAGMA key = \"x'{key}'\"; CREATE TABLE private_data(value TEXT); INSERT INTO private_data VALUES ('sealed');"
        ))
        .expect("encrypt fixture data");
    drop(connection);

    fs::write(key_dir.join(format!("{key_id}.key")), &key).expect("plant test-only key file");
    let state_dir = root.join("security");
    fs::write(
        state_dir.join("encryption_status.json"),
        format!(
            "{{\"database_encrypted\":true,\"derived_data_encrypted\":true,\"key_id\":\"{key_id}\",\"key_storage\":\"test_file_key_store\",\"activated_at\":\"2026-01-01T00:00:00Z\",\"backup_path\":\"\"}}"
        ),
    )
    .expect("write test-only key-store marker");

    assert!(
        security::open_database(&database_path).is_err(),
        "production library must not read the planted test-key file"
    );
    fs::remove_dir_all(root).expect("remove test fixture");
}
