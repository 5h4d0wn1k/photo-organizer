# VISION — Photo Organizer (flagship: `photo-organizer`)

> Permanent contract. If a PR, feature, workflow, or dependency conflicts with
> this file, the change does not land. Re-read before every architecture review.

## 1. The promise (what this product is *for*)

Your photos and videos are your private history. This product keeps that history
**yours** — organized, searchable, and reachable across all of your own devices,
without handing any of it to a service you do not operate.

This is an organizers-first application: domain assets (photos, videos, ML
derived metadata — embeddings, OCR text, scene tags, faces, EXIF) live in a
local-first, encrypted-at-rest library, synchronized device-to-device over a
mesh you own, and are never a precondition for any third-party's data plane.

## 2. Non-negotiable product pillars (ranked, no trade-offs)

1. **Privacy by construction.** No data leaves the mesh except to a node you
   control. No telemetry, no analytics SDK, no third-party crash reporting. If a
   dependency would phone home, it is replaced before it ships.
2. **No accounts, no signups — unless genuinely necessary.** The product must
   work fully on-device with zero identity. Account/metadata provisioning is an
   opt-in convenience, never a gate.
3. **Security first.** SQLCipher provides transparent, per-node encryption at
   rest of the whole gallery database; the vault exchange uses authenticated
   AEAD (ChaCha20-Poly1305) hardening. Secrets (keyring) are OS-protected.
   Compatible pre-Quantum aliens remain hermetic build output only.
4. **Open source, forever.** Apache-2.0. No open-core bait-and-switch, no
   "community vs. pro" license split of core functionality.
5. **Underscore the mesh.** Decentralized P2P (iroh) gives shared, pooled
   storage over LAN **and** internet across your own nodes. All nodes are peers;
   there is no star-server authority. Papers: sync_transport.rs.
6. **Determine everything hermetic.** CI/release must build one artifact shape
   from source on every target (linux/windows/macos/android/ios) with vendored
   dependency sources (OpenSSL, SQLCipher, shipped vendor patch files), so a
   checkout of a tag is byte-reproducible. No vcpkg, no service-with-API-rate
   gates in the critical path.
7. **Professional repository habit.** Every repo carries a README that tells the
   story and real install docs; branch protection on main; dependabot sees
   hermetic green builds; SBOM/audit/lints gate merges; releases are tag-gated,
   signed-shape labeled, and deterministic.

## 3. Explicit non-goals (say it so it never sneaks in)

- We do NOT sell ads. We do NOT resell data. We do NOT ingest your media into
  any cloud for model training. We do NOT ship an anonymous analytics beacon.
- We do NOT require a signup or email to use the core product.
- We do NOT hide a core feature (even "pooled storage") behind a licensied-
  walled enterprise edition.

## 4. Decision protocol

- New dependency: `cargo audit` green + vendored or hermetic-in-CI. A dependency
  whose build script negotiates system state (vcpkg, telemetry, dynamic OS
  discovery) requires a hermetic feature flag or replacement, not an ignore line.
- New endpoint/RPC: must be daemon-hosted (native_core), authenticated by the
  mesh keyring, and never world-addressable by default.
- New workflow: hermetic, tagged-release driven, artifact shape labeled
  (signed/unsigned) truthfully — never claim signing you did not perform.
- New platform: reuse the exact same hermetic lane pattern already proven in
  `release.yml` (same vendored sources, same matrix naming), so mobile Android
  `.so` + Flutter APK and iOS unsigned `.app` build deterministically from

  one tag, matching desktop.

## 5. Standing goals (re-checked at every phase gate)

| Goal | Owner | Gate |
|------|-------|------|
| Desktop hermetic green (win+linux+mac) | CI/CD | release.yml matrix = green |
| Android hermetic APK (false-data-free) | CI/CD | same lane pattern + cargo-ndk |
| iOS unsigned .app (same hermetic lane) | CI/CD | lane extends macOS |
| Pooled multi-node mesh docs + happy path | Product | sync_transport.rs tests |
| Org-wide SEO (descriptions/topics/license) done for every repo | Ops | sweep report |

_Nothing in this file is a suggestion._ It is the reason a change gets merged.
