# Deploy And Rollback Policy

Private Gallery releases must preserve local-first safety, no-hosted-content
privacy, and recoverability. A release is not ready without a rollback path for
every scoped platform.

## Release Risk Classes

| Class | Examples | Rollout expectation |
| --- | --- | --- |
| Documentation/config | Docs, checklists, non-runtime config. | Direct merge after review. |
| App UI/code | Flutter screens, API clients, local daemon launcher. | PR checks plus platform smoke for affected surfaces. |
| Storage/security | Encryption, chunks, backup, restore, tokens, route boundaries. | Full readiness review, fixture drill, rollback plan. |
| Platform/store | Installers, signing, app-store packages, updates. | Platform owner signoff, staged rollout where available. |
| Entitlements/billing | Plan gates, offline grace, store purchases, direct billing. | Entitlement privacy review and cancellation/export tests. |
| Relay/discovery/web | Remote routing, web sessions, local-web exposure. | Security review, route probes, staged rollout. |

## Rollout Strategy

- Release from immutable commit/tag or signed artifact set.
- Name the scoped platforms before release.
- Start with private beta, internal track, or small cohort when platform risk is
  material.
- Keep LAN HTTP development-only.
- Keep optional cloud bootstrap, relay, and discovery disabled unless explicitly
  in scope.
- Record skipped checks and accepted residual risk.

## Abort Criteria

Abort or roll back when any of these occur:

- Secret, key, token, file, OCR, embedding, face data, exact metadata, or
  workspace content exposure.
- Remote clients can reach desktop/admin APIs.
- Data loss, silent corruption, duplicate import, or restore over active library.
- Encrypted-only managed files are not protected by verified chunks.
- Pairing, revocation, upload, download, or range-hash smoke fails.
- Entitlement checks require content metadata or block safe local/export/restore
  behavior during connectivity loss.
- Store release uses debug signing or has inaccurate privacy disclosure.

## Rollback Paths

- Desktop: reinstall or relaunch last known good signed/checksummed artifact.
- Android: pause staged rollout, promote last known good track, revoke sessions
  if auth is implicated.
- iOS: halt phased release or submit rollback build according to App Store
  constraints.
- Web/local web: disable exposed route or roll back served bundle.
- Entitlements: disable newly introduced gates, preserve local access, and keep
  export/restore/revocation available.
- Storage/schema: do not downgrade real libraries until compatibility is proven
  on fixtures.

## Post-Rollout Evidence

- Health probe passes.
- Remote route probes return expected results.
- Import/search/vault/backup fixture passes.
- Mobile or web smoke passes when in scope.
- Support channels show no active privacy, data-loss, restore, or revocation
  reports.
- Release notes match supported surface and known limits.
