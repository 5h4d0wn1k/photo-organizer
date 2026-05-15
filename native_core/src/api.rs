use std::sync::Arc;

use axum::{
    Json, Router,
    extract::{Path, Query, State},
    http::{HeaderValue, Method, StatusCode, header::CONTENT_TYPE},
    response::{IntoResponse, Response},
    routing::{delete, get, post},
};
use serde::Deserialize;
use serde_json::json;
use thiserror::Error;
use tower_http::{cors::CorsLayer, trace::TraceLayer};
use uuid::Uuid;

use crate::{
    domain::{
        BackupExportRequest, BackupRestorePlanRequest, BackupRestoreRunRequest,
        BackupVerifyRequest, CommitImportSessionRequest, CorrectDateRequest, CorrectPlaceRequest,
        CreateAlbumRequest, CreateDeviceRequest, CreateManualPersonRequest,
        CreatePairingSessionRequest, CreateVaultRequest, CreateWatchFolderRequest,
        EncryptionActivationRequest, EnrollDeviceRequest, FeedbackEvent, HidePersonRequest,
        MergePersonRequest, ModelImportRequest, ModelInstallRequest, RebuildRequest,
        RejectPersonMatchRequest, RenameAlbumRequest, RenamePersonRequest, RevokeDeviceRequest,
        RunSyncRequest, ScanImportSourceRequest, SearchQuery, SplitPersonRequest,
        TitleEventRequest, UpdateAlbumAssetsRequest, UpdateAssetFlagsRequest,
        UpdateAssetsFlagsRequest, UpdateLibrarySettingsRequest, UpdatePersonAssetsRequest,
        UpdateVaultStoragePolicyRequest,
    },
    service::{GalleryService, ServiceError},
};

#[derive(Clone)]
pub struct AppState {
    pub service: Arc<GalleryService>,
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/library/status", get(library_status))
        .route(
            "/library/settings",
            get(get_library_settings).post(update_library_settings),
        )
        .route(
            "/watch-folders",
            get(list_watch_folders).post(create_watch_folder),
        )
        .route(
            "/watch-folders/{watch_folder_id}",
            delete(delete_watch_folder),
        )
        .route("/pairing/sessions", post(create_pairing_session))
        .route("/vaults", get(list_vaults).post(create_vault))
        .route("/vaults/{vault_id}/status", get(vault_status))
        .route(
            "/vaults/{vault_id}/storage-policy",
            post(update_vault_storage_policy),
        )
        .route("/devices", get(list_devices).post(create_device))
        .route("/devices/enroll", post(enroll_device))
        .route("/devices/{device_id}/revoke", post(revoke_device))
        .route("/sync/plan", get(sync_plan))
        .route("/sync/run", post(run_sync))
        .route("/sync/transfers", get(sync_transfers))
        .route("/sync/network/status", get(sync_network_status))
        .route("/sync/network/start", post(start_sync_network))
        .route("/sync/network/stop", post(stop_sync_network))
        .route(
            "/sync/transfers/{transfer_id}/retry",
            post(retry_sync_transfer),
        )
        .route(
            "/sync/transfers/{transfer_id}/cancel",
            post(cancel_sync_transfer),
        )
        .route("/assets/favorites", get(list_favorite_assets))
        .route("/assets/archived", get(list_archived_assets))
        .route("/assets/flags/bulk", post(update_assets_flags))
        .route("/assets/{asset_id}/flags", post(update_asset_flags))
        .route("/assets/{asset_id}/original", get(asset_original))
        .route("/assets/{asset_id}/availability", get(asset_availability))
        .route("/assets/{asset_id}/pin-local", post(pin_local_asset))
        .route("/assets/{asset_id}/evict-local", post(evict_local_asset))
        .route("/albums", get(list_albums).post(create_album))
        .route("/albums/{album_id}", get(get_album).delete(delete_album))
        .route("/albums/{album_id}/rename", post(rename_album))
        .route(
            "/albums/{album_id}/assets",
            get(get_album_assets).post(add_album_assets),
        )
        .route(
            "/albums/{album_id}/assets/remove",
            post(remove_album_assets),
        )
        .route("/imports/assets", post(import_asset))
        .route("/imports/scan", post(scan_import_source))
        .route("/imports/commit", post(commit_import_session))
        .route("/imports/sessions", get(list_import_sessions))
        .route("/imports/sessions/{session_id}", get(get_import_session))
        .route("/metadata/rebuild", post(rebuild_metadata))
        .route("/metadata/assets/{asset_id}", get(get_asset_metadata))
        .route(
            "/metadata/assets/{asset_id}/correct-date",
            post(correct_asset_date),
        )
        .route("/timeline", get(timeline))
        .route("/people", get(list_people))
        .route("/people/manual", post(create_manual_person))
        .route("/people/index", post(index_people))
        .route("/people/reset", post(reset_people))
        .route("/people/{person_id}", get(get_person))
        .route(
            "/people/{person_id}/assets",
            get(get_person_assets).post(add_person_assets),
        )
        .route(
            "/people/{person_id}/assets/remove",
            post(remove_person_assets),
        )
        .route("/people/{person_id}/rename", post(rename_person))
        .route("/people/{person_id}/hide", post(hide_person))
        .route(
            "/people/{person_id}/reject-match",
            post(reject_person_match),
        )
        .route("/people/{person_id}/merge", post(merge_person))
        .route("/people/{person_id}/split", post(split_person))
        .route("/places", get(list_places))
        .route("/places/rebuild", post(rebuild_places))
        .route("/places/{place_id}/assets", get(get_place_assets))
        .route("/places/{place_id}/correct", post(correct_place))
        .route("/events", get(list_events))
        .route("/events/rebuild", post(rebuild_events))
        .route("/events/{event_id}/assets", get(get_event_assets))
        .route("/events/{event_id}/title", post(title_event))
        .route("/feedback", post(record_feedback))
        .route("/search", get(search))
        .route("/search/status", get(search_status))
        .route("/search/rebuild", post(rebuild_search))
        .route("/ocr/rebuild", post(rebuild_ocr))
        .route("/ocr/assets/{asset_id}", get(get_asset_ocr_blocks))
        .route("/scenes/rebuild", post(rebuild_scenes))
        .route("/semantic/rebuild", post(rebuild_semantic))
        .route("/jobs", get(list_jobs))
        .route("/jobs/{job_id}", get(get_job))
        .route("/jobs/{job_id}/logs", get(get_job_logs))
        .route("/jobs/{job_id}/cancel", post(cancel_job))
        .route("/jobs/{job_id}/retry", post(retry_job))
        .route("/privacy/status", get(privacy_status))
        .route("/security/encryption-status", get(encryption_status))
        .route("/security/encryption/status", get(encryption_status))
        .route("/security/encryption/activate", post(activate_encryption))
        .route("/backup/export", post(export_backup))
        .route("/backup/verify", post(verify_backup))
        .route("/backup/restore/plan", post(plan_restore_backup))
        .route("/backup/restore/run", post(run_restore_backup))
        .route("/backup/restore/verify", post(verify_restore_backup))
        .route("/models", get(list_models))
        .route("/models/runtime-status", get(model_runtime_status))
        .route("/models/install", post(install_model))
        .route("/models/import-local", post(import_local_model))
        .route("/models/{model_id}/verify", post(verify_model))
        .route("/diagnostics", get(diagnostics))
        .with_state(state)
        .layer(private_cors_layer())
        .layer(TraceLayer::new_for_http())
}

fn private_cors_layer() -> CorsLayer {
    CorsLayer::new()
        .allow_origin([
            HeaderValue::from_static("http://127.0.0.1:4821"),
            HeaderValue::from_static("http://localhost:4821"),
        ])
        .allow_methods([Method::GET, Method::POST, Method::DELETE])
        .allow_headers([CONTENT_TYPE])
}

#[derive(Debug, Error)]
enum ApiError {
    #[error("{0}")]
    Service(#[from] ServiceError),
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, message) = match self {
            Self::Service(ServiceError::NotFound(message)) => (StatusCode::NOT_FOUND, message),
            Self::Service(ServiceError::Invalid(message)) => (StatusCode::BAD_REQUEST, message),
            Self::Service(ServiceError::Storage(message))
            | Self::Service(ServiceError::Io(message)) => {
                (StatusCode::INTERNAL_SERVER_ERROR, message)
            }
        };

        (status, Json(json!({ "error": message }))).into_response()
    }
}

async fn health() -> Json<serde_json::Value> {
    Json(json!({ "status": "ok" }))
}

async fn library_status(
    State(state): State<AppState>,
) -> Result<Json<crate::domain::LibraryStatusResponse>, ApiError> {
    Ok(Json(state.service.library_status().await))
}

async fn get_library_settings(
    State(state): State<AppState>,
) -> Result<Json<crate::domain::LibrarySettings>, ApiError> {
    Ok(Json(state.service.library_settings().await?))
}

async fn update_library_settings(
    State(state): State<AppState>,
    Json(request): Json<UpdateLibrarySettingsRequest>,
) -> Result<Json<crate::domain::LibrarySettings>, ApiError> {
    Ok(Json(state.service.update_library_settings(request).await?))
}

async fn list_watch_folders(
    State(state): State<AppState>,
) -> Result<Json<Vec<crate::domain::WatchFolder>>, ApiError> {
    Ok(Json(state.service.watch_folders().await))
}

async fn create_watch_folder(
    State(state): State<AppState>,
    Json(request): Json<CreateWatchFolderRequest>,
) -> Result<Json<crate::domain::WatchFolder>, ApiError> {
    Ok(Json(state.service.add_watch_folder(request).await?))
}

async fn delete_watch_folder(
    State(state): State<AppState>,
    Path(watch_folder_id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    state.service.delete_watch_folder(watch_folder_id).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn create_pairing_session(
    State(state): State<AppState>,
    Json(request): Json<CreatePairingSessionRequest>,
) -> Result<Json<crate::domain::DevicePairing>, ApiError> {
    Ok(Json(state.service.create_pairing_session(request).await?))
}

async fn list_vaults(
    State(state): State<AppState>,
) -> Result<Json<Vec<crate::domain::Vault>>, ApiError> {
    Ok(Json(state.service.vaults().await))
}

async fn create_vault(
    State(state): State<AppState>,
    Json(request): Json<CreateVaultRequest>,
) -> Result<Json<crate::domain::Vault>, ApiError> {
    Ok(Json(state.service.create_vault(request).await?))
}

async fn vault_status(
    State(state): State<AppState>,
    Path(vault_id): Path<Uuid>,
) -> Result<Json<crate::domain::VaultStatus>, ApiError> {
    Ok(Json(state.service.vault_status(vault_id).await?))
}

async fn update_vault_storage_policy(
    State(state): State<AppState>,
    Path(vault_id): Path<Uuid>,
    Json(request): Json<UpdateVaultStoragePolicyRequest>,
) -> Result<Json<crate::domain::Vault>, ApiError> {
    Ok(Json(
        state
            .service
            .update_vault_storage_policy(vault_id, request)
            .await?,
    ))
}

async fn list_devices(
    State(state): State<AppState>,
) -> Result<Json<Vec<crate::domain::DeviceIdentity>>, ApiError> {
    Ok(Json(state.service.devices().await))
}

async fn create_device(
    State(state): State<AppState>,
    Json(request): Json<CreateDeviceRequest>,
) -> Result<Json<crate::domain::DeviceIdentity>, ApiError> {
    Ok(Json(state.service.create_device(request).await?))
}

async fn enroll_device(
    State(state): State<AppState>,
    Json(request): Json<EnrollDeviceRequest>,
) -> Result<Json<crate::domain::DeviceIdentity>, ApiError> {
    Ok(Json(state.service.enroll_device(request).await?))
}

async fn revoke_device(
    State(state): State<AppState>,
    Path(device_id): Path<Uuid>,
    Json(request): Json<RevokeDeviceRequest>,
) -> Result<Json<crate::domain::DeviceIdentity>, ApiError> {
    Ok(Json(state.service.revoke_device(device_id, request).await?))
}

#[derive(Debug, Default, Deserialize)]
struct SyncPlanQuery {
    #[serde(default)]
    vault_id: Option<Uuid>,
}

async fn sync_plan(
    State(state): State<AppState>,
    Query(query): Query<SyncPlanQuery>,
) -> Result<Json<crate::domain::SyncPlan>, ApiError> {
    Ok(Json(state.service.sync_plan(query.vault_id).await?))
}

async fn run_sync(
    State(state): State<AppState>,
    Json(request): Json<RunSyncRequest>,
) -> Result<Json<crate::domain::SyncPlan>, ApiError> {
    Ok(Json(state.service.run_sync(request).await?))
}

async fn sync_transfers(
    State(state): State<AppState>,
) -> Result<Json<Vec<crate::domain::SyncTransfer>>, ApiError> {
    Ok(Json(state.service.sync_transfers().await))
}

async fn sync_network_status(
    State(state): State<AppState>,
) -> Result<Json<crate::domain::SyncNetworkStatus>, ApiError> {
    Ok(Json(state.service.sync_network_status().await))
}

async fn start_sync_network(
    State(state): State<AppState>,
) -> Result<Json<crate::domain::SyncNetworkStatus>, ApiError> {
    Ok(Json(state.service.start_sync_network().await?))
}

async fn stop_sync_network(
    State(state): State<AppState>,
) -> Result<Json<crate::domain::SyncNetworkStatus>, ApiError> {
    Ok(Json(state.service.stop_sync_network().await?))
}

async fn retry_sync_transfer(
    State(state): State<AppState>,
    Path(transfer_id): Path<Uuid>,
) -> Result<Json<crate::domain::SyncTransfer>, ApiError> {
    Ok(Json(state.service.retry_sync_transfer(transfer_id).await?))
}

async fn cancel_sync_transfer(
    State(state): State<AppState>,
    Path(transfer_id): Path<Uuid>,
) -> Result<Json<crate::domain::SyncTransfer>, ApiError> {
    Ok(Json(state.service.cancel_sync_transfer(transfer_id).await?))
}

async fn scan_import_source(
    State(state): State<AppState>,
    Json(request): Json<ScanImportSourceRequest>,
) -> Result<Json<crate::domain::ImportSession>, ApiError> {
    Ok(Json(state.service.scan_import_source(request).await?))
}

async fn commit_import_session(
    State(state): State<AppState>,
    Json(request): Json<CommitImportSessionRequest>,
) -> Result<Json<crate::domain::ImportSession>, ApiError> {
    Ok(Json(
        state
            .service
            .commit_import_session(
                request.session_id,
                request.selected_candidate_ids,
                request.import_mode,
                request.add_as_watch_folder,
            )
            .await?,
    ))
}

async fn get_import_session(
    State(state): State<AppState>,
    Path(session_id): Path<Uuid>,
) -> Result<Json<crate::domain::ImportSession>, ApiError> {
    Ok(Json(state.service.import_session(session_id).await?))
}

async fn list_import_sessions(
    State(state): State<AppState>,
) -> Result<Json<Vec<crate::domain::ImportSession>>, ApiError> {
    Ok(Json(state.service.import_sessions().await))
}

async fn import_asset(
    State(state): State<AppState>,
    Json(request): Json<crate::domain::ImportAssetRequest>,
) -> Result<Json<crate::domain::ImportAssetResponse>, ApiError> {
    Ok(Json(state.service.import_asset(request).await?))
}

async fn rebuild_metadata(
    State(state): State<AppState>,
    Json(_request): Json<RebuildRequest>,
) -> Result<Json<crate::domain::JobRecord>, ApiError> {
    Ok(Json(state.service.rebuild_metadata().await?))
}

async fn get_asset_metadata(
    State(state): State<AppState>,
    Path(asset_id): Path<Uuid>,
) -> Result<Json<crate::domain::AssetMetadata>, ApiError> {
    Ok(Json(state.service.asset_metadata(asset_id).await?))
}

async fn correct_asset_date(
    State(state): State<AppState>,
    Path(asset_id): Path<Uuid>,
    Json(request): Json<CorrectDateRequest>,
) -> Result<Json<crate::domain::AssetMetadata>, ApiError> {
    Ok(Json(
        state.service.correct_asset_date(asset_id, request).await?,
    ))
}

async fn timeline(
    State(state): State<AppState>,
    Query(query): Query<TimelineQuery>,
) -> Result<Json<crate::domain::TimelineResponse>, ApiError> {
    let cursor = query
        .cursor
        .as_deref()
        .and_then(|value| value.parse::<usize>().ok());
    Ok(Json(
        state
            .service
            .timeline_page_filtered(
                query.limit,
                query.per_bucket,
                cursor,
                query.include_archived.unwrap_or(false),
            )
            .await,
    ))
}

#[derive(Debug, Default, Deserialize)]
struct TimelineQuery {
    #[serde(default)]
    limit: Option<usize>,
    #[serde(default)]
    per_bucket: Option<usize>,
    #[serde(default)]
    cursor: Option<String>,
    #[serde(default)]
    include_archived: Option<bool>,
}

async fn update_asset_flags(
    State(state): State<AppState>,
    Path(asset_id): Path<Uuid>,
    Json(request): Json<UpdateAssetFlagsRequest>,
) -> Result<Json<crate::domain::Asset>, ApiError> {
    Ok(Json(
        state.service.update_asset_flags(asset_id, request).await?,
    ))
}

async fn asset_availability(
    State(state): State<AppState>,
    Path(asset_id): Path<Uuid>,
) -> Result<Json<crate::domain::AssetAvailability>, ApiError> {
    Ok(Json(state.service.asset_availability(asset_id).await?))
}

async fn asset_original(
    State(state): State<AppState>,
    Path(asset_id): Path<Uuid>,
) -> Result<Response, ApiError> {
    let (mime_type, bytes) = state.service.asset_original_bytes(asset_id).await?;
    let content_type = HeaderValue::from_str(&mime_type)
        .unwrap_or_else(|_| HeaderValue::from_static("application/octet-stream"));
    Ok(([(CONTENT_TYPE, content_type)], bytes).into_response())
}

async fn pin_local_asset(
    State(state): State<AppState>,
    Path(asset_id): Path<Uuid>,
) -> Result<Json<crate::domain::AssetAvailability>, ApiError> {
    Ok(Json(state.service.pin_local_asset(asset_id).await?))
}

async fn evict_local_asset(
    State(state): State<AppState>,
    Path(asset_id): Path<Uuid>,
) -> Result<Json<crate::domain::AssetAvailability>, ApiError> {
    Ok(Json(state.service.evict_local_asset(asset_id).await?))
}

async fn update_assets_flags(
    State(state): State<AppState>,
    Json(request): Json<UpdateAssetsFlagsRequest>,
) -> Result<Json<Vec<crate::domain::Asset>>, ApiError> {
    Ok(Json(state.service.update_assets_flags(request).await?))
}

async fn list_favorite_assets(
    State(state): State<AppState>,
) -> Result<Json<Vec<crate::domain::Asset>>, ApiError> {
    Ok(Json(state.service.favorite_assets().await))
}

async fn list_archived_assets(
    State(state): State<AppState>,
) -> Result<Json<Vec<crate::domain::Asset>>, ApiError> {
    Ok(Json(state.service.archived_assets().await))
}

async fn list_albums(
    State(state): State<AppState>,
) -> Result<Json<Vec<crate::domain::Album>>, ApiError> {
    Ok(Json(state.service.albums().await))
}

async fn get_album(
    State(state): State<AppState>,
    Path(album_id): Path<Uuid>,
) -> Result<Json<crate::domain::Album>, ApiError> {
    Ok(Json(state.service.album(album_id).await?))
}

async fn create_album(
    State(state): State<AppState>,
    Json(request): Json<CreateAlbumRequest>,
) -> Result<Json<crate::domain::Album>, ApiError> {
    Ok(Json(state.service.create_album(request).await?))
}

async fn rename_album(
    State(state): State<AppState>,
    Path(album_id): Path<Uuid>,
    Json(request): Json<RenameAlbumRequest>,
) -> Result<Json<crate::domain::Album>, ApiError> {
    Ok(Json(state.service.rename_album(album_id, request).await?))
}

async fn get_album_assets(
    State(state): State<AppState>,
    Path(album_id): Path<Uuid>,
) -> Result<Json<Vec<crate::domain::Asset>>, ApiError> {
    Ok(Json(state.service.album_assets(album_id).await?))
}

async fn add_album_assets(
    State(state): State<AppState>,
    Path(album_id): Path<Uuid>,
    Json(request): Json<UpdateAlbumAssetsRequest>,
) -> Result<Json<crate::domain::Album>, ApiError> {
    Ok(Json(
        state.service.add_album_assets(album_id, request).await?,
    ))
}

async fn remove_album_assets(
    State(state): State<AppState>,
    Path(album_id): Path<Uuid>,
    Json(request): Json<UpdateAlbumAssetsRequest>,
) -> Result<Json<crate::domain::Album>, ApiError> {
    Ok(Json(
        state.service.remove_album_assets(album_id, request).await?,
    ))
}

async fn delete_album(
    State(state): State<AppState>,
    Path(album_id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    state.service.delete_album(album_id).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn list_people(
    State(state): State<AppState>,
) -> Result<Json<Vec<crate::domain::PersonCluster>>, ApiError> {
    Ok(Json(state.service.people().await))
}

async fn get_person(
    State(state): State<AppState>,
    Path(person_id): Path<Uuid>,
) -> Result<Json<crate::domain::PersonCluster>, ApiError> {
    Ok(Json(state.service.person(person_id).await?))
}

async fn create_manual_person(
    State(state): State<AppState>,
    Json(request): Json<CreateManualPersonRequest>,
) -> Result<Json<crate::domain::PersonCluster>, ApiError> {
    Ok(Json(state.service.create_manual_person(request).await?))
}

async fn get_person_assets(
    State(state): State<AppState>,
    Path(person_id): Path<Uuid>,
) -> Result<Json<Vec<crate::domain::Asset>>, ApiError> {
    Ok(Json(state.service.person_assets(person_id).await?))
}

async fn index_people(
    State(state): State<AppState>,
    Json(_request): Json<RebuildRequest>,
) -> Result<Json<crate::domain::JobRecord>, ApiError> {
    Ok(Json(state.service.index_people().await?))
}

async fn reset_people(
    State(state): State<AppState>,
    Json(_request): Json<RebuildRequest>,
) -> Result<Json<crate::domain::JobRecord>, ApiError> {
    Ok(Json(state.service.reset_people().await?))
}

async fn rename_person(
    State(state): State<AppState>,
    Path(person_id): Path<Uuid>,
    Json(request): Json<RenamePersonRequest>,
) -> Result<Json<crate::domain::PersonCluster>, ApiError> {
    Ok(Json(state.service.rename_person(person_id, request).await?))
}

async fn add_person_assets(
    State(state): State<AppState>,
    Path(person_id): Path<Uuid>,
    Json(request): Json<UpdatePersonAssetsRequest>,
) -> Result<Json<crate::domain::PersonCluster>, ApiError> {
    Ok(Json(
        state.service.add_person_assets(person_id, request).await?,
    ))
}

async fn remove_person_assets(
    State(state): State<AppState>,
    Path(person_id): Path<Uuid>,
    Json(request): Json<UpdatePersonAssetsRequest>,
) -> Result<Json<crate::domain::PersonCluster>, ApiError> {
    Ok(Json(
        state
            .service
            .remove_person_assets(person_id, request)
            .await?,
    ))
}

async fn hide_person(
    State(state): State<AppState>,
    Path(person_id): Path<Uuid>,
    Json(request): Json<HidePersonRequest>,
) -> Result<Json<crate::domain::PersonCluster>, ApiError> {
    Ok(Json(state.service.hide_person(person_id, request).await?))
}

async fn reject_person_match(
    State(state): State<AppState>,
    Path(person_id): Path<Uuid>,
    Json(request): Json<RejectPersonMatchRequest>,
) -> Result<Json<crate::domain::PersonCluster>, ApiError> {
    Ok(Json(
        state
            .service
            .reject_person_match(person_id, request)
            .await?,
    ))
}

async fn merge_person(
    State(state): State<AppState>,
    Path(person_id): Path<Uuid>,
    Json(request): Json<MergePersonRequest>,
) -> Result<Json<crate::domain::PersonCluster>, ApiError> {
    Ok(Json(state.service.merge_person(person_id, request).await?))
}

async fn split_person(
    State(state): State<AppState>,
    Path(person_id): Path<Uuid>,
    Json(request): Json<SplitPersonRequest>,
) -> Result<Json<crate::domain::PersonCluster>, ApiError> {
    Ok(Json(state.service.split_person(person_id, request).await?))
}

async fn list_places(
    State(state): State<AppState>,
) -> Result<Json<Vec<crate::domain::PlaceCluster>>, ApiError> {
    Ok(Json(state.service.places().await))
}

async fn rebuild_places(
    State(state): State<AppState>,
    Json(_request): Json<RebuildRequest>,
) -> Result<Json<crate::domain::JobRecord>, ApiError> {
    Ok(Json(state.service.rebuild_places().await?))
}

async fn get_place_assets(
    State(state): State<AppState>,
    Path(place_id): Path<Uuid>,
) -> Result<Json<Vec<crate::domain::Asset>>, ApiError> {
    Ok(Json(state.service.place_assets(place_id).await?))
}

async fn correct_place(
    State(state): State<AppState>,
    Path(place_id): Path<Uuid>,
    Json(request): Json<CorrectPlaceRequest>,
) -> Result<Json<crate::domain::PlaceCluster>, ApiError> {
    Ok(Json(state.service.correct_place(place_id, request).await?))
}

async fn list_events(
    State(state): State<AppState>,
) -> Result<Json<Vec<crate::domain::EventCluster>>, ApiError> {
    Ok(Json(state.service.events().await))
}

async fn rebuild_events(
    State(state): State<AppState>,
    Json(_request): Json<RebuildRequest>,
) -> Result<Json<crate::domain::JobRecord>, ApiError> {
    Ok(Json(state.service.rebuild_events().await?))
}

async fn get_event_assets(
    State(state): State<AppState>,
    Path(event_id): Path<Uuid>,
) -> Result<Json<Vec<crate::domain::Asset>>, ApiError> {
    Ok(Json(state.service.event_assets(event_id).await?))
}

async fn title_event(
    State(state): State<AppState>,
    Path(event_id): Path<Uuid>,
    Json(request): Json<TitleEventRequest>,
) -> Result<Json<crate::domain::EventCluster>, ApiError> {
    Ok(Json(
        state.service.title_event(event_id, request.title).await?,
    ))
}

async fn record_feedback(
    State(state): State<AppState>,
    Json(feedback): Json<FeedbackEvent>,
) -> Result<Json<FeedbackEvent>, ApiError> {
    Ok(Json(state.service.record_feedback(feedback).await?))
}

async fn search(
    State(state): State<AppState>,
    Query(query): Query<SearchQuery>,
) -> Result<Json<crate::domain::SearchResponse>, ApiError> {
    Ok(Json(state.service.search(query).await))
}

async fn search_status(
    State(state): State<AppState>,
) -> Result<Json<crate::domain::SearchIndexStatus>, ApiError> {
    Ok(Json(state.service.search_status().await?))
}

async fn rebuild_search(
    State(state): State<AppState>,
    Json(_request): Json<RebuildRequest>,
) -> Result<Json<crate::domain::JobRecord>, ApiError> {
    Ok(Json(state.service.rebuild_search().await?))
}

async fn rebuild_ocr(
    State(state): State<AppState>,
    Json(request): Json<RebuildRequest>,
) -> Result<Json<crate::domain::JobRecord>, ApiError> {
    Ok(Json(state.service.rebuild_ocr(request).await?))
}

async fn get_asset_ocr_blocks(
    State(state): State<AppState>,
    Path(asset_id): Path<Uuid>,
) -> Result<Json<Vec<crate::domain::OcrBlock>>, ApiError> {
    Ok(Json(state.service.ocr_blocks_for_asset(asset_id).await?))
}

async fn rebuild_scenes(
    State(state): State<AppState>,
    Json(request): Json<RebuildRequest>,
) -> Result<Json<crate::domain::JobRecord>, ApiError> {
    Ok(Json(state.service.rebuild_scenes(request).await?))
}

async fn rebuild_semantic(
    State(state): State<AppState>,
    Json(_request): Json<RebuildRequest>,
) -> Result<Json<crate::domain::JobRecord>, ApiError> {
    Ok(Json(state.service.rebuild_semantic().await?))
}

async fn list_jobs(
    State(state): State<AppState>,
) -> Result<Json<Vec<crate::domain::JobRecord>>, ApiError> {
    Ok(Json(state.service.jobs().await))
}

async fn get_job(
    State(state): State<AppState>,
    Path(job_id): Path<Uuid>,
) -> Result<Json<crate::domain::JobRecord>, ApiError> {
    Ok(Json(state.service.job(job_id).await?))
}

async fn get_job_logs(
    State(state): State<AppState>,
    Path(job_id): Path<Uuid>,
) -> Result<Json<Vec<crate::domain::JobLog>>, ApiError> {
    Ok(Json(state.service.job_logs(job_id).await?))
}

async fn cancel_job(
    State(state): State<AppState>,
    Path(job_id): Path<Uuid>,
) -> Result<Json<crate::domain::JobRecord>, ApiError> {
    Ok(Json(state.service.cancel_job(job_id).await?))
}

async fn retry_job(
    State(state): State<AppState>,
    Path(job_id): Path<Uuid>,
) -> Result<Json<crate::domain::JobRecord>, ApiError> {
    Ok(Json(state.service.retry_job(job_id).await?))
}

async fn list_models(
    State(state): State<AppState>,
) -> Result<Json<Vec<crate::domain::ModelArtifact>>, ApiError> {
    Ok(Json(state.service.models().await?))
}

async fn model_runtime_status(
    State(state): State<AppState>,
) -> Result<Json<crate::domain::ModelRuntimeStatus>, ApiError> {
    Ok(Json(state.service.model_runtime_status().await))
}

async fn install_model(
    State(state): State<AppState>,
    Json(request): Json<ModelInstallRequest>,
) -> Result<Json<crate::domain::ModelArtifact>, ApiError> {
    Ok(Json(state.service.install_model(request).await?))
}

async fn import_local_model(
    State(state): State<AppState>,
    Json(request): Json<ModelImportRequest>,
) -> Result<Json<crate::domain::ModelArtifact>, ApiError> {
    Ok(Json(state.service.import_local_model(request).await?))
}

async fn verify_model(
    State(state): State<AppState>,
    Path(model_id): Path<String>,
) -> Result<Json<crate::domain::ModelArtifact>, ApiError> {
    Ok(Json(state.service.verify_model(&model_id).await?))
}

async fn privacy_status(
    State(state): State<AppState>,
) -> Result<Json<crate::domain::PrivacyStatus>, ApiError> {
    Ok(Json(state.service.privacy_status().await?))
}

async fn encryption_status(
    State(state): State<AppState>,
) -> Result<Json<crate::domain::EncryptionStatus>, ApiError> {
    Ok(Json(state.service.encryption_status().await))
}

async fn activate_encryption(
    State(state): State<AppState>,
    Json(request): Json<EncryptionActivationRequest>,
) -> Result<Json<crate::domain::EncryptionActivationResult>, ApiError> {
    Ok(Json(state.service.activate_encryption(request).await?))
}

async fn verify_backup(
    State(state): State<AppState>,
    Json(request): Json<BackupVerifyRequest>,
) -> Result<Json<crate::domain::BackupVerification>, ApiError> {
    Ok(Json(state.service.verify_backup(request).await?))
}

async fn export_backup(
    State(state): State<AppState>,
    Json(request): Json<BackupExportRequest>,
) -> Result<Json<crate::domain::BackupExportResult>, ApiError> {
    Ok(Json(state.service.export_backup(request).await?))
}

async fn verify_restore_backup(
    State(state): State<AppState>,
    Json(request): Json<BackupVerifyRequest>,
) -> Result<Json<crate::domain::BackupVerification>, ApiError> {
    Ok(Json(state.service.verify_backup(request).await?))
}

async fn plan_restore_backup(
    State(state): State<AppState>,
    Json(request): Json<BackupRestorePlanRequest>,
) -> Result<Json<crate::domain::BackupRestorePlan>, ApiError> {
    Ok(Json(state.service.plan_restore_backup(request).await?))
}

async fn run_restore_backup(
    State(state): State<AppState>,
    Json(request): Json<BackupRestoreRunRequest>,
) -> Result<Json<crate::domain::BackupRestoreRunResult>, ApiError> {
    Ok(Json(state.service.run_restore_backup(request).await?))
}

async fn diagnostics(State(state): State<AppState>) -> Result<Json<serde_json::Value>, ApiError> {
    Ok(Json(state.service.diagnostics().await))
}
