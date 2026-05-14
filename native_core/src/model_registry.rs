use std::{
    collections::HashMap,
    fs,
    io::Write,
    path::{Path, PathBuf},
};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::{
    config::AppConfig,
    domain::{
        EncryptionStatus, ModelArtifact, ModelImportRequest, ModelInstallAuditRecord,
        ModelInstallRequest, ModelInstallStatus, ModelTask, NetworkPolicy, PrivacyStatus,
    },
    imports, security,
};
use uuid::Uuid;

#[derive(Debug, Error)]
pub enum ModelRegistryError {
    #[error("invalid model registry request: {0}")]
    Invalid(String),
    #[error("model registry filesystem operation failed: {0}")]
    Io(String),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct InstalledModelRecord {
    id: String,
    installed_path: String,
    sha256: String,
    installed_at: DateTime<Utc>,
}

pub fn privacy_status(config: &AppConfig) -> Result<PrivacyStatus, ModelRegistryError> {
    Ok(PrivacyStatus {
        network_policy: config.network_policy,
        daemon_bind_address: config.bind_address(),
        loopback_only: is_loopback_host(&config.bind_host),
        developer_mode: config.developer_mode,
        photo_processing_network_allowed: false,
        model_download_requires_confirmation: true,
        telemetry_enabled: false,
        analytics_enabled: false,
        cloud_ai_enabled: false,
        installed_models: list_models(config)?
            .into_iter()
            .filter(|model| model.install_status == ModelInstallStatus::Installed)
            .collect(),
        local_only_disclosure:
            "Photos, metadata, face templates, OCR text, embeddings, and search queries stay on this machine."
                .to_string(),
        encryption: encryption_status(config),
    })
}

pub fn encryption_status(config: &AppConfig) -> EncryptionStatus {
    security::encryption_status(config)
}

pub fn list_models(config: &AppConfig) -> Result<Vec<ModelArtifact>, ModelRegistryError> {
    let installed = load_installed_models(config)?;
    let installed_by_id = installed
        .into_iter()
        .map(|record| (record.id.clone(), record))
        .collect::<HashMap<_, _>>();

    Ok(candidate_models()
        .into_iter()
        .map(|mut artifact| {
            if let Some(record) = installed_by_id.get(&artifact.id) {
                artifact.installed_path = Some(record.installed_path.clone());
                artifact.installed_sha256 = Some(record.sha256.clone());
                artifact.install_status = ModelInstallStatus::Installed;
            }
            artifact
        })
        .collect())
}

pub fn install_model(
    config: &AppConfig,
    request: ModelInstallRequest,
) -> Result<ModelArtifact, ModelRegistryError> {
    if !request.confirmed {
        return Err(ModelRegistryError::Invalid(
            "model installation requires explicit confirmation".to_string(),
        ));
    }

    let mut artifact = find_model(config, &request.id)?;
    let source_url = artifact.source_url.clone().ok_or_else(|| {
        ModelRegistryError::Invalid(format!(
            "model {} has no reviewed download URL; import a local file instead",
            artifact.id
        ))
    })?;
    if let Some(requested_url) = request.source_url.as_ref()
        && requested_url != &source_url
    {
        append_audit(
            config,
            &artifact.id,
            "download",
            Some(requested_url.clone()),
            request
                .expected_sha256
                .clone()
                .or(artifact.expected_sha256.clone()),
            None,
            "rejected",
            "requested URL does not match the reviewed registry URL",
        )?;
        return Err(ModelRegistryError::Invalid(
            "requested source_url does not match the reviewed registry URL".to_string(),
        ));
    }

    let expected_hash = request
        .expected_sha256
        .clone()
        .or_else(|| artifact.expected_sha256.clone())
        .ok_or_else(|| {
            ModelRegistryError::Invalid(
                "expected_sha256 is required for confirmed model downloads".to_string(),
            )
        })?;

    if !artifact.approved_for_personal_family_use {
        append_audit(
            config,
            &artifact.id,
            "download",
            Some(source_url.clone()),
            Some(expected_hash),
            None,
            "rejected",
            "model is not approved for personal/family local use yet",
        )?;
        return Err(ModelRegistryError::Invalid(
            "model license/hash review is not approved for personal/family local use yet"
                .to_string(),
        ));
    }

    if matches!(config.network_policy, NetworkPolicy::OfflineOnly) {
        artifact.install_status = ModelInstallStatus::DownloadBlocked;
        append_audit(
            config,
            &artifact.id,
            "download",
            Some(source_url.clone()),
            Some(expected_hash),
            None,
            "blocked",
            "network policy is offline_only",
        )?;
        return Err(ModelRegistryError::Invalid(format!(
            "network policy is offline_only; download blocked for {source_url}"
        )));
    }

    let download_dir = config.runtime_root.join("models").join("downloads");
    fs::create_dir_all(&download_dir).map_err(|err| ModelRegistryError::Io(err.to_string()))?;
    let temp_path = download_dir.join(format!("{}.download", artifact.id));
    let client = reqwest::blocking::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .https_only(true)
        .build()
        .map_err(|err| ModelRegistryError::Io(err.to_string()))?;
    let response = client
        .get(&source_url)
        .send()
        .map_err(|err| ModelRegistryError::Io(err.to_string()))?
        .error_for_status()
        .map_err(|err| ModelRegistryError::Io(err.to_string()))?;
    let bytes = response
        .bytes()
        .map_err(|err| ModelRegistryError::Io(err.to_string()))?;
    let mut temp_file =
        fs::File::create(&temp_path).map_err(|err| ModelRegistryError::Io(err.to_string()))?;
    temp_file
        .write_all(&bytes)
        .map_err(|err| ModelRegistryError::Io(err.to_string()))?;
    temp_file
        .sync_all()
        .map_err(|err| ModelRegistryError::Io(err.to_string()))?;

    let actual_hash = imports::derive_content_hash_from_file(&temp_path)
        .map_err(|err| ModelRegistryError::Io(err.to_string()))?;
    if !actual_hash.eq_ignore_ascii_case(&expected_hash) {
        let _ = fs::remove_file(&temp_path);
        artifact.install_status = ModelInstallStatus::HashMismatch;
        artifact.installed_sha256 = Some(actual_hash.clone());
        append_audit(
            config,
            &artifact.id,
            "download",
            Some(source_url),
            Some(expected_hash),
            Some(actual_hash),
            "hash_mismatch",
            "downloaded model hash did not match expected_sha256",
        )?;
        return Err(ModelRegistryError::Invalid(
            "downloaded model hash mismatch; file was not installed".to_string(),
        ));
    }

    let destination = model_destination(config, &artifact.id, &actual_hash, &temp_path)?;
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent).map_err(|err| ModelRegistryError::Io(err.to_string()))?;
    }
    if destination.exists() {
        fs::remove_file(&temp_path).map_err(|err| ModelRegistryError::Io(err.to_string()))?;
    } else {
        fs::rename(&temp_path, &destination)
            .map_err(|err| ModelRegistryError::Io(err.to_string()))?;
    }

    let mut installed = load_installed_models(config)?;
    installed.retain(|record| record.id != artifact.id);
    installed.push(InstalledModelRecord {
        id: artifact.id.clone(),
        installed_path: destination.to_string_lossy().to_string(),
        sha256: actual_hash.clone(),
        installed_at: Utc::now(),
    });
    save_installed_models(config, &installed)?;

    append_audit(
        config,
        &artifact.id,
        "download",
        artifact.source_url.clone(),
        Some(expected_hash),
        Some(actual_hash.clone()),
        "installed",
        "confirmed download installed after SHA-256 verification",
    )?;

    artifact.installed_path = Some(destination.to_string_lossy().to_string());
    artifact.installed_sha256 = Some(actual_hash);
    artifact.install_status = ModelInstallStatus::Installed;
    Ok(artifact)
}

pub fn import_local_model(
    config: &AppConfig,
    request: ModelImportRequest,
) -> Result<ModelArtifact, ModelRegistryError> {
    if !request.confirmed {
        return Err(ModelRegistryError::Invalid(
            "local model import requires explicit confirmation".to_string(),
        ));
    }

    let mut artifact = find_model(config, &request.id)?;
    let source_path = PathBuf::from(&request.local_path);
    if !source_path.is_file() {
        return Err(ModelRegistryError::Invalid(format!(
            "local_path is not a file: {}",
            source_path.to_string_lossy()
        )));
    }

    let actual_hash = imports::derive_content_hash_from_file(&source_path)
        .map_err(|err| ModelRegistryError::Io(err.to_string()))?;
    let expected_hash = request
        .expected_sha256
        .clone()
        .or_else(|| artifact.expected_sha256.clone())
        .ok_or_else(|| {
            ModelRegistryError::Invalid(
                "expected_sha256 is required until this model has a pinned registry hash"
                    .to_string(),
            )
        })?;

    if !actual_hash.eq_ignore_ascii_case(&expected_hash) {
        artifact.install_status = ModelInstallStatus::HashMismatch;
        artifact.installed_sha256 = Some(actual_hash);
        append_audit(
            config,
            &artifact.id,
            "import_local",
            Some(request.local_path),
            Some(expected_hash),
            artifact.installed_sha256.clone(),
            "hash_mismatch",
            "local model hash did not match expected_sha256",
        )?;
        return Err(ModelRegistryError::Invalid(
            "model hash mismatch; file was not installed".to_string(),
        ));
    }

    let destination = model_destination(config, &artifact.id, &actual_hash, &source_path)?;
    if destination != source_path {
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent).map_err(|err| ModelRegistryError::Io(err.to_string()))?;
        }
        if !destination.exists() {
            fs::copy(&source_path, &destination)
                .map_err(|err| ModelRegistryError::Io(err.to_string()))?;
        }
    }

    let mut installed = load_installed_models(config)?;
    installed.retain(|record| record.id != artifact.id);
    installed.push(InstalledModelRecord {
        id: artifact.id.clone(),
        installed_path: destination.to_string_lossy().to_string(),
        sha256: actual_hash.clone(),
        installed_at: Utc::now(),
    });
    save_installed_models(config, &installed)?;

    artifact.installed_path = Some(destination.to_string_lossy().to_string());
    artifact.installed_sha256 = Some(actual_hash);
    artifact.install_status = ModelInstallStatus::Installed;
    append_audit(
        config,
        &artifact.id,
        "import_local",
        Some(request.local_path),
        Some(expected_hash),
        artifact.installed_sha256.clone(),
        "installed",
        "local model installed after SHA-256 verification",
    )?;
    Ok(artifact)
}

pub fn verify_model(
    config: &AppConfig,
    model_id: &str,
) -> Result<ModelArtifact, ModelRegistryError> {
    let mut artifact = find_model(config, model_id)?;
    let record = load_installed_models(config)?
        .into_iter()
        .find(|record| record.id == model_id)
        .ok_or_else(|| ModelRegistryError::Invalid(format!("model {model_id} is not installed")))?;

    let installed_path = PathBuf::from(&record.installed_path);
    let actual_hash = imports::derive_content_hash_from_file(&installed_path)
        .map_err(|err| ModelRegistryError::Io(err.to_string()))?;
    if !actual_hash.eq_ignore_ascii_case(&record.sha256) {
        artifact.install_status = ModelInstallStatus::HashMismatch;
        artifact.installed_path = Some(record.installed_path);
        artifact.installed_sha256 = Some(actual_hash);
        return Err(ModelRegistryError::Invalid(
            "installed model hash no longer matches the recorded hash".to_string(),
        ));
    }

    artifact.install_status = ModelInstallStatus::Installed;
    artifact.installed_path = Some(record.installed_path);
    artifact.installed_sha256 = Some(actual_hash);
    Ok(artifact)
}

pub fn is_loopback_host(host: &str) -> bool {
    matches!(host, "127.0.0.1" | "localhost" | "::1")
}

fn find_model(config: &AppConfig, model_id: &str) -> Result<ModelArtifact, ModelRegistryError> {
    list_models(config)?
        .into_iter()
        .find(|model| model.id == model_id)
        .ok_or_else(|| ModelRegistryError::Invalid(format!("unknown model id: {model_id}")))
}

fn candidate_models() -> Vec<ModelArtifact> {
    vec![
        ModelArtifact {
            id: "scrfd-face-detector".to_string(),
            name: "SCRFD face detector candidate".to_string(),
            version: "onnx-personal-review".to_string(),
            task: ModelTask::FaceDetection,
            license: Some("InsightFace license review required".to_string()),
            source_url: Some("https://github.com/deepinsight/insightface".to_string()),
            expected_sha256: None,
            installed_path: None,
            installed_sha256: None,
            install_status: ModelInstallStatus::PendingReview,
            review_notes:
                "Candidate only. Do not install for production until model file, license, and SHA-256 are pinned."
                    .to_string(),
            approved_for_personal_family_use: false,
        },
        ModelArtifact {
            id: "arcface-embedding".to_string(),
            name: "ArcFace-class embedding candidate".to_string(),
            version: "onnx-personal-review".to_string(),
            task: ModelTask::FaceEmbedding,
            license: Some("InsightFace license review required".to_string()),
            source_url: Some("https://github.com/deepinsight/insightface".to_string()),
            expected_sha256: None,
            installed_path: None,
            installed_sha256: None,
            install_status: ModelInstallStatus::PendingReview,
            review_notes:
                "Candidate only. Face templates are biometric artifacts and stay disabled until explicit model approval."
                    .to_string(),
            approved_for_personal_family_use: false,
        },
        ModelArtifact {
            id: "tesseract-ocr-data".to_string(),
            name: "Tesseract OCR data candidate".to_string(),
            version: "local-system-review".to_string(),
            task: ModelTask::Ocr,
            license: Some("Apache-2.0 for Tesseract engine; language data varies".to_string()),
            source_url: Some("https://tesseract-ocr.github.io/".to_string()),
            expected_sha256: None,
            installed_path: None,
            installed_sha256: None,
            install_status: ModelInstallStatus::PendingReview,
            review_notes:
                "OCR is not active yet. Install only pinned local language data, never upload text or images."
                    .to_string(),
            approved_for_personal_family_use: false,
        },
        ModelArtifact {
            id: "scene-classifier-onnx".to_string(),
            name: "Local ONNX scene classifier candidate".to_string(),
            version: "unselected".to_string(),
            task: ModelTask::SceneTagging,
            license: None,
            source_url: None,
            expected_sha256: None,
            installed_path: None,
            installed_sha256: None,
            install_status: ModelInstallStatus::PendingReview,
            review_notes:
                "No scene model has been selected. Keep scene tagging unavailable until a local model is reviewed."
                    .to_string(),
            approved_for_personal_family_use: false,
        },
        ModelArtifact {
            id: "semantic-embedding-onnx".to_string(),
            name: "Local semantic embedding candidate".to_string(),
            version: "unselected".to_string(),
            task: ModelTask::SemanticEmbedding,
            license: None,
            source_url: None,
            expected_sha256: None,
            installed_path: None,
            installed_sha256: None,
            install_status: ModelInstallStatus::PendingReview,
            review_notes:
                "No semantic model has been selected. Future embeddings must be generated locally and be rebuildable."
                    .to_string(),
            approved_for_personal_family_use: false,
        },
    ]
}

fn registry_path(config: &AppConfig) -> PathBuf {
    config
        .runtime_root
        .join("models")
        .join("installed_models.json")
}

fn audit_path(config: &AppConfig) -> PathBuf {
    config
        .runtime_root
        .join("models")
        .join("install_audit.json")
}

fn append_audit(
    config: &AppConfig,
    model_id: &str,
    action: &str,
    source_url: Option<String>,
    expected_sha256: Option<String>,
    actual_sha256: Option<String>,
    status: &str,
    message: &str,
) -> Result<(), ModelRegistryError> {
    let path = audit_path(config);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|err| ModelRegistryError::Io(err.to_string()))?;
    }
    let mut records = if path.exists() {
        let raw =
            fs::read_to_string(&path).map_err(|err| ModelRegistryError::Io(err.to_string()))?;
        serde_json::from_str::<Vec<ModelInstallAuditRecord>>(&raw)
            .map_err(|err| ModelRegistryError::Invalid(err.to_string()))?
    } else {
        Vec::new()
    };
    records.insert(
        0,
        ModelInstallAuditRecord {
            id: Uuid::new_v4(),
            model_id: model_id.to_string(),
            action: action.to_string(),
            source_url,
            expected_sha256,
            actual_sha256,
            status: status.to_string(),
            message: message.to_string(),
            created_at: Utc::now(),
        },
    );
    let raw = serde_json::to_string_pretty(&records)
        .map_err(|err| ModelRegistryError::Invalid(err.to_string()))?;
    fs::write(path, raw).map_err(|err| ModelRegistryError::Io(err.to_string()))
}

fn model_destination(
    config: &AppConfig,
    model_id: &str,
    hash: &str,
    source_path: &Path,
) -> Result<PathBuf, ModelRegistryError> {
    let file_name = source_path
        .file_name()
        .map(|value| imports::sanitize_filename(&value.to_string_lossy()))
        .ok_or_else(|| {
            ModelRegistryError::Invalid("local model file has no filename".to_string())
        })?;
    Ok(config
        .runtime_root
        .join("models")
        .join("files")
        .join(format!("{model_id}-{hash}-{file_name}")))
}

fn load_installed_models(
    config: &AppConfig,
) -> Result<Vec<InstalledModelRecord>, ModelRegistryError> {
    let path = registry_path(config);
    if !path.exists() {
        return Ok(Vec::new());
    }
    let raw = fs::read_to_string(path).map_err(|err| ModelRegistryError::Io(err.to_string()))?;
    serde_json::from_str(&raw).map_err(|err| ModelRegistryError::Invalid(err.to_string()))
}

fn save_installed_models(
    config: &AppConfig,
    records: &[InstalledModelRecord],
) -> Result<(), ModelRegistryError> {
    let path = registry_path(config);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|err| ModelRegistryError::Io(err.to_string()))?;
    }
    let raw = serde_json::to_string_pretty(records)
        .map_err(|err| ModelRegistryError::Invalid(err.to_string()))?;
    fs::write(path, raw).map_err(|err| ModelRegistryError::Io(err.to_string()))
}
