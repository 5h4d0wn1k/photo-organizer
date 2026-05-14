use std::{
    collections::{BTreeSet, HashMap},
    fs,
    io::{BufReader, Read},
    path::{Path, PathBuf},
    time::SystemTime,
};

use chrono::{DateTime, Utc};
use serde_json::Value;
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::{
    domain::{
        Asset, AssetVariant, ImportAssetRequest, ImportCandidate, ImportMode, ImportSession,
        ImportSessionStatus, ImportSourceKind, JobKind, JobRecord, JobStatus, MediaKind,
        ModelProvenance, ScanImportSourceRequest, VariantKind,
    },
    metadata,
};

const HASH_BUFFER_BYTES: usize = 1024 * 1024;

pub fn infer_media_kind(path: &Path) -> Option<MediaKind> {
    let extension = path.extension()?.to_string_lossy().to_ascii_lowercase();
    match extension.as_str() {
        "jpg" | "jpeg" | "jfif" | "png" | "webp" | "gif" | "heic" | "heif" | "bmp" | "tif"
        | "tiff" | "dng" | "jxr" => Some(MediaKind::Photo),
        "mp4" | "mov" | "m4v" | "avi" | "mkv" | "webm" => Some(MediaKind::Video),
        _ => None,
    }
}

pub fn is_path_inside(child: &Path, parent: &Path) -> bool {
    let child = child.canonicalize().unwrap_or_else(|_| child.to_path_buf());
    let parent = parent
        .canonicalize()
        .unwrap_or_else(|_| parent.to_path_buf());
    child.starts_with(parent)
}

pub fn infer_mime_type(path: &Path, media_kind: &MediaKind) -> String {
    let extension = path
        .extension()
        .map(|value| value.to_string_lossy().to_ascii_lowercase())
        .unwrap_or_default();

    match (media_kind, extension.as_str()) {
        (MediaKind::Photo, "png") => "image/png".to_string(),
        (MediaKind::Photo, "webp") => "image/webp".to_string(),
        (MediaKind::Photo, "gif") => "image/gif".to_string(),
        (MediaKind::Photo, "tif") | (MediaKind::Photo, "tiff") => "image/tiff".to_string(),
        (MediaKind::Photo, "heic") | (MediaKind::Photo, "heif") => "image/heic".to_string(),
        (MediaKind::Photo, "dng") => "image/x-adobe-dng".to_string(),
        (MediaKind::Photo, "jxr") => "image/jxr".to_string(),
        (MediaKind::Video, "mov") => "video/quicktime".to_string(),
        (MediaKind::Video, "webm") => "video/webm".to_string(),
        (MediaKind::Video, "mkv") => "video/x-matroska".to_string(),
        (MediaKind::Video, "avi") => "video/x-msvideo".to_string(),
        (MediaKind::Video, _) => "video/mp4".to_string(),
        _ => "image/jpeg".to_string(),
    }
}

pub fn derive_content_hash_from_file(path: &Path) -> Result<String, std::io::Error> {
    let file = fs::File::open(path)?;
    let mut reader = BufReader::new(file);
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; HASH_BUFFER_BYTES];

    loop {
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }

    Ok(format!("{:x}", hasher.finalize()))
}

pub fn derive_content_hash(source_path: &str, bytes: u64) -> String {
    let mut hasher = Sha256::new();
    hasher.update(source_path.as_bytes());
    hasher.update(bytes.to_le_bytes());
    format!("{:x}", hasher.finalize())
}

pub fn derive_asset_storage_path(content_hash: &str, filename: &str) -> String {
    let extension = filename
        .rsplit('.')
        .next()
        .filter(|segment| *segment != filename)
        .unwrap_or("bin");
    format!(
        "objects/{}/{}/{}.{}",
        &content_hash[0..2],
        &content_hash[2..4],
        content_hash,
        extension
    )
}

pub fn derive_managed_original_path(
    content_hash: &str,
    filename: &str,
    captured_at: DateTime<Utc>,
) -> String {
    let safe_filename = sanitize_filename(filename);
    format!(
        "originals/{}/{}/{}-{}",
        captured_at.format("%Y"),
        captured_at.format("%m"),
        content_hash,
        safe_filename
    )
}

pub fn sanitize_filename(filename: &str) -> String {
    let sanitized = filename
        .chars()
        .map(|value| match value {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            value if value.is_control() => '_',
            value => value,
        })
        .collect::<String>();

    if sanitized.trim().is_empty() {
        "unknown".to_string()
    } else {
        sanitized
    }
}

pub fn collect_media_files(
    root: &Path,
    recursive: bool,
    excluded_roots: &[PathBuf],
) -> Result<Vec<PathBuf>, std::io::Error> {
    let mut files = Vec::new();

    if excluded_roots
        .iter()
        .any(|excluded| is_path_inside(root, excluded))
    {
        return Ok(files);
    }

    if root.is_file() {
        if infer_media_kind(root).is_some() {
            files.push(root.to_path_buf());
        }
        return Ok(files);
    }

    let mut entries = fs::read_dir(root)?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .collect::<Vec<_>>();
    entries.sort();

    for path in entries {
        if path.is_file() {
            if infer_media_kind(&path).is_some() {
                files.push(path);
            }
            continue;
        }

        if recursive && path.is_dir() {
            if is_internal_organizer_dir(&path) {
                continue;
            }
            files.extend(collect_media_files(&path, true, excluded_roots)?);
        }
    }

    Ok(files)
}

pub fn collect_unsupported_files(
    root: &Path,
    recursive: bool,
    excluded_roots: &[PathBuf],
) -> Result<Vec<PathBuf>, std::io::Error> {
    let mut files = Vec::new();

    if excluded_roots
        .iter()
        .any(|excluded| is_path_inside(root, excluded))
    {
        return Ok(files);
    }

    if root.is_file() {
        if infer_media_kind(root).is_none() && !is_json_file(root) {
            files.push(root.to_path_buf());
        }
        return Ok(files);
    }

    let mut entries = fs::read_dir(root)?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .collect::<Vec<_>>();
    entries.sort();

    for path in entries {
        if path.is_file() {
            if infer_media_kind(&path).is_none() && !is_json_file(&path) {
                files.push(path);
            }
            continue;
        }

        if recursive && path.is_dir() {
            if is_internal_organizer_dir(&path) {
                continue;
            }
            files.extend(collect_unsupported_files(&path, true, excluded_roots)?);
        }
    }

    Ok(files)
}

fn is_json_file(path: &Path) -> bool {
    path.extension()
        .map(|value| value.to_string_lossy().eq_ignore_ascii_case("json"))
        .unwrap_or(false)
}

fn is_internal_organizer_dir(path: &Path) -> bool {
    matches!(
        path.file_name()
            .map(|value| value.to_string_lossy().to_string())
            .as_deref(),
        Some("_security_review" | "_source_audit" | "_takeout_review" | "_manifests")
    )
}

#[derive(Debug, Default)]
struct SidecarIndex {
    media_name_counts: HashMap<String, usize>,
    takeout_title_sidecars: HashMap<String, Vec<PathBuf>>,
}

fn collect_json_files(
    root: &Path,
    recursive: bool,
    excluded_roots: &[PathBuf],
) -> Result<Vec<PathBuf>, std::io::Error> {
    let mut files = Vec::new();

    if excluded_roots
        .iter()
        .any(|excluded| is_path_inside(root, excluded))
    {
        return Ok(files);
    }

    if root.is_file() {
        if is_json_file(root) {
            files.push(root.to_path_buf());
        }
        return Ok(files);
    }

    let mut entries = fs::read_dir(root)?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .collect::<Vec<_>>();
    entries.sort();

    for path in entries {
        if path.is_file() {
            if is_json_file(&path) {
                files.push(path);
            }
            continue;
        }

        if recursive && path.is_dir() {
            if is_internal_organizer_dir(&path) {
                continue;
            }
            files.extend(collect_json_files(&path, true, excluded_roots)?);
        }
    }

    Ok(files)
}

fn build_sidecar_index(
    source_root: &Path,
    recursive: bool,
    excluded_roots: &[PathBuf],
    media_files: &[PathBuf],
) -> Result<SidecarIndex, std::io::Error> {
    let mut index = SidecarIndex::default();
    for media_path in media_files {
        if let Some(filename) = media_path.file_name().map(|value| value.to_string_lossy()) {
            *index
                .media_name_counts
                .entry(filename.to_string())
                .or_insert(0) += 1;
        }
    }

    for json_path in collect_json_files(source_root, recursive, excluded_roots)? {
        if let Some(title) = takeout_sidecar_title(&json_path) {
            index
                .takeout_title_sidecars
                .entry(title)
                .or_default()
                .push(json_path);
        }
    }

    Ok(index)
}

fn takeout_sidecar_title(path: &Path) -> Option<String> {
    let raw = fs::read_to_string(path).ok()?;
    let json = serde_json::from_str::<Value>(&raw).ok()?;
    if !is_takeout_sidecar_json(&json) {
        return None;
    }
    json.get("title")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
}

fn is_takeout_sidecar_json(json: &Value) -> bool {
    json.get("photoTakenTime").is_some()
        || json.get("creationTime").is_some()
        || json.get("geoData").is_some()
        || json.get("geoDataExif").is_some()
        || json.get("googlePhotosOrigin").is_some()
}

pub fn detect_sidecars(media_path: &Path, source_root: &Path) -> Vec<PathBuf> {
    detect_sidecars_with_index(media_path, source_root, None)
}

fn detect_sidecars_with_index(
    media_path: &Path,
    source_root: &Path,
    sidecar_index: Option<&SidecarIndex>,
) -> Vec<PathBuf> {
    let mut sidecars = BTreeSet::<PathBuf>::new();
    let parent = media_path.parent().unwrap_or(source_root);
    let filename = media_path
        .file_name()
        .map(|value| value.to_string_lossy().to_string())
        .unwrap_or_default();
    let stem = media_path
        .file_stem()
        .map(|value| value.to_string_lossy().to_string())
        .unwrap_or_default();

    for candidate in [
        parent.join(format!("{filename}.json")),
        parent.join(format!("{stem}.json")),
        source_root.join("json").join(format!("{filename}.json")),
        source_root.join("json").join(format!("{stem}.json")),
    ] {
        if candidate.is_file() {
            sidecars.insert(candidate);
        }
    }

    if let Some(index) = sidecar_index
        && !filename.is_empty()
        && index.media_name_counts.get(&filename).copied() == Some(1)
        && let Some(candidates) = index.takeout_title_sidecars.get(&filename)
        && candidates.len() == 1
    {
        sidecars.insert(candidates[0].clone());
    }

    sidecars.into_iter().collect()
}

pub fn system_time_to_utc(time: SystemTime) -> DateTime<Utc> {
    DateTime::<Utc>::from(time)
}

pub fn build_imported_asset(request: ImportAssetRequest) -> (Asset, JobRecord) {
    let captured_at = request.captured_at.unwrap_or_else(Utc::now);
    let imported_at = Utc::now();
    let content_hash = request.content_hash.unwrap_or_else(|| {
        let source_path = Path::new(&request.source_path);
        if source_path.exists() {
            derive_content_hash_from_file(source_path)
                .unwrap_or_else(|_| derive_content_hash(&request.source_path, request.bytes))
        } else {
            derive_content_hash(&request.source_path, request.bytes)
        }
    });
    let import_mode = request.import_mode.unwrap_or(ImportMode::Copy);
    let relative_original_path = match import_mode {
        ImportMode::Copy => derive_asset_storage_path(&content_hash, &request.original_filename),
        ImportMode::Reference => request.source_path.clone(),
        ImportMode::Move => {
            derive_managed_original_path(&content_hash, &request.original_filename, captured_at)
        }
    };
    let preview_path = format!("variants/previews/{content_hash}.jpg");
    let thumbnail_path = format!("variants/thumbs/{content_hash}.webp");

    let preview = AssetVariant {
        id: Uuid::new_v4(),
        kind: VariantKind::Preview,
        relative_path: preview_path,
        mime_type: request.mime_type.clone(),
        bytes: request.bytes.min(512_000),
        width: Some(1920),
        height: Some(1080),
        derived: ModelProvenance::local("preview-generator", "v0"),
    };

    let thumbnail = AssetVariant {
        id: Uuid::new_v4(),
        kind: VariantKind::Thumbnail,
        relative_path: thumbnail_path,
        mime_type: if request.media_kind == MediaKind::Photo {
            "image/jpeg".to_string()
        } else {
            "image/webp".to_string()
        },
        bytes: request.bytes.min(96_000),
        width: Some(480),
        height: Some(480),
        derived: ModelProvenance::local("thumb-generator", "v0"),
    };

    let asset = Asset {
        id: Uuid::new_v4(),
        original_filename: request.original_filename,
        relative_original_path,
        source_path: request.source_path,
        content_hash,
        media_kind: request.media_kind,
        import_mode,
        bytes: request.bytes,
        mime_type: request.mime_type,
        captured_at,
        imported_at,
        archived: false,
        favorite: false,
        is_available: true,
        place_hint: request.place_hint,
        metadata: None,
        variants: vec![preview, thumbnail],
    };

    let job = JobRecord {
        id: Uuid::new_v4(),
        kind: JobKind::Import,
        status: JobStatus::Queued,
        progress: 0,
        queued_at: imported_at,
        started_at: None,
        completed_at: None,
        detail: Some(format!("queued import for {}", asset.original_filename)),
        cancel_requested: false,
        retry_of_job_id: None,
        attempt: 1,
    };

    (asset, job)
}

pub fn scan_source<F>(
    request: &ScanImportSourceRequest,
    default_import_mode: ImportMode,
    library_root: Option<&Path>,
    duplicate_lookup: F,
) -> Result<ImportSession, std::io::Error>
where
    F: Fn(&str) -> Option<Uuid>,
{
    let source_root = PathBuf::from(&request.source_path);
    let import_mode = request.import_mode.unwrap_or(default_import_mode);
    let excluded_roots = library_root
        .filter(|root| root.exists())
        .map(|root| vec![root.to_path_buf()])
        .unwrap_or_default();
    let unsupported_file_paths =
        collect_unsupported_files(&source_root, request.recursive, &excluded_roots)?
            .into_iter()
            .map(|path| path.to_string_lossy().to_string())
            .collect::<Vec<_>>();

    let media_files = collect_media_files(&source_root, request.recursive, &excluded_roots)?;
    let sidecar_index = build_sidecar_index(
        &source_root,
        request.recursive,
        &excluded_roots,
        &media_files,
    )?;

    let candidates = media_files
        .into_iter()
        .map(|path| {
            let file_metadata = fs::metadata(&path)?;
            let media_kind = infer_media_kind(&path)
                .expect("collect_media_files only returns supported media files");
            let content_hash = derive_content_hash_from_file(&path)?;
            let filesystem_captured_at = file_metadata.modified().ok().map(system_time_to_utc);
            let duplicate_asset_id = duplicate_lookup(&content_hash);
            let original_filename = path
                .file_name()
                .map(|value| value.to_string_lossy().to_string())
                .unwrap_or_else(|| "unknown".to_string());
            let sidecar_paths =
                detect_sidecars_with_index(&path, &source_root, Some(&sidecar_index))
                    .into_iter()
                    .map(|value| value.to_string_lossy().to_string())
                    .collect::<Vec<_>>();
            let extracted_metadata = metadata::extract_import_metadata(
                &path,
                &sidecar_paths,
                filesystem_captured_at.unwrap_or_else(Utc::now),
            );
            let captured_at = Some(extracted_metadata.captured_at);
            let relative_destination = derive_managed_original_path(
                &content_hash,
                &original_filename,
                captured_at.unwrap_or_else(Utc::now),
            );
            let destination_path = library_root.map(|root| {
                root.join(&relative_destination)
                    .to_string_lossy()
                    .to_string()
            });
            let safety_status = if duplicate_asset_id.is_some() {
                "duplicate_skip".to_string()
            } else if import_mode == ImportMode::Move {
                "ready_to_move_verified_after_commit".to_string()
            } else {
                "ready".to_string()
            };

            Ok(ImportCandidate {
                id: Uuid::new_v4(),
                session_id: Uuid::nil(),
                source_path: path.to_string_lossy().to_string(),
                original_filename,
                media_kind: media_kind.clone(),
                mime_type: infer_mime_type(&path, &media_kind),
                bytes: file_metadata.len(),
                captured_at,
                place_hint: request
                    .place_hint
                    .clone()
                    .or_else(|| metadata::coarse_place_label(&extracted_metadata)),
                content_hash,
                duplicate_asset_id,
                selected: true,
                import_mode,
                destination_path,
                sidecar_paths,
                safety_status,
            })
        })
        .collect::<Result<Vec<_>, std::io::Error>>()?;

    let session_id = Uuid::new_v4();
    let candidates = candidates
        .into_iter()
        .map(|candidate| ImportCandidate {
            session_id,
            ..candidate
        })
        .collect();

    let mut session = ImportSession {
        id: session_id,
        source_kind: request.source_kind,
        source_path: request.source_path.clone(),
        import_mode,
        add_as_watch_folder: request.add_as_watch_folder,
        status: ImportSessionStatus::Scanned,
        created_at: Utc::now(),
        completed_at: None,
        place_hint: request.place_hint.clone(),
        candidates,
        imported_asset_ids: Vec::new(),
        duplicate_asset_ids: Vec::new(),
        moved_asset_ids: Vec::new(),
        skipped_duplicate_ids: Vec::new(),
        failed_candidate_ids: Vec::new(),
        sidecars_moved: 0,
        unsupported_file_paths,
        selected_candidate_count: 0,
        selected_bytes: 0,
        duplicate_count: 0,
        unsupported_count: 0,
        sidecar_count: 0,
        destination_root: None,
        requires_move_confirmation: false,
        source_contains_managed_library: false,
        selected_outside_source_count: 0,
    };
    refresh_import_session_summary(&mut session, library_root);
    Ok(session)
}

pub fn refresh_import_session_summary(session: &mut ImportSession, library_root: Option<&Path>) {
    let source_root = PathBuf::from(&session.source_path);
    session.selected_candidate_count = session
        .candidates
        .iter()
        .filter(|candidate| candidate.selected && candidate.duplicate_asset_id.is_none())
        .count();
    session.selected_bytes = session
        .candidates
        .iter()
        .filter(|candidate| candidate.selected && candidate.duplicate_asset_id.is_none())
        .map(|candidate| candidate.bytes)
        .sum();
    session.duplicate_count = session
        .candidates
        .iter()
        .filter(|candidate| candidate.duplicate_asset_id.is_some())
        .count();
    session.unsupported_count = session.unsupported_file_paths.len();
    session.sidecar_count = session
        .candidates
        .iter()
        .map(|candidate| candidate.sidecar_paths.len())
        .sum();
    session.destination_root = library_root.map(|root| root.to_string_lossy().to_string());
    session.requires_move_confirmation =
        session.import_mode == ImportMode::Move && session.selected_candidate_count > 0;
    session.source_contains_managed_library = library_root
        .map(|root| is_path_inside(root, &source_root) && root != source_root)
        .unwrap_or(false);
    session.selected_outside_source_count = session
        .candidates
        .iter()
        .filter(|candidate| candidate.selected && candidate.duplicate_asset_id.is_none())
        .filter(|candidate| !is_path_inside(Path::new(&candidate.source_path), &source_root))
        .count();
}

pub fn build_import_job_detail(
    source_kind: ImportSourceKind,
    source_path: &str,
    asset_count: usize,
) -> String {
    let label = match source_kind {
        ImportSourceKind::Folder => "folder import",
        ImportSourceKind::RemovableDrive => "removable drive import",
    };
    format!("{label}: {asset_count} items from {source_path}")
}

#[cfg(test)]
mod tests {
    use std::{fs, path::PathBuf};

    use chrono::Utc;
    use uuid::Uuid;

    use crate::domain::{ImportMode, ImportSourceKind, ScanImportSourceRequest};

    use super::{
        collect_media_files, collect_unsupported_files, derive_asset_storage_path, scan_source,
    };

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "private-gallery-{name}-{}",
            Utc::now().timestamp_nanos_opt().unwrap_or_default()
        ));
        fs::create_dir_all(&dir).expect("create temp dir");
        dir
    }

    #[test]
    fn content_address_path_uses_hash_prefixes() {
        let hash = "4f6f1c99f9850f1de7447efb233e2f4ec2d6cf0bc59d1b24fd3fd703f4f8d8c6";
        let path = derive_asset_storage_path(hash, "trip.mov");
        assert_eq!(
            path,
            "objects/4f/6f/4f6f1c99f9850f1de7447efb233e2f4ec2d6cf0bc59d1b24fd3fd703f4f8d8c6.mov"
        );
    }

    #[test]
    fn collects_media_files_recursively() {
        let root = temp_dir("collect");
        let nested = root.join("nested");
        fs::create_dir_all(&nested).expect("nested dir");
        fs::write(root.join("a.jpg"), b"image").expect("write image");
        fs::write(root.join("raw.dng"), b"raw").expect("write raw image");
        fs::write(root.join("scan.tiff"), b"scan").expect("write tiff image");
        fs::write(root.join("legacy.jfif"), b"legacy").expect("write jfif image");
        fs::write(root.join("windows.jxr"), b"jxr").expect("write jxr image");
        fs::write(nested.join("b.mp4"), b"video").expect("write video");

        let files = collect_media_files(&root, true, &[]).expect("scan should succeed");
        assert_eq!(files.len(), 6);
    }

    #[test]
    fn scan_source_marks_duplicates() {
        let root = temp_dir("scan");
        fs::write(root.join("a.jpg"), b"image").expect("write image");
        let request = ScanImportSourceRequest {
            source_path: root.to_string_lossy().to_string(),
            source_kind: ImportSourceKind::Folder,
            recursive: false,
            import_mode: Some(ImportMode::Copy),
            add_as_watch_folder: false,
            place_hint: Some("Goa".to_string()),
        };

        let session = scan_source(&request, ImportMode::Copy, None, |_| Some(Uuid::new_v4()))
            .expect("scan should succeed");
        assert_eq!(session.candidates.len(), 1);
        assert!(session.candidates[0].duplicate_asset_id.is_some());
    }

    #[test]
    fn scan_source_excludes_library_root_and_attaches_sidecars() {
        let root = temp_dir("sidecars");
        let library_root = root.join("PrivateGalleryLibrary");
        fs::create_dir_all(library_root.join("originals")).expect("library dir");
        fs::write(root.join("a.jpg"), b"image").expect("write image");
        fs::write(root.join("a.jpg.json"), b"{}").expect("write sidecar");
        fs::write(root.join("desktop.ini"), b"ignored").expect("write unsupported");
        fs::write(library_root.join("b.jpg"), b"managed").expect("write managed");
        fs::write(library_root.join("thumbs.db"), b"managed unsupported")
            .expect("write managed unsupported");
        let request = ScanImportSourceRequest {
            source_path: root.to_string_lossy().to_string(),
            source_kind: ImportSourceKind::Folder,
            recursive: true,
            import_mode: Some(ImportMode::Move),
            add_as_watch_folder: false,
            place_hint: None,
        };

        let session = scan_source(&request, ImportMode::Move, Some(&library_root), |_| None)
            .expect("scan should succeed");
        assert_eq!(session.candidates.len(), 1);
        assert_eq!(session.candidates[0].sidecar_paths.len(), 1);
        assert!(session.candidates[0].destination_path.is_some());
        assert_eq!(session.unsupported_file_paths.len(), 1);
        assert!(session.unsupported_file_paths[0].ends_with("desktop.ini"));
    }

    #[test]
    fn scan_source_excludes_internal_review_folders() {
        let root = temp_dir("internal-review");
        let review = root.join("_security_review").join("suspicious");
        let audit = root.join("_source_audit");
        let takeout = root.join("_takeout_review");
        fs::create_dir_all(&review).expect("review dir");
        fs::create_dir_all(&audit).expect("audit dir");
        fs::create_dir_all(&takeout).expect("takeout dir");
        fs::write(root.join("real.jpg"), b"image").expect("write real image");
        fs::write(review.join("quarantined.jpg"), b"html-not-image").expect("write review image");
        fs::write(audit.join("archive_browser.html"), b"<html>").expect("write audit html");
        fs::write(takeout.join("duplicate.jpg"), b"duplicate").expect("write takeout image");

        let request = ScanImportSourceRequest {
            source_path: root.to_string_lossy().to_string(),
            source_kind: ImportSourceKind::Folder,
            recursive: true,
            import_mode: Some(ImportMode::Reference),
            add_as_watch_folder: false,
            place_hint: None,
        };

        let session = scan_source(&request, ImportMode::Reference, None, |_| None)
            .expect("scan should succeed");
        assert_eq!(session.candidates.len(), 1);
        assert_eq!(session.candidates[0].original_filename, "real.jpg");
        assert!(session.unsupported_file_paths.is_empty());
    }

    #[test]
    fn scan_source_attaches_takeout_sidecar_by_unique_title() {
        let root = temp_dir("takeout-title");
        let json_dir = root.join("json");
        fs::create_dir_all(&json_dir).expect("json dir");
        fs::write(root.join("a.jpg"), b"image").expect("write image");
        fs::write(
            json_dir.join("takeout-renamed-sidecar.json"),
            r#"{
              "title": "a.jpg",
              "photoTakenTime": {"timestamp": "1735689600"},
              "geoData": {"latitude": 15.2993, "longitude": 74.1240}
            }"#,
        )
        .expect("write sidecar");

        let request = ScanImportSourceRequest {
            source_path: root.to_string_lossy().to_string(),
            source_kind: ImportSourceKind::Folder,
            recursive: true,
            import_mode: Some(ImportMode::Move),
            add_as_watch_folder: false,
            place_hint: None,
        };

        let session =
            scan_source(&request, ImportMode::Move, None, |_| None).expect("scan should succeed");
        assert_eq!(session.candidates.len(), 1);
        assert_eq!(session.candidates[0].sidecar_paths.len(), 1);
        assert!(session.candidates[0].sidecar_paths[0].ends_with("takeout-renamed-sidecar.json"));
    }

    #[test]
    fn scan_source_does_not_attach_takeout_title_when_media_name_is_ambiguous() {
        let root = temp_dir("takeout-title-ambiguous");
        let one = root.join("one");
        let two = root.join("two");
        let json_dir = root.join("json");
        fs::create_dir_all(&one).expect("one dir");
        fs::create_dir_all(&two).expect("two dir");
        fs::create_dir_all(&json_dir).expect("json dir");
        fs::write(one.join("a.jpg"), b"image one").expect("write image one");
        fs::write(two.join("a.jpg"), b"image two").expect("write image two");
        fs::write(
            json_dir.join("takeout-renamed-sidecar.json"),
            r#"{
              "title": "a.jpg",
              "photoTakenTime": {"timestamp": "1735689600"}
            }"#,
        )
        .expect("write sidecar");

        let request = ScanImportSourceRequest {
            source_path: root.to_string_lossy().to_string(),
            source_kind: ImportSourceKind::Folder,
            recursive: true,
            import_mode: Some(ImportMode::Move),
            add_as_watch_folder: false,
            place_hint: None,
        };

        let session =
            scan_source(&request, ImportMode::Move, None, |_| None).expect("scan should succeed");
        assert_eq!(session.candidates.len(), 2);
        assert!(
            session
                .candidates
                .iter()
                .all(|candidate| candidate.sidecar_paths.is_empty())
        );
    }

    #[test]
    fn collects_unsupported_files_without_json_sidecars() {
        let root = temp_dir("unsupported");
        fs::write(root.join("a.jpg"), b"image").expect("write image");
        fs::write(root.join("a.jpg.json"), b"{}").expect("write sidecar");
        fs::write(root.join("shortcut.lnk"), b"shortcut").expect("write unsupported");

        let files = collect_unsupported_files(&root, true, &[]).expect("scan should succeed");
        assert_eq!(files.len(), 1);
        assert!(files[0].ends_with("shortcut.lnk"));
    }
}
