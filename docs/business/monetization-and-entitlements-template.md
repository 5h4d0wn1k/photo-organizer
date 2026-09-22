# Monetization And Entitlements Review

This document defines how Private Gallery can charge for software, cross-platform
release quality, support, and optional relay/discovery convenience without
turning the company into a hosted content provider.

## Revenue Model

Primary model: low-cost subscription.

Secondary model: business/workspace plans priced per user, device, or workspace.

The product should not monetize hosted storage capacity by default. User devices
provide storage. The company sells maintained software, secure releases,
entitlements, support, platform reach, optional relay/discovery priority, and
workspace controls.

## Product Promise

Billing and entitlement systems must not receive or require:

- Files, originals, thumbnails, previews, or encrypted chunks.
- OCR text, embeddings, face data, scene labels, or semantic vectors.
- Exact GPS/capture metadata, folder names, project/client names, workspace
  content, search history, or file names.
- Vault keys, bearer tokens, pairing tokens, recovery secrets, or raw device
  private keys.

Allowed billing data is limited to account identifiers, plan identifiers,
payment provider status, coarse entitlement counters, support metadata, and
privacy-safe device/workspace counts.

## Tier Direction

| Tier | Target price | Must include | Can limit |
| --- | --- | --- | --- |
| Personal core | Around USD 1/month | Local cloud, one device group, LAN sync, organization, basic search, backup, privacy/security defaults. | Device count, family members, relay priority, workspace/admin features, large OCR/intelligence batches. |
| Family/remote | Around USD 2/month | More devices, family sharing, remote convenience, automation, larger OCR/intelligence scale. | Business audit, advanced admin, high-priority relay, enterprise support. |
| Power/workspace | Around USD 3/month | Stronger replication, advanced organization, storage-policy controls, workspace-ready features, priority relay/discovery. | Larger team/business governance, contractual support. |
| Business | Per user, device, or workspace | Roles, permissions, audit logs, project/client organization, support, admin reporting, retention controls. | Enterprise SSO, custom compliance, dedicated support. |

The lowest paid tier must remain genuinely useful. It should not block the core
private cloud loop: create library, import files, organize/search, pair a device,
sync locally, and verify backup.

## Entitlement Boundaries

Entitlements may gate:

- Number of trusted devices.
- Number of device groups or workspaces.
- Family/member count.
- Relay/discovery priority or monthly relay bandwidth.
- OCR/intelligence batch scale.
- Advanced replication policies and storage-node automation.
- Business roles, audit retention, admin reporting, and support level.

Entitlements must not gate:

- Access to already-local files.
- Ability to export or restore the user's own library.
- Ability to revoke devices or sessions.
- Ability to remove billing/account data.
- Core safety checks, encryption, route protection, or backup integrity.

## Required Platform Capabilities

- Privacy-preserving account and entitlement identifiers.
- Local entitlement cache with offline grace.
- Clear degraded mode when entitlement checks are unreachable.
- Store-specific purchase validation for Play Store and App Store where required.
- Direct billing path for desktop/web if chosen.
- Entitlement reconciliation that never scans library contents.
- Local audit logs for business/workspace security actions.
- Support bundle generation that excludes private content and secrets by default.

## Payment Channel Decisions

Open decisions before public paid launch:

- Whether mobile subscriptions are app-store-only, direct-billed, or hybrid.
- Whether desktop users can subscribe without a hosted account.
- Whether business plans require a hosted admin account or local license file.
- How long offline grace lasts after the last successful entitlement check.
- Which features remain available after cancellation for data portability.

## Cost-To-Serve Risks

- Relay/discovery can become expensive if priced too generously.
- App-store fees can consume a large share of USD 1/month plans.
- Support costs may exceed revenue if diagnostics are weak or setup is confusing.
- Cross-platform signing, review, and release maintenance can dominate early
  engineering time.
- Business plans require auditability, support, and security review beyond
  personal/family needs.

## Margin Guardrails

- Keep company-hosted storage out of default plans.
- Keep relay/discovery optional, bounded, and measurable without content access.
- Prefer local computation over hosted AI.
- Make support diagnostics privacy-preserving and self-serve where possible.
- Avoid unlimited business/workspace features in low-cost personal tiers.

## Expansion Opportunities

- Paid remote relay/discovery priority.
- Family admin and device-management convenience.
- Business workspace roles, audit logs, retention, and support.
- Local model packs distributed with verified hashes and clear licenses.
- Desktop auto-update, signed release channels, and priority support.
- Integrations with NAS, private networks, and enterprise device management.

## Launch Readiness Checklist

- Entitlement model documented and implemented without content-derived metering.
- Lowest tier tested against the full core user journey.
- Offline grace behavior tested.
- Cancellation and export behavior tested.
- Play Store, App Store, desktop, and web billing rules reviewed for scoped
  platforms.
- Support bundle redaction tested.
- Business/workspace audit events validated before business launch.
