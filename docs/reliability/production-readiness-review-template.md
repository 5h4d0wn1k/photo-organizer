# Production Readiness Review

Use this review before launching any release-scoped surface or major shared
storage, organization, platform, entitlement, relay, web, or business/workspace
change.

## Release Scope

- Release name:
- Commit or tag:
- Platforms in scope:
- Features in scope:
- Owners:
- Rollback owner:

## Success Path

The release is ready only if users can complete the scoped critical journey
without hosted user content:

1. Open or create an encrypted local library.
2. Import mixed media/files without duplicate or plaintext policy regressions.
3. Organize/search from live local data.
4. Pair or use trusted devices when device-group behavior is in scope.
5. Upload/download/repair files when sync or storage is in scope.
6. Verify backup and restore staging.
7. Install/update/rollback each scoped platform artifact.
8. Enforce entitlements without content-derived identifiers when paid plans are
   in scope.

## Launch Blockers

- Secret, key, token, file, OCR, embedding, face data, exact metadata, or
  workspace content exposure.
- Remote clients can reach desktop/admin APIs.
- Encrypted-only imports keep unmanaged plaintext as the protected source of
  truth without an explicit development-only exception.
- Backup verify or restore staging fails on a clean fixture.
- Revocation fails for a paired mobile/session/device.
- Store or direct-release signing evidence is missing for an in-scope platform.
- Entitlement checks require content, file names, OCR, exact metadata, or keys.
- No rollback path exists for the release surface.

## Verification Evidence

- Rust tests:
- Flutter analyze/tests:
- Platform build/package evidence:
- Android/iOS physical-device evidence:
- Web/local-web boundary evidence:
- Remote route probes:
- Backup/restore drill:
- Secret scan/dependency audit/SBOM:
- Support bundle redaction:
- Entitlement privacy review:

## Operational Readiness

- Release owner named.
- Platform owners named.
- Security owner named.
- Support owner named.
- Rollback instructions linked.
- Known limits documented.
- Skipped checks justified.
- Support escalation path ready.

## Recommendation

- Ship:
- Ship with constraints:
- Do not ship:

Record the decision, accepted residual risks, and follow-up owners before
release.
