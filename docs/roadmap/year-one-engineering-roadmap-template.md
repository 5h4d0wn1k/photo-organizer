# Year-One Product Engineering Roadmap

This roadmap sequences the full Private Gallery vision into a first year of
engineering work. It preserves the end state: cross-platform privacy-first
shared storage plus smart organization for media, documents, and work files.

## Year-One Success Definition

By the end of year one, Private Gallery should have credible evidence for:

- A complete personal local-cloud loop: create encrypted library, import mixed
  files, organize/search, pair a device, transfer a file, inspect availability,
  and verify backup.
- A private shared-storage loop: encrypted chunks, replica status, storage-node
  contribution, repair, pin/evict where scoped, and safe revocation.
- Smart organization beyond photos: files, documents, screenshots, OCR, tags or
  folders, project/client/workspace-ready metadata, and corrections.
- Release evidence for the scoped platforms, with a path toward Windows, Linux,
  macOS, Android/Play Store, iOS/App Store, web/browser, local web UI, and direct
  installers.
- Subscription and entitlement seams that preserve content privacy and safe
  offline local use.

## Quarter 1: Prove The Core Private Cloud Loop

Priorities:

- Stabilize local daemon startup and encrypted library setup.
- Make mixed file import first-class: photos, videos, documents, screenshots,
  audio, archives, text files, and project folders.
- Improve file tree, timeline, search, availability, and backup surfaces from
  live API data.
- Ensure encrypted-only managed originals create verified chunks and clear
  availability state.
- Make device group creation and pairing understandable on desktop and Android.
- Keep LAN HTTP development-only and Tailscale/HTTPS preferred for remote beta.

Evidence:

- First library/import/pair/search/backup journey passes on a fixture library.
- Remote desktop/admin route probes return forbidden.
- No demo data is required for core screens.
- Backup verify and restore staging work on an encrypted fixture.

Quality gates:

- Rust tests for storage, import, vault chunks, route boundaries, and backup.
- Flutter analyze and focused widget tests for setup/import/timeline/files/search.
- Android API smoke when mobile pairing/upload/download changes.

## Quarter 2: Make Organization And Shared Storage Useful Daily

Priorities:

- Add richer organization for documents, screenshots, PDFs, audio, archives,
  text files, projects, clients, workspaces, tags, and smart folders.
- Expand OCR coverage and indexing state visibility.
- Make correction loops durable: event/place/person/tag/project/client metadata.
- Improve mobile gallery, upload/download, availability, and device status UX.
- Add clearer storage policy editing, under-replication repair, retry/cancel, and
  replica health details.
- Improve privacy-safe diagnostics and support bundles.

Evidence:

- User can find a file by date, type, OCR text, source folder, tag/project, and
  availability state.
- Storage-node contribution and chunk repair are visible and testable.
- Canceled, duplicate, interrupted, and resumed transfers behave predictably.

Quality gates:

- Search/index coverage tests.
- Transfer retry/cancel tests.
- Support bundle redaction checks.
- Accessibility and visual checks for core desktop/mobile workflows.

## Quarter 3: Package Paid Personal And Family/Remote Use

Priorities:

- Implement entitlement seams without content-derived metering.
- Add local entitlement cache and offline grace.
- Define device/member/relay/intelligence limits for personal and family tiers.
- Prepare Play Store and direct desktop release evidence for scoped platforms.
- Harden remote access via Tailscale/private networks and optional
  relay/discovery design.
- Add app signing, update, rollback, and release checklist coverage for scoped
  platforms.

Evidence:

- Lowest tier completes the core user journey.
- Entitlement checks do not include file names, OCR text, metadata, keys, or
  tokens.
- Cancellation/export behavior preserves user control.
- Store/privacy disclosures match the no-hosted-content promise.

Quality gates:

- Entitlement privacy tests and code review.
- Offline grace tests.
- Release smoke for every in-scope platform.
- Secret scan, dependency audit, and SBOM evidence.

## Quarter 4: Expand Platform And Workspace Readiness

Priorities:

- Harden Windows and macOS desktop release paths with signing, secure storage,
  daemon launch, import/vault smoke, update, and rollback.
- Scope iOS implementation within App Store and iOS background/file permission
  constraints.
- Decide whether web is hosted account surface, local web UI, or both.
- Add business/workspace basics: roles, permissions, audit logs, project/client
  organization, admin reporting, and support boundaries.
- Prepare priority relay/discovery and stronger replication features for
  power/workspace plans.

Evidence:

- Platform completion matrix has evidence for launched surfaces.
- Workspace roles and revocation are testable.
- Audit logs are useful without leaking content.
- Business launch gates are explicit even if business remains beta.

Quality gates:

- Platform-specific install/update/uninstall smoke.
- Permission and secure-storage validation per platform.
- Business authorization and audit tests.
- Release owner signoff per scoped surface.

## Must-Have Now

- Local-first encrypted library.
- Mixed file import and organization.
- Device groups and trusted pairing.
- Encrypted chunk storage and availability state.
- Upload/download/retry/cancel.
- Backup verify/export/restore staging.
- No hosted content by default.
- Clear route boundaries.

## Should-Have Soon

- More useful file/project/workspace organization.
- OCR scale and coverage controls.
- Mobile gallery-grade UX.
- Storage policy editor and repair UX.
- Entitlement cache and offline grace.
- Release evidence for more desktop platforms.

## Wait For Proof

- Hosted relay/discovery at broad scale.
- iOS background sync depth.
- Hosted account surface for web.
- Business/enterprise contracts.
- Advanced semantic search and face models.
- Enterprise SSO, compliance packs, or custom support.

## Re-Architecture Triggers

- SQLite queries cannot support large libraries and mixed file search with
  acceptable latency.
- Encrypted chunk placement or replica planning becomes too slow for large
  device groups.
- Mobile background sync requires a native transport layer beyond the current
  API flow.
- Web/local-web access requires a separate authenticated UI boundary.
- Business roles require stronger authorization and audit modeling than the
  personal vault model.
- Entitlement or relay systems threaten the no-content boundary.

## Risk Watchlist

- Product drifts into a sync admin panel instead of a daily organizer.
- Cross-platform ambition outruns release quality.
- Low pricing cannot cover app-store fees, relay, and support.
- Store rules conflict with local-first file access or billing.
- Support flows accidentally collect private metadata.
- Business users expect compliance before the product has basic roles and audit.
