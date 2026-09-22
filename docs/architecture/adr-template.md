# ADR: Local-First Encrypted Device Groups As The Default Architecture

## Status

Accepted for the current product direction.

## Context

Private Gallery must provide shared-storage cloud convenience, Google
Photos-style organization, and business/workspace file sharing without giving
the company access to user content or private metadata. The product also needs a
credible path across Windows, Linux, macOS, Android, iOS, web/browser access,
local web UI, and direct desktop packages.

The central design pressure is trust: users should be able to store, find, share,
and recover files across trusted devices while originals, OCR text, embeddings,
face data, keys, tokens, file names, exact metadata, and project/client context
stay under user control.

## Requirements

- Store user files and media on user-controlled devices by default.
- Encrypt managed originals/files as authenticated chunks.
- Allow trusted devices to contribute storage, sync, and repair.
- Keep organization intelligence local or on trusted devices.
- Support offline local use when internet or billing checks are unavailable.
- Keep desktop/admin routes protected from remote clients.
- Permit optional metadata-only bootstrap, billing, entitlement, relay, or
  discovery systems without content access.
- Keep low-cost subscriptions viable by avoiding hosted storage and hosted AI as
  default cost centers.

## Options Considered

### Option A: Hosted Cloud Storage And Hosted Intelligence

Store originals, metadata, OCR, and embeddings in company infrastructure.

Pros:

- Easier remote access and cross-device availability.
- Easier web app and support flows.
- Familiar SaaS billing model.

Cons:

- Violates the product promise.
- Creates privacy, compliance, security, storage, AI, and support liability.
- Makes USD 1-3/month pricing unrealistic without heavy limits.
- Turns the company into a content processor.

### Option B: Local-First Device Groups With Encrypted Chunks

Store files on user devices, seal managed originals/files into encrypted chunks,
track availability/replicas locally, and use optional hosted services only for
metadata bootstrap, billing, entitlements, relay, or discovery.

Pros:

- Aligns with the no-hosted-content promise.
- Lets storage cost scale with user-owned devices.
- Supports local/offline use.
- Allows storage-only devices to hold opaque encrypted chunks.
- Keeps local intelligence and correction loops under user control.

Cons:

- Harder onboarding and remote access than hosted storage.
- Requires clear availability states and repair UX.
- Cross-platform storage, permissions, background sync, and signing are harder.
- Support must work without inspecting private content.

### Option C: Hybrid Hosted Storage For Premium Tiers

Use local-first by default but add hosted content storage for paid tiers.

Pros:

- Could simplify remote access and recovery.
- Creates a familiar premium upsell.

Cons:

- Blurs the core promise.
- Requires a separate privacy/security/legal review.
- Adds storage and support costs that conflict with low-cost tiers.
- Risks product drift toward ordinary cloud drive economics.

## Decision

Use Option B as the default architecture: local-first encrypted device groups
with no hosted user content by default.

Hosted systems may exist only as separately reviewed boundaries for account,
billing, entitlement checks, metadata-only bootstrap, relay, discovery, support,
or release management. They must not receive user files, thumbnails, OCR text,
embeddings, face data, exact metadata, search history, vault keys, bearer tokens,
pairing tokens, or project/client/workspace content.

## Rationale

This option best satisfies the product's trust promise, low-cost subscription
model, and shared-storage vision. It keeps storage and intelligence under the
user's control while still allowing the company to sell software quality,
platform releases, support, entitlement scale, and optional relay/discovery
convenience.

## Tradeoffs

- Onboarding must explain device groups, availability, and protection clearly.
- Remote access depends on trusted networks, Tailscale/private networks, or
  carefully bounded relay/discovery.
- Platform support must account for different secure storage, background sync,
  filesystem, app-store, and permission constraints.
- Web/browser access is constrained unless served from a trusted local device or
  implemented with strict no-content boundaries.

## Rollout And Compatibility

- Preserve the current Rust daemon plus Flutter client architecture.
- Keep Linux desktop and Android as the current private-beta baseline while
  adding evidence requirements for Windows, macOS, iOS, web, local web UI, and
  direct desktop packages.
- Continue to block remote clients from desktop/admin routes.
- Treat LAN HTTP as development mode only.
- Require new shared-storage, billing, relay, web, or business features to prove
  they do not create content access paths.

## Reversibility

This is a high-cost but not fully irreversible decision. A future hosted-content
product could be designed as a separate opt-in product boundary, but it would
require a new ADR, security model, pricing model, compliance review, and user
consent story.

## Re-Evaluation Triggers

- Users cannot complete remote access without company-hosted content.
- Relay/discovery requirements begin to require content metadata.
- Business customers require hosted storage or compliance controls beyond the
  local-first model.
- iOS/web constraints make a key workflow impossible without architectural
  change.
- The low-cost subscription model fails because support or relay costs exceed
  revenue.
