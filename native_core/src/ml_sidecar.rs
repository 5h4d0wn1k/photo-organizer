use std::{env, path::Path, path::PathBuf, process::Command};

use chrono::Utc;
use serde::Deserialize;
use uuid::Uuid;

use crate::{
    config::AppConfig,
    domain::{ModelProvenance, ModelRuntimeDependency, ModelRuntimeStatus, SceneTag},
};

#[derive(Debug, Deserialize)]
struct ProbeDependency {
    name: String,
    available: bool,
    version: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ProbeResponse {
    ok: bool,
    runtime: Option<String>,
    python_version: Option<String>,
    executable: Option<String>,
    offline_ready: Option<bool>,
    dependencies: Option<Vec<ProbeDependency>>,
    detail: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SceneTagResponse {
    ok: bool,
    model_name: Option<String>,
    model_version: Option<String>,
    model_hash: Option<String>,
    tags: Option<Vec<SceneTagCandidate>>,
    detail: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SceneTagCandidate {
    label: String,
    confidence: f32,
}

pub fn runtime_status(config: &AppConfig) -> ModelRuntimeStatus {
    let python = env::var("PRIVATE_GALLERY_PYTHON").unwrap_or_else(|_| "python3".to_string());
    let sidecar_path = resolve_sidecar_path();
    let Some(sidecar_path) = sidecar_path else {
        return ModelRuntimeStatus {
            ok: false,
            runtime: "python-sidecar".to_string(),
            sidecar_path: None,
            python_executable: python,
            python_version: None,
            offline_ready: false,
            dependencies: Vec::new(),
            detail: "ML sidecar script was not found beside the daemon or repository root"
                .to_string(),
        };
    };

    let output = Command::new(&python)
        .arg(&sidecar_path)
        .arg("probe")
        .env("HF_HUB_OFFLINE", "1")
        .env("TRANSFORMERS_OFFLINE", "1")
        .env("HF_DATASETS_OFFLINE", "1")
        .env("WANDB_DISABLED", "true")
        .env("DO_NOT_TRACK", "1")
        .env("NO_PROXY", "*")
        .env("PRIVATE_GALLERY_RUNTIME_ROOT", &config.runtime_root)
        .output();

    let output = match output {
        Ok(output) => output,
        Err(err) => {
            return ModelRuntimeStatus {
                ok: false,
                runtime: "python-sidecar".to_string(),
                sidecar_path: Some(sidecar_path.to_string_lossy().to_string()),
                python_executable: python,
                python_version: None,
                offline_ready: false,
                dependencies: Vec::new(),
                detail: format!("failed to launch Python sidecar: {err}"),
            };
        }
    };

    if !output.status.success() {
        return ModelRuntimeStatus {
            ok: false,
            runtime: "python-sidecar".to_string(),
            sidecar_path: Some(sidecar_path.to_string_lossy().to_string()),
            python_executable: python,
            python_version: None,
            offline_ready: false,
            dependencies: Vec::new(),
            detail: format!(
                "sidecar probe exited with status {}: {}",
                output.status,
                String::from_utf8_lossy(&output.stderr)
            ),
        };
    }

    let parsed = serde_json::from_slice::<ProbeResponse>(&output.stdout);
    match parsed {
        Ok(response) => ModelRuntimeStatus {
            ok: response.ok,
            runtime: response
                .runtime
                .unwrap_or_else(|| "python-sidecar".to_string()),
            sidecar_path: Some(sidecar_path.to_string_lossy().to_string()),
            python_executable: response.executable.unwrap_or(python),
            python_version: response.python_version,
            offline_ready: response.offline_ready.unwrap_or(false),
            dependencies: response
                .dependencies
                .unwrap_or_default()
                .into_iter()
                .map(|dependency| ModelRuntimeDependency {
                    name: dependency.name,
                    available: dependency.available,
                    version: dependency.version,
                })
                .collect(),
            detail: response
                .detail
                .unwrap_or_else(|| "sidecar probe completed".to_string()),
        },
        Err(err) => ModelRuntimeStatus {
            ok: false,
            runtime: "python-sidecar".to_string(),
            sidecar_path: Some(sidecar_path.to_string_lossy().to_string()),
            python_executable: python,
            python_version: None,
            offline_ready: false,
            dependencies: Vec::new(),
            detail: format!("sidecar probe returned invalid JSON: {err}"),
        },
    }
}

pub fn analyze_scene_tags(
    config: &AppConfig,
    asset_id: Uuid,
    image_path: &Path,
) -> Result<Vec<SceneTag>, String> {
    let output = run_sidecar_command(config, &["scene-tags", &image_path.to_string_lossy()])?;
    let response = serde_json::from_slice::<SceneTagResponse>(&output)
        .map_err(|err| format!("scene sidecar returned invalid JSON: {err}"))?;
    if !response.ok {
        return Err(response
            .detail
            .unwrap_or_else(|| "scene sidecar reported failure".to_string()));
    }

    let model_name = response
        .model_name
        .unwrap_or_else(|| "local-heuristic-scene-tagger".to_string());
    let model_version = response.model_version.unwrap_or_else(|| "v1".to_string());
    let tags = response
        .tags
        .unwrap_or_default()
        .into_iter()
        .filter(|tag| !tag.label.trim().is_empty())
        .map(|tag| SceneTag {
            id: Uuid::new_v4(),
            asset_id,
            label: tag.label,
            confidence: tag.confidence.clamp(0.0, 1.0),
            derived: ModelProvenance {
                model_name: model_name.clone(),
                model_version: model_version.clone(),
                model_hash: response.model_hash.clone(),
                created_at: Utc::now(),
                rebuildable: true,
            },
        })
        .collect();

    Ok(tags)
}

fn run_sidecar_command(config: &AppConfig, args: &[&str]) -> Result<Vec<u8>, String> {
    let python = env::var("PRIVATE_GALLERY_PYTHON").unwrap_or_else(|_| "python3".to_string());
    let sidecar_path = resolve_sidecar_path().ok_or_else(|| {
        "ML sidecar script was not found beside the daemon or repository root".to_string()
    })?;
    let output = Command::new(&python)
        .arg(&sidecar_path)
        .args(args)
        .env("HF_HUB_OFFLINE", "1")
        .env("TRANSFORMERS_OFFLINE", "1")
        .env("HF_DATASETS_OFFLINE", "1")
        .env("WANDB_DISABLED", "true")
        .env("DO_NOT_TRACK", "1")
        .env("NO_PROXY", "*")
        .env("PRIVATE_GALLERY_RUNTIME_ROOT", &config.runtime_root)
        .output()
        .map_err(|err| format!("failed to launch Python sidecar: {err}"))?;

    if !output.status.success() {
        return Err(format!(
            "sidecar exited with status {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    Ok(output.stdout)
}

fn resolve_sidecar_path() -> Option<PathBuf> {
    if let Ok(path) = env::var("PRIVATE_GALLERY_ML_SIDECAR") {
        let path = PathBuf::from(path);
        if path.exists() {
            return Some(path);
        }
    }

    let mut candidates = vec![
        PathBuf::from("ml_sidecar/private_gallery_ml_sidecar.py"),
        PathBuf::from("../ml_sidecar/private_gallery_ml_sidecar.py"),
    ];
    if let Some(path) = executable_adjacent_sidecar() {
        candidates.push(path);
    }
    candidates.into_iter().find(|path| path.exists())
}

fn executable_adjacent_sidecar() -> Option<PathBuf> {
    let executable = env::current_exe().ok()?;
    let parent = executable.parent()?;
    Some(parent.join("ml_sidecar/private_gallery_ml_sidecar.py"))
}
