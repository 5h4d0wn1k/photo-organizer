use chrono::{DateTime, Duration, Utc};
use uuid::Uuid;

use crate::domain::{Asset, EventCluster, EventTitleSource, ModelProvenance};

pub fn cluster_assets(assets: &[Asset]) -> Vec<EventCluster> {
    if assets.is_empty() {
        return Vec::new();
    }

    let mut sorted = assets.to_vec();
    sorted.sort_by_key(|asset| asset.captured_at);

    let mut events = Vec::new();
    let mut current_assets = vec![sorted[0].clone()];
    let mut current_place = sorted[0].place_hint.clone();

    for asset in sorted.into_iter().skip(1) {
        let last = current_assets.last().expect("current cluster must exist");
        let gap = asset.captured_at - last.captured_at;
        let place_changed = asset.place_hint != current_place;
        let should_split = gap > Duration::hours(8) || (place_changed && gap > Duration::hours(2));

        if should_split {
            events.push(build_event(&current_assets, current_place.clone()));
            current_place = asset.place_hint.clone();
            current_assets = vec![asset];
        } else {
            current_assets.push(asset);
        }
    }

    events.push(build_event(&current_assets, current_place));
    events
}

fn build_event(assets: &[Asset], place_hint: Option<String>) -> EventCluster {
    let first = assets.first().expect("event must contain assets");
    let last = assets.last().expect("event must contain assets");
    let metadata_title = first.metadata.as_ref().and_then(|metadata| {
        metadata
            .sidecar_title
            .clone()
            .or(metadata.folder_hint.clone())
    });
    let place_title = place_hint
        .or(metadata_title)
        .unwrap_or_else(|| "Untitled moment".to_string());
    EventCluster {
        id: Uuid::new_v4(),
        title: format!("{} · {}", place_title, first.captured_at.format("%b %-d")),
        title_source: EventTitleSource::Generated,
        asset_ids: assets.iter().map(|asset| asset.id).collect(),
        start_at: first.captured_at,
        end_at: last.captured_at,
        place_id: None,
        people_ids: Vec::new(),
        derived: ModelProvenance::local("event-cluster", "heuristic-v1"),
    }
}

pub fn retitle_event(event: &mut EventCluster, title: String) {
    event.title = title;
    event.title_source = EventTitleSource::User;
}

pub fn event_range_label(start_at: DateTime<Utc>, end_at: DateTime<Utc>) -> String {
    if start_at.date_naive() == end_at.date_naive() {
        start_at.format("%B %-d, %Y").to_string()
    } else {
        format!(
            "{} - {}",
            start_at.format("%B %-d"),
            end_at.format("%B %-d, %Y")
        )
    }
}

#[cfg(test)]
mod tests {
    use chrono::{TimeZone, Utc};
    use uuid::Uuid;

    use crate::domain::{Asset, ImportMode, MediaKind};

    use super::cluster_assets;

    fn asset(name: &str, hour: u32, place_hint: Option<&str>) -> Asset {
        Asset {
            id: Uuid::new_v4(),
            original_filename: name.to_string(),
            relative_original_path: name.to_string(),
            source_path: format!("/tmp/{name}"),
            content_hash: format!("hash-{name}"),
            media_kind: MediaKind::Photo,
            import_mode: ImportMode::Reference,
            bytes: 10,
            mime_type: "image/jpeg".to_string(),
            captured_at: Utc.with_ymd_and_hms(2025, 5, 1, hour, 0, 0).unwrap(),
            imported_at: Utc.with_ymd_and_hms(2025, 5, 1, hour, 0, 0).unwrap(),
            archived: false,
            favorite: false,
            is_available: true,
            place_hint: place_hint.map(ToString::to_string),
            metadata: None,
            variants: Vec::new(),
        }
    }

    #[test]
    fn clusters_split_on_large_time_gaps() {
        let assets = vec![
            asset("a.jpg", 9, Some("Jaipur")),
            asset("b.jpg", 10, Some("Jaipur")),
            asset("c.jpg", 20, Some("Jaipur")),
        ];

        let events = cluster_assets(&assets);
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].asset_ids.len(), 2);
        assert_eq!(events[1].asset_ids.len(), 1);
    }
}
