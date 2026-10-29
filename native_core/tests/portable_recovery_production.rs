//! Run only through scripts/test_portable_recovery_e2e.sh: each phase gets an
//! independent Secret Service session, HOME and runtime directory.
use native_core::{AppConfig, GalleryService, domain::*};
use std::{fs, path::PathBuf};
const PASSPHRASE: &str = "synthetic isolated portable recovery passphrase";
const CONTENT: &[u8] = b"portable production catalog and vault key proof";

fn root(phase: &str) -> PathBuf {
    let root = PathBuf::from(
        std::env::var_os("PHOTO_ORGANIZER_RECOVERY_TEST_ROOT")
            .expect("use the isolated recovery harness"),
    );
    assert!(root.is_absolute());
    let expected_home = root.join(format!("keyring-{phase}/home"));
    assert_eq!(
        PathBuf::from(std::env::var_os("HOME").expect("isolated HOME")),
        expected_home
    );
    assert_eq!(
        PathBuf::from(std::env::var_os("XDG_DATA_HOME").expect("isolated data")),
        expected_home.join("data")
    );
    assert_eq!(
        std::env::var("PHOTO_ORGANIZER_RECOVERY_TEST_PHASE").unwrap(),
        phase
    );
    assert!(std::env::var_os("DBUS_SESSION_BUS_ADDRESS").is_some());
    assert_eq!(
        fs::read(root.join("harness.marker")).expect("isolated harness marker"),
        b"photo-organizer-portable-test"
    );
    root
}

#[tokio::test]
#[ignore = "requires the isolated two-session Secret Service harness"]
async fn portable_export_phase() {
    let root = root("export");
    let config = AppConfig {
        runtime_root: root.join("source/runtime"),
        library_root: root.join("source/library"),
        ..AppConfig::default()
    };
    let service = GalleryService::new(config.clone()).expect("source service");
    service
        .update_library_settings(UpdateLibrarySettingsRequest {
            library_root: config.library_root.to_string_lossy().into_owned(),
            default_import_mode: ImportMode::Copy,
            original_storage_policy: Some(OriginalStoragePolicy::EncryptedOnly),
        })
        .await
        .expect("source settings");
    let source = root.join("source/input.jpg");
    fs::write(&source, CONTENT).expect("synthetic fixture");
    let asset = service
        .import_asset(ImportAssetRequest {
            source_path: source.to_string_lossy().into_owned(),
            original_filename: "input.jpg".into(),
            media_kind: MediaKind::Photo,
            mime_type: "image/jpeg".into(),
            bytes: CONTENT.len() as u64,
            content_hash: None,
            captured_at: None,
            place_hint: None,
            import_mode: Some(ImportMode::Copy),
        })
        .await
        .expect("encrypted source import");
    service
        .activate_encryption(EncryptionActivationRequest {
            confirmed: true,
            backup_root: None,
        })
        .await
        .expect("SQLCipher source activation");
    service
        .export_backup(BackupExportRequest {
            export_root: root.join("backup").to_string_lossy().into_owned(),
            include_models: false,
            recovery_passphrase: Some(PASSPHRASE.into()),
        })
        .await
        .expect("authenticated portable export");
    fs::write(root.join("asset-id"), asset.asset.id.to_string())
        .expect("non-secret fixture identity");
}

#[tokio::test]
#[ignore = "requires the isolated two-session Secret Service harness"]
async fn portable_restore_phase() {
    let root = root("restore");
    let manifest: serde_json::Value = serde_json::from_slice(
        &fs::read(root.join("backup/manifests/private-gallery-backup-manifest.json")).unwrap(),
    )
    .unwrap();
    for identity in manifest["recovery_key_inventory"]["required_keys"]
        .as_array()
        .unwrap()
    {
        if identity["kind"] == "vault" {
            let id = format!(
                "vault-key:{}:v{}",
                identity["vault_id"].as_str().unwrap(),
                identity["key_version"].as_u64().unwrap()
            );
            assert!(
                matches!(
                    keyring::Entry::new("private-gallery-vaults", &id)
                        .unwrap()
                        .get_password(),
                    Err(keyring::Error::NoEntry)
                ),
                "receiving OS keyring must start without source vault credentials"
            );
        }
    }
    let receiver = GalleryService::new(AppConfig {
        runtime_root: root.join("receiver/runtime"),
        library_root: root.join("receiver/library"),
        ..AppConfig::default()
    })
    .expect("independent receiving service");
    let destination = root.join("restored");
    let result = receiver
        .run_restore_backup(BackupRestoreRunRequest {
            export_root: root.join("backup").to_string_lossy().into_owned(),
            restore_root: destination.to_string_lossy().into_owned(),
            confirmed: true,
            recovery_passphrase: Some(PASSPHRASE.into()),
        })
        .await
        .expect("restore with source Secret Service unavailable");
    assert!(result.ok);
    drop(receiver);
    let restored = GalleryService::new(AppConfig {
        runtime_root: destination.join("runtime"),
        library_root: destination.join("library"),
        ..AppConfig::default()
    })
    .expect("cold launch with receiving Secret Service");
    let asset = fs::read_to_string(root.join("asset-id"))
        .unwrap()
        .parse()
        .unwrap();
    assert_eq!(
        restored
            .asset_original_bytes(asset)
            .await
            .expect("normal original reader")
            .1,
        CONTENT
    );
    assert_eq!(
        restored.library_settings().await.unwrap().library_root,
        destination.join("library").to_string_lossy()
    );
}
