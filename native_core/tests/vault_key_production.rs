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

    let reopened = GalleryService::new(config.clone()).expect("reopen service");
    assert_eq!(
        reopened
            .asset_original_bytes(imported.asset.id)
            .await
            .expect("retrieve existing key from Secret Service after restart")
            .1,
        bytes,
    );
    // Only the unique key created above in this isolated Secret Service is
    // deleted. Never enumerate or touch any credential from the user's session.
    let isolated_root = std::env::var_os("PHOTO_ORGANIZER_SECRET_SERVICE_TEST_ROOT")
        .expect("run through the isolated Secret Service harness");
    assert!(root.starts_with(std::path::Path::new(&isolated_root)));
    let vault = reopened.vaults().await.into_iter().next().expect("vault");
    let entry = keyring::Entry::new(
        "private-gallery-vaults",
        &native_core::vault_store::key_reference(vault.id, vault.key_version),
    )
    .expect("test-created entry");
    let ciphertext_before = ciphertext_snapshot(&library.join("vaults"));
    assert!(
        !ciphertext_before.is_empty(),
        "fixture must contain encrypted chunks"
    );
    entry
        .delete_credential()
        .expect("remove only test-created key");
    assert!(matches!(entry.get_password(), Err(keyring::Error::NoEntry)));
    assert!(
        reopened
            .asset_original_bytes(imported.asset.id)
            .await
            .is_err()
    );
    let second = root.join("second.jpg");
    let second_bytes = b"different private asset after lost key";
    fs::write(&second, second_bytes).expect("second source");
    assert!(
        reopened
            .import_asset(ImportAssetRequest {
                source_path: second.to_string_lossy().into_owned(),
                original_filename: "second.jpg".into(),
                media_kind: MediaKind::Photo,
                mime_type: "image/jpeg".into(),
                bytes: second_bytes.len() as u64,
                content_hash: None,
                captured_at: None,
                place_hint: None,
                import_mode: Some(ImportMode::Copy),
            })
            .await
            .is_err(),
        "missing initialized key must fail import, not replace it"
    );
    assert!(matches!(entry.get_password(), Err(keyring::Error::NoEntry)));
    assert_eq!(
        ciphertext_snapshot(&library.join("vaults")),
        ciphertext_before
    );
    drop(reopened);
    let after_loss = GalleryService::new(config).expect("reopen without replacing missing key");
    assert!(
        after_loss
            .asset_original_bytes(imported.asset.id)
            .await
            .is_err()
    );
    assert!(matches!(entry.get_password(), Err(keyring::Error::NoEntry)));
    assert_eq!(
        ciphertext_snapshot(&library.join("vaults")),
        ciphertext_before
    );
    drop(after_loss);
    fs::remove_dir_all(root).expect("remove isolated runtime and library");
}

fn ciphertext_snapshot(
    root: &std::path::Path,
) -> std::collections::BTreeMap<std::path::PathBuf, Vec<u8>> {
    fn visit(
        path: &std::path::Path,
        files: &mut std::collections::BTreeMap<std::path::PathBuf, Vec<u8>>,
    ) {
        for entry in fs::read_dir(path).expect("ciphertext directory") {
            let path = entry.expect("ciphertext entry").path();
            if path.is_dir() {
                visit(&path, files);
            } else if path
                .extension()
                .is_some_and(|extension| extension == "pgblob")
            {
                files.insert(path.clone(), fs::read(path).expect("ciphertext bytes"));
            }
        }
    }
    let mut files = std::collections::BTreeMap::new();
    visit(root, &mut files);
    files
}
