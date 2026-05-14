use chrono::{TimeZone, Utc};
use uuid::Uuid;

use crate::domain::{
    Asset, AssetVariant, BoundingBox, EventCluster, EventTitleSource, FaceTemplate, JobKind,
    JobRecord, JobStatus, MediaKind, ModelProvenance, PersonCluster, PlaceCluster, SyncSession,
    SyncStatus, VariantKind,
};

fn id(value: u128) -> Uuid {
    Uuid::from_u128(value)
}

pub struct SampleLibrary {
    pub assets: Vec<Asset>,
    pub people: Vec<PersonCluster>,
    pub places: Vec<PlaceCluster>,
    pub events: Vec<EventCluster>,
    pub faces: Vec<FaceTemplate>,
    pub jobs: Vec<JobRecord>,
    pub sync_sessions: Vec<SyncSession>,
}

pub fn bootstrap_sample_library() -> SampleLibrary {
    let provenance = ModelProvenance::local("bootstrap", "v1");
    let thumb_provenance = ModelProvenance::local("thumb-generator", "v0");
    let beach_id = id(10);
    let dinner_id = id(11);
    let beach_place_id = id(20);
    let home_place_id = id(21);
    let maya_id = id(30);
    let arjun_id = id(31);
    let maya_face = id(40);
    let arjun_face = id(41);

    let assets = vec![
        Asset {
            id: beach_id,
            original_filename: "beach-day.jpg".to_string(),
            relative_original_path: "objects/ab/cd/beach-day.jpg".to_string(),
            content_hash: "abcdbeach".to_string(),
            media_kind: MediaKind::Photo,
            bytes: 2_048_000,
            mime_type: "image/jpeg".to_string(),
            captured_at: Utc.with_ymd_and_hms(2025, 1, 3, 9, 30, 0).unwrap(),
            imported_at: Utc.with_ymd_and_hms(2025, 1, 3, 18, 0, 0).unwrap(),
            archived: false,
            favorite: true,
            place_hint: Some("Goa".to_string()),
            variants: vec![AssetVariant {
                id: id(100),
                kind: VariantKind::Thumbnail,
                relative_path: "variants/thumbs/beach-day.webp".to_string(),
                mime_type: "image/webp".to_string(),
                bytes: 76_000,
                width: Some(480),
                height: Some(480),
                derived: thumb_provenance.clone(),
            }],
        },
        Asset {
            id: dinner_id,
            original_filename: "family-dinner.mp4".to_string(),
            relative_original_path: "objects/ef/01/family-dinner.mp4".to_string(),
            content_hash: "ef01dinner".to_string(),
            media_kind: MediaKind::Video,
            bytes: 16_048_000,
            mime_type: "video/mp4".to_string(),
            captured_at: Utc.with_ymd_and_hms(2025, 1, 3, 19, 45, 0).unwrap(),
            imported_at: Utc.with_ymd_and_hms(2025, 1, 3, 22, 15, 0).unwrap(),
            archived: false,
            favorite: false,
            place_hint: Some("Home".to_string()),
            variants: vec![AssetVariant {
                id: id(101),
                kind: VariantKind::Preview,
                relative_path: "variants/previews/family-dinner.jpg".to_string(),
                mime_type: "image/jpeg".to_string(),
                bytes: 128_000,
                width: Some(1280),
                height: Some(720),
                derived: thumb_provenance,
            }],
        },
    ];

    let people = vec![
        PersonCluster {
            id: maya_id,
            display_name: "Maya".to_string(),
            asset_ids: vec![beach_id, dinner_id],
            face_template_ids: vec![maya_face],
            representative_asset_id: Some(beach_id),
            hidden: false,
            derived: provenance.clone(),
        },
        PersonCluster {
            id: arjun_id,
            display_name: "Arjun".to_string(),
            asset_ids: vec![dinner_id],
            face_template_ids: vec![arjun_face],
            representative_asset_id: Some(dinner_id),
            hidden: false,
            derived: provenance.clone(),
        },
    ];

    let places = vec![
        PlaceCluster {
            id: beach_place_id,
            label: "Goa".to_string(),
            country_code: Some("IN".to_string()),
            region: Some("Goa".to_string()),
            asset_ids: vec![beach_id],
            centroid_latitude: Some(15.2993),
            centroid_longitude: Some(74.1240),
            derived: provenance.clone(),
        },
        PlaceCluster {
            id: home_place_id,
            label: "Home".to_string(),
            country_code: Some("IN".to_string()),
            region: Some("Rajasthan".to_string()),
            asset_ids: vec![dinner_id],
            centroid_latitude: None,
            centroid_longitude: None,
            derived: provenance.clone(),
        },
    ];

    let events = vec![
        EventCluster {
            id: id(200),
            title: "Goa · Jan 3".to_string(),
            title_source: EventTitleSource::Generated,
            asset_ids: vec![beach_id],
            start_at: assets[0].captured_at,
            end_at: assets[0].captured_at,
            place_id: Some(beach_place_id),
            people_ids: vec![maya_id],
            derived: provenance.clone(),
        },
        EventCluster {
            id: id(201),
            title: "Family dinner".to_string(),
            title_source: EventTitleSource::User,
            asset_ids: vec![dinner_id],
            start_at: assets[1].captured_at,
            end_at: assets[1].captured_at,
            place_id: Some(home_place_id),
            people_ids: vec![maya_id, arjun_id],
            derived: provenance.clone(),
        },
    ];

    let faces = vec![
        FaceTemplate {
            id: maya_face,
            asset_id: beach_id,
            person_cluster_id: Some(maya_id),
            preview_variant_id: Some(id(100)),
            bounding_box: BoundingBox {
                x: 0.25,
                y: 0.18,
                width: 0.2,
                height: 0.2,
            },
            derived: provenance.clone(),
        },
        FaceTemplate {
            id: arjun_face,
            asset_id: dinner_id,
            person_cluster_id: Some(arjun_id),
            preview_variant_id: Some(id(101)),
            bounding_box: BoundingBox {
                x: 0.44,
                y: 0.2,
                width: 0.18,
                height: 0.18,
            },
            derived: provenance.clone(),
        },
    ];

    let jobs = vec![
        JobRecord {
            id: id(300),
            kind: JobKind::MetadataExtraction,
            status: JobStatus::Completed,
            progress: 100,
            queued_at: Utc::now(),
            started_at: Some(Utc::now()),
            completed_at: Some(Utc::now()),
            detail: Some("metadata extracted for seed library".to_string()),
            cancel_requested: false,
            retry_of_job_id: None,
            attempt: 1,
        },
        JobRecord {
            id: id(301),
            kind: JobKind::FaceClustering,
            status: JobStatus::Running,
            progress: 68,
            queued_at: Utc::now(),
            started_at: Some(Utc::now()),
            completed_at: None,
            detail: Some("rebuilding people clusters after corrections".to_string()),
            cancel_requested: false,
            retry_of_job_id: None,
            attempt: 1,
        },
    ];

    let sync_sessions = vec![SyncSession {
        id: id(400),
        pairing_id: id(500),
        status: SyncStatus::Active,
        started_at: Utc::now(),
        last_seen_at: Some(Utc::now()),
        uploaded_asset_ids: vec![beach_id],
        rejected_asset_ids: Vec::new(),
    }];

    SampleLibrary {
        assets,
        people,
        places,
        events,
        faces,
        jobs,
        sync_sessions,
    }
}
