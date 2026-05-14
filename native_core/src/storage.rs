use std::{
    collections::HashMap,
    fs,
    path::{Path, PathBuf},
};

use rusqlite::{Connection, OptionalExtension, params};
use uuid::Uuid;

use crate::{
    config::AppConfig,
    domain::{
        Album, Asset, AssetMetadata, AssetVariant, BlobChunk, BlobRecord, BlobReplica, CameraInfo,
        CapabilityGrant, CorrectionRecord, DeviceIdentity, DevicePairing, EventCluster,
        FaceTemplate, FeedbackEvent, GeoTag, ImportCandidate, ImportMode, ImportSession, JobLog,
        JobRecord, LibrarySettings, MetadataSource, ModelProvenance, OcrBlock, PersonCluster,
        PlaceCluster, RelayEndpoint, SceneTag, SyncConflict, SyncSession, SyncTransfer, Vault,
        VaultInvite, VaultMember, WatchFolder,
    },
    security,
};

const SCHEMA_VERSION: i64 = 9;

#[derive(Debug, Clone)]
pub struct StorageBootstrapReport {
    pub database_path: PathBuf,
}

#[derive(Debug, Clone, Default)]
pub struct PersistedLibraryState {
    pub library_settings: Option<LibrarySettings>,
    pub watch_folders: Vec<WatchFolder>,
    pub assets: Vec<Asset>,
    pub albums: Vec<Album>,
    pub people: Vec<PersonCluster>,
    pub places: Vec<PlaceCluster>,
    pub events: Vec<EventCluster>,
    pub faces: Vec<FaceTemplate>,
    pub feedback: Vec<FeedbackEvent>,
    pub vaults: Vec<Vault>,
    pub devices: Vec<DeviceIdentity>,
    pub vault_members: Vec<VaultMember>,
    pub blob_records: Vec<BlobRecord>,
    pub blob_chunks: Vec<BlobChunk>,
    pub blob_replicas: Vec<BlobReplica>,
    pub sync_transfers: Vec<SyncTransfer>,
    pub sync_conflicts: Vec<SyncConflict>,
    pub vault_invites: Vec<VaultInvite>,
    pub relay_endpoints: Vec<RelayEndpoint>,
    pub capability_grants: Vec<CapabilityGrant>,
    pub pairings: Vec<DevicePairing>,
    pub sync_sessions: Vec<SyncSession>,
    pub import_sessions: Vec<ImportSession>,
    pub jobs: Vec<JobRecord>,
    pub job_logs: Vec<JobLog>,
    pub corrections: Vec<CorrectionRecord>,
    pub ocr_blocks: Vec<OcrBlock>,
    pub scene_tags: Vec<SceneTag>,
}

pub fn bootstrap_storage(config: &AppConfig) -> Result<StorageBootstrapReport, rusqlite::Error> {
    let db_dir = config.runtime_root.join("db");
    fs::create_dir_all(&db_dir)
        .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?;

    let db_path = config.database_path();
    let connection = open_connection(&db_path)?;
    connection.pragma_update(None, "journal_mode", "WAL")?;
    connection.pragma_update(None, "foreign_keys", "ON")?;
    let user_version: i64 = connection.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if user_version > SCHEMA_VERSION {
        return Err(rusqlite::Error::InvalidQuery);
    }
    connection.execute_batch(include_str!("../sql/schema.sql"))?;
    migrate_schema(&connection, user_version)?;

    Ok(StorageBootstrapReport {
        database_path: db_path,
    })
}

fn migrate_schema(connection: &Connection, from_version: i64) -> Result<(), rusqlite::Error> {
    if from_version < 6 {
        for table in [
            "asset_variants",
            "asset_metadata",
            "person_clusters",
            "face_templates",
            "place_clusters",
            "event_clusters",
        ] {
            add_column_if_missing(connection, table, "model_hash", "model_hash TEXT")?;
        }
        add_column_if_missing(
            connection,
            "jobs",
            "cancel_requested",
            "cancel_requested INTEGER NOT NULL DEFAULT 0",
        )?;
        add_column_if_missing(
            connection,
            "jobs",
            "retry_of_job_id",
            "retry_of_job_id TEXT",
        )?;
        add_column_if_missing(
            connection,
            "jobs",
            "attempt",
            "attempt INTEGER NOT NULL DEFAULT 1",
        )?;
        record_migration(connection, 6, "job_logs_corrections_and_model_hash")?;
    }

    if from_version < 7 {
        record_migration(
            connection,
            7,
            "private_beta_encryption_model_and_derived_index_tables",
        )?;
    }

    if from_version < 8 {
        record_migration(connection, 8, "manual_albums")?;
    }

    if from_version < 9 {
        record_migration(connection, 9, "distributed_vault_control_plane")?;
    }

    connection.pragma_update(None, "user_version", SCHEMA_VERSION)
}

fn open_connection(path: &Path) -> Result<Connection, rusqlite::Error> {
    security::open_database(path)
        .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))
}

fn add_column_if_missing(
    connection: &Connection,
    table: &str,
    column: &str,
    definition: &str,
) -> Result<(), rusqlite::Error> {
    let pragma = format!("PRAGMA table_info({table})");
    let mut statement = connection.prepare(&pragma)?;
    let rows = statement.query_map([], |row| row.get::<_, String>(1))?;
    for row in rows {
        if row? == column {
            return Ok(());
        }
    }

    connection.execute(&format!("ALTER TABLE {table} ADD COLUMN {definition}"), [])?;
    Ok(())
}

fn record_migration(
    connection: &Connection,
    version: i64,
    name: &str,
) -> Result<(), rusqlite::Error> {
    connection.execute(
        r#"
        INSERT OR IGNORE INTO schema_migrations (version, name, applied_at)
        VALUES (?1, ?2, ?3)
        "#,
        params![version, name, chrono::Utc::now().to_rfc3339()],
    )?;
    Ok(())
}

pub fn ensure_library_layout(root: &Path) -> Result<(), rusqlite::Error> {
    for dir in [
        root.join("objects"),
        root.join("originals"),
        root.join("variants"),
        root.join("variants/previews"),
        root.join("variants/thumbs"),
        root.join("indexes"),
    ] {
        fs::create_dir_all(dir)
            .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?;
    }
    Ok(())
}

pub fn load_state(
    report: &StorageBootstrapReport,
) -> Result<PersistedLibraryState, rusqlite::Error> {
    let connection = open_connection(&report.database_path)?;
    connection.pragma_update(None, "foreign_keys", "ON")?;

    let library_settings = load_library_settings(&connection)?;
    let watch_folders = load_watch_folders(&connection)?;
    let assets = load_assets(&connection, library_settings.as_ref())?;
    let albums = load_albums(&connection)?;
    let people = load_people(&connection)?;
    let places = load_places(&connection)?;
    let events = load_events(&connection)?;
    let faces = load_faces(&connection)?;
    let feedback = load_feedback(&connection)?;
    let vaults = load_vaults(&connection)?;
    let devices = load_devices(&connection)?;
    let vault_members = load_vault_members(&connection)?;
    let blob_records = load_blob_records(&connection)?;
    let blob_chunks = load_blob_chunks(&connection)?;
    let blob_replicas = load_blob_replicas(&connection)?;
    let sync_transfers = load_sync_transfers_v2(&connection)?;
    let sync_conflicts = load_sync_conflicts(&connection)?;
    let vault_invites = load_vault_invites(&connection)?;
    let relay_endpoints = load_relay_endpoints(&connection)?;
    let capability_grants = load_capability_grants(&connection)?;
    let pairings = load_pairings(&connection)?;
    let sync_sessions = load_sync_sessions(&connection)?;
    let import_sessions = load_import_sessions(&connection)?;
    let jobs = load_jobs(&connection)?;
    let job_logs = load_job_logs(&connection)?;
    let corrections = load_corrections(&connection)?;
    let ocr_blocks = load_ocr_blocks(&connection)?;
    let scene_tags = load_scene_tags(&connection)?;

    Ok(PersistedLibraryState {
        library_settings,
        watch_folders,
        assets,
        albums,
        people,
        places,
        events,
        faces,
        feedback,
        vaults,
        devices,
        vault_members,
        blob_records,
        blob_chunks,
        blob_replicas,
        sync_transfers,
        sync_conflicts,
        vault_invites,
        relay_endpoints,
        capability_grants,
        pairings,
        sync_sessions,
        import_sessions,
        jobs,
        job_logs,
        corrections,
        ocr_blocks,
        scene_tags,
    })
}

pub fn save_state(
    report: &StorageBootstrapReport,
    state: &PersistedLibraryState,
) -> Result<(), rusqlite::Error> {
    let mut connection = open_connection(&report.database_path)?;
    connection.pragma_update(None, "foreign_keys", "ON")?;
    let transaction = connection.transaction()?;

    transaction.execute_batch(
        r#"
        DELETE FROM asset_variants;
        DELETE FROM asset_metadata;
        DELETE FROM ocr_blocks;
        DELETE FROM scene_tags;
        DELETE FROM face_templates;
        DELETE FROM album_assets;
        DELETE FROM event_assets;
        DELETE FROM place_assets;
        DELETE FROM import_candidates;
        DELETE FROM capability_grants;
        DELETE FROM relay_endpoints;
        DELETE FROM vault_invites;
        DELETE FROM sync_conflicts;
        DELETE FROM sync_transfers;
        DELETE FROM blob_replicas;
        DELETE FROM blob_chunks;
        DELETE FROM blob_records;
        DELETE FROM vault_members;
        DELETE FROM device_identities;
        DELETE FROM vaults;
        DELETE FROM sync_sessions;
        DELETE FROM device_pairings;
        DELETE FROM albums;
        DELETE FROM person_clusters;
        DELETE FROM event_clusters;
        DELETE FROM place_clusters;
        DELETE FROM job_logs;
        DELETE FROM correction_records;
        DELETE FROM feedback_events;
        DELETE FROM import_sessions;
        DELETE FROM jobs;
        DELETE FROM watch_folders;
        DELETE FROM assets;
        DELETE FROM library_settings;
        "#,
    )?;

    if let Some(settings) = &state.library_settings {
        transaction.execute(
            r#"
            INSERT INTO library_settings (
              id,
              library_root,
              default_import_mode,
              initialized_at,
              updated_at
            ) VALUES (?1, ?2, ?3, ?4, ?5)
            "#,
            params![
                1_i64,
                settings.library_root,
                enum_string(&settings.default_import_mode)?,
                settings.initialized_at.to_rfc3339(),
                settings.updated_at.to_rfc3339(),
            ],
        )?;
    }

    for folder in &state.watch_folders {
        transaction.execute(
            r#"
            INSERT INTO watch_folders (
              id, path, recursive, import_mode, created_at, last_scanned_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            "#,
            params![
                folder.id.to_string(),
                folder.path,
                folder.recursive,
                enum_string(&folder.import_mode)?,
                folder.created_at.to_rfc3339(),
                folder.last_scanned_at.map(|value| value.to_rfc3339()),
            ],
        )?;
    }

    for asset in &state.assets {
        transaction.execute(
            r#"
            INSERT INTO assets (
              id,
              original_filename,
              relative_original_path,
              source_path,
              content_hash,
              media_kind,
              import_mode,
              bytes,
              mime_type,
              captured_at,
              imported_at,
              archived,
              favorite,
              is_available,
              place_hint
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
            "#,
            params![
                asset.id.to_string(),
                asset.original_filename,
                asset.relative_original_path,
                asset.source_path,
                asset.content_hash,
                enum_string(&asset.media_kind)?,
                enum_string(&asset.import_mode)?,
                asset.bytes,
                asset.mime_type,
                asset.captured_at.to_rfc3339(),
                asset.imported_at.to_rfc3339(),
                asset.archived,
                asset.favorite,
                asset.is_available,
                asset.place_hint,
            ],
        )?;

        for variant in &asset.variants {
            transaction.execute(
                r#"
                INSERT INTO asset_variants (
                  id, asset_id, kind, relative_path, mime_type, bytes, width, height,
                  model_name, model_version, model_hash, created_at, rebuildable
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
                "#,
                params![
                    variant.id.to_string(),
                    asset.id.to_string(),
                    enum_string(&variant.kind)?,
                    variant.relative_path,
                    variant.mime_type,
                    variant.bytes,
                    variant.width,
                    variant.height,
                    variant.derived.model_name,
                    variant.derived.model_version,
                    variant.derived.model_hash,
                    variant.derived.created_at.to_rfc3339(),
                    variant.derived.rebuildable,
                ],
            )?;
        }

        if let Some(metadata) = &asset.metadata {
            transaction.execute(
                r#"
                INSERT INTO asset_metadata (
                  asset_id, captured_at, captured_at_source, timezone_offset_minutes,
                  width, height, camera_make, camera_model, lens_model,
                  latitude, longitude, altitude_meters, location_source, exact_gps_hidden,
                  sidecar_title, sidecar_description, folder_hint,
                  model_name, model_version, model_hash, created_at, rebuildable
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22)
                "#,
                params![
                    asset.id.to_string(),
                    metadata.captured_at.to_rfc3339(),
                    enum_string(&metadata.captured_at_source)?,
                    metadata.timezone_offset_minutes,
                    metadata.width,
                    metadata.height,
                    metadata.camera.as_ref().and_then(|camera| camera.make.clone()),
                    metadata.camera.as_ref().and_then(|camera| camera.model.clone()),
                    metadata.camera.as_ref().and_then(|camera| camera.lens_model.clone()),
                    metadata.geo.as_ref().map(|geo| geo.latitude),
                    metadata.geo.as_ref().map(|geo| geo.longitude),
                    metadata.geo.as_ref().and_then(|geo| geo.altitude_meters),
                    metadata.geo.as_ref().map(|geo| enum_string(&geo.source)).transpose()?,
                    metadata
                        .geo
                        .as_ref()
                        .map(|geo| geo.exact_hidden)
                        .unwrap_or(false),
                    metadata.sidecar_title,
                    metadata.sidecar_description,
                    metadata.folder_hint,
                    metadata.derived.model_name,
                    metadata.derived.model_version,
                    metadata.derived.model_hash,
                    metadata.derived.created_at.to_rfc3339(),
                    metadata.derived.rebuildable,
                ],
            )?;
        }
    }

    for block in &state.ocr_blocks {
        transaction.execute(
            r#"
            INSERT INTO ocr_blocks (
              id, asset_id, text, bounding_box_json,
              model_name, model_version, model_hash, created_at, rebuildable
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            "#,
            params![
                block.id.to_string(),
                block.asset_id.to_string(),
                block.text,
                block
                    .bounding_box
                    .as_ref()
                    .map(|box_value| {
                        serde_json::to_string(box_value)
                            .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))
                    })
                    .transpose()?,
                block.derived.model_name,
                block.derived.model_version,
                block.derived.model_hash,
                block.derived.created_at.to_rfc3339(),
                block.derived.rebuildable,
            ],
        )?;
    }

    for tag in &state.scene_tags {
        transaction.execute(
            r#"
            INSERT INTO scene_tags (
              id, asset_id, label, confidence,
              model_name, model_version, model_hash, created_at, rebuildable
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            "#,
            params![
                tag.id.to_string(),
                tag.asset_id.to_string(),
                tag.label,
                tag.confidence,
                tag.derived.model_name,
                tag.derived.model_version,
                tag.derived.model_hash,
                tag.derived.created_at.to_rfc3339(),
                tag.derived.rebuildable,
            ],
        )?;
    }

    for album in &state.albums {
        transaction.execute(
            r#"
            INSERT INTO albums (
              id, title, cover_asset_id, created_at, updated_at
            ) VALUES (?1, ?2, ?3, ?4, ?5)
            "#,
            params![
                album.id.to_string(),
                album.title,
                album.cover_asset_id.map(|value| value.to_string()),
                album.created_at.to_rfc3339(),
                album.updated_at.to_rfc3339(),
            ],
        )?;

        for (position, asset_id) in album.asset_ids.iter().enumerate() {
            transaction.execute(
                "INSERT INTO album_assets (album_id, asset_id, position) VALUES (?1, ?2, ?3)",
                params![album.id.to_string(), asset_id.to_string(), position as i64],
            )?;
        }
    }

    for person in &state.people {
        transaction.execute(
            r#"
            INSERT INTO person_clusters (
              id, display_name, asset_ids_json, face_template_ids_json, representative_asset_id,
              hidden, model_name, model_version, model_hash, created_at, rebuildable
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            "#,
            params![
                person.id.to_string(),
                person.display_name,
                uuid_vec_json(&person.asset_ids)?,
                uuid_vec_json(&person.face_template_ids)?,
                person
                    .representative_asset_id
                    .map(|value| value.to_string()),
                person.hidden,
                person.derived.model_name,
                person.derived.model_version,
                person.derived.model_hash,
                person.derived.created_at.to_rfc3339(),
                person.derived.rebuildable,
            ],
        )?;
    }

    for face in &state.faces {
        transaction.execute(
            r#"
            INSERT INTO face_templates (
              id, asset_id, person_cluster_id, preview_variant_id, bounding_box_json,
              model_name, model_version, model_hash, created_at, rebuildable
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            "#,
            params![
                face.id.to_string(),
                face.asset_id.to_string(),
                face.person_cluster_id.map(|value| value.to_string()),
                face.preview_variant_id.map(|value| value.to_string()),
                serde_json::to_string(&face.bounding_box)
                    .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?,
                face.derived.model_name,
                face.derived.model_version,
                face.derived.model_hash,
                face.derived.created_at.to_rfc3339(),
                face.derived.rebuildable,
            ],
        )?;
    }

    for place in &state.places {
        transaction.execute(
            r#"
            INSERT INTO place_clusters (
              id, label, country_code, region, centroid_latitude, centroid_longitude,
              model_name, model_version, model_hash, created_at, rebuildable
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            "#,
            params![
                place.id.to_string(),
                place.label,
                place.country_code,
                place.region,
                place.centroid_latitude,
                place.centroid_longitude,
                place.derived.model_name,
                place.derived.model_version,
                place.derived.model_hash,
                place.derived.created_at.to_rfc3339(),
                place.derived.rebuildable,
            ],
        )?;

        for asset_id in &place.asset_ids {
            transaction.execute(
                "INSERT INTO place_assets (place_id, asset_id) VALUES (?1, ?2)",
                params![place.id.to_string(), asset_id.to_string()],
            )?;
        }
    }

    for event in &state.events {
        transaction.execute(
            r#"
            INSERT INTO event_clusters (
              id, title, title_source, start_at, end_at, place_id, people_ids_json,
              model_name, model_version, model_hash, created_at, rebuildable
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
            "#,
            params![
                event.id.to_string(),
                event.title,
                enum_string(&event.title_source)?,
                event.start_at.to_rfc3339(),
                event.end_at.to_rfc3339(),
                event.place_id.map(|value| value.to_string()),
                uuid_vec_json(&event.people_ids)?,
                event.derived.model_name,
                event.derived.model_version,
                event.derived.model_hash,
                event.derived.created_at.to_rfc3339(),
                event.derived.rebuildable,
            ],
        )?;

        for asset_id in &event.asset_ids {
            transaction.execute(
                "INSERT INTO event_assets (event_id, asset_id) VALUES (?1, ?2)",
                params![event.id.to_string(), asset_id.to_string()],
            )?;
        }
    }

    for feedback in &state.feedback {
        transaction.execute(
            r#"
            INSERT INTO feedback_events (id, kind, payload_json, created_at)
            VALUES (?1, ?2, ?3, ?4)
            "#,
            params![
                feedback.id.to_string(),
                enum_string(&feedback.kind)?,
                serde_json::to_string(&feedback.payload)
                    .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?,
                feedback.created_at.to_rfc3339(),
            ],
        )?;
    }

    for vault in &state.vaults {
        transaction.execute(
            r#"
            INSERT INTO vaults (
              id, name, storage_policy_json, key_version, deletion_grace_days, created_at, updated_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            "#,
            params![
                vault.id.to_string(),
                vault.name,
                json_string(&vault.storage_policy)?,
                vault.key_version,
                vault.deletion_grace_days,
                vault.created_at.to_rfc3339(),
                vault.updated_at.to_rfc3339(),
            ],
        )?;
    }

    for device in &state.devices {
        transaction.execute(
            r#"
            INSERT INTO device_identities (
              id, display_name, platform, public_key, trust_level, storage_profile_json,
              enrolled_at, last_seen_at, revoked_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            "#,
            params![
                device.id.to_string(),
                device.display_name,
                device.platform,
                device.public_key,
                enum_string(&device.trust_level)?,
                json_string(&device.storage_profile)?,
                device.enrolled_at.to_rfc3339(),
                device.last_seen_at.map(|value| value.to_rfc3339()),
                device.revoked_at.map(|value| value.to_rfc3339()),
            ],
        )?;
    }

    for member in &state.vault_members {
        transaction.execute(
            r#"
            INSERT INTO vault_members (
              id, vault_id, device_id, role, trust_level, display_name, added_at, revoked_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            "#,
            params![
                member.id.to_string(),
                member.vault_id.to_string(),
                member.device_id.to_string(),
                enum_string(&member.role)?,
                enum_string(&member.trust_level)?,
                member.display_name,
                member.added_at.to_rfc3339(),
                member.revoked_at.map(|value| value.to_rfc3339()),
            ],
        )?;
    }

    for blob in &state.blob_records {
        transaction.execute(
            r#"
            INSERT INTO blob_records (
              id, vault_id, asset_id, content_hash, encrypted_hash, bytes, chunk_count,
              encryption_key_version, created_at, tombstoned_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            "#,
            params![
                blob.id.to_string(),
                blob.vault_id.to_string(),
                blob.asset_id.to_string(),
                blob.content_hash,
                blob.encrypted_hash,
                blob.bytes,
                blob.chunk_count,
                blob.encryption_key_version,
                blob.created_at.to_rfc3339(),
                blob.tombstoned_at.map(|value| value.to_rfc3339()),
            ],
        )?;
    }

    for chunk in &state.blob_chunks {
        transaction.execute(
            r#"
            INSERT INTO blob_chunks (
              id, blob_id, chunk_index, content_hash, encrypted_hash, bytes
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            "#,
            params![
                chunk.id.to_string(),
                chunk.blob_id.to_string(),
                chunk.chunk_index,
                chunk.content_hash,
                chunk.encrypted_hash,
                chunk.bytes,
            ],
        )?;
    }

    for replica in &state.blob_replicas {
        transaction.execute(
            r#"
            INSERT INTO blob_replicas (
              id, blob_id, device_id, health, bytes_present, verified_at, transfer_id
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            "#,
            params![
                replica.id.to_string(),
                replica.blob_id.to_string(),
                replica.device_id.to_string(),
                enum_string(&replica.health)?,
                replica.bytes_present,
                replica.verified_at.map(|value| value.to_rfc3339()),
                replica.transfer_id.map(|value| value.to_string()),
            ],
        )?;
    }

    for transfer in &state.sync_transfers {
        transaction.execute(
            r#"
            INSERT INTO sync_transfers (
              id, vault_id, blob_id, from_device_id, to_device_id, status, bytes_total,
              bytes_completed, started_at, updated_at, resumable_until
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            "#,
            params![
                transfer.id.to_string(),
                transfer.vault_id.to_string(),
                transfer.blob_id.to_string(),
                transfer.from_device_id.map(|value| value.to_string()),
                transfer.to_device_id.to_string(),
                enum_string(&transfer.status)?,
                transfer.bytes_total,
                transfer.bytes_completed,
                transfer.started_at.map(|value| value.to_rfc3339()),
                transfer.updated_at.to_rfc3339(),
                transfer.resumable_until.to_rfc3339(),
            ],
        )?;
    }

    for conflict in &state.sync_conflicts {
        transaction.execute(
            r#"
            INSERT INTO sync_conflicts (
              id, vault_id, asset_id, field, actor_device_ids_json, detected_at, detail
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            "#,
            params![
                conflict.id.to_string(),
                conflict.vault_id.to_string(),
                conflict.asset_id.map(|value| value.to_string()),
                conflict.field,
                uuid_vec_json(&conflict.actor_device_ids)?,
                conflict.detected_at.to_rfc3339(),
                conflict.detail,
            ],
        )?;
    }

    for invite in &state.vault_invites {
        transaction.execute(
            r#"
            INSERT INTO vault_invites (
              id, vault_id, invited_device_name, role, trust_level, invite_code,
              created_at, expires_at, accepted_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            "#,
            params![
                invite.id.to_string(),
                invite.vault_id.to_string(),
                invite.invited_device_name,
                enum_string(&invite.role)?,
                enum_string(&invite.trust_level)?,
                invite.invite_code,
                invite.created_at.to_rfc3339(),
                invite.expires_at.to_rfc3339(),
                invite.accepted_at.map(|value| value.to_rfc3339()),
            ],
        )?;
    }

    for endpoint in &state.relay_endpoints {
        transaction.execute(
            r#"
            INSERT INTO relay_endpoints (
              id, device_id, node_id, relay_url, direct_addresses_json, last_seen_at, expires_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            "#,
            params![
                endpoint.id.to_string(),
                endpoint.device_id.to_string(),
                endpoint.node_id,
                endpoint.relay_url,
                string_vec_json(&endpoint.direct_addresses)?,
                endpoint.last_seen_at.to_rfc3339(),
                endpoint.expires_at.to_rfc3339(),
            ],
        )?;
    }

    for grant in &state.capability_grants {
        transaction.execute(
            r#"
            INSERT INTO capability_grants (
              id, vault_id, device_id, capability, granted_by_device_id, granted_at, expires_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            "#,
            params![
                grant.id.to_string(),
                grant.vault_id.to_string(),
                grant.device_id.to_string(),
                grant.capability,
                grant.granted_by_device_id.map(|value| value.to_string()),
                grant.granted_at.to_rfc3339(),
                grant.expires_at.map(|value| value.to_rfc3339()),
            ],
        )?;
    }

    for pairing in &state.pairings {
        transaction.execute(
            r#"
            INSERT INTO device_pairings (
              id, device_name, platform, pairing_token, created_at, expires_at, approved_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            "#,
            params![
                pairing.id.to_string(),
                pairing.device_name,
                pairing.platform,
                pairing.pairing_token,
                pairing.created_at.to_rfc3339(),
                pairing.expires_at.to_rfc3339(),
                pairing.approved_at.map(|value| value.to_rfc3339()),
            ],
        )?;
    }

    for sync in &state.sync_sessions {
        transaction.execute(
            r#"
            INSERT INTO sync_sessions (
              id, pairing_id, status, started_at, last_seen_at,
              uploaded_asset_ids_json, rejected_asset_ids_json
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            "#,
            params![
                sync.id.to_string(),
                sync.pairing_id.to_string(),
                enum_string(&sync.status)?,
                sync.started_at.to_rfc3339(),
                sync.last_seen_at.map(|value| value.to_rfc3339()),
                uuid_vec_json(&sync.uploaded_asset_ids)?,
                uuid_vec_json(&sync.rejected_asset_ids)?,
            ],
        )?;
    }

    for session in &state.import_sessions {
        transaction.execute(
            r#"
            INSERT INTO import_sessions (
              id, source_kind, source_path, import_mode, add_as_watch_folder, status,
              created_at, completed_at, place_hint, imported_asset_ids_json, duplicate_asset_ids_json,
              moved_asset_ids_json, skipped_duplicate_ids_json, failed_candidate_ids_json,
              sidecars_moved, unsupported_file_paths_json
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
            "#,
            params![
                session.id.to_string(),
                enum_string(&session.source_kind)?,
                session.source_path,
                enum_string(&session.import_mode)?,
                session.add_as_watch_folder,
                enum_string(&session.status)?,
                session.created_at.to_rfc3339(),
                session.completed_at.map(|value| value.to_rfc3339()),
                session.place_hint,
                uuid_vec_json(&session.imported_asset_ids)?,
                uuid_vec_json(&session.duplicate_asset_ids)?,
                uuid_vec_json(&session.moved_asset_ids)?,
                uuid_vec_json(&session.skipped_duplicate_ids)?,
                uuid_vec_json(&session.failed_candidate_ids)?,
                session.sidecars_moved as i64,
                string_vec_json(&session.unsupported_file_paths)?,
            ],
        )?;

        for candidate in &session.candidates {
            transaction.execute(
                r#"
                INSERT INTO import_candidates (
                  id, session_id, source_path, original_filename, media_kind, mime_type,
                  bytes, captured_at, place_hint, content_hash, duplicate_asset_id, selected, import_mode,
                  destination_path, sidecar_paths_json, safety_status
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
                "#,
                params![
                    candidate.id.to_string(),
                    session.id.to_string(),
                    candidate.source_path,
                    candidate.original_filename,
                    enum_string(&candidate.media_kind)?,
                    candidate.mime_type,
                    candidate.bytes,
                    candidate.captured_at.map(|value| value.to_rfc3339()),
                    candidate.place_hint,
                    candidate.content_hash,
                    candidate.duplicate_asset_id.map(|value| value.to_string()),
                    candidate.selected,
                    enum_string(&candidate.import_mode)?,
                    candidate.destination_path,
                    string_vec_json(&candidate.sidecar_paths)?,
                    candidate.safety_status,
                ],
            )?;
        }
    }

    for job in &state.jobs {
        transaction.execute(
            r#"
            INSERT INTO jobs (
              id, kind, status, progress, queued_at, started_at, completed_at, detail,
              cancel_requested, retry_of_job_id, attempt
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            "#,
            params![
                job.id.to_string(),
                enum_string(&job.kind)?,
                enum_string(&job.status)?,
                job.progress,
                job.queued_at.to_rfc3339(),
                job.started_at.map(|value| value.to_rfc3339()),
                job.completed_at.map(|value| value.to_rfc3339()),
                job.detail,
                job.cancel_requested,
                job.retry_of_job_id.map(|value| value.to_string()),
                job.attempt,
            ],
        )?;
    }

    for log in &state.job_logs {
        transaction.execute(
            r#"
            INSERT INTO job_logs (id, job_id, level, message, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5)
            "#,
            params![
                log.id.to_string(),
                log.job_id.to_string(),
                log.level,
                log.message,
                log.created_at.to_rfc3339(),
            ],
        )?;
    }

    for correction in &state.corrections {
        transaction.execute(
            r#"
            INSERT INTO correction_records (
              id, kind, asset_id, place_id, event_id, previous_json, applied_json, created_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            "#,
            params![
                correction.id.to_string(),
                enum_string(&correction.kind)?,
                correction.asset_id.map(|value| value.to_string()),
                correction.place_id.map(|value| value.to_string()),
                correction.event_id.map(|value| value.to_string()),
                serde_json::to_string(&correction.previous_json)
                    .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?,
                serde_json::to_string(&correction.applied_json)
                    .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?,
                correction.created_at.to_rfc3339(),
            ],
        )?;
    }

    transaction.commit()?;
    Ok(())
}

fn load_library_settings(
    connection: &Connection,
) -> Result<Option<LibrarySettings>, rusqlite::Error> {
    connection
        .query_row(
            r#"
            SELECT library_root, default_import_mode, initialized_at, updated_at
            FROM library_settings WHERE id = 1
            "#,
            [],
            |row| {
                Ok(LibrarySettings {
                    library_root: row.get(0)?,
                    default_import_mode: parse_enum(&row.get::<_, String>(1)?)?,
                    initialized_at: parse_datetime(&row.get::<_, String>(2)?)?,
                    updated_at: parse_datetime(&row.get::<_, String>(3)?)?,
                })
            },
        )
        .optional()
}

fn load_watch_folders(connection: &Connection) -> Result<Vec<WatchFolder>, rusqlite::Error> {
    let mut statement = connection.prepare(
        "SELECT id, path, recursive, import_mode, created_at, last_scanned_at FROM watch_folders ORDER BY created_at ASC",
    )?;
    let rows = statement.query_map([], |row| {
        Ok(WatchFolder {
            id: parse_uuid(&row.get::<_, String>(0)?)?,
            path: row.get(1)?,
            recursive: row.get(2)?,
            import_mode: parse_enum(&row.get::<_, String>(3)?)?,
            created_at: parse_datetime(&row.get::<_, String>(4)?)?,
            last_scanned_at: row
                .get::<_, Option<String>>(5)?
                .map(|value| parse_datetime(&value))
                .transpose()?,
        })
    })?;
    rows.collect()
}

fn load_assets(
    connection: &Connection,
    settings: Option<&LibrarySettings>,
) -> Result<Vec<Asset>, rusqlite::Error> {
    let mut metadata_by_asset = load_asset_metadata(connection)?;
    let mut variants_by_asset = HashMap::<Uuid, Vec<AssetVariant>>::new();
    let mut variant_statement = connection.prepare(
        r#"
        SELECT id, asset_id, kind, relative_path, mime_type, bytes, width, height,
               model_name, model_version, model_hash, created_at, rebuildable
        FROM asset_variants
        ORDER BY relative_path ASC
        "#,
    )?;
    let variants = variant_statement.query_map([], |row| {
        let asset_id = parse_uuid(&row.get::<_, String>(1)?)?;
        Ok((
            asset_id,
            AssetVariant {
                id: parse_uuid(&row.get::<_, String>(0)?)?,
                kind: parse_enum(&row.get::<_, String>(2)?)?,
                relative_path: row.get(3)?,
                mime_type: row.get(4)?,
                bytes: row.get(5)?,
                width: row.get(6)?,
                height: row.get(7)?,
                derived: ModelProvenance {
                    model_name: row.get(8)?,
                    model_version: row.get(9)?,
                    model_hash: row.get(10)?,
                    created_at: parse_datetime(&row.get::<_, String>(11)?)?,
                    rebuildable: row.get(12)?,
                },
            },
        ))
    })?;
    for pair in variants {
        let (asset_id, variant) = pair?;
        variants_by_asset.entry(asset_id).or_default().push(variant);
    }

    let mut statement = connection.prepare(
        r#"
        SELECT id, original_filename, relative_original_path, source_path, content_hash,
               media_kind, import_mode, bytes, mime_type, captured_at, imported_at,
               archived, favorite, is_available, place_hint
        FROM assets
        ORDER BY captured_at DESC
        "#,
    )?;
    let rows = statement.query_map([], |row| {
        let id = parse_uuid(&row.get::<_, String>(0)?)?;
        let import_mode: ImportMode = parse_enum(&row.get::<_, String>(6)?)?;
        let relative_original_path: String = row.get(2)?;
        let source_path: String = row.get(3)?;
        let mut asset = Asset {
            id,
            original_filename: row.get(1)?,
            relative_original_path: relative_original_path.clone(),
            source_path: source_path.clone(),
            content_hash: row.get(4)?,
            media_kind: parse_enum(&row.get::<_, String>(5)?)?,
            import_mode,
            bytes: row.get(7)?,
            mime_type: row.get(8)?,
            captured_at: parse_datetime(&row.get::<_, String>(9)?)?,
            imported_at: parse_datetime(&row.get::<_, String>(10)?)?,
            archived: row.get(11)?,
            favorite: row.get(12)?,
            is_available: row.get(13)?,
            place_hint: row.get(14)?,
            metadata: metadata_by_asset.remove(&id),
            variants: variants_by_asset.remove(&id).unwrap_or_default(),
        };
        asset.is_available = asset_exists(&asset, settings);
        Ok(asset)
    })?;
    rows.collect()
}

fn load_asset_metadata(
    connection: &Connection,
) -> Result<HashMap<Uuid, AssetMetadata>, rusqlite::Error> {
    let mut statement = connection.prepare(
        r#"
        SELECT asset_id, captured_at, captured_at_source, timezone_offset_minutes,
               width, height, camera_make, camera_model, lens_model,
               latitude, longitude, altitude_meters, location_source, exact_gps_hidden,
               sidecar_title, sidecar_description, folder_hint,
               model_name, model_version, model_hash, created_at, rebuildable
        FROM asset_metadata
        "#,
    )?;
    let rows = statement.query_map([], |row| {
        let asset_id = parse_uuid(&row.get::<_, String>(0)?)?;
        let camera = camera_info(row.get(6)?, row.get(7)?, row.get(8)?);
        let latitude: Option<f64> = row.get(9)?;
        let longitude: Option<f64> = row.get(10)?;
        let location_source: Option<String> = row.get(12)?;
        let geo = match (latitude, longitude, location_source) {
            (Some(latitude), Some(longitude), Some(source)) => Some(GeoTag {
                latitude,
                longitude,
                altitude_meters: row.get(11)?,
                source: parse_enum::<MetadataSource>(&source)?,
                exact_hidden: row.get(13)?,
            }),
            _ => None,
        };
        Ok((
            asset_id,
            AssetMetadata {
                asset_id,
                captured_at: parse_datetime(&row.get::<_, String>(1)?)?,
                captured_at_source: parse_enum(&row.get::<_, String>(2)?)?,
                timezone_offset_minutes: row.get(3)?,
                width: row.get(4)?,
                height: row.get(5)?,
                camera,
                geo,
                sidecar_title: row.get(14)?,
                sidecar_description: row.get(15)?,
                folder_hint: row.get(16)?,
                derived: ModelProvenance {
                    model_name: row.get(17)?,
                    model_version: row.get(18)?,
                    model_hash: row.get(19)?,
                    created_at: parse_datetime(&row.get::<_, String>(20)?)?,
                    rebuildable: row.get(21)?,
                },
            },
        ))
    })?;
    rows.collect()
}

fn load_albums(connection: &Connection) -> Result<Vec<Album>, rusqlite::Error> {
    let memberships = load_positioned_memberships(connection, "album_assets", "album_id")?;
    let mut statement = connection.prepare(
        r#"
        SELECT id, title, cover_asset_id, created_at, updated_at
        FROM albums
        ORDER BY updated_at DESC
        "#,
    )?;
    let rows = statement.query_map([], |row| {
        let id = parse_uuid(&row.get::<_, String>(0)?)?;
        Ok(Album {
            id,
            title: row.get(1)?,
            asset_ids: memberships.get(&id).cloned().unwrap_or_default(),
            cover_asset_id: row
                .get::<_, Option<String>>(2)?
                .map(|value| parse_uuid(&value))
                .transpose()?,
            created_at: parse_datetime(&row.get::<_, String>(3)?)?,
            updated_at: parse_datetime(&row.get::<_, String>(4)?)?,
        })
    })?;
    rows.collect()
}

fn load_people(connection: &Connection) -> Result<Vec<PersonCluster>, rusqlite::Error> {
    let mut statement = connection.prepare(
        r#"
        SELECT id, display_name, asset_ids_json, face_template_ids_json, representative_asset_id,
               hidden, model_name, model_version, model_hash, created_at, rebuildable
        FROM person_clusters
        ORDER BY display_name ASC
        "#,
    )?;
    let rows = statement.query_map([], |row| {
        Ok(PersonCluster {
            id: parse_uuid(&row.get::<_, String>(0)?)?,
            display_name: row.get(1)?,
            asset_ids: parse_uuid_vec(&row.get::<_, String>(2)?)?,
            face_template_ids: parse_uuid_vec(&row.get::<_, String>(3)?)?,
            representative_asset_id: row
                .get::<_, Option<String>>(4)?
                .map(|value| parse_uuid(&value))
                .transpose()?,
            hidden: row.get(5)?,
            derived: ModelProvenance {
                model_name: row.get(6)?,
                model_version: row.get(7)?,
                model_hash: row.get(8)?,
                created_at: parse_datetime(&row.get::<_, String>(9)?)?,
                rebuildable: row.get(10)?,
            },
        })
    })?;
    rows.collect()
}

fn load_places(connection: &Connection) -> Result<Vec<PlaceCluster>, rusqlite::Error> {
    let memberships = load_memberships(connection, "place_assets", "place_id")?;
    let mut statement = connection.prepare(
        r#"
        SELECT id, label, country_code, region, centroid_latitude, centroid_longitude,
               model_name, model_version, model_hash, created_at, rebuildable
        FROM place_clusters
        ORDER BY label ASC
        "#,
    )?;
    let rows = statement.query_map([], |row| {
        let id = parse_uuid(&row.get::<_, String>(0)?)?;
        Ok(PlaceCluster {
            id,
            label: row.get(1)?,
            country_code: row.get(2)?,
            region: row.get(3)?,
            asset_ids: memberships.get(&id).cloned().unwrap_or_default(),
            centroid_latitude: row.get(4)?,
            centroid_longitude: row.get(5)?,
            derived: ModelProvenance {
                model_name: row.get(6)?,
                model_version: row.get(7)?,
                model_hash: row.get(8)?,
                created_at: parse_datetime(&row.get::<_, String>(9)?)?,
                rebuildable: row.get(10)?,
            },
        })
    })?;
    rows.collect()
}

fn load_events(connection: &Connection) -> Result<Vec<EventCluster>, rusqlite::Error> {
    let memberships = load_memberships(connection, "event_assets", "event_id")?;
    let mut statement = connection.prepare(
        r#"
        SELECT id, title, title_source, start_at, end_at, place_id, people_ids_json,
               model_name, model_version, model_hash, created_at, rebuildable
        FROM event_clusters
        ORDER BY start_at DESC
        "#,
    )?;
    let rows = statement.query_map([], |row| {
        let id = parse_uuid(&row.get::<_, String>(0)?)?;
        Ok(EventCluster {
            id,
            title: row.get(1)?,
            title_source: parse_enum(&row.get::<_, String>(2)?)?,
            asset_ids: memberships.get(&id).cloned().unwrap_or_default(),
            start_at: parse_datetime(&row.get::<_, String>(3)?)?,
            end_at: parse_datetime(&row.get::<_, String>(4)?)?,
            place_id: row
                .get::<_, Option<String>>(5)?
                .map(|value| parse_uuid(&value))
                .transpose()?,
            people_ids: parse_uuid_vec(&row.get::<_, String>(6)?)?,
            derived: ModelProvenance {
                model_name: row.get(7)?,
                model_version: row.get(8)?,
                model_hash: row.get(9)?,
                created_at: parse_datetime(&row.get::<_, String>(10)?)?,
                rebuildable: row.get(11)?,
            },
        })
    })?;
    rows.collect()
}

fn load_faces(connection: &Connection) -> Result<Vec<FaceTemplate>, rusqlite::Error> {
    let mut statement = connection.prepare(
        r#"
        SELECT id, asset_id, person_cluster_id, preview_variant_id, bounding_box_json,
               model_name, model_version, model_hash, created_at, rebuildable
        FROM face_templates
        "#,
    )?;
    let rows = statement.query_map([], |row| {
        Ok(FaceTemplate {
            id: parse_uuid(&row.get::<_, String>(0)?)?,
            asset_id: parse_uuid(&row.get::<_, String>(1)?)?,
            person_cluster_id: row
                .get::<_, Option<String>>(2)?
                .map(|value| parse_uuid(&value))
                .transpose()?,
            preview_variant_id: row
                .get::<_, Option<String>>(3)?
                .map(|value| parse_uuid(&value))
                .transpose()?,
            bounding_box: serde_json::from_str(&row.get::<_, String>(4)?).map_err(|err| {
                rusqlite::Error::FromSqlConversionFailure(
                    4,
                    rusqlite::types::Type::Text,
                    Box::new(err),
                )
            })?,
            derived: ModelProvenance {
                model_name: row.get(5)?,
                model_version: row.get(6)?,
                model_hash: row.get(7)?,
                created_at: parse_datetime(&row.get::<_, String>(8)?)?,
                rebuildable: row.get(9)?,
            },
        })
    })?;
    rows.collect()
}

fn load_ocr_blocks(connection: &Connection) -> Result<Vec<OcrBlock>, rusqlite::Error> {
    let mut statement = connection.prepare(
        r#"
        SELECT id, asset_id, text, bounding_box_json,
               model_name, model_version, model_hash, created_at, rebuildable
        FROM ocr_blocks
        ORDER BY created_at ASC
        "#,
    )?;
    let rows = statement.query_map([], |row| {
        let bounding_box_json: Option<String> = row.get(3)?;
        Ok(OcrBlock {
            id: parse_uuid(&row.get::<_, String>(0)?)?,
            asset_id: parse_uuid(&row.get::<_, String>(1)?)?,
            text: row.get(2)?,
            bounding_box: bounding_box_json
                .map(|value| {
                    serde_json::from_str(&value).map_err(|err| {
                        rusqlite::Error::FromSqlConversionFailure(
                            3,
                            rusqlite::types::Type::Text,
                            Box::new(err),
                        )
                    })
                })
                .transpose()?,
            derived: ModelProvenance {
                model_name: row.get(4)?,
                model_version: row.get(5)?,
                model_hash: row.get(6)?,
                created_at: parse_datetime(&row.get::<_, String>(7)?)?,
                rebuildable: row.get(8)?,
            },
        })
    })?;
    rows.collect()
}

fn load_scene_tags(connection: &Connection) -> Result<Vec<SceneTag>, rusqlite::Error> {
    let mut statement = connection.prepare(
        r#"
        SELECT id, asset_id, label, confidence,
               model_name, model_version, model_hash, created_at, rebuildable
        FROM scene_tags
        ORDER BY created_at ASC
        "#,
    )?;
    let rows = statement.query_map([], |row| {
        Ok(SceneTag {
            id: parse_uuid(&row.get::<_, String>(0)?)?,
            asset_id: parse_uuid(&row.get::<_, String>(1)?)?,
            label: row.get(2)?,
            confidence: row.get(3)?,
            derived: ModelProvenance {
                model_name: row.get(4)?,
                model_version: row.get(5)?,
                model_hash: row.get(6)?,
                created_at: parse_datetime(&row.get::<_, String>(7)?)?,
                rebuildable: row.get(8)?,
            },
        })
    })?;
    rows.collect()
}

fn load_feedback(connection: &Connection) -> Result<Vec<FeedbackEvent>, rusqlite::Error> {
    let mut statement = connection.prepare(
        "SELECT id, kind, payload_json, created_at FROM feedback_events ORDER BY created_at ASC",
    )?;
    let rows = statement.query_map([], |row| {
        Ok(FeedbackEvent {
            id: parse_uuid(&row.get::<_, String>(0)?)?,
            kind: parse_enum(&row.get::<_, String>(1)?)?,
            payload: serde_json::from_str(&row.get::<_, String>(2)?).map_err(|err| {
                rusqlite::Error::FromSqlConversionFailure(
                    2,
                    rusqlite::types::Type::Text,
                    Box::new(err),
                )
            })?,
            created_at: parse_datetime(&row.get::<_, String>(3)?)?,
        })
    })?;
    rows.collect()
}

fn load_vaults(connection: &Connection) -> Result<Vec<Vault>, rusqlite::Error> {
    let mut statement = connection.prepare(
        r#"
        SELECT id, name, storage_policy_json, key_version, deletion_grace_days, created_at, updated_at
        FROM vaults
        ORDER BY created_at ASC
        "#,
    )?;
    let rows = statement.query_map([], |row| {
        Ok(Vault {
            id: parse_uuid(&row.get::<_, String>(0)?)?,
            name: row.get(1)?,
            storage_policy: parse_json(&row.get::<_, String>(2)?)?,
            key_version: row.get(3)?,
            deletion_grace_days: row.get(4)?,
            created_at: parse_datetime(&row.get::<_, String>(5)?)?,
            updated_at: parse_datetime(&row.get::<_, String>(6)?)?,
        })
    })?;
    rows.collect()
}

fn load_devices(connection: &Connection) -> Result<Vec<DeviceIdentity>, rusqlite::Error> {
    let mut statement = connection.prepare(
        r#"
        SELECT id, display_name, platform, public_key, trust_level, storage_profile_json,
               enrolled_at, last_seen_at, revoked_at
        FROM device_identities
        ORDER BY enrolled_at ASC
        "#,
    )?;
    let rows = statement.query_map([], |row| {
        Ok(DeviceIdentity {
            id: parse_uuid(&row.get::<_, String>(0)?)?,
            display_name: row.get(1)?,
            platform: row.get(2)?,
            public_key: row.get(3)?,
            trust_level: parse_enum(&row.get::<_, String>(4)?)?,
            storage_profile: parse_json(&row.get::<_, String>(5)?)?,
            enrolled_at: parse_datetime(&row.get::<_, String>(6)?)?,
            last_seen_at: row
                .get::<_, Option<String>>(7)?
                .map(|value| parse_datetime(&value))
                .transpose()?,
            revoked_at: row
                .get::<_, Option<String>>(8)?
                .map(|value| parse_datetime(&value))
                .transpose()?,
        })
    })?;
    rows.collect()
}

fn load_vault_members(connection: &Connection) -> Result<Vec<VaultMember>, rusqlite::Error> {
    let mut statement = connection.prepare(
        r#"
        SELECT id, vault_id, device_id, role, trust_level, display_name, added_at, revoked_at
        FROM vault_members
        ORDER BY added_at ASC
        "#,
    )?;
    let rows = statement.query_map([], |row| {
        Ok(VaultMember {
            id: parse_uuid(&row.get::<_, String>(0)?)?,
            vault_id: parse_uuid(&row.get::<_, String>(1)?)?,
            device_id: parse_uuid(&row.get::<_, String>(2)?)?,
            role: parse_enum(&row.get::<_, String>(3)?)?,
            trust_level: parse_enum(&row.get::<_, String>(4)?)?,
            display_name: row.get(5)?,
            added_at: parse_datetime(&row.get::<_, String>(6)?)?,
            revoked_at: row
                .get::<_, Option<String>>(7)?
                .map(|value| parse_datetime(&value))
                .transpose()?,
        })
    })?;
    rows.collect()
}

fn load_blob_records(connection: &Connection) -> Result<Vec<BlobRecord>, rusqlite::Error> {
    let mut statement = connection.prepare(
        r#"
        SELECT id, vault_id, asset_id, content_hash, encrypted_hash, bytes, chunk_count,
               encryption_key_version, created_at, tombstoned_at
        FROM blob_records
        ORDER BY created_at ASC
        "#,
    )?;
    let rows = statement.query_map([], |row| {
        Ok(BlobRecord {
            id: parse_uuid(&row.get::<_, String>(0)?)?,
            vault_id: parse_uuid(&row.get::<_, String>(1)?)?,
            asset_id: parse_uuid(&row.get::<_, String>(2)?)?,
            content_hash: row.get(3)?,
            encrypted_hash: row.get(4)?,
            bytes: row.get(5)?,
            chunk_count: row.get(6)?,
            encryption_key_version: row.get(7)?,
            created_at: parse_datetime(&row.get::<_, String>(8)?)?,
            tombstoned_at: row
                .get::<_, Option<String>>(9)?
                .map(|value| parse_datetime(&value))
                .transpose()?,
        })
    })?;
    rows.collect()
}

fn load_blob_chunks(connection: &Connection) -> Result<Vec<BlobChunk>, rusqlite::Error> {
    let mut statement = connection.prepare(
        r#"
        SELECT id, blob_id, chunk_index, content_hash, encrypted_hash, bytes
        FROM blob_chunks
        ORDER BY blob_id ASC, chunk_index ASC
        "#,
    )?;
    let rows = statement.query_map([], |row| {
        Ok(BlobChunk {
            id: parse_uuid(&row.get::<_, String>(0)?)?,
            blob_id: parse_uuid(&row.get::<_, String>(1)?)?,
            chunk_index: row.get(2)?,
            content_hash: row.get(3)?,
            encrypted_hash: row.get(4)?,
            bytes: row.get(5)?,
        })
    })?;
    rows.collect()
}

fn load_blob_replicas(connection: &Connection) -> Result<Vec<BlobReplica>, rusqlite::Error> {
    let mut statement = connection.prepare(
        r#"
        SELECT id, blob_id, device_id, health, bytes_present, verified_at, transfer_id
        FROM blob_replicas
        ORDER BY verified_at DESC
        "#,
    )?;
    let rows = statement.query_map([], |row| {
        Ok(BlobReplica {
            id: parse_uuid(&row.get::<_, String>(0)?)?,
            blob_id: parse_uuid(&row.get::<_, String>(1)?)?,
            device_id: parse_uuid(&row.get::<_, String>(2)?)?,
            health: parse_enum(&row.get::<_, String>(3)?)?,
            bytes_present: row.get(4)?,
            verified_at: row
                .get::<_, Option<String>>(5)?
                .map(|value| parse_datetime(&value))
                .transpose()?,
            transfer_id: row
                .get::<_, Option<String>>(6)?
                .map(|value| parse_uuid(&value))
                .transpose()?,
        })
    })?;
    rows.collect()
}

fn load_sync_transfers_v2(connection: &Connection) -> Result<Vec<SyncTransfer>, rusqlite::Error> {
    let mut statement = connection.prepare(
        r#"
        SELECT id, vault_id, blob_id, from_device_id, to_device_id, status, bytes_total,
               bytes_completed, started_at, updated_at, resumable_until
        FROM sync_transfers
        ORDER BY updated_at DESC
        "#,
    )?;
    let rows = statement.query_map([], |row| {
        Ok(SyncTransfer {
            id: parse_uuid(&row.get::<_, String>(0)?)?,
            vault_id: parse_uuid(&row.get::<_, String>(1)?)?,
            blob_id: parse_uuid(&row.get::<_, String>(2)?)?,
            from_device_id: row
                .get::<_, Option<String>>(3)?
                .map(|value| parse_uuid(&value))
                .transpose()?,
            to_device_id: parse_uuid(&row.get::<_, String>(4)?)?,
            status: parse_enum(&row.get::<_, String>(5)?)?,
            bytes_total: row.get(6)?,
            bytes_completed: row.get(7)?,
            started_at: row
                .get::<_, Option<String>>(8)?
                .map(|value| parse_datetime(&value))
                .transpose()?,
            updated_at: parse_datetime(&row.get::<_, String>(9)?)?,
            resumable_until: parse_datetime(&row.get::<_, String>(10)?)?,
        })
    })?;
    rows.collect()
}

fn load_sync_conflicts(connection: &Connection) -> Result<Vec<SyncConflict>, rusqlite::Error> {
    let mut statement = connection.prepare(
        r#"
        SELECT id, vault_id, asset_id, field, actor_device_ids_json, detected_at, detail
        FROM sync_conflicts
        ORDER BY detected_at DESC
        "#,
    )?;
    let rows = statement.query_map([], |row| {
        Ok(SyncConflict {
            id: parse_uuid(&row.get::<_, String>(0)?)?,
            vault_id: parse_uuid(&row.get::<_, String>(1)?)?,
            asset_id: row
                .get::<_, Option<String>>(2)?
                .map(|value| parse_uuid(&value))
                .transpose()?,
            field: row.get(3)?,
            actor_device_ids: parse_uuid_vec(&row.get::<_, String>(4)?)?,
            detected_at: parse_datetime(&row.get::<_, String>(5)?)?,
            detail: row.get(6)?,
        })
    })?;
    rows.collect()
}

fn load_vault_invites(connection: &Connection) -> Result<Vec<VaultInvite>, rusqlite::Error> {
    let mut statement = connection.prepare(
        r#"
        SELECT id, vault_id, invited_device_name, role, trust_level, invite_code,
               created_at, expires_at, accepted_at
        FROM vault_invites
        ORDER BY created_at DESC
        "#,
    )?;
    let rows = statement.query_map([], |row| {
        Ok(VaultInvite {
            id: parse_uuid(&row.get::<_, String>(0)?)?,
            vault_id: parse_uuid(&row.get::<_, String>(1)?)?,
            invited_device_name: row.get(2)?,
            role: parse_enum(&row.get::<_, String>(3)?)?,
            trust_level: parse_enum(&row.get::<_, String>(4)?)?,
            invite_code: row.get(5)?,
            created_at: parse_datetime(&row.get::<_, String>(6)?)?,
            expires_at: parse_datetime(&row.get::<_, String>(7)?)?,
            accepted_at: row
                .get::<_, Option<String>>(8)?
                .map(|value| parse_datetime(&value))
                .transpose()?,
        })
    })?;
    rows.collect()
}

fn load_relay_endpoints(connection: &Connection) -> Result<Vec<RelayEndpoint>, rusqlite::Error> {
    let mut statement = connection.prepare(
        r#"
        SELECT id, device_id, node_id, relay_url, direct_addresses_json, last_seen_at, expires_at
        FROM relay_endpoints
        ORDER BY last_seen_at DESC
        "#,
    )?;
    let rows = statement.query_map([], |row| {
        Ok(RelayEndpoint {
            id: parse_uuid(&row.get::<_, String>(0)?)?,
            device_id: parse_uuid(&row.get::<_, String>(1)?)?,
            node_id: row.get(2)?,
            relay_url: row.get(3)?,
            direct_addresses: parse_string_vec(&row.get::<_, String>(4)?)?,
            last_seen_at: parse_datetime(&row.get::<_, String>(5)?)?,
            expires_at: parse_datetime(&row.get::<_, String>(6)?)?,
        })
    })?;
    rows.collect()
}

fn load_capability_grants(
    connection: &Connection,
) -> Result<Vec<CapabilityGrant>, rusqlite::Error> {
    let mut statement = connection.prepare(
        r#"
        SELECT id, vault_id, device_id, capability, granted_by_device_id, granted_at, expires_at
        FROM capability_grants
        ORDER BY granted_at DESC
        "#,
    )?;
    let rows = statement.query_map([], |row| {
        Ok(CapabilityGrant {
            id: parse_uuid(&row.get::<_, String>(0)?)?,
            vault_id: parse_uuid(&row.get::<_, String>(1)?)?,
            device_id: parse_uuid(&row.get::<_, String>(2)?)?,
            capability: row.get(3)?,
            granted_by_device_id: row
                .get::<_, Option<String>>(4)?
                .map(|value| parse_uuid(&value))
                .transpose()?,
            granted_at: parse_datetime(&row.get::<_, String>(5)?)?,
            expires_at: row
                .get::<_, Option<String>>(6)?
                .map(|value| parse_datetime(&value))
                .transpose()?,
        })
    })?;
    rows.collect()
}

fn load_pairings(connection: &Connection) -> Result<Vec<DevicePairing>, rusqlite::Error> {
    let mut statement = connection.prepare(
        "SELECT id, device_name, platform, pairing_token, created_at, expires_at, approved_at FROM device_pairings ORDER BY created_at DESC",
    )?;
    let rows = statement.query_map([], |row| {
        Ok(DevicePairing {
            id: parse_uuid(&row.get::<_, String>(0)?)?,
            device_name: row.get(1)?,
            platform: row.get(2)?,
            pairing_token: row.get(3)?,
            created_at: parse_datetime(&row.get::<_, String>(4)?)?,
            expires_at: parse_datetime(&row.get::<_, String>(5)?)?,
            approved_at: row
                .get::<_, Option<String>>(6)?
                .map(|value| parse_datetime(&value))
                .transpose()?,
        })
    })?;
    rows.collect()
}

fn load_sync_sessions(connection: &Connection) -> Result<Vec<SyncSession>, rusqlite::Error> {
    let mut statement = connection.prepare(
        r#"
        SELECT id, pairing_id, status, started_at, last_seen_at, uploaded_asset_ids_json, rejected_asset_ids_json
        FROM sync_sessions
        ORDER BY started_at DESC
        "#,
    )?;
    let rows = statement.query_map([], |row| {
        Ok(SyncSession {
            id: parse_uuid(&row.get::<_, String>(0)?)?,
            pairing_id: parse_uuid(&row.get::<_, String>(1)?)?,
            status: parse_enum(&row.get::<_, String>(2)?)?,
            started_at: parse_datetime(&row.get::<_, String>(3)?)?,
            last_seen_at: row
                .get::<_, Option<String>>(4)?
                .map(|value| parse_datetime(&value))
                .transpose()?,
            uploaded_asset_ids: parse_uuid_vec(&row.get::<_, String>(5)?)?,
            rejected_asset_ids: parse_uuid_vec(&row.get::<_, String>(6)?)?,
        })
    })?;
    rows.collect()
}

fn load_import_sessions(connection: &Connection) -> Result<Vec<ImportSession>, rusqlite::Error> {
    let mut candidates_by_session = HashMap::<Uuid, Vec<ImportCandidate>>::new();
    let mut candidates_statement = connection.prepare(
        r#"
        SELECT id, session_id, source_path, original_filename, media_kind, mime_type, bytes,
               captured_at, place_hint, content_hash, duplicate_asset_id, selected, import_mode,
               destination_path, sidecar_paths_json, safety_status
        FROM import_candidates
        ORDER BY original_filename ASC
        "#,
    )?;
    let candidates = candidates_statement.query_map([], |row| {
        let session_id = parse_uuid(&row.get::<_, String>(1)?)?;
        Ok((
            session_id,
            ImportCandidate {
                id: parse_uuid(&row.get::<_, String>(0)?)?,
                session_id,
                source_path: row.get(2)?,
                original_filename: row.get(3)?,
                media_kind: parse_enum(&row.get::<_, String>(4)?)?,
                mime_type: row.get(5)?,
                bytes: row.get(6)?,
                captured_at: row
                    .get::<_, Option<String>>(7)?
                    .map(|value| parse_datetime(&value))
                    .transpose()?,
                place_hint: row.get(8)?,
                content_hash: row.get(9)?,
                duplicate_asset_id: row
                    .get::<_, Option<String>>(10)?
                    .map(|value| parse_uuid(&value))
                    .transpose()?,
                selected: row.get(11)?,
                import_mode: parse_enum(&row.get::<_, String>(12)?)?,
                destination_path: row.get(13)?,
                sidecar_paths: parse_string_vec(&row.get::<_, String>(14)?)?,
                safety_status: row.get(15)?,
            },
        ))
    })?;
    for pair in candidates {
        let (session_id, candidate) = pair?;
        candidates_by_session
            .entry(session_id)
            .or_default()
            .push(candidate);
    }

    let mut statement = connection.prepare(
        r#"
        SELECT id, source_kind, source_path, import_mode, add_as_watch_folder, status, created_at,
               completed_at, place_hint, imported_asset_ids_json, duplicate_asset_ids_json,
               moved_asset_ids_json, skipped_duplicate_ids_json, failed_candidate_ids_json,
               sidecars_moved, unsupported_file_paths_json
        FROM import_sessions
        ORDER BY created_at DESC
        "#,
    )?;
    let rows = statement.query_map([], |row| {
        let id = parse_uuid(&row.get::<_, String>(0)?)?;
        Ok(ImportSession {
            id,
            source_kind: parse_enum(&row.get::<_, String>(1)?)?,
            source_path: row.get(2)?,
            import_mode: parse_enum(&row.get::<_, String>(3)?)?,
            add_as_watch_folder: row.get(4)?,
            status: parse_enum(&row.get::<_, String>(5)?)?,
            created_at: parse_datetime(&row.get::<_, String>(6)?)?,
            completed_at: row
                .get::<_, Option<String>>(7)?
                .map(|value| parse_datetime(&value))
                .transpose()?,
            place_hint: row.get(8)?,
            imported_asset_ids: parse_uuid_vec(&row.get::<_, String>(9)?)?,
            duplicate_asset_ids: parse_uuid_vec(&row.get::<_, String>(10)?)?,
            moved_asset_ids: parse_uuid_vec(&row.get::<_, String>(11)?)?,
            skipped_duplicate_ids: parse_uuid_vec(&row.get::<_, String>(12)?)?,
            failed_candidate_ids: parse_uuid_vec(&row.get::<_, String>(13)?)?,
            sidecars_moved: row.get::<_, i64>(14)? as usize,
            unsupported_file_paths: parse_string_vec(&row.get::<_, String>(15)?)?,
            selected_candidate_count: 0,
            selected_bytes: 0,
            duplicate_count: 0,
            unsupported_count: 0,
            sidecar_count: 0,
            destination_root: None,
            requires_move_confirmation: false,
            source_contains_managed_library: false,
            selected_outside_source_count: 0,
            candidates: candidates_by_session.remove(&id).unwrap_or_default(),
        })
    })?;
    rows.collect()
}

fn load_jobs(connection: &Connection) -> Result<Vec<JobRecord>, rusqlite::Error> {
    let mut statement = connection.prepare(
        r#"
        SELECT id, kind, status, progress, queued_at, started_at, completed_at, detail,
               cancel_requested, retry_of_job_id, attempt
        FROM jobs
        ORDER BY queued_at DESC
        "#,
    )?;
    let rows = statement.query_map([], |row| {
        Ok(JobRecord {
            id: parse_uuid(&row.get::<_, String>(0)?)?,
            kind: parse_enum(&row.get::<_, String>(1)?)?,
            status: parse_enum(&row.get::<_, String>(2)?)?,
            progress: row.get(3)?,
            queued_at: parse_datetime(&row.get::<_, String>(4)?)?,
            started_at: row
                .get::<_, Option<String>>(5)?
                .map(|value| parse_datetime(&value))
                .transpose()?,
            completed_at: row
                .get::<_, Option<String>>(6)?
                .map(|value| parse_datetime(&value))
                .transpose()?,
            detail: row.get(7)?,
            cancel_requested: row.get(8)?,
            retry_of_job_id: row
                .get::<_, Option<String>>(9)?
                .map(|value| parse_uuid(&value))
                .transpose()?,
            attempt: row.get(10)?,
        })
    })?;
    rows.collect()
}

fn load_job_logs(connection: &Connection) -> Result<Vec<JobLog>, rusqlite::Error> {
    let mut statement = connection.prepare(
        "SELECT id, job_id, level, message, created_at FROM job_logs ORDER BY created_at ASC",
    )?;
    let rows = statement.query_map([], |row| {
        Ok(JobLog {
            id: parse_uuid(&row.get::<_, String>(0)?)?,
            job_id: parse_uuid(&row.get::<_, String>(1)?)?,
            level: row.get(2)?,
            message: row.get(3)?,
            created_at: parse_datetime(&row.get::<_, String>(4)?)?,
        })
    })?;
    rows.collect()
}

fn load_corrections(connection: &Connection) -> Result<Vec<CorrectionRecord>, rusqlite::Error> {
    let mut statement = connection.prepare(
        r#"
        SELECT id, kind, asset_id, place_id, event_id, previous_json, applied_json, created_at
        FROM correction_records
        ORDER BY created_at ASC
        "#,
    )?;
    let rows = statement.query_map([], |row| {
        Ok(CorrectionRecord {
            id: parse_uuid(&row.get::<_, String>(0)?)?,
            kind: parse_enum(&row.get::<_, String>(1)?)?,
            asset_id: row
                .get::<_, Option<String>>(2)?
                .map(|value| parse_uuid(&value))
                .transpose()?,
            place_id: row
                .get::<_, Option<String>>(3)?
                .map(|value| parse_uuid(&value))
                .transpose()?,
            event_id: row
                .get::<_, Option<String>>(4)?
                .map(|value| parse_uuid(&value))
                .transpose()?,
            previous_json: serde_json::from_str(&row.get::<_, String>(5)?).map_err(|err| {
                rusqlite::Error::FromSqlConversionFailure(
                    5,
                    rusqlite::types::Type::Text,
                    Box::new(err),
                )
            })?,
            applied_json: serde_json::from_str(&row.get::<_, String>(6)?).map_err(|err| {
                rusqlite::Error::FromSqlConversionFailure(
                    6,
                    rusqlite::types::Type::Text,
                    Box::new(err),
                )
            })?,
            created_at: parse_datetime(&row.get::<_, String>(7)?)?,
        })
    })?;
    rows.collect()
}

fn load_memberships(
    connection: &Connection,
    table: &str,
    parent_column: &str,
) -> Result<HashMap<Uuid, Vec<Uuid>>, rusqlite::Error> {
    let mut memberships = HashMap::<Uuid, Vec<Uuid>>::new();
    let query = format!("SELECT {parent_column}, asset_id FROM {table}");
    let mut statement = connection.prepare(&query)?;
    let rows = statement.query_map([], |row| {
        Ok((
            parse_uuid(&row.get::<_, String>(0)?)?,
            parse_uuid(&row.get::<_, String>(1)?)?,
        ))
    })?;

    for pair in rows {
        let (parent_id, asset_id) = pair?;
        memberships.entry(parent_id).or_default().push(asset_id);
    }

    Ok(memberships)
}

fn load_positioned_memberships(
    connection: &Connection,
    table: &str,
    parent_column: &str,
) -> Result<HashMap<Uuid, Vec<Uuid>>, rusqlite::Error> {
    let mut memberships = HashMap::<Uuid, Vec<Uuid>>::new();
    let query = format!("SELECT {parent_column}, asset_id FROM {table} ORDER BY position ASC");
    let mut statement = connection.prepare(&query)?;
    let rows = statement.query_map([], |row| {
        Ok((
            parse_uuid(&row.get::<_, String>(0)?)?,
            parse_uuid(&row.get::<_, String>(1)?)?,
        ))
    })?;

    for pair in rows {
        let (parent_id, asset_id) = pair?;
        memberships.entry(parent_id).or_default().push(asset_id);
    }

    Ok(memberships)
}

fn asset_exists(asset: &Asset, settings: Option<&LibrarySettings>) -> bool {
    match asset.import_mode {
        ImportMode::Reference => Path::new(&asset.source_path).exists(),
        ImportMode::Copy | ImportMode::Move => {
            let root = settings
                .map(|value| PathBuf::from(&value.library_root))
                .unwrap_or_else(|| PathBuf::from("library"));
            root.join(&asset.relative_original_path).exists()
        }
    }
}

fn camera_info(
    make: Option<String>,
    model: Option<String>,
    lens_model: Option<String>,
) -> Option<CameraInfo> {
    if make.is_none() && model.is_none() && lens_model.is_none() {
        return None;
    }
    Some(CameraInfo {
        make,
        model,
        lens_model,
    })
}

fn parse_uuid(value: &str) -> Result<Uuid, rusqlite::Error> {
    Uuid::parse_str(value).map_err(|err| {
        rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(err))
    })
}

fn parse_datetime(value: &str) -> Result<chrono::DateTime<chrono::Utc>, rusqlite::Error> {
    chrono::DateTime::parse_from_rfc3339(value)
        .map(|value| value.with_timezone(&chrono::Utc))
        .map_err(|err| {
            rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(err))
        })
}

fn parse_uuid_vec(value: &str) -> Result<Vec<Uuid>, rusqlite::Error> {
    let strings = serde_json::from_str::<Vec<String>>(value).map_err(|err| {
        rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(err))
    })?;
    strings.into_iter().map(|item| parse_uuid(&item)).collect()
}

fn parse_string_vec(value: &str) -> Result<Vec<String>, rusqlite::Error> {
    serde_json::from_str::<Vec<String>>(value).map_err(|err| {
        rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(err))
    })
}

fn uuid_vec_json(values: &[Uuid]) -> Result<String, rusqlite::Error> {
    serde_json::to_string(&values.iter().map(Uuid::to_string).collect::<Vec<_>>())
        .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))
}

fn string_vec_json(values: &[String]) -> Result<String, rusqlite::Error> {
    serde_json::to_string(values)
        .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))
}

fn json_string<T: serde::Serialize>(value: &T) -> Result<String, rusqlite::Error> {
    serde_json::to_string(value)
        .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))
}

fn parse_json<T>(value: &str) -> Result<T, rusqlite::Error>
where
    T: serde::de::DeserializeOwned,
{
    serde_json::from_str(value).map_err(|err| {
        rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(err))
    })
}

fn enum_string<T: serde::Serialize>(value: &T) -> Result<String, rusqlite::Error> {
    let raw = serde_json::to_value(value)
        .map_err(|err| rusqlite::Error::ToSqlConversionFailure(Box::new(err)))?;
    raw.as_str().map(ToString::to_string).ok_or_else(|| {
        rusqlite::Error::ToSqlConversionFailure("enum did not serialize to string".into())
    })
}

fn parse_enum<T>(value: &str) -> Result<T, rusqlite::Error>
where
    T: serde::de::DeserializeOwned,
{
    serde_json::from_value(serde_json::Value::String(value.to_string())).map_err(|err| {
        rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(err))
    })
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use chrono::Utc;
    use rusqlite::Connection;

    use crate::{
        config::AppConfig,
        domain::{ImportMode, LibrarySettings},
    };

    use super::{PersistedLibraryState, SCHEMA_VERSION, bootstrap_storage, load_state, save_state};

    fn temp_runtime_root() -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "private-gallery-storage-{}",
            Utc::now().timestamp_nanos_opt().unwrap_or_default()
        ));
        std::fs::create_dir_all(&path).expect("create runtime root");
        path
    }

    #[test]
    fn saves_and_loads_library_settings() {
        let runtime_root = temp_runtime_root();
        let config = AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        };
        let report = bootstrap_storage(&config).expect("bootstrap storage");
        let state = PersistedLibraryState {
            library_settings: Some(LibrarySettings {
                library_root: runtime_root.join("library").to_string_lossy().to_string(),
                default_import_mode: ImportMode::Copy,
                initialized_at: Utc::now(),
                updated_at: Utc::now(),
            }),
            ..PersistedLibraryState::default()
        };

        save_state(&report, &state).expect("save state");
        let loaded = load_state(&report).expect("load state");
        assert!(loaded.library_settings.is_some());
        assert_eq!(
            loaded
                .library_settings
                .expect("library settings")
                .default_import_mode,
            ImportMode::Copy
        );
    }

    #[test]
    fn migration_preserves_existing_state_when_user_version_changes() {
        let runtime_root = temp_runtime_root();
        let config = AppConfig {
            runtime_root: runtime_root.clone(),
            ..AppConfig::default()
        };
        let report = bootstrap_storage(&config).expect("bootstrap storage");
        let state = PersistedLibraryState {
            library_settings: Some(LibrarySettings {
                library_root: runtime_root.join("library").to_string_lossy().to_string(),
                default_import_mode: ImportMode::Move,
                initialized_at: Utc::now(),
                updated_at: Utc::now(),
            }),
            ..PersistedLibraryState::default()
        };
        save_state(&report, &state).expect("save state");

        let connection = Connection::open(&report.database_path).expect("open db");
        connection
            .pragma_update(None, "user_version", 5_i64)
            .expect("downgrade version marker");
        drop(connection);

        let migrated = bootstrap_storage(&config).expect("migrate storage");
        let loaded = load_state(&migrated).expect("load migrated state");
        assert_eq!(
            loaded
                .library_settings
                .expect("library settings")
                .default_import_mode,
            ImportMode::Move
        );

        let connection = Connection::open(&migrated.database_path).expect("open migrated db");
        let version: i64 = connection
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .expect("user version");
        assert_eq!(version, SCHEMA_VERSION);
    }
}
