//! Non-secret key identities required by locally included backup ciphertext.
//! This is coverage metadata, not wrapped key material or proof of activation.
use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::domain::{BlobChunk, BlobRecord, ProtectedOriginal, ProtectedOriginalChunk};

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub(crate) enum RequiredRecoveryKey {
    Catalog {
        source_key_id: String,
    },
    Vault {
        vault_id: Uuid,
        key_version: u32,
    },
    Quarantine {
        object_id: Uuid,
        asset_id: Uuid,
        key_version: u32,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RecoveryKeyInventory {
    pub(crate) version: u32,
    pub(crate) required_keys: BTreeSet<RequiredRecoveryKey>,
}

pub(crate) fn build(
    catalog_key_id: Option<String>,
    blobs: &[BlobRecord],
    chunks: &[BlobChunk],
    originals: &[ProtectedOriginal],
    original_chunks: &[ProtectedOriginalChunk],
) -> Result<RecoveryKeyInventory, &'static str> {
    let mut required_keys = BTreeSet::new();
    if let Some(source_key_id) = catalog_key_id {
        if source_key_id.is_empty() {
            return Err("missing catalog key identity");
        }
        required_keys.insert(RequiredRecoveryKey::Catalog { source_key_id });
    }
    let mut blob_index = BTreeMap::new();
    for blob in blobs {
        if blob_index.insert(blob.id, blob).is_some() {
            return Err("duplicate blob identity in recovery inventory");
        }
    }
    let mut chunk_ids = BTreeSet::new();
    for chunk in chunks.iter().filter(|chunk| chunk.local_path.is_some()) {
        if !chunk_ids.insert(chunk.id) {
            return Err("duplicate included chunk identity");
        }
        let blob = blob_index
            .get(&chunk.blob_id)
            .ok_or("included chunk has no owning blob")?;
        if blob.encryption_key_version == 0 {
            return Err("included blob has an invalid key version");
        }
        // Tombstoned rows can still own included ciphertext; never substitute
        // the vault's current version or filter historical rows here.
        required_keys.insert(RequiredRecoveryKey::Vault {
            vault_id: blob.vault_id,
            key_version: blob.encryption_key_version,
        });
    }
    let mut objects = BTreeSet::new();
    let mut original_index = BTreeMap::new();
    for original in originals {
        if !objects.insert(original.object_id)
            || original_index.insert(original.asset_id, original).is_some()
        {
            return Err("duplicate quarantine identity in recovery inventory");
        }
        if original.key_version != 1 {
            return Err("unsupported quarantine key version");
        }
    }
    let mut original_indexes = BTreeMap::<Uuid, BTreeSet<u32>>::new();
    for chunk in original_chunks {
        if !chunk_ids.insert(chunk.id) {
            return Err("duplicate included chunk identity");
        }
        let original = original_index
            .get(&chunk.asset_id)
            .ok_or("included quarantine chunk has no owning object")?;
        if !original_indexes
            .entry(chunk.asset_id)
            .or_default()
            .insert(chunk.chunk_index)
        {
            return Err("duplicate quarantine chunk index");
        }
        required_keys.insert(RequiredRecoveryKey::Quarantine {
            object_id: original.object_id,
            asset_id: original.asset_id,
            key_version: original.key_version,
        });
    }
    for original in originals {
        let indexes = original_indexes
            .get(&original.asset_id)
            .ok_or("quarantine object has no included chunks")?;
        if original.chunk_count == 0
            || indexes.len() != original.chunk_count as usize
            || indexes.iter().copied().ne(0..original.chunk_count)
        {
            return Err("quarantine chunk inventory is incomplete");
        }
    }
    Ok(RecoveryKeyInventory {
        version: 1,
        required_keys,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    fn blob(vault_id: Uuid, version: u32) -> BlobRecord {
        BlobRecord {
            id: Uuid::new_v4(),
            vault_id,
            asset_id: Uuid::new_v4(),
            content_hash: "fixture".into(),
            encrypted_hash: "ciphertext".into(),
            bytes: 1,
            chunk_count: 1,
            encryption_key_version: version,
            created_at: Utc::now(),
            tombstoned_at: None,
        }
    }
    fn chunk(blob_id: Uuid) -> BlobChunk {
        BlobChunk {
            id: Uuid::new_v4(),
            blob_id,
            chunk_index: 0,
            content_hash: "fixture".into(),
            encrypted_hash: "ciphertext".into(),
            bytes: 1,
            encrypted_bytes: 17,
            local_path: Some("vaults/fixture.pgblob".into()),
            nonce_hex: None,
            aad: None,
        }
    }
    fn original() -> (ProtectedOriginal, ProtectedOriginalChunk) {
        let record = ProtectedOriginal {
            asset_id: Uuid::new_v4(),
            object_id: Uuid::new_v4(),
            content_hash: "fixture".into(),
            bytes: 1,
            encrypted_hash: "ciphertext".into(),
            chunk_count: 1,
            key_version: 1,
            reason: "conflict".into(),
            source_removed: true,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };
        let chunk = ProtectedOriginalChunk {
            id: Uuid::new_v4(),
            asset_id: record.asset_id,
            chunk_index: 0,
            content_hash: "fixture".into(),
            encrypted_hash: "ciphertext".into(),
            bytes: 1,
            encrypted_bytes: 17,
            local_path: "quarantine/fixture.qblob".into(),
            nonce_hex: "not exported".into(),
            aad: "not exported".into(),
        };
        (record, chunk)
    }

    #[test]
    fn includes_historical_versions_deduplicates_and_is_order_independent() {
        let vault = Uuid::new_v4();
        let mut old = blob(vault, 1);
        old.tombstoned_at = Some(Utc::now());
        let current = blob(vault, 2);
        let duplicate = blob(vault, 2);
        let remote = blob(Uuid::new_v4(), 3);
        let mut remote_chunk = chunk(remote.id);
        remote_chunk.local_path = None;
        let mut blobs = vec![old.clone(), current.clone(), duplicate.clone(), remote];
        let mut chunks = vec![
            chunk(old.id),
            chunk(current.id),
            chunk(duplicate.id),
            remote_chunk,
        ];
        let first = build(Some("catalog-ref".into()), &blobs, &chunks, &[], &[]).unwrap();
        blobs.reverse();
        chunks.reverse();
        assert_eq!(
            first,
            build(Some("catalog-ref".into()), &blobs, &chunks, &[], &[]).unwrap()
        );
        assert_eq!(first.required_keys.len(), 3);
        assert!(first.required_keys.contains(&RequiredRecoveryKey::Vault {
            vault_id: vault,
            key_version: 1
        }));
        assert!(first.required_keys.contains(&RequiredRecoveryKey::Vault {
            vault_id: vault,
            key_version: 2
        }));
    }

    #[test]
    fn rejects_orphan_duplicate_and_invalid_vault_evidence() {
        let mut record = blob(Uuid::new_v4(), 0);
        let chunks = [chunk(record.id)];
        assert!(build(None, &[], &chunks, &[], &[]).is_err());
        assert!(build(None, &[record.clone()], &chunks, &[], &[]).is_err());
        record.encryption_key_version = 1;
        assert!(build(None, &[record.clone(), record.clone()], &chunks, &[], &[]).is_err());
        assert!(
            build(
                None,
                &[record],
                &[chunks[0].clone(), chunks[0].clone()],
                &[],
                &[]
            )
            .is_err()
        );
    }

    #[test]
    fn quarantine_coverage_rejects_missing_or_ambiguous_evidence() {
        let (record, chunk) = original();
        let inventory = build(
            None,
            &[],
            &[],
            std::slice::from_ref(&record),
            std::slice::from_ref(&chunk),
        )
        .unwrap();
        assert_eq!(inventory.required_keys.len(), 1);
        assert!(build(None, &[], &[], &[], std::slice::from_ref(&chunk)).is_err());
        assert!(build(None, &[], &[], std::slice::from_ref(&record), &[]).is_err());
        assert!(
            build(
                None,
                &[],
                &[],
                &[record.clone(), record.clone()],
                std::slice::from_ref(&chunk)
            )
            .is_err()
        );
        let mut unsupported = record.clone();
        unsupported.key_version = 2;
        assert!(build(None, &[], &[], &[unsupported], std::slice::from_ref(&chunk)).is_err());
        let mut gap = chunk.clone();
        gap.chunk_index = 1;
        assert!(build(None, &[], &[], std::slice::from_ref(&record), &[gap]).is_err());
        // Assert the serialized contract structurally. Scanning the rendered
        // JSON for "aad" can match those letters in a random UUID and make
        // this test flaky even though no AAD field was serialized.
        let json = serde_json::to_value(&inventory).unwrap();
        assert_eq!(
            json,
            serde_json::json!({
                "version": 1,
                "required_keys": [{
                    "kind": "quarantine",
                    "object_id": record.object_id,
                    "asset_id": record.asset_id,
                    "key_version": 1,
                }],
            })
        );
        assert!(!json.to_string().contains("not exported"));
    }

    #[test]
    fn unencrypted_empty_backup_needs_no_keys() {
        assert!(
            build(None, &[], &[], &[], &[])
                .unwrap()
                .required_keys
                .is_empty()
        );
        assert!(build(Some(String::new()), &[], &[], &[], &[]).is_err());
    }
}
