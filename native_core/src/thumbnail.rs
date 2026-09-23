use std::{
    fs,
    path::{Path, PathBuf},
    time::UNIX_EPOCH,
};

use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::{config::AppConfig, domain::Asset};

pub const THUMB_MAX_DIMENSION: u32 = 256;
pub const THUMB_QUALITY: u8 = 80;
pub const THUMB_MIME_TYPE: &str = "image/jpeg";
pub const THUMB_EXTENSION: &str = "jpg";

/// Cache location for derived thumbnails, shared across libraries of one runtime.
pub fn thumbnail_dir(config: &AppConfig) -> PathBuf {
    config.runtime_root.join("thumbnails")
}

/// Deterministic path for the thumbnail of `asset` given the original's current
/// metadata. The filename embeds a digest of the asset id plus original mtime and
/// length, so a changed original naturally points at a fresh cache entry.
fn thumbnail_path_for_meta(config: &AppConfig, asset: &Asset, meta: &fs::Metadata) -> PathBuf {
    let digest = source_fingerprint(asset.id, meta);
    thumbnail_dir(config).join(format!(
        "{}.{}.{}",
        asset.id,
        &digest[..24],
        THUMB_EXTENSION
    ))
}

fn source_fingerprint(asset_id: Uuid, meta: &fs::Metadata) -> String {
    let (mtime_secs, mtime_nanos) = meta
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|duration| (duration.as_secs(), duration.subsec_nanos()))
        .unwrap_or((0, 0));
    let mut hasher = Sha256::new();
    hasher.update(asset_id.to_string().as_bytes());
    hasher.update(b":");
    hasher.update(mtime_secs.to_string().as_bytes());
    hasher.update(b":");
    hasher.update(mtime_nanos.to_string().as_bytes());
    hasher.update(b":");
    hasher.update(meta.len().to_string().as_bytes());
    let digest = hasher.finalize();
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn asset_prefix(asset_id: Uuid) -> String {
    format!("{asset_id}.")
}

/// Returns the cached thumbnail path when one is available, either at the
/// fingerprint-consistent location (the source is reachable and unchanged) or a
/// previously generated file for this asset when the exact fingerprint cannot be
/// recomputed (for example the original has been moved into an encrypted vault).
pub fn cached_thumbnail_path(
    config: &AppConfig,
    asset: &Asset,
    source_path: &Path,
) -> Option<PathBuf> {
    if let Ok(meta) = fs::metadata(source_path) {
        let path = thumbnail_path_for_meta(config, asset, &meta);
        if path.is_file() {
            return Some(path);
        }
    }
    lookup_by_asset_id(config, asset.id)
}

/// Whether the asset currently has a thumbnail matching its source fingerprint.
pub fn has_current_thumbnail(config: &AppConfig, asset: &Asset, source_path: &Path) -> bool {
    fs::metadata(source_path)
        .map(|meta| thumbnail_path_for_meta(config, asset, &meta).is_file())
        .unwrap_or(false)
}

/// Decodes a still photo and writes a small JPEG into the thumbnail cache.
/// Returns the cache path, reusing an existing current thumbnail when present.
pub fn generate_thumbnail(
    config: &AppConfig,
    asset: &Asset,
    source_path: &Path,
) -> Result<PathBuf, String> {
    let meta = fs::metadata(source_path)
        .map_err(|err| format!("stat {}: {err}", source_path.display()))?;
    let destination = thumbnail_path_for_meta(config, asset, &meta);
    if destination.is_file() {
        return Ok(destination);
    }
    if !source_path.is_file() {
        return Err(format!(
            "{} is not a readable file",
            source_path.to_string_lossy()
        ));
    }

    let decoded = image::open(source_path)
        .map_err(|err| format!("decode {}: {err}", source_path.to_string_lossy()))?;
    let thumbnail = decoded.thumbnail(THUMB_MAX_DIMENSION, THUMB_MAX_DIMENSION);
    let mut bytes = Vec::new();
    let encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut bytes, THUMB_QUALITY);
    thumbnail.write_with_encoder(encoder).map_err(|err| {
        format!(
            "encode thumbnail for {}: {err}",
            source_path.to_string_lossy()
        )
    })?;

    let dir = thumbnail_dir(config);
    fs::create_dir_all(&dir).map_err(|err| format!("create thumbnail cache: {err}"))?;
    let tmp = dir.join(format!(
        ".{}.{}.{}.tmp",
        asset.id,
        std::process::id(),
        Uuid::new_v4()
    ));
    fs::write(&tmp, &bytes).map_err(|err| format!("write thumbnail temp: {err}"))?;
    fs::rename(&tmp, &destination).map_err(|err| {
        let _ = fs::remove_file(&tmp);
        format!("commit thumbnail cache entry: {err}")
    })?;
    Ok(destination)
}

fn lookup_by_asset_id(config: &AppConfig, asset_id: Uuid) -> Option<PathBuf> {
    let dir = thumbnail_dir(config);
    if !dir.is_dir() {
        return None;
    }
    let prefix = asset_prefix(asset_id);
    fs::read_dir(dir)
        .ok()?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .find(|path| {
            path.is_file()
                && path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.starts_with(&prefix))
        })
}

#[cfg(test)]
mod tests {
    use std::{fs, path::PathBuf};

    use chrono::Utc;
    use uuid::Uuid;

    use crate::{
        domain::{ImportAssetRequest, ImportMode, MediaKind},
        imports,
    };

    use super::{
        THUMB_MAX_DIMENSION, cached_thumbnail_path, generate_thumbnail, has_current_thumbnail,
        thumbnail_dir,
    };
    use image::GenericImageView;

    fn temp_root(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "private-gallery-thumbnail-{name}-{}",
            Utc::now().timestamp_nanos_opt().unwrap_or_default()
        ));
        fs::create_dir_all(&root).expect("create temp root");
        root
    }

    fn write_ppm(path: &std::path::Path, width: u32, height: u32) {
        let mut bytes = format!("P6\n{width} {height}\n255\n").into_bytes();
        for y in 0..height {
            for x in 0..width {
                bytes.extend_from_slice(&[
                    ((x * 255) / width.max(1)) as u8,
                    ((y * 255) / height.max(1)) as u8,
                    40u8,
                ]);
            }
        }
        fs::write(path, bytes).expect("write PPM fixture");
    }

    fn photo_asset(source_path: &std::path::Path) -> crate::domain::Asset {
        let (asset, _) = imports::build_imported_asset(ImportAssetRequest {
            source_path: source_path.to_string_lossy().to_string(),
            original_filename: source_path
                .file_name()
                .map(|name| name.to_string_lossy().to_string())
                .unwrap_or_else(|| "photo.jpg".to_string()),
            media_kind: MediaKind::Photo,
            mime_type: "image/jpeg".to_string(),
            bytes: 64,
            content_hash: None,
            captured_at: None,
            place_hint: None,
            import_mode: Some(ImportMode::Reference),
        });
        asset
    }

    fn config(root: &std::path::Path) -> crate::config::AppConfig {
        crate::config::AppConfig {
            runtime_root: root.to_path_buf(),
            ..crate::config::AppConfig::default()
        }
    }

    #[test]
    fn generates_small_jpeg_thumbnail_from_synthetic_image() {
        let root = temp_root("generate");
        let source = root.join("wide.ppm");
        write_ppm(&source, 1200, 800);
        let asset = photo_asset(&source);
        let config = config(&root);

        let dest = generate_thumbnail(&config, &asset, &source).expect("generate");

        assert_eq!(
            dest.parent(),
            Some(thumbnail_dir(&config).as_path()),
            "thumbnail lives under runtime_root/thumbnails"
        );
        let bytes = fs::read(&dest).expect("read thumbnail");
        assert!(bytes.starts_with(&[0xFF, 0xD8]), "JPEG magic bytes");
        let decoded = image::open(&dest).expect("decode generated thumbnail");
        assert!(
            decoded.dimensions().0 <= THUMB_MAX_DIMENSION,
            "longest side capped at max dimension"
        );
        assert!(
            decoded.dimensions().1 <= THUMB_MAX_DIMENSION,
            "longest side capped at max dimension"
        );
        assert_eq!(
            decoded.dimensions(),
            (THUMB_MAX_DIMENSION, (THUMB_MAX_DIMENSION * 2) / 3),
            "aspect ratio is preserved for a 3:2 source"
        );
        assert_eq!(
            image::guess_format(&bytes).expect("format"),
            image::ImageFormat::Jpeg
        );
    }

    #[test]
    fn cache_hit_reuses_existing_file_without_rewriting() {
        let root = temp_root("cache-hit");
        let source = root.join("photo.ppm");
        write_ppm(&source, 640, 480);
        let asset = photo_asset(&source);
        let config = config(&root);

        let first = generate_thumbnail(&config, &asset, &source).expect("first generate");
        let first_bytes = fs::read(&first).expect("read first");
        let first_hits = fs::metadata(&first).expect("first metadata");
        let first_length = first_hits.len();
        let first_mtime = first_hits.modified().expect("first modified");

        let second = generate_thumbnail(&config, &asset, &source).expect("second generate");

        assert_eq!(second, first, "same cache entry reused");
        assert_eq!(
            fs::metadata(&second).expect("second metadata").len(),
            first_length
        );
        assert_eq!(fs::read(&second).expect("read second"), first_bytes);
        assert_eq!(
            fs::metadata(&second)
                .expect("second metadata")
                .modified()
                .expect("second modified"),
            first_mtime,
            "shared entry was not rewritten"
        );
    }

    #[test]
    fn source_change_produces_a_fresh_cache_entry() {
        let root = temp_root("staleness");
        let source = root.join("photo.ppm");
        write_ppm(&source, 640, 480);
        let asset = photo_asset(&source);
        let config = config(&root);

        let first = generate_thumbnail(&config, &asset, &source).expect("first generate");

        use std::io::Write;
        fs::OpenOptions::new()
            .append(true)
            .open(&source)
            .expect("open source")
            .write_all(b"\n")
            .expect("grow source");

        let second = generate_thumbnail(&config, &asset, &source).expect("second generate");

        assert_ne!(
            second, first,
            "changed original gets a distinct cache entry"
        );
        assert!(
            fs::metadata(&first).is_ok(),
            "prior entry is left untouched"
        );
        let third = generate_thumbnail(&config, &asset, &source).expect("third generate");
        assert_eq!(third, second, "second entry is now the current one");
    }

    #[test]
    fn cached_path_falls_back_to_scan_when_original_is_unreachable() {
        let root = temp_root("scan-fallback");
        let source = root.join("photo.ppm");
        write_ppm(&source, 640, 480);
        let asset = photo_asset(&source);
        let config = config(&root);

        let dest = generate_thumbnail(&config, &asset, &source).expect("generate");

        fs::remove_file(&source).expect("evict original");

        assert!(!has_current_thumbnail(&config, &asset, &source));
        assert_eq!(
            cached_thumbnail_path(&config, &asset, &source).as_deref(),
            Some(dest.as_path()),
            "serves the cached entry once the original is unreachable"
        );
    }
}
