# ADR: Explicit Vault Ownership For Assets

## Status

Proposed; implementation and verification are in progress. This document is not
release evidence or a claim that all authorization paths have been fixed.

## Context

A daemon may host several vaults, while mobile sessions authorize one vault.
The historical global `assets.content_hash` uniqueness constraint conflicts with
vault-scoped ingestion: uploading identical bytes to two vaults must not grant
one vault access to the other vault's metadata or key. Mutable asset metadata
also needs its own ownership boundary.

## Decision

Each `Asset` has one nullable `vault_id` owner. Identical bytes in different
vaults have distinct asset UUIDs, independently mutable metadata, and independent
vault-encrypted blobs. Duplicate detection and database uniqueness use
`(vault_id, content_hash)`. A hash is a content identifier, never an access grant.

New managed originals, previews, and thumbnails use asset UUID namespaces.
Existing UUIDs and stored paths remain unchanged. Reference imports continue to
reference the user's source paths; managed cleanup must never delete those
sources or another asset's shared legacy file.

The owner must agree with the vault's live blob and explicit file membership
before mobile APIs or sync expose an asset. All listings, file trees, metadata,
preview/original downloads, storage assignments, and sync push/pull must enforce
that boundary. Conflicting historical evidence remains quarantined until an
explicit repair resolves it. Device-local protected originals are not vault
members and cannot sync.

Imports into a library with multiple vaults require an explicit target. Scan
sessions preserve that target, and commit must not silently change it. A fresh
mobile upload uses the authenticated reservation's vault before completion.
Failures to seal or persist must not acknowledge completion or discard the only
recoverable source.

## Migration and Compatibility

Schema version 24 transactionally rebuilds `assets`, replacing global hash
uniqueness with `(vault_id, content_hash)` uniqueness. All old asset UUIDs, paths,
and dependent rows survive unchanged. Foreign-key enforcement is temporarily
disabled outside the transaction to prevent cascading deletion during table
replacement, then the transaction runs `foreign_key_check` before commit and
restores the original enforcement setting on success or failure.

Legacy ownership is backfilled only when every live blob, completed upload
receipt, and active file entry agrees on one existing vault. Conflicting,
dangling-only, and association-free evidence leaves the owner null. There is no
first-vault fallback. Nullable ownership permits preserving unresolved data
without pretending it belongs to a vault. Deserialization defaults missing owners
to null; recovery imports need the same conservative explicit repair policy.

The database transformation does not move or delete original files. Shared
legacy paths need ownership-aware cleanup, and ambiguous plaintext originals
need verified device-local encryption before normal service exposure.

## Rollback

The migration is atomic: errors before commit restore the original table,
relationships, and schema version. Older binaries must reject schema 24. Once
cross-vault duplicates are written, downgrading the global uniqueness constraint
would require destructive merging and is forbidden. Recovery uses a verified,
encrypted pre-migration backup with explicit treatment of writes made afterward.

## Remaining Work

The PR wires explicit ownership through ingestion, persistence, mobile and sync
routes, and repair; end-to-end acceptance is still incomplete. Verify
populated-database upgrades, failure rollback,
same-vault dedup, cross-vault independent identities and files, metadata edits,
trash/purge isolation, restart, and historical-conflict quarantine before this
ADR can be accepted as implemented. Explicit cross-vault sharing is a separate
product operation; it cannot be inferred from duplicate bytes.
