# ADR: Explicit Recovery of Quarantined Managed Originals

## Status

Partially implemented in PR #123: local inventory and explicit same-device
repair are implemented, including verified decrypt/reseal and retry handling.
Portable backup key wrapping is not implemented and remains a release blocker.
Restore planning and execution fail closed for encrypted catalogs or encrypted
vault/quarantine payloads before destination writes, because destination key
activation and path rebinding are not implemented. Export still preserves those
files; a verified copy is not a usable recovered library. Unencrypted catalogs
without encrypted media can be staged, without claiming activation.

## Context

During ownership reconciliation, a managed plaintext original with conflicting
or missing vault ownership is encrypted under a random device-local quarantine
key. The plaintext source is removed only after the ciphertext and metadata have
been verified and persisted. This prevents startup from guessing a vault and
sealing the original under the wrong vault key.

The production quarantine key lives in the OS keyring. Plaintext file-key
backends are forbidden; a synthetic file store exists only in unit-test builds.
Existing backup export copies quarantine ciphertext and metadata, but not that key. Existing restore stages a database and files; it
does not install quarantine keys on the destination device. Therefore a copied
backup alone does not prove portable recovery. Local inventory and explicit
same-device repair APIs are implemented; they do not establish cross-device
key recovery. The existing backup test previously decrypted copied quarantine
with the original configuration, which proved ciphertext preservation rather
than independent destination recovery. The restore admission tests now require
refusal without destination writes and preserve the original recoverable copy.

## Decision

Add an explicitly invoked, local-admin recovery flow. No startup, import, sync,
or backup operation may select a target vault automatically. Mobile sessions
and remote sync peers cannot list or repair quarantine records.

### API contract

Inventory and repair are implemented. The passphrase-based export and restore
changes below are proposed acceptance requirements, not current API behavior.

- `GET /quarantine/originals` returns a local inventory: asset/object IDs,
  display filename, media kind, expected plaintext byte count and SHA-256,
  quarantine reason, creation time, and whether the source was removed. It may
  return live vault choices as IDs and names. It never returns plaintext bytes,
  key material, nonce/AAD, or keyring details.
- `POST /quarantine/originals/{asset_id}/repair` takes a required
  `target_vault_id` and an explicit confirmation flag. The target must be a live
  vault. Missing, stale, or conflicting IDs fail closed. The response reports
  only success/failure and resulting asset/blob IDs; errors and logs must not
  include plaintext, passphrases, or keys.
- `POST /backup/export` accepts an optional recovery passphrase. If one or more
  quarantine records are included, export requires a passphrase. The passphrase
  is never persisted, logged, or returned.
- `POST /backup/restore/run` accepts the recovery passphrase when the manifest
  contains wrapped quarantine keys. A wrong or missing passphrase fails before
  the restore is reported successful. Restore planning reports that recovery
  material is present without asking for or storing the passphrase.

The API structs must mark passphrase fields as secret in Debug output (or avoid
derived Debug), use zeroizing buffers, and keep the passphrase out of tracing,
error strings, job details, audit payloads, and backup reports.

### Repair transaction and failure ordering

1. Take the service write lock; reload the target and quarantine record from
   authoritative state. Require the exact user-supplied live target vault.
2. Verify all quarantine descriptors and ciphertext hashes. Use a verified
   reader to stream plaintext directly into the destination encryption, with
   bounded zeroizing buffers. Verify the full plaintext SHA-256 and byte count
   against both asset and quarantine metadata. Never write temporary plaintext
   files or return plaintext bytes to an API caller.
3. Explicitly provision the selected vault's current key version through the
   guarded lifecycle API. Existing catalog/ciphertext history and initialization
   markers forbid replacing a missing credential. Reader-based sealing only
   loads existing keys. Create a fresh blob ID and use the normal vault path and
   namespace. Sync the chunk files and containing directories; verify ciphertext
   hashes, sizes, chunk ordering, and decrypt the new blob through the normal
   vault reader to a sink while rechecking plaintext hash/length.
4. Build a candidate state that assigns the asset to the selected vault,
   installs exactly one active namespace entry, adds the new blob/chunks, and
   resolves conflicting legacy evidence. Keep old ciphertext and quarantine
   metadata until the candidate state has been durably saved. Do not remove
   unrelated assets, reference-import sources, or old encrypted chunks as part
   of repair.
5. Persist the candidate state atomically. If persistence fails, leave the
   quarantine record and ciphertext untouched; orphaned new encrypted chunks
   are safe and can be garbage-collected only after reconciliation proves they
   are unreferenced.
6. Only after the saved normal blob is independently verified may repair retire
   the quarantine object and key. If retirement fails or the process stops
   between state save and retirement, retain the quarantine inventory entry.
   A retry recognizes the already-persisted target blob, verifies it again, and
   then completes retirement. This makes retries idempotent and preserves at
   least one verified copy at each crash boundary.

For an explicit conflict repair, retain audit evidence of the operation and
which vault was chosen, but do not include filenames, hashes, or precise media
metadata in audit detail. Conflicting old blob records must be tombstoned or
otherwise made non-authoritative; stale completed upload receipts and namespace
entries must not continue granting membership. Their ciphertext is not deleted
as part of the repair.

### Portable backup key wrapping

For each included quarantine object, export reads its key from the local keyring
and wraps it only in memory for the export. Use Argon2id with fixed, versioned
parameters (initial profile: 256 MiB memory, 3 iterations, one lane, 32-byte
output), a fresh random 16-byte salt per backup, and ChaCha20-Poly1305 with a
fresh random 12-byte nonce. Authenticated associated data binds the wrap to the
backup format version, object ID, and asset ID. Store only the algorithm and
parameter profile identifiers, salt, nonce, and wrapped ciphertext in the
manifest. Never put raw object keys or the passphrase in the manifest.

Restore accepts only supported bounded KDF profiles; it must reject unknown or
resource-excessive parameters before deriving a key. It authenticates every
wrap and verifies the restored quarantine ciphertext against the database
metadata before declaring quarantine recovery available. A wrong passphrase or
tampered wrap fails closed. The recovered object key is installed in the local
OS keyring only as part of the staged restore activation. Any failed restore must remove keys it created
and preserve the source backup unchanged. Zeroize derived keys and passphrase
buffers on success and failure.

The KDF and AEAD crates, profile constants, manifest schema, keyring install,
activation rollback, and restore UX require security review before implementation.
Changing the profile later requires versioned parsing and compatibility tests.

## Compatibility and rollout

The inventory and repair API can be additive. Backup format version must be
incremented when wrapped keys are introduced. Older backups with quarantine
ciphertext but no wrapped key remain valid for same-device recovery only; the
new restore flow must state that portability is unavailable instead of
pretending the object is recoverable. Older clients ignore neither new required
fields nor new manifest versions: unsupported versions must fail with a clear,
non-sensitive error.

Do not delete quarantine data during rollout. Keep the existing device-local
credential readable until successful verified repair or an explicit user purge.
Do not auto-purge orphaned quarantine files or keys during startup.

## Required tests before implementation is accepted

- Inventory includes quarantined originals but no plaintext/key/nonce/AAD and
  is inaccessible to mobile and remote roles.
- Repair requires a caller-selected live vault; missing, deleted, and
  wrong-vault choices leave quarantine unchanged.
- Successful repair verifies plaintext hash/length, creates normal encrypted
  chunks under the selected vault path/key, persists one owner and one active
  namespace entry, survives restart, and retires quarantine only afterward.
- Inject failures during decrypt, hash check, chunk write/fsync, normal-reader
  verification, DB save, and quarantine retirement. At every point at least one
  verified recoverable copy remains; retries are idempotent.
- Conflict repair prevents old receipts, blobs, namespace rows, search results,
  and download routes from exposing the asset in either unselected vault.
- Backup export refuses to include quarantine without a passphrase. Portable
  restore succeeds on a separate runtime/keyring with the correct passphrase;
  wrong passphrase, altered salt/nonce/ciphertext/AAD, unsupported KDF profile,
  and interrupted restore fail without losing source backup or existing keys.
- Logs, errors, audit events, manifests, and support bundles contain neither
  passphrase nor raw/wrapped plaintext key material beyond the authenticated
  wrapped ciphertext required by the backup format.

## Rollback

API additions can be rolled back while leaving quarantine data intact. Once
portable backup manifests contain wrapped keys, retain a reader for that
version. Never downgrade by deleting wrapped keys or quarantine files. If a
repair crashes after the owner transaction commits, retry must complete
quarantine retirement only after verifying the already-persisted normal blob.

## Remaining work

- Portable passphrase-wrapped backup recovery as specified above, with a
  dedicated security review and cross-config restore tests. The complete bundle
  must include the SQLCipher catalog key/state binding, every required vault key
  version, and quarantine keys. Activation must remap restored library paths,
  verify all ciphertext with destination credentials, handle existing-key
  collisions, and roll back only credentials created by that restore. Wrapping
  only quarantine keys does not satisfy this requirement.
- Unit tests inject one-shot failures at 11 repair boundaries around sealing,
  catalog/namespace saves, directory/key retirement, and final inventory save.
  Each case reopens from disk, verifies a readable copy, retries, and reopens
  again to check bytes, one owner/entry/live target blob and unchanged synthetic
  destination key. These are service interruption/error-boundary tests. Actual
  database-write and chunk/directory fsync failures, abrupt process termination,
  and power-loss durability still require separate acceptance. Existing tests
  also cover invalid target,
  confirmation, corrupt quarantine retry, fresh-target provisioning, missing-key
  refusal with unchanged quarantine, interrupted repair across a key-version
  change, successful repair, and idempotent retry.
- Keep local inventory and repair behind the desktop administrator boundary.
  Router tests cover local inventory access plus remote and missing-connection
  denial for inventory and repair. Complete paired-device and remote-sync
  acceptance before the ADR is accepted.

## Required-key coverage metadata

Format-2 backup manifests may include an additive `recovery_key_inventory`
(version 1). It records only source catalog credential identity, vault UUID/key
version pairs for locally included chunks (including tombstoned history), and
quarantine object/asset/key-version identities. References are deterministic and
deduplicated; orphan/ambiguous records and unsupported quarantine key versions
fail export. It contains no key bytes, passphrases, nonce/AAD or wrapped keys.

This advisory inventory is preparation for #223, not evidence that credentials
exist, are wrapped, or can be installed on another device. Restore admission
continues to inspect the actual catalog and encrypted manifest entries and must
not trust this inventory to enable encrypted restoration. Existing format-2
backups without the field remain supported under the same admission rules.
