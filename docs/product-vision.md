# Private Gallery Product Vision

Related product operating docs:

- [Pasteable Codex goal under 4000 characters](product-goal-4000.md)
- [Product PRFAQ](product/prfaq.md)
- [Critical user journeys](product/critical-user-journeys.md)
- [Platform release and entitlements](platform-release-and-entitlements.md)
- [Monetization and entitlements review](business/monetization-and-entitlements-template.md)
- [Unit economics scorecard](business/unit-economics-scorecard-template.md)
- [Year-one engineering roadmap](roadmap/year-one-engineering-roadmap-template.md)
- [Service ownership and runbook](platform/service-ownership-template.md)
- [Deploy and rollback policy](platform/deploy-and-rollback-policy-template.md)
- [Engineering operating system scorecard](platform/engineering-operating-system-scorecard-template.md)

## North Star

Private Gallery is a privacy-first shared-storage local cloud and smart organizer
for photos, videos, documents, and work files. It should give users cloud
convenience from their own trusted devices while keeping user content, metadata,
OCR text, face data, embeddings, keys, tokens, and private activity away from
company-controlled storage and intelligence systems.

The product is bigger than a photo gallery. Shared storage is the infrastructure:
trusted devices pool capacity, protect files, and make data reachable. Smart
organization is the daily value: users can find, understand, group, correct, and
recover their media and files without surrendering privacy.

## Customer Problem

People want Google Photos, iCloud, Dropbox, Google Drive, and workspace sharing
convenience, but they do not want private media, documents, family history,
client files, or business context mined, trained on, leaked, or locked inside a
hosted service. Existing local-first tools often solve sync but not discovery;
hosted products often solve discovery but require trusting the provider with
content and metadata.

Private Gallery should solve both sides: private shared storage plus meaningful
organization.

## Target Users

- Personal users replacing hosted photo/file storage with a private local cloud.
- Families sharing memories and spare device storage across trusted homes.
- Power users with laptops, phones, NAS devices, drives, and remote machines.
- Small teams and businesses that need workspace file sharing without pushing
  client/project data into a hosted content platform.

## Product Promise

- No hosted user content by default.
- No company access to files, originals, thumbnails, OCR text, embeddings, face
  templates, exact metadata, vault keys, bearer tokens, pairing tokens, or search
  history.
- No cloud AI, remote geocoding, hidden telemetry, analytics SDKs, or training on
  user data by default.
- Billing and account systems may exist only for subscriptions, entitlements,
  support, and release management. They must not become content access paths.
- Optional relay/discovery may help devices find each other, but it must not
  require the relay to inspect or store private content.

## Feature Pillars

### 1. Shared Local Cloud And Storage Pool

- Create private device groups.
- Pair phones, laptops, desktops, NAS, external drives, office machines, family
  devices, and storage-only devices by QR or manual invite.
- Pool trusted device storage into encrypted file availability.
- Store originals and general files as encrypted chunks.
- Sync device-to-device over LAN, hotspot, Tailscale/private networks, and future
  hosted relay/discovery for long-distance use.
- Keep useful local/offline behavior when internet or remote devices are absent.
- Show explicit availability states: local, remote, offline, missing,
  under-replicated, protected, corrupt, transfer pending.
- Upload, download, resume, cancel, retry, pin local, and safely evict protected
  files.
- Verify backup readiness, export restorable backups, and restore only into a
  staging root unless a separate explicit in-place restore design exists.

### 2. Smart Organization For Media And Files

- Organize photos and videos by timeline, dates, occasions, events, places,
  faces/people, albums, favorites, archive state, duplicates, OCR, scenes, and
  future semantic search.
- Organize PDFs, documents, screenshots, audio, archives, text files, work files,
  project folders, and mixed file collections.
- Group and search by project, client, workspace, device, source folder, file
  type, date, OCR text, topic, manual tag, smart folder, and future semantic
  meaning.
- Support correction loops: rename events, fix places, hide exact GPS, assign
  people, merge/split people, edit albums, tag files, and correct bad metadata.
- Keep organization reversible: metadata changes should not silently move,
  delete, upload, or mutate originals.

### 3. Privacy And Security

- Local-first by default.
- Encrypted originals/chunks and encrypted sensitive indexes.
- Tokens and keys stay local and are hashed or encrypted where stored.
- Desktop/admin routes remain protected from remote clients.
- LAN HTTP remains development mode; Tailscale/HTTPS is the preferred beta remote
  posture.
- Store and platform releases must preserve the no-hosted-content promise.

### 4. Personal, Family, And Business Use

- Personal: private Google Photos/Drive alternative.
- Family: shared memories, household storage pool, trusted remote relatives.
- Business/workspace: team file sharing, project folders, client files, local
  office cloud, roles, admin controls, audit logs, storage policies, remote-office
  sync, and privacy-first collaboration.

## Platform Completion Requirement

The product is not complete until it has a credible release path for:

- Windows desktop.
- Linux desktop.
- macOS desktop.
- Android through Google Play Store and internal/direct testing.
- iOS through Apple App Store.
- Web/browser access where privacy-compatible.
- Optional local web UI served from a trusted device.
- Direct desktop installers or packages.

Each platform needs signing, packaging, update strategy, current store-rule
review, privacy disclosure, release checks, and platform-specific tests before
public launch.

## Pricing And Packaging Direction

Use low-cost subscriptions because the company is not hosting user storage.
Pricing must preserve trust: the lowest tier must be genuinely useful.

- Around USD 1/month: core personal tier with local cloud, device group, LAN sync,
  smart organization, basic search, and backup.
- Around USD 2/month: more devices, family sharing, remote convenience,
  automation, and larger OCR/intelligence scale.
- Around USD 3/month: power/family/workspace features, stronger replication,
  advanced organization, admin controls, and priority relay/discovery.
- Business tier: per user, per device, or workspace pricing with roles, audit,
  permissions, support, retention controls, and admin reporting.

Required platform capabilities:

- Subscription entitlement checks that do not expose content.
- Clear offline grace behavior so local libraries do not break when billing
  checks are unavailable.
- Device, storage, relay, and workspace limits tied to entitlements.
- Local audit logs for security-sensitive workspace actions.
- Privacy-preserving support and diagnostics flows.

## V1 Completion Focus

The first broadly useful version should prove:

1. A user can create a device group and pair at least one phone and one desktop.
2. Files and media can be stored, encrypted, found, uploaded, downloaded, and
   protected across trusted devices.
3. Timeline, search, albums, places/events, OCR, files, availability, and backup
   are useful without demo data or hosted content.
4. The app can run locally/offline for local data and sync when trusted devices
   become reachable.
5. Desktop and mobile UX feel like a real private cloud and organizer, not a
   debug sync console.

## Explicit Non-Goals For The Privacy-First Product

- Hosted original/photo/file storage by default.
- Company-operated OCR, face recognition, semantic indexing, or model training
  over user libraries.
- Hidden telemetry, behavioral analytics, or remote crash dumps containing private
  paths or metadata.
- Public social sharing before a separate privacy and abuse review.
- A pricing model that makes the lowest tier too limited to use properly.

## Strategic Direction

Do not let the product become only an encrypted sync admin panel. The winning
version is a beautiful, understandable private cloud plus smart organizer.
Every feature should support at least one of these outcomes:

- Store privately.
- Find quickly.
- Share safely.
- Recover confidently.
- Work anywhere across trusted devices on all major platforms.
