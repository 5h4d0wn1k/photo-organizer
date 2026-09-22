# SLO And SLI Definition

The canonical SLO/SLI guide is maintained in
[../production-slo-sli.md](../production-slo-sli.md).

## Release-Blocking Objectives

- 100% of remote desktop/admin route probes return forbidden.
- 100% of new encrypted-only managed originals/files have verified encrypted
  chunks before plaintext managed copies are removed or considered protected.
- 100% of backup restore runs stage into a separate root unless a separately
  approved in-place restore design exists.
- 100% of billing and entitlement checks avoid file names, OCR text, face data,
  exact metadata, vault keys, bearer tokens, pairing tokens, and content-derived
  identifiers.
- 100% of in-scope platform releases have signing, package, store/privacy, test,
  and rollback evidence.

## Primary Signals

- `daemon_health_success`
- `remote_desktop_route_forbidden`
- `import_checksum_verified`
- `vault_chunk_verified`
- `file_organization_available`
- `mobile_pair_success`
- `mobile_upload_complete_success`
- `mobile_download_range_hash_match`
- `session_revocation_enforced`
- `backup_verify_success`
- `restore_staged_success`
- `platform_release_evidence_complete`
- `entitlement_content_exposure_absent`

## Review Cadence

Review SLOs before each public release and whenever platform support,
entitlements, relay/discovery, storage, encryption, backup, mobile sync, web, or
business/workspace authorization changes.
