use std::{fs, process::Command};

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

#[tokio::test]
#[ignore = "requires the isolated Secret Service started by scripts/test_vault_keyring_e2e.sh"]
async fn production_keyring_provisions_and_reopens_vault_key() {
    use native_core::domain::{
        ImportAssetRequest, ImportMode, MediaKind, UpdateLibrarySettingsRequest,
    };

    let root = std::env::temp_dir().join(format!("vault-keyring-roundtrip-{}", Uuid::new_v4()));
    let library = root.join("library");
    let source = root.join("source.jpg");
    let bytes = b"production keyring encrypted asset";
    fs::create_dir_all(&root).expect("test root");
    fs::write(&source, bytes).expect("source photo");
    let config = AppConfig {
        runtime_root: root.clone(),
        ..AppConfig::default()
    };

    let service = GalleryService::new(config.clone()).expect("production service");
    service
        .update_library_settings(UpdateLibrarySettingsRequest {
            library_root: library.to_string_lossy().to_string(),
            default_import_mode: ImportMode::Copy,
            original_storage_policy: None,
        })
        .await
        .expect("configure library");
    let imported = service
        .import_asset(ImportAssetRequest {
            source_path: source.to_string_lossy().to_string(),
            original_filename: "source.jpg".into(),
            media_kind: MediaKind::Photo,
            mime_type: "image/jpeg".into(),
            bytes: bytes.len() as u64,
            content_hash: None,
            captured_at: None,
            place_hint: None,
            import_mode: Some(ImportMode::Copy),
        })
        .await
        .expect("import through production keyring");

    assert_eq!(
        service
            .asset_original_bytes(imported.asset.id)
            .await
            .expect("decrypt with provisioned key")
            .1,
        bytes,
    );
    assert!(
        !root.join("security/vault-keys").exists(),
        "production key must not be written to a plaintext key directory"
    );
    drop(service);

    let reopened = GalleryService::new(config).expect("reopen service");
    assert_eq!(
        reopened
            .asset_original_bytes(imported.asset.id)
            .await
            .expect("retrieve existing key from Secret Service after restart")
            .1,
        bytes,
    );
    fs::remove_dir_all(root).expect("remove isolated runtime and library");
}
