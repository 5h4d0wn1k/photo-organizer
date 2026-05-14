use crate::domain::{
    Asset, EventCluster, OcrBlock, PersonCluster, PlaceCluster, SceneTag, SearchQuery,
    SearchResponse,
};

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

    if let Some(text) = query.text.as_deref() {
        let lower = text.to_lowercase();
        let ocr_asset_ids = ocr_blocks
            .iter()
            .filter(|block| block.text.to_lowercase().contains(&lower))
            .map(|block| block.asset_id)
            .collect::<std::collections::BTreeSet<_>>();
        let person_asset_ids = people
            .iter()
            .filter(|person| person.display_name.to_lowercase().contains(&lower))
            .flat_map(|person| person.asset_ids.iter().copied())
            .collect::<std::collections::BTreeSet<_>>();
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
            .collect::<std::collections::BTreeSet<_>>();
        let event_asset_ids = events
            .iter()
            .filter(|event| event.title.to_lowercase().contains(&lower))
            .flat_map(|event| event.asset_ids.iter().copied())
            .collect::<std::collections::BTreeSet<_>>();
        let scene_asset_ids = scene_tags
            .iter()
            .filter(|tag| tag.label.replace('_', " ").to_lowercase().contains(&lower))
            .map(|tag| tag.asset_id)
            .collect::<std::collections::BTreeSet<_>>();
        matched_assets.retain(|asset| {
            asset.original_filename.to_lowercase().contains(&lower)
                || asset
                    .place_hint
                    .as_ref()
                    .map(|hint| hint.to_lowercase().contains(&lower))
                    .unwrap_or(false)
                || ocr_asset_ids.contains(&asset.id)
                || person_asset_ids.contains(&asset.id)
                || place_asset_ids.contains(&asset.id)
                || event_asset_ids.contains(&asset.id)
                || scene_asset_ids.contains(&asset.id)
        });
    }

    let matched_asset_ids: std::collections::BTreeSet<_> =
        matched_assets.iter().map(|asset| asset.id).collect();

    let people = people
        .iter()
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
