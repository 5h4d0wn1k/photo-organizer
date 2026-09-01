# Open Design Project Brief

## Product

Private Gallery is a local-first media and file organizer for photos, videos,
documents, and other personal files. The primary value is Google Photos-style
organization without hosted media, plus a local-cloud device group that can
share available storage across laptop and Android devices on trusted networks.

## Audience

- Primary: one owner using Linux desktop as the control center and Android
  devices as capture, upload, download, and shared-storage companions.
- Secondary: family/private beta users who need understandable privacy,
  replication, and recovery states without reading runbooks.

## Primary Workflows

- Import media/files, review the timeline, and organize by people, places,
  events, albums, archive state, and search/OCR metadata.
- Pair phones and local devices, see whether storage contribution is available,
  and understand what is local, encrypted, remote, or missing.
- Upload/download originals and previews from any paired device on the trusted
  network, with clear progress and failure recovery.
- Recover from empty libraries, daemon offline states, under-replication, or
  unavailable originals without panic.

## Screens To Design

- Desktop shell and navigation.
- Main gallery timeline.
- Files, Albums, People, Places, Events, Search, Archive, Devices, Sync/Activity,
  and Settings surfaces.
- Mobile pairing/gallery/local-cloud workspace.
- Shared status badges, cards, empty states, buttons, and diagnostics panels.

## Constraints

- Do not use real secrets, bearer tokens, vault keys, private media, or precise private metadata.
- Use sanitized screenshots, synthetic data, and explicit acceptance criteria.
- Keep Linux desktop and Android as the primary targets.
- Preserve local-first privacy: no hosted media, hosted ML, telemetry, or hidden
  cloud assumptions.
- Keep LAN HTTP as a development mode; beta copy should point users toward
  trusted-network/Tailscale/HTTPS posture.
- Avoid a marketing landing page. The first screen should be the actual library
  control surface.
- Use a practical professional palette, not a one-note beige/slate/purple theme.

## Acceptance Criteria

- A desktop user can identify library health, encryption/local-only posture,
  asset count, watch folders, and current sync state from the shell.
- A mobile user can reach gallery, devices, upload, download, and pairing states
  without ambiguous copy.
- Empty/error/loading states explain the safe next action.
- Design components are tokenized so future screens do not hard-code ad hoc
  colors and shapes.
- `dart format`, `flutter analyze`, and relevant widget tests pass.

## Notes For Open Design

Design language: "private media operations console". Dense but calm. Use real
controls, familiar file/media icons, compact cards, readable metadata, and
explicit security/status copy. Avoid decorative hero layouts and generic SaaS
marketing visuals.
