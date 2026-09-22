# Codex Goal Prompt Under 4000 Characters

Goal: Complete Private Gallery as a privacy-first shared-storage local cloud and
smart organizer for photos, videos, documents, and work files. Users create
their own cloud from trusted devices: laptop, desktop, phone, NAS, external
drive, family device, office machine, or storage-only node. Files are encrypted
into chunks, replicated across the user's devices, usable locally/offline, and
reachable over LAN, hotspot, Tailscale/HTTPS, and future relay/discovery for
infinite-distance sync without hosted user content.

Product promise: the company must not take or access user files, originals,
thumbnails, OCR text, face data, embeddings, exact metadata, vault keys, bearer
tokens, pairing tokens, or private activity. Billing/support may exist, but
never as a content path. No cloud AI/training/hidden telemetry by default.
Local-first is mandatory.

Core features: setup encrypted library; import/copy/reference files; dedupe;
timeline; albums; places; events/occasions; people/faces; OCR; scenes; semantic
search; tags; smart folders; favorites/archive; duplicates; screenshots;
PDFs/docs/audio/archives/text/work files; organize by date, place, event, face,
project, client, workspace, folder, device, file type, topic, and manual
corrections. Metadata changes stay reversible and never silently mutate
originals.

Shared storage features: create/join device groups; QR/manual pairing;
upload/download; resume/cancel/retry; pin local; evict only protected files;
replica health; availability states; backup verify/export/restore staging;
revocation; role/admin controls for families/business/workspaces.

Platforms required before "complete": Linux, Windows, macOS desktop
apps/packages; Android Play Store; iOS App Store; web/browser access where
privacy-compatible; local web UI from trusted device; direct desktop installers.
Each needs signing, packaging, update/rollback, privacy disclosures, platform
tests, and store review.

Use cases: personal private Google Photos/Drive replacement; families sharing
memories/storage; power users with many machines; small businesses/workspaces
sharing project/client files with roles, audit logs, permissions, retention, and
privacy-first collaboration.

Pricing: low-cost subscription because company does not host storage. Approx
$1/month core personal tier with most important features usable; ~$2 adds more
devices/family/remote convenience/automation; ~$3 adds power/workspace features,
stronger replication, advanced organization, admin controls, and priority
relay/discovery. Business can be per user/device/workspace. Entitlements must
not expose content, and local access/export/restore must survive offline grace.

Build direction: do not make only a sync admin panel. Ship a beautiful,
understandable private cloud plus organizer. Every task should help users store
privately, find quickly, share safely, recover confidently, and work anywhere
across trusted devices.
