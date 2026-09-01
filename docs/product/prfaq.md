# Private Gallery PRFAQ

## Internal Press Release

Private Gallery launches as a privacy-first shared-storage local cloud and smart
organizer for photos, videos, documents, and work files. It lets people create a
private cloud from their own trusted devices, then organize and find files with
Google Photos-style intelligence without giving the company access to their
content.

With Private Gallery, a user can connect a laptop, phone, NAS, external drive, or
storage-only machine into a trusted device group. Files are stored as encrypted
chunks, replicated according to the user's protection policy, and made available
across LAN, private networks, and future relay/discovery paths. The same product
also helps users rediscover their library by dates, occasions, places, people,
projects, clients, workspaces, OCR text, file type, tags, and smart folders.

Private Gallery's promise is architectural, not only contractual: user content,
OCR text, embeddings, face data, metadata intelligence, vault keys, bearer
tokens, and search history do not enter company storage by default. Billing and
entitlement systems may verify subscriptions, but they must not become content
access paths.

## Customer Problem

People and small teams want cloud convenience, cross-device availability, and
smart organization. They also want private photos, family history, documents,
client files, and workspace context to stay under their own control. Hosted
services solve convenience by centralizing content. Many local-first tools solve
sync but do not solve rediscovery, albums, people, places, OCR, workspace
organization, backup confidence, or understandable availability states.

Private Gallery exists to combine both sides: private shared storage and useful
organization.

## Target Customers

- Personal users replacing hosted photo/file storage.
- Families sharing memories and spare device storage across trusted homes.
- Power users with laptops, phones, NAS devices, external drives, and remote
  machines.
- Small teams and businesses that need project/client/workspace file sharing
  without putting private work into a hosted content platform.

## Critical First Journey

The first journey the product must win:

1. User installs the desktop app.
2. User creates an encrypted local library.
3. User imports photos, videos, documents, or folders.
4. User creates a private device group.
5. User pairs a phone or storage device.
6. User sees files organized by timeline, type, folder/project context, and
   search.
7. User uploads or downloads one file from the paired device.
8. User sees whether the file is local, remote, protected, or under-replicated.
9. User verifies backup readiness or stages a restore.

Completion condition: the user trusts the app as a private cloud they can use
daily, not as a sync demo.

## Business Outcome

The business should earn low-cost subscriptions because it provides software,
release quality, support, relay/discovery convenience, and workspace controls,
not because it hosts user storage.

Primary metrics:

- Activation: first encrypted library plus first imported file.
- Shared-storage activation: first paired device plus first successful
  upload/download.
- Organization activation: first successful search, album/tag/correction, or OCR
  result.
- Trust activation: first visible protected/under-replicated availability state
  plus successful backup verification.
- Conversion: paid subscription after real local use.
- Retention: weekly successful browse/search/sync/backup activity.

## Pricing And Packaging Direction

- Around USD 1/month: core personal tier. It must include local cloud, device
  groups, LAN sync, smart organization, basic search, backup, and privacy
  defaults.
- Around USD 2/month: family/remote convenience. Add more devices, family
  sharing, larger OCR/intelligence scale, automation, and easier remote access.
- Around USD 3/month: power/workspace features. Add stronger replication,
  advanced organization, admin controls, and priority relay/discovery.
- Business tier: per user, per device, or per workspace pricing with roles,
  permissions, audit logs, retention controls, support, and admin reporting.

Billing correctness is a product requirement. Entitlements must use
privacy-preserving identifiers, local offline grace, and no content-derived
metering.

## V1 Essentials

- Desktop local daemon and app can create/open an encrypted library.
- Folder/file import supports photos, videos, documents, and other common file
  types without duplicate/demo data.
- Device group pairing works for at least one desktop plus one phone or storage
  device.
- Encrypted chunk storage, availability states, upload/download, backup verify,
  and restore staging are understandable.
- Timeline, files, albums/tags, places/events where applicable, OCR/search, and
  corrections provide real rediscovery value.
- Remote access uses Tailscale/HTTPS or a clearly labeled development LAN mode.
- The lowest paid tier is useful enough for real personal use.

## Future Expansion

- Native Android/iOS background encrypted chunk sync.
- Windows and macOS release hardening, installers, signing, and auto-update.
- Web/browser access and local web UI with strict privacy boundaries.
- Hosted relay/discovery that cannot inspect content.
- Approved local face, scene, and semantic model pipelines.
- Workspace roles, audit, retention, admin reports, and team sharing.
- App Store and Play Store distribution.

## Explicit Non-Goals

- Hosted user file/media storage by default.
- Company-run OCR, face recognition, semantic indexing, or model training over
  user libraries.
- Hidden telemetry, analytics SDKs, or crash dumps containing private paths or
  metadata.
- Social/public sharing before separate privacy and abuse review.
- A pricing model that makes the lowest tier too limited for proper use.

## FAQ

### Is this a photo app, a file sync tool, or a cloud drive?

It is all three, but the product center is a private shared-storage cloud with
smart organization. Photo organization is a major daily workflow, but documents,
screenshots, project files, and business workspaces are also in scope.

### Does the company store user files?

No hosted user content by default. Optional account, billing, entitlement,
support, relay, or discovery systems must not store or inspect user content.

### Why charge a subscription if storage is user-owned?

The subscription pays for maintained software, cross-platform releases,
entitlements, support, secure update paths, workspace features, and optional
relay/discovery convenience. The company is not selling hosted storage capacity.

### What makes the product trustworthy?

Local-first behavior, encrypted chunks, explicit availability states, protected
desktop routes, local intelligence, no default hosted content, backup/restore
evidence, and a lowest tier that does not punish normal use.

### What must not happen?

The product must not become only an encrypted sync admin panel. It must also be
beautiful and useful for finding, organizing, correcting, and recovering files.

## Open Risks

- Cross-platform release scope can exceed implementation capacity.
- App-store rules may constrain local cloud, file access, background sync, and
  billing models.
- Relay/discovery can create privacy confusion if the boundary is not explicit.
- Low prices require careful support, entitlement, and relay cost control.
- Smart organization requires strong UX; weak filters or hidden indexing gates
  will make the product feel less useful than hosted alternatives.
