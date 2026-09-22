use crate::domain::{
    Asset, DeviceIdentity, EventCluster, MediaKind, OcrBlock, PersonCluster, PlaceCluster,
    SceneTag, SearchQuery, SearchResponse, VaultFileEntry,
};
use chrono::{DateTime, NaiveDate, Utc};
use std::collections::BTreeSet;

pub struct SearchCorpus<'a> {
    pub assets: &'a [Asset],
    pub people: &'a [PersonCluster],
    pub places: &'a [PlaceCluster],
    pub events: &'a [EventCluster],
    pub ocr_blocks: &'a [OcrBlock],
    pub scene_tags: &'a [SceneTag],
    pub file_entries: &'a [VaultFileEntry],
    pub devices: &'a [DeviceIdentity],
}

impl<'a> SearchCorpus<'a> {
    pub fn new(assets: &'a [Asset]) -> Self {
        Self {
            assets,
            people: &[],
            places: &[],
            events: &[],
            ocr_blocks: &[],
            scene_tags: &[],
            file_entries: &[],
            devices: &[],
        }
    }

    pub fn with_people(mut self, people: &'a [PersonCluster]) -> Self {
        self.people = people;
        self
    }

    pub fn with_places(mut self, places: &'a [PlaceCluster]) -> Self {
        self.places = places;
        self
    }

    pub fn with_events(mut self, events: &'a [EventCluster]) -> Self {
        self.events = events;
        self
    }

    pub fn with_ocr_blocks(mut self, ocr_blocks: &'a [OcrBlock]) -> Self {
        self.ocr_blocks = ocr_blocks;
        self
    }

    pub fn with_scene_tags(mut self, scene_tags: &'a [SceneTag]) -> Self {
        self.scene_tags = scene_tags;
        self
    }

    pub fn with_file_entries(mut self, file_entries: &'a [VaultFileEntry]) -> Self {
        self.file_entries = file_entries;
        self
    }

    pub fn with_devices(mut self, devices: &'a [DeviceIdentity]) -> Self {
        self.devices = devices;
        self
    }
}

pub fn search_library(query: SearchQuery, corpus: SearchCorpus<'_>) -> SearchResponse {
    let SearchCorpus {
        assets,
        people,
        places,
        events,
        ocr_blocks,
        scene_tags,
        file_entries,
        devices,
    } = corpus;

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

    if let Some(tags_filter) = trimmed_filter(query.tags.as_deref()) {
        let requested_tags = parse_tag_filter(tags_filter);
        if !requested_tags.is_empty() {
            matched_assets.retain(|asset| manual_tags_match_filter(asset, &requested_tags));
        }
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

    if let Some(workspace_filter) = trimmed_filter(query.workspace.as_deref()) {
        matched_assets.retain(|asset| {
            organization_field_matches(asset, workspace_filter, |organization| {
                organization.workspace.as_deref()
            })
        });
    }

    if let Some(client_filter) = trimmed_filter(query.client.as_deref()) {
        matched_assets.retain(|asset| {
            organization_field_matches(asset, client_filter, |organization| {
                organization.client.as_deref()
            })
        });
    }

    if let Some(project_filter) = trimmed_filter(query.project.as_deref()) {
        matched_assets.retain(|asset| {
            organization_field_matches(asset, project_filter, |organization| {
                organization.project.as_deref()
            })
        });
    }

    if let Some(topic_filter) = trimmed_filter(query.topic.as_deref()) {
        matched_assets.retain(|asset| {
            organization_field_matches(asset, topic_filter, |organization| {
                organization.topic.as_deref()
            })
        });
    }

    if let Some(source_folder_filter) = trimmed_filter(query.source_folder.as_deref()) {
        matched_assets.retain(|asset| source_folder_matches_filter(asset, source_folder_filter));
    }

    if let Some(device_filter) = trimmed_filter(query.device.as_deref()) {
        let device_asset_ids = device_filter_asset_ids(device_filter, file_entries, devices);
        matched_assets.retain(|asset| device_asset_ids.contains(&asset.id));
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
                    .manual_tags
                    .iter()
                    .any(|tag| tag.to_lowercase().contains(&lower))
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

fn trimmed_filter(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|value| !value.is_empty())
}

fn parse_tag_filter(value: &str) -> Vec<String> {
    value
        .split(',')
        .map(str::trim)
        .filter(|tag| !tag.is_empty())
        .map(str::to_lowercase)
        .collect()
}

fn manual_tags_match_filter(asset: &Asset, requested_tags: &[String]) -> bool {
    requested_tags.iter().all(|requested| {
        asset
            .manual_tags
            .iter()
            .any(|tag| tag.to_lowercase().contains(requested))
    })
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

fn device_filter_asset_ids(
    filter: &str,
    file_entries: &[VaultFileEntry],
    devices: &[DeviceIdentity],
) -> BTreeSet<uuid::Uuid> {
    let matching_device_ids = devices
        .iter()
        .filter(|device| {
            device.id.to_string() == filter
                || text_matches_filter(&device.display_name, filter)
                || text_matches_filter(&device.platform, filter)
                || text_matches_filter(
                    &format!("{} {}", device.display_name, device.platform),
                    filter,
                )
        })
        .map(|device| device.id)
        .collect::<BTreeSet<_>>();
    file_entries
        .iter()
        .filter(|entry| {
            entry
                .origin_device_id
                .is_some_and(|device_id| matching_device_ids.contains(&device_id))
        })
        .filter_map(|entry| entry.asset_id)
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

fn organization_field_matches(
    asset: &Asset,
    filter: &str,
    field: impl for<'a> Fn(&'a crate::domain::FileOrganizationHints) -> Option<&'a str>,
) -> bool {
    asset
        .metadata
        .as_ref()
        .and_then(|metadata| field(&metadata.organization))
        .map(|value| text_matches_filter(value, filter))
        .unwrap_or(false)
}

fn source_folder_matches_filter(asset: &Asset, filter: &str) -> bool {
    asset
        .metadata
        .as_ref()
        .map(|metadata| {
            metadata
                .folder_hint
                .as_ref()
                .map(|value| text_matches_filter(value, filter))
                .unwrap_or(false)
                || metadata
                    .organization
                    .source_folder
                    .as_ref()
                    .map(|value| text_matches_filter(value, filter))
                    .unwrap_or(false)
                || metadata
                    .organization
                    .path_segments
                    .iter()
                    .any(|value| text_matches_filter(value, filter))
        })
        .unwrap_or(false)
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
            .organization
            .source_folder
            .as_ref()
            .map(|value| value.to_lowercase().contains(lower))
            .unwrap_or(false)
        || metadata
            .organization
            .workspace
            .as_ref()
            .map(|value| value.to_lowercase().contains(lower))
            .unwrap_or(false)
        || metadata
            .organization
            .client
            .as_ref()
            .map(|value| value.to_lowercase().contains(lower))
            .unwrap_or(false)
        || metadata
            .organization
            .project
            .as_ref()
            .map(|value| value.to_lowercase().contains(lower))
            .unwrap_or(false)
        || metadata
            .organization
            .topic
            .as_ref()
            .map(|value| value.to_lowercase().contains(lower))
            .unwrap_or(false)
        || metadata
            .organization
            .path_segments
            .iter()
            .any(|value| value.to_lowercase().contains(lower))
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
    use crate::domain::{
        AssetMetadata, DeviceStorageProfile, DeviceTrustLevel, FileOrganizationHints, ImportMode,
        MediaKind, MetadataSource, ModelProvenance, VaultFileKind,
    };
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
                workspace: None,
                client: None,
                project: None,
                topic: None,
                source_folder: None,
                device: None,
                media_kind: None,
                tags: None,
                favorite: None,
                from_date: Some("2026-01-01".to_string()),
                to_date: Some("2026-01-31".to_string()),
                include_archived: false,
                limit: None,
            },
            SearchCorpus::new(&[family.clone(), work, archived])
                .with_people(&people)
                .with_places(&places),
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
                workspace: None,
                client: None,
                project: None,
                topic: None,
                source_folder: None,
                device: None,
                media_kind: None,
                tags: None,
                favorite: None,
                from_date: None,
                to_date: None,
                include_archived: false,
                limit: None,
            },
            SearchCorpus::new(std::slice::from_ref(&archived))
                .with_people(std::slice::from_ref(&hidden_person)),
        );
        assert!(default_result.assets.is_empty());

        let archived_result = search_library(
            SearchQuery {
                text: Some("hidden".to_string()),
                people: None,
                places: None,
                events: None,
                workspace: None,
                client: None,
                project: None,
                topic: None,
                source_folder: None,
                device: None,
                media_kind: None,
                tags: None,
                favorite: None,
                from_date: None,
                to_date: None,
                include_archived: true,
                limit: None,
            },
            SearchCorpus::new(&[archived]).with_people(&[hidden_person]),
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
                workspace: None,
                client: None,
                project: None,
                topic: None,
                source_folder: None,
                device: None,
                media_kind: Some("video".to_string()),
                tags: None,
                favorite: Some(true),
                from_date: None,
                to_date: None,
                include_archived: false,
                limit: None,
            },
            SearchCorpus::new(&[birthday.clone(), commute]).with_events(&[event]),
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
                workspace: None,
                client: None,
                project: None,
                topic: None,
                source_folder: None,
                device: None,
                media_kind: Some("docs,archives".to_string()),
                tags: None,
                favorite: None,
                from_date: None,
                to_date: None,
                include_archived: false,
                limit: None,
            },
            SearchCorpus::new(&[document.clone(), archive.clone(), photo]),
        );

        let ids = result
            .assets
            .iter()
            .map(|asset| asset.id)
            .collect::<BTreeSet<_>>();
        assert_eq!(ids, BTreeSet::from([document.id, archive.id]));
    }

    #[test]
    fn device_filter_matches_file_origin_device_labels() {
        let phone_asset = asset("camera.jpg", "photo", "Home", 2026, 5, 2, false);
        let laptop_asset = asset("proposal.pdf", "document", "Office", 2026, 5, 2, false);
        let vault_id = Uuid::new_v4();
        let phone_id = Uuid::new_v4();
        let laptop_id = Uuid::new_v4();
        let devices = vec![
            device(phone_id, "Pixel phone", "android"),
            device(laptop_id, "Office laptop", "linux"),
        ];
        let file_entries = vec![
            file_entry(vault_id, phone_id, &phone_asset),
            file_entry(vault_id, laptop_id, &laptop_asset),
        ];

        let result = search_library(
            SearchQuery {
                text: None,
                people: None,
                places: None,
                events: None,
                workspace: None,
                client: None,
                project: None,
                topic: None,
                source_folder: None,
                device: Some("pixel".to_string()),
                media_kind: None,
                tags: None,
                favorite: None,
                from_date: None,
                to_date: None,
                include_archived: false,
                limit: None,
            },
            SearchCorpus::new(&[phone_asset.clone(), laptop_asset])
                .with_file_entries(&file_entries)
                .with_devices(&devices),
        );

        assert_eq!(result.assets.len(), 1);
        assert_eq!(result.assets[0].id, phone_asset.id);
    }

    #[test]
    fn explicit_file_organization_filters_match_workspace_client_project_topic_and_folder() {
        let mut proposal = asset("proposal.pdf", "document", "Work", 2026, 6, 1, false);
        proposal.metadata = Some(AssetMetadata {
            asset_id: proposal.id,
            captured_at: proposal.captured_at,
            captured_at_source: MetadataSource::Filesystem,
            timezone_offset_minutes: None,
            width: None,
            height: None,
            camera: None,
            geo: None,
            sidecar_title: None,
            sidecar_description: None,
            folder_hint: Some("Project Launch".to_string()),
            organization: FileOrganizationHints {
                source_folder: Some("Project Launch".to_string()),
                workspace: Some("Office".to_string()),
                client: Some("Client Acme".to_string()),
                project: Some("Project Launch".to_string()),
                topic: Some("Launch Notes".to_string()),
                path_segments: vec![
                    "Office".to_string(),
                    "Client Acme".to_string(),
                    "Project Launch".to_string(),
                ],
            },
            derived: ModelProvenance::local("test", "v1"),
        });
        let mut invoice = asset("invoice.pdf", "document", "Work", 2026, 6, 1, false);
        invoice.metadata = Some(AssetMetadata {
            asset_id: invoice.id,
            captured_at: invoice.captured_at,
            captured_at_source: MetadataSource::Filesystem,
            timezone_offset_minutes: None,
            width: None,
            height: None,
            camera: None,
            geo: None,
            sidecar_title: None,
            sidecar_description: None,
            folder_hint: Some("Finance".to_string()),
            organization: FileOrganizationHints {
                source_folder: Some("Finance".to_string()),
                workspace: Some("Office".to_string()),
                client: Some("Client Beta".to_string()),
                project: Some("Billing".to_string()),
                topic: Some("Invoices".to_string()),
                path_segments: vec!["Office".to_string(), "Client Beta".to_string()],
            },
            derived: ModelProvenance::local("test", "v1"),
        });

        let result = search_library(
            SearchQuery {
                text: None,
                people: None,
                places: None,
                events: None,
                workspace: Some("office".to_string()),
                client: Some("acme".to_string()),
                project: Some("launch".to_string()),
                topic: Some("notes".to_string()),
                source_folder: Some("project".to_string()),
                device: None,
                media_kind: Some("documents".to_string()),
                tags: None,
                favorite: None,
                from_date: None,
                to_date: None,
                include_archived: false,
                limit: None,
            },
            SearchCorpus::new(&[proposal.clone(), invoice]),
        );

        assert_eq!(result.assets.len(), 1);
        assert_eq!(result.assets[0].id, proposal.id);
    }

    #[test]
    fn text_search_matches_local_project_client_and_workspace_hints() {
        let mut proposal = asset("proposal.pdf", "document", "Work", 2026, 6, 1, false);
        proposal.metadata = Some(AssetMetadata {
            asset_id: proposal.id,
            captured_at: proposal.captured_at,
            captured_at_source: MetadataSource::Filesystem,
            timezone_offset_minutes: None,
            width: None,
            height: None,
            camera: None,
            geo: None,
            sidecar_title: None,
            sidecar_description: None,
            folder_hint: Some("Project Launch".to_string()),
            organization: FileOrganizationHints {
                source_folder: Some("Project Launch".to_string()),
                workspace: Some("Office".to_string()),
                client: Some("Client Acme".to_string()),
                project: Some("Project Launch".to_string()),
                topic: Some("Launch".to_string()),
                path_segments: vec![
                    "Office".to_string(),
                    "Client Acme".to_string(),
                    "Project Launch".to_string(),
                ],
            },
            derived: ModelProvenance::local("test", "v1"),
        });
        let photo = asset("family.jpg", "photo", "Home", 2026, 6, 1, false);

        let result = search_library(
            SearchQuery {
                text: Some("acme".to_string()),
                people: None,
                places: None,
                events: None,
                workspace: None,
                client: None,
                project: None,
                topic: None,
                source_folder: None,
                device: None,
                media_kind: Some("documents".to_string()),
                tags: None,
                favorite: None,
                from_date: None,
                to_date: None,
                include_archived: false,
                limit: None,
            },
            SearchCorpus::new(&[proposal.clone(), photo]),
        );

        assert_eq!(result.assets.len(), 1);
        assert_eq!(result.assets[0].id, proposal.id);
    }

    fn device(id: Uuid, display_name: &str, platform: &str) -> DeviceIdentity {
        DeviceIdentity {
            id,
            display_name: display_name.to_string(),
            platform: platform.to_string(),
            public_key: format!("public-key-{id}"),
            trust_level: DeviceTrustLevel::Trusted,
            storage_profile: DeviceStorageProfile::default(),
            enrolled_at: Utc.with_ymd_and_hms(2026, 1, 1, 12, 0, 0).unwrap(),
            last_seen_at: None,
            revoked_at: None,
        }
    }

    fn file_entry(vault_id: Uuid, origin_device_id: Uuid, asset: &Asset) -> VaultFileEntry {
        VaultFileEntry {
            id: Uuid::new_v4(),
            vault_id,
            parent_id: Some(Uuid::new_v4()),
            asset_id: Some(asset.id),
            name: asset.original_filename.clone(),
            kind: VaultFileKind::File,
            media_kind: Some(asset.media_kind.clone()),
            mime_type: Some(asset.mime_type.clone()),
            bytes: asset.bytes,
            content_hash: Some(asset.content_hash.clone()),
            origin_device_id: Some(origin_device_id),
            created_at: asset.imported_at,
            updated_at: asset.imported_at,
            trashed_at: None,
            organization: FileOrganizationHints::default(),
        }
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
            manual_tags: Vec::new(),
            metadata: None,
            variants: vec![],
        }
    }
}
