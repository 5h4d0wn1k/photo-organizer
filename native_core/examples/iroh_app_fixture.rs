//! Isolated mixed-version test setup/inspection, never a production key backend.
//! The daemons must be stopped before this program opens their databases.
use native_core::{
    AppConfig,
    domain::{DeviceRole, DeviceTrustLevel},
    storage,
};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let config = AppConfig::from_env();
    let test_root = std::env::var_os("PHOTO_ORGANIZER_IROH_APP_TEST_ROOT")
        .ok_or("run through scripts/tests/iroh_historical_app_test.sh")?;
    let test_root = std::fs::canonicalize(test_root)?;
    let runtime = std::fs::canonicalize(&config.runtime_root)?;
    if !runtime.starts_with(&test_root) || runtime == test_root {
        return Err("refusing to open runtime outside isolated test root".into());
    }
    let report = storage::bootstrap_storage(&config)?;
    let mut state = storage::load_state(&report)?;
    match std::env::args().nth(1).as_deref() {
        Some("setup-contributor") | Some("setup-storage-only") => {
            // Only alter fixture-local role/capacity, before peer enrollment or
            // transfers. Never construct transport, encrypted chunks or proof.
            if state.devices.len() != 1
                || !state.sync_transfers.is_empty()
                || !state.blob_records.is_empty()
            {
                return Err("setup requires one unenrolled empty local device".into());
            }
            let storage_only = std::env::args().nth(1).as_deref() == Some("setup-storage-only");
            let device = &mut state.devices[0];
            device.storage_profile.reserved_bytes = 0;
            device.storage_profile.accepts_storage = true;
            if storage_only {
                device.trust_level = DeviceTrustLevel::StorageOnly;
                for member in &mut state.vault_members {
                    if member.device_id == device.id {
                        member.role = DeviceRole::StorageOnly;
                        member.trust_level = DeviceTrustLevel::StorageOnly;
                    }
                }
            }
            storage::save_state(&report, &state)?;
        }
        Some("inspect") => {
            // Test-created metadata only. Never serialize runtime keys/tokens.
            println!(
                "{}",
                serde_json::json!({
                    "devices": state.devices,
                    "blobs": state.blob_records,
                    "chunks": state.blob_chunks,
                    "replicas": state.blob_replicas,
                    "transfers": state.sync_transfers,
                    "asset_count": state.assets.len(),
                })
            );
        }
        _ => return Err("expected setup-contributor, setup-storage-only or inspect".into()),
    }
    Ok(())
}
