use crate::domain::{
    Asset, EventCluster, MediaKind, OcrBlock, PersonCluster, PlaceCluster, SceneTag, SearchQuery,
    SearchResponse,
};
use chrono::{DateTime, NaiveDate, Utc};
use std::collections::BTreeSet;

pub fn search_library(
    query: SearchQuery,
    assets: &[Asset],
    people: &[PersonCluster],
    places: &[PlaceCluster],
    events: &[EventCluster],
    ocr_blocks: &[OcrBlock],
    scene_tags: &[SceneTag],
) -> SearchResponse {
    let mut matched_assets: Vec<Asset> = assets
        .iter()
        .filter(|asset| query.include_archived || !asset.archived)
        .cloned()
        .collect();

    if let Some(favorite) = query.favorite {
        matched_assets.retain(|asset| asset.favorite == favorite);
    }

    if let Some(media_kind_filter) = query
        .media_kind
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        matched_assets
            .retain(|asset| media_kind_matches_filter(&asset.media_kind, media_kind_filter));
    }

    if let Some(from_date) = query.from_date.as_deref().and_then(parse_filter_date_start) {
        matched_assets.retain(|asset| asset.captured_at >= from_date);
    }

    if let Some(to_date) = query.to_date.as_deref().and_then(parse_filter_date_end) {
        matched_assets.retain(|asset| asset.captured_at <= to_date);
    }

    if let Some(people_filter) = query
        .people
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
    {
        let person_asset_ids = people_filter_asset_ids(people_filter, people);
        matched_assets.retain(|asset| person_asset_ids.contains(&asset.id));
    }

    if let Some(places_filter) = query
        .places
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
    {
        let place_asset_ids = place_filter_asset_ids(places_filter, places);
        matched_assets.retain(|asset| {
            place_asset_ids.contains(&asset.id)
                || asset
                    .place_hint
                    .as_ref()
                    .map(|hint| text_matches_filter(hint, places_filter))
                    .unwrap_or(false)
                || asset
                    .metadata
                    .as_ref()
                    .and_then(|metadata| metadata.folder_hint.as_ref())
                    .map(|hint| text_matches_filter(hint, places_filter))
                    .unwrap_or(false)
        });
    }

    if let Some(events_filter) = query
        .events
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
    {
        let event_asset_ids = event_filter_asset_ids(events_filter, events);
        matched_assets.retain(|asset| event_asset_ids.contains(&asset.id));
    }

    if let Some(text) = query.text.as_deref() {
        let lower = text.to_lowercase();
        let ocr_asset_ids = ocr_blocks
            .iter()
            .filter(|block| block.text.to_lowercase().contains(&lower))
            .map(|block| block.asset_id)
            .collect::<BTreeSet<_>>();
        let person_asset_ids = people
            .iter()
            .filter(|person| !person.hidden && person.display_name.to_lowercase().contains(&lower))
            .flat_map(|person| person.asset_ids.iter().copied())
            .collect::<BTreeSet<_>>();
        let place_asset_ids = places
            .iter()
            .filter(|place| {
                place.label.to_lowercase().contains(&lower)
                    || place
                        .region
                        .as_ref()
                        .map(|region| region.to_lowercase().contains(&lower))
                        .unwrap_or(false)
                    || place
                        .country_code
                        .as_ref()
                        .map(|country| country.to_lowercase().contains(&lower))
                        .unwrap_or(false)
            })
            .flat_map(|place| place.asset_ids.iter().copied())
            .collect::<BTreeSet<_>>();
        let event_asset_ids = events
            .iter()
            .filter(|event| event.title.to_lowercase().contains(&lower))
            .flat_map(|event| event.asset_ids.iter().copied())
            .collect::<BTreeSet<_>>();
        let scene_asset_ids = scene_tags
            .iter()
            .filter(|tag| tag.label.replace('_', " ").to_lowercase().contains(&lower))
            .map(|tag| tag.asset_id)
            .collect::<BTreeSet<_>>();
        matched_assets.retain(|asset| {
            asset.original_filename.to_lowercase().contains(&lower)
                || format!("{:?}", asset.media_kind)
                    .to_lowercase()
                    .contains(&lower)
                || asset
                    .place_hint
                    .as_ref()
                    .map(|hint| hint.to_lowercase().contains(&lower))
                    .unwrap_or(false)
                || asset
                    .metadata
                    .as_ref()
                    .map(|metadata| metadata_matches_text(metadata, &lower))
                    .unwrap_or(false)
                || ocr_asset_ids.contains(&asset.id)
                || person_asset_ids.contains(&asset.id)
                || place_asset_ids.contains(&asset.id)
                || event_asset_ids.contains(&asset.id)
                || scene_asset_ids.contains(&asset.id)
        });
    }

    let matched_asset_ids: BTreeSet<_> = matched_assets.iter().map(|asset| asset.id).collect();

    let people = people
        .iter()
        .filter(|person| !person.hidden)
        .filter(|person| {
            person
                .asset_ids
                .iter()
                .any(|id| matched_asset_ids.contains(id))
        })
        .cloned()
        .collect();

    let places = places
        .iter()
        .filter(|place| {
            place
                .asset_ids
                .iter()
                .any(|id| matched_asset_ids.contains(id))
        })
        .cloned()
        .collect();

    let events = events
        .iter()
        .filter(|event| {
            event
                .asset_ids
                .iter()
                .any(|id| matched_asset_ids.contains(id))
        })
        .cloned()
        .collect();

    let limit = query.limit.unwrap_or(50);
    matched_assets.truncate(limit);

    SearchResponse {
        query,
        assets: matched_assets,
        people,
        places,
        events,
    }
}

fn parse_filter_date_start(value: &str) -> Option<DateTime<Utc>> {
    parse_filter_date(value, false)
}

fn parse_filter_date_end(value: &str) -> Option<DateTime<Utc>> {
    parse_filter_date(value, true)
}

fn parse_filter_date(value: &str, end_of_day: bool) -> Option<DateTime<Utc>> {
    let value = value.trim();
    if value.is_empty() {
        return None;
    }
    if let Ok(date_time) = DateTime::parse_from_rfc3339(value) {
        return Some(date_time.with_timezone(&Utc));
    }
    let date = NaiveDate::parse_from_str(value, "%Y-%m-%d").ok()?;
    let naive = if end_of_day {
        date.and_hms_opt(23, 59, 59)?
    } else {
        date.and_hms_opt(0, 0, 0)?
    };
    Some(DateTime::from_naive_utc_and_offset(naive, Utc))
}

fn event_filter_asset_ids(filter: &str, events: &[EventCluster]) -> BTreeSet<uuid::Uuid> {
    events
        .iter()
        .filter(|event| event.id.to_string() == filter || text_matches_filter(&event.title, filter))
        .flat_map(|event| event.asset_ids.iter().copied())
        .collect()
}

fn media_kind_matches_filter(media_kind: &MediaKind, filter: &str) -> bool {
    filter
        .split(',')
        .map(str::trim)
        .filter(|part| !part.is_empty())
        .any(|part| match part.to_ascii_lowercase().as_str() {
            "photo" | "photos" | "image" | "images" => *media_kind == MediaKind::Photo,
            "video" | "videos" => *media_kind == MediaKind::Video,
            "document" | "documents" | "doc" | "docs" | "pdf" | "office" => {
                *media_kind == MediaKind::Document
            }
            "audio" | "music" | "sound" => *media_kind == MediaKind::Audio,
            "archive" | "archives" | "zip" | "compressed" => *media_kind == MediaKind::Archive,
            "text" | "notes" | "markdown" | "csv" => *media_kind == MediaKind::Text,
            "file" | "files" | "other" => *media_kind == MediaKind::Other,
            _ => format!("{media_kind:?}").eq_ignore_ascii_case(part),
        })
}

fn people_filter_asset_ids(filter: &str, people: &[PersonCluster]) -> BTreeSet<uuid::Uuid> {
    people
        .iter()
        .filter(|person| {
            !person.hidden
                && (person.id.to_string() == filter
                    || text_matches_filter(&person.display_name, filter))
        })
        .flat_map(|person| person.asset_ids.iter().copied())
        .collect()
}

fn place_filter_asset_ids(filter: &str, places: &[PlaceCluster]) -> BTreeSet<uuid::Uuid> {
    places
        .iter()
        .filter(|place| {
            place.id.to_string() == filter
                || text_matches_filter(&place.label, filter)
                || place
                    .region
                    .as_ref()
                    .map(|region| text_matches_filter(region, filter))
                    .unwrap_or(false)
                || place
                    .country_code
                    .as_ref()
                    .map(|country| text_matches_filter(country, filter))
                    .unwrap_or(false)
        })
        .flat_map(|place| place.asset_ids.iter().copied())
        .collect()
}

fn text_matches_filter(value: &str, filter: &str) -> bool {
    let value = value.to_lowercase();
    filter
        .split(',')
        .map(str::trim)
        .filter(|part| !part.is_empty())
        .any(|part| value.contains(&part.to_lowercase()) || value == part.to_lowercase())
}

fn metadata_matches_text(metadata: &crate::domain::AssetMetadata, lower: &str) -> bool {
    metadata
        .sidecar_title
        .as_ref()
        .map(|value| value.to_lowercase().contains(lower))
        .unwrap_or(false)
        || metadata
            .sidecar_description
            .as_ref()
            .map(|value| value.to_lowercase().contains(lower))
            .unwrap_or(false)
        || metadata
            .folder_hint
            .as_ref()
            .map(|value| value.to_lowercase().contains(lower))
            .unwrap_or(false)
        || metadata
            .camera
            .as_ref()
            .map(|camera| {
                camera
                    .make
                    .as_ref()
                    .map(|value| value.to_lowercase().contains(lower))
                    .unwrap_or(false)
                    || camera
                        .model
                        .as_ref()
                        .map(|value| value.to_lowercase().contains(lower))
                        .unwrap_or(false)
                    || camera
                        .lens_model
                        .as_ref()
                        .map(|value| value.to_lowercase().contains(lower))
                        .unwrap_or(false)
            })
            .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{ImportMode, MediaKind, ModelProvenance};
    use chrono::TimeZone;
    use uuid::Uuid;

    #[test]
    fn organization_filters_narrow_assets_by_person_place_and_date() {
        let family = asset("family.jpg", "photo", "Goa", 2026, 1, 15, false);
        let work = asset("work.jpg", "photo", "Delhi", 2026, 2, 1, false);
        let archived = asset("archive.jpg", "photo", "Goa", 2026, 1, 16, true);
        let people = vec![PersonCluster {
            id: Uuid::new_v4(),
            display_name: "Mom".to_string(),
            asset_ids: vec![family.id, archived.id],
            face_template_ids: vec![],
            representative_asset_id: Some(family.id),
            hidden: false,
            derived: ModelProvenance::local("test", "v1"),
        }];
        let places = vec![
            PlaceCluster {
                id: Uuid::new_v4(),
                label: "Goa".to_string(),
                country_code: Some("IN".to_string()),
                region: Some("West Coast".to_string()),
                asset_ids: vec![family.id, archived.id],
                centroid_latitude: None,
                centroid_longitude: None,
                derived: ModelProvenance::local("test", "v1"),
            },
            PlaceCluster {
                id: Uuid::new_v4(),
                label: "Delhi".to_string(),
                country_code: Some("IN".to_string()),
                region: None,
                asset_ids: vec![work.id],
                centroid_latitude: None,
                centroid_longitude: None,
                derived: ModelProvenance::local("test", "v1"),
            },
        ];

        let result = search_library(
            SearchQuery {
                text: Some("family".to_string()),
                people: Some("mom".to_string()),
                places: Some("goa".to_string()),
                events: None,
                media_kind: None,
                favorite: None,
                from_date: Some("2026-01-01".to_string()),
                to_date: Some("2026-01-31".to_string()),
                include_archived: false,
                limit: None,
            },
            &[family.clone(), work, archived],
            &people,
            &places,
            &[],
            &[],
            &[],
        );

        assert_eq!(result.assets.len(), 1);
        assert_eq!(result.assets[0].id, family.id);
        assert_eq!(result.people.len(), 1);
        assert_eq!(result.places.len(), 1);
    }

    #[test]
    fn include_archived_opt_in_and_hidden_people_are_excluded() {
        let archived = asset("hidden-memory.jpg", "photo", "Home", 2026, 3, 1, true);
        let hidden_person = PersonCluster {
            id: Uuid::new_v4(),
            display_name: "Hidden person".to_string(),
            asset_ids: vec![archived.id],
            face_template_ids: vec![],
            representative_asset_id: Some(archived.id),
            hidden: true,
            derived: ModelProvenance::local("test", "v1"),
        };

        let default_result = search_library(
            SearchQuery {
                text: Some("hidden".to_string()),
                people: None,
                places: None,
                events: None,
                media_kind: None,
                favorite: None,
                from_date: None,
                to_date: None,
                include_archived: false,
                limit: None,
            },
            std::slice::from_ref(&archived),
            std::slice::from_ref(&hidden_person),
            &[],
            &[],
            &[],
            &[],
        );
        assert!(default_result.assets.is_empty());

        let archived_result = search_library(
            SearchQuery {
                text: Some("hidden".to_string()),
                people: None,
                places: None,
                events: None,
                media_kind: None,
                favorite: None,
                from_date: None,
                to_date: None,
                include_archived: true,
                limit: None,
            },
            &[archived],
            &[hidden_person],
            &[],
            &[],
            &[],
            &[],
        );
        assert_eq!(archived_result.assets.len(), 1);
        assert!(archived_result.people.is_empty());
    }

    #[test]
    fn organization_filters_include_events_media_kind_and_favorites() {
        let mut birthday = asset("birthday-video.mp4", "video", "Home", 2026, 4, 4, false);
        birthday.favorite = true;
        let commute = asset("train-photo.jpg", "photo", "Station", 2026, 4, 4, false);
        let event = EventCluster {
            id: Uuid::new_v4(),
            title: "Birthday dinner".to_string(),
            title_source: crate::domain::EventTitleSource::User,
            asset_ids: vec![birthday.id],
            start_at: birthday.captured_at,
            end_at: birthday.captured_at,
            place_id: None,
            people_ids: vec![],
            derived: ModelProvenance::local("test", "v1"),
        };

        let result = search_library(
            SearchQuery {
                text: None,
                people: None,
                places: None,
                events: Some("birthday".to_string()),
                media_kind: Some("video".to_string()),
                favorite: Some(true),
                from_date: None,
                to_date: None,
                include_archived: false,
                limit: None,
            },
            &[birthday.clone(), commute],
            &[],
            &[],
            &[event],
            &[],
            &[],
        );

        assert_eq!(result.assets.len(), 1);
        assert_eq!(result.assets[0].id, birthday.id);
    }

    #[test]
    fn media_kind_filter_accepts_general_file_categories() {
        let document = asset("report.pdf", "document", "Work", 2026, 5, 1, false);
        let archive = asset("bundle.zip", "archive", "Work", 2026, 5, 1, false);
        let photo = asset("scan.jpg", "photo", "Work", 2026, 5, 1, false);

        let result = search_library(
            SearchQuery {
                text: None,
                people: None,
                places: None,
                events: None,
                media_kind: Some("docs,archives".to_string()),
                favorite: None,
                from_date: None,
                to_date: None,
                include_archived: false,
                limit: None,
            },
            &[document.clone(), archive.clone(), photo],
            &[],
            &[],
            &[],
            &[],
            &[],
        );

        let ids = result
            .assets
            .iter()
            .map(|asset| asset.id)
            .collect::<BTreeSet<_>>();
        assert_eq!(ids, BTreeSet::from([document.id, archive.id]));
    }

    fn asset(
        filename: &str,
        kind: &str,
        place_hint: &str,
        year: i32,
        month: u32,
        day: u32,
        archived: bool,
    ) -> Asset {
        let id = Uuid::new_v4();
        Asset {
            id,
            original_filename: filename.to_string(),
            relative_original_path: filename.to_string(),
            source_path: format!("/source/{filename}"),
            content_hash: format!("hash-{id}"),
            media_kind: match kind {
                "video" => MediaKind::Video,
                "document" => MediaKind::Document,
                "audio" => MediaKind::Audio,
                "archive" => MediaKind::Archive,
                "text" => MediaKind::Text,
                "other" => MediaKind::Other,
                _ => MediaKind::Photo,
            },
            import_mode: ImportMode::Copy,
            bytes: 10,
            mime_type: "image/jpeg".to_string(),
            captured_at: Utc.with_ymd_and_hms(year, month, day, 12, 0, 0).unwrap(),
            imported_at: Utc.with_ymd_and_hms(year, month, day, 12, 1, 0).unwrap(),
            archived,
            favorite: false,
            is_available: true,
            place_hint: Some(place_hint.to_string()),
            metadata: None,
            variants: vec![],
        }
    }
}
