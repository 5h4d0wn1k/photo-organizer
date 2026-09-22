use std::collections::BTreeSet;

use uuid::Uuid;

use crate::domain::PersonCluster;

pub fn merge_clusters(target: &mut PersonCluster, sources: &[PersonCluster]) {
    let mut asset_ids: BTreeSet<Uuid> = target.asset_ids.iter().copied().collect();
    let mut face_ids: BTreeSet<Uuid> = target.face_template_ids.iter().copied().collect();

    for source in sources {
        asset_ids.extend(source.asset_ids.iter().copied());
        face_ids.extend(source.face_template_ids.iter().copied());
        if target.representative_asset_id.is_none() {
            target.representative_asset_id = source.representative_asset_id;
        }
    }

    target.asset_ids = asset_ids.into_iter().collect();
    target.face_template_ids = face_ids.into_iter().collect();
}

pub fn split_cluster(
    cluster: &mut PersonCluster,
    new_cluster_id: Uuid,
    new_display_name: String,
    moved_face_ids: &[Uuid],
) -> Option<PersonCluster> {
    let moved_set: BTreeSet<Uuid> = moved_face_ids.iter().copied().collect();
    if moved_set.is_empty() {
        return None;
    }

    let kept_faces: Vec<Uuid> = cluster
        .face_template_ids
        .iter()
        .copied()
        .filter(|id| !moved_set.contains(id))
        .collect();

    let new_faces: Vec<Uuid> = cluster
        .face_template_ids
        .iter()
        .copied()
        .filter(|id| moved_set.contains(id))
        .collect();

    if new_faces.is_empty() || kept_faces.is_empty() {
        return None;
    }

    cluster.face_template_ids = kept_faces;

    Some(PersonCluster {
        id: new_cluster_id,
        display_name: new_display_name,
        asset_ids: cluster.asset_ids.clone(),
        face_template_ids: new_faces,
        representative_asset_id: cluster.representative_asset_id,
        hidden: false,
        derived: cluster.derived.clone(),
    })
}

#[cfg(test)]
mod tests {
    use chrono::Utc;
    use uuid::Uuid;

    use crate::domain::{ModelProvenance, PersonCluster};

    use super::{merge_clusters, split_cluster};

    fn person(name: &str, asset_ids: Vec<Uuid>, face_ids: Vec<Uuid>) -> PersonCluster {
        PersonCluster {
            id: Uuid::new_v4(),
            display_name: name.to_string(),
            asset_ids,
            face_template_ids: face_ids,
            representative_asset_id: None,
            hidden: false,
            derived: ModelProvenance {
                model_name: "face-cluster".to_string(),
                model_version: "v0".to_string(),
                model_hash: None,
                created_at: Utc::now(),
                rebuildable: true,
            },
        }
    }

    #[test]
    fn merge_clusters_deduplicates_assets_and_faces() {
        let asset = Uuid::new_v4();
        let face_a = Uuid::new_v4();
        let face_b = Uuid::new_v4();
        let mut target = person("Target", vec![asset], vec![face_a]);
        let source = person("Source", vec![asset], vec![face_b]);

        merge_clusters(&mut target, &[source]);

        assert_eq!(target.asset_ids.len(), 1);
        assert_eq!(target.face_template_ids.len(), 2);
    }

    #[test]
    fn split_cluster_creates_new_cluster_when_faces_move() {
        let asset = Uuid::new_v4();
        let face_a = Uuid::new_v4();
        let face_b = Uuid::new_v4();
        let mut original = person("Family", vec![asset], vec![face_a, face_b]);

        let new_cluster =
            split_cluster(&mut original, Uuid::new_v4(), "Alex".to_string(), &[face_b])
                .expect("split should succeed");

        assert_eq!(original.face_template_ids, vec![face_a]);
        assert_eq!(new_cluster.face_template_ids, vec![face_b]);
    }
}
