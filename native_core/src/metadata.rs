use std::{
    fs,
    path::{Path, PathBuf},
};

use chrono::{DateTime, FixedOffset, TimeZone, Utc};
use nom_exif::{
    EntryValue, ExifDateTime, ExifTag, Metadata as NomMetadata, TrackInfoTag, read_metadata,
};
use serde_json::Value;
use uuid::Uuid;

use crate::domain::{
    AssetMetadata, CameraInfo, FileOrganizationHints, GeoTag, MetadataSource, ModelProvenance,
};

#[derive(Debug, Clone)]
pub struct ExtractedMediaMetadata {
    pub captured_at: DateTime<Utc>,
    pub captured_at_source: MetadataSource,
    pub timezone_offset_minutes: Option<i32>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub camera: Option<CameraInfo>,
    pub geo: Option<GeoTag>,
    pub sidecar_title: Option<String>,
    pub sidecar_description: Option<String>,
    pub folder_hint: Option<String>,
    pub organization: FileOrganizationHints,
}

impl ExtractedMediaMetadata {
    pub fn into_asset_metadata(self, asset_id: Uuid) -> AssetMetadata {
        AssetMetadata {
            asset_id,
            captured_at: self.captured_at,
            captured_at_source: self.captured_at_source,
            timezone_offset_minutes: self.timezone_offset_minutes,
            width: self.width,
            height: self.height,
            camera: self.camera,
            geo: self.geo,
            sidecar_title: self.sidecar_title,
            sidecar_description: self.sidecar_description,
            folder_hint: self.folder_hint,
            organization: self.organization,
            derived: ModelProvenance::local("metadata-extractor", "v1"),
        }
    }
}

#[derive(Debug, Clone, Default)]
struct PartialMetadata {
    captured_at: Option<(DateTime<Utc>, MetadataSource, Option<i32>)>,
    width: Option<u32>,
    height: Option<u32>,
    camera: Option<CameraInfo>,
    geo: Option<GeoTag>,
    sidecar_title: Option<String>,
    sidecar_description: Option<String>,
}

pub fn extract_media_metadata(
    media_path: &Path,
    sidecar_paths: &[String],
    filesystem_captured_at: DateTime<Utc>,
) -> ExtractedMediaMetadata {
    let mut embedded = parse_embedded_metadata(media_path).unwrap_or_default();
    let sidecar = parse_sidecar_metadata(sidecar_paths).unwrap_or_default();

    let captured_at = sidecar.captured_at.or(embedded.captured_at).unwrap_or((
        filesystem_captured_at,
        MetadataSource::Filesystem,
        None,
    ));

    if sidecar.width.is_some() {
        embedded.width = sidecar.width;
    }
    if sidecar.height.is_some() {
        embedded.height = sidecar.height;
    }

    let organization = derive_file_organization_hints(media_path, None);
    ExtractedMediaMetadata {
        captured_at: captured_at.0,
        captured_at_source: captured_at.1,
        timezone_offset_minutes: captured_at.2,
        width: embedded.width.or(sidecar.width),
        height: embedded.height.or(sidecar.height),
        camera: merge_camera(embedded.camera, sidecar.camera),
        geo: sidecar.geo.or(embedded.geo),
        sidecar_title: sidecar.sidecar_title,
        sidecar_description: sidecar.sidecar_description,
        folder_hint: media_path
            .parent()
            .and_then(Path::file_name)
            .map(|value| value.to_string_lossy().to_string())
            .filter(|value| !value.trim().is_empty()),
        organization,
    }
}

pub fn extract_import_metadata(
    media_path: &Path,
    sidecar_paths: &[String],
    filesystem_captured_at: DateTime<Utc>,
) -> ExtractedMediaMetadata {
    let sidecar = parse_sidecar_metadata(sidecar_paths).unwrap_or_default();
    let captured_at =
        sidecar
            .captured_at
            .unwrap_or((filesystem_captured_at, MetadataSource::Filesystem, None));

    let organization = derive_file_organization_hints(media_path, None);
    ExtractedMediaMetadata {
        captured_at: captured_at.0,
        captured_at_source: captured_at.1,
        timezone_offset_minutes: captured_at.2,
        width: sidecar.width,
        height: sidecar.height,
        camera: sidecar.camera,
        geo: sidecar.geo,
        sidecar_title: sidecar.sidecar_title,
        sidecar_description: sidecar.sidecar_description,
        folder_hint: media_path
            .parent()
            .and_then(Path::file_name)
            .map(|value| value.to_string_lossy().to_string())
            .filter(|value| !value.trim().is_empty()),
        organization,
    }
}

pub fn derive_file_organization_hints(
    file_path: &Path,
    source_root: Option<&Path>,
) -> FileOrganizationHints {
    let parent = file_path.parent();
    let source_folder = parent
        .and_then(Path::file_name)
        .map(clean_path_segment)
        .filter(|value| !value.is_empty());
    let path_segments = parent
        .and_then(|parent| source_root.and_then(|root| relative_parent_segments(parent, root)))
        .unwrap_or_else(|| source_folder.iter().cloned().collect::<Vec<_>>());

    let workspace = find_labeled_segment(&path_segments, &["workspace", "ws"])
        .or_else(|| fallback_segment(&path_segments, 3, 0));
    let client = find_labeled_segment(&path_segments, &["client", "customer"])
        .or_else(|| fallback_segment(&path_segments, 3, 1))
        .or_else(|| fallback_segment(&path_segments, 2, 0));
    let project = find_labeled_segment(&path_segments, &["project", "proj"])
        .or_else(|| fallback_segment(&path_segments, 3, 2))
        .or_else(|| fallback_segment(&path_segments, 2, 1))
        .or_else(|| fallback_segment(&path_segments, 1, 0));
    let topic = path_segments
        .last()
        .cloned()
        .or_else(|| source_folder.clone());

    FileOrganizationHints {
        source_folder,
        workspace,
        client,
        project,
        topic,
        path_segments,
    }
}

fn relative_parent_segments(parent: &Path, source_root: &Path) -> Option<Vec<String>> {
    let relative_parent = parent.strip_prefix(source_root).ok()?;
    let segments = relative_parent
        .components()
        .filter_map(|component| match component {
            std::path::Component::Normal(value) => Some(clean_path_segment(value)),
            _ => None,
        })
        .filter(|value| !value.is_empty())
        .collect::<Vec<_>>();
    if segments.is_empty() {
        None
    } else {
        Some(segments)
    }
}

fn clean_path_segment(value: impl AsRef<std::ffi::OsStr>) -> String {
    value
        .as_ref()
        .to_string_lossy()
        .trim()
        .trim_matches(&['/', '\\'][..])
        .to_string()
}

fn find_labeled_segment(segments: &[String], labels: &[&str]) -> Option<String> {
    for segment in segments {
        let lower = segment.to_ascii_lowercase();
        for label in labels {
            for separator in [" ", "-", "_", ":"] {
                let prefix = format!("{label}{separator}");
                if lower.starts_with(&prefix) {
                    let value = segment[prefix.len()..]
                        .trim_matches(&[' ', '-', '_', ':'][..])
                        .trim();
                    if !value.is_empty() {
                        return Some(value.to_string());
                    }
                }
            }
        }
    }
    None
}

fn fallback_segment(segments: &[String], len: usize, index: usize) -> Option<String> {
    if segments.len() == len {
        segments.get(index).cloned()
    } else {
        None
    }
}

pub fn coarse_place_label(metadata: &ExtractedMediaMetadata) -> Option<String> {
    metadata.geo.as_ref().map(|geo| {
        format!(
            "GPS {:.2}, {:.2}",
            round_coord(geo.latitude),
            round_coord(geo.longitude)
        )
    })
}

pub fn coarse_place_label_for_asset(metadata: &AssetMetadata) -> Option<String> {
    metadata.geo.as_ref().map(|geo| {
        format!(
            "GPS {:.2}, {:.2}",
            round_coord(geo.latitude),
            round_coord(geo.longitude)
        )
    })
}

fn round_coord(value: f64) -> f64 {
    (value * 100.0).round() / 100.0
}

fn merge_camera(embedded: Option<CameraInfo>, sidecar: Option<CameraInfo>) -> Option<CameraInfo> {
    match (embedded, sidecar) {
        (Some(mut embedded), Some(sidecar)) => {
            embedded.make = sidecar.make.or(embedded.make);
            embedded.model = sidecar.model.or(embedded.model);
            embedded.lens_model = sidecar.lens_model.or(embedded.lens_model);
            Some(embedded)
        }
        (embedded, sidecar) => sidecar.or(embedded),
    }
}

fn parse_embedded_metadata(path: &Path) -> Option<PartialMetadata> {
    match read_metadata(path).ok()? {
        NomMetadata::Exif(exif) => {
            let captured_at = exif
                .get(ExifTag::DateTimeOriginal)
                .and_then(EntryValue::as_datetime)
                .map(|value| datetime_to_utc(value, MetadataSource::Embedded));
            let camera = camera_info(
                text_value(exif.get(ExifTag::Make)),
                text_value(exif.get(ExifTag::Model)),
                text_value(exif.get(ExifTag::LensModel)),
            );
            let geo = exif.gps_info().and_then(|gps| {
                Some(GeoTag {
                    latitude: gps.latitude_decimal()?,
                    longitude: gps.longitude_decimal()?,
                    altitude_meters: gps.altitude_meters(),
                    source: MetadataSource::Embedded,
                    exact_hidden: false,
                })
            });
            Some(PartialMetadata {
                captured_at,
                width: u32_value(
                    exif.get(ExifTag::ExifImageWidth)
                        .or_else(|| exif.get(ExifTag::ImageWidth)),
                ),
                height: u32_value(
                    exif.get(ExifTag::ExifImageHeight)
                        .or_else(|| exif.get(ExifTag::ImageHeight)),
                ),
                camera,
                geo,
                ..PartialMetadata::default()
            })
        }
        NomMetadata::Track(track) => {
            let captured_at = track
                .get(TrackInfoTag::CreateDate)
                .and_then(EntryValue::as_datetime)
                .map(|value| datetime_to_utc(value, MetadataSource::Embedded));
            let camera = camera_info(
                text_value(track.get(TrackInfoTag::Make)),
                text_value(track.get(TrackInfoTag::Model)),
                None,
            );
            let geo = track.gps_info().and_then(|gps| {
                Some(GeoTag {
                    latitude: gps.latitude_decimal()?,
                    longitude: gps.longitude_decimal()?,
                    altitude_meters: gps.altitude_meters(),
                    source: MetadataSource::Embedded,
                    exact_hidden: false,
                })
            });
            Some(PartialMetadata {
                captured_at,
                width: u32_value(track.get(TrackInfoTag::Width)),
                height: u32_value(track.get(TrackInfoTag::Height)),
                camera,
                geo,
                ..PartialMetadata::default()
            })
        }
    }
}

fn parse_sidecar_metadata(sidecar_paths: &[String]) -> Option<PartialMetadata> {
    let mut merged = PartialMetadata::default();
    for path in sidecar_paths.iter().map(PathBuf::from) {
        let Ok(raw) = fs::read_to_string(&path) else {
            continue;
        };
        let Ok(json) = serde_json::from_str::<Value>(&raw) else {
            continue;
        };

        if merged.captured_at.is_none() {
            merged.captured_at =
                takeout_timestamp(&json).map(|value| (value, MetadataSource::TakeoutSidecar, None));
        }
        if merged.geo.is_none() {
            merged.geo = takeout_geo(&json);
        }
        if merged.sidecar_title.is_none() {
            merged.sidecar_title = json
                .get("title")
                .and_then(Value::as_str)
                .map(ToString::to_string);
        }
        if merged.sidecar_description.is_none() {
            merged.sidecar_description = json
                .get("description")
                .or_else(|| json.get("imageViews"))
                .and_then(Value::as_str)
                .map(ToString::to_string);
        }
    }

    Some(merged)
}

fn datetime_to_utc(
    value: ExifDateTime,
    source: MetadataSource,
) -> (DateTime<Utc>, MetadataSource, Option<i32>) {
    match value {
        ExifDateTime::Aware(value) => (
            value.with_timezone(&Utc),
            source,
            Some(value.offset().local_minus_utc() / 60),
        ),
        ExifDateTime::Naive(value) => (value.and_utc(), source, None),
    }
}

fn takeout_timestamp(json: &Value) -> Option<DateTime<Utc>> {
    for path in [
        &["photoTakenTime", "timestamp"][..],
        &["creationTime", "timestamp"][..],
        &["modificationTime", "timestamp"][..],
    ] {
        let mut cursor = json;
        for key in path {
            cursor = cursor.get(*key)?;
        }
        if let Some(timestamp) = cursor.as_str().and_then(|value| value.parse::<i64>().ok())
            && let Some(value) = Utc.timestamp_opt(timestamp, 0).single()
        {
            return Some(value);
        }
        if let Some(timestamp) = cursor.as_i64()
            && let Some(value) = Utc.timestamp_opt(timestamp, 0).single()
        {
            return Some(value);
        }
    }
    None
}

fn takeout_geo(json: &Value) -> Option<GeoTag> {
    for key in ["geoData", "geoDataExif"] {
        let Some(geo) = json.get(key) else {
            continue;
        };
        let latitude = geo.get("latitude").and_then(Value::as_f64).unwrap_or(0.0);
        let longitude = geo.get("longitude").and_then(Value::as_f64).unwrap_or(0.0);
        if latitude == 0.0 && longitude == 0.0 {
            continue;
        }
        return Some(GeoTag {
            latitude,
            longitude,
            altitude_meters: geo.get("altitude").and_then(Value::as_f64),
            source: MetadataSource::TakeoutSidecar,
            exact_hidden: false,
        });
    }
    None
}

fn text_value(value: Option<&EntryValue>) -> Option<String> {
    value
        .and_then(EntryValue::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
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

fn u32_value(value: Option<&EntryValue>) -> Option<u32> {
    match value? {
        EntryValue::U8(value) => Some(*value as u32),
        EntryValue::U16(value) => Some(*value as u32),
        EntryValue::U32(value) => Some(*value),
        EntryValue::U64(value) => u32::try_from(*value).ok(),
        EntryValue::I8(value) => u32::try_from(*value).ok(),
        EntryValue::I16(value) => u32::try_from(*value).ok(),
        EntryValue::I32(value) => u32::try_from(*value).ok(),
        EntryValue::I64(value) => u32::try_from(*value).ok(),
        _ => None,
    }
}

#[allow(dead_code)]
fn fixed_offset_minutes(offset: FixedOffset) -> i32 {
    offset.local_minus_utc() / 60
}

#[cfg(test)]
mod tests {
    use std::fs;

    use chrono::{TimeZone, Utc};

    use super::{
        derive_file_organization_hints, extract_import_metadata, extract_media_metadata,
        takeout_timestamp,
    };

    #[test]
    fn parses_takeout_timestamp_and_geo_sidecar() {
        let root = std::env::temp_dir().join(format!(
            "private-gallery-metadata-{}",
            Utc::now().timestamp_nanos_opt().unwrap_or_default()
        ));
        fs::create_dir_all(&root).expect("temp dir");
        let media = root.join("a.jpg");
        let sidecar = root.join("a.jpg.json");
        fs::write(&media, b"not-real-jpeg").expect("media");
        fs::write(
            &sidecar,
            r#"{
              "title": "Beach day",
              "description": "Family trip",
              "photoTakenTime": {"timestamp": "1735689600"},
              "geoData": {"latitude": 15.2993, "longitude": 74.1240, "altitude": 8.0}
            }"#,
        )
        .expect("sidecar");

        let extracted = extract_media_metadata(
            &media,
            &[sidecar.to_string_lossy().to_string()],
            Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap(),
        );

        assert_eq!(
            extracted.captured_at,
            Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap()
        );
        assert_eq!(extracted.sidecar_title.as_deref(), Some("Beach day"));
        assert!(extracted.geo.is_some());
    }

    #[test]
    fn ignores_empty_takeout_gps() {
        let json = serde_json::json!({
            "photoTakenTime": {"timestamp": "1735689600"},
            "geoData": {"latitude": 0.0, "longitude": 0.0}
        });

        assert_eq!(
            takeout_timestamp(&json),
            Some(Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap())
        );
    }

    #[test]
    fn derives_local_file_organization_hints_from_relative_path() {
        let root = std::env::temp_dir().join(format!(
            "private-gallery-org-hints-{}",
            Utc::now().timestamp_nanos_opt().unwrap_or_default()
        ));
        let file = root
            .join("Office")
            .join("Client Acme")
            .join("Project Launch")
            .join("proposal.pdf");
        fs::create_dir_all(file.parent().expect("parent")).expect("folders");
        fs::write(&file, b"pdf").expect("file");

        let hints = derive_file_organization_hints(&file, Some(&root));

        assert_eq!(hints.source_folder.as_deref(), Some("Project Launch"));
        assert_eq!(hints.workspace.as_deref(), Some("Office"));
        assert_eq!(hints.client.as_deref(), Some("Acme"));
        assert_eq!(hints.project.as_deref(), Some("Launch"));
        assert_eq!(hints.topic.as_deref(), Some("Project Launch"));
        assert_eq!(
            hints.path_segments,
            vec![
                "Office".to_string(),
                "Client Acme".to_string(),
                "Project Launch".to_string()
            ]
        );
    }

    #[test]
    fn import_metadata_has_folder_hints_without_hosted_services() {
        let root = std::env::temp_dir().join(format!(
            "private-gallery-import-org-{}",
            Utc::now().timestamp_nanos_opt().unwrap_or_default()
        ));
        let file = root.join("project-renewal").join("notes.md");
        fs::create_dir_all(file.parent().expect("parent")).expect("folders");
        fs::write(&file, b"notes").expect("file");

        let extracted = extract_import_metadata(
            &file,
            &[],
            Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap(),
        );

        assert_eq!(extracted.folder_hint.as_deref(), Some("project-renewal"));
        assert_eq!(extracted.organization.project.as_deref(), Some("renewal"));
    }
}
