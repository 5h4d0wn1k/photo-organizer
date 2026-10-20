use std::{fs, process::Command};

use native_core::domain::VaultKeyStorage;
use native_core::{AppConfig, GalleryService};
use uuid::Uuid;

#[test]
fn production_daemon_rejects_file_override_before_creating_runtime() {
    let root = std::env::temp_dir().join(format!("vault-backend-rejection-{}", Uuid::new_v4()));
    let output = Command::new(env!("CARGO_BIN_EXE_galleryd"))
        .env("PRIVATE_GALLERY_RUNTIME_ROOT", &root)
        .env("PRIVATE_GALLERY_VAULT_KEY_STORAGE", "file")
        .output()
        .expect("run production daemon");
    assert!(!output.status.success());
    assert!(
        !root.exists(),
        "backend rejection must precede database or directory creation"
    );
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("plaintext file storage is forbidden")
    );
}

#[test]
fn production_service_rejects_legacy_key_directory_before_creating_database() {
    let root = std::env::temp_dir().join(format!("vault-legacy-rejection-{}", Uuid::new_v4()));
    fs::create_dir_all(root.join("security/vault-keys")).unwrap();
    let config = AppConfig {
        runtime_root: root.clone(),
        ..AppConfig::default()
    };
    assert!(GalleryService::new(config).is_err());
    assert!(
        !root.join("db").exists(),
        "legacy storage rejection must precede bootstrap"
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn production_service_rejects_file_backend_config_before_creating_runtime() {
    let root = std::env::temp_dir().join(format!("vault-config-rejection-{}", Uuid::new_v4()));
    let config = AppConfig {
        runtime_root: root.clone(),
        vault_key_storage: VaultKeyStorage::File,
        ..AppConfig::default()
    };
    assert!(GalleryService::new(config).is_err());
    assert!(
        !root.exists(),
        "file backend config must be rejected before library mutation"
    );
}
