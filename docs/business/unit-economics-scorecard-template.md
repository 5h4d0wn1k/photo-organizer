# Unit Economics Scorecard

Private Gallery's pricing only works if the company avoids becoming a storage,
AI, analytics, or high-touch support business by accident. This scorecard tracks
whether low-cost subscriptions can remain healthy while preserving the
no-hosted-content promise.

## Revenue Units

| Unit | Notes |
| --- | --- |
| Personal subscriber | Around USD 1/month; must be useful enough for real local cloud and organization use. |
| Family/remote subscriber | Around USD 2/month; pays for more devices, sharing, remote convenience, and larger intelligence scale. |
| Power/workspace subscriber | Around USD 3/month; pays for stronger replication, advanced organization, admin controls, and priority relay/discovery. |
| Business workspace | Per user/device/workspace; pays for roles, audit, retention, support, and admin reporting. |

## Cost Drivers

| Cost driver | Gross-margin risk | Control |
| --- | --- | --- |
| App-store fees | High on USD 1/month tiers. | Prefer annual plans where allowed, direct billing on desktop/web where appropriate, and clear app-store-specific pricing if needed. |
| Relay/discovery | Can grow with remote usage. | Bound relay priority, measure coarse bandwidth without content metadata, and keep local/Tailscale paths first-class. |
| Support | Can exceed low-tier revenue. | Improve onboarding, self-serve diagnostics, privacy-safe support bundles, and platform-specific runbooks. |
| Cross-platform releases | Requires signing, packaging, store review, and tests. | Sequence platform expansion; avoid broad launch without release evidence. |
| Local model distribution | License review and support risk. | Require pinned hashes, local import/install audit, and optional packs only after review. |
| Business features | Audit/support/security expectations rise quickly. | Charge separately, define roles and retention, and require business readiness gates. |

## Margin Assumptions

- Default plans do not include company-hosted user storage.
- Default plans do not include hosted OCR, hosted face recognition, hosted
  semantic indexing, or training on user libraries.
- Relay/discovery is convenience infrastructure, not a bulk storage product.
- Support artifacts exclude content and secrets, reducing legal and operational
  exposure.
- Local devices carry storage and compute costs.

## Metrics To Track

Track only privacy-safe counters:

- Active subscribers by tier.
- Coarse device count per entitlement.
- Coarse workspace/member count for business plans.
- Relay/discovery usage totals without file names, metadata, or content.
- Support contact rate per tier.
- Release failure rate by platform.
- Activation rates: first library, first import, first paired device, first
  search, first backup verify.
- Churn after failed pairing, failed import, failed update, or entitlement
  confusion.

Do not track:

- File names.
- Folder/project/client names.
- Search queries.
- OCR text.
- GPS/capture metadata.
- Face/embedding data.
- Vault identifiers that can be correlated with content.

## Tier Health Questions

### Personal Core

- Can a user complete the full local cloud loop without upgrading?
- Does the plan cover support and app-store fees?
- Are device limits generous enough to feel fair but bounded enough to preserve
  upgrade paths?

### Family/Remote

- Does remote convenience create measurable relay cost?
- Can family sharing be supported without high manual support load?
- Are revocation and role basics clear enough for non-technical families?

### Power/Workspace

- Are stronger replication policies and advanced organization valuable enough to
  justify the tier?
- Does the tier avoid becoming a cheap business plan with expensive support?

### Business

- Are roles, audit logs, retention, support, and admin reporting mature enough to
  charge business users?
- Are business users likely to need SSO, MDM, legal review, or custom support
  before launch?

## Red Flags

- Relay/discovery cost per low-tier user approaches subscription revenue.
- Support tickets require inspecting private data.
- The lowest tier cannot complete the critical user journey.
- App-store policies force a billing model that conflicts with direct desktop
  entitlements.
- Business users ask for compliance features before role/audit basics are
  reliable.
- Platform release maintenance blocks core product reliability work.

## Decision Gates

- Launch paid personal tier only after the first library/import/pair/search/backup
  journey is smooth.
- Launch family/remote tier only after revocation, device status, and remote
  access are understandable.
- Launch power/workspace tier only after storage policy and advanced organization
  are user-visible and tested.
- Launch business only after roles, permissions, audit logs, support boundaries,
  and backup/restore evidence are production-ready.
