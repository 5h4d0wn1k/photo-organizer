# Service Ownership And Runbook

This runbook defines ownership for Private Gallery's local-first shared-storage
cloud, smart organization, platform release, and subscription surfaces.

## Ownership Summary

| Area | Owns | Does not own |
| --- | --- | --- |
| Desktop owner | Windows/Linux/macOS app startup, daemon launch, desktop packages, local import, local UI release evidence. | Mobile store policy, hosted billing provider operations. |
| Mobile owner | Android/iOS pairing, upload/download, storage contribution, media/file permissions, store release evidence. | Desktop daemon internals beyond mobile API contracts. |
| Storage owner | Encrypted chunks, replica health, sync plans, repair, pin/evict, backup/restore storage evidence. | Hosted billing, app-store policy. |
| Organization owner | Timeline, files, search, OCR, places/events, tags, projects, clients, workspaces, correction loops. | Transport-level replication. |
| Security owner | Route boundaries, key/token handling, no-hosted-content reviews, support redaction, threat models. | Product pricing decisions. |
| Entitlements owner | Subscription tiers, offline grace, privacy-safe entitlement identifiers, billing integration. | User file storage or content metadata. |
| Web/local-web owner | Browser session model, local-web route isolation, CSRF/CORS, no-content-hosted web boundary. | Native app packaging. |
| Support owner | User guidance, incident communication, support bundle process, rollback communication. | Root-cause implementation fixes. |

If an area has no named owner for a release, that area is not public-production
ready.

## Critical Journeys Owned

- First encrypted library and import.
- Smart organization and local search.
- Device group pairing and revocation.
- Upload/download and storage-node repair.
- Backup verify/export/restore staging.
- Platform install/update/rollback.
- Subscription/entitlement check with offline grace.
- Business/workspace role and audit flows.

## Common Failure Modes And First Response

### Daemon startup failure

1. Confirm platform and release artifact.
2. Run local health probe: `curl -fsS http://127.0.0.1:4821/health`.
3. Check launcher logs without sharing secrets or private paths.
4. Roll back to last known good desktop artifact if startup blocks core use.

### Remote route exposure

1. Stop remote exposure or Tailscale Serve route.
2. Probe `/library/status` and `/pairing/sessions` remotely.
3. Revoke affected sessions.
4. Rotate exposed secrets and halt rollout.

### Import or storage corruption

1. Stop further imports on affected build.
2. Preserve job records and hashes.
3. Run backup verification.
4. Restore only into staging.
5. Do not delete active library evidence.

### Mobile pairing or revocation failure

1. Pause mobile rollout.
2. Re-run two-phone API smoke.
3. Revoke affected sessions/devices.
4. Publish user guidance if tokens or access are affected.

### Entitlement failure

1. Confirm existing local library remains safely usable.
2. Disable the broken entitlement gate if it blocks export, restore, revocation,
   or local access.
3. Verify billing identifiers did not include content metadata.

## Escalation

- Privacy/security exposure: security owner plus release owner immediately.
- Data loss/corruption: storage owner plus release owner immediately.
- Store rejection: platform owner plus entitlements owner when billing is
  implicated.
- Support spike: support owner plus relevant feature owner.

## Required Runbook Links

- [Public production release runbook](../public-production-release-runbook.md)
- [Rollback and recovery checklist](../rollback-recovery-checklist.md)
- [Production readiness review](../reliability/production-readiness-review-template.md)
- [Platform release and entitlements](../platform-release-and-entitlements.md)
