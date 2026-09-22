# Platform Release And Entitlements Plan

This plan turns the product vision into release evidence. A platform or paid tier
is not complete until its evidence is available and repeatable.

## Platform Completion Matrix

| Surface | Completion evidence |
| --- | --- |
| Linux desktop | Signed or checksummed bundle/package, daemon startup smoke, import/search/vault/backup smoke, rollback instructions, dependency notes. |
| Windows desktop | Signed installer/package, daemon launch strategy, Windows secure storage validation, import/vault smoke, uninstall/update behavior. |
| macOS desktop | Signed and notarized build, keychain validation, sandbox/privacy prompt review, import/vault smoke, update and rollback path. |
| Android / Play Store | Release-signed APK/AAB, Play policy/privacy declarations, pairing/upload/download/storage-node smoke, revocation smoke, staged rollout plan. |
| iOS / App Store | App Store signing, privacy nutrition labels, media/files permission review, secure storage validation, pairing/download/upload design within iOS limits. |
| Web/browser | Privacy-compatible web boundary, no content upload to company servers by default, auth/session model, browser storage limits, download/upload smoke. |
| Local web UI | Served from a trusted device, desktop/admin route isolation, LAN/Tailscale exposure rules, CSRF/CORS review, browser smoke. |
| Direct desktop distribution | Installer/package checksums, signing where available, update channel, rollback path, support diagnostics. |

## Store And Release Gates

- Each release artifact must be built from an immutable commit or tag.
- Store builds must have privacy disclosures that match the no-hosted-content
  promise.
- Signing keys, app-store credentials, bearer tokens, pairing tokens, vault keys,
  service credentials, runtime databases, and media exports must never be
  committed.
- Remote access must expose only the intended mobile/local-web surface. Desktop
  control APIs remain protected from remote clients.
- Platform-specific tests must cover startup, secure storage, import or upload,
  search/organization, availability, backup/restore where applicable, and
  revocation.

## Entitlement Model

Billing is for product access, scale, convenience, support, and optional
relay/discovery priority. Billing must not grant the company content access.

| Tier | Intended value | Likely entitlements |
| --- | --- | --- |
| Personal core, around USD 1/month | Make the product genuinely usable. | Local cloud, device group, LAN sync, organization, basic search, backup, privacy/security defaults. |
| Family/remote, around USD 2/month | More devices and convenience. | Higher device limits, family sharing, remote/Tailscale convenience, larger OCR/intelligence batches, more automation. |
| Power/workspace, around USD 3/month | Stronger protection and advanced workflows. | Advanced organization, stronger replication policies, admin controls, priority relay/discovery, workspace-ready features. |
| Business | Team/private workspace use. | Per user/device/workspace limits, roles, permissions, audit logs, retention controls, support, admin reporting. |

## Required Entitlement Capabilities

- Local entitlement cache with offline grace so existing local libraries remain
  usable when billing checks are unreachable.
- Clear limits for device count, workspace count, family members, relay priority,
  OCR/intelligence scale, and admin/workspace controls.
- Privacy-preserving billing identifiers that do not include library content,
  file names, OCR text, face data, exact metadata, or vault keys.
- Local audit logs for business/workspace security actions.
- A support bundle flow that redacts or excludes private content and secret
  material by default.

## Open Decisions

- Whether subscriptions are sold only through app stores on mobile, direct billing
  on desktop, or a hybrid model.
- Whether the web option is a hosted account surface, a local web UI only, or
  both with strict no-content boundaries.
- The exact free trial and offline-grace behavior.
- The first public launch surface: Linux/Android private beta, cross-desktop
  beta, or store-first mobile release.
