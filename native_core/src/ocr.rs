use std::{
    env, fs,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

use chrono::Utc;
use sha2::{Digest, Sha256};
use thiserror::Error;

use crate::{
    config::AppConfig,
    domain::{ModelProvenance, OcrBlock},
};
use uuid::Uuid;

const OCR_ASSET_TIMEOUT: Duration = Duration::from_secs(45);

#[derive(Debug, Error)]
pub enum OcrError {
    #[error("local OCR provider missing: {0}")]
    MissingProvider(String),
    #[error("local OCR provider failed: {0}")]
    ProviderFailed(String),
    #[error("OCR filesystem operation failed: {0}")]
    Io(String),
}

#[derive(Debug, Clone)]
pub struct TesseractProvider {
    command: PathBuf,
}

#[derive(Debug, Clone)]
pub struct OcrProviderInfo {
    pub version: String,
    pub hash: String,
}

impl TesseractProvider {
    pub fn from_config(config: &AppConfig) -> Self {
        Self {
            command: config
                .tesseract_path
                .clone()
                .unwrap_or_else(|| PathBuf::from("tesseract")),
        }
    }

    pub fn provider_info(&self) -> Result<OcrProviderInfo, OcrError> {
        let output = Command::new(&self.command)
            .arg("--version")
            .output()
            .map_err(|err| OcrError::MissingProvider(err.to_string()))?;
        if !output.status.success() {
            return Err(OcrError::MissingProvider(
                String::from_utf8_lossy(&output.stderr).trim().to_string(),
            ));
        }

        let raw_version = String::from_utf8_lossy(&output.stdout);
        let version = raw_version
            .lines()
            .next()
            .unwrap_or("tesseract unknown")
            .trim()
            .to_string();
        let hash = provider_hash(&self.command, &raw_version)?;
        Ok(OcrProviderInfo { version, hash })
    }

    pub fn recognize_asset(
        &self,
        asset_id: Uuid,
        image_path: &Path,
        info: &OcrProviderInfo,
    ) -> Result<Option<OcrBlock>, OcrError> {
        let mut child = Command::new(&self.command)
            .arg(image_path)
            .arg("stdout")
            .arg("-l")
            .arg("eng")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|err| OcrError::ProviderFailed(err.to_string()))?;

        let started_at = Instant::now();
        loop {
            if child
                .try_wait()
                .map_err(|err| OcrError::ProviderFailed(err.to_string()))?
                .is_some()
            {
                break;
            }
            if started_at.elapsed() > OCR_ASSET_TIMEOUT {
                let _ = child.kill();
                let _ = child.wait();
                return Err(OcrError::ProviderFailed(format!(
                    "timed out after {} seconds",
                    OCR_ASSET_TIMEOUT.as_secs()
                )));
            }
            thread::sleep(Duration::from_millis(100));
        }

        let output = child
            .wait_with_output()
            .map_err(|err| OcrError::ProviderFailed(err.to_string()))?;

        if !output.status.success() {
            return Err(OcrError::ProviderFailed(
                String::from_utf8_lossy(&output.stderr).trim().to_string(),
            ));
        }

        let text = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if text.is_empty() {
            return Ok(None);
        }

        Ok(Some(OcrBlock {
            id: Uuid::new_v4(),
            asset_id,
            text,
            bounding_box: None,
            derived: ModelProvenance {
                model_name: "tesseract-cli".to_string(),
                model_version: info.version.clone(),
                model_hash: Some(info.hash.clone()),
                created_at: Utc::now(),
                rebuildable: true,
            },
        }))
    }
}

fn provider_hash(command: &Path, version_output: &str) -> Result<String, OcrError> {
    let mut hasher = Sha256::new();
    hasher.update(version_output.as_bytes());

    if let Some(path) = resolve_command_path(command) {
        let bytes = fs::read(path).map_err(|err| OcrError::Io(err.to_string()))?;
        hasher.update(bytes);
    }

    if let Ok(prefix) = env::var("TESSDATA_PREFIX") {
        let eng_path = PathBuf::from(prefix).join("eng.traineddata");
        if eng_path.exists() {
            let bytes = fs::read(eng_path).map_err(|err| OcrError::Io(err.to_string()))?;
            hasher.update(bytes);
        }
    }

    Ok(hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

fn resolve_command_path(command: &Path) -> Option<PathBuf> {
    if command.is_absolute() && command.exists() {
        return Some(command.to_path_buf());
    }

    let command_name = command.to_string_lossy();
    env::var_os("PATH").and_then(|paths| {
        env::split_paths(&paths)
            .map(|path| path.join(command_name.as_ref()))
            .find(|candidate| candidate.exists())
    })
}
