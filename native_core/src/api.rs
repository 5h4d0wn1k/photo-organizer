use std::{
    fs,
    net::SocketAddr,
    path::{Component, Path as FsPath, PathBuf},
    sync::Arc,
};

use axum::{
    Json, Router,
    body::{Body, Bytes},
    extract::{ConnectInfo, DefaultBodyLimit, Path, Query, Request, State},
    http::{
        HeaderMap, HeaderValue, Method, StatusCode,
        header::{
            ACCEPT_RANGES, AUTHORIZATION, CACHE_CONTROL, CONTENT_LENGTH, CONTENT_RANGE,
            CONTENT_TYPE, RANGE,
        },
    },
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{delete, get, patch, post, put},
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
        CreateAlbumRequest, CreateDeviceRequest, CreateFileFolderRequest,
        CreateManualPersonRequest, CreatePairingSessionRequest, CreateSmartFolderRequest,
        CreateVaultRequest, CreateWatchFolderRequest, EncryptionActivationRequest,
        EnrollDeviceRequest, FeedbackEvent, HidePersonRequest, MergePersonRequest,
        MobilePairRequest, MobileReplicaReportRequest, MobileStorageProfileUpdateRequest,
        MobileUploadRequest, ModelImportRequest, ModelInstallRequest, MoveFileEntryRequest,
        RebuildRequest, RejectPersonMatchRequest, RenameAlbumRequest, RenameFileEntryRequest,
        RenamePersonRequest, RevokeDeviceRequest, RunSyncRequest, ScanImportSourceRequest,
        SearchQuery, SplitPersonRequest, SupportBundleExportRequest, TitleEventRequest,
        UpdateAlbumAssetsRequest, UpdateAssetFlagsRequest, UpdateAssetTagsRequest,
        UpdateAssetsFlagsRequest, UpdateLibrarySettingsRequest, UpdatePersonAssetsRequest,
        UpdateVaultStoragePolicyRequest,
    },
    service::{ByteRangeRequest, GalleryService, ServiceError},
    vault_store,
};

const MOBILE_UPLOAD_BODY_LIMIT_BYTES: usize = 8 * 1024 * 1024;
const MOBILE_REPLICA_CHUNK_BODY_LIMIT_BYTES: usize = vault_store::CHUNK_BYTES + 1024 * 1024;

#[derive(Clone)]
pub struct AppState {
    pub service: Arc<GalleryService>,
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/local-web", get(local_web_index))
        .route("/local-web/", get(local_web_index))
        .route("/local-web/{*asset_path}", get(local_web_asset))
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
        .route("/mobile/pair", post(pair_mobile_device))
        .route("/mobile/session", get(mobile_session_status))
        .route("/mobile/session/refresh", post(refresh_mobile_session))
        .route(
            "/mobile/session/revoke",
            post(revoke_current_mobile_session),
        )
        .route("/mobile/sessions", get(list_mobile_sessions))
        .route(
            "/mobile/devices/{device_id}/sessions/revoke",
            post(revoke_mobile_device_sessions),
        )
        .route("/mobile/workspace", get(mobile_workspace))
        .route(
            "/mobile/storage-profile",
            post(update_mobile_storage_profile),
        )
        .route("/mobile/storage/plan", get(mobile_storage_plan))
        .route(
            "/mobile/storage/blobs/{blob_id}/chunks/{chunk_index}",
            get(mobile_replica_chunk)
                .put(restore_mobile_replica_chunk)
                .layer(DefaultBodyLimit::max(MOBILE_REPLICA_CHUNK_BODY_LIMIT_BYTES)),
        )
        .route(
            "/mobile/storage/blobs/{blob_id}/report",
            post(report_mobile_replica),
        )
        .route("/mobile/search", get(mobile_search))
        .route("/mobile/uploads", post(reserve_mobile_upload))
        .route(
            "/mobile/uploads/{upload_id}",
            get(mobile_upload_status)
                .put(receive_mobile_upload)
                .delete(cancel_mobile_upload),
        )
        .route(
            "/mobile/uploads/{upload_id}/chunks/{offset}",
            put(receive_mobile_upload_chunk),
        )
        .route(
            "/mobile/uploads/{upload_id}/complete",
            post(complete_mobile_upload),
        )
        .route("/mobile/assets", get(list_mobile_assets))
        .route(
            "/mobile/assets/{asset_id}/availability",
            get(mobile_asset_availability),
        )
        .route(
            "/mobile/assets/{asset_id}/flags",
            post(update_mobile_asset_flags),
        )
        .route(
            "/mobile/assets/{asset_id}/tags",
            post(update_mobile_asset_tags),
        )
        .route(
            "/mobile/assets/{asset_id}/preview",
            get(mobile_asset_preview),
        )
        .route(
            "/mobile/assets/{asset_id}/original",
            get(mobile_asset_original),
        )
        .route("/mobile/files/tree", get(mobile_file_tree))
        .route(
            "/mobile/files/{entry_id}/original",
            get(mobile_file_original),
        )
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
            "/sync/network/local-endpoint",
            get(sync_network_local_endpoint),
        )
        .route(
            "/sync/transfers/{transfer_id}/retry",
            post(retry_sync_transfer),
        )
        .route(
            "/sync/transfers/{transfer_id}/cancel",
            post(cancel_sync_transfer),
        )
        .route("/files/tree", get(file_tree))
        .route("/files/folders", post(create_file_folder))
        .route("/files/{entry_id}", patch(rename_file_entry))
        .route("/files/{entry_id}/move", post(move_file_entry))
        .route("/files/{entry_id}/trash", post(trash_file_entry))
        .route("/files/{entry_id}/restore", post(restore_file_entry))
        .route("/files/{entry_id}/original", get(file_original))
        .route("/assets/favorites", get(list_favorite_assets))
        .route("/assets/archived", get(list_archived_assets))
        .route("/assets/flags/bulk", post(update_assets_flags))
        .route("/assets/{asset_id}/flags", post(update_asset_flags))
        .route("/assets/{asset_id}/tags", post(update_asset_tags))
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
        .route(
            "/smart-folders",
            get(list_smart_folders).post(create_smart_folder),
        )
        .route("/smart-folders/{folder_id}", delete(delete_smart_folder))
        .route("/smart-folders/{folder_id}/search", get(run_smart_folder))
        .route("/imports/assets", post(import_asset))
        .route("/imports/scan", post(scan_import_source))
        .route("/imports/commit", post(commit_import_session))
        .route("/imports/sessions", get(list_import_sessions))
        .route("/imports/sessions/{session_id}", get(get_import_session))
        .route("/duplicates", get(duplicate_review_summary))
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
        .route("/audit/events", get(list_audit_events))
        .route(
            "/entitlements/status",
            get(entitlement_status).post(update_entitlement_cache),
        )
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
        .route("/support/bundle", post(export_support_bundle))
        .route("/models", get(list_models))
        .route("/models/runtime-status", get(model_runtime_status))
        .route("/models/install", post(install_model))
        .route("/models/import-local", post(import_local_model))
        .route("/models/{model_id}/verify", post(verify_model))
        .route("/release/readiness", get(platform_release_readiness))
        .route("/diagnostics", get(diagnostics))
        .with_state(state)
        .layer(DefaultBodyLimit::max(MOBILE_UPLOAD_BODY_LIMIT_BYTES))
        .layer(middleware::from_fn(enforce_private_api_boundary))
        .layer(private_cors_layer())
        .layer(TraceLayer::new_for_http())
}

fn private_cors_layer() -> CorsLayer {
    CorsLayer::new()
        .allow_origin([
            HeaderValue::from_static("http://127.0.0.1:4821"),
            HeaderValue::from_static("http://localhost:4821"),
        ])
        .allow_methods([
            Method::GET,
            Method::POST,
            Method::PUT,
            Method::PATCH,
            Method::DELETE,
        ])
        .allow_headers([CONTENT_TYPE, AUTHORIZATION])
}

async fn enforce_private_api_boundary(request: Request, next: Next) -> Response {
    let path = request.uri().path().to_string();
    let remote = request
        .extensions()
        .get::<ConnectInfo<SocketAddr>>()
        .map(|info| info.0);
    if is_desktop_api_client(remote, request.headers()) || is_public_remote_route(&path) {
        return next.run(request).await;
    }

    (
        StatusCode::FORBIDDEN,
        Json(json!({
            "error": "desktop API routes are only available to loopback clients; remote clients may use /mobile/* after pairing"
        })),
    )
        .into_response()
}

fn is_public_remote_route(path: &str) -> bool {
    path == "/health"
        || path.starts_with("/mobile/")
        || path == "/local-web"
        || path.starts_with("/local-web/")
}

fn is_desktop_api_client(remote: Option<SocketAddr>, headers: &HeaderMap) -> bool {
    if has_tailscale_serve_identity(headers) {
        return false;
    }
    remote
        .map(|address| address.ip().is_loopback())
        .unwrap_or(true)
}

fn has_tailscale_serve_identity(headers: &HeaderMap) -> bool {
    [
        "tailscale-user-login",
        "tailscale-user-name",
        "tailscale-user-profile-pic",
        "tailscale-app-capabilities",
    ]
    .iter()
    .any(|name| headers.contains_key(*name))
}

#[derive(Debug, Error)]
enum ApiError {
    #[error("{0}")]
    Service(#[from] ServiceError),
    #[error("{1}")]
    Http(StatusCode, String),
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
            Self::Http(status, message) => (status, message),
        };

        (status, Json(json!({ "error": message }))).into_response()
    }
}

fn mobile_bearer_token(headers: &HeaderMap) -> Result<String, ApiError> {
    let value = headers
        .get(AUTHORIZATION)
        .ok_or_else(|| ServiceError::Invalid("authorization header is required".to_string()))?;
    let raw = value
        .to_str()
        .map_err(|_| ServiceError::Invalid("authorization header is not valid UTF-8".to_string()))?
        .trim();
    let (scheme, token) = raw.split_once(' ').ok_or_else(|| {
        ServiceError::Invalid("authorization header must use Bearer token".to_string())
    })?;
    if !scheme.eq_ignore_ascii_case("bearer") || token.trim().is_empty() {
        return Err(ServiceError::Invalid(
            "authorization header must use Bearer token".to_string(),
        )
        .into());
    }
    Ok(token.trim().to_string())
}

fn parse_single_byte_range(headers: &HeaderMap) -> Result<Option<ByteRangeRequest>, ApiError> {
    let Some(value) = headers.get(RANGE) else {
        return Ok(None);
    };
    let raw = value.to_str().map_err(|_| {
        ApiError::Http(
            StatusCode::RANGE_NOT_SATISFIABLE,
            "range header is not valid UTF-8".to_string(),
        )
    })?;
    let Some(spec) = raw.trim().strip_prefix("bytes=") else {
        return Err(ApiError::Http(
            StatusCode::RANGE_NOT_SATISFIABLE,
            "only bytes ranges are supported".to_string(),
        ));
    };
    if spec.contains(',') {
        return Err(ApiError::Http(
            StatusCode::RANGE_NOT_SATISFIABLE,
            "multipart byte ranges are not supported".to_string(),
        ));
    }
    let (start, end) = spec.split_once('-').ok_or_else(|| {
        ApiError::Http(
            StatusCode::RANGE_NOT_SATISFIABLE,
            "range header must use bytes=start-end".to_string(),
        )
    })?;
    if start.is_empty() {
        let length = end.parse::<u64>().map_err(|_| {
            ApiError::Http(
                StatusCode::RANGE_NOT_SATISFIABLE,
                "suffix byte range length must be numeric".to_string(),
            )
        })?;
        return Ok(Some(ByteRangeRequest::Suffix { length }));
    }
    let start = start.parse::<u64>().map_err(|_| {
        ApiError::Http(
            StatusCode::RANGE_NOT_SATISFIABLE,
            "range start must be numeric".to_string(),
        )
    })?;
    let end = if end.is_empty() {
        None
    } else {
        Some(end.parse::<u64>().map_err(|_| {
            ApiError::Http(
                StatusCode::RANGE_NOT_SATISFIABLE,
                "range end must be numeric".to_string(),
            )
        })?)
    };
    Ok(Some(ByteRangeRequest::Start { start, end }))
}

fn range_service_error(error: ServiceError) -> ApiError {
    match error {
        ServiceError::Invalid(message) => {
            ApiError::Http(StatusCode::RANGE_NOT_SATISFIABLE, message)
        }
        other => ApiError::Service(other),
    }
}

fn response_with_body(
    status: StatusCode,
    content_type: HeaderValue,
    content_range: Option<String>,
    content_length: Option<u64>,
    bytes: Vec<u8>,
) -> Result<Response, ApiError> {
    let mut builder = Response::builder()
        .status(status)
        .header(CONTENT_TYPE, content_type)
        .header(ACCEPT_RANGES, HeaderValue::from_static("bytes"));
    if let Some(content_range) = content_range {
        builder = builder.header(
            CONTENT_RANGE,
            HeaderValue::from_str(&content_range).map_err(|_| {
                ServiceError::Invalid("content range could not be encoded".to_string())
            })?,
        );
    }
    if let Some(content_length) = content_length {
        builder = builder.header(
            CONTENT_LENGTH,
            HeaderValue::from_str(&content_length.to_string()).map_err(|_| {
                ServiceError::Invalid("content length could not be encoded".to_string())
            })?,
        );
    }
    builder
        .body(Body::from(bytes))
        .map_err(|err| ServiceError::Invalid(err.to_string()).into())
}

async fn health() -> Json<serde_json::Value> {
    Json(json!({ "status": "ok" }))
}

async fn local_web_index(State(state): State<AppState>) -> Result<Response, ApiError> {
    serve_local_web_asset(&state, "").await
}

async fn local_web_asset(
    State(state): State<AppState>,
    Path(asset_path): Path<String>,
) -> Result<Response, ApiError> {
    serve_local_web_asset(&state, &asset_path).await
}

async fn serve_local_web_asset(state: &AppState, asset_path: &str) -> Result<Response, ApiError> {
    let root = state
        .service
        .config()
        .local_web_root
        .as_deref()
        .ok_or_else(|| {
            ApiError::Http(
                StatusCode::NOT_FOUND,
                "local web UI is not configured".to_string(),
            )
        })?;
    let file_path = local_web_file_path(root, asset_path)?;
    let bytes = fs::read(&file_path).map_err(|err| {
        if err.kind() == std::io::ErrorKind::NotFound {
            ApiError::Http(
                StatusCode::NOT_FOUND,
                "local web UI asset was not found".to_string(),
            )
        } else {
            ServiceError::Io(err.to_string()).into()
        }
    })?;
    Response::builder()
        .status(StatusCode::OK)
        .header(CONTENT_TYPE, local_web_content_type(&file_path))
        .header(CACHE_CONTROL, HeaderValue::from_static("no-store"))
        .body(Body::from(bytes))
        .map_err(|err| ServiceError::Invalid(err.to_string()).into())
}

fn local_web_file_path(root: &FsPath, asset_path: &str) -> Result<PathBuf, ApiError> {
    let relative = local_web_relative_path(asset_path).ok_or_else(|| {
        ApiError::Http(
            StatusCode::NOT_FOUND,
            "local web UI asset path is not allowed".to_string(),
        )
    })?;
    let candidate = root.join(&relative);
    if candidate.is_file() {
        return Ok(candidate);
    }
    let index = root.join("index.html");
    if index.is_file() {
        return Ok(index);
    }
    Err(ApiError::Http(
        StatusCode::NOT_FOUND,
        "local web UI index.html was not found".to_string(),
    ))
}

fn local_web_relative_path(asset_path: &str) -> Option<PathBuf> {
    let requested = asset_path.trim_start_matches('/');
    let requested = if requested.is_empty() {
        "index.html"
    } else {
        requested
    };
    let mut relative = PathBuf::new();
    for component in FsPath::new(requested).components() {
        match component {
            Component::Normal(part) => relative.push(part),
            Component::CurDir => {}
            Component::Prefix(_) | Component::RootDir | Component::ParentDir => return None,
        }
    }
    if relative.as_os_str().is_empty() {
        relative.push("index.html");
    }
    Some(relative)
}

fn local_web_content_type(path: &FsPath) -> HeaderValue {
    match path.extension().and_then(|value| value.to_str()) {
        Some("css") => HeaderValue::from_static("text/css; charset=utf-8"),
        Some("html") => HeaderValue::from_static("text/html; charset=utf-8"),
        Some("ico") => HeaderValue::from_static("image/x-icon"),
        Some("js") | Some("mjs") => {
            HeaderValue::from_static("application/javascript; charset=utf-8")
        }
        Some("json") | Some("webmanifest") => {
            HeaderValue::from_static("application/json; charset=utf-8")
        }
        Some("png") => HeaderValue::from_static("image/png"),
        Some("svg") => HeaderValue::from_static("image/svg+xml"),
        Some("wasm") => HeaderValue::from_static("application/wasm"),
        _ => HeaderValue::from_static("application/octet-stream"),
    }
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

async fn pair_mobile_device(
    State(state): State<AppState>,
    Json(request): Json<MobilePairRequest>,
) -> Result<Json<crate::domain::MobilePairResponse>, ApiError> {
    Ok(Json(state.service.pair_mobile_device(request).await?))
}

async fn mobile_session_status(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<crate::domain::MobileSession>, ApiError> {
    let token = mobile_bearer_token(&headers)?;
    Ok(Json(state.service.mobile_session_status(&token).await?))
}

async fn refresh_mobile_session(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<crate::domain::MobileSessionRefreshResponse>, ApiError> {
    let token = mobile_bearer_token(&headers)?;
    Ok(Json(state.service.refresh_mobile_session(&token).await?))
}

async fn list_mobile_sessions(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Vec<crate::domain::MobileSession>>, ApiError> {
    let token = mobile_bearer_token(&headers)?;
    Ok(Json(state.service.mobile_sessions(&token).await?))
}

async fn revoke_current_mobile_session(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<crate::domain::MobileSession>, ApiError> {
    let token = mobile_bearer_token(&headers)?;
    Ok(Json(
        state.service.revoke_current_mobile_session(&token).await?,
    ))
}

async fn revoke_mobile_device_sessions(
    State(state): State<AppState>,
    Path(device_id): Path<Uuid>,
    headers: HeaderMap,
) -> Result<Json<Vec<crate::domain::MobileSession>>, ApiError> {
    let token = mobile_bearer_token(&headers)?;
    Ok(Json(
        state
            .service
            .revoke_mobile_device_sessions(&token, device_id)
            .await?,
    ))
}

async fn mobile_workspace(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<crate::domain::MobileWorkspaceResponse>, ApiError> {
    let token = mobile_bearer_token(&headers)?;
    Ok(Json(state.service.mobile_workspace(&token).await?))
}

async fn update_mobile_storage_profile(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<MobileStorageProfileUpdateRequest>,
) -> Result<Json<crate::domain::DeviceIdentity>, ApiError> {
    let token = mobile_bearer_token(&headers)?;
    Ok(Json(
        state
            .service
            .update_mobile_storage_profile(&token, request)
            .await?,
    ))
}

async fn mobile_storage_plan(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<crate::domain::MobileStoragePlan>, ApiError> {
    let token = mobile_bearer_token(&headers)?;
    Ok(Json(state.service.mobile_storage_plan(&token).await?))
}

async fn mobile_replica_chunk(
    State(state): State<AppState>,
    Path((blob_id, chunk_index)): Path<(Uuid, u32)>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let token = mobile_bearer_token(&headers)?;
    let bytes = state
        .service
        .mobile_replica_chunk_bytes(&token, blob_id, chunk_index)
        .await?;
    response_with_body(
        StatusCode::OK,
        HeaderValue::from_static("application/octet-stream"),
        None,
        Some(bytes.len() as u64),
        bytes,
    )
}

async fn report_mobile_replica(
    State(state): State<AppState>,
    Path(blob_id): Path<Uuid>,
    headers: HeaderMap,
    Json(request): Json<MobileReplicaReportRequest>,
) -> Result<Json<crate::domain::MobileReplicaReport>, ApiError> {
    let token = mobile_bearer_token(&headers)?;
    Ok(Json(
        state
            .service
            .report_mobile_replica(&token, blob_id, request)
            .await?,
    ))
}

async fn restore_mobile_replica_chunk(
    State(state): State<AppState>,
    Path((blob_id, chunk_index)): Path<(Uuid, u32)>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<crate::domain::MobileReplicaRestoreResult>, ApiError> {
    let token = mobile_bearer_token(&headers)?;
    Ok(Json(
        state
            .service
            .restore_mobile_replica_chunk(&token, blob_id, chunk_index, body.to_vec())
            .await?,
    ))
}

async fn mobile_search(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<SearchQuery>,
) -> Result<Json<crate::domain::SearchResponse>, ApiError> {
    let token = mobile_bearer_token(&headers)?;
    Ok(Json(state.service.mobile_search(&token, query).await?))
}

async fn reserve_mobile_upload(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<MobileUploadRequest>,
) -> Result<Json<crate::domain::MobileUpload>, ApiError> {
    let token = mobile_bearer_token(&headers)?;
    Ok(Json(
        state.service.reserve_mobile_upload(&token, request).await?,
    ))
}

async fn receive_mobile_upload(
    State(state): State<AppState>,
    Path(upload_id): Path<Uuid>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<crate::domain::MobileUpload>, ApiError> {
    let token = mobile_bearer_token(&headers)?;
    Ok(Json(
        state
            .service
            .receive_mobile_upload(&token, upload_id, body.to_vec())
            .await?,
    ))
}

async fn mobile_upload_status(
    State(state): State<AppState>,
    Path(upload_id): Path<Uuid>,
    headers: HeaderMap,
) -> Result<Json<crate::domain::MobileUpload>, ApiError> {
    let token = mobile_bearer_token(&headers)?;
    Ok(Json(
        state
            .service
            .mobile_upload_status(&token, upload_id)
            .await?,
    ))
}

async fn cancel_mobile_upload(
    State(state): State<AppState>,
    Path(upload_id): Path<Uuid>,
    headers: HeaderMap,
) -> Result<Json<crate::domain::MobileUpload>, ApiError> {
    let token = mobile_bearer_token(&headers)?;
    Ok(Json(
        state
            .service
            .cancel_mobile_upload(&token, upload_id)
            .await?,
    ))
}

async fn receive_mobile_upload_chunk(
    State(state): State<AppState>,
    Path((upload_id, offset)): Path<(Uuid, u64)>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<crate::domain::MobileUpload>, ApiError> {
    let token = mobile_bearer_token(&headers)?;
    Ok(Json(
        state
            .service
            .receive_mobile_upload_chunk(&token, upload_id, offset, body.to_vec())
            .await?,
    ))
}

async fn complete_mobile_upload(
    State(state): State<AppState>,
    Path(upload_id): Path<Uuid>,
    headers: HeaderMap,
) -> Result<Json<crate::domain::MobileUpload>, ApiError> {
    let token = mobile_bearer_token(&headers)?;
    Ok(Json(
        state
            .service
            .complete_mobile_upload(&token, upload_id)
            .await?,
    ))
}

async fn list_mobile_assets(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Vec<crate::domain::MobileAssetSummary>>, ApiError> {
    let token = mobile_bearer_token(&headers)?;
    Ok(Json(state.service.mobile_assets(&token).await?))
}

async fn mobile_asset_availability(
    State(state): State<AppState>,
    Path(asset_id): Path<Uuid>,
    headers: HeaderMap,
) -> Result<Json<crate::domain::AssetAvailability>, ApiError> {
    let token = mobile_bearer_token(&headers)?;
    Ok(Json(
        state
            .service
            .mobile_asset_availability(&token, asset_id)
            .await?,
    ))
}

async fn update_mobile_asset_flags(
    State(state): State<AppState>,
    Path(asset_id): Path<Uuid>,
    headers: HeaderMap,
    Json(request): Json<UpdateAssetFlagsRequest>,
) -> Result<Json<crate::domain::Asset>, ApiError> {
    let token = mobile_bearer_token(&headers)?;
    Ok(Json(
        state
            .service
            .update_mobile_asset_flags(&token, asset_id, request)
            .await?,
    ))
}

async fn update_mobile_asset_tags(
    State(state): State<AppState>,
    Path(asset_id): Path<Uuid>,
    headers: HeaderMap,
    Json(request): Json<UpdateAssetTagsRequest>,
) -> Result<Json<crate::domain::Asset>, ApiError> {
    let token = mobile_bearer_token(&headers)?;
    Ok(Json(
        state
            .service
            .update_mobile_asset_tags(&token, asset_id, request)
            .await?,
    ))
}

async fn mobile_asset_original(
    State(state): State<AppState>,
    Path(asset_id): Path<Uuid>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let token = mobile_bearer_token(&headers)?;
    if let Some(range) = parse_single_byte_range(&headers)? {
        let ranged = state
            .service
            .mobile_original_range_bytes(&token, asset_id, range)
            .await
            .map_err(range_service_error)?;
        let content_type = HeaderValue::from_str(&ranged.mime_type)
            .unwrap_or_else(|_| HeaderValue::from_static("application/octet-stream"));
        return response_with_body(
            StatusCode::PARTIAL_CONTENT,
            content_type,
            Some(format!(
                "bytes {}-{}/{}",
                ranged.start, ranged.end, ranged.total_bytes
            )),
            Some(ranged.bytes.len() as u64),
            ranged.bytes,
        );
    }
    let (mime_type, bytes) = state
        .service
        .mobile_original_bytes(&token, asset_id)
        .await?;
    let content_type = HeaderValue::from_str(&mime_type)
        .unwrap_or_else(|_| HeaderValue::from_static("application/octet-stream"));
    response_with_body(
        StatusCode::OK,
        content_type,
        None,
        Some(bytes.len() as u64),
        bytes,
    )
}

async fn mobile_asset_preview(
    State(state): State<AppState>,
    Path(asset_id): Path<Uuid>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let token = mobile_bearer_token(&headers)?;
    let (mime_type, bytes) = state.service.mobile_preview_bytes(&token, asset_id).await?;
    let content_type = HeaderValue::from_str(&mime_type)
        .unwrap_or_else(|_| HeaderValue::from_static("application/octet-stream"));
    Ok(([(CONTENT_TYPE, content_type)], bytes).into_response())
}

#[derive(Debug, Default, Deserialize)]
struct FileTreeQuery {
    #[serde(default)]
    vault_id: Option<Uuid>,
    #[serde(default)]
    include_trashed: Option<bool>,
}

async fn mobile_file_tree(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<FileTreeQuery>,
) -> Result<Json<crate::domain::VaultFileTreeResponse>, ApiError> {
    let token = mobile_bearer_token(&headers)?;
    Ok(Json(
        state
            .service
            .mobile_file_tree(&token, query.include_trashed.unwrap_or(false))
            .await?,
    ))
}

async fn mobile_file_original(
    State(state): State<AppState>,
    Path(entry_id): Path<Uuid>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let token = mobile_bearer_token(&headers)?;
    if let Some(range) = parse_single_byte_range(&headers)? {
        let ranged = state
            .service
            .mobile_file_original_range_bytes(&token, entry_id, range)
            .await
            .map_err(range_service_error)?;
        let content_type = HeaderValue::from_str(&ranged.mime_type)
            .unwrap_or_else(|_| HeaderValue::from_static("application/octet-stream"));
        return response_with_body(
            StatusCode::PARTIAL_CONTENT,
            content_type,
            Some(format!(
                "bytes {}-{}/{}",
                ranged.start, ranged.end, ranged.total_bytes
            )),
            Some(ranged.bytes.len() as u64),
            ranged.bytes,
        );
    }
    let (mime_type, bytes) = state
        .service
        .mobile_file_original_bytes(&token, entry_id)
        .await?;
    let content_type = HeaderValue::from_str(&mime_type)
        .unwrap_or_else(|_| HeaderValue::from_static("application/octet-stream"));
    response_with_body(
        StatusCode::OK,
        content_type,
        None,
        Some(bytes.len() as u64),
        bytes,
    )
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

async fn sync_network_local_endpoint(
    State(state): State<AppState>,
) -> Result<Json<crate::domain::LocalEndpointPayload>, ApiError> {
    Ok(Json(state.service.sync_network_local_endpoint().await?))
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

async fn file_tree(
    State(state): State<AppState>,
    Query(query): Query<FileTreeQuery>,
) -> Result<Json<crate::domain::VaultFileTreeResponse>, ApiError> {
    Ok(Json(
        state
            .service
            .file_tree(query.vault_id, query.include_trashed.unwrap_or(false))
            .await?,
    ))
}

async fn create_file_folder(
    State(state): State<AppState>,
    Json(request): Json<CreateFileFolderRequest>,
) -> Result<Json<crate::domain::VaultFileEntry>, ApiError> {
    Ok(Json(state.service.create_file_folder(request).await?))
}

async fn rename_file_entry(
    State(state): State<AppState>,
    Path(entry_id): Path<Uuid>,
    Json(request): Json<RenameFileEntryRequest>,
) -> Result<Json<crate::domain::VaultFileEntry>, ApiError> {
    Ok(Json(
        state.service.rename_file_entry(entry_id, request).await?,
    ))
}

async fn move_file_entry(
    State(state): State<AppState>,
    Path(entry_id): Path<Uuid>,
    Json(request): Json<MoveFileEntryRequest>,
) -> Result<Json<crate::domain::VaultFileEntry>, ApiError> {
    Ok(Json(
        state.service.move_file_entry(entry_id, request).await?,
    ))
}

async fn trash_file_entry(
    State(state): State<AppState>,
    Path(entry_id): Path<Uuid>,
) -> Result<Json<crate::domain::VaultFileEntry>, ApiError> {
    Ok(Json(state.service.trash_file_entry(entry_id).await?))
}

async fn restore_file_entry(
    State(state): State<AppState>,
    Path(entry_id): Path<Uuid>,
) -> Result<Json<crate::domain::VaultFileEntry>, ApiError> {
    Ok(Json(state.service.restore_file_entry(entry_id).await?))
}

async fn file_original(
    State(state): State<AppState>,
    Path(entry_id): Path<Uuid>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    if let Some(range) = parse_single_byte_range(&headers)? {
        let ranged = state
            .service
            .file_original_range_bytes(entry_id, range)
            .await
            .map_err(range_service_error)?;
        let content_type = HeaderValue::from_str(&ranged.mime_type)
            .unwrap_or_else(|_| HeaderValue::from_static("application/octet-stream"));
        return response_with_body(
            StatusCode::PARTIAL_CONTENT,
            content_type,
            Some(format!(
                "bytes {}-{}/{}",
                ranged.start, ranged.end, ranged.total_bytes
            )),
            Some(ranged.bytes.len() as u64),
            ranged.bytes,
        );
    }
    let (mime_type, bytes) = state.service.file_original_bytes(entry_id).await?;
    let content_type = HeaderValue::from_str(&mime_type)
        .unwrap_or_else(|_| HeaderValue::from_static("application/octet-stream"));
    response_with_body(
        StatusCode::OK,
        content_type,
        None,
        Some(bytes.len() as u64),
        bytes,
    )
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

async fn duplicate_review_summary(
    State(state): State<AppState>,
) -> Result<Json<crate::domain::DuplicateReviewSummary>, ApiError> {
    Ok(Json(state.service.duplicate_review_summary().await))
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

async fn update_asset_tags(
    State(state): State<AppState>,
    Path(asset_id): Path<Uuid>,
    Json(request): Json<UpdateAssetTagsRequest>,
) -> Result<Json<crate::domain::Asset>, ApiError> {
    Ok(Json(
        state.service.update_asset_tags(asset_id, request).await?,
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
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    if let Some(range) = parse_single_byte_range(&headers)? {
        let ranged = state
            .service
            .asset_original_range_bytes(asset_id, range)
            .await
            .map_err(range_service_error)?;
        let content_type = HeaderValue::from_str(&ranged.mime_type)
            .unwrap_or_else(|_| HeaderValue::from_static("application/octet-stream"));
        return response_with_body(
            StatusCode::PARTIAL_CONTENT,
            content_type,
            Some(format!(
                "bytes {}-{}/{}",
                ranged.start, ranged.end, ranged.total_bytes
            )),
            Some(ranged.bytes.len() as u64),
            ranged.bytes,
        );
    }
    let (mime_type, bytes) = state.service.asset_original_bytes(asset_id).await?;
    let content_type = HeaderValue::from_str(&mime_type)
        .unwrap_or_else(|_| HeaderValue::from_static("application/octet-stream"));
    response_with_body(
        StatusCode::OK,
        content_type,
        None,
        Some(bytes.len() as u64),
        bytes,
    )
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

async fn list_smart_folders(
    State(state): State<AppState>,
) -> Result<Json<Vec<crate::domain::SmartFolder>>, ApiError> {
    Ok(Json(state.service.smart_folders().await))
}

async fn create_smart_folder(
    State(state): State<AppState>,
    Json(request): Json<CreateSmartFolderRequest>,
) -> Result<Json<crate::domain::SmartFolder>, ApiError> {
    Ok(Json(state.service.create_smart_folder(request).await?))
}

async fn run_smart_folder(
    State(state): State<AppState>,
    Path(folder_id): Path<Uuid>,
) -> Result<Json<crate::domain::SearchResponse>, ApiError> {
    Ok(Json(state.service.run_smart_folder(folder_id).await?))
}

async fn delete_smart_folder(
    State(state): State<AppState>,
    Path(folder_id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    state.service.delete_smart_folder(folder_id).await?;
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

#[derive(Debug, Default, Deserialize)]
struct AuditEventsQuery {
    #[serde(default)]
    limit: Option<usize>,
}

async fn list_audit_events(
    State(state): State<AppState>,
    Query(query): Query<AuditEventsQuery>,
) -> Result<Json<Vec<crate::domain::AuditEvent>>, ApiError> {
    Ok(Json(state.service.audit_events(query.limit).await))
}

async fn entitlement_status(
    State(state): State<AppState>,
) -> Result<Json<crate::domain::EntitlementStatusResponse>, ApiError> {
    Ok(Json(state.service.entitlement_status().await))
}

async fn update_entitlement_cache(
    State(state): State<AppState>,
    Json(request): Json<crate::domain::UpdateEntitlementCacheRequest>,
) -> Result<Json<crate::domain::EntitlementStatusResponse>, ApiError> {
    Ok(Json(state.service.update_entitlement_cache(request).await?))
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

async fn platform_release_readiness(
    State(state): State<AppState>,
) -> Result<Json<crate::domain::PlatformReleaseReadinessResponse>, ApiError> {
    Ok(Json(state.service.platform_release_readiness().await))
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

async fn export_support_bundle(
    State(state): State<AppState>,
    Json(request): Json<SupportBundleExportRequest>,
) -> Result<Json<crate::domain::SupportBundleExportResult>, ApiError> {
    Ok(Json(state.service.export_support_bundle(request).await?))
}

async fn diagnostics(State(state): State<AppState>) -> Result<Json<serde_json::Value>, ApiError> {
    Ok(Json(state.service.diagnostics().await))
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        net::{IpAddr, Ipv4Addr, SocketAddr},
    };

    use axum::http::{HeaderMap, HeaderValue};
    use chrono::Utc;

    use super::{
        is_desktop_api_client, is_public_remote_route, local_web_file_path, local_web_relative_path,
    };

    #[test]
    fn loopback_without_tailnet_headers_is_desktop_api_client() {
        let headers = HeaderMap::new();
        let remote = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 4821);

        assert!(is_desktop_api_client(Some(remote), &headers));
    }

    #[test]
    fn non_loopback_without_tailnet_headers_is_not_desktop_api_client() {
        let headers = HeaderMap::new();
        let remote = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 20)), 4821);

        assert!(!is_desktop_api_client(Some(remote), &headers));
    }

    #[test]
    fn tailscale_serve_identity_header_limits_loopback_proxy_to_mobile_api() {
        let mut headers = HeaderMap::new();
        headers.insert(
            "tailscale-user-login",
            HeaderValue::from_str("abcmkc153@gmail.com").expect("header"),
        );
        let remote = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 4821);

        assert!(!is_desktop_api_client(Some(remote), &headers));
    }

    #[test]
    fn local_web_is_a_public_static_route_without_opening_desktop_routes() {
        assert!(is_public_remote_route("/health"));
        assert!(is_public_remote_route("/mobile/workspace"));
        assert!(is_public_remote_route("/local-web"));
        assert!(is_public_remote_route("/local-web/main.dart.js"));
        assert!(!is_public_remote_route("/library/status"));
        assert!(!is_public_remote_route("/assets/asset-1/original"));
    }

    #[test]
    fn local_web_paths_reject_traversal_and_absolute_paths() {
        assert_eq!(
            local_web_relative_path("").expect("index"),
            std::path::PathBuf::from("index.html")
        );
        assert_eq!(
            local_web_relative_path("assets/app.js").expect("asset"),
            std::path::PathBuf::from("assets/app.js")
        );
        assert!(local_web_relative_path("../private.db").is_none());
        assert!(local_web_relative_path("/../private.db").is_none());
        assert!(local_web_relative_path("/tmp/private.db").is_some());
    }

    #[test]
    fn local_web_file_path_serves_assets_with_index_fallback() {
        let root = std::env::temp_dir().join(format!(
            "private-gallery-local-web-{}",
            Utc::now().timestamp_nanos_opt().unwrap_or_default()
        ));
        fs::create_dir_all(root.join("assets")).expect("create local web root");
        fs::write(root.join("index.html"), b"index").expect("write index");
        fs::write(root.join("assets/app.js"), b"app").expect("write asset");

        assert_eq!(
            local_web_file_path(&root, "assets/app.js").expect("asset"),
            root.join("assets/app.js")
        );
        assert_eq!(
            local_web_file_path(&root, "deep/client/route").expect("fallback"),
            root.join("index.html")
        );
        assert!(local_web_file_path(&root, "../runtime/gallery.sqlite3").is_err());

        fs::remove_dir_all(root).expect("remove local web root");
    }
}
